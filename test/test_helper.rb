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
    'game_seconds' => 600,
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

  # Writes a generation's networks (name => bytes) into networks/N/ in
  # `experiment`, each with a birth whose genome is its SHA-256, as a saved
  # setup leaves them. The default, '..', is the experiment directory of
  # tests that run in the current directory as work/.
  def write_networks(generation, networks, experiment: '..', store: database)
    directory = File.join(experiment, 'networks', generation.to_s)
    FileUtils.mkdir_p(directory)
    networks.each do |name, bytes|
      File.binwrite(File.join(directory, name), bytes)
      store.record_birth(generation:, child: name, operator: 'initial', seed: 1, genome: Digest::SHA256.hexdigest(bytes))
    end
  end

  # The files in `directory` by name, with their contents; {} when it does
  # not exist.
  def files_in(directory)
    return {} unless Dir.exist?(directory)

    Dir.children(directory).sort.to_h { |name| [name, File.binread(File.join(directory, name))] }
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

# The arena's record for a game where a network cannot be loaded (side
# 'both': neither, which is a failure).
def arena_network_error(id, side: 'black', message: 'x.ann does not fit a 9x9 board')
  [id, 'end=network_error', "error=#{side}", "message=#{message}", 'ok'].join("\t")
end

# The arena's failure record for a game a bot could not finish.
def arena_failed(id, finish: 'timeout', side: 'white', moves: %w[D4 pass], time_black: 0.01, time_white: 10.2,
                 duration: 10.25, message: 'genmove: no answer to genmove within 10.000 s')
  times = [time_black, time_white, duration].map { |t| format('%.6f', t) }
  [id, "end=#{finish}", "error=#{side}", "length=#{moves.size}", "time_black=#{times[0]}", "time_white=#{times[1]}",
   "duration=#{times[2]}", "moves=#{moves.join(',')}", "message=#{message}", 'ok'].join("\t")
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
# order they were queued. A plain job (the benchmark's GoGui game, an
# evolve) is "run" by calling the block, which writes its result files, and
# comes back as [identifier, duration, status]. A streaming job (an arena
# chunk) comes back as `arena --mixed` would stream it, one event per
# next_finished: a WorkerPool::Line for each line of its stdout, then a
# WorkerPool::Exited. Its stdout is the header, then the record `arena`
# gives from each game's ID and game (black wins by default; nil leaves the
# record out), then the trailer, which counts the records; `arena_output`
# may rewrite that whole text (nil: no output), as an arena that died
# would leave it; `arena_stderr` is written to its stderr file when its
# first event comes. `status` is every job's exit status, or a lambda
# giving it from the job's identifier; by default the job succeeded. With
# a `clock` (a FakeClock), a job's end advances it by the job's duration.
# `terminate` stands in for WorkerPool#terminate: the jobs not yet ended
# count as running and never come back; `on_terminate` runs first.
# `reverse` hands the jobs back last queued first, as a pool whose later
# jobs finish sooner would; `interleave` hands back one event of each
# running job in turn, as parallel arenas would stream them. `on_event` is
# called with each event before it is handed back.
class FakePool
  attr_reader :commands, :identifiers, :terminated

  def initialize(arena: ->(id, _game) { arena_played(id) }, arena_output: ->(text) { text }, arena_stderr: '',
                 duration: 1.5, status: exit_status(0), clock: nil, on_terminate: nil, reverse: false,
                 interleave: false, on_event: nil, concurrency: nil, &run)
    @run = run
    @concurrency = concurrency
    @reverse = reverse
    @interleave = interleave
    @on_event = on_event
    @on_terminate = on_terminate
    @terminated = []
    @clock = clock
    @arena = arena
    @arena_output = arena_output
    @arena_stderr = arena_stderr
    @duration = duration
    @status = status
    @queued = []
    @events = {}.compare_by_identity
    @commands = []
    @identifiers = []
  end

  def submit(command, identifier)
    @commands << command
    @identifiers << identifier
    @queued << identifier
  end

  def submit_streaming(command, identifier)
    submit(command, identifier)
    @events[identifier] = nil
  end

  # Stops every queued job and returns how many ran: the first
  # `concurrency` of them (all when not given), as the real pool signals
  # only its running jobs.
  def terminate
    @on_terminate&.call
    running = @concurrency ? [@concurrency, @queued.size].min : @queued.size
    @terminated.concat(@queued)
    @queued.clear
    running
  end

  # Every job "takes" 1.5 seconds unless told otherwise.
  def next_finished
    identifier = @reverse ? @queued.last : @queued.first
    event = @events.key?(identifier) ? next_event(identifier) : run(identifier)
    @on_event&.call(event)
    event
  end

  private

  def run(identifier)
    @queued.delete_at(@reverse ? -1 : 0)
    @run&.call(identifier)
    @clock&.advance(@duration)
    [identifier, @duration, status_of(identifier)]
  end

  def next_event(identifier)
    events = (@events[identifier] ||= arena_events(identifier))
    event = events.shift
    if events.empty?
      @queued.delete(identifier)
      @clock&.advance(@duration)
    elsif @interleave
      @queued.push(@queued.delete(identifier))
    end
    event
  end

  def arena_events(chunk)
    records = chunk.games.filter_map { |id, game| @arena.call(id, game) }
    output = @arena_output.call(([ArenaResult::HEADER] + records + ["done #{records.size}"]).map { |l| "#{l}\n" }.join)
    File.write(chunk.err, @arena_stderr)
    lines = output.to_s.b.split("\n", -1)
    lines.pop if lines.last == ''
    lines.map { |line| WorkerPool::Line.new(chunk, line.force_encoding(Encoding::UTF_8).scrub) } +
      [WorkerPool::Exited.new(chunk, @duration, status_of(chunk))]
  end

  def status_of(identifier)
    @status.respond_to?(:call) ? @status.call(identifier) : @status
  end
end

# A FakePool that "runs" each evolve job (a RunGeneration::EvolveJob) by
# calling the block with the job's evolve command, as the shell would run
# it, and writing what the block returns: [success, stdout, status,
# stderr], where status defaults to exit 0 or 1 by success and stderr to
# nothing. The pool's options are FakePool's.
def evolve_pool(**options, &evolve)
  statuses = {}.compare_by_identity
  FakePool.new(status: ->(job) { statuses.fetch(job) }, **options) do |job|
    success, stdout, status, stderr = evolve.call(job.command)
    File.write(job.out, stdout)
    File.write(job.err, stderr || '')
    statuses[job] = status || exit_status(success ? 0 : 1)
  end
end

# Stands in for AwakeClock, the clock of GenerationTimings: time moves only
# when a test advances it.
class FakeClock
  def initialize
    @now = 0.0
  end

  def call = @now

  def advance(seconds)
    @now += seconds
  end
end
