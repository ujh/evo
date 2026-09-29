require_relative 'test_helper'
require_relative '../ruby/generation_timings'

class GenerationTimingsTest < Minitest::Test
  def timings(partial: false)
    @clock = FakeClock.new
    GenerationTimings.new(3, partial:, clock: @clock)
  end

  # Plays a round of `games` (each [seconds a worker ran, failure]) whose
  # jobs the runner waits `waited` seconds for, doing `ruby` seconds of its
  # own work besides.
  def play_round(timings, number, games, waited:, ruby:)
    timings.round(number) do
      @clock.advance(ruby)
      timings.wait { @clock.advance(waited) }
      games.each do |seconds, failure|
        timings.job(seconds)
        timings.game(failure)
      end
    end
  end

  def full_generation(partial: false)
    t = timings(partial:)
    t.time(:total) do
      t.time(:setup) { @clock.advance(1.5) }
      play_round(t, 1, [[2.0, nil], [3.5, 'arena: no result']], waited: 4.0, ruby: 0.5)
      play_round(t, 2, [[1.0, nil]], waited: 1.0, ruby: 0.25)
      t.time(:benchmark) { @clock.advance(10.0) }
    end
    t
  end

  def test_the_machine_line_has_every_part_that_ran_in_seconds
    assert_equal 'timings generation=3 partial=0 setup=1.500 ' \
                 'round_1=4.500 worker_round_1=5.500 ruby_round_1=0.500 games_round_1=2 failures_round_1=1 ' \
                 'round_2=1.250 worker_round_2=1.000 ruby_round_2=0.250 games_round_2=1 failures_round_2=0 ' \
                 'tournament=5.750 worker=6.500 ruby=0.750 games=3 failures=1 benchmark=10.000 total=17.250',
                 full_generation.line
  end

  def test_the_summary_names_the_parts_and_the_failed_rounds
    assert_equal ['Generation 3 took 17.25 s: setup 1.50 s, tournament 5.75 s, benchmark 10.00 s.',
                  'Tournament: 2 rounds, 3 games, 1 failed (round 1: 1); ' \
                  'workers 6.50 s, Ruby 0.75 s outside waiting for them.'],
                 full_generation.summary
  end

  # A breeding generation's setup: emptying work/, deleting stale network
  # directories, breeding (with 0.25 s of hashing and 0.5 s of storing
  # inside it, over two children), syncing and renaming the networks,
  # saving the state, and deleting the parents.
  def breeding_generation
    t = timings
    t.time(:total) do
      t.time(:setup) do
        t.time(:setup_clear) { @clock.advance(0.25) }
        t.time(:setup_retire) { @clock.advance(0.125) }
        t.time(:setup_breed) do
          2.times do
            @clock.advance(2.0)
            t.time(:setup_hash) { @clock.advance(0.125) }
            t.time(:setup_store) { @clock.advance(0.25) }
          end
        end
        t.time(:setup_sync) { @clock.advance(1.0) }
        t.time(:setup_save) { @clock.advance(0.75) }
        t.time(:setup_retire) { @clock.advance(0.375) }
      end
    end
    t
  end

  def test_the_parts_of_setup_follow_setup_on_the_line_and_repeated_parts_add_up
    assert_equal 'timings generation=3 partial=0 setup=7.250 setup_clear=0.250 setup_breed=4.750 setup_hash=0.250 ' \
                 'setup_store=0.500 setup_sync=1.000 setup_save=0.750 setup_retire=0.500 total=7.250',
                 breeding_generation.line
  end

  def test_the_summary_names_the_parts_of_setup_that_ran
    assert_equal ['Generation 3 took 7.25 s: setup 7.25 s, no tournament round, no benchmark.',
                  'Setup: emptying work/ 0.25 s, breeding 4.75 s (hashing 0.25 s and storing 0.50 s during it), ' \
                  'syncing 1.00 s, saving 0.75 s, deleting old networks 0.50 s.'],
                 breeding_generation.summary
  end

  def test_a_resumed_setup_names_only_what_it_did
    t = timings(partial: true)
    t.time(:total) do
      t.time(:setup) do
        t.time(:setup_clear) { @clock.advance(0.25) }
        t.time(:setup_retire) { @clock.advance(0.25) }
        t.time(:setup_verify) { @clock.advance(0.5) }
      end
    end
    assert_equal 'timings generation=3 partial=1 setup=1.000 setup_clear=0.250 setup_retire=0.250 setup_verify=0.500 ' \
                 'total=1.000', t.line
    assert_equal 'Setup: emptying work/ 0.25 s, deleting old networks 0.25 s, verifying 0.50 s.', t.summary[1]
  end

  # Storing a checkpoint's champion is part of its last round, after the
  # tournament's fields on the line.
  def test_storing_the_champion_is_timed_within_the_last_round
    t = timings
    t.time(:total) do
      t.round(1) do
        t.wait { @clock.advance(1.0) }
        t.time(:champion) { @clock.advance(0.25) }
      end
      t.time(:benchmark) { @clock.advance(2.0) }
    end
    assert_equal 'timings generation=3 partial=0 round_1=1.250 worker_round_1=0.000 ruby_round_1=0.250 games_round_1=0 ' \
                 'failures_round_1=0 tournament=1.250 worker=0.000 ruby=0.250 games=0 failures=0 champion=0.250 ' \
                 'benchmark=2.000 total=3.250', t.line
    assert_equal 'Tournament: 1 round, 0 games, none failed; workers 0.00 s, Ruby 0.25 s outside waiting for them; ' \
                 'storing the champion 0.25 s of it.', t.summary[1]
  end

  def test_a_resumed_generation_is_marked_partial
    t = full_generation(partial: true)
    assert_includes t.line, ' partial=1 '
    assert_equal 'Resumed: the times cover only what this session ran.', t.summary.last
  end

  def test_parts_that_did_not_run_are_left_out
    t = timings(partial: true)
    t.time(:total) { t.time(:setup) { @clock.advance(0.5) } }
    assert_equal 'timings generation=3 partial=1 setup=0.500 total=0.500', t.line
    assert_equal ['Generation 3 took 0.50 s: setup 0.50 s, no tournament round, no benchmark.',
                  'Resumed: the times cover only what this session ran.'], t.summary
  end

  def test_a_round_without_failures_says_none_failed
    t = timings
    t.time(:total) { play_round(t, 1, [[1.0, nil]], waited: 1.0, ruby: 0.0) }
    assert_equal 'Tournament: 1 round, 1 game, none failed; workers 1.00 s, Ruby 0.00 s outside waiting for them.',
                 t.summary.last
  end

  def test_report_prints_the_summary_then_the_line
    t = full_generation
    out, = capture_io { t.report }
    assert_equal [*t.summary, t.line].join("\n") + "\n", out
  end

  def test_time_returns_the_blocks_value
    t = timings
    assert_equal :done, t.time(:setup) { :done }
    assert_equal :value, t.wait { :value }
  end

  def test_the_default_clock_is_the_awake_clock
    t = GenerationTimings.new(0, partial: false)
    t.time(:total) { sleep 0.01 }
    assert_operator Float(t.line[/ total=(\S+)$/, 1]), :>=, 0.01
    times = [3.0, 7.25]
    original = AwakeClock.method(:now)
    AwakeClock.define_singleton_method(:now) { times.shift }
    t = GenerationTimings.new(0, partial: false)
    t.time(:total) {}
    assert_includes t.line, ' total=4.250'
  ensure
    if original
      AwakeClock.singleton_class.send(:remove_method, :now)
      AwakeClock.define_singleton_method(:now, original)
    end
  end
end
