require 'minitest/autorun'
require 'tmpdir'
require_relative '../ruby/all'

$stop_now = false

class RunExperimentTest < Minitest::Test
  SETTINGS = { 'concurrency' => '2', 'one_generation' => true }.freeze

  # Replaces RunGeneration.call with `stub` for the duration of the block.
  def with_generation(stub)
    original = RunGeneration.method(:call)
    RunGeneration.define_singleton_method(:call, stub)
    yield
  ensure
    RunGeneration.singleton_class.send(:remove_method, :call)
    RunGeneration.define_singleton_method(:call, original)
  end

  def generations_run(database, results)
    called = []
    stub = lambda do |generation, _settings, _pool, _store|
      called << generation
      results.fetch(generation, nil)
    end
    with_generation(stub) { capture_io { RunExperiment.call(SETTINGS, database) } }
    called
  end

  def test_resumes_with_the_last_generation_in_the_database
    database = ExperimentDatabase.new(':memory:')
    (0..2).each { |g| database.save_state(g, 'round' => 0, 'players' => {}, 'ranking' => [], 'games' => []) }
    assert_equal ['2'], generations_run(database, {})
  end

  def test_moves_on_when_the_last_generation_is_already_done
    database = ExperimentDatabase.new(':memory:')
    (0..2).each { |g| database.save_state(g, 'round' => 1, 'players' => {}, 'ranking' => [], 'games' => []) }
    assert_equal %w[2 3], generations_run(database, { '2' => :already_done })
  end

  def test_a_new_experiment_starts_at_generation_zero
    assert_equal ['0'], generations_run(ExperimentDatabase.new(':memory:'), {})
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
