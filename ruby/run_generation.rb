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
      next unless file_name =~ /(\d+)x(\d+)R(\d+)/
      black = "#$1.ann"
      white = "#$2.ann"
      # Exclude games against external engines
      break unless File.exist?(black)
      break unless File.exist?(white)

      data_row = File.readlines(file_name).last.split
      result = data_row[3]
      length = data_row[6].to_i
      winner = result.start_with?('B') ? black : white
      stats["game_results"] << {black:, white:, result:, winner:, length:}
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
    puts "\rBest player #{player} with #{percentage} wins (#{wins} wins in #{games} games)                "
  end

  def play_games
    return if data["round"] >= settings["tournament_rounds"].to_i

    loop do
      play_round
      setup_next_round

      break if data["round"] >= settings["tournament_rounds"].to_i
    end
  end

  def setup_next_round
    games = if data["round"].succ >= settings["tournament_rounds"].to_i
      []
    else
      games_from_ranking(data['ranking'])
    end

    new_data = data.merge(
      'round' => data['round'] + 1,
      'completed_games' => [],
      'games' => games
    )
    save_data(new_data)
  end

  def play_round
    puts "\rPlaying round #{data['round'] + 1} of #{settings['tournament_rounds']} ...              "
    total = data["games"].length + data["completed_games"].length

    loop do
      game = data["games"].first
      break unless game

      n = data["completed_games"].length + 1
      percentage = ((n.to_f/total)*100).round(2)
      print "\rPlaying game #{n} of #{total} [#{percentage}%] ..."

      result = play_game(game)
      new_ranking = data['ranking'].map do |s|
        if s['name'] == result['winner']
          s.merge('score' => s['score'] + 1)
        else
          s
        end
      end.sort_by {|s| -s['score'] }
      new_data = data.merge(
        "games" => data["games"][1..-1],
        "completed_games" => data["completed_games"] + [game.merge(result)],
        "ranking" => new_ranking
      )
      save_data(new_data)
    end
  end

  def play_game(game)
    # Odd number of players. Received a bye
    return { 'winner' => game['black']} unless game['white']

    black = data['players'][game["black"]]['command']
    white = data['players'][game["white"]]['command']
    size = settings["board_size"]
    maxmoves = settings["max_moves"]
    prefix = prefix_from(game)
    time = settings["game_length"]
    cmd = %|gogui-twogtp -black "#{black}" -white "#{white}" -referee "gnugo --mode gtp" -size #{size} -auto -games 1 -sgffile #{prefix} -time #{time} -force -maxmoves #{maxmoves}|
    system(cmd)
    result = File.readlines("#{prefix}.dat").last.split
    winner = result[3].start_with?('B') ? game['black'] : game['white']
    # game_length = result[]
    { 'winner' => winner }
  end

  def prefix_from(game)
    "#{File.basename(game["black"], ".*")}x#{File.basename(game["white"], ".*")}R#{data['round']}"
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
    save_data(setup_tournament)
  end

  def evolve_from_previous_population
    return if data["setup_complete"]

    puts "Generating population ..."
    previous_generation = generation.to_i - 1
    previous_data = JSON.load_file("../#{previous_generation}/data.json")
    # The more wins the more often in array to pick from
    # TODO: Check if that's even a correct way to calculate this with the new tournament style
    picks = previous_data['stats']['wins_per_player'].flat_map {|k,v| [k]*v }
    # Generate the new population
    settings['population_size'].to_i.times do |i|
      `../evolve #{settings["cross_over_rate"]} ../#{previous_generation}/#{picks.sample} ../#{previous_generation}/#{picks.sample}`
      FileUtils.mv("child.ann", "#{i}.ann")
    end
    save_data(setup_tournament)
  end

  EXTERNAL_PLAYERS = [
    {'name' => 'Brown', 'command' => 'brown'},
    {'name' => 'AmiGo', 'command' => 'amigogtp'},
    {'name' => 'GnuGoLevel0', 'command' => 'gnugo --level 0 --mode gtp'}
  ]

  def setup_tournament
    data = {
      'round' => 0,
      'players' => setup_players,
      'setup_complete' => true,
      'completed_games' => [],
    }
    data['ranking'] = data['players'].keys.map {|player| {'name' => player, 'score' => 0} }.shuffle
    data['games'] = games_from_ranking(data['ranking'])
    data
  end

  def games_from_ranking(ranking)
    games = []
    ranked_players = ranking.map {|r| r['name'] }
    loop do
      players = ranked_players.shift(2).shuffle
      break if players.empty?
      players << nil if players.length == 1
      games << {black: players.first, white: players.last}
    end
    games
  end

  def setup_players
    players = EXTERNAL_PLAYERS.each_with_object({}) {|player, hash| hash[player['name']] = {'command' => player['command'], 'external' => true} }
    players.merge!(Dir["*.ann"].each_with_object({}) {|player,hash | hash[player] = { 'command' => "../evo #{player}" } })
    players
  end
end
