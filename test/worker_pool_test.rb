require 'minitest/autorun'
require 'tmpdir'
require_relative '../ruby/worker_pool'

class WorkerPoolTest < Minitest::Test
  def finish_all(pool, count)
    Array.new(count) { pool.next_finished.first }
  end

  def test_runs_every_job_and_reports_each_identifier_once
    Dir.mktmpdir do |dir|
      pool = WorkerPool.new(2)
      5.times { |i| pool.submit("touch #{dir}/#{i}", { 'game' => i }) }
      finished = finish_all(pool, 5)
      pool.stop
      assert_equal (0..4).map { |i| { 'game' => i } }, finished.sort_by { |f| f['game'] }
      assert_equal (0..4).map(&:to_s), Dir.children(dir).sort
    end
  end

  def test_runs_up_to_its_size_in_parallel_and_no_more
    pool = WorkerPool.new(2)
    started = Time.now
    4.times { |i| pool.submit('sleep 0.5', i) }
    finish_all(pool, 4)
    elapsed = Time.now - started
    pool.stop
    # Two at a time: about 1 s. One at a time would take 2 s, four at a time 0.5 s.
    assert_in_delta 1.0, elapsed, 0.4
  end

  def test_a_failing_command_still_reports_its_identifier
    pool = WorkerPool.new(1)
    pool.submit('exit 3', :failed)
    assert_equal :failed, pool.next_finished.first
    pool.stop
  end

  def test_reports_how_long_each_command_ran
    pool = WorkerPool.new(2)
    pool.submit('sleep 0.3', :slow)
    pool.submit('true', :fast)
    seconds = Array.new(2) { pool.next_finished.first(2) }.to_h
    pool.stop
    assert_in_delta 0.3, seconds[:slow], 0.2
    assert_operator seconds[:fast], :<, seconds[:slow]
  end

  def test_reports_each_commands_exit_status
    pool = WorkerPool.new(2)
    pool.submit('exit 3', :failed)
    pool.submit('true > /dev/null', :succeeded)
    statuses = Array.new(2) { pool.next_finished.values_at(0, 2) }.to_h
    pool.stop
    assert_equal 3, statuses[:failed].exitstatus
    assert statuses[:succeeded].success?
  end

  def status_of(command)
    system(command)
    $?
  end

  # Ruby sees a command that SIGINT or SIGTERM ended as killed by it, or,
  # when the program catches the signal and exits (the JVM that runs
  # gogui-twogtp exits 130 on Ctrl-C), as exiting with 128 plus the signal.
  def test_a_command_ended_by_ctrl_c_or_sigterm_was_interrupted
    ['kill -INT $$', 'kill -TERM $$', 'exit 130', 'exit 143'].each do |command|
      assert WorkerPool.interrupted?(status_of(command)), command
    end
  end

  def test_a_command_that_failed_or_crashed_was_not_interrupted
    ['true', 'exit 1', 'exit 139', 'kill -KILL $$'].each do |command|
      refute WorkerPool.interrupted?(status_of(command)), command
    end
    refute WorkerPool.interrupted?(nil)
  end

  def test_stop_waits_for_running_jobs_and_drops_queued_ones
    Dir.mktmpdir do |dir|
      pool = WorkerPool.new(1)
      pool.submit("sleep 0.3; touch #{dir}/first", 1)
      pool.submit("touch #{dir}/second", 2)
      sleep 0.1 # let the first job start
      pool.stop
      assert_equal ['first'], Dir.children(dir)
      assert pool.stopped?
    end
  end

  def test_halt_from_a_signal_trap_keeps_queued_jobs_from_starting
    Dir.mktmpdir do |dir|
      pool = WorkerPool.new(2)
      previous = trap('INT') { pool.halt }
      4.times { |i| pool.submit("sleep 0.3; touch #{dir}/#{i}", i) }
      sleep 0.1 # both threads are running a job
      Process.kill('INT', Process.pid)
      2.times { pool.next_finished }
      pool.stop
      assert_equal %w[0 1], Dir.children(dir).sort
    ensure
      trap('INT', previous || 'DEFAULT')
    end
  end

  def test_size_below_one_is_rejected
    assert_raises(ArgumentError) { WorkerPool.new(0) }
  end
end
