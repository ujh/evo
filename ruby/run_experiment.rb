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
