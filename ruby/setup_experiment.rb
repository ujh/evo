require 'fileutils'
require 'json'

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
      JSON.load_file("settings.json")
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
      File.open("settings.json", "w") do |f|
        f.puts JSON.pretty_generate(settings)
      end
      settings
    end
  end
end
