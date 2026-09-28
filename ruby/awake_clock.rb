# The clock the runner times games and generations by: one that stops while
# the machine sleeps, as the arena's does (engine/arena.c). On macOS that is
# CLOCK_UPTIME_RAW, since its CLOCK_MONOTONIC keeps counting during sleep;
# elsewhere CLOCK_MONOTONIC, which on Linux already leaves out suspend. So a
# laptop closed during a round adds nothing to a chunk's time, and so
# nothing to the overhead shared over its stored games.
module AwakeClock
  # The clock id of `process` (Process, or a stand-in in the tests).
  def self.id(process = Process)
    process.const_defined?(:CLOCK_UPTIME_RAW) ? process::CLOCK_UPTIME_RAW : process::CLOCK_MONOTONIC
  end

  ID = id

  # Seconds on that clock.
  def self.now
    Process.clock_gettime(ID)
  end
end
