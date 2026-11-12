#!/usr/bin/env ruby
# Describes several runs side by side from their recorded checkpoint
# champions, births and rankings alone (read-only; a run may still be
# running). Descriptive only: it prints no test, p-value or interval for a
# difference.
#
#   mise exec -- scripts/compare-runs.rb [--bots A,B,...] experiments/NAME/experiment.sqlite3...
#
# A run is named after its database's directory. Generations whose
# tournament did not finish (generations.round below tournament_rounds)
# are left out everywhere, and the report names them. It prints:
#
# - Ratings: one BenchmarkRatings fit over every run's champion-against-bot
#   games and the first run's bot-against-bot games. Each bot is one
#   player, shared by name across runs (refused unless every run stores
#   the same command for it); each run's champions are players of their
#   own, RUN:GenN. Games against Gen0Champion and GenNChampion are left
#   out: through them a champion's rating would depend on its run's later
#   champions. Identical champions with identical games therefore get
#   identical ratings.
# - Wins: per checkpoint, each champion's wins against the --bots (default
#   AmiGo, MichiWeak, MichiMid), with the binomial spread of one
#   champion's wins over another sample of openings and bot seeds; per run,
#   over the windows 500..1000 and 200..1000 (fixed in advance, none from
#   100, where the early jump dominates), the mean wins and the
#   least-squares slope with the residual spread, only for a run whose
#   complete checkpoints cover the window.
# - Given exactly two runs, their win differences per checkpoint.
# - For every pair of runs, where they diverge: the first generation whose
#   births differ, how many births they still share there, the last
#   generation with a shared birth, and the first whose rankings differ.
# - Per run, each champion's operator, and the checkpoints whose champion
#   has the same genome as a network it was benchmarked against.
require 'optparse'
require 'sequel'
require_relative '../ruby/benchmark_ratings'

module CompareRuns
  DEFAULT_BOTS = %w[AmiGo MichiWeak MichiMid].freeze
  # True of the default bots only: a bot outside them, such as an unpinned
  # GNU Go, need not replay its games alike (#132).
  REPLAYS = ' Replaying the same games would not move them: the openings repeat at every checkpoint, AmiGo plays ' \
            'deterministically, and the michi levels repeat for their seed.'.freeze
  # Fixed before any run was compared (plans: the elitism analysis).
  WINDOWS = [500..1000, 200..1000].freeze
  # A game's score for the ratings, as ExperimentStats scores it: 1 for the
  # champion (a champion's game) or for Black (a bots' game), 0 for the
  # other, a draw 1/2.
  CHAMPION_SCORES = { 'network' => 1, 'opponent' => 0, nil => 1 / 2r }.freeze
  BOT_SCORES = { 'black' => 1, 'white' => 0, nil => 1 / 2r }.freeze
  # A genome is a SHA-256 in hex; its first 15 digits (60 bits, so an
  # Integer without allocation) tell genomes apart, which keeps a run's
  # million births in memory. Two genomes that differ share them with
  # probability 2^-60.
  GENOME_DIGITS = 15

  # A run that cannot be compared.
  class Refused < StandardError; end

  # One generation's births (children and genome prefixes) or rankings
  # (players and scores), sorted by name.
  Roster = Data.define(:names, :values)
  EMPTY = Roster.new(names: [].freeze, values: [].freeze)

  # One run as stored: its finished generations (sorted), the unfinished
  # ones as [generation, round], the benchmark panel in stored order, the
  # finished generations' champion games and every bot game, births and
  # rankings per finished generation (Rosters), and per checkpoint the
  # champion: { network:, operator:, genome:, opponents: { name => genome } }.
  Run = Data.define(:name, :rounds, :keep_every, :benchmark_games, :finished, :unfinished, :panel,
                    :champion_games, :bot_games, :births, :rankings, :champions)

  # One checkpoint champion's results against the chosen bots: its wins,
  # its games (failed ones included), the failed ones, whether every game
  # is stored, and the 95 % half-width of the binomial spread of its wins.
  Wins = Data.define(:wins, :games, :failures, :complete, :spread)

  # A run's figures over a window of checkpoints: the mean wins, the
  # least-squares slope in wins per 100 generations, and the residual
  # standard deviation around the line (n - 2 degrees of freedom; nil below
  # three checkpoints, the slope nil below two).
  Window = Data.define(:range, :checkpoints, :mean, :slope, :residual_sd)

  # Where two runs diverge, over the finished generations both have
  # (`both`, sorted; the rest nil when it is empty). A generation's births
  # differ when a child's genome differs or a child is in one run only;
  # `shared_there` counts the births (same child, same genome) of the first
  # such generation. Rankings likewise, by player and score.
  Divergence = Data.define(:both, :births_differ, :shared_there, :last_shared, :rankings_differ)

  module_function

  def load(db, name)
    settings = db[:settings].to_hash(:key, :value)
    rounds = Integer(settings.fetch('tournament_rounds'))
    played = db[:generations].order(:generation).select_map(%i[generation round])
    finished = played.select { |_, round| round >= rounds }.map(&:first)
    kept = finished.to_h { |generation| [generation, true] }
    champion_games = db[:benchmark_games]
                     .select(:generation, :opponent, :opening, :network_color, :network, :opponent_network, :winner, :failure)
                     .order(:generation, :opponent, :opening, :network_color).all
                     .select { |game| kept[game[:generation]] }
    Run.new(name:, rounds:, keep_every: Integer(settings.fetch('keep_every')),
            benchmark_games: Integer(settings.fetch('benchmark_games')), finished:,
            unfinished: played.reject { |_, round| round >= rounds },
            panel: db[:benchmark_opponents].order(:position).select(:name, :kind, :command).all,
            champion_games:,
            bot_games: db[:benchmark_bot_games].select(:black, :white, :opening, :winner, :failure)
                                               .order(:black, :white, :opening).all,
            births: rosters(db[:births], :child, :genome, kept) { |genome| Integer(genome[0, GENOME_DIGITS], 16) },
            rankings: rosters(db[:rankings], :name, :score, kept, &:itself),
            champions: champions(db, champion_games))
  end

  # Per kept generation a Roster of `name` and `value` (turned by the
  # block). Consecutive generations with the same names share one Array.
  def rosters(dataset, name, value, kept)
    rows = Hash.new { |hash, generation| hash[generation] = [[], []] }
    dataset.select(:generation, name, value).order(:generation, name).naked.each do |row|
      next unless kept[row[:generation]]

      names, values = rows[row[:generation]]
      names << row[name]
      values << yield(row[value])
    end
    previous = nil
    rows.transform_values do |names, values|
      previous = names == previous ? previous : names.freeze
      Roster.new(names: previous, values: values.freeze)
    end
  end

  def champions(db, games)
    games.group_by { |game| game[:generation] }.to_h do |generation, rows|
      network, *others = rows.map { |row| row[:network] }.uniq
      raise Refused, "checkpoint #{generation} benchmarked #{[network, *others].join(' and ')}" unless others.empty?

      opponents = rows.filter_map { |row| row[:opponent_network] && [row[:opponent], row[:opponent_network]] }.uniq
                      .sort_by { |_, source| Integer(source.split(':').first) }
                      .to_h { |opponent, source| [opponent, birth(db, *source.split(':', 2)).fetch(:genome)] }
      [generation, birth(db, generation, network).merge(network:, opponents:)]
    end
  end

  def birth(db, generation, child)
    db[:births].where(generation: Integer(generation), child:).select(:operator, :genome).first ||
      raise(Refused, "no birth of #{child} in generation #{generation}")
  end

  def player(run, generation) = "#{run.name}:Gen#{generation}"

  # Every run's bots by name and command, refused where two runs store
  # different commands for one name.
  def bots(runs)
    commands = {}
    runs.each do |run|
      run.panel.each do |row|
        next unless row[:kind] == 'bot'

        command, first = commands[row[:name]] ||= [row[:command], run.name]
        next if command == row[:command]

        raise Refused, "bot #{row[:name]} is `#{command}` in #{first} but `#{row[:command]}` in #{run.name}"
      end
    end
    commands.transform_values(&:first)
  end

  def check(runs, chosen)
    duplicate = runs.map(&:name).tally.find { |_, count| count > 1 }
    raise Refused, "two runs are named #{duplicate.first}" if duplicate

    bots(runs)
    runs.each do |run|
      missing = chosen - run.panel.select { |row| row[:kind] == 'bot' }.map { |row| row[:name] }
      raise Refused, "#{run.name} has no benchmark bot #{missing.join(', ')}" unless missing.empty?
    end
  end

  # The fit's games: each run's champions against the bots (not against
  # champions), and the first run's bot-against-bot games. Failed games
  # have no winner and no place in it.
  def rating_games(runs)
    bots = bots(runs)
    champion_games = runs.flat_map do |run|
      run.champion_games.select { |game| bots.key?(game[:opponent]) && !game[:failure] }.map do |game|
        [player(run, game[:generation]), game[:opponent], CHAMPION_SCORES.fetch(game[:winner])]
      end
    end
    champion_games + runs.first.bot_games.reject { |game| game[:failure] }.map do |game|
      [game[:black], game[:white], BOT_SCORES.fetch(game[:winner])]
    end
  end

  # BenchmarkRatings rows by player, AmiGo (else the first run's first
  # bot) rated 0.
  def ratings(runs)
    anchor = BenchmarkRatings.anchor(runs.first.panel)
    BenchmarkRatings.new(rating_games(runs), anchor:).rows.to_h { |row| [row.player, row] }
  end

  # How `other`'s bot games compare with `first`'s, game by game (black,
  # white, opening): those with another result (winner, or failed or not),
  # those with a counterpart, and those without.
  def bot_agreement(first, other)
    reference = first.bot_games.to_h { |game| [game.values_at(:black, :white, :opening), game] }
    matched, unmatched = other.bot_games.partition { |game| reference.key?(game.values_at(:black, :white, :opening)) }
    result = ->(game) { [game[:winner], game[:failure].nil?] }
    another = matched.count { |game| result[game] != result[reference[game.values_at(:black, :white, :opening)]] }
    [another, matched.size, unmatched.size]
  end

  # The 95 % half-width of a champion's wins over another sample of
  # openings and bot seeds: the binomial spread summed over the bots, each
  # at the champion's win rate against it. `per_bot` lists [wins, games].
  def spread(per_bot)
    BenchmarkRatings::Z95 * Math.sqrt(per_bot.sum { |wins, games| games.zero? ? 0 : wins * (games - wins).fdiv(games) })
  end

  # Per checkpoint (sorted), the run's champion's Wins against `bots`.
  def wins(run, bots)
    games = run.champion_games.select { |game| bots.include?(game[:opponent]) }
    games.group_by { |game| game[:generation] }.sort.to_h do |generation, rows|
      won = rows.count { |game| game[:winner] == 'network' }
      per_bot = rows.reject { |game| game[:failure] }.group_by { |game| game[:opponent] }.values.map do |played|
        [played.count { |game| game[:winner] == 'network' }, played.size]
      end
      [generation, Wins.new(wins: won, games: rows.size, failures: rows.count { |game| game[:failure] },
                            complete: rows.size == bots.size * run.benchmark_games, spread: spread(per_bot))]
    end
  end

  # The mean, the least-squares slope per generation, and the residual
  # standard deviation of [x, y] points.
  def line(points)
    n = points.size
    mx = points.sum(&:first).fdiv(n)
    my = points.sum(&:last).fdiv(n)
    sxx = points.sum { |x, _| (x - mx)**2 }
    return [my, nil, nil] if n < 2

    slope = points.sum { |x, y| (x - mx) * (y - my) } / sxx
    residuals = points.sum { |x, y| (y - my - (slope * (x - mx)))**2 }
    [my, slope, n < 3 ? nil : Math.sqrt(residuals / (n - 2))]
  end

  # The run's Window over `range`, or nil unless every checkpoint the run's
  # keep_every puts in it is there and complete.
  def window(run, wins, range)
    return nil unless run.keep_every.positive?

    checkpoints = range.select { |generation| (generation % run.keep_every).zero? }
    return nil if checkpoints.empty? || !checkpoints.all? { |generation| wins[generation]&.complete }

    mean, slope, residual_sd = line(checkpoints.map { |generation| [generation, wins[generation].wins] })
    Window.new(range:, checkpoints: checkpoints.size, mean:, slope: slope && (100 * slope), residual_sd:)
  end

  # The births (or rankings) two Rosters share: same name, same value.
  def shared(a, b)
    return a.values.each_index.count { |i| a.values[i] == b.values[i] } if a.names == b.names

    other = b.names.each_index.to_h { |i| [b.names[i], b.values[i]] }
    a.names.each_index.count { |i| other.fetch(a.names[i], :none) == a.values[i] }
  end

  def differ?(a, b)
    common = shared(a, b)
    common < a.names.size || common < b.names.size
  end

  def divergence(a, b)
    both = a.finished & b.finished
    return Divergence.new(both:, births_differ: nil, shared_there: nil, last_shared: nil, rankings_differ: nil) if both.empty?

    births = ->(run, generation) { run.births.fetch(generation, EMPTY) }
    rankings = ->(run, generation) { run.rankings.fetch(generation, EMPTY) }
    births_differ = both.find { |generation| differ?(births[a, generation], births[b, generation]) }
    Divergence.new(both:, births_differ:,
                   shared_there: births_differ && shared(births[a, births_differ], births[b, births_differ]),
                   last_shared: both.reverse_each.find { |generation| shared(births[a, generation], births[b, generation]).positive? },
                   rankings_differ: both.find { |generation| differ?(rankings[a, generation], rankings[b, generation]) })
  end

  # Per checkpoint: [generation, the champion's operator, the opponents
  # whose genome equals the champion's].
  def self_benchmark(run)
    run.champions.sort.map do |generation, champion|
      [generation, champion[:operator], champion[:opponents].select { |_, genome| genome == champion[:genome] }.keys]
    end
  end

  def signed(value) = format('%+.1f', value.round(1) + 0.0)

  def table(header, rows)
    lines = ["| #{header.join(' | ')} |", "| --- |#{' ---: |' * (header.size - 1)}"]
    lines + rows.map { |row| "| #{row.join(' | ')} |" }
  end

  def report(runs, chosen = DEFAULT_BOTS)
    check(runs, chosen)
    [header(runs), rating_section(runs), wins_section(runs, chosen),
     (difference_section(runs, chosen) if runs.size == 2), divergence_section(runs), self_benchmark_section(runs)]
      .compact.map { |lines| lines.join("\n") }.join("\n\n") << "\n"
  end

  def header(runs)
    unfinished = runs.flat_map do |run|
      run.unfinished.map { |generation, round| "#{run.name} generation #{generation} (round #{round} of #{run.rounds})" }
    end
    ["Runs: #{runs.map(&:name).join(', ')}.",
     "Left out everywhere, their tournament unfinished: #{unfinished.empty? ? 'none' : unfinished.join(', ')}."]
  end

  def rating_section(runs)
    rows = ratings(runs)
    first = runs.first
    agreement = runs.drop(1).map do |run|
      another, matched, unmatched = bot_agreement(first, run)
      "#{run.name} #{another} of #{matched}#{"; #{unmatched} not in #{first.name}" if unmatched.positive?}"
    end
    checkpoints = runs.flat_map { |run| run.champion_games.map { |game| game[:generation] } }.uniq.sort
    panel_bots = bots(runs).keys
    complete = runs.to_h { |run| [run.name, wins(run, panel_bots).transform_values(&:complete)] }
    cell = lambda do |row, incomplete = false|
      next '—' unless row

      text = row.margin ? "#{row.rating} ± #{row.margin}" : row.rating.to_s
      incomplete ? "#{text}, incomplete" : text
    end
    bots = panel_bots.filter_map { |bot| rows[bot] }.sort_by { |row| [-row.rating, row.player] }
    ['## Ratings from the games against the bots', '',
     "One rating fit (BenchmarkRatings) over every run's champion-against-bot games and #{first.name}'s " \
     "bot-against-bot games, #{BenchmarkRatings.anchor(first.panel)} rated 0. Each bot is one player in all runs; " \
     "each run's champions are players of their own. Games against Gen0Champion and the GenNChampion opponents " \
     'are left out, so champions are linked only through the bots. The bots are rated from all given runs\' ' \
     "champions, so a champion's rating still moves with the other champions given, and ratings compare only " \
     'within one invocation of this script. ± is the 95 % half-width with the other ratings held fixed; a ' \
     'checkpoint missing some of its games against the bots is marked incomplete.',
     *(['', "Bot-against-bot games with another result than in #{first.name}: #{agreement.join(', ')}."] unless agreement.empty?),
     '', *table(['Checkpoint', *runs.map(&:name)],
                checkpoints.map do |generation|
                  [generation, *runs.map { |run| cell[rows[player(run, generation)], complete[run.name][generation] == false] }]
                end),
     '', *table(%w[Bot Rating], bots.map { |row| [row.player, cell[row]] })]
  end

  def wins_section(runs, chosen)
    wins = runs.to_h { |run| [run.name, wins(run, chosen)] }
    checkpoints = wins.values.flat_map(&:keys).uniq.sort
    cell = lambda do |result|
      next '—' unless result
      next "#{result.wins} of #{result.games}, incomplete" unless result.complete

      "#{result.wins} ± #{result.spread.round}"
    end
    failed = runs.filter_map do |run|
      count = wins[run.name].values.sum(&:failures)
      "#{run.name} #{count}" if count.positive?
    end
    windows = runs.flat_map do |run|
      WINDOWS.map do |range|
        w = window(run, wins[run.name], range)
        next [run.name, "#{range.begin}..#{range.end}", 'does not cover', '—', '—', '—'] unless w

        [run.name, "#{range.begin}..#{range.end}", w.checkpoints, format('%.1f', w.mean),
         w.slope ? signed(w.slope) : '—', w.residual_sd ? format('%.1f', w.residual_sd) : '—']
      end
    end
    ["## Wins against #{chosen.join(', ')}", '',
     "Per checkpoint, the champion's wins against these bots (games a checkpoint: " \
     "#{runs.map { |run| "#{run.name} #{chosen.size * run.benchmark_games}" }.join(', ')}). After ±, how far one " \
     "champion's wins would move over another sample of openings and bot seeds: the 95 % half-width of the binomial " \
     "spread, summed over the bots at the champion's own win rate against each.#{REPLAYS if (chosen - DEFAULT_BOTS).empty?}",
     *(['', "Failed games against these bots (no winner, so not wins; left out of the ratings): #{failed.join(', ')}."] unless failed.empty?),
     '', *table(['Checkpoint', *runs.map(&:name)],
                checkpoints.map { |generation| [generation, *runs.map { |run| cell[wins[run.name][generation]] }] }),
     '',
     'Per run and window, over its checkpoints: the mean wins, the least-squares slope in wins per 100 ' \
     'generations, and the residual standard deviation around that line. A slope describes a straight line ' \
     'over the window, not its shape. A run whose complete checkpoints do not cover the whole window gets no figures.',
     '', *table(['Run', 'Window', 'Checkpoints', 'Mean wins', 'Slope per 100 generations', 'Residual SD'], windows)]
  end

  def difference_section(runs, chosen)
    a, b = runs
    wins_a = wins(a, chosen)
    wins_b = wins(b, chosen)
    both = (wins_a.keys & wins_b.keys).select { |generation| wins_a[generation].complete && wins_b[generation].complete }
    ["## Differences, #{a.name} − #{b.name}", '',
     "Per checkpoint both runs have complete, the champions' wins against #{chosen.join(', ')} and their difference.",
     '', *table(['Checkpoint', a.name, b.name, 'Difference'], both.map do |generation|
       [generation, wins_a[generation].wins, wins_b[generation].wins, format('%+d', wins_a[generation].wins - wins_b[generation].wins)]
     end)]
  end

  def divergence_section(runs)
    rows = runs.combination(2).map do |a, b|
      d = divergence(a, b)
      next ["#{a.name}, #{b.name}", 'none', '—', '—', '—', '—'] if d.both.empty?

      ["#{a.name}, #{b.name}", "#{d.both.first}–#{d.both.last}", d.births_differ || 'never', d.shared_there || '—',
       d.last_shared || 'none', d.rankings_differ || 'never']
    end
    ['## Where the runs diverge', '',
     'Per pair of runs, over the finished generations both have: the first whose births differ (a child with ' \
     'another genome, or a child in one run only) and how many births (same child, same genome) the two still ' \
     'share there, the last generation with any shared birth, and the first whose rankings differ (a player with ' \
     'another score, or a player in one run only). A genome hashes the network file, which holds the genes too, so ' \
     'a different genome can mean different stored genes only (networks bred from the same draws): no shared ' \
     'birth does not mean no shared network play.',
     *(rows.empty? ? ['', 'One run: no pairs.'] : ['', *table(['Runs', 'Generations both have', 'Births first differ',
                                                                'Shared births there', 'Last shared birth',
                                                                'Rankings first differ'], rows)])]
  end

  def self_benchmark_section(runs)
    lines = runs.map do |run|
      checks = self_benchmark(run)
      pairs = checks.reject { |_, _, opponents| opponents.empty? }
                    .map { |generation, _, opponents| "#{generation} (#{opponents.join(', ')})" }
      "- #{run.name}: #{checks.map { |generation, operator, _| "#{generation} #{operator}" }.join(', ')}; " \
        "same genome as an opponent: #{pairs.empty? ? 'none' : pairs.join(', ')}"
    end
    ['## Champions benchmarked against themselves', '',
     "Per run, each checkpoint champion's operator (its birth), and the checkpoints whose champion has the same " \
     'genome as a network it was benchmarked against (Gen0Champion or a GenNChampion).', '', *lines]
  end
end

if $PROGRAM_NAME == __FILE__
  usage = 'usage: scripts/compare-runs.rb [--bots A,B,...] DATABASE...'
  bots = CompareRuns::DEFAULT_BOTS
  begin
    paths = OptionParser.new(usage) { |options| options.on('--bots A,B,...', Array) { |list| bots = list } }.parse(ARGV)
  rescue OptionParser::ParseError => e
    abort "#{e.message}\n#{usage}"
  end
  abort usage if paths.empty?

  begin
    runs = paths.map do |path|
      # Read-only, so a mistyped path fails instead of creating an empty
      # database inside an experiment.
      db = Sequel.sqlite(path, readonly: true, timeout: 5_000)
      CompareRuns.load(db, File.basename(File.dirname(File.expand_path(path))))
    rescue Sequel::DatabaseConnectionError => e
      abort "cannot open #{path}: #{e.message}"
    ensure
      db&.disconnect
    end
    print CompareRuns.report(runs, bots)
  rescue CompareRuns::Refused => e
    abort e.message
  end
end
