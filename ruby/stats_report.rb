require 'csv'
require 'terminal-table'
require_relative 'experiment_stats'

class ExperimentStats
  # Formats what ExperimentStats computes, for the stats script: text tables,
  # CSV, and the --watch loop. `figures` is a list of ExperimentStats#generation
  # hashes, oldest first.
  module Report
    CLEAR = "\e[2J\e[H".freeze
    # The generation table shows the latest generations only.
    GENERATION_ROWS = 50
    GENERATION_HEADINGS = %w[Gen Done Games Draws Failed Time Copies Parents Genomes Min Med Max].freeze
    GENERATION_NOTE = <<~NOTE.freeze
      Done: rounds and benchmark played. Time: of all games. Copies: bred children identical to a parent.
      Parents: networks that passed on weights. Genomes: distinct children. Min, Med, Max: network scores.
    NOTE
    BENCHMARK_HEADINGS = %w[Gen Network Opponent Games Black White Draws Failed].freeze
    BENCHMARK_NOTE = <<~NOTE.freeze
      Games: stored of planned; fewer means the benchmark is still playing or was stopped.
      Black, White: W-L of the benchmarked network with that color.
    NOTE
    NO_GENERATIONS = 'No generations yet.'.freeze
    # The genome tables show fewer generations: they are for the trend, and
    # --csv has every generation.
    GENOME_ROWS = 10
    GENES_HEADINGS = %w[Gen Copy Changes Step Act Struct Layers Width Weights].freeze
    GENES_NOTE = <<~NOTE.freeze
      Medians of the networks' genes, then min and max in one generation. Copy: copy_chance.
      Changes: weight_changes. Step: weight_step. Act, Struct: activation_rate, structure_rate.
      Weights: per network.
    NOTE
    SHAPES_HEADINGS = %w[Gen Shapes Hidden Output].freeze
    SHAPES_NOTE = <<~NOTE.freeze
      Networks per shape (hidden layers x width) and per activation, the three most common.
    NOTE
    # Short names for the activation columns.
    ACTIVATION_NAMES = { 'sigmoid' => 'sig', 'sigmoid_cached' => 'sigc', 'threshold' => 'thr', 'linear' => 'lin',
                         'tanh' => 'tanh', 'relu' => 'relu' }.freeze
    BREEDING_HEADINGS = %w[Gen Kids Childless Widen Narrow Add Remove Bots].freeze
    BREEDING_NOTE = <<~NOTE.freeze
      Kids: most children of one parent. Childless: parents with none. Widen..Remove: structural changes.
      Bots, then each bot: the best copy's rank by score, with the networks above it in brackets.
    NOTE

    module_function

    # Every generation's figures. A generation before the last one no longer
    # changes (the runner benchmarks a checkpoint before it breeds the next
    # generation), so its figures are kept in `cache` and computed only once.
    def figures(stats, cache = {})
      generations = stats.generations
      generations.map do |generation|
        next stats.generation(generation) if generation == generations.last

        cache[generation] ||= stats.generation(generation)
      end
    end

    # The latest `limit` generations, and the benchmarks of the checkpoints
    # among them.
    def text(figures, limit: GENERATION_ROWS)
      return "#{NO_GENERATIONS}\n" if figures.empty?

      shown = figures.last(limit)
      title = "Generations#{" (latest #{shown.size} of #{figures.size})" if shown.size < figures.size}"
      out = +"#{title}\n#{table(GENERATION_HEADINGS, shown.map { |f| generation_row(f) })}\n#{GENERATION_NOTE}"
      out << genome_tables(shown.last(GENOME_ROWS))
      checkpoints = shown.select { |f| f[:benchmark] }
      return out if checkpoints.empty?

      out << "\nBenchmark\n#{benchmark_table(checkpoints)}\n#{BENCHMARK_NOTE}"
    end

    SUMMARY = %w[min median max].freeze
    # The CSV columns before the bots' and the benchmark's, in the order of
    # ExperimentStats#generation. Shapes are summarized, not counted per
    # shape, so the columns stay the same whatever shapes evolve.
    CSV_COLUMNS = [
      'generation', 'finished',
      *%w[games draws failures game_seconds].map { |key| "tournament.#{key}" },
      'population.children', *ExperimentStats::OPERATORS.map { |operator| "population.operators.#{operator}" },
      *%w[identical distinct_parents unique_genomes].map { |key| "population.#{key}" },
      *SUMMARY.map { |key| "population.scores.#{key}" },
      *ExperimentStats::GENES.flat_map { |gene| SUMMARY.map { |key| "genes.#{gene}.#{key}" } },
      *%w[layers width weights].flat_map { |part| SUMMARY.map { |key| "shape.#{part}.#{key}" } },
      *%w[hidden output].flat_map { |layer| ExperimentStats::ACTIVATIONS.map { |name| "activation.#{layer}.#{name}" } },
      *ExperimentStats::STRUCTURES.map { |op| "structure.#{op}" },
      *%w[max_children childless used].map { |key| "parents.#{key}" },
      'bots.best_rank', 'bots.networks_above'
    ].freeze
    STANDING = %w[best_rank networks_above].freeze

    # One row per generation. The header depends only on the tournament's
    # bot groups (`bot_groups`) and the benchmark panel (`opponents`, names
    # in panel order), so experiments with the same opponents and panel can
    # be compared column by column. A generation without a figure (a
    # benchmark, genes, a ranked copy of a bot, ...), or an opponent its
    # checkpoint does not play, has empty cells.
    def csv(figures, opponents, bot_groups: [])
      headers = CSV_COLUMNS + bot_groups.flat_map { |group| STANDING.map { |key| "bots.#{group}.#{key}" } } +
                %w[benchmark.network benchmark.complete] + opponents.flat_map do |name|
                  %w[black white].flat_map { |color| %w[win loss draw failure].map { |result| "benchmark.#{name}.#{color}.#{result}" } }
                end
      CSV.generate do |out|
        out << headers
        figures.each { |f| out << flatten(f).values_at(*headers) }
      end
    end

    # Nested hashes as one hash with dotted keys, e.g. "population.scores.min".
    def flatten(hash, prefix = nil)
      hash.each_with_object({}) do |(key, value), flat|
        name = [prefix, key].compact.join('.')
        value.is_a?(Hash) ? flat.merge!(flatten(value, name)) : flat[name] = value
      end
    end

    # Redraws the text tables every `interval` seconds, until interrupted.
    def watch(stats, io, interval: 5, pause: ->(seconds) { sleep(seconds) })
      cache = {}
      loop do
        io.print(CLEAR, text(figures(stats, cache)), "\nUpdated #{Time.now.strftime('%H:%M:%S')}; Ctrl-C to stop.\n")
        io.flush
        pause.call(interval)
      end
    end

    # Numbers right-aligned, the columns numbered in `left` (names) left.
    def table(headings, rows, left: [])
      table = Terminal::Table.new(headings:, rows:)
      headings.each_index { |i| table.align_column(i, left.include?(i) ? :left : :right) }
      table
    end

    def generation_row(figures)
      tournament = figures[:tournament]
      population = figures[:population]
      scores = population[:scores]
      [figures[:generation], figures[:finished] ? 'yes' : 'no', tournament[:games], tournament[:draws],
       tournament[:failures], duration(tournament[:game_seconds]), identical_share(population), population[:distinct_parents],
       population[:unique_genomes], *scores.values_at(:min, :median, :max).map { |s| s.nil? ? '-' : s }]
    end

    # The share of bred children (not the initial population) that copy a
    # parent unchanged.
    def identical_share(population)
      bred = population[:children] - population[:operators].fetch('initial', 0)
      bred.zero? ? '-' : "#{(100.0 * population[:identical] / bred).round}%"
    end

    def duration(seconds)
      return '-' if seconds.nil?
      return format('%.1fs', seconds) if seconds < 60

      minutes = (seconds / 60).floor
      minutes < 60 ? format('%dm%02ds', minutes, seconds % 60) : format('%dh%02dm', minutes / 60, minutes % 60)
    end

    # The genes, shapes and activations, and breeding and bots tables.
    def genome_tables(shown)
      latest = shown.reverse.find { |f| f[:genes].values.any? { |gene| gene[:median] } }
      genes = shown.map { |f| genes_row(f[:generation], f, :median) }
      title = 'Genes'
      if latest
        genes += [:separator, genes_row('min', latest, :min), genes_row('max', latest, :max)]
        title += " (range: generation #{latest[:generation]})"
      end
      bots = shown.last&.fetch(:bots)&.keys&.grep(String) || []
      "\n#{title}\n#{table(GENES_HEADINGS, genes)}\n#{GENES_NOTE}" \
        "\nShapes and activations\n#{table(SHAPES_HEADINGS, shown.map { |f| shapes_row(f) }, left: [1, 2, 3])}\n#{SHAPES_NOTE}" \
        "\nBreeding and bots\n#{table(BREEDING_HEADINGS + bots, shown.map { |f| breeding_row(f, bots) })}\n#{BREEDING_NOTE}"
    end

    def genes_row(label, figures, key)
      shape = figures[:shape]
      [label, *ExperimentStats::GENES.map { |gene| number(figures[:genes][gene][key]) },
       *%i[layers width weights].map { |part| number(shape[part][key]) }]
    end

    # Three significant digits, whole numbers from 1000.
    def number(value)
      return '-' if value.nil?

      value.abs >= 1000 ? value.round.to_s : format('%.3g', value)
    end

    def shapes_row(figures)
      activation = figures[:activation]
      [figures[:generation], most_common(figures[:shape][:counts]),
       *%i[hidden output].map { |layer| activation ? most_common(activation[layer], ACTIVATION_NAMES) : '-' }]
    end

    # "NAME COUNT" for the three largest counts, and how many more names
    # have any.
    def most_common(counts, names = {})
      present = counts.select { |_, count| count.positive? }.sort_by { |name, count| [-count, name] }
      return '-' if present.empty?

      shown = present.first(3).map { |name, count| "#{names.fetch(name, name)} #{count}" }.join(', ')
      present.size > 3 ? "#{shown} +#{present.size - 3}" : shown
    end

    def breeding_row(figures, bots)
      parents = figures[:parents] || {}
      structure = figures[:structure] || {}
      [figures[:generation], *%i[max_children childless].map { |key| parents.fetch(key, '-') },
       *%w[widen narrow add_layer remove_layer].map { |op| structure.fetch(op, '-') },
       standing(figures[:bots]), *bots.map { |group| standing(figures[:bots][group]) }]
    end

    def standing(bot)
      bot.nil? || bot[:best_rank].nil? ? '-' : "#{bot[:best_rank]} (#{bot[:networks_above]})"
    end

    # One row per checkpoint and opponent it plays, in panel order.
    def benchmark_table(checkpoints)
      rows = checkpoints.flat_map do |f|
        benchmark = f[:benchmark]
        benchmark.keys.grep(String).map do |name|
          black, white = benchmark[name].values_at(:black, :white)
          played = [black, white].sum { |counts| counts.values.sum }
          [f[:generation], benchmark[:network] || '-', name, "#{played}/#{benchmark[:games]}", "#{black[:win]}-#{black[:loss]}",
           "#{white[:win]}-#{white[:loss]}", black[:draw] + white[:draw], black[:failure] + white[:failure]]
        end
      end
      table(BENCHMARK_HEADINGS, rows, left: [1, 2])
    end
  end
end
