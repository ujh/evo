require 'optparse'

# The runner's command line: `./runner NAME [--concurrency N]
# [--one-generation | --until-generation G]`. Options may come before or
# after the name.
class RunnerOptions
  Refused = Class.new(StandardError)

  USAGE = 'Usage: mise run run NAME [--concurrency N] [--one-generation | --until-generation G]'.freeze

  attr_reader :name, :concurrency, :one_generation, :until_generation

  def self.parse(args)
    new(args)
  end

  def initialize(args)
    @concurrency = 2
    @one_generation = false
    @until_generation = nil
    rest = parser.parse(args)
    raise Refused, "Name of experiment required as argument!\n#{USAGE}" if rest.empty?
    raise Refused, "One experiment name expected, got #{rest.join(' ')}\n#{USAGE}" if rest.size > 1
    if one_generation && until_generation
      raise Refused, "Give either --one-generation or --until-generation, not both.\n#{USAGE}"
    end

    @name = rest.first
  rescue OptionParser::ParseError => e
    raise Refused, "#{e.message}\n#{USAGE}"
  end

  # The experiment's settings with this run's options, as RunExperiment
  # reads them.
  def run_settings(settings)
    settings.merge('concurrency' => concurrency, 'one_generation' => one_generation,
                   'until_generation' => until_generation)
  end

  private

  def parser
    OptionParser.new do |opts|
      opts.banner = USAGE
      opts.on('--concurrency N', 'Games and breeding jobs at once (default 2)') do |value|
        @concurrency = whole_number(value, '--concurrency', 1)
      end
      opts.on('--one-generation', 'Stop after one generation that does work') { @one_generation = true }
      opts.on('--until-generation G', 'Stop after generation G is finished, its benchmark included') do |value|
        @until_generation = whole_number(value, '--until-generation', 0)
      end
    end
  end

  def whole_number(value, option, minimum)
    number = Integer(value, 10, exception: false)
    return number if number && number >= minimum

    raise Refused, "#{option} must be a whole number of at least #{minimum}, got #{value}\n#{USAGE}"
  end
end
