require 'minitest/autorun'
require 'tmpdir'
require_relative '../ruby/all'

$stop_now = false

class RunExperimentTest < Minitest::Test
  SETTINGS = { 'concurrency' => 2, 'one_generation' => true, 'keep_every' => 0 }.freeze

  # Replaces RunGeneration.call with `stub` for the duration of the block.
  def with_generation(stub)
    original = RunGeneration.method(:call)
    RunGeneration.define_singleton_method(:call, stub)
    yield
  ensure
    RunGeneration.singleton_class.send(:remove_method, :call)
    RunGeneration.define_singleton_method(:call, original)
  end

  def generations_run(database, results, settings = SETTINGS, capture: true)
    called = []
    stub = lambda do |generation, _settings, _pool, _store|
      called << generation
      results.fetch(generation, nil)
    end
    with_generation(stub) do
      capture ? capture_io { RunExperiment.call(settings, database) } : RunExperiment.call(settings, database)
    end
    called
  end

  # Replaces CheckpointBenchmark.call with `stub` for the duration of the
  # block.
  def with_benchmark(stub)
    original = CheckpointBenchmark.method(:call)
    CheckpointBenchmark.define_singleton_method(:call, stub)
    yield
  ensure
    CheckpointBenchmark.singleton_class.send(:remove_method, :call)
    CheckpointBenchmark.define_singleton_method(:call, original)
  end

  # The checkpoints benchmarked before the run resumes, each with the
  # directory it ran in, that directory's files, and its heading; and the
  # generations run after, each with whether it ran in the experiment
  # directory.
  def catch_up(last_generation, keep_every:)
    database = ExperimentDatabase.new(':memory:')
    (0..last_generation).each do |g|
      database.save_state(g, { 'round' => 0, 'players' => {}, 'ranking' => [], 'games' => [] })
    end
    benchmarked = []
    generations = []
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        FileUtils.mkdir(RunGeneration::WORK)
        File.write(File.join(RunGeneration::WORK, 'stale'), '')
        # Runs as a method of CheckpointBenchmark, so it records its
        # arguments and the test checks them afterwards.
        passed = []
        benchmark = lambda do |generation, settings, pool, store, heading:|
          passed << [settings, pool, store]
          benchmarked << [generation, File.basename(Dir.pwd), Dir.children('.'), heading]
          false
        end
        generation = lambda do |g, _settings, _pool, _store|
          generations << [g, File.realpath(Dir.pwd) == File.realpath(dir)]
          nil
        end
        with_benchmark(benchmark) do
          with_generation(generation) do
            capture_io { RunExperiment.call(SETTINGS.merge('keep_every' => keep_every), database) }
          end
        end
        passed.each do |settings, pool, store|
          assert_equal SETTINGS.merge('keep_every' => keep_every), settings
          assert_kind_of WorkerPool, pool
          assert_same database, store
        end
      end
    end
    [benchmarked, generations]
  end

  # An earlier checkpoint plays the benchmark games it lacks, as after
  # benchmark_games was raised, in an emptied work/; the generation the run
  # resumes with finishes its own benchmark.
  def test_earlier_checkpoints_play_their_missing_benchmark_games_before_the_run_resumes
    benchmarked, generations = catch_up(250, keep_every: 100)
    assert_equal [[0, 'work', [], '*** BENCHMARK OF GENERATION 0 ***'],
                  [100, 'work', [], '*** BENCHMARK OF GENERATION 100 ***'],
                  [200, 'work', [], '*** BENCHMARK OF GENERATION 200 ***']], benchmarked
    # Back in the experiment directory, as RunGeneration expects.
    assert_equal [['250', true]], generations
  end

  def test_the_generation_the_run_resumes_with_is_not_caught_up
    benchmarked, = catch_up(200, keep_every: 100)
    assert_equal [0, 100], benchmarked.map(&:first)
  end

  def test_no_catch_up_without_checkpoints
    benchmarked, = catch_up(5, keep_every: 0)
    assert_empty benchmarked
  end

  def test_a_new_experiment_catches_up_nothing
    benchmarked, = catch_up(0, keep_every: 1)
    assert_empty benchmarked
  end

  def test_resumes_with_the_last_generation_in_the_database
    database = ExperimentDatabase.new(':memory:')
    (0..2).each { |g| database.save_state(g, { 'round' => 0, 'players' => {}, 'ranking' => [], 'games' => [] }) }
    assert_equal ['2'], generations_run(database, {})
  end

  def test_moves_on_when_the_last_generation_is_already_done
    database = ExperimentDatabase.new(':memory:')
    (0..2).each { |g| database.save_state(g, { 'round' => 1, 'players' => {}, 'ranking' => [], 'games' => [] }) }
    assert_equal %w[2 3], generations_run(database, { '2' => :already_done })
  end

  def test_a_new_experiment_starts_at_generation_zero
    assert_equal ['0'], generations_run(ExperimentDatabase.new(':memory:'), {})
  end

  def database_with_generations(last, round: 0)
    database = ExperimentDatabase.new(':memory:')
    (0..last).each { |g| database.save_state(g, { 'round' => round, 'players' => {}, 'ranking' => [], 'games' => [] }) }
    database
  end

  def until_settings(last)
    SETTINGS.merge('one_generation' => false, 'until_generation' => last)
  end

  def test_a_run_until_a_generation_stops_after_that_generation
    assert_equal %w[0 1 2], generations_run(ExperimentDatabase.new(':memory:'), {}, until_settings(2))
  end

  # The last generation in the database is finished, so the run moves on
  # and stops after the until generation.
  def test_a_resumed_run_until_a_generation_runs_up_to_it
    assert_equal %w[2 3 4], generations_run(database_with_generations(2, round: 1), { '2' => :already_done }, until_settings(4))
  end

  def test_a_run_until_the_finished_last_generation_runs_no_new_one
    assert_equal ['2'], generations_run(database_with_generations(2, round: 1), { '2' => :already_done }, until_settings(2))
  end

  # A run that has not reached its until generation yet still catches up
  # the earlier checkpoints, as after benchmark_games was raised.
  def test_a_run_until_a_later_generation_catches_up_earlier_checkpoints
    benchmarked = []
    benchmark = lambda do |generation, _settings, _pool, _store, heading:|
      benchmarked << generation
      false
    end
    called = nil
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        with_benchmark(benchmark) do
          called = generations_run(database_with_generations(2), {}, until_settings(4).merge('keep_every' => 1))
        end
      end
    end
    assert_equal [0, 1], benchmarked
    assert_equal %w[2 3 4], called
  end

  # The until generation is behind the database: nothing to run, and no
  # checkpoint is caught up either.
  def test_a_run_until_a_generation_already_passed_runs_nothing
    benchmark = ->(*_args, **_opts) { flunk 'caught up a checkpoint' }
    called = nil
    out = nil
    with_benchmark(benchmark) do
      out, = capture_io do
        called = generations_run(database_with_generations(5), {}, until_settings(3).merge('keep_every' => 1), capture: false)
      end
    end
    assert_empty called
    assert_match(/Generation 5 is past generation 3, the last to run; nothing to do\./, out)
  end

  # A stop prints its report and exits 1, not 130 and with no backtrace,
  # and still waits for the pool's threads.
  def test_an_arena_stop_exits_1_with_its_report
    stopped = nil
    generation = lambda do |_generation, _settings, pool, _store|
      stopped = pool
      raise RunGeneration::ArenaStopped, "Arena chunk arena-0 stopped.\nThe run stopped; resume after fixing the cause."
    end
    err = nil
    with_generation(generation) do
      _, err = capture_io do
        assert_equal 1, assert_raises(SystemExit) { RunExperiment.call(SETTINGS, ExperimentDatabase.new(':memory:')) }.status
      end
    end
    assert_equal "\nArena chunk arena-0 stopped.\nThe run stopped; resume after fixing the cause.\n", err
    assert stopped.stopped?
  end

  # Damaged networks stop the run the same way.
  def test_damaged_networks_exit_1_with_the_report
    generation = lambda do |_generation, _settings, _pool, _store|
      raise RunGeneration::NetworksDamaged, 'networks/3/ does not match the database.'
    end
    err = nil
    with_generation(generation) do
      _, err = capture_io do
        assert_equal 1, assert_raises(SystemExit) { RunExperiment.call(SETTINGS, ExperimentDatabase.new(':memory:')) }.status
      end
    end
    assert_equal "\nnetworks/3/ does not match the database.\n", err
  end

  # So does a breeding failure.
  def test_a_breeding_failure_exits_1_with_the_report
    generation = lambda do |_generation, _settings, _pool, _store|
      raise RunGeneration::BreedingFailed, 'evolve failed to breed 0.ann.'
    end
    err = nil
    with_generation(generation) do
      _, err = capture_io do
        assert_equal 1, assert_raises(SystemExit) { RunExperiment.call(SETTINGS, ExperimentDatabase.new(':memory:')) }.status
      end
    end
    assert_equal "\nevolve failed to breed 0.ann.\n", err
  end

  def test_ctrl_c_starts_no_queued_game
    previous = trap('INT', 'DEFAULT')
    Dir.mktmpdir do |dir|
      jobs = File.join(dir, 'jobs')
      Dir.mkdir(jobs)
      Dir.chdir(dir) do
        # Stands in for a round with more games than threads, interrupted
        # while the first two play.
        generation = lambda do |_generation, _settings, pool, _store|
          4.times { |i| pool.submit("sleep 0.3; touch #{jobs}/#{i}", i) }
          sleep 0.1
          Process.kill('INT', Process.pid)
          2.times { pool.next_finished }
        end
        with_generation(generation) do
          capture_io { RunExperiment.call(SETTINGS, ExperimentDatabase.new(':memory:')) }
        end
      end
      assert $stop_now
      assert_equal %w[0 1], Dir.children(jobs).sort
    end
  ensure
    $stop_now = false
    trap('INT', previous || 'DEFAULT')
  end
end
