require_relative 'checkpoint_benchmark'

# What `stats` reports about an experiment, computed from its database
# alone. A tournament score only ranks the networks of one generation, so
# progress shows in the benchmark at checkpoints (see migration 008), and
# the tournament and population figures show whether evolution is healthy:
# how many games failed, how many children merely copy a parent, how varied
# the parents and genomes are.
class ExperimentStats
  RESULTS = { 'network' => :win, 'opponent' => :loss }.freeze
  # Every generation counts each, so the CSV has the same columns for all.
  OPERATORS = %w[initial crossover mutation].freeze

  # `database` is an ExperimentDatabase, normally opened read-only.
  def initialize(database)
    @database = database
  end

  def generations
    database.generations
  end

  # The names of the benchmark panel, in panel order.
  def benchmark_opponents
    database.benchmark_opponents.map { |opponent| opponent[:name] }
  end

  # A Hash with the generation's figures; see the private methods for each
  # part. The last generation may still be playing, and a checkpoint is
  # finished only once its benchmark is complete.
  def generation(generation)
    state = database.state(generation)
    benchmark = benchmark(generation)
    {
      generation:,
      finished: state['round'] >= Integer(settings.fetch('tournament_rounds')) && (benchmark.nil? || benchmark[:complete]),
      tournament: tournament(generation),
      population: population(generation),
      benchmark:
    }
  end

  private

  attr_reader :database

  # Settings are stored as strings.
  def settings
    @settings ||= database.settings
  end

  # The scored games. A draw has neither winner nor failure; game_seconds is
  # nil when no game has a timing.
  def tournament(generation)
    games = database.games(generation, columns: %i[winner failure duration])
    durations = games.filter_map { |game| game[:duration] }
    {
      games: games.size,
      draws: games.count { |game| game[:winner].nil? && game[:failure].nil? },
      failures: games.count { |game| game[:failure] },
      game_seconds: durations.empty? ? nil : durations.sum
    }
  end

  # How the generation's networks came about, and the networks' scores (the
  # bots are ranked too, but are left out).
  def population(generation)
    births = database.births(generation)
    scores = database.ranking(generation).reject { |row| row[:external] }.map { |row| row[:score] }.sort
    {
      children: births.size,
      operators: OPERATORS.to_h { |operator| [operator, 0] }.merge(births.map { |birth| birth[:operator] }.tally),
      identical: births.count { |birth| birth[:operator] != 'initial' && identical?(birth) },
      distinct_parents: births.flat_map { |birth| inherited_from(birth) }.uniq.size,
      unique_genomes: births.map { |birth| birth[:genome] }.uniq.size,
      scores: { min: scores.first, median: median(scores), max: scores.last }
    }
  end

  # The parents a child has weights from. evolve mutates a copy of one
  # parent, the one the child differs less from (the first when both are
  # identical), and a crossover that copied one parent has only its weights.
  def inherited_from(birth)
    first, second = birth.values_at(:first_parent, :second_parent)
    one, two = birth.values_at(:differs_from_first, :differs_from_second)
    case birth[:operator]
    when 'mutation' then [one <= two ? first : second]
    when 'crossover'
      return [first] if one.zero?
      return [second] if two.zero?

      [first, second]
    else []
    end
  end

  def identical?(birth)
    birth[:differs_from_first].zero? || birth[:differs_from_second].zero?
  end

  def median(sorted)
    return nil if sorted.empty?

    middle = (sorted[(sorted.size - 1) / 2] + sorted[sorted.size / 2]) / 2.0
    middle == middle.to_i ? middle.to_i : middle
  end

  # nil unless the generation is a checkpoint. Else the benchmarked network
  # (nil before the first game), the games planned per opponent, whether
  # every game is stored, and, per
  # opponent the checkpoint plays (CheckpointBenchmark.opponents_for), in
  # panel order, the results by the network's color: a win is the
  # network's.
  def benchmark(generation)
    return nil unless checkpoint?(generation)

    rows = database.benchmark_games(generation, columns: %i[opponent network_color network winner failure])
    opponents = CheckpointBenchmark.opponents_for(generation, database.benchmark_opponents, keep_every)
    by_opponent = rows.group_by { |row| row[:opponent] }
    result = { network: rows.first&.fetch(:network), games: benchmark_games,
               complete: rows.size == opponents.size * benchmark_games }
    opponents.each_with_object(result) do |opponent, figures|
      games = by_opponent.fetch(opponent[:name], [])
      figures[opponent[:name]] = %w[black white].to_h do |color|
        [color.to_sym, results(games.select { |game| game[:network_color] == color })]
      end
    end
  end

  def benchmark_games
    Integer(settings.fetch('benchmark_games'))
  end

  def keep_every
    Integer(settings.fetch('keep_every'))
  end

  # As in RunGeneration: the generations whose networks are kept.
  def checkpoint?(generation)
    keep_every.positive? && (generation % keep_every).zero?
  end

  def results(games)
    outcomes = games.map { |game| game[:failure] ? :failure : RESULTS.fetch(game[:winner], :draw) }.tally
    { win: 0, loss: 0, draw: 0, failure: 0 }.merge(outcomes)
  end
end
