require 'fileutils'
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

  # Creates an experiment from key=value arguments, so it can be started
  # without the prompts (`mise run new-experiment NAME key=value ...`).
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

  def self.settings_from_arguments(arguments)
    given = arguments.to_h do |argument|
      key, value = argument.split('=', 2)
      raise ArgumentError, "expected key=value, got #{argument}" if value.nil?

      [key, value]
    end
    unknown = given.keys - SETTINGS.keys
    raise ArgumentError, "unknown settings: #{unknown.join(', ')}" if unknown.any?

    missing = SETTINGS.select { |key, (_, default)| default.nil? && !given.key?(key) }.keys
    raise ArgumentError, "missing settings: #{missing.join(', ')}" if missing.any?

    SETTINGS.to_h { |key, (_, default)| [key, given.fetch(key) { default_for(default) }] }
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
