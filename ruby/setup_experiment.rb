require 'json'

class SetupExperiment
  def self.call
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
      print "Game length: "
      settings["game_length"] = STDIN.gets.chomp
      File.open("settings.json", "w") do |f|
        f.puts JSON.pretty_generate(settings)
      end
      settings
    end
  end
end
