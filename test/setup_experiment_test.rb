require 'minitest/autorun'
require 'json'
require 'tmpdir'
require_relative '../ruby/setup_experiment'

class SetupExperimentTest < Minitest::Test
  def in_tmpdir(&)
    Dir.mktmpdir { |dir| Dir.chdir(dir, &) }
  end

  def test_a_settings_json_is_imported_once_given_a_seed_and_removed
    in_tmpdir do
      File.write('settings.json', JSON.generate('board_size' => 9))
      database = ExperimentDatabase.new('experiment.sqlite3')
      first = SetupExperiment.settings(database)
      assert_equal '9', first['board_size']
      assert_match(/\A\d+\z/, first['seed'])
      refute File.exist?('settings.json')
      assert_equal first, database.settings
      assert_equal first, SetupExperiment.settings(database)
    end
  end

  def test_settings_in_the_database_win_over_a_settings_json
    in_tmpdir do
      database = ExperimentDatabase.new('experiment.sqlite3')
      database.save_settings('board_size' => '9', 'seed' => '5')
      File.write('settings.json', JSON.generate('board_size' => '19'))
      assert_equal({ 'board_size' => '9', 'seed' => '5' }, SetupExperiment.settings(database))
    end
  end
end
