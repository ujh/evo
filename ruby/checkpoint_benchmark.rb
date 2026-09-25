require 'fileutils'
require_relative 'game_result'
require_relative 'openings'
require_relative 'seeds'

# Measures progress apart from evolution. A tournament score only compares
# networks of one generation, so at checkpoint generations the generation's
# top network also plays a fixed panel (see migration 008). Every opening is
# played once with each color, and the openings are the same at every
# checkpoint, so checkpoints can be compared.
class CheckpointBenchmark
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

  # The rows of the benchmark panel (ExperimentDatabase#benchmark_opponents)
  # that the checkpoint `generation` plays, in panel order. Generation 0 has
  # no earlier network to play. Its champion is also the previous checkpoint
  # of the first checkpoint, so that one is played once. ExperimentStats
  # uses this to tell a complete benchmark.
  def self.opponents_for(generation, panel, keep_every)
    panel.select do |row|
      case row[:kind]
      when 'bot' then true
      when 'initial_champion' then generation.positive?
      when 'previous_checkpoint' then (generation - keep_every).positive?
      else raise ArgumentError, "unknown benchmark opponent kind #{row[:kind]}"
      end
    end
  end

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
  # plays what is missing. Returns whether it played any game.
  def call
    FileUtils.mkdir_p(DIRECTORY)
    played = store.benchmark_games(generation).to_set { |row| row.values_at(:opponent, :opening, :network_color) }
    all = games
    pending = all.reject { |game| played.include?([game.opponent.name, game.opening, game.color]) }
    return false if pending.empty?

    pending.each { |game| pool.submit(command(game), game) }
    pending.size.times do |i|
      game, duration = pool.next_finished
      # As in the tournament: a game killed by Ctrl-C stays unscored and is
      # replayed on resume.
      exit if $stop_now
      store_game(game, duration)
      print "\rBenchmark ... Game: #{all.size - pending.size + i + 1}/#{all.size}".ljust(70)
    end
    puts "\rBenchmark ... done".ljust(70)
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
    self.class.opponents_for(generation, store.benchmark_opponents, settings['keep_every']).map do |row|
      case row[:kind]
      when 'bot' then Opponent.new(name: row[:name], command: row[:command], network: nil)
      when 'initial_champion' then network_opponent(row[:name], 0)
      when 'previous_checkpoint' then network_opponent(row[:name], generation - settings['keep_every'])
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
    # GNU Go, as the referee and as a bot, plays at random unless seeded.
    seed = Seeds.gnugo(settings.fetch('seed'), 'benchmark', generation, game.opponent.name, game.opening, game.color)
    opponent = Seeds.with_gnugo_seed(game.opponent.command, seed)
    black, white = game.color == 'black' ? [network_command, opponent] : [opponent, network_command]
    moves = opening_moves(game.opening)
    # twogtp counts the opening's stones toward -maxmoves.
    maxmoves = settings['max_moves'] + moves.size
    openings = moves.empty? ? '' : " -openings #{opening_directory(game.opening, moves)}"
    prefix = game.prefix
    %(gogui-twogtp -black "#{black}" -white "#{white}" -referee "#{GameResult::REFEREE} --seed #{seed}" ) +
      %(-size #{settings['board_size']} -komi #{settings.fetch('komi')} -auto -games 1 -sgffile #{prefix} ) +
      %(-time #{settings['game_length']} ) +
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
end
