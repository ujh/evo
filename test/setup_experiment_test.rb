require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'stringio'
require 'timeout'
require 'tmpdir'
require_relative '../ruby/setup_experiment'
require_relative '../ruby/run_generation'
require_relative 'hot_journal'

class SetupExperimentTest < Minitest::Test
  include HotJournal

  REQUIRED = %w[--board-size 9 --population-size 4 --hidden-layers 1 --layer-size 10 --cross-over-rate 0.5
                --game-seconds 600 --max-moves 200 --tournament-rounds 1].freeze

  # An answer to every prompt: board size 9, benchmark games 2, 1 for the
  # other required settings, and the default for the rest.
  def prompt_answers(overrides = {})
    answers = { 'board_size' => '9', 'benchmark_games' => '2' }.merge(overrides)
    SetupExperiment::SETTINGS.map { |key, (_, default)| answers.fetch(key) { default.nil? ? '1' : '' } }
  end

  # 9x9 with 1 hidden layer of 10 and every feature group (the default):
  # 974 inputs, so 10 x 975 + 82 x 11.
  REQUIRED_WEIGHTS = 10_652
  ALL_GROUPS = 'shapes,tactics,last_move,liberties'.freeze

  def in_tmpdir(&)
    Dir.mktmpdir { |dir| Dir.chdir(dir, &) }
  end

  def test_arguments_give_settings_with_defaults_for_the_rest
    settings = SetupExperiment.settings_from_arguments(REQUIRED)
    assert_equal 9, settings['board_size']
    assert_equal 3, settings['tournament_size']
    assert_equal 10, settings['keep_every']
    assert_equal 20, settings['benchmark_games']
    assert_equal 4, settings['benchmark_opening_moves']
    assert_equal 6.5, settings['komi']
    assert_kind_of Float, settings['komi']
    assert_kind_of Integer, settings['seed']
    assert_equal SetupExperiment::SETTINGS.keys.sort, settings.keys.sort
  end

  def test_an_argument_overrides_a_default
    assert_equal 5, SetupExperiment.settings_from_arguments(REQUIRED + %w[--tournament-size 5])['tournament_size']
  end

  def test_values_are_parsed_into_numbers
    settings = SetupExperiment.settings_from_arguments(REQUIRED)
    assert_equal 0.5, settings['cross_over_rate']
    assert_equal 200, settings['max_moves']
  end

  # Each of these used to be taken silently: .to_i or C's atoi and atof
  # read a prefix or 0, so a typo changed the experiment without a word.
  BAD_VALUES = [
    %w[--board-size 9x9], %w[--board-size 1], %w[--board-size 20],
    %w[--population-size abc], %w[--population-size 0],
    %w[--hidden-layers -1], %w[--layer-size 0],
    %w[--cross-over-rate 0,5], %w[--cross-over-rate 1.5], %w[--cross-over-rate -0.1],
    %w[--game-seconds 0], %w[--game-seconds 1000001], %w[--game-seconds 0.5], %w[--game-seconds 20s], %w[--max-moves 2.5], %w[--tournament-rounds ten], %w[--tournament-rounds 0],
    %w[--tournament-size 0], %w[--keep-every -1], %w[--seed -3], %w[--seed 9223372036854775808],
    %w[--benchmark-games 21], %w[--benchmark-games 0], %w[--benchmark-games -2], %w[--benchmark-games many],
    %w[--benchmark-games 4.0], %w[--benchmark-bot-games 3], %w[--benchmark-bot-games -2],
    %w[--benchmark-bot-games some], %w[--benchmark-opening-moves -1], %w[--benchmark-opening-moves four],
    %w[--komi 7.25], %w[--komi 51], %w[--komi -50.5], %w[--komi abc], %w[--komi 6,5],
    %w[--meta-rate -0.1], %w[--meta-rate 10.5], %w[--meta-rate fast],
    %w[--initial-copy-chance 0.00009], %w[--initial-copy-chance 0.11],
    %w[--initial-weight-changes 0.5], %w[--initial-weight-changes 2e9], %w[--initial-weight-changes some],
    %w[--initial-weight-step 0.00009], %w[--initial-weight-step 10.5],
    %w[--initial-activation-rate 0.00009], %w[--initial-activation-rate 0.6],
    %w[--initial-structure-rate 0], %w[--initial-structure-rate 0.51],
    %w[--max-hidden-layers -1], %w[--max-hidden-layers many], %w[--max-layer-size 0], %w[--max-layer-size 2.5],
    %w[--initial-feature-noise -0.1], %w[--initial-feature-noise 1.1], %w[--initial-feature-noise some],
    %w[--initial-feature-step 0.00009], %w[--initial-feature-step 1.1], %w[--initial-feature-step tiny],
    %w[--features nothing], %w[--features shapes,], %w[--features ,shapes], %w[--features shapes,,tactics],
    %w[--features shapes,shapes], %w[--features none,shapes], %w[--features all,shapes], %w[--features Shapes],
    %w[--features ALL], %w[--features ladders], %w[--features shapes\ tactics]
  ].freeze

  def test_a_bad_value_is_refused_with_its_option_and_value
    BAD_VALUES.each do |option, value|
      error = assert_raises(ArgumentError, "#{option} #{value}") do
        SetupExperiment.settings_from_arguments(REQUIRED + [option, value])
      end
      assert_includes error.message, option.delete_prefix('--').tr('-', '_')
      assert_includes error.message, value
    end
  end

  # The feature set is stored as the genes line writes it: `none`, or the
  # groups in their fixed order, so `all` is spelled out.
  def test_the_features_default_to_every_group
    assert_equal ALL_GROUPS, SetupExperiment.settings_from_arguments(REQUIRED)['features']
  end

  def test_a_feature_set_is_normalized
    {
      'all' => ALL_GROUPS, 'none' => 'none', 'liberties' => 'liberties', 'tactics,shapes' => 'shapes,tactics',
      'liberties,last_move,tactics,shapes' => ALL_GROUPS, ALL_GROUPS => ALL_GROUPS
    }.each do |text, expected|
      assert_equal expected, SetupExperiment.settings_from_arguments(REQUIRED + ['--features', text])['features'], text
    end
  end

  def test_an_empty_feature_set_is_refused
    error = assert_raises(ArgumentError) { SetupExperiment.settings_from_arguments(REQUIRED + ['--features', '']) }
    assert_includes error.message, 'features'
  end

  # save_settings stores value.to_s, and loading parses it again.
  def test_a_feature_set_round_trips_through_the_database
    in_tmpdir do
      SetupExperiment.create('experiments/x', REQUIRED + %w[--features last_move,shapes])
      database = ExperimentDatabase.new('experiments/x/experiment.sqlite3', readonly: true)
      assert_equal 'shapes,last_move', database.settings['features']
      assert_equal 'shapes,last_move', SetupExperiment.parse(database.settings)['features']
    end
  end

  def test_the_feature_gene_settings_have_defaults
    settings = SetupExperiment.settings_from_arguments(REQUIRED)
    assert_equal [0.3, 0.01], settings.values_at('initial_feature_noise', 'initial_feature_step')
  end

  def test_the_edges_of_the_feature_gene_ranges_are_accepted
    low = SetupExperiment.settings_from_arguments(REQUIRED + %w[--initial-feature-noise 0 --initial-feature-step 0.0001])
    assert_equal [0.0, 0.0001], low.values_at('initial_feature_noise', 'initial_feature_step')
    high = SetupExperiment.settings_from_arguments(REQUIRED + %w[--initial-feature-noise 1 --initial-feature-step 1])
    assert_equal [1.0, 1.0], high.values_at('initial_feature_noise', 'initial_feature_step')
  end

  # The feature set comes before initial_weight_changes, whose default and
  # check count the feature inputs.
  def test_the_feature_set_comes_before_the_weight_changes
    keys = SetupExperiment::SETTINGS.keys
    assert_operator keys.index('features'), :<, keys.index('initial_weight_changes')
  end

  # An experiment created before the feature settings does not load.
  def test_loading_an_experiment_without_the_feature_settings_fails
    %w[features initial_feature_noise initial_feature_step].each do |key|
      in_tmpdir do
        database = ExperimentDatabase.new('experiment.sqlite3')
        database.save_settings(SetupExperiment.settings_from_arguments(REQUIRED).except(key))
        error = assert_raises(ArgumentError, key) { SetupExperiment.settings(database) }
        assert_equal "#{key} is missing", error.message
      end
    end
  end

  # The time setting is in seconds and has no default; an experiment still
  # holding the minutes of game_length (before migration 014) does not load.
  def test_the_game_seconds_are_required
    error = assert_raises(ArgumentError) do
      SetupExperiment.settings_from_arguments(REQUIRED - %w[--game-seconds 600])
    end
    assert_equal 'missing options: --game-seconds', error.message
    in_tmpdir do
      database = ExperimentDatabase.new('experiment.sqlite3')
      settings = SetupExperiment.settings_from_arguments(REQUIRED)
      database.save_settings(settings.except('game_seconds').merge('game_length' => 10))
      error = assert_raises(ArgumentError) { SetupExperiment.settings(database) }
      assert_equal 'game_seconds is missing', error.message
    end
  end

  def test_the_game_seconds_range_from_1_to_the_arenas_limit
    [1, 20, 1_000_000].each do |seconds|
      settings = SetupExperiment.settings_from_arguments(REQUIRED + %W[--game-seconds #{seconds}])
      assert_equal seconds, settings['game_seconds']
    end
  end

  def test_a_prompt_asks_again_for_a_bad_feature_set
    answers = prompt_answers('features' => "ladders\ntactics,shapes")
    $stdin = StringIO.new("#{answers.join("\n")}\n")
    settings = nil
    out, = capture_io { settings = SetupExperiment.prompt_for_settings }
    assert_equal 'shapes,tactics', settings['features']
    assert_includes out, 'features must be'
    assert_includes out, 'Feature groups'
  ensure
    $stdin = STDIN
  end

  def test_the_edges_of_each_range_are_accepted
    settings = SetupExperiment.settings_from_arguments(
      REQUIRED + %w[--board-size 19 --hidden-layers 0 --cross-over-rate 1 --keep-every 0 --seed 0
                    --benchmark-games 2 --benchmark-opening-moves 0]
    )
    assert_equal [19, 0, 1.0, 0, 0, 2, 0],
                 settings.values_at('board_size', 'hidden_layers', 'cross_over_rate', 'keep_every', 'seed',
                                    'benchmark_games', 'benchmark_opening_moves')
  end

  # The genes of generation 0 and the meta rate, as the C programs clamp them.
  def test_the_gene_settings_have_defaults
    settings = SetupExperiment.settings_from_arguments(REQUIRED)
    assert_equal [0.2, 0.01, 0.5, 0.02, 0.02],
                 settings.values_at('meta_rate', 'initial_copy_chance', 'initial_weight_step',
                                    'initial_activation_rate', 'initial_structure_rate')
  end

  def test_the_edges_of_the_gene_ranges_are_accepted
    low = SetupExperiment.settings_from_arguments(
      REQUIRED + %w[--meta-rate 0 --initial-copy-chance 0.0001 --initial-weight-changes 1 --initial-weight-step 0.0001
                    --initial-activation-rate 0.0001 --initial-structure-rate 0.0001]
    )
    assert_equal [0.0, 0.0001, 1.0, 0.0001, 0.0001, 0.0001],
                 low.values_at('meta_rate', *RunGeneration::INITIAL_GENES)
    high = SetupExperiment.settings_from_arguments(
      REQUIRED + %W[--meta-rate 10 --initial-copy-chance 0.1 --initial-weight-changes #{REQUIRED_WEIGHTS}
                    --initial-weight-step 10 --initial-activation-rate 0.5 --initial-structure-rate 0.5]
    )
    assert_equal [10.0, 0.1, 10_652.0, 10.0, 0.5, 0.5], high.values_at('meta_rate', *RunGeneration::INITIAL_GENES)
  end

  # Without the option, weight_changes is the old hard-coded load: 0.0004
  # changes per weight of the generation-0 shape, at least 1.
  def test_the_initial_weight_changes_follow_the_generation_0_shape
    {
      [9, 3, 400] => 0.0004 * ((400 * 83) + (2 * 400 * 401) + (82 * 401)),
      [9, 0, 10] => 0.0004 * (82 * 83),
      [9, 1, 10] => 1.0,
      [5, 1, 10] => 1.0
    }.each do |(board_size, layers, width), expected|
      arguments = REQUIRED + %W[--board-size #{board_size} --hidden-layers #{layers} --layer-size #{width}
                                --max-layer-size 400 --features none]
      assert_equal expected, SetupExperiment.settings_from_arguments(arguments)['initial_weight_changes'],
                   [board_size, layers, width].inspect
    end
  end

  # With every group, 9x9 1x10's 4.2608: 0.0004 x 10,652 weights.
  def test_the_initial_weight_changes_count_the_feature_inputs
    assert_in_delta 0.0004 * REQUIRED_WEIGHTS, SetupExperiment.settings_from_arguments(REQUIRED)['initial_weight_changes'],
                    1e-12
    assert_equal 4.2608, SetupExperiment.settings_from_arguments(REQUIRED)['initial_weight_changes'].round(4)
  end

  def test_the_total_weights_count_every_bias_and_weight
    assert_equal 1732, SetupExperiment.total_weights(9, 1, 10, 'none')
    assert_equal 82 * 83, SetupExperiment.total_weights(9, 0, 10, 'none')
    assert_equal (400 * 83) + (2 * 400 * 401) + (82 * 401), SetupExperiment.total_weights(9, 3, 400, 'none')
  end

  # Each group's inputs, as lib/ann.c's ann_layout_inputs lays them out: 3
  # planes each for shapes, tactics, and liberties, and for last_move the
  # near_last plane, the last_move plane, and opponent_passed.
  def test_the_total_weights_count_the_feature_inputs
    { 'shapes' => 82 + 243, 'tactics' => 82 + 243, 'liberties' => 82 + 243, 'last_move' => 82 + 163,
      ALL_GROUPS => 974, 'shapes,liberties' => 82 + 486 }.each do |features, inputs|
      assert_equal (inputs + 1) * 82, SetupExperiment.total_weights(9, 0, 10, features), features
      assert_equal (10 * (inputs + 1)) + (82 * 11), SetupExperiment.total_weights(9, 1, 10, features), features
    end
    assert_equal REQUIRED_WEIGHTS, SetupExperiment.total_weights(9, 1, 10, ALL_GROUPS)
    # 19x19: 1 + 12 x 361 + 1 inputs; 1x50.
    assert_equal 235_212, SetupExperiment.total_weights(19, 1, 50, ALL_GROUPS)
  end

  def test_initial_weight_changes_above_the_networks_weights_are_refused
    error = assert_raises(ArgumentError) do
      SetupExperiment.settings_from_arguments(REQUIRED + %W[--initial-weight-changes #{REQUIRED_WEIGHTS + 1}])
    end
    assert_includes error.message, 'initial_weight_changes'
    assert_includes error.message, REQUIRED_WEIGHTS.to_s
  end

  # The computed default is stored, so a later change of the formula never
  # changes an experiment that exists.
  def test_create_stores_the_computed_initial_weight_changes
    in_tmpdir do
      SetupExperiment.create('experiments/x', REQUIRED + %w[--hidden-layers 3 --layer-size 400 --max-layer-size 400])
      database = ExperimentDatabase.new('experiments/x/experiment.sqlite3', readonly: true)
      expected = 0.0004 * SetupExperiment.total_weights(9, 3, 400, ALL_GROUPS)
      assert_equal expected, Float(database.settings['initial_weight_changes'])
      assert_equal expected, SetupExperiment.parse(database.settings)['initial_weight_changes']
    end
  end

  def test_a_prompt_offers_the_computed_initial_weight_changes
    answers = prompt_answers('hidden_layers' => '3', 'layer_size' => '400', 'max_layer_size' => '400')
    $stdin = StringIO.new("#{answers.join("\n")}\n")
    settings = nil
    out, = capture_io { settings = SetupExperiment.prompt_for_settings }
    expected = 0.0004 * SetupExperiment.total_weights(9, 3, 400, ALL_GROUPS)
    assert_equal expected, settings['initial_weight_changes']
    assert_includes out, "(default #{expected})"
  ensure
    $stdin = STDIN
  end

  def test_a_prompt_asks_again_for_more_weight_changes_than_weights
    answers = prompt_answers('initial_weight_changes' => "#{REQUIRED_WEIGHTS + 1}\n5")
    $stdin = StringIO.new("#{answers.join("\n")}\n")
    settings = nil
    out, = capture_io { settings = SetupExperiment.prompt_for_settings }
    assert_equal 5.0, settings['initial_weight_changes']
    assert_includes out, 'initial_weight_changes must be at most'
  ensure
    $stdin = STDIN
  end

  def test_loading_refuses_more_weight_changes_than_weights
    in_tmpdir do
      database = ExperimentDatabase.new('experiment.sqlite3')
      database.save_settings(SetupExperiment.settings_from_arguments(REQUIRED).merge('initial_weight_changes' => '10653'))
      error = assert_raises(ArgumentError) { SetupExperiment.settings(database) }
      assert_includes error.message, 'initial_weight_changes'
    end
  end

  # The bounds on the shape evolution may give a network.
  def test_the_shape_bounds_have_defaults
    settings = SetupExperiment.settings_from_arguments(REQUIRED)
    assert_equal [4, 200], settings.values_at('max_hidden_layers', 'max_layer_size')
  end

  def test_an_initial_shape_at_the_bounds_is_accepted
    settings = SetupExperiment.settings_from_arguments(
      REQUIRED + %w[--hidden-layers 2 --layer-size 30 --max-hidden-layers 2 --max-layer-size 30]
    )
    assert_equal [2, 30, 2, 30], settings.values_at('hidden_layers', 'layer_size', 'max_hidden_layers', 'max_layer_size')
    none = SetupExperiment.settings_from_arguments(REQUIRED + %w[--hidden-layers 0 --max-hidden-layers 0])
    assert_equal [0, 0], none.values_at('hidden_layers', 'max_hidden_layers')
  end

  def test_more_initial_layers_than_the_bound_are_refused
    error = assert_raises(ArgumentError) { SetupExperiment.settings_from_arguments(REQUIRED + %w[--hidden-layers 5]) }
    assert_equal 'max_hidden_layers must be at least hidden_layers (5), got 4', error.message
  end

  def test_wider_initial_layers_than_the_bound_are_refused
    error = assert_raises(ArgumentError) do
      SetupExperiment.settings_from_arguments(REQUIRED + %w[--layer-size 30 --max-layer-size 20])
    end
    assert_equal 'max_layer_size must be at least layer_size (30), got 20', error.message
  end

  # Without hidden layers the width is unused until a layer is added, and
  # then it is clamped to max_layer_size.
  def test_the_width_of_no_hidden_layers_is_not_bounded
    settings = SetupExperiment.settings_from_arguments(REQUIRED + %w[--hidden-layers 0 --layer-size 500])
    assert_equal [500, 200], settings.values_at('layer_size', 'max_layer_size')
  end

  def test_a_prompt_asks_again_for_a_bound_below_the_initial_shape
    answers = prompt_answers('hidden_layers' => '6', 'max_hidden_layers' => "\n3\n6")
    $stdin = StringIO.new("#{answers.join("\n")}\n")
    settings = nil
    out, = capture_io { settings = SetupExperiment.prompt_for_settings }
    assert_equal 6, settings['max_hidden_layers']
    assert_includes out, 'max_hidden_layers must be at least hidden_layers (6), got 4'
    assert_includes out, 'max_hidden_layers must be at least hidden_layers (6), got 3'
  ensure
    $stdin = STDIN
  end

  def test_loading_refuses_an_initial_shape_above_the_bounds
    in_tmpdir do
      database = ExperimentDatabase.new('experiment.sqlite3')
      database.save_settings(SetupExperiment.settings_from_arguments(REQUIRED).merge('max_layer_size' => '9'))
      error = assert_raises(ArgumentError) { SetupExperiment.settings(database) }
      assert_includes error.message, 'max_layer_size must be at least layer_size (10)'
    end
  end

  # Half of a benchmark's games are played with each color.
  def test_an_odd_number_of_benchmark_games_is_refused_as_not_even
    error = assert_raises(ArgumentError) { SetupExperiment.settings_from_arguments(REQUIRED + %w[--benchmark-games 3]) }
    assert_equal 'benchmark_games must be an even whole number of at least 2, got 3', error.message
  end

  # The panel's bots play each other once per experiment; 0 turns that off.
  def test_the_bot_games_default_to_40_and_take_any_even_number_from_0
    assert_equal 40, SetupExperiment.settings_from_arguments(REQUIRED)['benchmark_bot_games']
    [0, 2, 100].each do |games|
      settings = SetupExperiment.settings_from_arguments(REQUIRED + ['--benchmark-bot-games', games.to_s])
      assert_equal games, settings['benchmark_bot_games']
    end
    error = assert_raises(ArgumentError) { SetupExperiment.settings_from_arguments(REQUIRED + %w[--benchmark-bot-games 1]) }
    assert_equal 'benchmark_bot_games must be an even whole number of at least 0, got 1', error.message
    keys = SetupExperiment::SETTINGS.keys
    assert_equal keys.index('benchmark_champions') + 1, keys.index('benchmark_bot_games')
  end

  # Komi is a multiple of 0.5, so a Tromp-Taylor margin is never zero
  # without being a draw, and never prints as W+0.0.
  def test_komi_takes_whole_and_half_numbers
    [['6.5', 6.5], ['-3', -3.0], ['7', 7.0], ['0', 0.0], ['50', 50.0], ['-50', -50.0]].each do |text, value|
      assert_equal value, SetupExperiment.settings_from_arguments(REQUIRED + ['--komi', text])['komi'], text
    end
  end

  def test_a_komi_that_is_no_multiple_of_a_half_is_refused_with_the_rule
    error = assert_raises(ArgumentError) { SetupExperiment.settings_from_arguments(REQUIRED + %w[--komi 7.25]) }
    assert_equal 'komi must be a multiple of 0.5 from -50 to 50, got 7.25', error.message
  end

  def test_a_missing_required_setting_is_named
    error = assert_raises(ArgumentError) { SetupExperiment.settings_from_arguments(REQUIRED[0..-3]) }
    assert_includes error.message, '--tournament-rounds'
  end

  def test_an_unknown_setting_is_named
    error = assert_raises(ArgumentError) { SetupExperiment.settings_from_arguments(REQUIRED + %w[--boards 9]) }
    assert_includes error.message, '--boards'
  end

  def test_an_abbreviated_option_is_not_accepted
    # OptionParser would otherwise read --board as --board-size.
    assert_raises(ArgumentError) { SetupExperiment.settings_from_arguments(REQUIRED[2..] + %w[--board 9]) }
  end

  def test_an_option_without_a_value_is_an_error
    assert_raises(ArgumentError) { SetupExperiment.settings_from_arguments(REQUIRED + %w[--seed]) }
  end

  def test_a_stray_argument_is_an_error
    error = assert_raises(ArgumentError) { SetupExperiment.settings_from_arguments(REQUIRED + %w[extra]) }
    assert_includes error.message, 'extra'
  end

  def test_the_help_lists_every_setting_with_its_default
    help = SetupExperiment.option_parser({}).help
    SetupExperiment::SETTINGS.each_key { |key| assert_includes help, "--#{key.tr('_', '-')}" }
    assert_includes help, 'default 3'
    assert_includes help, 'an even whole number of at least 2, default 20'
    assert_includes help, 'a whole number of at least 0, default 4'
    assert_includes help, '--komi VALUE'
    assert_includes help, 'a multiple of 0.5 from -50 to 50, default 6.5'
    assert_includes help, 'a number from 1 to 1000000000, default from the generation-0 shape and features'
    assert_includes help, 'Hidden layers of generation 0'
  end

  def test_create_writes_the_settings_into_a_new_experiment
    in_tmpdir do
      SetupExperiment.create('experiments/x', REQUIRED)
      database = ExperimentDatabase.new('experiments/x/experiment.sqlite3', readonly: true)
      # The database keeps strings; loading parses them again.
      assert_equal '9', database.settings['board_size']
      assert_equal '0.5', database.settings['cross_over_rate']
    end
  end

  def test_a_new_experiment_stores_its_opponents_and_scoring
    in_tmpdir do
      SetupExperiment.create('experiments/x', REQUIRED)
      database = ExperimentDatabase.new('experiments/x/experiment.sqlite3', readonly: true)
      assert_equal SetupExperiment::DEFAULT_OPPONENTS, database.opponents
      assert_equal SetupExperiment::DEFAULT_SCORING, database.scoring
      # Rules 4: every game in the arena, scored by Tromp-Taylor, and no
      # game between two copies of one bot while another player is left.
      assert_equal '4', database.scoring['rules']
      assert_equal SetupExperiment::DEFAULT_BENCHMARK, database.benchmark_opponents
    end
  end

  # The tournament's bots, weakest first: the michi levels calibrated between
  # AmiGo and GNU Go level 0 (docs/experiment-reference.md), and GNU Go with
  # --capture-all-dead, so it leaves no dead stones for Tromp-Taylor to count.
  def test_the_default_opponents
    assert_equal [['Brown', 'brown', 5], ['AmiGo', 'amigogtp', 10],
                  ['MichiWeak', 'michi gtp --sims 80 --play-until-end', 5],
                  ['MichiMid', 'michi gtp --sims 300 --play-until-end', 5],
                  ['MichiStrong', 'michi gtp --sims 1200 --play-until-end', 5],
                  ['GnuGo', 'gnugo --level 0 --mode gtp --capture-all-dead', 3]],
                 SetupExperiment::DEFAULT_OPPONENTS.map { |o| o.values_at(:name, :command, :copies) }
  end

  # The benchmark panel: the bots weakest first, the michi levels with the
  # tournament's commands, GNU Go level 0 without an ending flag (its GNU Go
  # referee removes dead stones), then the two network opponents the runner
  # picks from the experiment's own generations: generation 0's champion and
  # the rolling set of past checkpoints' champions.
  def test_the_default_benchmark_panel
    assert_equal [%w[Brown bot brown], %w[AmiGo bot amigogtp],
                  ['MichiWeak', 'bot', 'michi gtp --sims 80 --play-until-end'],
                  ['MichiMid', 'bot', 'michi gtp --sims 300 --play-until-end'],
                  ['MichiStrong', 'bot', 'michi gtp --sims 1200 --play-until-end'],
                  ['GnuGoLevel0', 'bot', 'gnugo --level 0 --mode gtp'],
                  ['Gen0Champion', 'initial_champion', nil], ['PastChampions', 'past_champions', nil]],
                 SetupExperiment::DEFAULT_BENCHMARK.map { |o| o.values_at(:name, :kind, :command) }
  end

  def test_prompted_settings_store_the_opponents_and_scoring_too
    in_tmpdir do
      database = ExperimentDatabase.new('experiment.sqlite3')
      answers = prompt_answers
      with_stdin("#{answers.join("\n")}\n") { SetupExperiment.settings(database) }
      assert_equal 6, database.opponents.size
      assert_equal SetupExperiment::DEFAULT_SCORING, database.scoring
      assert_equal SetupExperiment::DEFAULT_BENCHMARK, database.benchmark_opponents
    end
  end

  # Settings without their opponents and scoring could never run, so the
  # two are saved together or not at all.
  def test_settings_are_not_saved_without_their_rules
    in_tmpdir do
      database = ExperimentDatabase.new('experiment.sqlite3')
      database.define_singleton_method(:save_scoring) { |_| raise IOError, 'disk full' }
      answers = prompt_answers
      with_stdin("#{answers.join("\n")}\n") do
        assert_raises(IOError) { SetupExperiment.settings(database) }
      end
      assert_empty database.settings
      assert_empty database.opponents
    end
  end

  def test_settings_are_not_saved_without_their_benchmark_panel
    in_tmpdir do
      database = ExperimentDatabase.new('experiment.sqlite3')
      database.define_singleton_method(:save_benchmark_opponents) { |_| raise IOError, 'disk full' }
      with_stdin("#{prompt_answers.join("\n")}\n") do
        assert_raises(IOError) { SetupExperiment.settings(database) }
      end
      assert_empty database.settings
      assert_empty database.opponents
      assert_empty database.scoring
    end
  end

  # Scoring logic that changed since the experiment began would score its
  # remaining games by different rules, so the run refuses to start.
  def test_an_experiment_scored_by_other_rules_does_not_run
    in_tmpdir do
      fake_checkout
      database = ExperimentDatabase.new('experiments/x/experiment.sqlite3')
      database.save_scoring(database.scoring.merge('rules' => 'older'))
      database.close
      error = assert_raises(RuntimeError) { capture_io { run_setup } }
      assert_includes error.message, 'older'
      refute File.exist?('experiments/x/evo')
      refute File.exist?('make.log')
    end
  end

  # An experiment begun before every tournament game went through the arena
  # continues only with the code it began with.
  def test_an_experiment_scored_by_rules_2_does_not_run
    in_tmpdir do
      fake_checkout
      database = ExperimentDatabase.new('experiments/x/experiment.sqlite3')
      database.save_scoring(database.scoring.merge('rules' => '2'))
      database.close
      error = assert_raises(RuntimeError) { capture_io { run_setup } }
      assert_includes error.message, 'rules "2", but the code scores by "4"'
    end
  end

  # An experiment begun while copies of one bot could play each other
  # continues only with the code it began with.
  def test_an_experiment_scored_by_rules_3_does_not_run
    in_tmpdir do
      fake_checkout
      database = ExperimentDatabase.new('experiments/x/experiment.sqlite3')
      database.save_scoring(database.scoring.merge('rules' => '3'))
      database.close
      error = assert_raises(RuntimeError) { capture_io { run_setup } }
      assert_includes error.message, 'rules "3", but the code scores by "4"'
    end
  end

  def test_create_refuses_an_experiment_that_already_has_settings
    in_tmpdir do
      SetupExperiment.create('experiments/x', REQUIRED)
      assert_raises(ArgumentError) { SetupExperiment.create('experiments/x', REQUIRED) }
    end
  end

  # The michi levels were calibrated on 9x9 only (docs/experiment-reference.md),
  # and the default panels hold them, so a new experiment on any other board
  # is refused before anything is written.
  def test_create_refuses_a_board_other_than_9_with_the_michi_panel
    in_tmpdir do
      %w[5 13 19].each do |size|
        arguments = REQUIRED + %W[--board-size #{size}]
        error = assert_raises(ArgumentError, size) { SetupExperiment.create('experiments/x', arguments) }
        assert_includes error.message, "board_size #{size}"
        assert_includes error.message, 'calibrated for 9×9 only'
        assert_includes error.message, 'MichiWeak'
        refute Dir.exist?('experiments/x'), size
      end
    end
  end

  def test_the_prompts_refuse_a_board_other_than_9_with_the_michi_panel
    in_tmpdir do
      database = ExperimentDatabase.new('experiment.sqlite3')
      answers = prompt_answers('board_size' => '13')
      with_stdin("#{answers.join("\n")}\n") do
        error = assert_raises(SetupExperiment::Refused) { SetupExperiment.settings(database) }
        assert_includes error.message, 'calibrated for 9×9 only'
      end
      assert_empty database.settings
      assert_empty database.opponents
    end
  end

  # A stored experiment is checked against its own panels: a michi command
  # in either one refuses any board but 9x9, and without michi other sizes
  # still run.
  def test_loading_refuses_a_board_other_than_9_when_a_panel_holds_michi
    stored = SetupExperiment.settings_from_arguments(REQUIRED + %w[--board-size 13])
    michi = { name: 'MichiWeak', command: 'michi gtp --sims 80 --play-until-end', copies: 1 }
    brown = { name: 'Brown', command: 'brown', copies: 1 }
    [[[michi], []], [[brown], [michi.slice(:name, :command).merge(kind: 'bot')]]].each do |opponents, benchmark|
      in_tmpdir do
        database = ExperimentDatabase.new('experiment.sqlite3')
        database.save_settings(stored)
        database.save_opponents(opponents)
        database.save_benchmark_opponents(benchmark)
        error = assert_raises(SetupExperiment::Refused) { SetupExperiment.settings(database) }
        assert_includes error.message, 'board_size 13'
        assert_includes error.message, 'calibrated for 9×9 only'
      end
    end
    in_tmpdir do
      database = ExperimentDatabase.new('experiment.sqlite3')
      database.save_settings(stored)
      database.save_opponents([brown])
      database.save_benchmark_opponents([{ name: 'Brown', kind: 'bot', command: 'brown' }])
      assert_equal 13, SetupExperiment.settings(database)['board_size']
    end
  end

  # On 9x9 the michi panel loads.
  def test_loading_accepts_9x9_with_the_michi_panel
    in_tmpdir do
      SetupExperiment.create('experiments/x', REQUIRED)
      database = ExperimentDatabase.new('experiments/x/experiment.sqlite3')
      assert_equal 9, SetupExperiment.settings(database)['board_size']
    end
  end

  def test_the_prompts_ask_for_every_setting
    answers = prompt_answers.join("\n")
    $stdin = StringIO.new("#{answers}\n")
    settings = nil
    capture_io { settings = SetupExperiment.prompt_for_settings }
    assert_equal SetupExperiment::SETTINGS.keys.sort, settings.keys.sort
    assert_kind_of Integer, settings['seed']
  ensure
    $stdin = STDIN
  end

  def test_a_prompt_asks_again_after_a_bad_answer
    answers = prompt_answers('board_size' => "9x9\n9")
    $stdin = StringIO.new("#{answers.join("\n")}\n")
    settings = nil
    out, = capture_io { settings = SetupExperiment.prompt_for_settings }
    assert_equal 9, settings['board_size']
    assert_includes out, 'board_size must be'
  ensure
    $stdin = STDIN
  end

  def test_loading_parses_the_stored_settings
    in_tmpdir do
      database = ExperimentDatabase.new('experiment.sqlite3')
      database.save_settings(SetupExperiment.settings_from_arguments(REQUIRED))
      settings = SetupExperiment.settings(database)
      assert_equal 9, settings['board_size']
      assert_equal 0.5, settings['cross_over_rate']
    end
  end

  def test_loading_refuses_a_bad_stored_setting
    in_tmpdir do
      database = ExperimentDatabase.new('experiment.sqlite3')
      database.save_settings(SetupExperiment.settings_from_arguments(REQUIRED).merge('max_moves' => 'lots'))
      error = assert_raises(ArgumentError) { SetupExperiment.settings(database) }
      assert_includes error.message, 'max_moves'
    end
  end

  # A fake checkout: the four executables, committed to git, an installed
  # external tools release, and a Makefile whose build appends to make.log
  # whether experiments/x's lock was held while it ran.
  def fake_checkout
    File.write('Makefile', <<~MAKE)
      all:
      \t@#{RbConfig.ruby} -e 'held = !File.open("experiments/x/experiment.lock").flock(File::LOCK_EX | File::LOCK_NB); File.write("make.log", held ? "built, locked\\n" : "built, unlocked\\n", mode: "a")'
    MAKE
    { 'engine/evo' => 'evo v1', 'engine/arena' => 'arena v1', 'initial-population/initial-population' => 'ip v1', 'evolve/evolve' => 'evolve v1' }.each do |path, text|
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, text)
    end
    FileUtils.mkdir_p('.local/evo-tools/releases/tools_r7')
    File.symlink('releases/tools_r7', '.local/evo-tools/current')
    git = 'git -c user.name=t -c user.email=t@example.com'
    system("git init -q . && #{git} add engine initial-population evolve && #{git} commit -q -m init", exception: true)
    SetupExperiment.create('experiments/x', REQUIRED)
  end

  def run_setup
    SetupExperiment.call('experiments/x') { |_settings, database| return database.provenance }
  end

  def test_the_executables_are_copied_once_and_their_build_recorded
    in_tmpdir do
      fake_checkout
      provenance = nil
      capture_io { provenance = run_setup }
      %w[evo arena initial-population evolve].each do |name|
        path = "experiments/x/#{name}"
        refute File.symlink?(path), name
        assert File.executable?(path) || File.file?(path), name
      end
      assert_equal 'evo v1', File.read('experiments/x/evo')
      assert_equal 'arena v1', File.read('experiments/x/arena')
      assert_equal `git rev-parse HEAD`.strip, provenance['code_revision']
      assert_equal 'false', provenance['uncommitted_changes']
      assert_equal 'tools_r7', provenance['external_tools']

      # A rebuild does not reach an experiment that has its executables.
      File.write('engine/evo', 'evo v2')
      capture_io { provenance = run_setup }
      assert_equal 'evo v1', File.read('experiments/x/evo')
      assert_equal 'false', provenance['uncommitted_changes']
    end
  end

  # The build is needed only for the copies: a resumed experiment runs its
  # own executables, so it compiles nothing.
  def test_the_first_run_builds_after_taking_the_lock_and_a_resume_does_not
    in_tmpdir do
      fake_checkout
      out, = capture_io { run_setup }
      assert_includes out, 'Building C programs ... ✔'
      assert_equal "built, locked\n", File.read('make.log')
      out, = capture_io { run_setup }
      refute_includes out, 'Building C programs'
      assert_equal "built, locked\n", File.read('make.log')
    end
  end

  def test_a_failed_build_is_refused_with_makes_output_and_copies_nothing
    in_tmpdir do
      fake_checkout
      File.write('Makefile', "all:\n\t@echo compiling engine; echo 'arena.c:1: error: broken' >&2; exit 1\n")
      error = assert_raises(SetupExperiment::Refused) { capture_io { run_setup } }
      assert_includes error.message, 'compiling engine'
      assert_includes error.message, 'arena.c:1: error: broken'
      refute File.exist?('experiments/x/evo')
      assert_empty ExperimentDatabase.new('experiments/x/experiment.sqlite3').provenance
      lock = ExperimentLock.acquire('experiments/x')
      assert lock, 'a refused runner releases the lock'
      lock.close
    end
  end

  def test_an_experiment_missing_an_executable_is_not_given_new_ones
    in_tmpdir do
      fake_checkout
      capture_io { run_setup }
      File.delete('experiments/x/evolve')
      File.write('engine/evo', 'evo v2')
      error = assert_raises(RuntimeError) { capture_io { run_setup } }
      assert_includes error.message, 'evolve'
      assert_equal 'evo v1', File.read('experiments/x/evo')
      refute File.exist?('experiments/x/evolve')
    end
  end

  def test_aborting_the_prompts_copies_nothing
    in_tmpdir do
      fake_checkout
      FileUtils.rm_rf('experiments/x')
      with_stdin("9\n") do
        assert_raises(SetupExperiment::PromptAborted) { SetupExperiment.call('experiments/x') { flunk } }
      end
      refute File.exist?('experiments/x/evo')
      refute File.exist?('make.log')
      assert_empty ExperimentDatabase.new('experiments/x/experiment.sqlite3').provenance
    end
  end

  def test_uncommitted_changes_are_recorded
    in_tmpdir do
      fake_checkout
      File.write('engine/evo', 'evo v1 edited')
      provenance = nil
      capture_io { provenance = run_setup }
      assert_equal 'true', provenance['uncommitted_changes']
      assert_equal 'evo v1 edited', File.read('experiments/x/evo')
    end
  end

  def with_stdin(text)
    $stdin = StringIO.new(text)
    capture_io { yield }
  ensure
    $stdin = STDIN
  end

  def test_input_ending_during_the_prompts_saves_nothing
    in_tmpdir do
      database = ExperimentDatabase.new('experiment.sqlite3')
      with_stdin("9\n4\n") do
        error = assert_raises(SetupExperiment::PromptAborted) { SetupExperiment.settings(database) }
        assert_includes error.message, 'hidden_layers'
      end
      assert_empty database.settings
    end
  end

  def test_an_empty_answer_to_a_required_prompt_saves_nothing
    in_tmpdir do
      database = ExperimentDatabase.new('experiment.sqlite3')
      with_stdin("\n" * SetupExperiment::SETTINGS.size) do
        error = assert_raises(SetupExperiment::PromptAborted) { SetupExperiment.settings(database) }
        assert_includes error.message, 'board_size'
      end
      assert_empty database.settings
    end
  end

  def test_a_settings_json_is_not_read
    in_tmpdir do
      File.write('settings.json', JSON.generate('board_size' => '19'))
      database = ExperimentDatabase.new('experiment.sqlite3')
      database.save_settings(SetupExperiment.settings_from_arguments(REQUIRED))
      assert_equal 9, SetupExperiment.settings(database)['board_size']
      assert File.exist?('settings.json')
    end
  end

  ENV_VARS = { 'BUNDLE_GEMFILE' => File.expand_path('../Gemfile', __dir__) }.freeze

  # Starts a process that holds the experiment's lock until its stdin
  # closes, as a running runner does, and yields once it holds it.
  def holding_the_lock_elsewhere(experiment_dir)
    script = "require 'bundler/setup'; require #{File.expand_path('../ruby/experiment_lock', __dir__).inspect}; " \
             "lock = ExperimentLock.acquire(#{experiment_dir.inspect}) or abort 'not locked'; " \
             'puts :locked; $stdout.flush; $stdin.read'
    IO.popen(ENV_VARS, ['ruby', '-e', script], 'r+') do |io|
      # Closing stdin ends the child even when an assertion fails, so the
      # block's end does not wait on it forever.
      begin
        assert_equal "locked\n", Timeout.timeout(LOCK_TIMEOUT) { io.gets }
        yield
      ensure
        io.close_write
      end
    end
  end

  # A broken lock must fail these tests, not hang them: a runner that
  # ignored a held lock would go on to prompt for settings.
  LOCK_TIMEOUT = 30

  def bounded(&)
    $stdin = StringIO.new('')
    Timeout.timeout(LOCK_TIMEOUT, &)
  ensure
    $stdin = STDIN
  end

  def test_the_runner_holds_the_lock_while_it_runs
    in_tmpdir do
      fake_checkout
      held = nil
      bounded { capture_io { SetupExperiment.call('experiments/x') { held = ExperimentLock.acquire('.') } } }
      assert_nil held, 'a second lock while the runner runs'
      lock = ExperimentLock.acquire('experiments/x')
      assert lock, 'the lock is released once the runner ends'
      lock.close
    end
  end

  # A runner that opened the database before locking could keep writing
  # to it after an archive replaced it, so a held lock stops the runner
  # before it opens anything.
  def test_a_held_lock_refuses_the_runner_before_it_opens_the_database
    in_tmpdir do
      FileUtils.mkdir_p('experiments/y')
      holding_the_lock_elsewhere('experiments/y') do
        error = assert_raises(SetupExperiment::Refused) do
          bounded { capture_io { SetupExperiment.call('experiments/y') { flunk } } }
        end
        assert_includes error.message, 'experiments/y'
        assert_includes error.message, ExperimentLock::FILE
      end
      refute File.exist?('experiments/y/experiment.sqlite3')
    end
  end

  # Ruby opens files close-on-exec, so the games the runner starts do not
  # keep its lock after it ends.
  def test_a_child_process_does_not_inherit_the_lock
    in_tmpdir do
      FileUtils.mkdir_p('experiments/x')
      lock = ExperimentLock.acquire('experiments/x')
      child = Process.spawn('sleep 30')
      lock.close
      again = ExperimentLock.acquire('experiments/x')
      assert again, 'the child holds the lock'
      again.close
    ensure
      Process.kill(:KILL, child) if child
      Process.wait(child) if child
    end
  end

  # The check comes before the migrations, so an archived experiment is
  # left exactly as the archive wrote it.
  def test_an_archived_experiment_is_refused_before_migrating
    in_tmpdir do
      fake_checkout
      db = Sequel.sqlite('experiments/y/experiment.sqlite3'.tap { |path| FileUtils.mkdir_p(File.dirname(path)) })
      Sequel::Migrator.run(db, ExperimentDatabase::MIGRATIONS, target: 11)
      db[:settings].insert(key: 'archived', value: '2026-09-29 10:00:00 +0200')
      db.disconnect
      error = assert_raises(SetupExperiment::Refused) { capture_io { SetupExperiment.call('experiments/y') { flunk } } }
      assert_includes error.message, 'archived'
      assert_includes error.message, '2026-09-29 10:00:00 +0200'
      db = Sequel.sqlite('experiments/y/experiment.sqlite3', readonly: true)
      assert_equal 11, db[:schema_info].get(:version)
      db.disconnect
      lock = ExperimentLock.acquire('experiments/y')
      assert lock, 'a refused runner releases the lock'
      lock.close
    end
  end

  # A runner killed during a transaction leaves a hot journal, which a
  # read-only connection cannot roll back. The runner must still start and
  # roll it back, as it did before the archived check.
  def test_a_hot_journal_is_rolled_back_rather_than_refused
    in_tmpdir do
      fake_checkout
      path = 'experiments/x/experiment.sqlite3'
      leave_hot_journal(path, "update settings set value = 'broken'")
      settings = nil
      capture_io { SetupExperiment.call('experiments/x') { |s, _| settings = s } }
      assert_equal 9, settings['board_size']
      refute File.exist?("#{path}-journal")
    end
  end

  # The rolled-back transaction had deleted the `archived` setting, which
  # only the roll-back brings back.
  def test_an_archived_experiment_with_a_hot_journal_is_still_refused
    in_tmpdir do
      fake_checkout
      path = 'experiments/x/experiment.sqlite3'
      db = Sequel.sqlite(path)
      db[:settings].insert(key: 'archived', value: 'yesterday')
      db.disconnect
      leave_hot_journal(path, "delete from settings where key = 'archived'")
      error = assert_raises(SetupExperiment::Refused) { capture_io { SetupExperiment.call('experiments/x') { flunk } } }
      assert_includes error.message, 'yesterday'
    end
  end
end
