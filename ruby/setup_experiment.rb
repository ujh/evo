require 'fileutils'
require 'optparse'
require_relative 'experiment_database'
require_relative 'seeds'

class SetupExperiment
  DATABASE = 'experiment.sqlite3'.freeze

  # Every setting, with its prompt and its default. nil means required; a
  # Proc is called for a fresh default.
  SETTINGS = {
    'board_size' => ['Board size', nil],
    'population_size' => ['Population size', nil],
    'hidden_layers' => ['Number of hidden layers', nil],
    'layer_size' => ['Number of neurons per layer', nil],
    'cross_over_rate' => ['Cross over rate', nil],
    'game_length' => ['Game length (time)', nil],
    'max_moves' => ['Max moves', nil],
    'tournament_rounds' => ['Rounds (tournament)', nil],
    'tournament_size' => ['Tournament size for parent selection', '3'],
    'sgf_every' => ['Keep the SGF of every game in every Nth generation (0 for never)', '10'],
    'seed' => ['Seed', -> { Seeds.new_experiment_seed.to_s }]
  }.freeze

  # Opens the experiment's database and yields its settings and the database.
  def self.call(experiment_dir)
    puts "Setting up ... ✔"
    setup_directory(experiment_dir)
    Dir.chdir(experiment_dir) do
      database = ExperimentDatabase.new(File.expand_path(DATABASE))
      yield settings(database), database
    ensure
      database&.close
    end
  end

  # Creates an experiment from command-line options, so it can be started
  # without the prompts (`mise run new-experiment NAME --board-size 9 ...`).
  def self.create(experiment_dir, arguments)
    settings = settings_from_arguments(arguments)
    FileUtils.mkdir_p(experiment_dir)
    database = ExperimentDatabase.new(File.join(experiment_dir, DATABASE))
    raise ArgumentError, "#{experiment_dir} already has settings" unless database.settings.empty?

    database.save_settings(settings)
    settings
  ensure
    database&.close
  end

  # One --option per setting (board_size becomes --board-size), filling
  # `given` as it parses.
  def self.option_parser(given)
    OptionParser.new do |parser|
      parser.banner = 'Usage: mise run new-experiment NAME [options]'
      # Without this, OptionParser takes --board for --board-size.
      parser.require_exact = true
      SETTINGS.each do |key, (prompt, default)|
        note = if default.nil? then 'required'
               elsif default.respond_to?(:call) then 'default random'
               else "default #{default}"
               end
        parser.on("--#{key.tr('_', '-')} VALUE", "#{prompt} (#{note})") { |value| given[key] = value }
      end
    end
  end

  def self.settings_from_arguments(arguments)
    given = {}
    rest = option_parser(given).parse(arguments)
    raise ArgumentError, "unexpected arguments: #{rest.join(' ')}" if rest.any?

    missing = SETTINGS.select { |key, (_, default)| default.nil? && !given.key?(key) }.keys
    raise ArgumentError, "missing options: #{missing.map { |key| "--#{key.tr('_', '-')}" }.join(', ')}" if missing.any?

    SETTINGS.to_h { |key, (_, default)| [key, given.fetch(key) { default_for(default) }] }
  rescue OptionParser::ParseError => e
    raise ArgumentError, e.message
  end

  def self.default_for(default)
    default.respond_to?(:call) ? default.call : default
  end

  def self.setup_directory(experiment_dir)
    FileUtils.mkdir_p(experiment_dir)
    executables = ["engine/evo", "initial-population/initial-population", "evolve/evolve"].map {|e| File.expand_path(e)}
    FileUtils.ln_s(executables, experiment_dir, force: true)
  end

  # The settings live in the database; a new experiment prompts for them.
  def self.settings(database)
    settings = database.settings
    if settings.empty?
      settings = prompt_for_settings
      database.save_settings(settings)
    end
    settings
  end

  def self.prompt_for_settings
    SETTINGS.to_h do |key, (prompt, default)|
      label = default.nil? ? prompt : "#{prompt} (default #{default.respond_to?(:call) ? 'random' : default})"
      print "#{label}: "
      answer = $stdin.gets.to_s.chomp
      [key, answer.empty? && !default.nil? ? default_for(default) : answer]
    end
  end
end
