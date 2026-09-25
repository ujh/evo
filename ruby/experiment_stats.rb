require_relative 'checkpoint_benchmark'

# What `stats` reports about an experiment, computed from its database
# alone. A tournament score only ranks the networks of one generation, so
# progress shows in the benchmark at checkpoints (see migration 008), and
# the tournament and population figures show whether evolution is healthy:
# how many games failed, how many children merely copy a parent, how varied
# the parents and genomes are. The genome figures (genes, shapes,
# activations, structural changes, children per parent) come from births,
# and show whether the self-adapting genes drift (for instance copy_chance
# toward its bound); the bot ranks come from the rankings and place the
# networks against the fixed bots.
class ExperimentStats
  RESULTS = { 'network' => :win, 'opponent' => :loss }.freeze
  # Every generation counts each, so the CSV has the same columns for all.
  OPERATORS = %w[initial crossover mutation copy].freeze
  # The genes, the activations, and the structural changes as births store
  # them (evolve's genes and summary lines); each is counted or summarized
  # in every generation that has them, for the same reason.
  GENES = %w[copy_chance weight_changes weight_step activation_rate structure_rate].freeze
  ACTIVATIONS = %w[sigmoid sigmoid_cached threshold linear tanh relu].freeze
  STRUCTURES = %w[none widen narrow add_layer remove_layer].freeze

  # `database` is an ExperimentDatabase, normally opened read-only.
  def initialize(database)
    @database = database
  end

  def generations
    database.generations
  end

  # The tournament's bot groups: the stored opponents, whose copies play as
  # the name plus a copy number (Brown1, Brown2, ...).
  def bot_groups
    database.opponents.map { |opponent| opponent[:name] }
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
    births = database.births(generation)
    {
      generation:,
      finished: state['round'] >= Integer(settings.fetch('tournament_rounds')) && (benchmark.nil? || benchmark[:complete]),
      tournament: tournament(generation),
      population: population(generation),
      genes: GENES.to_h { |gene| [gene, summary(births.filter_map { |birth| birth[gene.to_sym] })] },
      shape: shape(births),
      activation: activation(births),
      structure: structure(births),
      parents: parents(generation, births),
      bots: bots(generation),
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
    parents = generation.zero? ? {} : database.births(generation - 1).to_h { |birth| [birth[:child], birth] }
    scores = database.ranking(generation).reject { |row| row[:external] }.map { |row| row[:score] }.sort
    {
      children: births.size,
      operators: OPERATORS.to_h { |operator| [operator, 0] }.merge(births.map { |birth| birth[:operator] }.tally),
      identical: births.count { |birth| birth[:operator] != 'initial' && identical?(birth, parents) },
      distinct_parents: births.flat_map { |birth| inherited_from(birth) }.uniq.size,
      unique_genomes: births.map { |birth| birth[:genome] }.uniq.size,
      scores: { min: scores.first, median: median(scores), max: scores.last }
    }
  end

  # The parents a child has weights from. A mutation or a copy comes from
  # the parent evolve picked; births from before the parent column name
  # none, and there it is the one the child differs less from (the first
  # when both are equal). A crossover that copied one parent has only its
  # weights. A differs count is nil for a parent of another shape.
  def inherited_from(birth)
    first, second = birth.values_at(:first_parent, :second_parent)
    one, two = birth.values_at(:differs_from_first, :differs_from_second)
    case birth[:operator]
    when 'mutation', 'copy'
      picked = birth[:parent] || (two.nil? || (!one.nil? && one <= two) ? 'first' : 'second')
      [picked == 'first' ? first : second]
    when 'crossover'
      return [first] if one&.zero?
      return [second] if two&.zero?

      [first, second]
    else []
    end
  end

  # A bred child equal to a parent: the same weights (differs 0) and the
  # same activations. A copy always is. A child of another shape than a
  # parent has no count for it; one whose activation switched plays
  # differently even with the same weights; and a crossover takes the
  # picked parent's activations, so it can have all of the other parent's
  # weights but not its activations. `parents` are the previous
  # generation's births by name (rows from before migration 010 have no
  # activations, which then compare equal).
  def identical?(birth, parents)
    return true if birth[:operator] == 'copy'
    return false if birth[:activation_changed]

    { first_parent: :differs_from_first, second_parent: :differs_from_second }.any? do |parent, differs|
      birth[differs]&.zero? && same_activations?(birth, parents[birth[parent]])
    end
  end

  def same_activations?(birth, parent)
    columns = %i[act_hidden act_output]
    birth.values_at(*columns) == (parent || {}).values_at(*columns)
  end

  # Min, median, and max; all nil without values.
  def summary(values)
    sorted = values.sort
    { min: sorted.first, median: median(sorted), max: sorted.last }
  end

  # The networks' shapes: the hidden layers, their width, and the total
  # weights (nil without the board size), each summarized, and how many
  # networks have each shape, as "LAYERSxWIDTH". Births from before
  # migration 010 have no shape.
  def shape(births)
    shaped = births.select { |birth| birth[:layers] }
    shapes = shaped.map { |birth| birth.values_at(:layers, :width) }
    {
      layers: summary(shapes.map(&:first)),
      width: summary(shapes.map(&:last)),
      weights: summary(shapes.filter_map { |layers, width| total_weights(layers, width) }),
      counts: shapes.map { |layers, width| "#{layers}x#{width}" }.tally.sort_by { |name, count| [-count, name] }.to_h
    }
  end

  # As GENANN lays them out: each neuron has a bias and a weight per neuron
  # of the layer before; a board of N points has N² + 1 inputs and outputs.
  def total_weights(layers, width)
    return nil unless settings['board_size']

    ends = (Integer(settings['board_size'])**2) + 1
    return (ends + 1) * ends if layers.zero?

    ((ends + 1) * width) + ((layers - 1) * (width + 1) * width) + ((width + 1) * ends)
  end

  # How many networks have each hidden and each output activation; nil
  # without activations.
  def activation(births)
    return nil if births.none? { |birth| birth[:act_hidden] }

    { hidden: :act_hidden, output: :act_output }.transform_values do |column|
      ACTIVATIONS.to_h { |name| [name, 0] }.merge(births.filter_map { |birth| birth[column] }.tally)
    end
  end

  # How many bred children had each structural change (crossovers and
  # copies none); nil without bred children.
  def structure(births)
    values = births.filter_map { |birth| birth[:structure] }
    values.empty? ? nil : STRUCTURES.to_h { |op| [op, 0] }.merge(values.tally)
  end

  # How selection spread the children over the previous generation's
  # networks: the most children one parent got, how many got none, and how
  # many got any. A crossover counts for both parents (both were
  # selected and crossed), a mutation or a copy only for the parent evolve
  # picked. nil for the initial population. Unlike distinct_parents, this
  # counts selection, not whose weights survive.
  def parents(generation, births)
    bred = births.reject { |birth| birth[:operator] == 'initial' }
    return nil if generation.zero? || bred.empty?

    children = bred.flat_map do |birth|
      first, second = birth.values_at(:first_parent, :second_parent)
      next [first, second] if birth[:operator] == 'crossover'

      [birth[:parent] == 'second' ? second : first]
    end.tally
    pool = previous_networks(generation) | children.keys
    { max_children: children.values.max, childless: (pool - children.keys).size, used: children.size }
  end

  # The networks parents were drawn from: the previous generation's
  # ranking, or its births when it has none.
  def previous_networks(generation)
    ranked = database.ranking(generation - 1).reject { |row| row[:external] }.map { |row| row[:name] }
    ranked.empty? ? database.births(generation - 1).map { |birth| birth[:child] } : ranked
  end

  # Where the bots stand, by score: the best bot's rank (one more than the
  # players with more points, so ties share a rank, whatever order the
  # ranking broke them in) and how many networks have more points, and the
  # same for each group's best copy (nil when no copy is ranked).
  def bots(generation)
    ranking = database.ranking(generation)
    networks = ranking.reject { |row| row[:external] }.map { |row| row[:score] }
    standing = lambda do |copies|
      best = copies.map { |row| row[:score] }.max
      best && { best_rank: 1 + ranking.count { |row| row[:score] > best }, networks_above: networks.count { |score| score > best } }
    end
    external = ranking.select { |row| row[:external] }
    groups = bot_groups.to_h do |group|
      [group, standing.call(external.select { |row| row[:name].match?(/\A#{Regexp.escape(group)}\d*\z/) })]
    end
    (standing.call(external) || { best_rank: nil, networks_above: nil }).merge(groups)
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
