require_relative 'test_helper'
require 'rbconfig'
require_relative '../scripts/brittleness'

# scripts/brittleness.rb, with gogui-twogtp stubbed by FakePool (each game
# "played" by writing its result files) and perturb by a small script that
# copies the champion and logs its arguments.
class BrittlenessTest < Minitest::Test
  include RunGenerationHelpers

  B = Brittleness
  GEN = 10
  SEED = 5

  # A network file with the given genes: the .ann header (magic, version,
  # four sizes, two activation codes), the five genes, then any bytes. By
  # default the genes are the 0.5 step's, so `own` is skipped.
  def ann(weight_changes: 229.0, weight_step: 0.5)
    ['EVOANN', 2, 1, 1, 1, 82, 1, 1, 0.01, weight_changes, weight_step, 0.02, 0.02].pack('a6L<l<4L<2E5') + 'weights'
  end

  def setup
    @tmp = Dir.mktmpdir('brittleness-test')
    @experiment = File.join(@tmp, 'experiments', 'exp')
    FileUtils.mkdir_p(@experiment)
    File.write(File.join(@experiment, 'evo'), 'the experiment\'s evo')
    @out = File.join(@tmp, 'out')
    @perturb_log = File.join(@tmp, 'perturb.log')
    @perturb = File.join(@tmp, 'perturb')
    File.write(@perturb, <<~RUBY)
      #!#{RbConfig.ruby}
      net, out, changes, step, seed = ARGV
      File.open(#{@perturb_log.inspect}, 'a') { |f| f.puts ARGV.join(' ') }
      File.binwrite(out, File.binread(net) + "child \#{changes} \#{step} \#{seed}")
      puts 'differs=5'
    RUBY
    File.chmod(0o755, @perturb)
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  # An experiment whose generation GEN (or each of `generations`) has the
  # champion c.ann, ranked behind a bot, with the given genes, and its
  # benchmark games against `opponents` on `openings` openings, won or
  # lost as `stored` says.
  def make_experiment(genes: {}, opponents: %w[AmiGo MichiWeak], openings: 2, stored: ->(*) { 'network' },
                      length: ->(*) { 93 }, referee: nil, generations: [GEN])
    db = ExperimentDatabase.new(File.join(@experiment, 'experiment.sqlite3'))
    db.save_settings(SETTINGS.merge('benchmark_games' => 2 * openings, 'seed' => SEED))
    db.save_benchmark_opponents(SetupExperiment::DEFAULT_BENCHMARK)
    generations.each { |generation| save_generation(db, generation, genes:, opponents:, openings:, stored:, length:, referee:) }
    db.close
  end

  def save_generation(db, generation, genes:, opponents:, openings:, stored:, length:, referee:)
    db.save_state(generation, { 'players' => { 'AmiGo1' => { 'external' => true }, 'c.ann' => {}, 'd.ann' => {} },
                         'ranking' => [{ 'name' => 'AmiGo1', 'score' => 3 }, { 'name' => 'c.ann', 'score' => 2 },
                                       { 'name' => 'd.ann', 'score' => 1 }] },
                  champion: ['c.ann', ann(**genes)])
    opponents.product((0...openings).to_a, %w[black white]) do |opponent, opening, color|
      winner = stored.call(opponent, opening, color)
      # As the fixtures black_wins and white_wins have it.
      referee_result = referee&.call(opponent, opening, color) ||
                       ((color == 'black') == (winner == 'network') ? 'B+R' : 'W+22.5')
      db.record_benchmark_game(generation:, opponent:, opening:, network_color: color, network: 'c.ann',
                               winner:, length: length.call(opponent, opening, color), referee_result:)
    end
  end

  DEFAULT_ARGS = %w[--opponents AmiGo,MichiWeak --children 2 --steps 0.5,0.02 --retest-games 8].freeze

  def options(*args, defaults: DEFAULT_ARGS)
    B::Options.parse([@experiment, GEN.to_s, '--out', @out, *defaults, *args])
  end

  # Plays the run with a pool whose games the network wins when `wins`
  # says so (by default always), with the moves `moves` gives, or the
  # fixture `fixture` gives (nil: by `wins`). Returns the pool.
  def brittleness(*args, wins: ->(_game) { true }, moves: ->(_game) { 'ee' }, fixture: ->(_game) {}, status: exit_status(0),
          on_event: nil, defaults: DEFAULT_ARGS, &with_run)
    pool = FakePool.new(status:, on_event:) do |game|
      won = wins.call(game)
      copy_dat(fixture.call(game) || ((game.color == 'black') == won ? 'black_wins' : 'white_wins'), game.prefix)
      # moves nil: twogtp left no SGF.
      move = moves.call(game)
      File.write("#{game.prefix}-0.sgf", "(;GM[1]SZ[9];B[aa];W[#{move}])") if move
    end
    script = B::Run.new(options(*args, defaults:), pool:, perturb: @perturb)
    with_run&.call(script)
    # As the script's main: the run, then the report of its generations.
    @printed, = capture_io do
      script.call
      puts
      B::Report.call(@out, experiment: 'exp', generations: [GEN])
    end
    pool
  end

  def results
    @results ||= Sequel.sqlite(File.join(@out, 'results.sqlite3'), readonly: true)
  end

  def stored_games(phase = nil)
    rows = results[:games]
    rows = rows.where(phase:) if phase
    rows.all
  end

  def report(*filters)
    out, = capture_io { B::Report.call(@out, experiment: filters[0], generations: filters[1]) }
    out
  end

  def player(step, child, changes: 229.0)
    weight_step = step == 'champion' ? 0.0 : Float(step)
    B::Player.new(step:, weight_changes: step == 'champion' ? 0.0 : changes, weight_step:, child:)
  end

  def game_of(pool, phase, step, child, opponent, opening, color)
    index = pool.identifiers.index do |game|
      game.phase == phase && game.player.step == step && game.player.child == child &&
        [game.opponent, game.opening, game.color] == [opponent, opening, color]
    end
    [pool.identifiers[index], pool.commands[index]]
  end

  # --- Options -----------------------------------------------------------

  def test_the_defaults_are_the_plans
    make_experiment
    o = options(defaults: [])
    assert_equal %w[0.005 0.02 0.1 0.5], o.steps
    assert_equal 229.0, o.changes
    assert_equal 32, o.children
    assert_equal %w[AmiGo MichiWeak MichiMid], o.opponents
    assert_equal 600, o.retest_games
    assert_equal 2, o.concurrency
    assert_equal 'exp', o.name
  end

  # Any prefix of the re-test's games covers every opponent equally, so
  # its size must split into both colours of every opponent.
  def test_the_retest_games_must_divide_into_colours_and_opponents
    make_experiment
    error = assert_raises(B::Refused) { options('--retest-games', '10') }
    assert_match(/divisible by 4/, error.message)
    assert_equal 12, options('--retest-games', '12').retest_games
    assert_equal 300, options('--opponents', 'AmiGo,MichiWeak,MichiMid', '--retest-games', '300').retest_games
  end

  def test_steps_are_labelled_by_their_value
    make_experiment
    assert_equal %w[0.5 0.02], options('--steps', '0.50,2e-2').steps
    assert_raises(B::Refused) { options('--steps', '0.5,0.50') }
    assert_raises(B::Refused) { options('--steps', '20') }
    assert_raises(B::Refused) { options('--changes', '0.5') }
  end

  # --- Steps -------------------------------------------------------------

  # A champion with fixed genes equal to a fixed step's (seed2-meta0's
  # 229.3128 and 0.5) is that step in distribution: no `own`.
  def test_own_is_skipped_when_it_matches_a_fixed_step
    fixed = %w[0.005 0.02 0.1 0.5]
    assert_equal fixed, B.steps(fixed, 229.0, [229.3128, 0.5]).map(&:label)
    own = B.steps(fixed, 229.0, [26.25, 0.00048]).last
    assert_equal ['own', 26.25, 0.00048], [own.label, own.weight_changes, own.weight_step]
    # The step within 1e-6 relative, the changes 2 % off: a different load.
    assert_equal 'own', B.steps(fixed, 229.0, [233.6, 0.5 * (1 + 5e-7)]).last.label
    assert_equal 'own', B.steps(fixed, 229.0, [229.0, 0.5 * (1 + 2e-6)]).last.label
    assert_equal fixed, B.steps(fixed, 229.0, [231.2, 0.5 * (1 - 9e-7)]).map(&:label)
  end

  # Bonferroni over the champion's re-tested best children: ceil(children
  # / 10) a step.
  def test_bonferroni_m_counts_the_retested_best_children
    assert_equal 16, B.bonferroni_m(B.steps(%w[0.005 0.02 0.1 0.5], 229.0, [229.3128, 0.5]), 32)
    assert_equal 20, B.bonferroni_m(B.steps(%w[0.005 0.02 0.1 0.5], 229.0, [26.25, 0.00048]), 32)
    assert_equal 2, B.bonferroni_m(B.steps(%w[0.5], 229.0, [26.25, 0.00048]), 1)
  end

  def test_the_genes_are_read_from_the_network_file
    assert_equal [26.25, 0.00048], B.genes(ann(weight_changes: 26.25, weight_step: 0.00048))
    assert_raises(B::Refused) { B.genes('not a network') }
  end

  # --- Players and pairing ------------------------------------------------

  def test_each_child_is_perturbed_from_the_champion_with_its_own_seed
    make_experiment
    brittleness
    calls = File.readlines(@perturb_log, chomp: true).map(&:split)
    # Screen: 2 steps x 2 children; re-test: 1 best and 1 control a step.
    assert_equal 8, calls.size
    first = calls.first
    assert_equal 'players/10-champion.ann', first[0]
    assert_equal ['229.0', '0.5', Seeds.derive(SEED, 'brittleness', 'exp', GEN, '0.5', 0).to_s], first[2..]
    seeds = calls.first(4).map(&:last)
    assert_equal 4, seeds.uniq.size
    # The re-test rebuilds each child (all four here) from the same seed.
    assert_equal calls.first(4).sort, calls.last(4).sort
    assert_equal [5], results[:children].select_map(:differs).uniq
  end

  # A screen game is the champion's benchmark game with the child in its
  # place: the same command, opening and seed.
  def test_screen_games_pair_with_the_champions_benchmark_games
    make_experiment
    pool = brittleness
    settings = SetupExperiment.parse(ExperimentDatabase.new(File.join(@experiment, 'experiment.sqlite3'), readonly: true).settings)
    game, command = game_of(pool, 'screen', '0.02', 1, 'MichiWeak', 1, 'white')
    seed = Seeds.gnugo(SEED, 'benchmark', GEN, 'MichiWeak', 1, 'white')
    assert_equal CheckpointBenchmark.game_command(
      network: '../evo players/10-0.02-229.0-0.02-1.ann', opponent: SetupExperiment::MICHI_WEAK, color: 'white', seed:,
      prefix: game.prefix, openings: 'openings/screen/1', opening_stones: 4, settings:
    ), command
    assert_equal Openings.sgf(9, Openings.moves(SEED, 1, 9, 4)),
                 File.read(File.join(@out, 'exp', 'work', 'openings', 'screen', '1', 'opening.sgf'))
    _, replay = game_of(pool, 'screen', 'champion', 'replay', 'MichiWeak', 1, 'white')
    assert_equal command.sub('players/10-0.02-229.0-0.02-1.ann', 'players/10-champion.ann').gsub(game.prefix, game_of(pool, 'screen', 'champion', 'replay', 'MichiWeak', 1, 'white')[0].prefix), replay
  end

  # The re-test plays fresh openings and seeds, the same for the champion
  # and every child.
  def test_retest_games_pair_child_and_champion_on_fresh_openings
    make_experiment
    pool = brittleness
    champion, champion_command = game_of(pool, 'retest', 'champion', 'replay', 'AmiGo', 1, 'black')
    child = pool.identifiers.find { |g| g.phase == 'retest' && !g.player.replay? && [g.opponent, g.opening, g.color] == ['AmiGo', 1, 'black'] }
    child_command = pool.commands[pool.identifiers.index(child)]
    seed = Seeds.gnugo(SEED, 'brittleness-retest', GEN, 'AmiGo', 1, 'black')
    [champion_command, child_command].each do |command|
      assert_includes command, "--seed #{seed}\""
      assert_includes command, ' -openings openings/retest/1 '
    end
    assert_equal champion_command.sub('10-champion.ann', child.player.file_name(GEN)).gsub(champion.prefix, child.prefix),
                 child_command
    fresh = Openings.moves(Seeds.derive(SEED, 'brittleness-retest'), 1, 9, 4)
    assert_equal Openings.sgf(9, fresh), File.read(File.join(@out, 'exp', 'work', 'openings', 'retest', '1', 'opening.sgf'))
    refute_equal Openings.moves(SEED, 1, 9, 4), fresh
  end

  # By opening, then colour, then opponent: any prefix covers every
  # opponent equally.
  def test_the_retest_order
    assert_equal [['A', 0, 'black'], ['M', 0, 'black'], ['A', 0, 'white'], ['M', 0, 'white'],
                  ['A', 1, 'black'], ['M', 1, 'black'], ['A', 1, 'white'], ['M', 1, 'white']],
                 B.retest_keys(8, %w[A M])
    make_experiment
    pool = brittleness
    replay = pool.identifiers.select { |g| g.phase == 'retest' && g.player.replay? }
    assert_equal B.retest_keys(8, %w[AmiGo MichiWeak]), replay.map { |g| [g.opponent, g.opening, g.color] }
  end

  def test_every_game_has_its_own_files
    make_experiment
    pool = brittleness
    assert_equal pool.identifiers.size, pool.identifiers.map(&:prefix).uniq.size
    # 5 players x 8 screen games; the champion, and 1 best and 1 control
    # a step, x 8 re-test games.
    assert_equal 40 + 40, pool.identifiers.size
    assert_empty Dir.children(File.join(@out, 'exp', 'work', 'games'))
    # Each child's file goes once its games of the phase are stored.
    assert_equal %w[10-champion.ann], Dir.children(File.join(@out, 'exp', 'work', 'players'))
    assert_equal 'the experiment\'s evo', File.read(File.join(@out, 'exp', 'evo'))
  end

  # The key keeps phases, steps and weight changes apart.
  def test_row_keys_keep_phases_steps_and_changes_apart
    games = [
      B::Game.new(generation: GEN, phase: 'screen', player: player('0.5', 0), opponent: 'AmiGo', opening: 0, color: 'black'),
      B::Game.new(generation: GEN, phase: 'retest', player: player('0.5', 0), opponent: 'AmiGo', opening: 0, color: 'black'),
      B::Game.new(generation: GEN, phase: 'screen', player: player('0.02', 0), opponent: 'AmiGo', opening: 0, color: 'black'),
      B::Game.new(generation: GEN, phase: 'screen', player: player('0.5', 0, changes: 100.0), opponent: 'AmiGo', opening: 0,
                                                                                                      color: 'black'),
      B::Game.new(generation: GEN, phase: 'screen', player: player('0.5', 1), opponent: 'AmiGo', opening: 0, color: 'black')
    ]
    assert_equal 5, games.map(&:key).uniq.size
    assert_equal 5, games.map(&:prefix).uniq.size
    FileUtils.mkdir_p(@out)
    store = B::Results.new(File.join(@out, 'results.sqlite3'))
    games.each { |g| store.record_game('exp', g, winner: 'network', failure: nil, length: 1, referee_result: 'B+R', moves_hash: 'x', duration: 1.0) }
    assert_equal 5, store.games('exp', GEN).size
  end

  # --- Resume, failures and interrupts ------------------------------------

  def test_a_resumed_run_skips_stored_games_and_replays_failures
    make_experiment
    failing = lambda do |game|
      game.phase == 'retest' && game.player.replay? && [game.opponent, game.opening, game.color] == ['AmiGo', 1, 'black']
    end
    brittleness(fixture: ->(game) { 'no_referee_score' if failing.call(game) })
    assert_equal 1, stored_games.count { |row| row[:failure] }
    @results = nil
    pool = brittleness
    assert_equal 1, pool.identifiers.size
    assert failing.call(pool.identifiers.first)
    assert_equal 0, stored_games.count { |row| row[:failure] }
    assert_equal 80, stored_games.size
  end

  # Failures count as losses, so a child whose screen failed could be
  # passed over: the re-test waits until no screen failure is left.
  def test_the_retest_waits_for_the_screen_failures_to_be_replayed
    make_experiment
    failing = lambda do |game|
      game.phase == 'screen' && game.player.child == 1 && game.player.step == '0.5' && game.opponent == 'MichiWeak'
    end
    pool = brittleness(fixture: ->(game) { 'no_referee_score' if failing.call(game) })
    assert_empty pool.identifiers.select { |game| game.phase == 'retest' }
    assert_empty results[:selections].all
    assert_match(/4 screen games failed/, @printed)
    @results = nil
    pool = brittleness
    assert_equal 4 + 40, pool.identifiers.size
    assert_equal 4, results[:selections].count
  end

  # A screen game that fails on every run keeps the re-test waiting until
  # --accept-failures lets it go ahead with the failure counted as a loss;
  # the option is not one of the run's stored options.
  def test_accept_failures_lets_the_retest_go_ahead
    make_experiment
    failing = lambda do |game|
      game.phase == 'screen' && game.player.child == 1 && game.player.step == '0.5' &&
        [game.opponent, game.opening, game.color] == ['MichiWeak', 0, 'black']
    end
    fixture = ->(game) { 'no_referee_score' if failing.call(game) }
    brittleness(fixture:)
    assert_match(/add --accept-failures/, @printed)
    @results = nil
    pool = brittleness(fixture:)
    assert_equal 1, pool.identifiers.size
    assert_empty results[:selections].all
    @results = nil
    pool = brittleness('--accept-failures', fixture:)
    assert_equal 1 + 40, pool.identifiers.size
    assert_equal 4, results[:selections].count
    # The failed game counts as a loss: 7 of 8 against the champion's 8.
    assert_equal [[0, 'best', 0], [1, 'control', -1]],
                 results[:selections].where(step: '0.5').order(:child).select_map(%i[child role screen_difference])
    assert_match(/chosen while 1 screen games had failed, counted as losses \(--accept-failures\)/, @printed)
    # Once chosen, the children stay, and the re-test no longer waits.
    @results = nil
    assert_equal 1, brittleness(fixture:).identifiers.size
    refute_match(/re-test waits/, @printed)
    assert_match(/chosen while 1 screen games had failed/, report)
  end

  # The selection compares children with the champion's stored games, so
  # a failed replay game does not hold the re-test back.
  def test_a_failed_replay_game_does_not_hold_the_retest
    make_experiment
    pool = brittleness(fixture: ->(game) { 'no_referee_score' if game.phase == 'screen' && game.player.replay? && game.opening == 0 })
    assert_equal 40, pool.identifiers.count { |game| game.phase == 'retest' }
    refute_match(/re-test waits|chosen while/, @printed)
  end

  # No backwards compatibility: a directory an older script wrote is
  # refused, by a run and by the report.
  def test_a_directory_of_an_older_script_is_refused
    make_experiment
    FileUtils.mkdir_p(@out)
    Sequel.sqlite(File.join(@out, 'results.sqlite3')) { |db| db.create_table(:runs) { String :experiment } }
    [-> { brittleness }, -> { report }].each do |call|
      assert_match(/written by an older brittleness\.rb; use a new --out/, assert_raises(B::Refused) { call.call }.message)
    end
  end

  # The documented use: several generations in one invocation, each
  # with its own games, resumed as a whole.
  def test_one_run_plays_several_generations
    make_experiment(generations: [10, 20])
    run = lambda do
      pool = FakePool.new do |game|
        copy_dat('black_wins', game.prefix) if game.color == 'black'
        copy_dat('white_wins', game.prefix) if game.color == 'white'
      end
      options = B::Options.parse([@experiment, '10', '20', '--out', @out, *DEFAULT_ARGS])
      capture_io { B::Run.new(options, pool:, perturb: @perturb).call }
      pool
    end
    pool = run.call
    assert_equal({ 10 => 80, 20 => 80 }, pool.identifiers.map(&:generation).tally)
    assert_equal({ 10 => 80, 20 => 80 }, results[:games].group_and_count(:generation).as_hash(:generation, :count))
    assert_includes File.read(@perturb_log), Seeds.derive(SEED, 'brittleness', 'exp', 20, '0.5', 0).to_s
    @results = nil
    assert_empty run.call.identifiers
  end

  def test_an_interrupted_game_is_not_stored
    make_experiment
    third = 0
    status = ->(_game) { (third += 1) == 3 ? exit_status(130) : exit_status(0) }
    assert_raises(B::Interrupted) { brittleness(status:) }
    assert_equal 2, stored_games.size
    assert_empty Dir.children(File.join(@out, 'exp', 'work', 'games')).grep(/\.dat\z/).reject { |f| f.start_with?('10-screen-champion') }
  end

  # Ctrl-C (the trap calls stop!) stores no game that comes back after it.
  def test_after_ctrl_c_no_game_is_stored
    make_experiment
    script = nil
    events = 0
    assert_raises(B::Interrupted) do
      brittleness(on_event: ->(_) { script.stop! if (events += 1) == 4 }) { |r| script = r }
    end
    assert_equal 3, stored_games.size
  end

  # Ctrl-C reaches perturb too, which then fails: that is an interrupt,
  # not a perturb failure. The stub sends the test process SIGINT, whose
  # trap stops the run as the script's does.
  def test_ctrl_c_during_perturb_is_an_interrupt
    make_experiment
    File.write(@perturb, "#!#{RbConfig.ruby}\nProcess.kill('INT', Process.ppid)\nsleep 0.2\nexit 1\n")
    script = nil
    previous = trap('INT') { script.stop! }
    begin
      assert_raises(B::Interrupted) { brittleness { |r| script = r } }
    ensure
      trap('INT', previous)
    end
  end

  def test_a_halted_pools_unstarted_games_are_not_stored
    make_experiment
    assert_raises(B::Interrupted) { brittleness(status: WorkerPool::NOT_STARTED) }
    assert_empty stored_games
  end

  # Leftovers of an interrupted run: game files twogtp would not replay
  # over, and perturb's temporary files.
  def test_leftover_files_are_deleted_on_start
    make_experiment
    work = File.join(@out, 'exp', 'work')
    FileUtils.mkdir_p(File.join(work, 'games'))
    FileUtils.mkdir_p(File.join(work, 'players'))
    leftovers = [File.join(work, 'games', '10-screen-champion-0.0-0.0-replay-AmiGo-0-black.dat'),
                 File.join(work, 'players', '10-0.5-229.0-0.5-0.ann.tmp.Ab12Cd')]
    leftovers.each { |path| File.write(path, 'old') }
    brittleness
    leftovers.each { |path| refute_path_exists path }
  end

  def test_a_second_run_on_the_same_directory_is_refused
    make_experiment
    FileUtils.mkdir_p(@out)
    File.open(File.join(@out, 'brittleness.lock'), File::RDWR | File::CREAT) do |lock|
      lock.flock(File::LOCK_EX)
      error = assert_raises(B::Refused) { brittleness }
      assert_match(/another brittleness run/, error.message)
    end
    brittleness
    assert_equal 80, stored_games.size
  end

  def test_a_directory_with_other_options_is_refused
    make_experiment
    brittleness
    error = assert_raises(B::Refused) { brittleness('--children', '3') }
    assert_match(/other options/, error.message)
    # --concurrency may change between resumes.
    assert_empty brittleness('--concurrency', '5').identifiers
  end

  def test_opponents_must_be_bots_with_stored_benchmark_games
    make_experiment
    assert_match(/not a bot/, assert_raises(B::Refused) { brittleness('--opponents', 'AmiGo,Gen0Champion') }.message)
    assert_match(/lacks/, assert_raises(B::Refused) { brittleness('--opponents', 'AmiGo,MichiMid') }.message)
  end

  def test_the_experiment_is_only_read
    make_experiment
    database = File.join(@experiment, 'experiment.sqlite3')
    before = Dir.children(@experiment).sort.to_h { |f| [f, File.binread(File.join(@experiment, f))] }
    brittleness
    assert_equal before, Dir.children(@experiment).sort.to_h { |f| [f, File.binread(File.join(@experiment, f))] }
    assert_path_exists database
  end

  # --- Selection ----------------------------------------------------------

  def test_the_best_children_by_screen_difference_then_seeded_controls
    differences = { 0 => 3, 1 => 5, 2 => 5, 3 => -1, 4 => 0, 5 => 5, 6 => 2, 7 => 1, 8 => 0, 9 => -4, 10 => 4, 11 => 0 }
    seed = Seeds.derive(SEED, 'brittleness-controls', 'exp', GEN, '0.5')
    picked = B.select_retest(differences, 2, seed)
    # Three children tie at 5: the lower indexes win.
    assert_equal [1, 2], picked[:best]
    rest = [0, 3, 4, 5, 6, 7, 8, 9, 10, 11]
    assert_equal rest.sample(2, random: Random.new(seed)).sort, picked[:controls]
    assert_empty picked[:controls] & picked[:best]
    assert_equal picked, B.select_retest(differences, 2, seed)
  end

  def test_the_run_retests_the_best_child_and_a_control_per_step
    make_experiment
    # Child 1 of each step wins every game, child 0 none.
    brittleness(wins: ->(game) { game.player.replay? || game.player.child == 1 })
    selection = results[:selections].order(:step, :role).select_map(%i[step child role])
    assert_equal [['0.02', 1, 'best'], ['0.02', 0, 'control'], ['0.5', 1, 'best'], ['0.5', 0, 'control']], selection
  end

  # With 12 children, 2 a step are re-tested best and 2 controls drawn
  # from the other 10 with the step's seed.
  def test_the_controls_are_drawn_with_the_steps_seed
    make_experiment
    brittleness('--children', '12', '--steps', '0.5', wins: ->(game) { game.player.replay? || [3, 7].include?(game.player.child) })
    rest = [0, 1, 2, 4, 5, 6, 8, 9, 10, 11]
    controls = rest.sample(2, random: Random.new(Seeds.derive(SEED, 'brittleness-controls', 'exp', GEN, '0.5'))).sort
    assert_equal [[3, 'best'], [7, 'best']] + controls.map { |c| [c, 'control'] },
                 results[:selections].order(:role, :child).select_map(%i[child role])
  end

  # --- Statistics ---------------------------------------------------------

  # Two children of A and of B on three games, the variance parts by hand:
  # s_T² 0.5 each, MSE 1/6 each, var_g(ȳA − ȳB) 0.75, so
  # 0.5/2 + 0.5/2 + 3 × (0.75 − 1/12 − 1/12) = 2.25.
  def test_the_crossed_variance_between_two_steps
    a = [[1, 0, 1], [0, 0, 1]]
    b = [[1, 1, 0], [1, 0, 0]]
    parts = B::Stats.parts(a)
    assert_in_delta 0.5, parts[:s_t2]
    assert_in_delta 1 / 6r, parts[:mse]
    assert_equal [0.5, 0.0, 1.0], parts[:game_means]
    assert_in_delta 2.25, B::Stats.crossed_variance(a, b)
  end

  # Against the champion (one player) its s_T²/n and MSE/n drop:
  # 0.5/2 + 3 × (7/12 − 1/12) = 1.75.
  def test_the_crossed_variance_against_the_champion
    assert_in_delta 1.75, B::Stats.crossed_variance([[1, 0, 1], [0, 0, 1]], [1, 0, 0])
  end

  # The games part is never negative: here var_g(z) is 0 and MSE/n 0.5.
  def test_the_games_part_is_clamped_at_zero
    assert_in_delta 0.0, B::Stats.crossed_variance([[1, 0], [0, 1]], [1, 1])
  end

  # P(Bin(27, ½) ≥ 21) = 397594 / 2^27 ≈ 0.00296, between 0.05/20 and
  # 0.05/16; P(≥ 22) = 101584 / 2^27.
  def test_the_sign_tests_critical_values
    assert_equal Rational(397_594, 2**27), B::Stats.sign_tail(27, 21)
    assert_equal Rational(101_584, 2**27), B::Stats.sign_tail(27, 22)
    assert_equal 21, B::Stats.critical(27, Rational(1, 20) / 16)
    assert_equal 22, B::Stats.critical(27, Rational(1, 20) / 20)
    assert_equal 9, B::Stats.critical(10, Rational(1, 20))
    assert_equal 1, B::Stats.critical(0, Rational(1, 20))
    assert_equal 1, B::Stats.sign_tail(5, 0)
    # At the level itself, the child is better.
    assert_equal 5, B::Stats.critical(5, Rational(1, 32))
  end

  # Round 4's exact computation (scratchpad round4/mde_exact.rb) at 600
  # re-test games and m 20 gave 6.2/8.0 points for d 0.287 and 4.0/5.0 for
  # d 0.118, to one decimal.
  def test_the_minimum_detectable_effect
    alpha = Rational(1, 20) / 20
    assert_in_delta 0.062, B::Stats.mde(0.287, 600, alpha, 0.5), 0.0007
    assert_in_delta 0.080, B::Stats.mde(0.287, 600, alpha, 0.8), 0.0007
    assert_in_delta 0.040, B::Stats.mde(0.118, 600, alpha, 0.5), 0.0007
    assert_in_delta 0.050, B::Stats.mde(0.118, 600, alpha, 0.8), 0.0007
    assert_nil B::Stats.mde(0.0, 600, alpha, 0.5)
    assert_nil B::Stats.mde(0.01, 6, alpha, 0.5)
  end

  # Two points always correlate ±1.
  def test_pearson_is_na_below_three
    assert_in_delta(-1.0, B::Stats.pearson([1, 2, 3], [3, 2, 1]))
    assert_nil B::Stats.pearson([1], [2])
    assert_nil B::Stats.pearson([1, 2], [2, 3])
    assert_nil B::Stats.pearson([1, 1, 1], [2, 3, 4])
  end

  # --- Report -------------------------------------------------------------

  def test_the_replay_is_checked_against_the_stored_games
    make_experiment(stored: ->(opponent, opening, color) { opponent == 'AmiGo' && opening == 1 && color == 'white' ? 'opponent' : 'network' })
    brittleness
    assert_match(/Replay: 1 of 8 stored benchmark games differ/, @printed)
    assert_match(/AmiGo 1 white: replay network, length 93, W\+22\.5; stored opponent, length 93, B\+R/, @printed)
    assert_match(/unreliable/, @printed)
  end

  def test_a_replay_of_another_length_differs
    make_experiment(length: ->(opponent, opening, color) { [opponent, opening, color] == ['MichiWeak', 0, 'black'] ? 94 : 93 })
    brittleness
    assert_match(/Replay: 1 of 8 stored benchmark games differ/, @printed)
    assert_match(/MichiWeak 0 black: replay network, length 93, B\+R; stored network, length 94, B\+R/, @printed)
  end

  def test_a_replay_with_another_score_differs
    make_experiment(referee: ->(opponent, opening, color) { 'B+5.5' if [opponent, opening, color] == ['MichiWeak', 0, 'black'] })
    brittleness
    assert_match(/Replay: 1 of 8 stored benchmark games differ/, @printed)
    assert_match(/MichiWeak 0 black: replay network, length 93, B\+R; stored network, length 93, B\+5\.5/, @printed)
  end

  def test_a_matching_replay
    make_experiment
    brittleness
    assert_match(/Replay: all 8 stored benchmark games reproduced/, @printed)
    assert_match(/Weights a child changed \(perturb's differs\), per step: 0\.5 5–5, 0\.02 5–5\./, @printed)
  end

  # The champion wins every screen game (stored) and re-test game; child 1
  # of each step loses only its AmiGo games, child 0 every game.
  def test_the_report_on_a_known_table
    make_experiment
    brittleness(wins: ->(game) { game.player.replay? || (game.player.child == 1 && game.opponent != 'AmiGo') },
                moves: ->(game) { game.player.replay? || game.opponent != 'AmiGo' || game.opening == 1 ? 'ee' : 'dd' })
    text = report
    # Step 0.5: children's differences -8 and -4 (of 8): mean -6. Child
    # totals 0 and 4: s_T² 8. Child 0 scores 0 everywhere, child 1 0 on
    # AmiGo and 1 on MichiWeak: game means 0 and 0.5, each of the 16
    # residuals ±0.25, so MSE 1/7; z = game means - 1, var_g(z) 1/14 =
    # MSE/2, so the games part is 0 and SE² = 8/2.
    assert_match(/\| 0\.5 \| 229 \| 0\.5 \| 2 \| -6\.00 \| 2\.00 \(n 2\) \| 2\.83 \|/, text)
    # Between the steps (alike): 4 + 4.
    assert_match(/\| 0\.5 \| 0\.02 \| \+0\.00 \| 2\.83 \(n 2, 2\) \|/, text)
    # Identical: each child plays other moves than the replay only on
    # AmiGo's opening 0, both colours: 6 of 8.
    assert_match(/\| 0\.5 \|.*\| 75 % \|/, text)
    assert_match(/m = 2/, text)
    assert_match(/Between steps/, text)
    assert_match(/independence approximation/, text)
    # Child 1, re-tested best: 4 discordant games, none its: p = 1.
    assert_match(/\| 0\.5 \| best \| 1 \| -4 \| -4 \| 4 \| 0 \| 1\.0000 \| no \|/, text)
    assert_match(/\| 0\.5 \| control \| 0 \| -8 \| -8 \| 8 \| 0 \|/, text)
  end

  # Two steps, 1 best child each: m 2, so a best child is better at
  # P ≤ 0.025. Child 1 wins every game; the champion wins the re-test's
  # AmiGo games and `champion_michi` of its MichiWeak games.
  def verdict(champion_michi)
    make_experiment
    michi = 0
    brittleness('--retest-games', '12', wins: lambda do |game|
      next game.player.child == 1 || game.player.replay? if game.phase == 'screen'
      next true unless game.player.replay?

      game.opponent == 'AmiGo' || (michi += 1) <= champion_michi
    end)
    @printed[/^\| 0\.5 \| best \| 1 \|.*$/]
  end

  # 6 discordant games, all the child's: P = 1/64.
  def test_a_best_child_better_after_bonferroni
    assert_equal '| 0.5 | best | 1 | +0 | +6 | 6 | 6 | 0.0156 | yes |', verdict(0)
  end

  # 5 discordant games, all the child's: P = 1/32, below 0.05 but not
  # 0.05 / 2.
  def test_a_best_child_not_better_after_bonferroni
    assert_equal '| 0.5 | best | 1 | +0 | +5 | 5 | 5 | 0.0312 | no |', verdict(1)
  end

  # A champion with its own genes (seed2-rounds20 generation 500's) gets
  # the `own` step: perturbed with those genes, keyed by them, reported,
  # and resumed without replaying a game.
  def test_the_own_step_uses_the_champions_genes
    make_experiment(genes: { weight_changes: 26.25, weight_step: 0.00048 })
    pool = brittleness('--steps', '0.5')
    own = File.readlines(@perturb_log, chomp: true).map(&:split).select { |call| call[3] == '0.00048' }
    assert_equal [0, 1, 0, 1].map { |k| ['26.25', '0.00048', Seeds.derive(SEED, 'brittleness', 'exp', GEN, 'own', k).to_s] }.sort,
                 own.map { |call| call[2..] }.sort
    assert_equal [26.25], stored_games.select { |row| row[:step] == 'own' }.map { |row| row[:weight_changes] }.uniq
    assert_equal 2 * 8, pool.identifiers.count { |game| game.phase == 'screen' && game.player.step == 'own' }
    assert_match(/^\| own \| 26\.25 \| 0\.00048 \| 2 \| \+0\.00 \|/, @printed)
    assert_match(/m = 2/, @printed)
    @results = nil
    assert_empty brittleness('--steps', '0.5').identifiers
  end

  # A report on a hand-made table: one step, 20 children (so 2 best and 2
  # controls are re-tested and m is 1), screen rows for children 0–3
  # only, and a champion that wins 3 of 4 AmiGo and 1 of 4 MichiWeak
  # screen games.
  # A second step, 0.02, has screen rows for children 0–3 too but no
  # re-test; m is 4. With `retest_games` other than 8 the re-test games
  # are not recorded (the MDE takes only the option).
  def rich_report(retest_games: 8)
    FileUtils.mkdir_p(@out)
    store = B::Results.new(File.join(@out, 'results.sqlite3'))
    options = { 'steps' => %w[0.5 0.02], 'changes' => 229.0, 'children' => 20, 'opponents' => %w[AmiGo MichiWeak],
                'retest_games' => retest_games }
    store.check_run('exp', GEN, options, champion: 'c.ann', own: [229.0, 0.5])
    screen_keys = B.screen_keys(%w[AmiGo MichiWeak], 2)
    champion = [1, 1, 1, 0, 1, 0, 0, 0]
    store.save_champion_games('exp', GEN, screen_keys.zip(champion).map do |(opponent, opening, color), won|
      { opponent:, opening:, network_color: color, winner: won == 1 ? 'network' : 'opponent', length: 50, referee_result: 'B+R' }
    end)
    record = lambda do |phase, player, keys, wins|
      keys.zip(wins).each do |(opponent, opening, color), won|
        game = B::Game.new(generation: GEN, phase:, player:, opponent:, opening:, color:)
        store.record_game('exp', game, winner: won == 1 ? 'network' : 'opponent', failure: nil, length: 50,
                                       referee_result: 'B+R', moves_hash: 'x', duration: 0.1)
      end
    end
    @screen = { 0 => [1, 1, 1, 1, 1, 1, 0, 0], 1 => [1, 1, 1, 1, 1, 0, 0, 0],
                2 => [1, 1, 0, 0, 1, 0, 0, 0], 3 => [0, 1, 0, 0, 0, 0, 0, 0] }
    @retest = { 0 => [1, 1, 1, 0, 1, 1, 0, 1], 1 => [1, 0, 1, 1, 1, 1, 1, 1],
                2 => [1, 0, 0, 0, 1, 1, 0, 0], 3 => [1, 0, 1, 0, 0, 0, 0, 0] }
    @screen_002 = { 0 => [0, 0, 1, 0, 1, 0, 0, 0], 1 => [1, 1, 1, 0, 0, 0, 0, 0],
                    2 => [1, 1, 1, 0, 1, 0, 1, 0], 3 => [1, 0, 1, 0, 1, 0, 0, 0] }
    @champion_retest = [1, 0, 1, 0, 1, 1, 0, 0]
    retest_keys = B.retest_keys(8, %w[AmiGo MichiWeak])
    record.call('retest', B::CHAMPION, retest_keys, @champion_retest) if retest_games == 8
    @screen.each_key do |child|
      record.call('screen', player('0.5', child), screen_keys, @screen[child])
      record.call('screen', player('0.02', child), screen_keys, @screen_002[child])
      record.call('retest', player('0.5', child), retest_keys, @retest[child]) if retest_games == 8
    end
    store.record_selection('exp', GEN, @screen.keys.map do |child|
      { step: '0.5', weight_changes: 229.0, weight_step: 0.5, child:, role: child < 2 ? 'best' : 'control',
        screen_difference: @screen[child].sum - champion.sum }
    end)
    store.close
    @champion_screen = champion
    report
  end

  # The main comparison: 0.5's children win 6, 5, 3 and 1, 0.02's 2, 3,
  # 5 and 3, so 0.5 − 0.02 is +0.50.
  def test_the_report_compares_the_steps
    text = rich_report
    se = Math.sqrt(B::Stats.crossed_variance(@screen.values, @screen_002.values))
    assert_includes text, "| 0.5 | 0.02 | +0.50 | #{format('%.2f', se)} (n 4, 4) |"
  end

  # The MDE at the re-test's size and the Bonferroni level, m = 2 steps ×
  # 2 best; 0.02's discordance: AmiGo 2, 0, 0, 1 of 4, MichiWeak 0, 1, 1,
  # 0 of 4.
  def test_the_report_gives_each_steps_mde
    text = rich_report(retest_games: 600)
    { '0.5' => (0.3125 + 0.125) / 2, '0.02' => ((3 / 16.0) + (2 / 16.0)) / 2 }.each do |step, d|
      mdes = [0.5, 0.8].map { |power| format('%.1f', 100 * B::Stats.mde(d, 600, Rational(1, 20) / 4, power)) }
      assert_includes text, "| #{step} | #{format('%.3f', d)} | #{mdes.join(' | ')} |"
    end
  end

  def test_the_report_summarises_the_retest_by_role
    text = rich_report
    champion = @champion_retest
    level = B::Stats.crossed_variance([@retest[2], @retest[3]], champion)
    gap = B::Stats.crossed_variance([@retest[0], @retest[1]], [@retest[2], @retest[3]])
    r = B::Stats.pearson([2, 1, -1, -3], [2, 3, -1, -2])
    # Controls win 3 and 2 against the champion's 4; best 6 and 7.
    row = "| 0.5 | -1.50 | #{format('%.2f', Math.sqrt(level))} (n 2) | +4.00 | " \
          "#{format('%.2f', Math.sqrt(gap))} (n 2, 2) | #{format('%+.2f', r)} (n 4) |"
    assert_includes text, row
    assert_match(/Screen–re-test correlation: #{Regexp.escape(format('%+.2f', r))} \(n 4\)/, text)
  end

  # Per opponent: AmiGo 1, 1, 1 and 2 of 4 games differ (0.3125),
  # MichiWeak 1, 0, 0, 1 (0.125); the MDE's d is their mean.
  def test_the_report_gives_discordance_per_opponent
    text = rich_report
    assert_match(/\| 0\.5 \| 229 \| 0\.5 \| 4 \| [^\n]*\| #{format('%.2f', 0.3125)}\/#{format('%.2f', 0.125)} \|/, text)
    assert_match(/^\| 0\.5 \| #{Regexp.escape(format('%.3f', 0.21875))} \|/, text)
  end

  # The champion's rates 3/4 and 1/4: SD √(4 × 3/16 × 2) = √1.5.
  def test_the_independence_band_takes_each_opponents_rate
    text = rich_report
    assert_includes text, "within ±#{format('%.1f', 1.96 * Math.sqrt(1.5))} of 0 (95 %, SD #{format('%.2f', Math.sqrt(1.5))})"
  end

  # --- Whole reports -------------------------------------------------------

  # perturb's differs varies by child: the seed's last two digits + 10.
  def perturb_differs_by_seed
    File.write(@perturb, <<~RUBY)
      #!#{RbConfig.ruby}
      net, out, changes, step, seed = ARGV
      File.binwrite(out, File.binread(net) + "child \#{changes} \#{step} \#{seed}")
      puts "differs=\#{(seed.to_i % 100) + 10}"
    RUBY
  end

  # The champion's stored games: AmiGo lost only on opening 1 with
  # White, MichiWeak won only on opening 0 with Black (3 and 1 of 4).
  STORED = lambda do |opponent, opening, color|
    won = opponent == 'AmiGo' ? [opening, color] != [1, 'white'] : [opening, color] == [0, 'black']
    won ? 'network' : 'opponent'
  end

  def stored_win?(game) = STORED.call(game.opponent, game.opening, game.color) == 'network'

  # Who wins what in the whole-report runs: the replay plays the stored
  # games; on the re-test the champion wins 4 of 8.
  def scripted_wins(game)
    key = [game.opponent, game.opening, game.color]
    player = game.player
    return stored_win?(game) if game.phase == 'screen' && player.replay?

    if game.phase == 'screen'
      case [player.step, player.child]
      when ['0.5', 0] then game.opponent == 'AmiGo'
      when ['0.5', 1] then stored_win?(game) || key == ['MichiWeak', 1, 'white']
      when ['0.02', 1] then false
      when ['own', 1] then stored_win?(game) && key != ['AmiGo', 0, 'black']
      else stored_win?(game)
      end
    else
      champion = game.opponent == 'AmiGo' ? key != ['AmiGo', 1, 'white'] : key == ['MichiWeak', 0, 'black']
      case [player.step, player.child]
      when ['0.5', 0] then game.opponent == 'AmiGo' || game.opening.zero?
      when ['0.02', 0] then champion || key == ['MichiWeak', 1, 'black']
      when ['0.02', 1] then key == ['AmiGo', 0, 'black']
      when ['own', 1] then champion && key != ['AmiGo', 1, 'black']
      else champion
      end
    end
  end

  def scripted_moves(game)
    return nil if game.phase == 'screen' && [game.opponent, game.opening, game.color] == ['MichiWeak', 1, 'white']
    return nil if game.player.step == '0.5' && game.player.child.zero? && [game.opponent, game.opening, game.color] == ['AmiGo', 1, 'black']
    return 'ee' if game.player.replay? || game.player.step == 'own'
    return 'dd' if game.player.step == '0.5'

    game.opponent == 'AmiGo' ? 'cc' : 'ee'
  end

  def scripted_fixture(game)
    return 'no_referee_score' if game.phase == 'screen' && game.player.replay? && [game.opponent, game.opening, game.color] == ['AmiGo', 0, 'white']

    # The champion's re-test game every child wins: left out.
    return 'no_referee_score' if game.phase == 'retest' && game.player.replay? && [game.opponent, game.opening, game.color] == ['AmiGo', 0, 'black']
    return unless game.phase == 'retest' && game.player.step == '0.02' && game.player.child == 1

    # A bot that crashes after the network's win: a failure, twice.
    { ['MichiWeak', 1, 'black'] => 'white_crashed', ['MichiWeak', 1, 'white'] => 'black_crashed' }[
      [game.opponent, game.opening, game.color]]
  end

  # The whole text, so no figure or line can change unnoticed. Checked by
  # hand: the champion wins 4 of 8 screen games (AmiGo 3/4, MichiWeak 1/4:
  # band SD √1.5) and 4 of 8 re-test games; a game whose SGF is missing
  # for the child and the replay (MichiWeak 1 white) is not identical, so
  # `own`, whose moves are otherwise the replay's, has 7 of 8 (88 %); the
  # replay's failed game is listed with its reason; the selection, made
  # without a child's failure, has no --accept-failures line. The
  # champion's failed re-test game (AmiGo 0 black, which every child
  # wins) is left out: counted as its loss, it would add a discordant
  # win to every child.
  def test_the_whole_report_with_an_own_step
    make_experiment(genes: { weight_changes: 26.25, weight_step: 0.00048 }, stored: STORED)
    perturb_differs_by_seed
    brittleness('--steps', '0.5,0.02', wins: method(:scripted_wins), moves: method(:scripted_moves),
                                        fixture: method(:scripted_fixture))
    assert_equal <<~TEXT, report
      # exp generation 10

      Champion c.ann, own genes: weight_changes 26.25, weight_step 0.00048.
      2 children a step; opponents AmiGo, MichiWeak; screen 8 games a player (the benchmark's), re-test 8 fresh games.
      Screen: 56 games stored, 1 failures (1 × no referee score: ?).
      Re-test: 56 games stored, 3 failures (2 × MichiWeak crashed; 1 × no referee score: ?).
      Weights a child changed (perturb's differs), per step: 0.5 59–76, 0.02 20–30, own 35–89.

      Replay: 1 of 8 stored benchmark games differ: this champion's results are unreliable.
      - AmiGo 0 white: replay no referee score: ?, length 93, ?; stored network, length 93, W+22.5

      ## Screen: children against the champion on its 8 benchmark games

      The champion won 4 of 8 (stored). Differences are the children's wins minus the champion's, the mean over a step's children labelled as its champion-relative level; SEs from the crossed children × games formula, with n children. Identical games: share of a child's games move for move the replay's. Discordance: share of games a child's result differs from the champion's, per opponent (AmiGo/MichiWeak).

      | Step | Changes | Weight step | Children | Mean difference | SE (crossed) | Observed SD | Identical games | Discordance |
      | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
      | 0.5 | 229 | 0.5 | 2 | +0.50 | 0.50 (n 2) | 0.71 | 0 % | 0.12/0.25 |
      | 0.02 | 229 | 0.02 | 2 | -2.00 | 2.00 (n 2) | 2.83 | 38 % | 0.38/0.12 |
      | own | 26.25 | 0.00048 | 2 | -0.50 | 0.50 (n 2) | 0.71 | 88 % | 0.12/0.00 |

      Null band of the screen, independence approximation: a child as strong as the champion lands within ±2.4 of 0 (95 %, SD 1.22); compare the observed SD above. Children agree with the champion more than independence predicts, so the band is too wide.

      ## Between steps (screen, wins of 8)

      | Step A | Step B | A − B | SE (crossed) |
      | --- | --- | ---: | ---: |
      | 0.5 | 0.02 | +2.50 | 2.06 (n 2, 2) |
      | 0.5 | own | +1.00 | 0.71 (n 2, 2) |
      | 0.02 | own | -1.50 | 2.06 (n 2, 2) |

      ## Re-test on 8 fresh games (wins of 8)

      The champion won 3 of 7: 1 of its re-test games failed; they are left out of every comparison below and replayed by the same command. Improvement: a re-tested best child is better when its wins among the games its result differs from the champion's, k of n_d, satisfy P(Bin(n_d, ½) ≥ k) ≤ 0.05 / m (exact one-sided sign test, Bonferroni over the champion's re-tested best children, m = 3).

      | Step | Role | Child | Screen difference | Re-test difference | n_d | k | P | Better |
      | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
      | 0.02 | best | 0 | +0 | +1 | 1 | 1 | 0.5000 | no |
      | 0.02 | control | 1 | -4 | -3 | 3 | 0 | 1.0000 | — |
      | 0.5 | best | 1 | +1 | +0 | 0 | 0 | 1.0000 | no |
      | 0.5 | control | 0 | +0 | +2 | 2 | 2 | 0.2500 | — |
      | own | best | 0 | +0 | +0 | 0 | 0 | 1.0000 | no |
      | own | control | 1 | -1 | -1 | 1 | 0 | 1.0000 | — |

      Controls against the champion (an unbiased level only as far as the screen does not predict the re-test), the re-tested best minus the controls, and the screen–re-test correlation over both, each with n (a t interval on n − 1 degrees of freedom applies to a few children):

      | Step | Controls − champion | SE (crossed) | Best − controls | SE (crossed) | Screen–re-test correlation |
      | --- | ---: | ---: | ---: | ---: | ---: |
      | 0.5 | +2.00 | n/a (n 1) | -2.00 | n/a (n 1, 1) | n/a (n 2) |
      | 0.02 | -3.00 | n/a (n 1) | +4.00 | n/a (n 1, 1) | n/a (n 2) |
      | own | -1.00 | n/a (n 1) | +1.00 | n/a (n 1, 1) | n/a (n 2) |

      Screen–re-test correlation: +0.82 (n 6) over every re-tested child.

      ## Smallest detectable improvement (estimate, percentage points of the 8 re-test games)

      Model: an effect δ makes the child win a game its result differs from the champion's with probability (1 + δ/d) / 2, d the step's screen discordance averaged over the opponents, n_d = d × 8; the sign test at 0.05 / 3. A null result means no child better by at least this much, not never.

      | Step | d | 50 % power | 80 % power |
      | --- | ---: | ---: | ---: |
      | 0.5 | 0.188 | n/a | n/a |
      | 0.02 | 0.250 | n/a | n/a |
      | own | 0.062 | n/a | n/a |
    TEXT
  end

  # The champion's genes are the 0.5 step's, so the header says so and
  # no `own` row appears.
  def test_the_whole_report_without_an_own_step
    make_experiment(stored: STORED)
    brittleness('--steps', '0.5,0.02', wins: method(:scripted_wins), moves: method(:scripted_moves))
    assert_equal <<~TEXT, report
      # exp generation 10

      Champion c.ann, own genes: weight_changes 229, weight_step 0.5 (the same as a fixed step: no own step).
      2 children a step; opponents AmiGo, MichiWeak; screen 8 games a player (the benchmark's), re-test 8 fresh games.
      Screen: 40 games stored, 0 failures.
      Re-test: 40 games stored, 0 failures.
      Weights a child changed (perturb's differs), per step: 0.5 5–5, 0.02 5–5.

      Replay: all 8 stored benchmark games reproduced (winner, length, referee result).

      ## Screen: children against the champion on its 8 benchmark games

      The champion won 4 of 8 (stored). Differences are the children's wins minus the champion's, the mean over a step's children labelled as its champion-relative level; SEs from the crossed children × games formula, with n children. Identical games: share of a child's games move for move the replay's. Discordance: share of games a child's result differs from the champion's, per opponent (AmiGo/MichiWeak).

      | Step | Changes | Weight step | Children | Mean difference | SE (crossed) | Observed SD | Identical games | Discordance |
      | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
      | 0.5 | 229 | 0.5 | 2 | +0.50 | 0.50 (n 2) | 0.71 | 0 % | 0.12/0.25 |
      | 0.02 | 229 | 0.02 | 2 | -2.00 | 2.00 (n 2) | 2.83 | 38 % | 0.38/0.12 |

      Null band of the screen, independence approximation: a child as strong as the champion lands within ±2.4 of 0 (95 %, SD 1.22); compare the observed SD above. Children agree with the champion more than independence predicts, so the band is too wide.

      ## Between steps (screen, wins of 8)

      | Step A | Step B | A − B | SE (crossed) |
      | --- | --- | ---: | ---: |
      | 0.5 | 0.02 | +2.50 | 2.06 (n 2, 2) |

      ## Re-test on 8 fresh games (wins of 8)

      The champion won 4. Improvement: a re-tested best child is better when its wins among the games its result differs from the champion's, k of n_d, satisfy P(Bin(n_d, ½) ≥ k) ≤ 0.05 / m (exact one-sided sign test, Bonferroni over the champion's re-tested best children, m = 2).

      | Step | Role | Child | Screen difference | Re-test difference | n_d | k | P | Better |
      | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
      | 0.02 | best | 0 | +0 | +1 | 1 | 1 | 0.5000 | no |
      | 0.02 | control | 1 | -4 | -3 | 3 | 0 | 1.0000 | — |
      | 0.5 | best | 1 | +1 | +0 | 0 | 0 | 1.0000 | no |
      | 0.5 | control | 0 | +0 | +2 | 2 | 2 | 0.2500 | — |

      Controls against the champion (an unbiased level only as far as the screen does not predict the re-test), the re-tested best minus the controls, and the screen–re-test correlation over both, each with n (a t interval on n − 1 degrees of freedom applies to a few children):

      | Step | Controls − champion | SE (crossed) | Best − controls | SE (crossed) | Screen–re-test correlation |
      | --- | ---: | ---: | ---: | ---: | ---: |
      | 0.5 | +2.00 | n/a (n 1) | -2.00 | n/a (n 1, 1) | n/a (n 2) |
      | 0.02 | -3.00 | n/a (n 1) | +4.00 | n/a (n 1, 1) | n/a (n 2) |

      Screen–re-test correlation: +0.84 (n 4) over every re-tested child.

      ## Smallest detectable improvement (estimate, percentage points of the 8 re-test games)

      Model: an effect δ makes the child win a game its result differs from the champion's with probability (1 + δ/d) / 2, d the step's screen discordance averaged over the opponents, n_d = d × 8; the sign test at 0.05 / 2. A null result means no child better by at least this much, not never.

      | Step | d | 50 % power | 80 % power |
      | --- | ---: | ---: | ---: |
      | 0.5 | 0.188 | n/a | n/a |
      | 0.02 | 0.250 | n/a | n/a |
    TEXT
  end

  # A directory as a run leaves it while it plays: generation 10 has a
  # partial replay, children with partial and no screens, and a partial
  # re-test of a control; generation 20 a partial re-test of the
  # champion and nothing else.
  def partial_directory
    FileUtils.mkdir_p(@out)
    store = B::Results.new(File.join(@out, 'results.sqlite3'))
    screen_keys = B.screen_keys(%w[AmiGo MichiWeak], 2)
    retest_keys = B.retest_keys(8, %w[AmiGo MichiWeak])
    options = { 'steps' => %w[0.5 0.02], 'changes' => 229.0, 'children' => 3, 'opponents' => %w[AmiGo MichiWeak],
                'retest_games' => 8 }
    record = lambda do |generation, phase, player, keys, wins|
      keys.each do |opponent, opening, color|
        game = B::Game.new(generation:, phase:, player:, opponent:, opening:, color:)
        store.record_game('exp', game, winner: wins.call(opponent, opening, color) ? 'network' : 'opponent',
                                       failure: nil, length: 93, referee_result: 'B+R', moves_hash: 'x', duration: 0.1)
      end
    end
    stored = ->(*key) { STORED.call(*key) == 'network' }
    [10, 20].each do |generation|
      store.check_run('exp', generation, options, champion: 'c.ann', own: [229.0, 0.5])
      store.save_champion_games('exp', generation, screen_keys.map do |opponent, opening, color|
        winner = STORED.call(opponent, opening, color)
        { opponent:, opening:, network_color: color, winner:, length: 93, referee_result: 'B+R' }
      end)
    end
    record.call(10, 'screen', B::CHAMPION, screen_keys.first(5), stored)
    record.call(10, 'screen', player('0.5', 0), screen_keys, ->(*) { true })
    record.call(10, 'screen', player('0.5', 1), screen_keys, stored)
    record.call(10, 'screen', player('0.5', 2), screen_keys.first(3), stored)
    record.call(10, 'screen', player('0.02', 0), screen_keys, ->(opponent, *) { opponent == 'AmiGo' })
    record.call(10, 'screen', player('0.02', 1), screen_keys.first(6), stored)
    store.record_selection('exp', 10, [
                             { step: '0.5', weight_changes: 229.0, weight_step: 0.5, child: 0, role: 'best', screen_difference: 4 },
                             { step: '0.5', weight_changes: 229.0, weight_step: 0.5, child: 1, role: 'control', screen_difference: 0 }
                           ])
    record.call(10, 'retest', B::CHAMPION, retest_keys, ->(opponent, *) { opponent == 'AmiGo' })
    record.call(10, 'retest', player('0.5', 0), retest_keys, ->(*) { true })
    record.call(10, 'retest', player('0.5', 1), retest_keys.first(5), ->(*) { true })
    record.call(20, 'retest', B::CHAMPION, retest_keys.first(3), ->(*) { true })
    store.close
  end

  # --report-only while a run plays: incomplete screens and re-tests are
  # named and left out of every figure, and the replay is counted so far.
  def test_the_report_takes_only_the_given_generations
    partial_directory
    text = report('exp', [20])
    assert text.start_with?('# exp generation 20')
    refute_includes text, 'generation 10'
  end

  def test_the_whole_report_of_a_directory_still_playing
    partial_directory
    assert_equal <<~TEXT, report
      # exp generation 10

      Champion c.ann, own genes: weight_changes 229, weight_step 0.5 (the same as a fixed step: no own step).
      3 children a step; opponents AmiGo, MichiWeak; screen 8 games a player (the benchmark's), re-test 8 fresh games.
      Screen: 38 games stored, 0 failures.
      Re-test: 21 games stored, 0 failures.

      Replay: 5 of 8 stored benchmark games replayed so far.
      Replay: all 5 stored benchmark games reproduced (winner, length, referee result).

      ## Screen: children against the champion on its 8 benchmark games

      The champion won 4 of 8 (stored). Differences are the children's wins minus the champion's, the mean over a step's children labelled as its champion-relative level; SEs from the crossed children × games formula, with n children. Identical games: share of a child's games move for move the replay's. Discordance: share of games a child's result differs from the champion's, per opponent (AmiGo/MichiWeak).

      | Step | Changes | Weight step | Children | Mean difference | SE (crossed) | Observed SD | Identical games | Discordance |
      | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
      | 0.5 | 229 | 0.5 | 2 | +2.00 | 2.00 (n 2) | 2.83 | n/a | 0.12/0.38 |
      | 0.02 | 229 | 0.02 | 1 | +0.00 | n/a (n 1) | n/a | n/a | 0.25/0.25 |

      Left out until their screen is complete: 0.5 child 2 (3 of 8), 0.02 child 1 (6 of 8), 0.02 child 2 (0 of 8).

      Null band of the screen, independence approximation: a child as strong as the champion lands within ±2.4 of 0 (95 %, SD 1.22); compare the observed SD above. Children agree with the champion more than independence predicts, so the band is too wide.

      ## Between steps (screen, wins of 8)

      | Step A | Step B | A − B | SE (crossed) |
      | --- | --- | ---: | ---: |
      | 0.5 | 0.02 | +2.00 | n/a (n 2, 1) |

      ## Re-test on 8 fresh games (wins of 8)

      The champion won 4. Improvement: a re-tested best child is better when its wins among the games its result differs from the champion's, k of n_d, satisfy P(Bin(n_d, ½) ≥ k) ≤ 0.05 / m (exact one-sided sign test, Bonferroni over the champion's re-tested best children, m = 2).

      | Step | Role | Child | Screen difference | Re-test difference | n_d | k | P | Better |
      | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
      | 0.5 | best | 0 | +4 | +4 | 4 | 4 | 0.0625 | no |
      | 0.5 | control | 1 | +0 | 5 of 8 games | | | | |

      A child whose re-test is not complete is left out of the summary below.

      Controls against the champion (an unbiased level only as far as the screen does not predict the re-test), the re-tested best minus the controls, and the screen–re-test correlation over both, each with n (a t interval on n − 1 degrees of freedom applies to a few children):

      | Step | Controls − champion | SE (crossed) | Best − controls | SE (crossed) | Screen–re-test correlation |
      | --- | ---: | ---: | ---: | ---: | ---: |
      | 0.5 | n/a | n/a (n 0) | n/a | n/a (n 1, 0) | n/a (n 1) |
      | 0.02 | n/a | n/a (n 0) | n/a | n/a (n 0, 0) | n/a (n 0) |

      Screen–re-test correlation: n/a (n 1) over every re-tested child.

      ## Smallest detectable improvement (estimate, percentage points of the 8 re-test games)

      Model: an effect δ makes the child win a game its result differs from the champion's with probability (1 + δ/d) / 2, d the step's screen discordance averaged over the opponents, n_d = d × 8; the sign test at 0.05 / 2. A null result means no child better by at least this much, not never.

      | Step | d | 50 % power | 80 % power |
      | --- | ---: | ---: | ---: |
      | 0.5 | 0.250 | n/a | n/a |
      | 0.02 | 0.250 | n/a | n/a |

      # exp generation 20

      Champion c.ann, own genes: weight_changes 229, weight_step 0.5 (the same as a fixed step: no own step).
      3 children a step; opponents AmiGo, MichiWeak; screen 8 games a player (the benchmark's), re-test 8 fresh games.
      Screen: 0 games stored, 0 failures.
      Re-test: 3 games stored, 0 failures.

      Replay: 0 of 8 stored benchmark games replayed so far.

      ## Screen: children against the champion on its 8 benchmark games

      The champion won 4 of 8 (stored). Differences are the children's wins minus the champion's, the mean over a step's children labelled as its champion-relative level; SEs from the crossed children × games formula, with n children. Identical games: share of a child's games move for move the replay's. Discordance: share of games a child's result differs from the champion's, per opponent (AmiGo/MichiWeak).

      | Step | Changes | Weight step | Children | Mean difference | SE (crossed) | Observed SD | Identical games | Discordance |
      | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
      | 0.5 | 229 | 0.5 | 0 | n/a | n/a (n 0) | n/a | n/a | n/a |
      | 0.02 | 229 | 0.02 | 0 | n/a | n/a (n 0) | n/a | n/a | n/a |

      Left out until their screen is complete: 0.5 child 0 (0 of 8), 0.5 child 1 (0 of 8), 0.5 child 2 (0 of 8), 0.02 child 0 (0 of 8), 0.02 child 1 (0 of 8), 0.02 child 2 (0 of 8).

      Null band of the screen, independence approximation: a child as strong as the champion lands within ±2.4 of 0 (95 %, SD 1.22); compare the observed SD above. Children agree with the champion more than independence predicts, so the band is too wide.

      ## Between steps (screen, wins of 8)

      | Step A | Step B | A − B | SE (crossed) |
      | --- | --- | ---: | ---: |
      | 0.5 | 0.02 | n/a | n/a |

      ## Re-test on 8 fresh games (wins of 8)

      Not complete: the champion has 3 of 8 re-test games; 0 children selected.

      ## Smallest detectable improvement (estimate, percentage points of the 8 re-test games)

      Model: an effect δ makes the child win a game its result differs from the champion's with probability (1 + δ/d) / 2, d the step's screen discordance averaged over the opponents, n_d = d × 8; the sign test at 0.05 / 2. A null result means no child better by at least this much, not never.

      | Step | d | 50 % power | 80 % power |
      | --- | ---: | ---: | ---: |
      | 0.5 | n/a | n/a | n/a |
      | 0.02 | n/a | n/a | n/a |
    TEXT
  end

  def test_estimates_below_two_children_are_na
    make_experiment
    brittleness('--children', '1', '--steps', '0.5')
    assert_match(/\| 0\.5 \| 229 \| 0\.5 \| 1 \| \+0\.00 \| n\/a \(n 1\) \| n\/a \|/, @printed)
    assert_match(/Screen–re-test correlation: n\/a \(n 1\)/, @printed)
    assert_match(/n\/a/, @printed)
  end

  def test_the_report_needs_only_the_output_directory
    make_experiment
    brittleness
    printed = @printed
    FileUtils.rm_rf(File.join(@tmp, 'experiments'))
    assert_equal printed[printed.index('# exp generation 10')..], report('exp', [GEN])
    assert_equal report, report('exp', nil)
    assert_raises(B::Refused) { report('other', nil) }
  end
end
