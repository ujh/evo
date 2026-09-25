require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'tmpdir'
require_relative '../ruby/run_generation'
require_relative '../ruby/experiment_database'

$stop_now = false

module RunGenerationHelpers
  FIXTURES = File.expand_path('fixtures', __dir__)

  SETTINGS = {
    'board_size' => '9',
    'population_size' => '2',
    'hidden_layers' => '1',
    'layer_size' => '10',
    'cross_over_rate' => '0.5',
    'game_length' => '10',
    'max_moves' => '200',
    'tournament_rounds' => '1',
    'seed' => '1',
    'concurrency' => 1
  }.freeze

  # Tests build the object without calling initialize and set its instance
  # variables directly. A fixed seed keeps parent selection reproducible.
  def build_generation(generation: '1', settings: {}, rng: Random.new(42), store: ExperimentDatabase.new(':memory:'))
    gen = RunGeneration.allocate
    gen.instance_variable_set(:@generation, generation)
    gen.instance_variable_set(:@settings, SETTINGS.merge(settings))
    gen.instance_variable_set(:@rng, rng)
    gen.instance_variable_set(:@store, store)
    gen
  end

  # Runs the block inside a fresh experiment directory, chdir'd into the given
  # generation directory, the way RunGeneration#setup does.
  def in_experiment(generation: '1')
    Dir.mktmpdir('evo-test') do |dir|
      path = File.join(dir, generation)
      FileUtils.mkdir_p(path)
      Dir.chdir(path) { yield dir }
    end
  end

  def write_data(hash, path = 'data.json')
    File.write(path, JSON.pretty_generate(hash))
  end

  # Copies a result fixture and, when there is one, the twogtp stderr it came with.
  def copy_dat(fixture, prefix)
    %w[dat err].each do |ext|
      source = File.join(FIXTURES, 'dat', "#{fixture}.#{ext}")
      FileUtils.cp(source, "#{prefix}.#{ext}") if File.exist?(source)
    end
  end
end
