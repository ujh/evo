# Runs shell commands on a fixed number of threads. The commands play games
# (one gogui-twogtp game, or a chunk of games in the arena), so the threads
# spend their time waiting for their command's process (`Process.wait2`),
# which releases the interpreter lock; plain threads run them just as much
# in parallel as Ractors would, without their deadlocks. Each command runs
# in `sh -c`, in the runner's process group, so a Ctrl-C in the terminal
# reaches every job.
class WorkerPool
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
  # command has exited, whatever its exit status.
  def submit(command, identifier)
    @jobs << [command, identifier]
  end

  # Blocks until a command finishes and returns its identifier, the
  # wall-clock seconds it ran, and its Process::Status.
  def next_finished
    @finished.pop
  end

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

    STOPPING.include?(status.termsig) || STOPPING.map { |signal| 128 + signal }.include?(status.exitstatus)
  end

  # Stops the run for a job that `interrupted?` calls interrupted while no
  # Ctrl-C was seen (the trap may not have run yet, or someone killed one
  # game), saying so, with the status a shell gives a command Ctrl-C ended.
  def self.exit_interrupted(job, pending)
    warn "\n#{job} was interrupted; #{pending}. Stopping."
    exit 130
  end

  # Keeps queued commands from starting; running ones finish. Only sets a
  # flag, so it is safe to call from a signal trap. Without it, a thread whose
  # game was killed by Ctrl-C would start the next queued game, which never
  # got the signal and would play to the end.
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
      break if @halted

      command, identifier = job
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      pid = start(command)
      @lock.synchronize do
        @pids[Thread.current] = pid
        signal(pid) if @terminating
      end
      status = reap(pid)
      @lock.synchronize { @pids.delete(Thread.current) }
      @finished << [identifier, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, status]
    end
  end

  # Starts the command as `system` would a command with shell syntax, also
  # when it has none, so a program that cannot run exits 127 instead of
  # raising in the thread.
  def start(command)
    Process.spawn('/bin/sh', '-c', command)
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
