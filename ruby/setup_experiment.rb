require 'fileutils'
require 'json'
require_relative 'experiment_database'
require_relative 'seeds'

class SetupExperiment
  DATABASE = 'experiment.sqlite3'.freeze

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

  def self.setup_directory(experiment_dir)
    FileUtils.mkdir_p(experiment_dir)
    executables = ["engine/evo", "initial-population/initial-population", "evolve/evolve"].map {|e| File.expand_path(e)}
    FileUtils.ln_s(executables, experiment_dir, force: true)
  end

  # The settings live in the database. A settings.json in the experiment
  # directory is imported once and removed, so an experiment can still be
  # started without the prompts.
  def self.settings(database)
    settings = database.settings
    if settings.empty? && File.exist?("settings.json")
      settings = JSON.load_file("settings.json").transform_values(&:to_s)
      File.delete("settings.json")
    elsif settings.empty?
      settings = prompt_for_settings
    end
    # Every seed in the experiment derives from this one, so it is saved.
    settings["seed"] ||= Seeds.new_experiment_seed.to_s
    database.save_settings(settings)
    settings
  end

  def self.prompt_for_settings
    settings = {}
    print "Board Size: "
    settings["board_size"] = STDIN.gets.chomp
    print "Population Size: "
    settings["population_size"] = STDIN.gets.chomp
    print "Number of hidden layers: "
    settings["hidden_layers"] = STDIN.gets.chomp
    print "Number of neurons per layer: "
    settings["layer_size"] = STDIN.gets.chomp
    print "Cross over rate: "
    settings["cross_over_rate"] = STDIN.gets.chomp
    print "Game length (time): "
    settings["game_length"] = STDIN.gets.chomp
    print "Max moves: "
    settings["max_moves"] = STDIN.gets.chomp
    print "Rounds (tournament): "
    settings["tournament_rounds"] = STDIN.gets.chomp
    print "Tournament size for parent selection (default 3): "
    tournament_size = STDIN.gets.chomp
    settings["tournament_size"] = tournament_size.empty? ? "3" : tournament_size
    print "Keep the SGF of every game in every Nth generation (default 10, 0 for never): "
    sgf_every = STDIN.gets.chomp
    settings["sgf_every"] = sgf_every.empty? ? "10" : sgf_every
    print "Seed (default random): "
    seed = STDIN.gets.chomp
    settings["seed"] = seed.empty? ? Seeds.new_experiment_seed.to_s : seed
    settings
  end
end
