require 'minitest/autorun'
require 'tmpdir'
require 'timeout'
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

  # A job's time is awake time (AwakeClock), so a sleeping laptop does not
  # add its sleep to the job.
  def test_times_jobs_with_the_awake_clock
    times = Queue.new
    [10.0, 12.5].each { |t| times << t }
    original = AwakeClock.method(:now)
    AwakeClock.define_singleton_method(:now) { times.pop }
    pool = WorkerPool.new(1)
    pool.submit('true', :job)
    assert_equal 2.5, pool.next_finished[1]
    pool.stop
  ensure
    AwakeClock.singleton_class.send(:remove_method, :now)
    AwakeClock.define_singleton_method(:now, original)
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
      statuses = Timeout.timeout(5) { Array.new(4) { pool.next_finished.last } }
      pool.stop
      assert_equal %w[0 1], Dir.children(dir).sort
      assert_equal 2, statuses.count { |status| status.equal?(WorkerPool::NOT_STARTED) }
    ensure
      trap('INT', previous || 'DEFAULT')
    end
  end

  # Ctrl-C can come just before the runner queues a batch of jobs: a
  # halted pool starts none of them, and still hands each back, as not
  # started, so waiting for them never blocks.
  def test_a_halted_pool_hands_back_the_jobs_it_does_not_start
    Dir.mktmpdir do |dir|
      pool = WorkerPool.new(2)
      pool.halt
      3.times { |i| pool.submit("touch #{dir}/#{i}", i) }
      finished = Timeout.timeout(5) { Array.new(3) { pool.next_finished } }
      pool.stop
      assert_equal [0, 1, 2], finished.map(&:first).sort
      finished.each do |_, seconds, status|
        assert_equal 0, seconds
        assert_same WorkerPool::NOT_STARTED, status
        assert WorkerPool.interrupted?(status)
      end
      assert_empty Dir.children(dir)
    end
  end

  # A pool job's own status, as the runner reads it: what Ruby reports for
  # the shell or the program it ran.
  def pool_status(command)
    pool = WorkerPool.new(1)
    pool.submit(command, :job)
    pool.next_finished.last
  ensure
    pool&.stop
  end

  def test_a_job_ended_by_ctrl_c_or_sigterm_was_interrupted
    ['kill -INT $$', 'kill -TERM $$', 'exit 130', 'exit 143', 'exec sh -c "kill -TERM \\$\\$"'].each do |command|
      assert WorkerPool.interrupted?(pool_status(command)), command
    end
    ['true', 'exit 1', 'exit 139', 'kill -KILL $$', 'kill -SEGV $$'].each do |command|
      refute WorkerPool.interrupted?(pool_status(command)), command
    end
  end

  # As `system` did: the shell reports a program it cannot run.
  def test_a_command_that_cannot_run_exits_127
    saved = $stderr.dup
    $stderr.reopen(File::NULL) # the shell's "not found"
    status = pool_status('no-such-program-anywhere')
    $stderr.reopen(saved)
    assert_equal 127, status.exitstatus
  end

  # Waits until `path` holds a pid, and returns it.
  def pid_in(path)
    Timeout.timeout(5) { sleep 0.01 until File.size?(path) }
    Integer(File.read(path).split.first)
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def test_terminate_sends_sigterm_to_the_running_jobs_and_says_how_many
    Dir.mktmpdir do |dir|
      pool = WorkerPool.new(3)
      2.times { |i| pool.submit("echo $$ > #{dir}/#{i}; exec sleep 30", i) }
      pids = Array.new(2) { |i| pid_in("#{dir}/#{i}") }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_equal 2, pool.terminate
      statuses = Array.new(2) { pool.next_finished.last }
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
      assert_equal [Signal.list['TERM']] * 2, statuses.map(&:termsig)
      refute pids.any? { |pid| alive?(pid) }
      pool.stop
    end
  end

  # The arena is exec'd, so the SIGTERM reaches it and not a shell, and its
  # own cleanup stops its bots. Here a shell that kills its child on SIGTERM
  # stands in for it.
  def test_terminate_reaches_an_execd_program_that_stops_its_children
    Dir.mktmpdir do |dir|
      File.write("#{dir}/arena", "sleep 30 & echo $! > #{dir}/bot; trap 'kill $!; exit 143' TERM; wait\n")
      pool = WorkerPool.new(1)
      pool.submit("exec sh #{dir}/arena > #{dir}/out 2> #{dir}/err", :chunk)
      bot = pid_in("#{dir}/bot")
      assert_equal 1, pool.terminate
      assert_equal 143, pool.next_finished.last.exitstatus
      Timeout.timeout(5) { sleep 0.01 while alive?(bot) }
      pool.stop
    end
  end

  # A pool that records each pid it signals.
  class RecordingPool < WorkerPool
    def signalled = (@signalled ||= [])

    private

    def signal(pid)
      signalled << pid
      super
    end
  end

  def test_terminate_starts_no_queued_job_and_signals_no_finished_one
    Dir.mktmpdir do |dir|
      pool = RecordingPool.new(1)
      pool.submit('true', :done)
      pool.next_finished
      # The finished job's pid is no longer recorded, so it is not signalled.
      assert_equal 0, pool.terminate
      pool.submit("touch #{dir}/queued", :queued)
      sleep 0.2 # the thread takes the job before stop drops it
      pool.stop
      assert_empty pool.signalled
      assert_empty Dir.children(dir)
    end
  end

  # A pool whose threads wait at `hook` (:start, before starting a job, or
  # :reap, after a job was reaped but before its pid is cleared) until the
  # test lets them go on.
  class HeldPool < WorkerPool
    def initialize(size, hook)
      @hook = hook
      @reached = Queue.new
      @go = Queue.new
      super(size)
    end

    attr_reader :reached, :go

    private

    def start(command)
      hold if @hook == :start
      super
    end

    def reap(pid)
      status = super
      hold if @hook == :reap
      status
    end

    def hold
      @reached << true
      @go.pop
    end
  end

  # A job whose thread has passed the halt check but not yet started it
  # when terminate runs: it must not escape.
  def test_a_job_started_just_after_terminate_is_killed_at_once
    pool = HeldPool.new(1, :start)
    pool.submit('exec sleep 30', :late)
    Timeout.timeout(5) { pool.reached.pop }
    assert_equal 0, pool.terminate
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    pool.go << true
    assert_equal Signal.list['TERM'], pool.next_finished.last.termsig
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
    pool.stop
  end

  # Between reaping a job and clearing its pid, the pid is gone: signalling
  # it fails with ESRCH, which terminate ignores.
  def test_terminate_ignores_a_job_reaped_but_not_yet_cleared
    pool = HeldPool.new(1, :reap)
    pool.submit('true', :reaped)
    Timeout.timeout(5) { pool.reached.pop }
    assert_equal 0, pool.terminate
    pool.go << true
    assert pool.next_finished.last.success?
    pool.stop
  end

  # Ctrl-C in a terminal reaches the whole foreground process group: the
  # runner and every job, an exec'd arena and a shell running gogui-twogtp
  # with its child alike. Here a child Ruby in its own group stands in for
  # the runner, and the test sends the group SIGINT.
  def test_ctrl_c_in_the_terminal_reaches_every_job
    Dir.mktmpdir do |dir|
      child = %(ruby -e 'File.write(ARGV[0], Process.pid.to_s); sleep 30')
      runner = <<~RUBY
        require #{File.expand_path('../ruby/worker_pool', __dir__).inspect}
        pool = WorkerPool.new(2)
        trap('INT') { pool.halt }
        pool.submit("exec #{child} #{dir}/arena > /dev/null 2>&1", :arena)
        pool.submit("#{child} #{dir}/twogtp 2> /dev/null; true", :twogtp)
        statuses = Array.new(2) { pool.next_finished.last }
        pool.stop
        File.write(#{"#{dir}/statuses".inspect}, statuses.map { |s| WorkerPool.interrupted?(s) }.inspect)
      RUBY
      pid = Process.spawn(RbConfig.ruby, '-e', runner, pgroup: true)
      jobs = %w[arena twogtp].map { |name| pid_in("#{dir}/#{name}") }
      Process.kill('INT', -pid)
      Timeout.timeout(10) { Process.wait(pid) }
      assert_equal '[true, true]', File.read("#{dir}/statuses")
      refute jobs.any? { |job| alive?(job) }
    end
  end

  # Streaming jobs

  # Every event a streaming job gives, in order, until its exit event.
  def stream_events(pool)
    events = []
    events << Timeout.timeout(10) { pool.next_finished } until events.last.is_a?(WorkerPool::Exited)
    events
  end

  # The runner scores each arena record as it arrives, so the job hands
  # back each line of its stdout (without the newline, the last one also
  # without one) before its exit.
  def test_a_streaming_job_hands_back_each_line_of_its_stdout_then_its_exit
    pool = WorkerPool.new(1)
    pool.submit_streaming("printf 'one\\n\\ntwo\\tfields\\nlast'; exit 3", :chunk)
    events = stream_events(pool)
    pool.stop
    assert_equal ['one', '', "two\tfields", 'last'], events[0..-2].map(&:text)
    assert(events[0..-2].all? { |event| event.is_a?(WorkerPool::Line) && event.identifier == :chunk })
    exited = events.last
    assert_equal :chunk, exited.identifier
    assert_equal 3, exited.status.exitstatus
    assert_operator exited.duration, :>, 0
  end

  def test_a_streaming_job_without_output_hands_back_only_its_exit
    pool = WorkerPool.new(1)
    pool.submit_streaming('true', :quiet)
    events = stream_events(pool)
    pool.stop
    assert_equal [WorkerPool::Exited], events.map(&:class)
    assert events.last.status.success?
  end

  # A line arrives while the job still runs, not only once it exited.
  def test_a_line_arrives_before_the_job_exits
    Dir.mktmpdir do |dir|
      pool = WorkerPool.new(1)
      pool.submit_streaming("echo first; while [ ! -e #{dir}/go ]; do sleep 0.01; done; echo second", :chunk)
      assert_equal 'first', Timeout.timeout(5) { pool.next_finished }.text
      File.write("#{dir}/go", '')
      assert_equal %w[second], stream_events(pool)[0..-2].map(&:text)
      pool.stop
    end
  end

  # UTF-8 whatever the locale (US-ASCII under LANG=C), with bytes that are
  # not UTF-8 replaced, as the runner read the arena's output file.
  def test_lines_are_utf8_with_invalid_bytes_replaced
    verbose, $VERBOSE = $VERBOSE, nil
    external = Encoding.default_external
    Encoding.default_external = Encoding::US_ASCII
    pool = WorkerPool.new(1)
    pool.submit_streaming("printf 'Gr\\303\\266\\303\\237e caf\\351\\n'", :chunk)
    line = stream_events(pool).first.text
    pool.stop
    assert_equal Encoding::UTF_8, line.encoding
    assert_equal 'Größe caf�', line
  ensure
    Encoding.default_external = external
    $VERBOSE = verbose
  end

  # Each job's pipe is its own: a long job started while a short one's
  # pipe is open must not hold that pipe's write end, or the short job's
  # EOF, and so its exit, would wait for the long job.
  def test_parallel_streaming_jobs_each_see_the_end_of_their_own_output
    Dir.mktmpdir do |dir|
      pool = WorkerPool.new(2)
      pool.submit_streaming("echo short; while [ ! -e #{dir}/go ]; do sleep 0.01; done", :short)
      assert_equal 'short', Timeout.timeout(5) { pool.next_finished }.text
      pool.submit_streaming("echo long; touch #{dir}/go; exec sleep 5", :long)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      events = []
      events << Timeout.timeout(10) { pool.next_finished } until events.any? { |e| e.is_a?(WorkerPool::Exited) }
      assert_equal :short, events.last.identifier
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2.5
      pool.terminate
      pool.stop
    end
  end

  # Ctrl-C can come just before the runner queues its chunks: they come
  # back as exit events without lines, not started, so waiting never blocks.
  def test_a_halted_pool_hands_back_streaming_jobs_as_not_started
    Dir.mktmpdir do |dir|
      pool = WorkerPool.new(2)
      pool.halt
      3.times { |i| pool.submit_streaming("echo line; touch #{dir}/#{i}", i) }
      events = Timeout.timeout(5) { Array.new(3) { pool.next_finished } }
      pool.stop
      assert_equal [0, 1, 2], events.map(&:identifier).sort
      events.each do |event|
        assert_kind_of WorkerPool::Exited, event
        assert_equal 0, event.duration
        assert_same WorkerPool::NOT_STARTED, event.status
      end
      assert_empty Dir.children(dir)
    end
  end

  def test_terminate_reaches_a_streaming_job
    Dir.mktmpdir do |dir|
      pool = WorkerPool.new(1)
      pool.submit_streaming("echo $$ > #{dir}/pid; echo started; exec sleep 30", :chunk)
      assert_equal 'started', Timeout.timeout(5) { pool.next_finished }.text
      assert_equal 1, pool.terminate
      assert_equal Signal.list['TERM'], stream_events(pool).last.status.termsig
      refute alive?(pid_in("#{dir}/pid"))
      pool.stop
    end
  end

  # Plain jobs, the benchmark's and breeding's, keep their tuple.
  def test_plain_and_streaming_jobs_share_the_pool
    pool = WorkerPool.new(1)
    pool.submit('echo not captured > /dev/null', :plain)
    pool.submit_streaming('echo captured', :streaming)
    identifier, seconds, status = Timeout.timeout(5) { pool.next_finished }
    assert_equal [:plain, true], [identifier, status.success?]
    assert_kind_of Float, seconds
    assert_equal %w[captured], stream_events(pool)[0..-2].map(&:text)
    pool.stop
  end

  def test_size_below_one_is_rejected
    assert_raises(ArgumentError) { WorkerPool.new(0) }
  end
end
