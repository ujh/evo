# The feature groups a network can see besides the stones and komi, and
# each group's move features, in the fixed order of lib/ann.c's
# ANN_GROUP_NAMES and ANN_FEATURES. liberties adds inputs but no move feature.
module FeatureGroups
  GROUPS = {
    'shapes' => %w[hane cut edge],
    'tactics' => %w[capture self_atari saves_atari],
    'last_move' => %w[near_last],
    'liberties' => []
  }.freeze

  # The move features of a feature set written as the genes line writes it,
  # `none` or its groups comma-separated in GROUPS' order, or nil for any
  # other text (`all` included).
  def self.move_features(feature_set)
    return [] if feature_set == 'none'

    groups = feature_set.split(',', -1)
    return nil if groups.empty? || GROUPS.keys & groups != groups

    groups.flat_map { |group| GROUPS.fetch(group) }
  end
end
