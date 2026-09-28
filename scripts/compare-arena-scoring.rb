#!/usr/bin/env ruby
# Plays the same seeded tournament-style games through `arena --mixed` and
# through gogui-twogtp with the runner's flags and GNU Go referee, checks
# that both play identical moves, and, for each finished game, compares the
# arena's Tromp–Taylor result with the referee's on the same moves: how
# often the winner changes, by how much the margin moves, and why (from
# GNU Go's dead and seki stones in the final position).
#
#   mise exec -- scripts/compare-arena-scoring.rb [--lanes N] [--small] [--keep]
#
# The networks are the kept champions of experiments/bigrun and
# experiments/even-bigger at several generations and a few random
# generation-0 networks of each, exported from their databases opened
# read-only. They play Brown, AmiGo and GNU Go level 0 with both colors
# and each other; the bots play each other. GNU Go, as a player and as the
# referee, gets a seed per game, as the runner gives it.
#
# --lanes N  games at a time, for the arena and for twogtp (default 6).
# --small    a few games only, to try the script; its numbers mean nothing.
# --keep     keep the scratch directory (networks, manifests, twogtp files,
#            and games.tsv with one row per game).
#
# Exits 1 when a game's moves or end differ between the arena and twogtp,
# when the arena writes a failure record, when twogtp reports an error
# other than the move limit, or when the arena's result differs from a
# Tromp–Taylor recount of twogtp's final position. Winner differences are
# the measurement, not a failure. docs/experiment-reference.md records a
# run.
require 'bundler/setup'
require 'fileutils'
require 'optparse'
require 'tmpdir'
require_relative '../ruby/experiment_database'
require_relative '../ruby/game_result'
require_relative '../ruby/seeds'

module CompareArenaScoring
  ROOT = File.expand_path('..', __dir__)
  LETTERS = 'ABCDEFGHJKLMNOPQRSTUVWXYZ'.freeze
  SGF_LETTERS = 'abcdefghijklmnopqrstuvwxyz'.freeze
  SIZE = 9
  KOMI = 6.5
  MAX_MOVES = 200
  # Minutes, as the runner passes game_length to twogtp's -time; the arena
  # gets it in seconds, with the runner's 10 s deadline and grace.
  GAME_LENGTH = 10
  DEADLINE = 10
  BOTS = { 'Brown' => 'brown', 'AmiGo' => 'amigogtp', 'GNUGo' => 'gnugo --level 0 --mode gtp' }.freeze
  # [experiment, kept generations whose champion plays]; both experiments
  # are 9x9 with the same feature groups, so their networks can meet.
  EXPERIMENTS = [
    ['bigrun', [0, 500, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 4500, 5000, 5500, 5750]],
    ['even-bigger', [0, 100, 200, 300]]
  ].freeze
  RANDOM_NETWORKS = 4
  NETWORK_PAIRS = 40
  SEED = 'compare-arena-scoring'.freeze

  class ArenaFailed < StandardError; end

  PLAYED = /\A([^\t]+)\tresult=([^\t]+)\tend=(passes|limit|resign|time)\tlength=(\d+)\t
            time_black=[\d.]+\ttime_white=[\d.]+\tduration=[\d.]+\tmoves=([^\t]*)\tok\z/x

  # The moves of an SGF game as the arena writes them: uppercase GTP
  # vertices (no I, rows counted from the bottom) and "pass" for an empty
  # move or tt. Only move nodes count, not comments.
  def self.sgf_moves(sgf, size)
    sgf.scan(/;([BW])\[([a-z]{2})?\]/).map do |_color, point|
      next 'pass' if point.nil? || point == 'tt'

      x = SGF_LETTERS.index(point[0])
      y = SGF_LETTERS.index(point[1])
      "#{LETTERS[x]}#{size - y}"
    end
  end

  # The Tromp–Taylor result of a position, as the arena scores it: each
  # color's stones plus the empty regions that touch only that color,
  # black minus white minus komi. Stones in `dead` are taken off first.
  def self.tromp_taylor(size, komi, black, white, dead: [])
    board = {}
    black.each { |v| board[point(v)] = :b }
    white.each { |v| board[point(v)] = :w }
    dead.each { |v| board.delete(point(v)) }
    score = { b: 0, w: 0 }
    board.each_value { |color| score[color] += 1 }
    seen = {}
    (1..size).each do |x|
      (1..size).each do |y|
        next if board.key?([x, y]) || seen.key?([x, y])

        points, borders = flood(size, board, seen, [x, y])
        score[borders.first] += points if borders.size == 1
      end
    end
    format_margin(score[:b] - score[:w] - komi)
  end

  def self.point(vertex)
    [LETTERS.index(vertex[0].upcase) + 1, Integer(vertex[1..], 10)]
  end

  def self.flood(size, board, seen, start)
    stack = [start]
    seen[start] = true
    points = 0
    borders = []
    until stack.empty?
      x, y = stack.pop
      points += 1
      [[x + 1, y], [x - 1, y], [x, y + 1], [x, y - 1]].each do |n|
        next unless n.all? { |c| c.between?(1, size) }

        if board.key?(n)
          borders |= [board[n]]
        elsif !seen.key?(n)
          seen[n] = true
          stack << n
        end
      end
    end
    [points, borders]
  end

  def self.format_margin(margin)
    return '0' if margin.zero?

    format('%<side>s+%<points>.1f', side: margin.positive? ? 'B' : 'W', points: margin.abs)
  end

  # Black's margin of a counted result; nil for a resignation or time loss.
  def self.margin(result)
    return 0.0 if result == '0'
    return nil unless result =~ /\A([BW])\+(\d+(?:\.\d+)?)\z/

    Regexp.last_match(1) == 'B' ? Float(Regexp.last_match(2)) : -Float(Regexp.last_match(2))
  end

  def self.winner(result)
    result[0] == '0' ? '0' : result[0]
  end

  # How twogtp's game ended, in the arena's terms.
  def self.twogtp_end(result)
    return 'resign' if result.referee.to_s.end_with?('+R')
    return 'limit' if result.error_message == GameResult::MOVE_LIMIT

    'passes'
  end

  # The arena's played records by game ID. Any failure record, missing
  # game, or missing trailer raises ArenaFailed: the comparison needs every
  # game played.
  def self.parse_arena(text, ids)
    lines = text.split("\n")
    raise ArenaFailed, "no header: #{lines.first}" unless lines.first == 'arena protocol 3 ready'
    raise ArenaFailed, "no trailer: #{lines.last}" unless lines.last == "done #{ids.size}"

    games = lines[1...-1].to_h do |line|
      m = PLAYED.match(line) or raise ArenaFailed, "not a played game: #{line}"
      [m[1], { result: m[2], end: m[3], moves: m[5].split(',') }]
    end
    raise ArenaFailed, "the games are not the scheduled ones: #{games.keys - ids}" unless games.keys.sort == ids.sort

    games
  end

  # A result after the empty points that touch both colors (GNU Go's
  # dame) are filled in turn, starting with the side to move: with an odd
  # number of them, that side gets one more. GNU Go's Chinese-rules
  # final_score counts so; Tromp-Taylor leaves them to neither.
  def self.fill_dame(result, dame, to_move)
    return result if dame.even?

    format_margin(margin(result) + (to_move == 'black' ? 1 : -1))
  end

  # Why the referee's result differs from the arena's, if it does.
  # without_dead is the Tromp-Taylor result with GNU Go's dead stones taken
  # off, filled that result after fill_dame.
  #   :same          it does not
  #   :resign        a resignation, which both report alike
  #   :move_limit    the game stopped at the move limit, so GNU Go judged
  #                  an unfinished position
  #   :dame          no dead stones; filling the dame gives the referee's
  #                  result
  #   :dead_stones   taking GNU Go's dead stones off gives it
  #   :dead_stones_and_dame  taking them off and filling the dame gives it
  #   :seki, :judgement, :dead_stones_and_judgement  none of that gives it
  #                  (with stones in seki; or not): GNU Go judged some
  #                  region otherwise
  def self.cause(end:, dead:, seki:, arena:, referee:, without_dead:, filled:)
    return :resign if binding.local_variable_get(:end) == 'resign'
    return :same if arena == referee
    return :move_limit if binding.local_variable_get(:end) == 'limit'

    if dead.empty?
      return :dame if filled == referee

      return seki.empty? ? :judgement : :seki
    end
    return :dead_stones if without_dead == referee

    filled == referee ? :dead_stones_and_dame : :dead_stones_and_judgement
  end

  # Plays the games and reports.
  class Run
    Game = Struct.new(:id, :kind, :black, :white, :seed)

    def initialize(argv)
      @lanes = 6
      @small = false
      @keep = false
      OptionParser.new do |opts|
        opts.banner = 'Usage: scripts/compare-arena-scoring.rb [--lanes N] [--small] [--keep]'
        opts.on('--lanes N', Integer, 'games at a time (default 6)') { |n| @lanes = n }
        opts.on('--small', 'a few games only, to try the script') { @small = true }
        opts.on('--keep', 'keep the scratch directory') { @keep = true }
      end.parse!(argv)
      raise OptionParser::InvalidArgument, "--lanes #{@lanes}" unless @lanes.positive?
    end

    def call
      %w[engine/arena engine/evo].each do |program|
        abort "build #{program} first (mise run build)" unless File.executable?(File.join(ROOT, program))
      end
      @scratch = Dir.mktmpdir('evo-compare-arena-scoring-', ENV.fetch('TMPDIR', '/tmp'))
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      networks = export_networks
      games = schedule(networks)
      puts "#{networks.size} networks, #{games.size} games, #{@lanes} at a time"
      arena = play_arena(networks, games)
      rows = play_twogtp(networks, games, arena)
      write_tsv(rows)
      report(rows)
      printf("%.0f s\n", Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      @problems.empty? ? 0 : 1
    rescue ArenaFailed => e
      warn "the arena did not play every game: #{e.message}"
      1
    ensure
      if @scratch && @keep
        puts "kept #{@scratch}"
      elsif @scratch
        FileUtils.rm_rf(@scratch)
      end
    end

    private

    # { player ID => .ann path }: each kept generation's champion (its first
    # network by rank, as the benchmark picks it) and a few random
    # generation-0 networks, read from the databases without writing.
    def export_networks
      dir = File.join(@scratch, 'networks')
      FileUtils.mkdir_p(dir)
      rng = Random.new(1)
      EXPERIMENTS.each_with_object({}) do |(name, generations), networks|
        path = File.join(ROOT, 'experiments', name, 'experiment.sqlite3')
        abort "#{path} not found" unless File.exist?(path)
        store = ExperimentDatabase.new(path, readonly: true)
        generations = generations.values_at(0, -1) if @small
        champions = generations.map do |generation|
          champion = store.ranking(generation).find { |row| !row[:external] } or
            abort "#{name} generation #{generation} has no ranked network"
          [generation, champion[:name]]
        end
        random = (store.network_names(0) - [champions.first.last]).sample(@small ? 1 : RANDOM_NETWORKS, random: rng)
        (champions + random.map { |n| [0, n] }).each do |generation, network|
          id = "#{name}-#{generation}-#{File.basename(network, '.ann')}"
          file = File.join(dir, "#{id}.ann")
          store.export_network(generation, network, file) or abort "#{id} has no stored network"
          networks[id] = file
        end
      ensure
        store&.close
      end
    end

    def schedule(networks)
      rng = Random.new(2)
      games = []
      add = ->(kind, black, white) { games << Game.new(format('g%03d', games.size), kind, black, white) }
      networks.each_key do |net|
        BOTS.each_key do |bot|
          add.call("network-#{bot}", net, bot)
          add.call("network-#{bot}", bot, net)
        end
      end
      BOTS.each_key do |black|
        BOTS.each_key do |white|
          # Brown and AmiGo play deterministically; only GNU Go's seed
          # gives another game.
          (black == 'GNUGo' || white == 'GNUGo' ? (@small ? 1 : 3) : 1).times { add.call('bot-bot', black, white) }
        end
      end
      networks.keys.combination(2).to_a.sample(@small ? 2 : NETWORK_PAIRS, random: rng).each do |a, b|
        add.call('network-network', a, b)
        add.call('network-network', b, a)
      end
      games.each { |g| g.seed = Seeds.gnugo(SEED, g.id) }
    end

    def command(player, seed)
      Seeds.with_gnugo_seed(BOTS.fetch(player), seed)
    end

    # The games in @lanes arena --mixed chunks at once, dealt round-robin.
    def play_arena(networks, games)
      chunks = games.group_by.with_index { |_, i| i % @lanes }.values
      results = {}
      chunks.each_with_index.map do |chunk, n|
        Thread.new do
          manifest = File.join(@scratch, "chunk-#{n}.manifest")
          File.write(manifest, manifest_text(networks, chunk))
          out = File.join(@scratch, "chunk-#{n}.out")
          err = File.join(@scratch, "chunk-#{n}.err")
          system(File.join(ROOT, 'engine/arena'), '--mixed', SIZE.to_s, KOMI.to_s, MAX_MOVES.to_s,
                 (GAME_LENGTH * 60).to_s, DEADLINE.to_s, DEADLINE.to_s, manifest, out:, err:)
          [chunk, out, err]
        end
      end.each do |thread|
        chunk, out, err = thread.value
        begin
          results.merge!(CompareArenaScoring.parse_arena(File.read(out), chunk.map(&:id)))
        rescue ArenaFailed => e
          raise ArenaFailed, "#{e.message}\n#{File.read(err)}"
        end
      end
      results
    end

    def manifest_text(networks, chunk)
      players = chunk.flat_map { |g| [g.black, g.white] }.uniq
      lines = players.map { |p| networks.key?(p) ? "network\t#{p}\t#{networks[p]}" : "bot\t#{p}" }
      chunk.each do |g|
        lines << "game\t#{g.id}\t#{g.black}\t#{g.white}"
        { 'black' => g.black, 'white' => g.white }.each do |color, player|
          lines << "command\t#{g.id}\t#{color}\t#{command(player, g.seed)}" unless networks.key?(player)
        end
      end
      lines.map { |l| "#{l}\n" }.join
    end

    # Every game through twogtp, as the tournament ran it before rules 3,
    # then compared with the arena's record.
    def play_twogtp(networks, games, arena)
      dir = File.join(@scratch, 'twogtp')
      FileUtils.mkdir_p(dir)
      queue = Queue.new
      games.each { |g| queue << g }
      queue.close
      rows = Queue.new
      Array.new(@lanes) do
        Thread.new do
          while (game = queue.pop)
            rows << compare(game, networks, arena.fetch(game.id), dir)
          end
        end
      end.each(&:join)
      rows.close
      Array.new(rows.size) { rows.pop }.sort_by { |r| r[:game].id }
    end

    def player_command(player, networks, seed)
      networks.key?(player) ? "#{File.join(ROOT, 'engine/evo')} #{networks[player]}" : command(player, seed)
    end

    def compare(game, networks, arena, dir)
      prefix = File.join(dir, game.id)
      system('gogui-twogtp', '-black', player_command(game.black, networks, game.seed),
             '-white', player_command(game.white, networks, game.seed),
             '-referee', "#{GameResult::REFEREE} --seed #{game.seed}",
             '-size', SIZE.to_s, '-komi', KOMI.to_s, '-auto', '-games', '1', '-sgffile', prefix,
             '-time', GAME_LENGTH.to_s, '-force', '-maxmoves', MAX_MOVES.to_s,
             chdir: dir, in: File::NULL, out: File::NULL, err: "#{prefix}.err")
      twogtp = GameResult.read(prefix)
      row = { game:, arena: arena[:result], end: arena[:end], length: arena[:moves].size, referee: twogtp.referee }
      return row.merge(problem: "twogtp: #{twogtp.failure}") if twogtp.failure || twogtp.crashed?

      sgf = File.read("#{prefix}-0.sgf")
      moves = CompareArenaScoring.sgf_moves(sgf, SIZE)
      twogtp_end = CompareArenaScoring.twogtp_end(twogtp)
      if moves != arena[:moves] || twogtp_end != arena[:end]
        return row.merge(problem: "moves differ: arena #{arena[:end]} #{arena[:moves].join(',')} / " \
                                  "twogtp #{twogtp_end} #{moves.join(',')}")
      end
      return row.merge(dead: [], seki: [], cause: :resign) if arena[:end] == 'resign'

      final_position(row, game, "#{prefix}-0.sgf")
    end

    # Loads twogtp's game into GNU Go (the game's seeded referee) for the
    # final stones, the side to move, and GNU Go's dead, seki and dame
    # points.
    def final_position(row, game, sgf)
      script = "boardsize #{SIZE}\nloadsgf #{sgf}\nlist_stones black\nlist_stones white\n" \
               "final_status_list dead\nfinal_status_list seki\nfinal_status_list dame\nquit\n"
      answers = IO.popen([*GameResult::REFEREE.split, '--seed', game.seed.to_s], 'r+', err: File::NULL) do |io|
        io.write(script)
        io.close_write
        io.read
      end.split(/\n\n+/).map(&:strip)
      if answers.size != 8 || answers.any? { |a| a.start_with?('?') }
        return row.merge(problem: "GNU Go could not list the final position: #{answers.inspect}")
      end

      to_move = answers[1].delete_prefix('=').strip
      black, white, dead, seki, dame = answers[2..6].map { |a| a.delete_prefix('=').split }
      recount = CompareArenaScoring.tromp_taylor(SIZE, KOMI, black, white)
      return row.merge(problem: "the arena scored #{row[:arena]}, a recount gives #{recount}") if recount != row[:arena]

      without_dead = CompareArenaScoring.tromp_taylor(SIZE, KOMI, black, white, dead:)
      filled = CompareArenaScoring.fill_dame(without_dead, dame.size, to_move)
      row.merge(dead:, dead_black: (dead & black).size, dead_white: (dead & white).size, seki:, dame: dame.size,
                to_move:, without_dead:, filled:,
                cause: CompareArenaScoring.cause(end: row[:end], dead:, seki:, arena: row[:arena],
                                                 referee: row[:referee], without_dead:, filled:))
    end

    def write_tsv(rows)
      File.open(File.join(@scratch, 'games.tsv'), 'w') do |f|
        f.puts %w[game kind black white seed end length arena referee without_dead filled dead_black dead_white
                  seki dame to_move cause problem].join("\t")
        rows.each do |r|
          g = r[:game]
          f.puts [g.id, g.kind, g.black, g.white, g.seed, r[:end], r[:length], r[:arena], r[:referee],
                  r[:without_dead], r[:filled], r[:dead_black], r[:dead_white], r[:seki]&.size, r[:dame], r[:to_move],
                  r[:cause], r[:problem]].join("\t")
        end
      end
    end

    def report(rows)
      @problems = rows.select { |r| r[:problem] }
      @problems.each { |r| warn "#{r[:game].id} #{r[:game].black} vs #{r[:game].white}: #{r[:problem]}" }
      compared = rows.reject { |r| r[:problem] }
      puts "#{rows.size - @problems.size} of #{rows.size} games with identical moves and end in both"
      puts
      puts format('%-18s %5s %6s %5s %6s %6s %6s %7s %7s', 'pairing', 'games', 'passes', 'limit', 'resign',
                  'same', 'margin', 'winner', 'mean |d|')
      compared.group_by { |r| r[:game].kind }.sort.each { |kind, group| summary_line(kind, group) }
      summary_line('all', compared)
      puts
      causes(compared)
      winner_changes(compared)
    end

    def summary_line(kind, group)
      counted = group.reject { |r| r[:end] == 'resign' }
      diffs = counted.map { |r| (CompareArenaScoring.margin(r[:referee]) - CompareArenaScoring.margin(r[:arena])).abs }
      same = group.count { |r| r[:cause] == :same || r[:cause] == :resign }
      changed = group.count { |r| CompareArenaScoring.winner(r[:arena]) != CompareArenaScoring.winner(r[:referee]) }
      puts format('%-18s %5d %6d %5d %6d %6d %6d %7d %7.1f', kind, group.size,
                  group.count { |r| r[:end] == 'passes' }, group.count { |r| r[:end] == 'limit' },
                  group.count { |r| r[:end] == 'resign' }, same, group.size - same - changed, changed,
                  diffs.empty? ? 0 : diffs.sum / diffs.size)
    end

    def causes(compared)
      puts 'Why the referee differs (games; of them, winner changed):'
      compared.reject { |r| %i[same resign].include?(r[:cause]) }.group_by { |r| r[:cause] }.sort.each do |cause, group|
        changed = group.count { |r| CompareArenaScoring.winner(r[:arena]) != CompareArenaScoring.winner(r[:referee]) }
        dead = group.sum { |r| r[:dead].size }
        puts format('  %-26s %4d  %4d   (%d dead stones in all)', cause, group.size, changed, dead)
      end
      puts
    end

    def winner_changes(compared)
      changes = compared.select { |r| CompareArenaScoring.winner(r[:arena]) != CompareArenaScoring.winner(r[:referee]) }
      puts "Winner changes (#{changes.size}):"
      # In a game between a network and a bot, who the arena's count makes
      # the winner instead of the referee's.
      gainers = changes.filter_map do |r|
        g = r[:game]
        next unless g.kind.start_with?('network-') && g.kind != 'network-network'

        winner = CompareArenaScoring.winner(r[:arena]) == 'B' ? g.black : g.white
        BOTS.key?(winner) ? 'the bot' : 'the network'
      end.tally
      puts "  network against bot: the arena's count gives the win to #{gainers.map { |k, v| "#{k} #{v}" }.join(', ')}" \
        unless gainers.empty?
      changes.each do |r|
        g = r[:game]
        puts format('  %s %-15s %s vs %s: %s, %d moves, arena %s, referee %s, ' \
                    'without dead %s, dead B%d W%d, %s',
                    g.id, g.kind, g.black, g.white, r[:end], r[:length], r[:arena], r[:referee], r[:without_dead],
                    r[:dead_black].to_i, r[:dead_white].to_i, r[:cause])
      end
    end
  end
end

exit CompareArenaScoring::Run.new(ARGV).call if $PROGRAM_NAME == __FILE__
