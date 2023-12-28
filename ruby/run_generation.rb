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
      analyze_games
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

  def analyze_games
    return if data["stats"]

    print "Analyzing games ..."
    sleep(5)
    print "\n"
    exit
  end

  def play_games
    find_missing_games
    return if data["games"].empty?

    total = data["games"].length + data["completed_games"].length

    while data["games"].length > 0
      n = data["completed_games"].length + 1
      print "\rPlaying game #{n} of #{total} ..."
      game = data["games"].first
      play_game(game)
      new_data = data.merge(
        "games" => data["games"][1..-1],
        "completed_games" => data["completed_games"] + [game]
      )
      save_data(new_data)
    end
    print "\n"
  end

  def find_missing_games
    missing = data["completed_games"].find_all do |g|
      !File.exist?("#{File.basename(g["black"], ".*")}x#{File.basename(g["white"], ".*")}.dat")
    end
    new_data = data.merge(
      "games" => data["games"] + missing,
      "completed_games" => data["completed_games"].find_all {|g| !missing.include?(g)}
    )
    save_data(new_data)
  end

  def play_game(game)
    black = "../evo #{game["black"]}"
    white = "../evo #{game["white"]}"
    size = settings["board_size"]
    prefix = "#{File.basename(game["black"], ".*")}x#{File.basename(game["white"], ".*")}"
    time = settings["game_length"]
    cmd = %|gogui-twogtp -black "#{black}" -white "#{white}" -referee "gnugo --mode gtp" -size #{size} -auto -games 1 -sgffile #{prefix} -time #{time} -force|
    system(cmd)
  end

  def play_external_bots
    puts "Playing external bots ..."
    sleep(5)
  end

  def data
    return {} unless File.exist?("data.json")

    @data ||=JSON.load_file("data.json")
  end

  def save_data(hash)
    File.open("data.json", "w") do |f|
      f.puts JSON.pretty_generate(hash)
    end
    @data = nil
    exit if $stop_now
  end

  def setup_initial_population
    return if data["setup_complete"]

    puts "Generating initial population ..."
    system("../initial-population #{settings['population_size']} #{settings['board_size']} #{settings['hidden_layers']} #{settings['layer_size']}")
    save_data(
      "games" => games_from_files,
      "completed_games" => [],
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
