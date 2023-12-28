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
    print "Analyzing games ... "
    stats = {
      "game_results" => [],
      "wins_per_player" => Hash.new {|h,k| h[k] = 0},
      "games_per_player" => Hash.new {|h,k| h[k] = 0}
    }
    Dir["*.dat"].each do |file_name|
      contents = File.read(file_name)
      next unless file_name =~ /(\d+)x(\d+)/
      black = "#$1.ann"
      white = "#$2.ann"
      result = File.readlines(file_name).last.split[3]
      winner = result.start_with?('B') ? black : white
      stats["game_results"] << {black: black, white: white, result: result, winner: winner}
      stats["wins_per_player"][winner] += 1
      stats["games_per_player"][black] += 1
      stats["games_per_player"][white] += 1
    end

    player, wins = stats["wins_per_player"].sort_by {|k,v| -v}.first
    games = stats["games_per_player"][player]
    percentage = (wins.to_f/games).round(2)
    stats["best_player"] = {player:, wins:, games:, percentage:}

    new_data = data.merge("stats" => stats)
    save_data(new_data)
    puts "\rBest player #{player} with #{percentage} wins"
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
    best_player = data["stats"]["best_player"]
    opponents = [
      {name: 'brown', command: 'brown'},
      {name: 'gnugoL0', command: 'gnugo --level 0 --mode gtp'}
    ]
    games = 100
    opponent_stats = []
    opponents.each do |opponent|
      print "Playing against #{opponent[:name]} ..."
      black = "../evo #{best_player["player"]}"
      white = opponent[:command]
      size = settings["board_size"]
      time = settings["game_length"]
      prefix = opponent[:name]
      cmd = %|gogui-twogtp -black "#{black}" -white "#{white}" -referee "gnugo --mode gtp" -size #{size} -auto -games #{games} -sgffile #{prefix} -time #{time} -alternate|
      system(cmd)
      wins = File.readlines("#{opponent[:name]}.dat").reject {|l| l.start_with?('#') }.map {|l| l.split[3]}.find_all {|r| r.start_with?('B') }.length
      opponent_stats << { opponent:, wins:, games: }
      puts " #{(wins.to_f/games).round(2)} wins"
      new_data = data.merge('opponent_stats' => opponent_stats)
      save_data(new_data)
    end
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
    previous_generation = generation.to_i - 1
    previous_data = JSON.load_file("../#{previous_generation}/data.json")
    # The more wins the more often in array to pick from
    picks = previous_data['stats']['wins_per_player'].flat_map {|k,v| [k]*v }
    # Generate the new population
    settings['population_size'].to_i.times do |i|
      `../evolve #{settings["cross_over_rate"]} ../#{previous_generation}/#{picks.sample} ../#{previous_generation}/#{picks.sample}`
      FileUtils.mv("child.ann", "#{i}.ann")
    end
    save_data(
      "games" => games_from_files,
      "completed_games" => [],
      "setup_complete" => true
    )
  end

  def games_from_files
    nns = Dir["*.ann"]
    nns.flat_map {|nb| nns.find_all {|nw| nw != nb }.map {|nw| {black: nb, white: nw} } }
  end
end
