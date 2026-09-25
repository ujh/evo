# Runs shell commands on a fixed number of threads. The commands play games
# (one gogui-twogtp game, or a chunk of games in the arena), so the threads
# spend their time in `system`, which releases the interpreter lock; plain
# threads run them just as much in parallel as Ractors would, without their
# deadlocks.
class WorkerPool
  def initialize(size)
    raise ArgumentError, "a worker pool needs at least 1 thread, got #{size}" if size < 1

    @jobs = Queue.new
    @finished = Queue.new
    @halted = false
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

  # Keeps queued commands from starting; running ones finish. Only sets a
  # flag, so it is safe to call from a signal trap. Without it, a thread whose
  # game was killed by Ctrl-C would start the next queued game, which never
  # got the signal and would play to the end.
  def halt
    @halted = true
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
      system(command)
      # $? belongs to this thread.
      @finished << [identifier, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, $?]
    end
  end
end
