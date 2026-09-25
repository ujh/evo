require 'json'

class RunExperiment
  def self.call(settings)
    new(settings).call
  end

  def initialize(settings)
    self.settings = settings
  end

  def call
    puts "*** Settings ***"
    puts JSON.pretty_generate(settings)

    pool = WorkerPool.new(settings['concurrency'].to_i)
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
    loop do
      r = RunGeneration.call(generation.to_s, settings, pool)
      generation += 1
      break if settings['one_generation'] && (r != :already_done)
    end
  ensure
    pool&.stop
  end

  private

  attr_accessor :settings

  def start_generation
    generations = ["0"] + Dir["*"].find_all {|f| File.directory?(f)}
    generations.uniq.sort_by {|d| d.to_i }.last.to_i
  end
end
