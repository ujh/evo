require 'minitest/autorun'
require 'json'
require 'tmpdir'
require_relative '../ruby/setup_experiment'

class SetupExperimentTest < Minitest::Test
  def test_settings_without_a_seed_get_one_and_keep_it
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        File.write('settings.json', JSON.generate('board_size' => '9'))
        first = SetupExperiment.settings
        assert_match(/\A\d+\z/, first['seed'])
        assert_equal first, JSON.load_file('settings.json')
        assert_equal first['seed'], SetupExperiment.settings['seed']
      end
    end
  end
end
