require 'digest'

# Every seed in an experiment comes from one experiment seed in the settings,
# so a run can be repeated. Each seed is derived from that seed and a label
# naming what it is for, such as ("birth", generation, index): different
# labels give unrelated seeds, and the same label always the same one.
module Seeds
  # A seed in 0...2**63, which fits SQLite's INTEGER and evolve's uint64.
  def self.derive(base, *parts)
    Digest::SHA256.digest([base, *parts].join(':')).unpack1('Q>') >> 1
  end

  # GNU Go takes its --seed as a C int.
  def self.gnugo(base, *parts)
    derive(base, *parts) % (2**31)
  end

  # Adds the seed to a GNU Go command and leaves other programs' alone.
  def self.with_gnugo_seed(command, seed)
    command.start_with?('gnugo ') ? "#{command} --seed #{seed}" : command
  end

  def self.new_experiment_seed
    Random.new_seed % (2**63)
  end
end
