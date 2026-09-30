require 'fileutils'
require_relative 'game_result'
require_relative 'openings'
require_relative 'progress_line'
require_relative 'seeds'
require_relative 'worker_pool'

# Measures progress apart from evolution. A tournament score only compares
# networks of one generation, so at checkpoint generations the generation's
# top network also plays a fixed panel (see migration 008). Every opening is
# played once with each color, and the openings are the same at every
# checkpoint, so checkpoints can be compared. The panel's bots also play
# each other (migration 016), once per experiment: each checkpoint plays
# those still missing along with its own games.
class CheckpointBenchmark
  include ProgressLine

  # Inside the generation's work directory, which twogtp runs in, so the
  # engine is ../evo as in the tournament.
  DIRECTORY = 'benchmark'.freeze

  # `network` is "generation:name" for the network kinds and nil for a bot.
  Opponent = Data.define(:name, :command, :network) do
    def bot? = network.nil?
  end

  # `color` is the benchmarked network's.
  Game = Data.define(:opponent, :opening, :color) do
    def prefix = File.join(DIRECTORY, "#{opponent.name}-#{opening}-#{color}")
  end

  # A game between two panel bots (Opponents). Its prefix ends in the
  # opening's number, a champion game's in a color, so the two never clash.
  BotGame = Data.define(:black, :white, :opening) do
    def prefix = File.join(DIRECTORY, "#{black.name}-#{white.name}-#{opening}")
    def key = [black.name, white.name, opening]
  end

  # What the checkpoint `generation` plays, from the benchmark panel
  # (ExperimentDatabase#benchmark_opponents), in panel order: a Hash per
  # opponent with its :name, :kind, :command, and :source, the generation
  # a network opponent comes from (nil for a bot). Generation 0 has no
  # earlier network to play. The `past_champions` row stands for the top
  # networks of the last `champions` checkpoints before this one, oldest
  # first, each named by champion_name; generation 0's is left out, since
  # `initial_champion` always plays it. ExperimentStats uses this to tell a
  # complete benchmark.
  def self.opponents_for(generation, panel, keep_every:, champions:)
    panel.flat_map do |row|
      case row[:kind]
      when 'bot' then [row.merge(source: nil)]
      when 'initial_champion' then generation.positive? ? [row.merge(source: 0)] : []
      when 'past_champions'
        past_champions(generation, keep_every, champions).map { |source| row.merge(name: champion_name(source), source:) }
      else raise ArgumentError, "unknown benchmark opponent kind #{row[:kind]}"
      end
    end
  end

  # The checkpoints before `generation` whose top networks it plays as past
  # champions, oldest first.
  def self.past_champions(generation, keep_every, champions)
    (1..champions).map { |back| generation - (back * keep_every) }.select(&:positive?).reverse
  end

  def self.champion_name(source) = "Gen#{source}Champion"

  def self.call(generation, settings, pool, store)
    new(generation, settings, pool, store).call
  end

  # `generation` is an Integer; the other arguments are RunGeneration's.
  def initialize(generation, settings, pool, store)
    @generation = generation
    @settings = settings
    @pool = pool
    @store = store
  end

  # Plays the games not yet in the database, so a resumed benchmark only
  # plays what is missing: the checkpoint's own games, and the bot games no
  # checkpoint has stored yet, in one pool. Returns whether it played any
  # game.
  def call
    FileUtils.mkdir_p(DIRECTORY)
    played = store.benchmark_games(generation).to_set { |row| row.values_at(:opponent, :opening, :network_color) }
    all = games
    pending = all.reject { |game| played.include?([game.opponent.name, game.opening, game.color]) }
    stored_bot_games = store.benchmark_bot_games(columns: %i[black white opening]).to_set(&:values)
    pending += bot_games.reject { |game| stored_bot_games.include?(game.key) }
    return false if pending.empty?

    # The checkpoint's games and the bot games still missing when it starts;
    # bot games an earlier checkpoint stored do not count.
    done = all.size - pending.count { |game| game.is_a?(Game) }
    total = done + pending.size
    # Until the first game is in, the line shows the benchmark starting.
    show("Benchmark: starting #{pending.size} games ...")
    pending.each { |game| pool.submit(command(game), game) }
    pending.size.times do |i|
      game, duration, status = pool.next_finished
      # As in the tournament: a game killed by Ctrl-C stays unscored and is
      # replayed on resume, also when it is back before the trap has run.
      exit if $stop_now
      WorkerPool.exit_interrupted("benchmark game #{game.prefix}", 'it stays pending') if WorkerPool.interrupted?(status)
      game.is_a?(BotGame) ? store_bot_game(game, duration) : store_game(game, duration)
      show("Benchmark ... Game: #{done + i + 1}/#{total}")
    end
    end_line('Benchmark ... done')
    true
  end

  private

  attr_reader :generation, :settings, :pool, :store

  def games
    openings = settings['benchmark_games'] / 2
    opponents.product((0...openings).to_a, %w[black white]).map do |opponent, opening, color|
      Game.new(opponent:, opening:, color:)
    end
  end

  def opponents
    rows = self.class.opponents_for(generation, store.benchmark_opponents,
                                    keep_every: settings['keep_every'], champions: settings['benchmark_champions'])
    rows.map do |row|
      next bot(row) if row[:kind] == 'bot'

      network_opponent(row[:name], row[:source])
    end
  end

  def bot(row) = Opponent.new(name: row[:name], command: row[:command], network: nil)

  # Every pair of the panel's bots, a before b in panel order, and for each
  # opening a game with each of them as Black.
  def bot_games
    bots = store.benchmark_opponents.select { |row| row[:kind] == 'bot' }.map { |row| bot(row) }
    openings = settings['benchmark_bot_games'] / 2
    bots.combination(2).flat_map do |a, b|
      (0...openings).flat_map do |opening|
        [BotGame.new(black: a, white: b, opening:), BotGame.new(black: b, white: a, opening:)]
      end
    end
  end

  def network_opponent(name, source)
    Opponent.new(name:, command: "../evo #{export(source)}", network: "#{source}:#{top_network(source)}")
  end

  # The first network of the generation's final ranking; bots are ranked too.
  def top_network(source)
    (@top_networks ||= {})[source] ||= begin
      entry = store.ranking(source).find { |row| !row[:external] }
      raise "generation #{source} has no ranked network to benchmark" unless entry

      entry[:name]
    end
  end

  # Both generations name their networks 0.ann, 1.ann, and so on, so the
  # file name carries the generation.
  def export(source)
    name = top_network(source)
    path = File.join(DIRECTORY, "#{source}-#{name}")
    store.export_network(source, name, path) or raise "generation #{source} has no stored network #{name}"
  end

  def network_command
    @network_command ||= "../evo #{export(generation)}"
  end

  def command(game)
    return bot_game_command(game) if game.is_a?(BotGame)

    # GNU Go, as the referee and as a bot, and michi play at random unless
    # seeded; the referee and the bot share the game's seed.
    seed = Seeds.gnugo(settings.fetch('seed'), 'benchmark', generation, game.opponent.name, game.opening, game.color)
    opponent = Seeds.with_bot_seed(game.opponent.command, seed)
    black, white = game.color == 'black' ? [network_command, opponent] : [opponent, network_command]
    twogtp(black, white, seed, game)
  end

  # The seed has no generation in it, so a bot game is the same whichever
  # checkpoint plays it; both bots and the referee share it.
  def bot_game_command(game)
    seed = Seeds.gnugo(settings.fetch('seed'), 'benchmark-bots', game.black.name, game.white.name, game.opening)
    twogtp(Seeds.with_bot_seed(game.black.command, seed), Seeds.with_bot_seed(game.white.command, seed), seed, game)
  end

  def twogtp(black, white, seed, game)
    moves = opening_moves(game.opening)
    # twogtp counts the opening's stones toward -maxmoves.
    maxmoves = settings['max_moves'] + moves.size
    openings = moves.empty? ? '' : " -openings #{opening_directory(game.opening, moves)}"
    prefix = game.prefix
    %(gogui-twogtp -black "#{black}" -white "#{white}" -referee "#{GameResult::REFEREE} --seed #{seed}" ) +
      %(-size #{settings['board_size']} -komi #{settings.fetch('komi')} -auto -games 1 -sgffile #{prefix} ) +
      %(-time #{settings['game_seconds']}s ) +
      %(-force -maxmoves #{maxmoves}#{openings} 2> #{prefix}.err)
  end

  def opening_moves(index)
    (@opening_moves ||= {})[index] ||=
      Openings.moves(settings.fetch('seed'), index, settings['board_size'], settings['benchmark_opening_moves'])
  end

  def opening_directory(index, moves)
    Openings.write(File.join(DIRECTORY, 'openings', index.to_s), settings['board_size'], moves)
  end

  # The tournament's rules, from the benchmarked network's side: the
  # referee decides, a crashed network loses, and a crashed bot, like any
  # game without a usable result, is a failure with no winner.
  def score(game, result)
    return { winner: nil, failure: result.failure } if result.failure
    return { winner: nil, failure: nil } unless result.winner

    network_won = (result.winner == :black) == (game.color == 'black')
    # A bot crashing says nothing about the network that played it.
    return { winner: nil, failure: "#{game.opponent.name} crashed" } if network_won && result.crashed? && game.opponent.bot?

    { winner: network_won ? 'network' : 'opponent', failure: nil }
  end

  # Both players are bots, so a crash says nothing about either: like any
  # game without a usable result, it is a failure with no winner.
  def score_bot_game(game, result)
    return { winner: nil, failure: result.failure } if result.failure
    return { winner: nil, failure: nil } unless result.winner

    loser = result.winner == :black ? game.white : game.black
    return { winner: nil, failure: "#{loser.name} crashed" } if result.crashed?

    { winner: result.winner.to_s, failure: nil }
  end

  # Writes the game's row, then deletes the files twogtp left. After a crash
  # between the two, the row is stored, so a resume skips the game, and the
  # files left behind go when work/ is emptied.
  def store_game(game, duration)
    prefix = game.prefix
    result = GameResult.read(prefix)
    scored = score(game, result)
    err_file = "#{prefix}.err"
    store.record_benchmark_game(
      generation:, opponent: game.opponent.name, opening: game.opening, network_color: game.color,
      network: top_network(generation), opponent_network: game.opponent.network, **scored,
      length: result.length, referee_result: result.referee, error_message: result.error_message,
      stderr: File.exist?(err_file) ? File.read(err_file) : nil,
      duration:, time_black: result.time_black, time_white: result.time_white
    )
    warn "\n#{prefix}: #{scored[:failure]}" if scored[:failure]
    FileUtils.rm_f(["#{prefix}.dat", "#{prefix}-0.sgf", err_file])
  end

  # As store_game, for a bot game.
  def store_bot_game(game, duration)
    prefix = game.prefix
    result = GameResult.read(prefix)
    scored = score_bot_game(game, result)
    err_file = "#{prefix}.err"
    store.record_benchmark_bot_game(
      generation:, black: game.black.name, white: game.white.name, opening: game.opening, **scored,
      length: result.length, referee_result: result.referee, error_message: result.error_message,
      stderr: File.exist?(err_file) ? File.read(err_file) : nil,
      duration:, time_black: result.time_black, time_white: result.time_white
    )
    warn "\n#{prefix}: #{scored[:failure]}" if scored[:failure]
    FileUtils.rm_f(["#{prefix}.dat", "#{prefix}-0.sgf", err_file])
  end
end
