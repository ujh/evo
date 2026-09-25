require 'fileutils'
require 'json'
require_relative 'seeds'

class SetupExperiment
  def self.call(experiment_dir)
    puts "Setting up ... ✔"
    setup_directory(experiment_dir)
    Dir.chdir(experiment_dir) do
      yield settings
    end
  end

  def self.setup_directory(experiment_dir)
    FileUtils.mkdir_p(experiment_dir)
    executables = ["engine/evo", "initial-population/initial-population", "evolve/evolve"].map {|e| File.expand_path(e)}
    FileUtils.ln_s(executables, experiment_dir, force: true)
  end

  def self.settings
    if File.exist?("settings.json")
      settings = JSON.load_file("settings.json")
      # Every seed in the experiment derives from this one, so it is saved.
      unless settings["seed"]
        settings["seed"] = Seeds.new_experiment_seed.to_s
        File.write("settings.json", JSON.pretty_generate(settings))
      end
      settings
    else
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
      File.open("settings.json", "w") do |f|
        f.puts JSON.pretty_generate(settings)
      end
      settings
    end
  end
end
