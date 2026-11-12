#!/usr/bin/env ruby
# Describes how strong each run's population was against the bots, what
# became of its elites, and how far the scores of networks that play two
# tournaments unchanged move, from every generation's births and final
# ranking (read-only). Descriptive only: it prints no test, p-value or
# interval.
#
#   mise exec -- scripts/population-strength.rb [--window W] experiments/NAME/experiment.sqlite3...
#
# A run is named after its database's directory. Generations whose
# tournament did not finish (generations.round below tournament_rounds) are
# left out everywhere, and the report names them. Generation 0 is a row of
# its own, then windows of W generations (default 50: 1–50, 51–100, …);
# every row says how many generations it holds. Elites are births with
# operator `elite`, never told from the elite_share setting, which schema
# 17 databases lack. Per run and window it prints:
#
# - Population against the bots: the share of networks whose score is
#   strictly above the mean score of the AmiGo, MichiWeak and MichiMid
#   copies (players.opponent), for all networks, the bred networks and the
#   elites alone.
# - Elites: their rank percentile among the networks, how many are carried
#   again, the longest chain of carries, and their bred children in the
#   next generation against those of the first 10 % of networks that are
#   not elites (counted as ExperimentStats#parents counts them).
# - Score retest: elites and exact clones (copies, crossovers with a
#   parent's genome) against their parent's score in the generation before.
require 'optparse'
require 'sequel'
require_relative '../ruby/elitism'

module PopulationStrength
  BOTS = %w[AmiGo MichiWeak MichiMid].freeze
  POPULATIONS = { all: 'All networks', bred: 'Bred networks', elites: 'Elites' }.freeze
  UNBRED = %w[initial elite].freeze
  COLUMNS = %i[generation child first_parent second_parent operator parent genome].freeze

  # A run that cannot be described.
  class Refused < StandardError; end

  # One kept generation: per population (:all, :bred, :elites) how many
  # networks and, per bot, how many are above the mean of its copies; the
  # elites' percentiles and chains; the elites' and the first tenth's
  # non-elite names; the [score before, score after] pairs of elites and of
  # exact clones. `followed` is set once the next generation is kept:
  # how many elites were carried again, and each elite's and each
  # first-tenth non-elite's bred children there.
  Generation = Struct.new(:generation, :networks, :above, :percentiles, :chains, :elites, :first_tenth,
                          :elite_pairs, :clone_pairs, :followed, keyword_init: true)

  # A run as described: its tournament rounds, the window width, its
  # unfinished generations as [generation, round], its elites in the kept
  # generations, and its kept Generations by window index.
  Run = Data.define(:name, :rounds, :width, :unfinished, :elites, :windows)

  module_function

  def load(db, name, width)
    rounds = Integer(db[:settings].where(key: 'tournament_rounds').get(:value))
    played = db[:generations].order(:generation).select_map(%i[generation round])
    kept = played.select { |_, round| round >= rounds }.to_h { |generation, _| [generation, true] }
    opponents = Hash.new { |hash, key| hash[key] = {} }
    db[:players].where(external: true).select_map(%i[generation name opponent]).each do |generation, player, opponent|
      opponents[generation][player] = opponent
    end
    records = []
    previous = nil
    births = []
    finish = lambda do
      return if births.empty?

      number = births.first[:generation]
      before = previous if previous && previous[:generation] == number - 1
      follow(before[:record], births) if before && before[:record] && kept[number]
      record = scores = nil
      if kept[number]
        ranking = db[:rankings].where(generation: number).order(:rank).select(:name, :score, :external).naked.all
        record = generation(number, births, ranking, opponents[number], before)
        records << record
        scores = ranking.to_h { |row| [row[:name], row[:score]] }
      end
      previous = { generation: number, births: births.to_h { |birth| [birth[:child], birth] }, scores:, record:,
                   chains: chains(births, before) }
      births = []
    end
    db[:births].select(*COLUMNS).order(:generation, :child).naked.each do |row|
      finish.call if births.any? && births.first[:generation] != row[:generation]
      births << row
    end
    finish.call
    Run.new(name:, rounds:, width:, unfinished: played.reject { |_, round| round >= rounds },
            elites: records.sum { |record| record.elites.size },
            windows: records.group_by { |record| window_index(record.generation, width) })
  end

  def window_index(generation, width) = generation.zero? ? 0 : ((generation - 1) / width) + 1

  def label(index, width) = index.zero? ? '0' : "#{((index - 1) * width) + 1}–#{index * width}"

  def picked(birth) = birth[:parent] == 'second' ? birth[:second_parent] : birth[:first_parent]

  def other(birth) = birth[:parent] == 'second' ? birth[:first_parent] : birth[:second_parent]

  # The first 10 % of a generation's networks, rounded as Elitism rounds a
  # share.
  def first_tenth(networks) = Elitism.count(1 / 10r, networks)

  # Per elite of the generation, how many generations in a row its network
  # has been carried, this one included.
  def chains(births, previous)
    births.select { |birth| birth[:operator] == 'elite' }.to_h do |birth|
      [birth[:child], 1 + (previous ? previous[:chains].fetch(birth[:first_parent], 0) : 0)]
    end
  end

  # Bred children per parent, as ExperimentStats#parents counts them: a
  # crossover for each of its distinct parents, a mutation or copy for the
  # parent it used.
  def children(births)
    births.reject { |birth| UNBRED.include?(birth[:operator]) }.flat_map do |birth|
      birth[:operator] == 'crossover' ? [birth[:first_parent], birth[:second_parent]].uniq : [picked(birth)]
    end.tally
  end

  def follow(record, births)
    return if record.elites.empty?

    counts = children(births)
    carried = births.select { |birth| birth[:operator] == 'elite' }.map { |birth| birth[:first_parent] }
    record.followed = { stay: record.elites.count { |elite| carried.include?(elite) },
                        elite_children: record.elites.map { |elite| counts.fetch(elite, 0) },
                        first_tenth_children: record.first_tenth.map { |name| counts.fetch(name, 0) } }
  end

  def generation(number, births, ranking, opponents, previous)
    operators = births.to_h { |birth| [birth[:child], birth[:operator]] }
    networks = ranking.reject { |row| row[:external] }
    networks.each do |row|
      raise Refused, "generation #{number}: network #{row[:name]} has no birth" unless operators.key?(row[:name])
    end
    position = networks.each_with_index.to_h { |row, i| [row[:name], i] }
    births.each do |birth|
      raise Refused, "generation #{number}: #{birth[:child]} is not ranked" unless position.key?(birth[:child])
    end
    means = BOTS.to_h do |bot|
      copies = ranking.select { |row| row[:external] && opponents[row[:name]] == bot }
      raise Refused, "generation #{number} has no copy of #{bot}" if copies.empty?

      [bot, copies.sum { |row| row[:score] }.fdiv(copies.size)]
    end
    members = { all: networks, bred: networks.reject { |row| UNBRED.include?(operators[row[:name]]) },
                elites: networks.select { |row| operators[row[:name]] == 'elite' } }
    elites = births.select { |birth| birth[:operator] == 'elite' }.map { |birth| birth[:child] }
    last = [networks.size - 1, 1].max
    chains = chains(births, previous)
    Generation.new(
      generation: number, networks: members.transform_values(&:size),
      above: members.transform_values { |rows| means.transform_values { |mean| rows.count { |row| row[:score] > mean } } },
      percentiles: elites.map { |elite| position[elite].fdiv(last) }, chains: elites.map { |elite| chains[elite] },
      elites:, first_tenth: networks.first(first_tenth(networks.size)).map { |row| row[:name] } - elites,
      **retest(number, births, ranking, previous)
    )
  end

  # The [score before, score after] pairs of the elites and the exact
  # clones, each against the parent whose genome it equals (the one it used
  # when both have it); none without a kept generation before.
  def retest(number, births, ranking, previous)
    pairs = { elite_pairs: [], clone_pairs: [] }
    return pairs unless previous && previous[:scores]

    scores = ranking.to_h { |row| [row[:name], row[:score]] }
    births.each do |birth|
      operator = birth[:operator]
      next unless %w[elite copy crossover].include?(operator)

      names = operator == 'elite' ? [birth[:first_parent]] : [picked(birth), other(birth)]
      source = names.find { |name| parent(number, birth, previous, name)[:genome] == birth[:genome] }
      unless source
        next if operator == 'crossover'

        which = operator == 'elite' ? "an elite, has not its parent's" : "a copy, has neither parent's"
        raise Refused, "generation #{number}: #{birth[:child]}, #{which} genome"
      end
      pair = [previous[:scores].fetch(source), scores.fetch(birth[:child])]
      pairs[operator == 'elite' ? :elite_pairs : :clone_pairs] << pair
    end
    pairs
  end

  def parent(number, birth, previous, name)
    previous[:births][name] ||
      raise(Refused, "generation #{number}: #{birth[:child]} has no parent #{name} in generation #{number - 1}")
  end

  def mean(values) = values.sum.fdiv(values.size)

  def median(values)
    sorted = values.sort
    (sorted[(sorted.size - 1) / 2] + sorted[sorted.size / 2]) / 2.0
  end

  # Pearson's correlation, nil below 2 pairs or without spread.
  def correlation(pairs)
    return nil if pairs.size < 2

    xs, ys = pairs.transpose
    mx = mean(xs)
    my = mean(ys)
    sxx = xs.sum { |x| (x - mx)**2 }
    syy = ys.sum { |y| (y - my)**2 }
    return nil if sxx.zero? || syy.zero?

    pairs.sum { |x, y| (x - mx) * (y - my) } / Math.sqrt(sxx * syy)
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
    [header(runs), bots_section(runs), elites_section(runs), retest_section(runs)]
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

  # One row per run and window: the run, the window, its generations, then
  # what the block gives for the window's Generations.
  def rows(runs)
    runs.flat_map do |run|
      run.windows.sort.map { |index, records| [run.name, label(index, run.width), records.size, *yield(records)] }
    end
  end

  # The runs with elites, after a line naming those without; or a line
  # saying no run has elites.
  def with_elites(runs)
    shown = runs.select { |run| run.elites.positive? }
    return ['No run has elites.'] if shown.empty?

    without = runs - shown
    [*(["Runs without elites: #{without.map(&:name).join(', ')}.", ''] unless without.empty?), *yield(shown)]
  end

  def bots_section(runs)
    lines = ['## Population against the bots', '',
             "Per run and window, the share of networks whose tournament score is strictly above the mean score of a bot's " \
             "copies in the same tournament, for #{BOTS[0..-2].join(', ')} and #{BOTS.last} (a bot's copies are the " \
             "players whose players.opponent names it), over the window's generations; a network whose score equals " \
             'the mean is not above it. Three populations: all networks, the bred networks (the initial population and ' \
             'the elites left out), and the elites alone.']
    POPULATIONS.each do |population, title|
      lines += ['', "### #{title}", '']
      table = lambda do |shown|
        table(['Run', 'Window', 'Generations', 'Networks', *BOTS.map { |bot| "Above #{bot}" }],
              rows(shown) do |records|
                networks = records.sum { |record| record.networks[population] }
                [networks, *BOTS.map do |bot|
                  networks.zero? ? '—' : share(records.sum { |record| record.above[population][bot] }, networks)
                end]
              end)
      end
      lines += population == :elites ? with_elites(runs, &table) : table[runs]
    end
    lines
  end

  def elites_section(runs)
    ['## Elites', '',
     "Per run with elites and window, of the elites carried into the window's generations (births with operator " \
     "elite), in the tournament they are carried into: their rank percentile among the generation's networks, mean " \
     "and median (the share of the generation's other networks before it in the stored ranking, so 0 is the first " \
     'network and 1 the last; bots left out); and the longest chain, the most generations in a row one network was ' \
     'carried as an elite, up to a generation of the window (counted from its first carry, which can lie in an ' \
     "earlier window). Of the elites whose next generation is kept (Elites followed; a run's last kept generation " \
     'has none): the share carried again into the next generation (Stay elite), and their mean number of bred ' \
     'children in the next generation, against the same mean for the networks of the same generations that are ' \
     "among the generation's first 10 % of networks by stored rank (0.1 times the networks, rounded, a half up, at " \
     'least 1; bots left out) and are not elites. Children are counted as stats counts them: a crossover once for ' \
     'each of its two distinct parents, a mutation or copy only for the parent it used (parent), never for both ' \
     'drawn parents.', '',
     *with_elites(runs) do |shown|
       table(['Run', 'Window', 'Generations', 'Elites', 'Mean percentile', 'Median percentile', 'Longest chain',
              'Elites followed', 'Stay elite', 'Children per elite', 'Top 10 % non-elites',
              'Children per top 10 % non-elite'],
             rows(shown) do |records|
               percentiles = records.flat_map(&:percentiles)
               chains = records.flat_map(&:chains)
               followed = records.filter_map(&:followed)
               elite_children = followed.flat_map { |f| f[:elite_children] }
               tenth_children = followed.flat_map { |f| f[:first_tenth_children] }
               [percentiles.size, *(percentiles.empty? ? %w[— —] : [number(mean(percentiles)), number(median(percentiles))]),
                chains.max || '—', elite_children.size,
                *(elite_children.empty? ? %w[— —] : [share(followed.sum { |f| f[:stay] }, elite_children.size),
                                                     number(mean(elite_children))]),
                tenth_children.size, tenth_children.empty? ? '—' : number(mean(tenth_children))]
             end)
     end]
  end

  def pair_cells(pairs)
    return %w[— — —] if pairs.empty?

    before, after = pairs.transpose
    [number(mean(before)), number(mean(after)), number(mean(pairs.map { |b, a| a - b }))]
  end

  def retest_section(runs)
    ['## Score retest', '',
     'Networks that play two tournaments unchanged: the elites, and the exact clones (births with operator copy, and ' \
     "crossovers whose genome equals a parent's). Per run and window, each one's tournament score against the " \
     'score, in the generation before, of the parent whose genome it equals (the parent it used when both parents ' \
     'have that genome): how many, the mean score before and after, and the mean change (after minus before); for ' \
     'the exact clones also the correlation of the scores before and after (Pearson; — below 2 or without spread). ' \
     "An elite's score before is its parent's, one of the previous generation's first networks by rank, so " \
     'those scores all lie near the top and a correlation would say nothing; the elites get none. Both compare two ' \
     "tournaments against different fields (the next generation's players), so neither the change nor the " \
     'correlation is a reliability coefficient of one tournament.',
     '', '### Elites', '',
     *with_elites(runs) do |shown|
       table(%w[Run Window Generations Elites] + ['Mean before', 'Mean after', 'Mean change'],
             rows(shown) do |records|
               pairs = records.flat_map(&:elite_pairs)
               [pairs.size, *pair_cells(pairs)]
             end)
     end,
     '', '### Exact clones', '',
     *table(['Run', 'Window', 'Generations', 'Exact clones', 'Mean before', 'Mean after', 'Mean change', 'Correlation'],
            rows(runs) do |records|
              pairs = records.flat_map(&:clone_pairs)
              correlation = correlation(pairs)
              [pairs.size, *pair_cells(pairs), correlation ? number(correlation) : '—']
            end)]
  end
end

if $PROGRAM_NAME == __FILE__
  usage = 'usage: scripts/population-strength.rb [--window W] DATABASE...'
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
      PopulationStrength.load(db, File.basename(File.dirname(File.expand_path(path))), width)
    rescue Sequel::DatabaseConnectionError => e
      abort "cannot open #{path}: #{e.message}"
    ensure
      db&.disconnect
    end
    print PopulationStrength.report(runs)
  rescue PopulationStrength::Refused => e
    abort e.message
  end
end
