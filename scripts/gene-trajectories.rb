#!/usr/bin/env ruby
# Describes how each run's mutation genes, shapes and clones moved, from
# every generation's births alone (read-only; a run may still be running).
# Descriptive only: it prints no test, p-value or interval.
#
#   mise exec -- scripts/gene-trajectories.rb [--window W] experiments/NAME/experiment.sqlite3...
#
# A run is named after its database's directory. Generations whose
# tournament did not finish (generations.round below tournament_rounds) are
# left out everywhere, and the report names them. Generation 0 is a row of
# its own, then windows of W generations (default 50: 1–50, 51–100, …);
# every row says how many generations it holds. Elites are births with
# operator `elite`, never told from the elite_share setting, which schema
# 17 databases lack. Per run and window it prints:
#
# - Genes: for each of copy_chance, weight_changes, weight_step,
#   activation_rate, structure_rate and feature_step, the median of the
#   per-generation medians, the 10th and 90th percentiles over the window's
#   networks (nearest rank), and the shares within 1 % of a clamp
#   (lib/ann.h; weight_changes has only its minimum, and a copy_chance of
#   exactly 0 is counted apart), for all networks, the bred children
#   (elites left out) and the elites alone.
# - Structural changes (structure set and not none) and distinct shapes.
# - Clones: copies, self-crossovers, crossovers with differs 0 against the
#   picked parent, crossovers with a parent's genome (columns that nest,
#   never to be added), and the exact clones, copies plus the last.
# - Apart from the clones, the mutation children with no network weight
#   changed (differs 0 against the picked parent, no structural or
#   activation change), and their largest feature-weight change.
require 'optparse'
require 'sequel'
require_relative '../ruby/experiment_database'

module GeneTrajectories
  GENES = %w[copy_chance weight_changes weight_step activation_rate structure_rate feature_step].freeze
  # lib/ann.h's ANN_*_MIN and ANN_*_MAX. weight_changes has no fixed
  # maximum: its limit is the network's own weight count.
  CLAMPS = { 'copy_chance' => [1e-4, 0.1], 'weight_changes' => [1.0, nil], 'weight_step' => [1e-4, 10.0],
             'activation_rate' => [1e-4, 0.5], 'structure_rate' => [1e-4, 0.5],
             'feature_step' => [1e-4, 1.0] }.freeze
  POPULATIONS = { all: 'All networks', bred: 'Bred children', elites: 'Elites' }.freeze
  UNBRED = %w[initial elite].freeze
  FEATURE_WEIGHTS = ExperimentDatabase::BIRTH_FEATURE_WEIGHT_COLUMNS
  COLUMNS = [*%i[generation child first_parent second_parent operator differs_from_first differs_from_second genome
                 parent structure activation_changed layers width], *GENES.map(&:to_sym), *FEATURE_WEIGHTS].freeze
  P10 = 1 / 10r
  P90 = 9 / 10r

  # A run that cannot be described.
  class Refused < StandardError; end

  # One kept generation's births, described: per population (:all, :bred,
  # :elites) and gene the networks' values; the bred children; those with
  # a structural change; the shapes ([layers, width], distinct); the
  # clone counts (crossovers outside the nesting: a self-crossover without
  # differs 0, or differs 0 without a parent's genome); the mutation
  # children; and per mutation child with no network weight changed its
  # largest feature-weight change against its picked parent (nil when no
  # feature weight is stored for both).
  Generation = Data.define(:generation, :genes, :bred, :structural, :shapes, :copies, :self_crossovers,
                           :differs_zero, :parent_genome, :outside_nesting, :mutations, :no_weight_changes)

  # One gene over a window's networks of one population: how many, the
  # median of the per-generation medians, the 10th and 90th percentiles
  # (nil without networks), and how many are within 1 % of the minimum or
  # the maximum clamp, or exactly 0.
  Figures = Data.define(:networks, :median, :p10, :p90, :min, :max, :zero)

  # A window of a run: its label, its kept generations, Figures per
  # population and gene, and the counts of its Generations summed; the
  # shapes are counted distinct over the window, the largest
  # feature-weight changes summarized as median and maximum.
  Window = Data.define(:label, :generations, :genes, :bred, :structural, :shapes, :copies, :self_crossovers,
                       :differs_zero, :parent_genome, :outside_nesting, :mutations, :no_weight, :no_weight_median,
                       :no_weight_max)

  # A run as described: its tournament rounds, the window width, its
  # unfinished generations as [generation, round], its elites in the kept
  # generations, and its Windows in order.
  Run = Data.define(:name, :rounds, :width, :unfinished, :elites, :windows)

  module_function

  def load(db, name, width)
    rounds = Integer(db[:settings].where(key: 'tournament_rounds').get(:value))
    played = db[:generations].order(:generation).select_map(%i[generation round])
    kept = played.select { |_, round| round >= rounds }.to_h { |generation, _| [generation, true] }
    windows = []
    current = []
    elites = 0
    add = lambda do |record|
      elites += record.genes[:elites].fetch(GENES.first).size
      if current.any? && window_index(current.first.generation, width) != window_index(record.generation, width)
        windows << window(current, width)
        current = []
      end
      current << record
    end
    previous = {}
    births = []
    finish = lambda do
      return if births.empty?

      number = births.first[:generation]
      add[generation(number, births, previous)] if kept[number]
      previous = births.to_h { |birth| [birth[:child], birth] }
      births = []
    end
    db[:births].select(*COLUMNS).order(:generation, :child).naked.each do |row|
      finish.call if births.any? && births.first[:generation] != row[:generation]
      births << row
    end
    finish.call
    windows << window(current, width) if current.any?
    Run.new(name:, rounds:, width:, unfinished: played.reject { |_, round| round >= rounds }, elites:, windows:)
  end

  def window_index(generation, width) = generation.zero? ? 0 : ((generation - 1) / width) + 1

  def label(index, width) = index.zero? ? '0' : "#{((index - 1) * width) + 1}–#{index * width}"

  def picked(birth) = birth[:parent] == 'second' ? birth[:second_parent] : birth[:first_parent]

  def picked_differs(birth) = birth[birth[:parent] == 'second' ? :differs_from_second : :differs_from_first]

  def parent(number, birth, previous, name)
    previous[name] ||
      raise(Refused, "generation #{number}: #{birth[:child]} has no parent #{name} in generation #{number - 1}")
  end

  def generation(number, births, previous)
    genes = POPULATIONS.keys.to_h { |population| [population, GENES.to_h { |gene| [gene, []] }] }
    counts = Hash.new(0)
    changes = []
    births.each do |birth|
      operator = birth[:operator]
      population = { 'initial' => nil, 'elite' => :elites }.fetch(operator, :bred)
      GENES.each do |gene|
        value = birth[gene.to_sym] || raise(Refused, "generation #{number}: #{birth[:child]} has no #{gene}")
        genes[:all][gene] << value
        genes[population][gene] << value if population
      end
      next if UNBRED.include?(operator)

      counts[:bred] += 1
      counts[:structural] += 1 if birth[:structure] && birth[:structure] != 'none'
      zero = picked_differs(birth)&.zero?
      case operator
      when 'copy' then counts[:copies] += 1
      when 'crossover'
        alone = birth[:first_parent] == birth[:second_parent]
        genome = %i[first_parent second_parent].any? do |column|
          parent(number, birth, previous, birth[column])[:genome] == birth[:genome]
        end
        counts[:self_crossovers] += 1 if alone
        counts[:differs_zero] += 1 if zero
        counts[:parent_genome] += 1 if genome
        counts[:outside_nesting] += 1 if (alone && !zero) || (zero && !genome)
      when 'mutation'
        counts[:mutations] += 1
        next unless zero && birth[:structure] == 'none' && !birth[:activation_changed]

        source = parent(number, birth, previous, picked(birth))
        changes << FEATURE_WEIGHTS.filter_map do |column|
          (birth[column] - source[column]).abs if birth[column] && source[column]
        end.max
      end
    end
    Generation.new(generation: number, genes:, bred: counts[:bred], structural: counts[:structural],
                   shapes: births.map { |birth| birth.values_at(:layers, :width) }.uniq,
                   copies: counts[:copies], self_crossovers: counts[:self_crossovers],
                   differs_zero: counts[:differs_zero], parent_genome: counts[:parent_genome],
                   outside_nesting: counts[:outside_nesting], mutations: counts[:mutations],
                   no_weight_changes: changes)
  end

  def median(sorted) = (sorted[(sorted.size - 1) / 2] + sorted[sorted.size / 2]) / 2.0

  # Nearest rank: the smallest value with at least the share p of the
  # values at or below it.
  def percentile(sorted, p) = sorted[(p * sorted.size).ceil - 1]

  # :zero, :min or :max when the value is exactly 0 or within 1 % of the
  # gene's minimum or maximum clamp, else nil.
  def clamp(gene, value)
    min, max = CLAMPS.fetch(gene)
    return :zero if value.zero?
    return :min if value <= min * 1.01
    return :max if max && value >= max * 0.99

    nil
  end

  def figures(gene, per_generation)
    values = per_generation.flatten.sort
    return Figures.new(networks: 0, median: nil, p10: nil, p90: nil, min: 0, max: 0, zero: 0) if values.empty?

    medians = per_generation.reject(&:empty?).map { |generation| median(generation.sort) }.sort
    near = values.map { |value| clamp(gene, value) }.tally
    Figures.new(networks: values.size, median: median(medians), p10: percentile(values, P10),
                p90: percentile(values, P90), min: near.fetch(:min, 0), max: near.fetch(:max, 0),
                zero: near.fetch(:zero, 0))
  end

  def window(records, width)
    genes = POPULATIONS.keys.to_h do |population|
      [population, GENES.to_h { |gene| [gene, figures(gene, records.map { |record| record.genes[population][gene] })] }]
    end
    sum = ->(field) { records.sum(&field) }
    changes = records.flat_map(&:no_weight_changes)
    measured = changes.compact.sort
    Window.new(label: label(window_index(records.first.generation, width), width), generations: records.size, genes:,
               bred: sum[:bred], structural: sum[:structural], shapes: records.flat_map(&:shapes).uniq.size,
               copies: sum[:copies], self_crossovers: sum[:self_crossovers], differs_zero: sum[:differs_zero],
               parent_genome: sum[:parent_genome], outside_nesting: sum[:outside_nesting], mutations: sum[:mutations],
               no_weight: changes.size, no_weight_median: measured.empty? ? nil : median(measured),
               no_weight_max: measured.last)
  end

  # Three significant figures, from 100 on the nearest whole number.
  def number(value) = value.abs >= 100 ? format('%.0f', value) : format('%.3g', value)

  def share(count, total) = format('%.1f %%', 100.0 * count / total)

  def table(header, rows)
    ["| #{header.join(' | ')} |", "| --- |#{' ---: |' * (header.size - 1)}",
     *rows.map { |row| "| #{row.join(' | ')} |" }]
  end

  def check(runs)
    duplicate = runs.map(&:name).tally.find { |_, count| count > 1 }
    raise Refused, "two runs are named #{duplicate.first}" if duplicate
  end

  def report(runs)
    check(runs)
    [header(runs), genes_section(runs), structure_section(runs), clones_section(runs), no_weight_section(runs)]
      .map { |lines| lines.join("\n") }.join("\n\n") << "\n"
  end

  def header(runs)
    unfinished = runs.flat_map do |run|
      run.unfinished.map do |generation, round|
        "#{run.name} generation #{generation} (round #{round} of #{run.rounds})"
      end
    end
    width = runs.first.width
    ["Runs: #{runs.map(&:name).join(', ')}.",
     "Left out everywhere, their tournament unfinished: #{unfinished.empty? ? 'none' : unfinished.join(', ')}.",
     'Elites (births with operator elite) in the generations kept: ' \
     "#{runs.map { |run| "#{run.name} #{run.elites.zero? ? 'none' : run.elites}" }.join(', ')}.",
     "Windows: generation 0 on its own, then #{width} generations each (1–#{width}, #{width + 1}–#{2 * width}, …). " \
     "A run's last window can hold fewer; the Generations column says how many each row holds."]
  end

  def genes_section(runs)
    lines = ['## Genes', '',
             "Per run and window, from every kept generation's births, for each gene: the median of the " \
             "per-generation medians; the 10th and 90th percentiles over the window's networks (nearest rank); and " \
             'the share of networks within 1 % of a clamp of lib/ann.h (at most 1.01 times the minimum, at least ' \
             '0.99 times the maximum). weight_changes has no fixed maximum (its limit is the network\'s own weight ' \
             'count), so only its minimum is counted. A copy_chance of exactly 0 (initial_copy_chance 0: never ' \
             'copy) lies below the clamp range; it is counted as Exactly 0, never as within 1 % of the minimum. ' \
             'Three populations: all networks (every birth, as stats counts genes), the bred children (the initial ' \
             'population and the elites left out), and the elites alone. Values to 3 significant figures, from 100 ' \
             'on to the nearest whole number.']
    GENES.each do |gene|
      lines += ['', "### #{gene}"]
      POPULATIONS.each do |population, title|
        lines += ['', "#### #{title}", '']
        shown = population == :elites ? runs.select { |run| run.elites.positive? } : runs
        if shown.empty?
          lines << 'No run has elites.'
          next
        end
        without = runs - shown
        lines += ["Runs without elites: #{without.map(&:name).join(', ')}.", ''] unless without.empty?
        lines += gene_table(shown, population, gene)
      end
    end
    lines
  end

  def gene_table(runs, population, gene)
    min, max = CLAMPS.fetch(gene)
    zero = gene == 'copy_chance'
    header = ['Run', 'Window', 'Generations', 'Networks', 'Median of medians', '10th percentile', '90th percentile',
              "Within 1 % of #{number(min)}", *("Within 1 % of #{number(max)}" if max), *('Exactly 0' if zero)]
    rows = runs.flat_map do |run|
      run.windows.map do |window|
        f = window.genes[population][gene]
        cells = if f.networks.zero? then ['—'] * (header.size - 4)
                else
                  [number(f.median), number(f.p10), number(f.p90), share(f.min, f.networks),
                   *(share(f.max, f.networks) if max), *(share(f.zero, f.networks) if zero)]
                end
        [run.name, window.label, window.generations, f.networks, *cells]
      end
    end
    table(header, rows)
  end

  def rows(runs)
    runs.flat_map { |run| run.windows.map { |window| [run.name, window.label, window.generations, *yield(window)] } }
  end

  def structure_section(runs)
    ['## Structural changes and shapes', '',
     'Per run and window: the bred children, how many had a structural change (structure set and not none; ' \
     "crossovers, copies and elites store none), and the distinct shapes (hidden layers by width) among all the " \
     "window's networks.", '',
     *table(['Run', 'Window', 'Generations', 'Bred children', 'Structural changes', 'Distinct shapes'],
            rows(runs) { |window| [window.bred, window.structural, window.shapes] })]
  end

  def clones_section(runs)
    outside = runs.map { |run| "#{run.name} #{run.windows.sum(&:outside_nesting)}" }
    ['## Clones', '',
     'Bred children that equal a parent or come from one parent alone, per run and window. Copies: operator copy. ' \
     'Self-crossovers: crossovers of a network with itself (first_parent = second_parent). Differs 0: crossovers ' \
     'whose differs count against the picked parent (the differs_from_first or differs_from_second column that ' \
     "parent names) is 0. A parent's genome: crossovers whose genome equals either parent's (exact clones, " \
     'feature weights and genes included). The three crossover columns nest, each within the next (a crossover can ' \
     'also have the genome of the parent not picked), so they are never to be added. Exact clones: copies plus ' \
     "crossovers with a parent's genome.", '',
     *table(['Run', 'Window', 'Generations', 'Bred children', 'Copies', 'Self-crossovers', 'Differs 0',
             "A parent's genome", 'Exact clones'],
            rows(runs) do |window|
              [window.bred, window.copies, window.self_crossovers, window.differs_zero, window.parent_genome,
               window.copies + window.parent_genome]
            end),
     '',
     'Crossovers outside that nesting (a self-crossover without differs 0, or differs 0 without a parent\'s ' \
     "genome): #{outside.join(', ')}."]
  end

  def no_weight_section(runs)
    ['## No network weight changed', '',
     'Counted apart from the clones, and neither as clones nor as not clones: mutation children whose differs ' \
     'count against their picked parent is 0, with no structural or activation change. No network weight ' \
     "changed; feature weights and genes may differ from the parent's (the feature-weight change is below); " \
     'whether they play like the parent is not measured. Per run and ' \
     "window, of each such child's largest feature-weight change against its picked parent (its fw_* columns " \
     "against the parent's, where both have one), the median and the maximum. stats' Copies column counts them.",
     '',
     *table(['Run', 'Window', 'Generations', 'Mutation children', 'No network weight changed',
             'Largest feature-weight change, median', 'Largest feature-weight change, maximum'],
            rows(runs) do |window|
              [window.mutations, window.no_weight, window.no_weight_median ? number(window.no_weight_median) : '—',
               window.no_weight_max ? number(window.no_weight_max) : '—']
            end)]
  end
end

if $PROGRAM_NAME == __FILE__
  usage = 'usage: scripts/gene-trajectories.rb [--window W] DATABASE...'
  width = 50
  begin
    paths = OptionParser.new(usage) do |options|
      options.on('--window W', Integer) { |value| width = value }
    end.parse(ARGV)
  rescue OptionParser::ParseError => e
    abort "#{e.message}\n#{usage}"
  end
  abort "window must be a whole number above 0\n#{usage}" unless width.positive?
  abort usage if paths.empty?

  begin
    runs = paths.map do |path|
      # Read-only, so a mistyped path fails instead of creating an empty
      # database inside an experiment.
      db = Sequel.sqlite(path, readonly: true, timeout: 5_000)
      GeneTrajectories.load(db, File.basename(File.dirname(File.expand_path(path))), width)
    rescue Sequel::DatabaseConnectionError => e
      abort "cannot open #{path}: #{e.message}"
    ensure
      db&.disconnect
    end
    print GeneTrajectories.report(runs)
  rescue GeneTrajectories::Refused => e
    abort e.message
  end
end
