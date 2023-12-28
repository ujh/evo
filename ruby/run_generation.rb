class RunGeneration
  def self.call(generation, settings)
    new(generation, settings).call
  end

  def initialize(generation, settings)
    self.generation = generation
    self.settings = settings
  end

  def call
    puts "\n*** GENERATION #{generation} ***\n\n"
    setup do
      play_games
      play_external_bots
    end
  end

  private

  attr_accessor :generation, :settings

  def setup
    FileUtils.mkdir(generation) unless File.exist?(generation)
    Dir.chdir(generation) do
      if generation == "0"
        setup_initial_population
      else
        evolve_from_previous_population
      end
      yield
    end
  end

  def play_games
    puts "Playing games ..."
    puts data["games"].length
    sleep(5)
  end

  def play_external_bots
    puts "Playing external bots ..."
    sleep(5)
  end

  def data
    return JSON.load_file("data.json") if File.exist?("data.json")

    {}
  end

  def save_data(hash)
    File.open("data.json", "w") do |f|
      f.puts JSON.pretty_generate(hash)
    end
  end

  def setup_initial_population
    return if data["setup_complete"]

    puts "Generating initial population ..."
    system("../initial-population #{settings['population_size']} #{settings['board_size']} #{settings['hidden_layers']} #{settings['layer_size']}")
    save_data(
      "games" => games_from_files,
      "setup_complete" => true
    )
  end

  def evolve_from_previous_population
    return if data["setup_complete"]

    puts "Generating population ..."
  end

  def games_from_files
    nns = Dir["*.ann"]
    nns.flat_map {|nb| nns.find_all {|nw| nw != nb }.map {|nw| {black: nb, white: nw} } }
  end
end
