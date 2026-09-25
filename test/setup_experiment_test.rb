require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'stringio'
require 'tmpdir'
require_relative '../ruby/setup_experiment'

class SetupExperimentTest < Minitest::Test
  REQUIRED = %w[--board-size 9 --population-size 4 --hidden-layers 1 --layer-size 10 --cross-over-rate 0.5
                --game-length 10 --max-moves 200 --tournament-rounds 1].freeze

  def in_tmpdir(&)
    Dir.mktmpdir { |dir| Dir.chdir(dir, &) }
  end

  def test_arguments_give_settings_with_defaults_for_the_rest
    settings = SetupExperiment.settings_from_arguments(REQUIRED)
    assert_equal 9, settings['board_size']
    assert_equal 3, settings['tournament_size']
    assert_equal 10, settings['keep_every']
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
    %w[--game-length 0], %w[--max-moves 2.5], %w[--tournament-rounds ten], %w[--tournament-rounds 0],
    %w[--tournament-size 0], %w[--keep-every -1], %w[--seed -3], %w[--seed 9223372036854775808]
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

  def test_the_edges_of_each_range_are_accepted
    settings = SetupExperiment.settings_from_arguments(
      REQUIRED + %w[--board-size 19 --hidden-layers 0 --cross-over-rate 1 --keep-every 0 --seed 0]
    )
    assert_equal [19, 0, 1.0, 0, 0], settings.values_at('board_size', 'hidden_layers', 'cross_over_rate', 'keep_every', 'seed')
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

  def test_create_refuses_an_experiment_that_already_has_settings
    in_tmpdir do
      SetupExperiment.create('experiments/x', REQUIRED)
      assert_raises(ArgumentError) { SetupExperiment.create('experiments/x', REQUIRED) }
    end
  end

  def test_the_prompts_ask_for_every_setting
    answers = SetupExperiment::SETTINGS.keys.map { |key| { 'seed' => '', 'board_size' => '9' }.fetch(key, '1') }.join("\n")
    $stdin = StringIO.new("#{answers}\n")
    settings = nil
    capture_io { settings = SetupExperiment.prompt_for_settings }
    assert_equal SetupExperiment::SETTINGS.keys.sort, settings.keys.sort
    assert_kind_of Integer, settings['seed']
  ensure
    $stdin = STDIN
  end

  def test_a_prompt_asks_again_after_a_bad_answer
    answers = SetupExperiment::SETTINGS.keys.map { |key| { 'seed' => '', 'board_size' => "9x9\n9" }.fetch(key, '1') }
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

  # A fake checkout: the three executables, committed to git, and an
  # installed external tools release.
  def fake_checkout
    { 'engine/evo' => 'evo v1', 'initial-population/initial-population' => 'ip v1', 'evolve/evolve' => 'evolve v1' }.each do |path, text|
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
      %w[evo initial-population evolve].each do |name|
        path = "experiments/x/#{name}"
        refute File.symlink?(path), name
        assert File.executable?(path) || File.file?(path), name
      end
      assert_equal 'evo v1', File.read('experiments/x/evo')
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
end
