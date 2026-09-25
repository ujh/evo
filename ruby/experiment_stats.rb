# What `stats` reports about an experiment, computed from its database
# alone. A tournament score only ranks the networks of one generation, so
# progress shows in the benchmark at checkpoints (see migration 008), and
# the tournament and population figures show whether evolution is healthy:
# how many games failed, how many children merely copy a parent, how varied
# the parents and genomes are.
class ExperimentStats
  RESULTS = { 'network' => :win, 'opponent' => :loss }.freeze

  # `database` is an ExperimentDatabase, normally opened read-only.
  def initialize(database)
    @database = database
  end

  def generations
    database.generations
  end

  # A Hash with the generation's figures; see the private methods for each
  # part. The last generation may still be playing.
  def generation(generation)
    state = database.state(generation)
    {
      generation:,
      finished: state['round'] >= Integer(settings.fetch('tournament_rounds')),
      tournament: tournament(generation),
      population: population(generation),
      benchmark: benchmark(generation)
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
    games = database.games(generation)
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
      operators: births.map { |birth| birth[:operator] }.tally,
      identical: births.count { |birth| birth[:operator] != 'initial' && identical?(birth) },
      distinct_parents: births.flat_map { |birth| birth.values_at(:first_parent, :second_parent) }.compact.uniq.size,
      unique_genomes: births.map { |birth| birth[:genome] }.uniq.size,
      scores: { min: scores.first, median: median(scores), max: scores.last }
    }
  end

  def identical?(birth)
    birth[:differs_from_first].zero? || birth[:differs_from_second].zero?
  end

  def median(sorted)
    return nil if sorted.empty?

    middle = (sorted[(sorted.size - 1) / 2] + sorted[sorted.size / 2]) / 2.0
    middle == middle.to_i ? middle.to_i : middle
  end

  # nil unless the generation is a checkpoint with benchmark games. Else the
  # benchmarked network and, per opponent that was played, in panel order,
  # the results by the network's color: a win is the network's.
  def benchmark(generation)
    return nil unless checkpoint?(generation)

    rows = database.benchmark_games(generation)
    return nil if rows.empty?

    by_opponent = rows.group_by { |row| row[:opponent] }
    database.benchmark_opponents.each_with_object({ network: rows.first[:network] }) do |opponent, result|
      games = by_opponent[opponent[:name]]
      next unless games

      result[opponent[:name]] = %w[black white].to_h do |color|
        [color.to_sym, results(games.select { |game| game[:network_color] == color })]
      end
    end
  end

  # As in RunGeneration: the generations whose networks are kept.
  def checkpoint?(generation)
    every = Integer(settings.fetch('keep_every'))
    every.positive? && (generation % every).zero?
  end

  def results(games)
    outcomes = games.map { |game| game[:failure] ? :failure : RESULTS.fetch(game[:winner], :draw) }.tally
    { win: 0, loss: 0, draw: 0, failure: 0 }.merge(outcomes)
  end
end
