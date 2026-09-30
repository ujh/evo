require 'fileutils'
require 'json'

class RunExperiment
  def self.call(settings, store)
    new(settings, store).call
  end

  # `store` is the experiment's ExperimentDatabase, opened by SetupExperiment.
  def initialize(settings, store)
    self.settings = settings
    self.store = store
  end

  def call
    puts "*** Settings ***"
    puts JSON.pretty_generate(settings)

    pool = WorkerPool.new(settings['concurrency'])
    # Ctrl-C reaches the running games too, and they stop. The runner checks
    # the flag between games, and the pool starts no queued game after it.
    # The trap is installed here, after the settings prompts, so Ctrl-C at a
    # prompt still aborts.
    trap('SIGINT') do
      puts 'Stopping ...'
      $stop_now = true
      pool.halt
    end
    generation = start_generation
    catch_up_benchmarks(generation, pool)
    loop do
      r = RunGeneration.call(generation.to_s, settings, pool, store)
      generation += 1
      break if settings['one_generation'] && (r != :already_done)
    end
  rescue RunGeneration::Stopped => e
    # An arena stop sent the other chunks SIGTERM already; the ensure waits
    # for them.
    warn "\n#{e.message}"
    exit 1
  ensure
    pool&.stop
  end

  private

  attr_accessor :settings, :store

  # The checkpoints before `generation` play the benchmark games they lack,
  # as after benchmark_games or benchmark_bot_games was raised (migration
  # 017), in an emptied work/ as a generation's benchmark does. Their
  # champions are in the database. `generation` itself is the one the run
  # resumes with, and RunGeneration finishes its benchmark.
  def catch_up_benchmarks(generation, pool)
    every = settings['keep_every']
    return unless every.positive?

    checkpoints = (0...generation).step(every).to_a
    return if checkpoints.empty?

    FileUtils.rm_rf(RunGeneration::WORK)
    FileUtils.mkdir(RunGeneration::WORK)
    Dir.chdir(RunGeneration::WORK) do
      checkpoints.each do |checkpoint|
        CheckpointBenchmark.call(checkpoint, settings, pool, store, heading: "*** BENCHMARK OF GENERATION #{checkpoint} ***")
      end
    end
  end

  # Resume with the last generation the database knows about.
  def start_generation
    store.generations.last || 0
  end
end
