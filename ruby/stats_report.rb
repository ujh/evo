require 'csv'
require 'terminal-table'
require_relative 'experiment_stats'

class ExperimentStats
  # Formats what ExperimentStats computes, for the stats script: text tables,
  # CSV, and the --watch loop. `figures` is a list of ExperimentStats#generation
  # hashes, oldest first.
  module Report
    CLEAR = "\e[2J\e[H".freeze
    # Around each cell of a generation that is not done, with `dim`: italic
    # and grey (bright black), then back to upright and the default color.
    DIM = ["\e[3;90m", "\e[23;39m"].freeze
    # The generation table shows the latest generations only.
    GENERATION_ROWS = 50
    GENERATION_HEADINGS = %w[Gen Done Games Draws Time Copies Parents Genomes Min Med Max].freeze
    GENERATION_NOTE = <<~NOTE.freeze
      Done: rounds and benchmark played. Time: of all games. Copies: bred children identical to a parent.
      Parents: networks that passed on weights. Genomes: distinct children. Min, Med, Max: network scores.
      In a terminal, a generation not done is grey and italic where its figures still change.
    NOTE
    BENCHMARK_HEADINGS = %w[Rank Player Games Black White Draws Failed Score].freeze
    BENCHMARK_NOTE = <<~NOTE.freeze
      Strongest first, by the champion's score against each opponent; > marks the champion, placed above
      the opponents it scored more than half against. Opponents without a scored game come last.
      Games: stored of planned; fewer means the benchmark is still playing or was stopped.
      Black, White: W-L of the champion with that color. Score: its share, a draw counting half.
    NOTE
    # Around each cell of the champion's row, with `dim`.
    BOLD = ["\e[1m", "\e[22m"].freeze
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
    FEATURES_NOTE = <<~NOTE.freeze
      Medians of feature_step (Step) and of the weight each move feature adds to a point's score, then min
      and max in one generation. Only the experiment's features.
    NOTE
    # Column names for the feature weights.
    FEATURE_NAMES = { 'fw_hane' => 'Hane', 'fw_cut' => 'Cut', 'fw_edge' => 'Edge', 'fw_capture' => 'Capture',
                      'fw_self_atari' => 'SelfAtari', 'fw_saves_atari' => 'SavesAtari',
                      'fw_near_last' => 'NearLast' }.freeze
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
    AGAINST_BOTS_NOTE = <<~NOTE.freeze
      Tournament games between a network and a copy of the bot: the networks' wins of the games played,
      and their share. Networks meet the bots near their own score.
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

    # The latest `limit` generations, and the benchmark of the latest
    # checkpoint, whether or not it is among them: with keep_every above
    # `limit` they often hold none. With `dim` (a terminal), the champion's row
    # in the benchmark is bold, and the rows of a generation that is not done
    # are grey and italic in the tables whose figures change while it plays: the
    # generations, the bots, and the benchmark. The genome figures come from
    # births, which a generation has before it plays.
    def text(figures, limit: GENERATION_ROWS, dim: false)
      return "#{NO_GENERATIONS}\n" if figures.empty?

      shown = figures.last(limit)
      title = "Generations#{" (latest #{shown.size} of #{figures.size})" if shown.size < figures.size}"
      rows = shown.map { |f| style(generation_row(f), f, dim) }
      out = +"#{title}\n#{table(GENERATION_HEADINGS, rows)}\n#{GENERATION_NOTE}"
      out << genome_tables(shown.last(GENOME_ROWS), dim)
      checkpoint = figures.reverse.find { |f| f[:benchmark] }
      return out unless checkpoint

      network = checkpoint[:benchmark][:network]
      title = "Benchmark: generation #{checkpoint[:generation]}#{" (#{network})" if network}"
      out << "\n#{title}\n#{benchmark_table(checkpoint, dim)}\n#{BENCHMARK_NOTE}"
    end

    # The row with each cell dimmed, if `dim` and the generation is not
    # done.
    def style(row, figures, dim)
      return row unless dim && !figures[:finished]

      row.map { |cell| "#{DIM.first}#{cell}#{DIM.last}" }
    end

    SUMMARY = %w[min median max].freeze
    # The CSV columns before the bots' and the benchmark's, in the order of
    # ExperimentStats#generation. Shapes are summarized, not counted per
    # shape, so the columns stay the same whatever shapes evolve.
    CSV_COLUMNS = [
      'generation', 'finished',
      *%w[games draws play_seconds].map { |key| "tournament.#{key}" },
      'population.children', *ExperimentStats::OPERATORS.map { |operator| "population.operators.#{operator}" },
      *%w[identical distinct_parents unique_genomes].map { |key| "population.#{key}" },
      *SUMMARY.map { |key| "population.scores.#{key}" },
      *(ExperimentStats::GENES + [ExperimentStats::FEATURE_STEP] + ExperimentStats::FEATURE_WEIGHTS).flat_map do |gene|
        SUMMARY.map { |key| "genes.#{gene}.#{key}" }
      end,
      *%w[layers width weights].flat_map { |part| SUMMARY.map { |key| "shape.#{part}.#{key}" } },
      *%w[hidden output].flat_map { |layer| ExperimentStats::ACTIVATIONS.map { |name| "activation.#{layer}.#{name}" } },
      *ExperimentStats::STRUCTURES.map { |op| "structure.#{op}" },
      *%w[max_children childless used].map { |key| "parents.#{key}" },
      'bots.best_rank', 'bots.networks_above'
    ].freeze
    STANDING = %w[best_rank networks_above].freeze
    AGAINST = %w[games wins draws].freeze

    # One row per generation. The header depends only on the tournament's
    # bot groups (`bot_groups`) and the benchmark panel (`opponents`, names
    # in panel order), so experiments with the same opponents and panel can
    # be compared column by column. A generation without a figure (a
    # benchmark, genes, a ranked copy of a bot, ...), or an opponent its
    # checkpoint does not play, has empty cells.
    def csv(figures, opponents, bot_groups: [])
      headers = CSV_COLUMNS + bot_groups.flat_map { |group| STANDING.map { |key| "bots.#{group}.#{key}" } } +
                bot_groups.flat_map { |group| AGAINST.map { |key| "against_bots.#{group}.#{key}" } } +
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
        io.print(CLEAR, text(figures(stats, cache), dim: io.tty?), "\nUpdated #{Time.now.strftime('%H:%M:%S')}; Ctrl-C to stop.\n")
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
       duration(tournament[:play_seconds]), identical_share(population), population[:distinct_parents],
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

    # The genes, feature weights (none without features), shapes and
    # activations, breeding and bots, and networks against bots tables.
    def genome_tables(shown, dim)
      latest = shown.reverse.find { |f| f[:genes].values.any? { |gene| gene[:median] } }
      weights = shown.last ? shown.last[:genes].keys & ExperimentStats::FEATURE_WEIGHTS : []
      bots = shown.last&.fetch(:bots)&.keys&.grep(String) || []
      out = genes_table('Genes', GENES_HEADINGS, shown, latest) { |f, key| genes_row(f, key) }
      out << "\n#{GENES_NOTE}"
      unless weights.empty?
        headings = %w[Gen Step] + weights.map { |gene| FEATURE_NAMES.fetch(gene) }
        features = genes_table('Feature weights', headings, shown, latest) do |f, key|
          [ExperimentStats::FEATURE_STEP, *weights].map { |gene| number(f[:genes][gene][key]) }
        end
        out << features << "\n#{FEATURES_NOTE}"
      end
      out << "\nShapes and activations\n#{table(SHAPES_HEADINGS, shown.map { |f| shapes_row(f) }, left: [1, 2, 3])}\n#{SHAPES_NOTE}" \
        "\nBreeding and bots\n#{table(BREEDING_HEADINGS + bots, shown.map { |f| style(breeding_row(f, bots), f, dim) })}\n#{BREEDING_NOTE}"
      out << against_bots_table(shown, dim)
    end

    # Per generation and bot group, the networks' wins against it.
    def against_bots_table(shown, dim)
      bots = shown.last&.fetch(:against_bots)&.keys || []
      return '' if bots.empty?

      rows = shown.map { |f| style([f[:generation], *bots.map { |bot| wins_cell(f[:against_bots][bot]) }], f, dim) }
      "\nNetworks against bots\n#{table(['Gen', *bots], rows)}\n#{AGAINST_BOTS_NOTE}"
    end

    # "WINS/GAMES SHARE%", or "-" without games.
    def wins_cell(counts)
      return '-' if counts.nil? || counts[:games].zero?

      "#{counts[:wins]}/#{counts[:games]} #{(100.0 * counts[:wins] / counts[:games]).round}%"
    end

    # A row of medians per generation, then the min and max of `latest`, the
    # latest generation with births; the block gives a row's cells after
    # its label.
    def genes_table(title, headings, shown, latest)
      rows = shown.map { |f| [f[:generation], *yield(f, :median)] }
      if latest
        rows += [:separator, ['min', *yield(latest, :min)], ['max', *yield(latest, :max)]]
        title += " (range: generation #{latest[:generation]})"
      end
      +"\n#{title}\n#{table(headings, rows)}"
    end

    def genes_row(figures, key)
      shape = figures[:shape]
      [*ExperimentStats::GENES.map { |gene| number(figures[:genes][gene][key]) },
       *%i[layers width weights].map { |part| number(shape[part][key]) }]
    end

    # Three significant digits, whole numbers from 999.5 (which %.3g would
    # print as 1e+03). A number below 0.01 that needs more than 6 characters
    # (7 negative) keeps two digits, and one that still does not fit becomes a
    # short exponent such as 1.2e-5, so a column near 0 is no wider than the
    # others.
    def number(value)
      return '-' if value.nil?
      return value.round.to_s if value.abs >= 999.5

      limit = value.negative? ? 7 : 6
      text = format('%.3g', value)
      return text if text.size <= limit && !text.include?('e')

      text = format('%.2g', value)
      return text if text.size <= limit && !text.include?('e')

      [1, 0].map { |digits| short_exponent(format("%.#{digits}e", value)) }.find { |t| t.size <= limit }
    end

    # "1.2e-05" as "1.2e-5", "1.0e-09" as "1e-9".
    def short_exponent(text)
      text.sub('.0e', 'e').sub(/e([-+])0+(?=\d)/, 'e\1')
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

    # The checkpoint `f`'s ranking (ranking), one row per player: the
    # opponents with their results, the champion, the checkpoint's own top
    # network, named as later checkpoints name it, with none.
    def benchmark_table(f, dim)
      benchmark = f[:benchmark]
      rows = ranking(benchmark).each_with_index.map do |name, i|
        next style(champion_row(i + 1, f[:generation], dim), f, dim) if name == :champion

        black, white = benchmark[name].values_at(:black, :white)
        played = [black, white].sum { |counts| counts.values.sum }
        share = score_share(benchmark[name])
        style([i + 1, name, "#{played}/#{benchmark[:games]}", "#{black[:win]}-#{black[:loss]}",
               "#{white[:win]}-#{white[:loss]}", black[:draw] + white[:draw], black[:failure] + white[:failure],
               share ? "#{(100 * share).round}%" : '-'], f, dim)
      end
      table(BENCHMARK_HEADINGS, rows, left: [1])
    end

    def champion_row(rank, generation, dim)
      row = [rank, "> #{CheckpointBenchmark.champion_name(generation)}", *[''] * 6]
      dim ? row.map { |cell| "#{BOLD.first}#{cell}#{BOLD.last}" } : row
    end

    # The opponents of a checkpoint's benchmark, strongest first: the one the
    # champion scored the lowest share against first (score_share), ties in
    # reverse panel order, since the panel lists the bots weakest first, and :champion before the first it scored more than half
    # against. Opponents without a scored game come last.
    def ranking(benchmark)
      names = benchmark.keys.grep(String)
      played, unplayed = names.partition { |name| score_share(benchmark[name]) }
      played = played.sort_by.with_index { |name, position| [score_share(benchmark[name]), -position] }
      above = played.take_while { |name| score_share(benchmark[name]) <= 1/2r }
      above + [:champion] + played.drop(above.size) + unplayed
    end

    # The champion's share of points against one opponent, a win 1 and a
    # draw 1/2 of the games with a result, failures left out; nil without
    # such a game.
    def score_share(results)
      counts = results.values
      scored = counts.sum { |c| c[:win] + c[:loss] + c[:draw] }
      return nil if scored.zero?

      counts.sum { |c| c[:win] + (c[:draw] / 2r) } / scored
    end
  end
end
