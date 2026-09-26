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

  # The inputs each group adds, as lib/ann.c's ann_layout_inputs lays them
  # out: planes of one input per point, and single inputs. Each move feature
  # is a plane; liberties has 3 planes, and last_move adds the last_move
  # plane and opponent_passed.
  PLANES = { 'shapes' => 3, 'tactics' => 3, 'last_move' => 2, 'liberties' => 3 }.freeze
  SINGLES = { 'shapes' => 0, 'tactics' => 0, 'last_move' => 1, 'liberties' => 0 }.freeze

  ALL = GROUPS.keys.join(',').freeze

  # The move features of a feature set written as the genes line writes it,
  # `none` or its groups comma-separated in GROUPS' order, or nil for any
  # other text (`all` included).
  def self.move_features(feature_set)
    groups = groups(feature_set) or return nil
    groups.flat_map { |group| GROUPS.fetch(group) }
  end

  # The groups of a feature set written as the genes line writes it, or nil.
  def self.groups(feature_set)
    return [] if feature_set == 'none'

    groups = feature_set.split(',', -1)
    return nil if groups.empty? || GROUPS.keys & groups != groups

    groups
  end

  # A feature set as the setting takes it (`none`, `all`, or groups
  # comma-separated in any order, each once) written as the genes line
  # writes it; nil for anything else.
  def self.normalize(text)
    return 'none' if text == 'none'
    return ALL if text == 'all'

    groups = text.split(',', -1)
    return nil if groups.empty? || groups.uniq != groups || !(groups - GROUPS.keys).empty?

    (GROUPS.keys & groups).join(',')
  end

  # The inputs of a network for a board of `board_size` with a feature set
  # as the genes line writes it: komi, the stones, then the groups' inputs.
  def self.inputs(board_size, feature_set)
    points = board_size**2
    groups = groups(feature_set) or raise ArgumentError, "unknown feature set #{feature_set.inspect}"
    1 + points + groups.sum { |group| (PLANES.fetch(group) * points) + SINGLES.fetch(group) }
  end

  # The weights of such a network with the given hidden layers, as GENANN
  # counts them: each neuron has a bias and one weight per neuron of the
  # layer before. The outputs are the points and pass.
  def self.total_weights(board_size, layers, width, feature_set)
    inputs = inputs(board_size, feature_set)
    outputs = (board_size**2) + 1
    return outputs * (inputs + 1) if layers.zero?

    (width * (inputs + 1)) + ((layers - 1) * width * (width + 1)) + (outputs * (width + 1))
  end
end
