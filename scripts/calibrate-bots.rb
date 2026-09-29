#!/usr/bin/env ruby
# Calibrates the tournament's bots in the tournament's own conditions: every
# game goes through `arena --mixed` at 9x9, komi 6.5, max_moves 200, 60 s
# main time per side, 10 s response deadline and grace (as the runner plays
# game_length 1), each bot with its own per-game --seed (Seeds.with_bot_seed),
# both colors, one game per arena process, at most --lanes games at a time.
#
#   mise exec -- scripts/calibrate-bots.rb endings --out DIR [--budget S]
#   mise exec -- scripts/calibrate-bots.rb ladder --out DIR --games N \
#     --bot NAME=COMMAND ... --pairing NAME,NAME ... [--budget S]
#
# endings: random generation-0 networks (seeded, from the repository's
#   initial-population, 9x9, one hidden layer of 20, all feature groups)
#   and engine/example.ann play each ENDINGS_BOTS command, 5 seeds x both
#   colors. For each game ended by two passes or at the move limit, the
#   arena's moves are loaded into the seeded GNU Go referee
#   (GameResult::REFEREE) and its final_score compared with the arena's
#   Tromp–Taylor winner. Per command: games, winner changes among games
#   ended by passes (and to whom the arena's count gives the win), resigned
#   games, move-limit games (and their winner changes) apart.
# ladder: each --pairing plays --games games (half with each color) between
#   two --bot commands; per pairing, the first bot's wins with a 95 % Wilson
#   interval.
#
# Each game's result is written to DIR as it ends, so a run stopped by
# --budget (seconds after which no new game starts) or interrupted resumes
# where it stopped when run again with the same arguments; DIR holds the
# schedule and refuses a different one. The tables print once every game
# is played, with the command that defines them. --lanes N (default 3, the
# owner's concurrency).
require 'bundler/setup'
require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require 'shellwords'
require_relative '../ruby/game_result'
require_relative '../ruby/seeds'

module CalibrateBots
  ROOT = File.expand_path('..', __dir__)
  LETTERS = 'ABCDEFGHJKLMNOPQRSTUVWXYZ'.freeze
  SIZE = 9
  KOMI = 6.5
  MAX_MOVES = 200
  MAIN_TIME = 60
  DEADLINE = 10
  GRACE = 10
  SEED = 'calibrate-bots'.freeze
  NETWORKS = 10
  ENDINGS_SEEDS = 5
  ENDINGS_BOTS = [
    'gnugo --level 0 --mode gtp',
    'gnugo --level 0 --mode gtp --capture-all-dead',
    'michi gtp --sims 150',
    'michi gtp --sims 150 --play-until-end',
    'michi gtp --sims 1000',
    'michi gtp --sims 1000 --play-until-end'
  ].freeze

  # One arena --mixed run's stdout for the single game `id`: its result,
  # end and moves, or { failure: why } for a failure record, a one-sided
  # network error, no record, or a played game without the trailer.
  def self.parse_arena(text, id)
    lines = text.split("\n")
    record = lines.find { |line| line.start_with?("#{id}\t") } if lines.first == 'arena protocol 3 ready'
    return { failure: "no record for #{id}" } unless record

    fields = record.split("\t")[1...-1].to_h { |field| field.split('=', 2) }
    if fields.key?('error')
      return { failure: "#{fields['end']} #{fields['error']}: #{fields['message']}" }
    end
    return { failure: 'no trailer' } unless lines.last == 'done 1'

    { result: fields.fetch('result'), end: fields.fetch('end'), moves: fields.fetch('moves').split(',') }
  end

  # The game's moves (the arena's vertices, black first) as SGF for the
  # referee's loadsgf.
  def self.sgf(moves, size, komi)
    nodes = moves.each_with_index.map do |vertex, k|
      point = if vertex == 'pass'
                ''
              else
                column = LETTERS.index(vertex[0].upcase)
                row = Integer(vertex[1..], 10)
                ('a'.ord + column).chr + ('a'.ord + size - row).chr
              end
      ";#{k.even? ? 'B' : 'W'}[#{point}]"
    end
    "(;GM[1]FF[4]SZ[#{size}]KM[#{komi}]#{nodes.join})"
  end

  # The 95 % Wilson score interval of `wins` in `n` games; nil without games.
  def self.wilson(wins, n, z = 1.96)
    return nil if n.zero?

    p = wins.to_f / n
    center = p + (z * z / (2 * n))
    half = z * Math.sqrt((p * (1 - p) / n) + (z * z / (4 * n * n)))
    denominator = 1 + (z * z / n)
    # At 0 or n wins one end is exactly 0 or 1; rounding would miss it.
    [wins.zero? ? 0.0 : (center - half) / denominator, wins == n ? 1.0 : (center + half) / denominator]
  end

  # The winner's color of a result ('B', 'W', or '0' for a draw).
  def self.winner(result)
    result == '0' ? '0' : result[0]
  end

  # Counts for one bot command's endings games, each { bot_color:, end:,
  # result:, referee: } or { failure: }. Winner changes count only games
  # ended by two passes; to_bot means the arena's count gives the bot a
  # game the referee gives the network. Resignations and the move limit
  # are apart: a resigned position says nothing about dead stones, and at
  # the limit the referee judges an unfinished game.
  def self.endings_row(games)
    played = games.reject { |g| g[:failure] }
    passes = played.select { |g| g[:end] == 'passes' }
    changed = passes.reject { |g| winner(g[:result]) == winner(g[:referee]) }
    limit = played.select { |g| g[:end] == 'limit' }
    resigned = played.select { |g| g[:end] == 'resign' }
    {
      games: games.size, failures: games.size - played.size, passes: passes.size,
      changed: changed.size,
      to_bot: changed.count { |g| winner(g[:result]) == g[:bot_color] },
      to_network: changed.count { |g| winner(g[:result]) != g[:bot_color] },
      margin_only: passes.count { |g| g[:result] != g[:referee] && winner(g[:result]) == winner(g[:referee]) },
      resigned: resigned.size,
      bot_resigned: resigned.count { |g| winner(g[:result]) != g[:bot_color] },
      limit: limit.size,
      limit_changed: limit.count { |g| winner(g[:result]) != winner(g[:referee]) },
      time: played.count { |g| g[:end] == 'time' }
    }
  end

  # Counts for one ladder pairing's games, each { a_color:, end:, result: }
  # or { failure: }, by player whatever the color.
  def self.ladder_row(games)
    played = games.reject { |g| g[:failure] }
    a_wins = played.count { |g| winner(g[:result]) == g[:a_color] }
    draws = played.count { |g| winner(g[:result]) == '0' }
    resigned = played.select { |g| g[:end] == 'resign' }
    {
      games: games.size, failures: games.size - played.size, a_wins:, b_wins: played.size - a_wins - draws, draws:,
      a_resigned: resigned.count { |g| winner(g[:result]) != g[:a_color] },
      b_resigned: resigned.count { |g| winner(g[:result]) == g[:a_color] },
      limit: played.count { |g| g[:end] == 'limit' }
    }
  end

  # Plays the scheduled games that have no result in DIR yet and prints the
  # tables once all have.
  class Run
    # color: the bot's (endings) or the first bot's (ladder); black and
    # white: [:bot, COMMAND with --seed] or [:network, PATH].
    Game = Struct.new(:id, :group, :color, :black, :white, :referee_seed)

    def initialize(argv)
      @argv = argv.dup
      @lanes = 3
      @budget = nil
      @bots = {}
      @pairings = []
      @games = nil
      @mode = argv.shift
      parser.parse!(argv)
      abort parser.banner unless %w[endings ladder].include?(@mode) && @out && argv.empty?
      abort '--lanes must be positive' unless @lanes.positive?
      check_ladder_options if @mode == 'ladder'
    end

    def call
      %w[engine/arena initial-population/initial-population engine/example.ann].each do |file|
        abort "build #{file} first (mise run build)" unless File.exist?(File.join(ROOT, file))
      end
      FileUtils.mkdir_p(File.join(@out, 'games'))
      FileUtils.mkdir_p(File.join(@out, 'work'))
      games = @mode == 'endings' ? endings_schedule : ladder_schedule
      check_schedule(games)
      play(games)
      results = games.to_h { |g| [g.id, result(g)] }
      missing = results.count { |_, r| r.nil? }
      if missing.positive?
        puts "#{games.size - missing} of #{games.size} games played; run the same command again to resume"
        return 0
      end
      puts "Command: #{defining_command}"
      puts
      @mode == 'endings' ? endings_report(games, results) : ladder_report(games, results)
      0
    end

    private

    def parser
      @parser ||= OptionParser.new do |opts|
        opts.banner = "Usage: scripts/calibrate-bots.rb endings|ladder --out DIR [--budget S] [--lanes N]\n" \
                      '       ladder: --games N --bot NAME=COMMAND ... --pairing NAME,NAME ...'
        opts.on('--out DIR', 'results directory (resumable)') { |d| @out = File.expand_path(d) }
        opts.on('--budget S', Float, 'start no game after S seconds') { |s| @budget = s }
        opts.on('--lanes N', Integer, 'games at a time (default 3)') { |n| @lanes = n }
        opts.on('--games N', Integer, 'ladder: games per pairing, even') { |n| @games = n }
        opts.on('--bot NAME=COMMAND', 'ladder: a bot and its command, without --seed') do |spec|
          name, command = spec.split('=', 2)
          abort "--bot #{spec}: NAME=COMMAND" unless command && name.match?(/\A[A-Za-z0-9_-]+\z/) && !command.empty?
          @bots[name] = command
        end
        opts.on('--pairing A,B', 'ladder: two --bot names') { |spec| @pairings << spec.split(',', -1) }
      end
    end

    def check_ladder_options
      abort '--games must be a positive even number' unless @games&.positive? && @games.even?
      abort 'no --pairing' if @pairings.empty?
      @pairings.each do |pair|
        abort "--pairing #{pair.join(',')}: two --bot names" unless pair.size == 2 && pair.all? { |n| @bots.key?(n) }
      end
    end

    # The arguments that define the games, for the tables' citation: not
    # --out, --budget or --lanes, which change where and how fast only.
    def defining_command
      args = []
      skip = false
      @argv.each do |arg|
        if skip
          skip = false
        elsif %w[--out --budget --lanes].include?(arg)
          skip = true
        elsif !arg.start_with?('--out=', '--budget=', '--lanes=')
          args << arg
        end
      end
      "mise exec -- scripts/calibrate-bots.rb #{args.shelljoin}"
    end

    def seed(*label) = Seeds.gnugo(SEED, *label)

    # 10 seeded random networks and example.ann, each against every
    # ENDINGS_BOTS command, 5 seeds, both colors.
    def endings_schedule
      networks = generate_networks
      games = []
      ENDINGS_BOTS.each_with_index do |bot, b|
        networks.each do |network, path|
          (1..ENDINGS_SEEDS).each do |k|
            %w[B W].each do |bot_color|
              id = format('e%d-%s-s%d-%s', b, network, k, bot_color.downcase)
              command = Seeds.with_bot_seed(bot, seed(id, 'bot'))
              black, white = bot_color == 'B' ? [[:bot, command], [:network, path]] : [[:network, path], [:bot, command]]
              games << game(id, bot, bot_color, black, white)
            end
          end
        end
      end
      games
    end

    def ladder_schedule
      @pairings.flat_map do |a, b|
        (0...@games).map do |k|
          id = format('l-%s-%s-%03d', a, b, k)
          a_command = Seeds.with_bot_seed(@bots[a], seed(id, 'a'))
          b_command = Seeds.with_bot_seed(@bots[b], seed(id, 'b'))
          black, white = k.even? ? [[:bot, a_command], [:bot, b_command]] : [[:bot, b_command], [:bot, a_command]]
          game(id, [a, b], k.even? ? 'B' : 'W', black, white)
        end
      end
    end

    def game(id, group, color, black, white)
      Game.new(id, group, color, black, white, seed(id, 'referee'))
    end

    # { name => path }: example.ann and NETWORKS generation-0 networks, as
    # arena-agreement.sh makes them (the genes do not affect play).
    def generate_networks
      dir = File.join(@out, 'networks')
      unless File.exist?(File.join(dir, format('%04d.ann', NETWORKS)))
        FileUtils.rm_rf(dir)
        FileUtils.mkdir_p(dir)
        generator = File.join(ROOT, 'initial-population/initial-population')
        arguments = [NETWORKS, SIZE, 1, 20, 0.01, 1, 0.5, 0.02, 0.02, 'all', 0.3, 0.01,
                     Seeds.derive(SEED, 'initial-population')].map(&:to_s)
        system(generator, *arguments, chdir: dir, out: File::NULL) or abort "#{generator} #{arguments.join(' ')} failed"
      end
      networks = (1..NETWORKS).to_h { |n| [format('n%02d', n), File.join(dir, format('%04d.ann', n))] }
      networks.merge('example' => File.join(ROOT, 'engine/example.ann'))
    end

    # The schedule, with each network's SHA-256, is stored in DIR on the
    # first run; a later run must have the same one.
    def check_schedule(games)
      schedule = games.map do |g|
        g.to_h.merge(black: side(g.black), white: side(g.white))
      end
      text = JSON.pretty_generate(schedule)
      path = File.join(@out, 'schedule.json')
      if File.exist?(path)
        abort "#{@out} holds another schedule; use a new --out" unless File.read(path) == text
      else
        File.write(path, text)
      end
    end

    def side((kind, value))
      kind == :network ? { network: File.basename(value), sha256: Digest::SHA256.file(value).hexdigest } : { bot: value }
    end

    def result_path(game) = File.join(@out, 'games', "#{game.id}.json")

    def result(game)
      path = result_path(game)
      File.exist?(path) ? JSON.parse(File.read(path), symbolize_names: true) : nil
    end

    def play(games)
      todo = games.reject { |g| File.exist?(result_path(g)) }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      queue = Queue.new
      todo.each { |g| queue << g }
      queue.close
      done = 0
      lock = Mutex.new
      Array.new(@lanes) do
        Thread.new do
          while (game = queue.pop)
            break if @budget && Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > @budget

            record = play_one(game)
            File.write("#{result_path(game)}.tmp", JSON.generate(record))
            File.rename("#{result_path(game)}.tmp", result_path(game))
            lock.synchronize do
              done += 1
              warn "#{game.id}: #{record[:failure] || "#{record[:result]} #{record[:end]}"} (#{done}/#{todo.size})"
            end
          end
        end
      end.each(&:join)
    end

    # One game in its own arena run, then, for a game ended by passes or
    # the move limit in the endings run, the referee's score of its final
    # position.
    def play_one(game)
      prefix = File.join(@out, 'games', game.id)
      File.write("#{prefix}.manifest", manifest(game))
      system(File.join(ROOT, 'engine/arena'), '--mixed', SIZE.to_s, KOMI.to_s, MAX_MOVES.to_s, MAIN_TIME.to_s,
             DEADLINE.to_s, GRACE.to_s, "#{prefix}.manifest",
             chdir: File.join(@out, 'work'), in: File::NULL, out: "#{prefix}.out", err: "#{prefix}.err")
      record = CalibrateBots.parse_arena(File.read("#{prefix}.out"), game.id)
      return record if record[:failure] || @mode != 'endings' || record[:end] == 'resign'

      File.write("#{prefix}.sgf", CalibrateBots.sgf(record[:moves], SIZE, KOMI))
      record.merge(referee: referee(game, "#{prefix}.sgf"))
    end

    def manifest(game)
      lines = []
      { 'black' => game.black, 'white' => game.white }.each do |color, (kind, value)|
        lines << (kind == :network ? "network\t#{color}\t#{value}" : "bot\t#{color}")
      end
      lines << "game\t#{game.id}\tblack\twhite"
      { 'black' => game.black, 'white' => game.white }.each do |color, (kind, value)|
        lines << "command\t#{game.id}\t#{color}\t#{value}" if kind == :bot
      end
      lines.map { |l| "#{l}\n" }.join
    end

    # The seeded referee's final_score of the SGF's final position, as
    # twogtp asks it at the end of a benchmark game.
    def referee(game, sgf)
      script = "boardsize #{SIZE}\nclear_board\nloadsgf #{sgf}\nkomi #{KOMI}\nfinal_score\nquit\n"
      answers = IO.popen([*GameResult::REFEREE.split, '--seed', game.referee_seed.to_s], 'r+', err: File::NULL) do |io|
        io.write(script)
        io.close_write
        io.read
      end.split(/\n\n+/).map(&:strip)
      score = answers[4].to_s
      abort "the referee could not score #{sgf}: #{answers.inspect}" unless score.match?(/\A= ([BW]\+[\d.]+|0)\z/)

      score.delete_prefix('= ')
    end

    def endings_report(games, results)
      puts "Endings: #{NETWORKS} random generation-0 networks and example.ann, #{ENDINGS_SEEDS} seeds, both colors;"
      puts "#{SIZE}x#{SIZE}, komi #{KOMI}, max_moves #{MAX_MOVES}, main time #{MAIN_TIME} s, deadlines #{DEADLINE}/#{GRACE} s."
      puts 'Winner changes: games ended by two passes whose Tromp-Taylor winner differs from the referee\'s ' \
           '(to bot / to network: whom the arena\'s count favours).'
      puts
      puts '| Bot command | Games | Passes | Winner changes | to bot / to network | Margin only | Resigned (by bot) ' \
           '| Move limit (winner changed) | Time | Failures |'
      puts '| --- | ---: | ---: | ---: | --- | ---: | --- | --- | ---: | ---: |'
      games.group_by(&:group).each do |bot, group|
        row = CalibrateBots.endings_row(group.map do |g|
          results.fetch(g.id).merge(bot_color: g.color)
        end)
        puts "| `#{bot}` | #{row[:games]} | #{row[:passes]} | #{row[:changed]} | #{row[:to_bot]} / #{row[:to_network]} " \
             "| #{row[:margin_only]} | #{row[:resigned]} (#{row[:bot_resigned]}) | #{row[:limit]} (#{row[:limit_changed]}) " \
             "| #{row[:time]} | #{row[:failures]} |"
      end
      failures(games, results)
    end

    def ladder_report(games, results)
      puts "Ladder: #{@games} games per pairing, half with each color; #{SIZE}x#{SIZE}, komi #{KOMI}, " \
           "max_moves #{MAX_MOVES}, main time #{MAIN_TIME} s, deadlines #{DEADLINE}/#{GRACE} s, Tromp-Taylor."
      @bots.each { |name, command| puts "  #{name}: `#{command}`" }
      puts
      puts '| A | B | Games | A wins | B wins | Draws | A win rate (95 %) | A resigned | B resigned | Move limit | Failures |'
      puts '| --- | --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: |'
      games.group_by(&:group).each do |(a, b), group|
        row = CalibrateBots.ladder_row(group.map do |g|
          results.fetch(g.id).merge(a_color: g.color)
        end)
        counted = row[:games] - row[:failures]
        low, high = CalibrateBots.wilson(row[:a_wins], counted)
        rate = low ? format('%.0f %% (%.0f–%.0f %%)', 100.0 * row[:a_wins] / counted, 100 * low, 100 * high) : '–'
        puts "| #{a} | #{b} | #{row[:games]} | #{row[:a_wins]} | #{row[:b_wins]} | #{row[:draws]} | #{rate} " \
             "| #{row[:a_resigned]} | #{row[:b_resigned]} | #{row[:limit]} | #{row[:failures]} |"
      end
      failures(games, results)
    end

    def failures(games, results)
      failed = games.select { |g| results.fetch(g.id)[:failure] }
      return if failed.empty?

      puts
      puts 'Failures:'
      failed.each { |g| puts "  #{g.id}: #{results.fetch(g.id)[:failure]} (#{g.black.last} / #{g.white.last})" }
    end
  end
end

exit CalibrateBots::Run.new(ARGV).call if $PROGRAM_NAME == __FILE__
