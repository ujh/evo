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
      Parents: distinct parents. Genomes: distinct children. Min, Med, Max: the networks' scores.
    NOTE
    BENCHMARK_HEADINGS = %w[Gen Network Opponent Games Black White Draws Failed].freeze
    BENCHMARK_NOTE = <<~NOTE.freeze
      Games: stored of planned; fewer means the benchmark is still playing or was stopped.
      Black, White: W-L of the benchmarked network with that color.
    NOTE
    NO_GENERATIONS = 'No generations yet.'.freeze

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
      checkpoints = shown.select { |f| f[:benchmark] }
      return out if checkpoints.empty?

      out << "\nBenchmark\n#{benchmark_table(checkpoints)}\n#{BENCHMARK_NOTE}"
    end

    # The CSV columns before the benchmark's results, in the order of
    # ExperimentStats#generation.
    CSV_COLUMNS = [
      'generation', 'finished',
      *%w[games draws failures game_seconds].map { |key| "tournament.#{key}" },
      'population.children', *ExperimentStats::OPERATORS.map { |operator| "population.operators.#{operator}" },
      *%w[identical distinct_parents unique_genomes].map { |key| "population.#{key}" },
      *%w[min median max].map { |key| "population.scores.#{key}" },
      'benchmark.network', 'benchmark.complete'
    ].freeze

    # One row per generation. The header depends only on the benchmark
    # panel (`opponents`, names in panel order), so experiments with the
    # same panel can be compared column by column. A generation without a
    # benchmark, or an opponent its checkpoint does not play, has empty
    # cells.
    def csv(figures, opponents)
      headers = CSV_COLUMNS + opponents.flat_map do |name|
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
