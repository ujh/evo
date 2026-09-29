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

  # A bot's or the referee's --seed, in 0...2**31: GNU Go takes it as a
  # C int, and michi takes any 32-bit unsigned value.
  def self.gnugo(base, *parts)
    derive(base, *parts) % (2**31)
  end

  # The programs that pick moves at random unless they get --seed N. Brown
  # and AmiGo play deterministically and take no seed.
  SEEDED_BOTS = %w[gnugo michi].freeze

  # Adds the seed to the command of a bot that takes one (by its program,
  # the command's first word) and leaves other programs' alone.
  def self.with_bot_seed(command, seed)
    SEEDED_BOTS.include?(command.split(' ', 2).first) ? "#{command} --seed #{seed}" : command
  end

  def self.new_experiment_seed
    Random.new_seed % (2**63)
  end
end
