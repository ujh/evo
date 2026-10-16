# Elitism: the top networks of a generation's final ranking enter the next
# generation unchanged. Its own file, so the runner (run_generation.rb) and
# the settings (setup_experiment.rb) load the same rule without loading
# each other.
module Elitism
  # E, the networks carried over: the share of the population rounded to
  # the nearest whole number (a half up), and at least 1 for any share
  # above 0. Rounded, not ceiled or floored: 0.07 x 100 is
  # 7.000000000000001 in floating point and 0.29 x 100 is
  # 28.999999999999996.
  def self.count(share, population_size)
    return 0 if share.zero?

    [(share * population_size).round, 1].max
  end
end
