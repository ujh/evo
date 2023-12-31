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

    generation = start_generation
    loop do
      RunGeneration.call(generation.to_s, settings)
      generation += 1
    end
  end

  private

  attr_accessor :settings

  def start_generation
    generations = ["0"] + Dir["*"].find_all {|f| File.directory?(f)}
    generations.uniq.sort_by {|d| d.to_i }.last.to_i
  end
end
