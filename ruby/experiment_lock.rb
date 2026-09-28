# The lock that says a process is using an experiment: the runner holds it
# for its whole life, and the archive while it rebuilds the database, so
# neither starts while the other runs, and two runners never share one
# experiment. SQLite's own locks cannot tell: the runner holds none between
# transactions.
#
# It is an flock on experiments/NAME/experiment.lock. Only the lock counts,
# never whether the file exists: the file stays after its holder ends, and
# the kernel releases the lock as soon as the holder exits, even after a
# kill -9. Ruby opens files close-on-exec, so programs the holder starts do
# not inherit it.
module ExperimentLock
  FILE = 'experiment.lock'.freeze

  # The open, locked file, which holds the lock until it is closed; nil
  # when another process holds it.
  def self.acquire(experiment_dir)
    file = File.open(File.join(experiment_dir, FILE), File::RDWR | File::CREAT, 0o644)
    return file if file.flock(File::LOCK_EX | File::LOCK_NB)

    file.close
    nil
  end
end
