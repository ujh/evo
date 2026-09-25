require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'tmpdir'
require_relative '../ruby/run_generation'
require_relative '../ruby/experiment_database'
require_relative '../ruby/setup_experiment'

$stop_now = false

module RunGenerationHelpers
  FIXTURES = File.expand_path('fixtures', __dir__)

  SETTINGS = {
    'board_size' => 9,
    'population_size' => 2,
    'hidden_layers' => 1,
    'layer_size' => 10,
    'cross_over_rate' => 0.5,
    'game_length' => 10,
    'max_moves' => 200,
    'tournament_rounds' => 1,
    'tournament_size' => 3,
    'seed' => 1,
    'keep_every' => 10,
    'concurrency' => 1
  }.freeze

  # Tests build the object without calling initialize and set its instance
  # variables directly. A fixed seed keeps parent selection reproducible.
  def build_generation(generation: '1', settings: {}, rng: Random.new(42), store: database)
    gen = RunGeneration.allocate
    gen.instance_variable_set(:@generation, generation)
    gen.instance_variable_set(:@settings, SETTINGS.merge(settings))
    gen.instance_variable_set(:@rng, rng)
    gen.instance_variable_set(:@store, store)
    gen
  end

  # Runs the block inside a fresh directory named after the generation.
  # Tests of RunGeneration#setup see it as the experiment directory, since
  # setup creates work/ inside it; other tests use it as work/ itself.
  def in_experiment(generation: '1')
    Dir.mktmpdir('evo-test') do |dir|
      path = File.join(dir, generation)
      FileUtils.mkdir_p(path)
      Dir.chdir(path) { yield dir }
    end
  end

  # One in-memory experiment database per test, with the opponents and
  # scoring a new experiment gets.
  def database
    @database ||= ExperimentDatabase.new(':memory:').tap { |db| SetupExperiment.save_rules(db) }
  end

  # Saves a generation's tournament state, as the runner's save_data does.
  # Called either with a hash or with the state's keys as keyword arguments.
  def write_data(hash = {}, generation: 1, **state)
    database.save_state(generation, hash.merge(state))
  end

  # Copies a result fixture and, when there is one, the twogtp stderr it came with.
  def copy_dat(fixture, prefix)
    %w[dat err].each do |ext|
      source = File.join(FIXTURES, 'dat', "#{fixture}.#{ext}")
      FileUtils.cp(source, "#{prefix}.#{ext}") if File.exist?(source)
    end
  end
end
