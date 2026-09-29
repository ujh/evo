require_relative 'awake_clock'

# Runs shell commands on a fixed number of threads. The commands play games
# (one gogui-twogtp game, or a chunk of games in the arena), so the threads
# spend their time waiting for their command's process (`Process.wait2`),
# which releases the interpreter lock; plain threads run them just as much
# in parallel as Ractors would, without their deadlocks. Each command runs
# in `sh -c`, in the runner's process group, so a Ctrl-C in the terminal
# reaches every job.
#
# A plain job (submit) comes back from next_finished once, as
# [identifier, seconds, status]. A streaming job (submit_streaming) has its
# stdout on a pipe its thread reads: each line comes back as a Line as soon
# as it is read, then the job's end as an Exited. The arena's chunks stream,
# so the runner scores each game as its record arrives.
class WorkerPool
  # A line of a streaming job's stdout: UTF-8 whatever the locale (bytes
  # that are not UTF-8 are replaced by U+FFFD), without its newline.
  Line = Struct.new(:identifier, :text)

  # A streaming job's end, after its last Line: the seconds it ran and its
  # Process::Status, as next_finished gives them for a plain job.
  Exited = Struct.new(:identifier, :duration, :status)

  def initialize(size)
    raise ArgumentError, "a worker pool needs at least 1 thread, got #{size}" if size < 1

    @jobs = Queue.new
    @finished = Queue.new
    @halted = false
    # The pid of each thread's running command, and whether terminate has
    # been called; both only under @lock.
    @lock = Mutex.new
    @pids = {}
    @terminating = false
    @threads = Array.new(size) { Thread.new { work } }
  end

  # Queues a command. `identifier` comes back from next_finished once the
  # command has exited, whatever its exit status, or, once the pool is
  # halted, as not started.
  def submit(command, identifier)
    @jobs << [command, identifier, false]
  end

  # Queues a command whose stdout comes back line by line (Line), then its
  # end (Exited, also for a job a halted pool did not start, with no line).
  def submit_streaming(command, identifier)
    @jobs << [command, identifier, true]
  end

  # Blocks until a command finishes and returns its identifier, the
  # seconds it ran (on AwakeClock, so not counting system sleep), and its
  # Process::Status; for a command a halted pool did not start, 0 and
  # NOT_STARTED. For a streaming job, returns its next Line or its Exited.
  def next_finished
    @finished.pop
  end

  # The status of a job a halted pool never started. Every queued job comes
  # back from next_finished, so a caller that waits for each job it queued
  # never blocks, also when Ctrl-C halted the pool just before it queued
  # them. interrupted? counts it as interrupted.
  NOT_STARTED = Object.new.tap do |status|
    def status.inspect = 'WorkerPool::NOT_STARTED'
  end.freeze

  # Signals that stop a run: Ctrl-C (SIGINT) and SIGTERM.
  STOPPING = [Signal.list['INT'], Signal.list['TERM']].freeze

  # Whether `status` says the command was ended by Ctrl-C or SIGTERM. Ctrl-C
  # reaches the games as well as the runner, and a killed game can come back
  # before the runner's trap has run, so the status is what tells that its
  # result is not one. A program killed by the signal shows as signaled; one
  # that catches it and exits, like the JVM running gogui-twogtp, exits with
  # 128 plus the signal, as the shell reports a child killed by a signal.
  def self.interrupted?(status)
    return false unless status
    return true if status.equal?(NOT_STARTED)

    STOPPING.include?(status.termsig) || STOPPING.map { |signal| 128 + signal }.include?(status.exitstatus)
  end

  # Stops the run for a job that `interrupted?` calls interrupted while no
  # Ctrl-C was seen (the trap may not have run yet, or someone killed one
  # game), saying so, with the status a shell gives a command Ctrl-C ended.
  def self.exit_interrupted(job, pending)
    warn "\n#{job} was interrupted; #{pending}. Stopping."
    exit 130
  end

  # Keeps queued commands from starting, now and later; running ones
  # finish, and the others come back from next_finished as NOT_STARTED.
  # Only sets a flag, so it is safe to call from a signal trap. Without it,
  # a thread whose game was killed by Ctrl-C would start the next queued
  # game, which never got the signal and would play to the end.
  def halt
    @halted = true
  end

  # Keeps queued commands from starting, as halt does, and sends SIGTERM to
  # the running ones; returns how many it signalled. Only for commands that
  # `exec` their program, so the signal reaches it and not a shell that
  # would leave it running. A thread that starts its command after this
  # kills it at once, and a command already reaped is never signalled (its
  # pid could be another process's by now). Not from a signal trap: it
  # takes a lock.
  def terminate
    halt
    @lock.synchronize do
      @terminating = true
      @pids.values.count { |pid| signal(pid) }
    end
  end

  # Drops queued commands and waits for the running ones to exit.
  def stop
    @jobs.clear
    @jobs.close
    @threads.each(&:join)
  end

  def stopped?
    @threads.none?(&:alive?)
  end

  private

  def work
    while (job = @jobs.pop)
      command, identifier, streaming = job
      if @halted
        @finished << finished(identifier, 0, NOT_STARTED, streaming)
        next
      end

      started = AwakeClock.now
      status = streaming ? run_streaming(command, identifier) : run(command)
      @finished << finished(identifier, AwakeClock.now - started, status, streaming)
    end
  end

  def finished(identifier, seconds, status, streaming)
    streaming ? Exited.new(identifier, seconds, status) : [identifier, seconds, status]
  end

  def run(command)
    watch(start(command))
  end

  # Runs the command with its stdout on a pipe and hands back each line.
  # The parent closes its write end at once, and Ruby opens every pipe
  # close-on-exec, so no other job holds it: EOF comes when the command
  # and whatever it started with that stdout are done.
  def run_streaming(command, identifier)
    reader, writer = IO.pipe
    reader.binmode
    begin
      pid = start(command, out: writer)
    ensure
      writer.close
    end
    watch(pid) do
      reader.each_line do |line|
        text = line.delete_suffix("\n").force_encoding(Encoding::UTF_8).scrub
        @finished << Line.new(identifier, text)
      end
    end
  ensure
    reader&.close
  end

  # Records the running command's pid for terminate, runs the block while
  # it runs, and returns its Process::Status once it exited.
  def watch(pid)
    @lock.synchronize do
      @pids[Thread.current] = pid
      signal(pid) if @terminating
    end
    yield if block_given?
    reap(pid)
  ensure
    @lock.synchronize { @pids.delete(Thread.current) }
  end

  # Starts the command as `system` would a command with shell syntax, also
  # when it has none, so a program that cannot run exits 127 instead of
  # raising in the thread.
  def start(command, **redirects)
    Process.spawn('/bin/sh', '-c', command, **redirects)
  end

  # Waits for the command to exit and returns its Process::Status.
  def reap(pid)
    Process.wait2(pid).last
  end

  # Sends SIGTERM; false when the process is gone, in the moment between a
  # thread reaping its command and clearing its pid.
  def signal(pid)
    Process.kill('TERM', pid)
    true
  rescue Errno::ESRCH
    false
  end
end
