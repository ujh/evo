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
    'max_hidden_layers' => 4,
    'max_layer_size' => 200,
    'features' => 'none',
    'cross_over_rate' => 0.5,
    'game_length' => 10,
    'max_moves' => 200,
    'tournament_rounds' => 1,
    'tournament_size' => 3,
    'seed' => 1,
    'keep_every' => 10,
    'benchmark_games' => 20,
    'benchmark_opening_moves' => 4,
    'komi' => 6.5,
    'meta_rate' => 0.2,
    'initial_copy_chance' => 0.01,
    'initial_weight_changes' => 1.0,
    'initial_weight_step' => 0.5,
    'initial_activation_rate' => 0.02,
    'initial_structure_rate' => 0.02,
    'initial_feature_noise' => 0.3,
    'initial_feature_step' => 0.01,
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

# One line of the arena's output for a played game, in its exact format.
def arena_played(id, result: 'B+3.5', finish: 'passes', moves: %w[C3 D4 pass pass],
                 time_black: 0.012, time_white: 0.034, duration: 0.05)
  times = [time_black, time_white, duration].map { |t| format('%.6f', t) }
  [id, "result=#{result}", "end=#{finish}", "length=#{moves.size}", "time_black=#{times[0]}",
   "time_white=#{times[1]}", "duration=#{times[2]}", "moves=#{moves.join(',')}", 'ok'].join("\t")
end

# The arena's line for a game where a network cannot play.
def arena_errored(id, side: 'black', message: 'x.ann does not fit a 9x9 board')
  [id, "error=#{side}", "message=#{message}", 'ok'].join("\t")
end

# A real Process::Status of a shell that exited with `code`, as WorkerPool
# reports a finished command.
def exit_status(code)
  system("exit #{code}")
  $?
end

# A real Process::Status of a shell killed by the signal `name` ('INT').
def signal_status(name)
  system("kill -#{name} $$")
  $?
end

# Stands in for WorkerPool: "runs" a job and hands the jobs back in the
# order they were queued. A GoGui game is "run" by calling the block, which
# writes its result file. An arena chunk (one with a schedule) is "run" by
# writing its stdout: `arena` gives each scheduled game's line from its ID
# and game (black wins by default; nil leaves the line out), then the
# trailer; `arena_output` may rewrite that whole text (nil writes no file),
# as an arena that died would leave it; `arena_stderr` is written to its
# stderr. `status` is every job's exit status, or a lambda giving it from
# the job's identifier; by default the job succeeded.
class FakePool
  attr_reader :commands, :identifiers

  def initialize(arena: ->(id, _game) { arena_played(id) }, arena_output: ->(text) { text }, arena_stderr: '',
                 duration: 1.5, status: exit_status(0), &run)
    @run = run
    @arena = arena
    @arena_output = arena_output
    @arena_stderr = arena_stderr
    @duration = duration
    @status = status
    @queued = []
    @commands = []
    @identifiers = []
  end

  def submit(command, identifier)
    @commands << command
    @identifiers << identifier
    @queued << identifier
  end

  # Every job "takes" 1.5 seconds unless told otherwise.
  def next_finished
    identifier = @queued.shift
    if identifier.respond_to?(:schedule)
      lines = identifier.games.filter_map { |id, game| @arena.call(id, game) }
      output = @arena_output.call((lines + ["done #{lines.size}"]).map { |l| "#{l}\n" }.join)
      File.write(identifier.out, output) if output
      File.write(identifier.err, @arena_stderr)
    else
      @run&.call(identifier)
    end
    [identifier, @duration, @status.respond_to?(:call) ? @status.call(identifier) : @status]
  end
end
