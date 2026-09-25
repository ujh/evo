require 'minitest/autorun'
require 'json'
require 'stringio'
require 'tmpdir'
require_relative '../ruby/setup_experiment'

class SetupExperimentTest < Minitest::Test
  REQUIRED = %w[board_size=9 population_size=4 hidden_layers=1 layer_size=10 cross_over_rate=0.5
                game_length=10 max_moves=200 tournament_rounds=1].freeze

  def in_tmpdir(&)
    Dir.mktmpdir { |dir| Dir.chdir(dir, &) }
  end

  def test_arguments_give_settings_with_defaults_for_the_rest
    settings = SetupExperiment.settings_from_arguments(REQUIRED)
    assert_equal '9', settings['board_size']
    assert_equal '3', settings['tournament_size']
    assert_equal '10', settings['sgf_every']
    assert_match(/\A\d+\z/, settings['seed'])
    assert_equal SetupExperiment::SETTINGS.keys.sort, settings.keys.sort
  end

  def test_an_argument_overrides_a_default
    assert_equal '5', SetupExperiment.settings_from_arguments(REQUIRED + ['tournament_size=5'])['tournament_size']
  end

  def test_a_missing_required_setting_is_named
    error = assert_raises(ArgumentError) { SetupExperiment.settings_from_arguments(REQUIRED - ['max_moves=200']) }
    assert_includes error.message, 'max_moves'
  end

  def test_an_unknown_setting_is_named
    error = assert_raises(ArgumentError) { SetupExperiment.settings_from_arguments(REQUIRED + ['board=9']) }
    assert_includes error.message, 'board'
  end

  def test_create_writes_the_settings_into_a_new_experiment
    in_tmpdir do
      SetupExperiment.create('experiments/x', REQUIRED)
      database = ExperimentDatabase.new('experiments/x/experiment.sqlite3', readonly: true)
      assert_equal '9', database.settings['board_size']
    end
  end

  def test_create_refuses_an_experiment_that_already_has_settings
    in_tmpdir do
      SetupExperiment.create('experiments/x', REQUIRED)
      assert_raises(ArgumentError) { SetupExperiment.create('experiments/x', REQUIRED) }
    end
  end

  def test_the_prompts_ask_for_every_setting
    answers = SetupExperiment::SETTINGS.keys.map { |key| key == 'seed' ? '' : '1' }.join("\n")
    $stdin = StringIO.new("#{answers}\n")
    settings = nil
    capture_io { settings = SetupExperiment.prompt_for_settings }
    assert_equal SetupExperiment::SETTINGS.keys.sort, settings.keys.sort
    assert_match(/\A\d+\z/, settings['seed'])
  ensure
    $stdin = STDIN
  end

  def test_a_settings_json_is_not_read
    in_tmpdir do
      File.write('settings.json', JSON.generate('board_size' => '19'))
      database = ExperimentDatabase.new('experiment.sqlite3')
      database.save_settings(SetupExperiment.settings_from_arguments(REQUIRED))
      assert_equal '9', SetupExperiment.settings(database)['board_size']
      assert File.exist?('settings.json')
    end
  end
end
