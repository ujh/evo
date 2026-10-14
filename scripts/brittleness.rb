#!/usr/bin/env ruby
# The brittleness test: how a checkpoint champion's play changes when only
# its dense weights change (docs/experiment-reference.md, "How brittle a
# champion is"). Reads the experiment (read-only) and writes only to --out.
#
#   mise exec -- scripts/brittleness.rb EXPERIMENT GEN... --out DIR
#       [--steps 0.005,0.02,0.1,0.5] [--changes 229] [--children 32]
#       [--opponents AmiGo,MichiWeak,MichiMid] [--retest-games 600]
#       [--concurrency N] [--accept-failures]
#   mise exec -- scripts/brittleness.rb --report-only --out DIR [EXPERIMENT [GEN...]]
#
# For each generation the champion's children (evolve/perturb, one seed
# each) at every step size, plus a replay of the champion, play the
# champion's benchmark games (screen); the best and as many random control
# children of each step, and the champion, then play the same fresh games
# (re-test). Results go to DIR/results.sqlite3; a second invocation resumes.
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'sequel'
require_relative '../ruby/checkpoint_benchmark'
require_relative '../ruby/experiment_database'
require_relative '../ruby/game_result'
require_relative '../ruby/openings'
require_relative '../ruby/progress_line'
require_relative '../ruby/seeds'
require_relative '../ruby/setup_experiment'
require_relative '../ruby/worker_pool'

module Brittleness
  # A refusal: bad options, a directory in use or holding other options,
  # an experiment that cannot be tested.
  class Refused < StandardError; end

  # A game came back interrupted, or Ctrl-C was pressed: nothing after it
  # is stored, and the same command resumes.
  class Interrupted < StandardError; end

  PERTURB = File.expand_path('../evolve/perturb', __dir__)
  DEFAULT_STEPS = %w[0.005 0.02 0.1 0.5].freeze
  DEFAULT_OPPONENTS = %w[AmiGo MichiWeak MichiMid].freeze
  COLORS = %w[black white].freeze
  PHASES = %w[screen retest].freeze
  # The weight step range of the genes (lib/ann.h), which perturb takes.
  STEP_RANGE = (1e-4..10.0)
  # The label of the champion's own genes as a step.
  OWN = 'own'.freeze
  # The child of the champion's replay, under the step CHAMPION.
  REPLAY = 'replay'.freeze
  CHAMPION_STEP = 'champion'.freeze
  # In the work directory, which twogtp runs in, so the network command is
  # ../evo as in the benchmark.
  PLAYERS = 'players'.freeze
  GAMES = 'games'.freeze
  OPENINGS = 'openings'.freeze
  RESULTS = 'results.sqlite3'.freeze
  LOCK = 'brittleness.lock'.freeze

  Options = Data.define(:experiment, :generations, :steps, :changes, :children, :opponents, :retest_games,
                        :concurrency, :accept_failures, :report_only, :out) do
    def self.parse(argv)
      given = { steps: DEFAULT_STEPS, changes: 229.0, children: 32, opponents: DEFAULT_OPPONENTS, retest_games: 600,
                concurrency: 2, accept_failures: false, report_only: false, out: nil }
      parser = OptionParser.new do |o|
        o.banner = 'Usage: scripts/brittleness.rb EXPERIMENT GEN... --out DIR [options] | --report-only --out DIR [EXPERIMENT [GEN...]]'
        o.on('--steps LIST', 'Fixed weight steps, comma-separated') { |v| given[:steps] = Brittleness.step_labels(v) }
        o.on('--changes N', 'Weight changes of every fixed step') { |v| given[:changes] = number(v, '--changes', 1.0) }
        o.on('--children N', 'Children per step') { |v| given[:children] = whole(v, '--children', 1) }
        o.on('--opponents LIST', 'Benchmark bots, comma-separated') { |v| given[:opponents] = v.split(',') }
        o.on('--retest-games N', 'Re-test games per player') { |v| given[:retest_games] = whole(v, '--retest-games', 1) }
        o.on('--concurrency N', 'Games at once (may change between resumes)') { |v| given[:concurrency] = whole(v, '--concurrency', 1) }
        o.on('--accept-failures', 'Choose the re-tested children although screen games failed (as losses)') do
          given[:accept_failures] = true
        end
        o.on('--report-only', 'Print the report from DIR alone') { given[:report_only] = true }
        o.on('--out DIR', 'Output directory') { |v| given[:out] = v }
      end
      begin
        experiment, *generations = parser.parse(argv)
      rescue OptionParser::ParseError => e
        raise Refused, "#{e.message}\n#{parser.banner}"
      end
      raise Refused, "--out is required\n#{parser.banner}" unless given[:out]
      unless given[:report_only] || (experiment && !generations.empty?)
        raise Refused, "an experiment and at least one generation are required\n#{parser.banner}"
      end

      generations = generations.map { |g| whole(g, 'a generation', 0) }
      raise Refused, 'a generation is given twice' if generations.uniq.size < generations.size
      raise Refused, 'an opponent is given twice' if given[:opponents].uniq.size < given[:opponents].size

      split = 2 * given[:opponents].size
      unless (given[:retest_games] % split).zero?
        raise Refused, "--retest-games must be divisible by #{split} (both colours of #{given[:opponents].size} opponents)"
      end

      experiment &&= File.expand_path(File.directory?(experiment) ? experiment : File.join('experiments', experiment))
      new(experiment:, generations:, **given, out: File.expand_path(given[:out]))
    end

    def self.whole(text, name, min)
      value = Integer(text, 10, exception: false)
      raise Refused, "#{name} must be a whole number of at least #{min}, got #{text}" unless value && value >= min

      value
    end

    def self.number(text, name, min)
      value = Float(text, exception: false)
      raise Refused, "#{name} must be a number of at least #{min}, got #{text}" unless value&.finite? && value >= min

      value
    end

    def name = experiment && File.basename(experiment)

    # What a run's results depend on, which a directory keeps for each
    # (experiment, generation); --concurrency is not one of them.
    def run_options
      { 'steps' => steps, 'changes' => changes, 'children' => children, 'opponents' => opponents,
        'retest_games' => retest_games }
    end
  end

  # A step size of the children: a fixed step with --changes weight
  # changes, or the champion's own genes.
  Step = Data.define(:label, :weight_changes, :weight_step)

  # One player: the champion's replay (child REPLAY) or a child, an index.
  Player = Data.define(:step, :weight_changes, :weight_step, :child) do
    def replay? = child == REPLAY
    def key = [step, weight_changes, weight_step, child.to_s]
    def file_name(generation) = replay? ? "#{generation}-champion.ann" : "#{key.unshift(generation).join('-')}.ann"
  end

  CHAMPION = Player.new(step: CHAMPION_STEP, weight_changes: 0.0, weight_step: 0.0, child: REPLAY)

  # One game of a player, the network playing `color` against the bot
  # `opponent` (its name) on opening `opening`. Its prefix names its files
  # uniquely: twogtp does not play a game whose .dat exists.
  Game = Data.define(:generation, :phase, :player, :opponent, :opening, :color) do
    def key = [phase, *player.key, opponent, opening, color]
    def game_key = [opponent, opening, color]
    def prefix = File.join(GAMES, [generation, phase, *player.key, opponent, opening, color].join('-'))
  end

  module_function

  # Each step's label is its value as Ruby prints it, so 0.50 and 0.5 are
  # one step (the label goes into the children's seeds).
  def step_labels(text)
    values = text.split(',').map do |part|
      value = Float(part, exception: false)
      raise Refused, "--steps takes numbers in #{STEP_RANGE}, got #{part}" unless value && STEP_RANGE.cover?(value)

      value
    end
    labels = values.map(&:to_s)
    raise Refused, 'a step is given twice' if labels.uniq.size < labels.size

    labels
  end

  # The fixed steps, each with `changes` weight changes, then `own`, the
  # champion's genes (weight_changes, weight_step), unless they are a fixed
  # step's: a fixed-gene champion's children at its own genes are that
  # step's in distribution.
  def steps(labels, changes, own)
    fixed = labels.map { |label| Step.new(label:, weight_changes: changes, weight_step: Float(label)) }
    own_changes, own_step = own
    same = fixed.any? do |step|
      (own_step - step.weight_step).abs <= 1e-6 * step.weight_step && (own_changes - changes).abs <= 0.01 * changes
    end
    same ? fixed : fixed + [Step.new(label: OWN, weight_changes: own_changes, weight_step: own_step)]
  end

  def retested_per_step(children) = (children / 10.0).ceil

  # The champion's re-tested best children, the sign test's Bonferroni m.
  def bonferroni_m(steps, children) = steps.size * retested_per_step(children)

  # weight_changes and weight_step from a network's .ann bytes (lib/ann.h:
  # the magic, the version, four sizes and two activation codes come first,
  # then copy_chance and these two).
  def genes(bytes)
    raise Refused, 'the champion is not an .ann network' unless bytes.start_with?('EVOANN') && bytes.bytesize >= 58

    bytes.byteslice(42, 16).unpack('E2')
  end

  # The checkpoint's benchmark games of the given opponents: each opening
  # with both colours.
  def screen_keys(opponents, openings)
    opponents.product((0...openings).to_a, COLORS)
  end

  # The re-test's games, ordered by opening, then colour, then opponent,
  # so any prefix covers every opponent equally.
  def retest_keys(retest_games, opponents)
    openings = retest_games / (2 * opponents.size)
    (0...openings).to_a.product(COLORS, opponents).map { |opening, color, opponent| [opponent, opening, color] }
  end

  # The `count` children with the highest screen difference (ties: lower
  # index), and as many controls drawn with `seed` from the rest.
  def select_retest(differences, count, seed)
    best = differences.keys.sort_by { |child| [-differences[child], child] }.first(count)
    rest = (differences.keys - best).sort
    { best:, controls: rest.sample([count, rest.size].min, random: Random.new(seed)).sort }
  end

  # A game's moves from its SGF, so identical games can be told apart from
  # games that only end alike.
  def moves_hash(sgf)
    Digest::SHA256.hexdigest(sgf.scan(/;[BW]\[[a-z]*\]/).join)[0, 16]
  end

  # The statistics of the report.
  module Stats
    module_function

    def mean(values) = values.sum.fdiv(values.size)

    def variance(values)
      m = mean(values)
      values.sum { |v| (v - m)**2 } / (values.size - 1).to_f
    end

    # The parts of a children × games table (rows of 0/1 per game, n ≥ 2,
    # at least 2 games) that the crossed formula takes: each game's mean
    # over the children, the variance of the children's totals, and the
    # two-way ANOVA's residual mean square.
    def parts(rows)
      n = rows.size
      games = rows.first.size
      game_means = (0...games).map { |j| rows.sum { |row| row[j] }.fdiv(n) }
      totals = rows.map(&:sum)
      child_means = totals.map { |t| t.fdiv(games) }
      grand = mean(child_means)
      sse = rows.each_with_index.sum do |row, i|
        row.each_with_index.sum { |y, j| (y - game_means[j] - child_means[i] + grand)**2 }
      end
      { n:, game_means:, s_t2: variance(totals), mse: sse / ((n - 1) * (games - 1)).to_f }
    end

    # Var(mean_A − mean_B) of the children's totals for children × games
    # data on the same games: s_TA²/n_A + s_TB²/n_B + N·max(0,
    # var_g(ȳA_g − ȳB_g) − MSE_A/n_A − MSE_B/n_B). `b` is rows too, or one
    # player's results (the champion's), whose s_T² and MSE terms drop.
    def crossed_variance(a, b)
      pa = parts(a)
      children = pa[:s_t2] / pa[:n]
      noise = pa[:mse] / pa[:n]
      if b.first.is_a?(Array)
        pb = parts(b)
        children += pb[:s_t2] / pb[:n]
        noise += pb[:mse] / pb[:n]
        b_means = pb[:game_means]
      else
        b_means = b
      end
      z = pa[:game_means].zip(b_means).map { |x, y| x - y }
      children + (z.size * [variance(z) - noise, 0].max)
    end

    # C(n, 0), ..., C(n, n).
    def coefficients(n)
      c = 1
      (0..n).map do |i|
        value = c
        c = c * (n - i) / (i + 1)
        value
      end
    end

    # P(Bin(n, ½) ≥ k), exactly.
    def sign_tail(n, k)
      return Rational(1) if k <= 0
      return Rational(0) if k > n

      Rational(coefficients(n)[k..].sum, 2**n)
    end

    # The fewest wins among n discordant games with which the child is
    # better at level alpha (n + 1 when none): the smallest k with
    # sign_tail(n, k) ≤ alpha, summed from the top.
    def critical(n, alpha)
      row = coefficients(n)
      limit = alpha * (2**n)
      tail = 0
      k = n + 1
      while k.positive? && tail + row[k - 1] <= limit
        tail += row[k - 1]
        k -= 1
      end
      k
    end

    # P(Bin(n, p) ≥ k).
    def binomial_tail(n, k, p)
      return k <= n ? 1.0 : 0.0 if p >= 1
      return k <= 0 ? 1.0 : 0.0 if p <= 0

      (k..n).sum do |i|
        Math.exp(Math.lgamma(n + 1)[0] - Math.lgamma(i + 1)[0] - Math.lgamma(n - i + 1)[0] +
                 (i * Math.log(p)) + ((n - i) * Math.log(1 - p)))
      end
    end

    # The smallest effect δ (a share of the re-test's games) the sign test
    # detects with probability `power`, from a discordance rate d over
    # `games` re-test games: n_d = round(d × games) discordant games, of
    # which the child wins each with probability (1 + δ/d) / 2. nil when no
    # δ ≤ d is detected (or nothing is discordant).
    def mde(d, games, alpha, power)
      discordant = (d * games).round
      return nil if discordant.zero?

      needed = critical(discordant, alpha)
      return nil if needed > discordant

      low = 0.0
      high = d
      60.times do
        mid = (low + high) / 2
        binomial_tail(discordant, needed, (1 + (mid / d)) / 2) >= power ? high = mid : low = mid
      end
      high
    end

    # nil below three pairs (two always give ±1) or without spread.
    def pearson(xs, ys)
      return nil if xs.size < 3

      mx = mean(xs)
      my = mean(ys)
      sx = xs.sum { |x| (x - mx)**2 }
      sy = ys.sum { |y| (y - my)**2 }
      return nil if sx.zero? || sy.zero?

      xs.zip(ys).sum { |x, y| (x - mx) * (y - my) } / Math.sqrt(sx * sy)
    end
  end

  # DIR/results.sqlite3: per game a row keyed by (experiment, generation,
  # phase, step, weight_changes, weight_step, child, opponent, opening,
  # color); per (experiment, generation) the options (runs), the
  # champion's stored benchmark games, the children perturb made, and the
  # re-test's selection.
  class Results
    KEY = %i[experiment generation phase step weight_changes weight_step child opponent opening color].freeze

    # The layout this script writes; a directory with another (or none,
    # from before the version) is refused, not converted.
    VERSION = 2

    def initialize(path, readonly: false)
      @db = Sequel.sqlite(path, readonly:, timeout: 5_000)
      if @db.tables.empty? && !readonly
        create_tables
        return
      end

      version = @db.tables.include?(:version) ? @db[:version].get(:version) : nil
      return if version == VERSION

      @db.disconnect
      raise Refused, "#{File.dirname(path)} was written by an older brittleness.rb; use a new --out"
    end

    def close = @db.disconnect

    # Refuses options other than those stored for the (experiment,
    # generation); stores them, with the champion, the first time.
    def check_run(experiment, generation, options, champion:, own:)
      row = @db[:runs].where(experiment:, generation:).first
      if row
        stored = JSON.parse(row[:options])
        if stored != options || row[:champion] != champion
          raise Refused, "#{experiment} generation #{generation} was run with other options in this directory " \
                         "(stored: #{stored.to_json}, champion #{row[:champion]}; given: #{options.to_json}, " \
                         "champion #{champion}); use another --out"
        end
        return
      end
      @db[:runs].insert(experiment:, generation:, options: options.to_json, champion:,
                        own_weight_changes: own[0], own_weight_step: own[1])
    end

    def runs = @db[:runs].order(:experiment, :generation).all

    # The champion's benchmark games as the experiment stored them, so the
    # report needs only this directory.
    def save_champion_games(experiment, generation, rows)
      @db.transaction do
        @db[:champion_games].where(experiment:, generation:).delete
        @db[:champion_games].multi_insert(rows.map do |row|
          { experiment:, generation:, opponent: row[:opponent], opening: row[:opening], color: row[:network_color],
            winner: row[:winner], failure: row[:failure], length: row[:length], referee_result: row[:referee_result] }
        end)
      end
    end

    def champion_games(experiment, generation)
      @db[:champion_games].where(experiment:, generation:).order(:opponent, :opening, :color).all
    end

    def record_child(experiment, generation, player, seed:, differs:)
      @db[:children].insert_conflict(:replace).insert(experiment:, generation:, step: player.step,
                                                      weight_changes: player.weight_changes,
                                                      weight_step: player.weight_step, child: player.child, seed:,
                                                      differs:)
    end

    def children(experiment, generation) = @db[:children].where(experiment:, generation:).all

    # The re-tested children, and how many screen games had failed when
    # they were chosen (only with --accept-failures, else 0).
    def record_selection(experiment, generation, rows, screen_failures: 0)
      @db.transaction do
        @db[:selections].multi_insert(rows.map { |row| { experiment:, generation:, **row } })
        @db[:selection_failures].insert(experiment:, generation:, screen_failures:)
      end
    end

    def selection_failures(experiment, generation)
      @db[:selection_failures].where(experiment:, generation:).get(:screen_failures) || 0
    end

    def selections(experiment, generation)
      @db[:selections].where(experiment:, generation:).order(:step, :role, :child).all
    end

    # A replayed game replaces its row.
    def record_game(experiment, game, **result)
      player = game.player
      @db[:games].insert_conflict(:replace).insert(
        experiment:, generation: game.generation, phase: game.phase, step: player.step,
        weight_changes: player.weight_changes, weight_step: player.weight_step, child: player.child.to_s,
        opponent: game.opponent, opening: game.opening, color: game.color, **result
      )
    end

    def games(experiment, generation, phase = nil)
      rows = @db[:games].where(experiment:, generation:)
      rows = rows.where(phase:) if phase
      rows.all
    end

    private

    def create_tables
      @db.create_table(:version) { Integer :version, null: false }
      @db[:version].insert(version: VERSION)
      @db.create_table?(:runs) do
        String :experiment, null: false
        Integer :generation, null: false
        String :options, null: false
        String :champion, null: false
        Float :own_weight_changes, null: false
        Float :own_weight_step, null: false
        primary_key %i[experiment generation]
      end
      @db.create_table?(:champion_games) do
        String :experiment, null: false
        Integer :generation, null: false
        String :opponent, null: false
        Integer :opening, null: false
        String :color, null: false
        String :winner
        String :failure
        Integer :length
        String :referee_result
        primary_key %i[experiment generation opponent opening color]
      end
      @db.create_table?(:children) do
        String :experiment, null: false
        Integer :generation, null: false
        String :step, null: false
        Float :weight_changes, null: false
        Float :weight_step, null: false
        Integer :child, null: false
        Integer :seed, null: false
        Integer :differs, null: false
        primary_key %i[experiment generation step weight_changes weight_step child]
      end
      @db.create_table?(:selections) do
        String :experiment, null: false
        Integer :generation, null: false
        String :step, null: false
        Float :weight_changes, null: false
        Float :weight_step, null: false
        Integer :child, null: false
        String :role, null: false
        Integer :screen_difference, null: false
        primary_key %i[experiment generation step weight_changes weight_step child]
      end
      @db.create_table?(:selection_failures) do
        String :experiment, null: false
        Integer :generation, null: false
        Integer :screen_failures, null: false
        primary_key %i[experiment generation]
      end
      @db.create_table?(:games) do
        String :experiment, null: false
        Integer :generation, null: false
        String :phase, null: false
        String :step, null: false
        Float :weight_changes, null: false
        Float :weight_step, null: false
        String :child, null: false
        String :opponent, null: false
        Integer :opening, null: false
        String :color, null: false
        String :winner
        String :failure
        Integer :length
        String :referee_result
        String :moves_hash
        Float :duration
        primary_key KEY
      end
    end
  end

  # One generation's champion and what it plays.
  Champion = Data.define(:generation, :name, :path, :own, :steps, :screen_keys, :stored_games)

  # Plays the screen and the re-test of an experiment's generations, in
  # DIR/NAME/work (twogtp's directory, emptied on every start), resuming
  # from DIR/results.sqlite3.
  class Run
    include ProgressLine

    # `pool` runs the games (a WorkerPool of --concurrency threads);
    # `perturb` is the program that makes a child.
    def initialize(options, pool:, perturb: PERTURB)
      @options = options
      @pool = pool
      @perturb = perturb
      @stopping = false
    end

    # For the Ctrl-C trap: no game is stored or started after it. Only sets
    # flags, so it is safe in a trap.
    def stop!
      @stopping = true
      @pool.halt
    end

    def call
      FileUtils.mkdir_p(options.out)
      @lock = File.open(File.join(options.out, LOCK), File::RDWR | File::CREAT, 0o644)
      raise Refused, "another brittleness run is using #{options.out}" unless @lock.flock(File::LOCK_EX | File::LOCK_NB)

      open_experiment
      reset_work_directory
      @results = Results.new(File.join(options.out, RESULTS))
      champions = Dir.chdir(work) { options.generations.map { |generation| champion(generation) } }
      champions.each do |c|
        @results.check_run(options.name, c.generation, options.run_options, champion: c.name, own: c.own)
      end
      Dir.chdir(work) do
        champions.each do |c|
          @results.save_champion_games(options.name, c.generation, c.stored_games)
          play_generation(c)
        end
      end
    ensure
      @results&.close
      @store&.close
      @lock&.close
    end

    private

    attr_reader :options, :pool, :settings

    def work = File.join(options.out, options.name, 'work')

    def open_experiment
      database = File.join(options.experiment, 'experiment.sqlite3')
      raise Refused, "#{options.experiment} has no experiment.sqlite3" unless File.exist?(database)
      raise Refused, "#{options.experiment} has no evo" unless File.exist?(File.join(options.experiment, 'evo'))

      @store = ExperimentDatabase.new(database, readonly: true)
      @settings = SetupExperiment.parse(@store.settings)
      @panel = @store.benchmark_opponents.to_h { |row| [row[:name], row] }
      options.opponents.each do |name|
        raise Refused, "#{name} is not a bot of the benchmark panel" unless @panel.dig(name, :kind) == 'bot'
      end
    end

    # Empties the work directory, so no game file twogtp would not replay
    # over and no temporary file of perturb is left, and copies the
    # experiment's evo next to it, which every player runs.
    def reset_work_directory
      FileUtils.rm_rf(work)
      [PLAYERS, GAMES, OPENINGS].each { |dir| FileUtils.mkdir_p(File.join(work, dir)) }
      FileUtils.cp(File.join(options.experiment, 'evo'), File.join(options.out, options.name, 'evo'), preserve: true)
    end

    # The generation's champion, exported into players/, and its stored
    # benchmark games, which every screen game pairs with.
    def champion(generation)
      entry = @store.ranking(generation).find { |row| !row[:external] }
      raise Refused, "generation #{generation} has no ranked network" unless entry

      path = File.join(PLAYERS, CHAMPION.file_name(generation))
      @store.export_network(generation, entry[:name], path) or
        raise Refused, "generation #{generation} has no stored network #{entry[:name]}"
      own = Brittleness.genes(File.binread(path))
      keys = Brittleness.screen_keys(options.opponents, settings['benchmark_games'] / 2)
      stored = @store.benchmark_games(generation).select { |row| options.opponents.include?(row[:opponent]) }
      missing = keys - stored.map { |row| row.values_at(:opponent, :opening, :network_color) }
      unless missing.empty?
        raise Refused, "generation #{generation}'s benchmark lacks #{missing.size} of the #{keys.size} games " \
                       "against #{options.opponents.join(', ')}"
      end
      Champion.new(generation:, name: entry[:name], path:, own:, steps: Brittleness.steps(options.steps, options.changes, own),
                   screen_keys: keys, stored_games: stored)
    end

    def play_generation(champion)
      children = champion.steps.flat_map do |step|
        (0...options.children).map do |child|
          Player.new(step: step.label, weight_changes: step.weight_changes, weight_step: step.weight_step, child:)
        end
      end
      write_openings('screen', settings['benchmark_games'] / 2)
      play(champion, 'screen', [CHAMPION, *children], champion.screen_keys)
      # A failure counts as a loss, which would bias the selection: the
      # re-test waits until a later run has replayed every failure, or
      # --accept-failures takes the failures as losses. Once chosen, the
      # children stay.
      # The replay's failures do not count: the selection compares with
      # the champion's stored games.
      failed = @results.games(options.name, champion.generation, 'screen').count do |row|
        row[:failure] && row[:child] != REPLAY
      end
      chosen = @results.selections(options.name, champion.generation).any?
      if failed.positive? && !chosen && !options.accept_failures
        puts "Generation #{champion.generation}: #{failed} screen games failed; the re-test waits until they are " \
             'replayed. Run the same command again, and add --accept-failures if the same games keep failing ' \
             '(they then count as losses).'
        return
      end

      retest = selection(champion, failed)
      keys = Brittleness.retest_keys(options.retest_games, options.opponents)
      write_openings('retest', keys.map { |_, opening, _| opening }.max + 1)
      play(champion, 'retest', [CHAMPION, *retest], keys)
    end

    # The re-tested children, chosen once from the complete screen and
    # stored, so a resume re-tests the same ones.
    def selection(champion, failed)
      stored = @results.selections(options.name, champion.generation)
      if stored.empty?
        stored = choose_retest(champion)
        @results.record_selection(options.name, champion.generation, stored, screen_failures: failed)
      end
      stored.map do |row|
        Player.new(step: row[:step], weight_changes: row[:weight_changes], weight_step: row[:weight_step], child: row[:child])
      end
    end

    def choose_retest(champion)
      champion_wins = champion.stored_games.count { |row| row[:winner] == 'network' }
      wins = Hash.new(0)
      @results.games(options.name, champion.generation, 'screen').each do |row|
        wins[[row[:step], row[:child]]] += 1 if row[:winner] == 'network'
      end
      champion.steps.flat_map do |step|
        differences = (0...options.children).to_h { |child| [child, wins[[step.label, child.to_s]] - champion_wins] }
        seed = Seeds.derive(settings.fetch('seed'), 'brittleness-controls', options.name, champion.generation, step.label)
        picked = Brittleness.select_retest(differences, Brittleness.retested_per_step(options.children), seed)
        %i[best controls].flat_map do |role|
          picked[role].map do |child|
            { step: step.label, weight_changes: step.weight_changes, weight_step: step.weight_step, child:,
              role: role == :best ? 'best' : 'control', screen_difference: differences[child] }
          end
        end
      end
    end

    # Writes every opening of the phase before any game is submitted: a
    # twogtp that reads an opening while it is rewritten fails.
    def write_openings(phase, count)
      (0...count).each do |index|
        moves = opening_moves(phase, index)
        Openings.write(File.join(OPENINGS, phase, index.to_s), settings['board_size'], moves) unless moves.empty?
      end
    end

    # The screen's openings are the benchmark's; the re-test's come from a
    # derived seed, since Openings.moves labels its own seed.
    def opening_moves(phase, index)
      seed = settings.fetch('seed')
      seed = Seeds.derive(seed, 'brittleness-retest') if phase == 'retest'
      Openings.moves(seed, index, settings['board_size'], settings['benchmark_opening_moves'])
    end

    # Plays each player's games of the phase that have no row or a failure
    # row, a player's games together, a child's file made just before its
    # games and deleted once they are stored.
    def play(champion, phase, players, keys)
      stored = @results.games(options.name, champion.generation, phase).to_h do |row|
        [[phase, *Results::KEY.drop(3).map { |column| row[column] }], row]
      end
      queue = players.filter_map do |player|
        games = keys.map do |opponent, opening, color|
          Game.new(generation: champion.generation, phase:, player:, opponent:, opening:, color:)
        end
        games = games.select { |game| (row = stored[game.key]).nil? || row[:failure] }
        [player, games] unless games.empty?
      end
      total = queue.sum { |_, games| games.size }
      return if total.zero?

      label = "Generation #{champion.generation} #{phase}"
      show("#{label}: starting #{total} games ...")
      running = 0
      left = Hash.new(0)
      total.times do |done|
        # Two players' games at most are queued, so at most two children's
        # files exist, and the pool never runs dry between players.
        while !queue.empty? && running < 2 * options.concurrency
          player, games = queue.shift
          path = build(champion, player)
          games.each do |game|
            remove_files(game.prefix)
            pool.submit(command(game, path), game)
          end
          left[player] += games.size
          running += games.size
        end
        game, duration, status = pool.next_finished
        running -= 1
        # As in the runner: after Ctrl-C nothing is stored, also a game
        # back before the trap ran, since its players may have been killed.
        raise Interrupted if @stopping
        if WorkerPool.interrupted?(status)
          warn "\n#{game.prefix} was interrupted; it stays pending."
          raise Interrupted
        end

        store_game(game, duration)
        File.delete(path_of(champion, game.player)) if (left[game.player] -= 1).zero? && !game.player.replay?
        show("#{label} ... Game: #{done + 1}/#{total}")
      end
      end_line("#{label} ... done")
    end

    def path_of(champion, player) = File.join(PLAYERS, player.file_name(champion.generation))

    # The champion's file, or a child made by perturb from it with the
    # child's own seed.
    def build(champion, player)
      return champion.path if player.replay?

      path = path_of(champion, player)
      seed = Seeds.derive(settings.fetch('seed'), 'brittleness', options.name, champion.generation, player.step, player.child)
      stdout, stderr, status = Open3.capture3(@perturb, champion.path, path, player.weight_changes.to_s,
                                              player.weight_step.to_s, seed.to_s)
      raise Interrupted if @stopping

      differs = stdout[/\Adiffers=(\d+)\n\z/, 1] if status.success?
      raise Refused, "perturb failed for #{path}: #{stderr.strip}" unless differs && File.exist?(path)

      @results.record_child(options.name, champion.generation, player, seed:, differs: Integer(differs))
      path
    end

    def command(game, path)
      seed = Seeds.gnugo(settings.fetch('seed'), game.phase == 'screen' ? 'benchmark' : 'brittleness-retest',
                         game.generation, game.opponent, game.opening, game.color)
      moves = opening_moves(game.phase, game.opening)
      CheckpointBenchmark.game_command(
        network: "../evo #{path}", opponent: @panel.fetch(game.opponent)[:command], color: game.color, seed:,
        prefix: game.prefix, openings: (File.join(OPENINGS, game.phase, game.opening.to_s) unless moves.empty?),
        opening_stones: moves.size, settings:
      )
    end

    def store_game(game, duration)
      prefix = game.prefix
      result = GameResult.read(prefix)
      scored = CheckpointBenchmark.score(result, color: game.color, opponent: game.opponent, bot: true)
      sgf = "#{prefix}-0.sgf"
      @results.record_game(options.name, game, **scored, length: result.length, referee_result: result.referee,
                                                         moves_hash: File.exist?(sgf) ? Brittleness.moves_hash(File.read(sgf)) : nil,
                                                         duration:)
      warn "\n#{prefix}: #{scored[:failure]}" if scored[:failure]
      remove_files(prefix)
    end

    def remove_files(prefix)
      FileUtils.rm_f(["#{prefix}.dat", "#{prefix}-0.sgf", "#{prefix}.err"])
    end
  end

  # The report, from DIR/results.sqlite3 alone.
  class Report
    FAMILY_ALPHA = Rational(1, 20)

    def self.call(out, experiment: nil, generations: nil, io: $stdout)
      path = File.join(out, RESULTS)
      raise Refused, "#{out} has no #{RESULTS}" unless File.exist?(path)

      results = Results.new(path, readonly: true)
      runs = results.runs.select do |run|
        (experiment.nil? || run[:experiment] == experiment) &&
          (generations.nil? || generations.empty? || generations.include?(run[:generation]))
      end
      raise Refused, "#{out} holds no results for #{[experiment, *generations].compact.join(' ')}" if runs.empty?

      runs.each_with_index do |run, i|
        io.puts if i.positive?
        new(results, run, io).call
      end
    ensure
      results&.close
    end

    def initialize(results, run, io)
      @results = results
      @run = run
      @io = io
      @options = JSON.parse(run[:options])
      @own = [run[:own_weight_changes], run[:own_weight_step]]
      @steps = Brittleness.steps(@options['steps'], @options['changes'], @own)
      @m = Brittleness.bonferroni_m(@steps, @options['children'])
      @alpha = FAMILY_ALPHA / @m
      @champion_games = results.champion_games(run[:experiment], run[:generation])
      @screen_keys = @champion_games.map { |row| row.values_at(:opponent, :opening, :color) }
      @retest_keys = Brittleness.retest_keys(@options['retest_games'], @options['opponents'])
      @rows = Hash.new { |h, k| h[k] = {} }
      results.games(run[:experiment], run[:generation]).each do |row|
        @rows[[row[:phase], row[:step], row[:weight_changes], row[:weight_step], row[:child]]][
          row.values_at(:opponent, :opening, :color)] = row
      end
      @selections = results.selections(run[:experiment], run[:generation])
      @selection_failures = results.selection_failures(run[:experiment], run[:generation])
    end

    def call
      header
      replay
      screen
      between_steps
      retest
      detectable
    end

    private

    attr_reader :io

    def puts(text = '') = io.puts(text)

    def header
      run = @run
      puts "# #{run[:experiment]} generation #{run[:generation]}"
      puts
      puts "Champion #{run[:champion]}, own genes: weight_changes #{num(@own[0])}, weight_step #{num(@own[1])}" \
           "#{@steps.any? { |s| s.label == OWN } ? '' : ' (the same as a fixed step: no own step)'}."
      puts "#{@options['children']} children a step; opponents #{@options['opponents'].join(', ')}; " \
           "screen #{@screen_keys.size} games a player (the benchmark's), re-test #{@options['retest_games']} fresh games."
      PHASES.each do |phase|
        rows = @rows.select { |key, _| key[0] == phase }.values.flat_map(&:values)
        failures = rows.count { |row| row[:failure] }
        puts "#{phase == 'screen' ? 'Screen' : 'Re-test'}: #{rows.size} games stored, #{failures} failures" \
             "#{failures.positive? ? " (#{rows.select { |r| r[:failure] }.map { |r| r[:failure] }.tally.map { |f, n| "#{n} × #{f}" }.join('; ')})" : ''}."
      end
      differs = @results.children(run[:experiment], run[:generation]).group_by { |row| row[:step] }
      return if differs.empty?

      ranges = @steps.filter_map do |step|
        rows = differs[step.label]
        "#{step.label} #{rows.map { |row| row[:differs] }.minmax.join('–')}" if rows
      end
      puts "Weights a child changed (perturb's differs), per step: #{ranges.join(', ')}."

    end

    def replay
      rows = player_rows('screen', CHAMPION)
      compared = @champion_games.select { |game| rows.key?(game.values_at(:opponent, :opening, :color)) }
      differ = compared.reject do |game|
        row = rows[game.values_at(:opponent, :opening, :color)]
        row[:winner] == game[:winner] && row[:length] == game[:length] && row[:referee_result] == game[:referee_result]
      end
      puts
      if compared.size < @champion_games.size
        puts "Replay: #{compared.size} of #{@champion_games.size} stored benchmark games replayed so far."
      end
      if differ.empty?
        puts "Replay: all #{compared.size} stored benchmark games reproduced (winner, length, referee result)." if compared.any?
        return
      end

      puts "Replay: #{differ.size} of #{compared.size} stored benchmark games differ: this champion's results are unreliable."
      differ.each do |game|
        row = rows[game.values_at(:opponent, :opening, :color)]
        puts "- #{game[:opponent]} #{game[:opening]} #{game[:color]}: replay #{row[:winner] || row[:failure] || 'draw'}, " \
             "length #{row[:length]}, #{row[:referee_result]}; stored #{game[:winner] || game[:failure] || 'draw'}, " \
             "length #{game[:length]}, #{game[:referee_result]}"
      end
    end

    # The rows of a player's games of the phase, by (opponent, opening, color).
    def player_rows(phase, player) = @rows[[phase, *player.key]]

    def player(step, child) = Player.new(step: step.label, weight_changes: step.weight_changes, weight_step: step.weight_step, child:)

    def wins(rows, keys) = keys.map { |key| rows.fetch(key)[:winner] == 'network' ? 1 : 0 }

    def complete?(rows, keys) = keys.all? { |key| rows.key?(key) }

    # The screen tables of a step's children whose screen is complete.
    def screen_children(step)
      (0...@options['children']).filter_map do |child|
        rows = player_rows('screen', player(step, child))
        [child, rows] if complete?(rows, @screen_keys)
      end
    end

    def champion_screen = @champion_games.map { |row| row[:winner] == 'network' ? 1 : 0 }

    def screen
      champion = champion_screen
      replay = player_rows('screen', CHAMPION)
      opponents = @options['opponents']
      puts
      puts "## Screen: children against the champion on its #{@screen_keys.size} benchmark games"
      puts
      puts "The champion won #{champion.sum} of #{@screen_keys.size} (stored). Differences are the children's wins minus the " \
           "champion's, the mean over a step's children labelled as its champion-relative level; SEs from the crossed " \
           'children × games formula, with n children. Identical games: share of a child\'s games move for move the ' \
           "replay's. Discordance: share of games a child's result differs from the champion's, per opponent " \
           "(#{opponents.join('/')})."
      puts
      puts '| Step | Changes | Weight step | Children | Mean difference | SE (crossed) | Observed SD | Identical games | Discordance |'
      puts '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |'
      @screen_stats = {}
      @steps.each do |step|
        children = screen_children(step)
        tables = children.map { |_, rows| wins(rows, @screen_keys) }
        stats = { n: tables.size, tables: }
        unless tables.empty?
          differences = tables.map { |t| t.sum - champion.sum }
          stats[:mean] = Stats.mean(differences)
          stats[:se] = Math.sqrt(Stats.crossed_variance(tables, champion)) if tables.size >= 2
          stats[:sd] = Math.sqrt(Stats.variance(differences)) if tables.size >= 2
          stats[:discordance] = opponents.map do |opponent|
            indexes = @screen_keys.each_index.select { |j| @screen_keys[j][0] == opponent }
            Stats.mean(tables.map { |t| indexes.count { |j| t[j] != champion[j] }.fdiv(indexes.size) })
          end
          if complete?(replay, @screen_keys)
            stats[:identical] = Stats.mean(children.map do |_, rows|
              @screen_keys.count { |key| rows[key][:moves_hash] && rows[key][:moves_hash] == replay[key][:moves_hash] }.fdiv(@screen_keys.size)
            end)
          end
        end
        @screen_stats[step.label] = stats
        puts "| #{step.label} | #{num(step.weight_changes)} | #{num(step.weight_step)} | #{stats[:n]} | " \
             "#{stats[:mean] ? format('%+.2f', stats[:mean]) : 'n/a'} | #{se(stats[:se], stats[:n])} | " \
             "#{stats[:sd] ? format('%.2f', stats[:sd]) : 'n/a'} | " \
             "#{stats[:identical] ? format('%.0f %%', 100 * stats[:identical]) : 'n/a'} | " \
             "#{stats[:discordance] ? stats[:discordance].map { |d| format('%.2f', d) }.join('/') : 'n/a'} |"
      end
      incomplete = @steps.flat_map do |step|
        (0...@options['children']).filter_map do |child|
          rows = player_rows('screen', player(step, child))
          "#{step.label} child #{child} (#{rows.size} of #{@screen_keys.size})" unless complete?(rows, @screen_keys)
        end
      end
      unless incomplete.empty?
        puts
        puts "Left out until their screen is complete: #{incomplete.join(', ')}."
      end
      independence(champion)
    end

    # A child as strong as the champion whose games were independent of
    # the champion's would differ by Σ Bin(n_o, p_o) − the champion's wins.
    def independence(champion)
      variance = @options['opponents'].sum do |opponent|
        indexes = @screen_keys.each_index.select { |j| @screen_keys[j][0] == opponent }
        p = indexes.sum { |j| champion[j] }.fdiv(indexes.size)
        indexes.size * p * (1 - p)
      end
      sd = Math.sqrt(variance)
      puts
      puts "Null band of the screen, independence approximation: a child as strong as the champion lands within " \
           "±#{format('%.1f', 1.96 * sd)} of 0 (95 %, SD #{format('%.2f', sd)}); compare the observed SD above. Children " \
           'agree with the champion more than independence predicts, so the band is too wide.'
    end

    def between_steps
      pairs = @steps.combination(2).to_a
      return if pairs.empty?

      puts
      puts "## Between steps (screen, wins of #{@screen_keys.size})"
      puts
      puts '| Step A | Step B | A − B | SE (crossed) |'
      puts '| --- | --- | ---: | ---: |'
      pairs.each do |a, b|
        sa = @screen_stats[a.label]
        sb = @screen_stats[b.label]
        if sa[:n].zero? || sb[:n].zero?
          puts "| #{a.label} | #{b.label} | n/a | n/a |"
          next
        end
        se = Math.sqrt(Stats.crossed_variance(sa[:tables], sb[:tables])) if sa[:n] >= 2 && sb[:n] >= 2
        puts "| #{a.label} | #{b.label} | #{format('%+.2f', sa[:mean] - sb[:mean])} | " \
             "#{se ? format('%.2f', se) : 'n/a'} (n #{sa[:n]}, #{sb[:n]}) |"
      end
    end

    def retest
      champion_rows = player_rows('retest', CHAMPION)
      puts
      puts "## Re-test on #{@options['retest_games']} fresh games (wins of #{@options['retest_games']})"
      puts
      unless complete?(champion_rows, @retest_keys) && @selections.any?
        puts "Not complete: the champion has #{champion_rows.size} of #{@retest_keys.size} re-test games; " \
             "#{@selections.size} children selected."
        return
      end

      champion = wins(champion_rows, @retest_keys)
      if @selection_failures.positive?
        puts "The re-tested children were chosen while #{@selection_failures} screen games had failed, counted as " \
             'losses (--accept-failures).'
      end
      puts "The champion won #{champion.sum}. Improvement: a re-tested best child is better when its wins among the " \
           "games its result differs from the champion's, k of n_d, satisfy P(Bin(n_d, ½) ≥ k) ≤ 0.05 / m " \
           "(exact one-sided sign test, Bonferroni over the champion's re-tested best children, m = #{@m})."
      puts
      puts '| Step | Role | Child | Screen difference | Re-test difference | n_d | k | P | Better |'
      puts '| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |'
      by_step = Hash.new { |h, k| h[k] = { 'best' => [], 'control' => [] } }
      playing = false
      @selections.each do |sel|
        step = @steps.find { |s| s.label == sel[:step] }
        rows = player_rows('retest', player(step, sel[:child]))
        unless complete?(rows, @retest_keys)
          puts "| #{sel[:step]} | #{sel[:role]} | #{sel[:child]} | #{format('%+d', sel[:screen_difference])} | " \
               "#{rows.size} of #{@retest_keys.size} games | | | | |"
          playing = true
          next
        end
        table = wins(rows, @retest_keys)
        discordant = table.zip(champion).count { |c, h| c != h }
        k = table.zip(champion).count { |c, h| c > h }
        p = Stats.sign_tail(discordant, k)
        verdict = sel[:role] == 'best' ? (k >= Stats.critical(discordant, @alpha) ? 'yes' : 'no') : '—'
        puts "| #{sel[:step]} | #{sel[:role]} | #{sel[:child]} | #{format('%+d', sel[:screen_difference])} | " \
             "#{format('%+d', table.sum - champion.sum)} | #{discordant} | #{k} | #{format('%.4f', p.to_f)} | #{verdict} |"
        by_step[sel[:step]][sel[:role]] << [sel[:screen_difference], table]
      end
      if playing
        puts
        puts 'A child whose re-test is not complete is left out of the summary below.'
      end
      retest_summary(by_step, champion)
    end

    def retest_summary(by_step, champion)
      puts
      puts 'Controls against the champion (an unbiased level only as far as the screen does not predict the re-test), ' \
           'the re-tested best minus the controls, and the screen–re-test correlation over both, each with n ' \
           '(a t interval on n − 1 degrees of freedom applies to a few children):'
      puts
      puts '| Step | Controls − champion | SE (crossed) | Best − controls | SE (crossed) | Screen–re-test correlation |'
      puts '| --- | ---: | ---: | ---: | ---: | ---: |'
      all = []
      @steps.each do |step|
        best = by_step[step.label]['best']
        controls = by_step[step.label]['control']
        control_tables = controls.map(&:last)
        best_tables = best.map(&:last)
        level = control_tables.empty? ? nil : Stats.mean(control_tables.map { |t| t.sum - champion.sum })
        level_se = Math.sqrt(Stats.crossed_variance(control_tables, champion)) if control_tables.size >= 2
        gap = (Stats.mean(best_tables.map(&:sum)) - Stats.mean(control_tables.map(&:sum)) unless best.empty? || controls.empty?)
        gap_se = Math.sqrt(Stats.crossed_variance(best_tables, control_tables)) if best.size >= 2 && controls.size >= 2
        both = best + controls
        all.concat(both)
        r = Stats.pearson(both.map(&:first), both.map { |_, t| t.sum - champion.sum })
        puts "| #{step.label} | #{level ? format('%+.2f', level) : 'n/a'} | #{se(level_se, controls.size)} | " \
             "#{gap ? format('%+.2f', gap) : 'n/a'} | #{gap_se ? format('%.2f', gap_se) : 'n/a'} (n #{best.size}, #{controls.size}) | " \
             "#{r ? format('%+.2f', r) : 'n/a'} (n #{both.size}) |"
      end
      r = Stats.pearson(all.map(&:first), all.map { |_, t| t.sum - champion.sum })
      puts
      puts "Screen–re-test correlation: #{r ? format('%+.2f', r) : 'n/a'} (n #{all.size}) over every re-tested child."
    end

    def detectable
      games = @options['retest_games']
      puts
      puts "## Smallest detectable improvement (estimate, percentage points of the #{games} re-test games)"
      puts
      puts "Model: an effect δ makes the child win a game its result differs from the champion's with probability " \
           "(1 + δ/d) / 2, d the step's screen discordance averaged over the opponents, n_d = d × #{games}; the sign " \
           "test at 0.05 / #{@m}. A null result means no child better by at least this much, not never."
      puts
      puts '| Step | d | 50 % power | 80 % power |'
      puts '| --- | ---: | ---: | ---: |'
      @steps.each do |step|
        discordance = @screen_stats[step.label][:discordance]
        if discordance.nil?
          puts "| #{step.label} | n/a | n/a | n/a |"
          next
        end
        d = Stats.mean(discordance)
        mdes = [0.5, 0.8].map { |power| Stats.mde(d, games, @alpha, power) }
        puts "| #{step.label} | #{format('%.3f', d)} | #{mdes.map { |x| x ? format('%.1f', 100 * x) : 'n/a' }.join(' | ')} |"
      end
    end

    # Four significant digits: the champion's own genes have many more.
    def num(value) = format('%.4g', value)

    def se(value, n) = "#{value ? format('%.2f', value) : 'n/a'} (n #{n})"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    options = Brittleness::Options.parse(ARGV)
    unless options.report_only
      pool = WorkerPool.new(options.concurrency)
      run = Brittleness::Run.new(options, pool:)
      # Ctrl-C reaches the games too; no game is stored after it.
      trap('SIGINT') { run.stop! }
      begin
        run.call
      ensure
        pool.stop
      end
      puts
    end
    Brittleness::Report.call(options.out, experiment: options.name, generations: options.generations)
  rescue Brittleness::Refused => e
    warn e.message
    exit 1
  rescue Brittleness::Interrupted
    warn "\nStopped. The same command resumes."
    exit 130
  end
end
