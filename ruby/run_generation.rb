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
    return if data["round"] >= settings["tournament_rounds"].to_i

    loop do
      play_round
      setup_next_round

      break if data["round"] >= settings["tournament_rounds"].to_i
    end
    puts "\rPlaying ... done".ljust(60)
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
    current_round = data['round'] + 1
    total_rounds = settings['tournament_rounds'].to_i
    total_games = data["games"].length + data["completed_games"].length
    overall_total = total_games * total_rounds

    loop do
      game = data["games"].first
      break unless game

      current_game = data["completed_games"].length + 1
      overall_current_game = (total_games * data['round']) + current_game
      overall_percentage = (overall_current_game.to_f/overall_total*100).round(2)
      print "\rPlaying ... Game: #{current_game}/#{total_games} Round: #{current_round}/#{total_rounds} Total: #{overall_current_game}/#{overall_total} [#{overall_percentage}%]"

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

    previous_generation = generation.to_i - 1
    previous_data = JSON.load_file("../#{previous_generation}/data.json")
    # Use the score to determine how "good" the individual is
    picks = previous_data['ranking'].reject do |player|
      previous_data['players'][player['name']]['external']
    end.flat_map do |player|
      player_name = player['name']
      [player_name] * player['score']
    end.compact
    # Generate the new population
    total = settings['population_size'].to_i
    total.times do |i|
      print "\rGenerating population ... #{i+1}/#{total}"
      `../evolve #{settings["cross_over_rate"]} ../#{previous_generation}/#{picks.sample} ../#{previous_generation}/#{picks.sample}`
      FileUtils.mv("child.ann", "#{i}.ann")
    end
    puts "\rGenerating population ... done         "
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
