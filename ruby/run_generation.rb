class RunGeneration
  def self.call(generation, settings)
    new(generation, settings).call
  end

  def initialize(generation, settings)
    self.generation = generation
    self.settings = settings
    self.pipe = initialize_pipe
    self.ractors = initialize_ractors

    trap "SIGINT" do
      puts "Stopping ..."
      stop_ractors
      $stop_now = true
    end
  end

  def call
    puts "\n*** GENERATION #{generation} [#{Time.now}] ***\n\n"
    setup do
      play_games
    end
  end

  private

  attr_accessor :generation, :settings, :ractors, :pipe

  def stop_ractors
    ractors.each {|r| r.send(:stop)}
    pipe.send(:stop)
  end

  def initialize_ractors
    settings['concurrency'].to_i.times.map do
      Ractor.new(pipe) do |pipe|
        while msg = pipe.take
          if msg == :stop
            puts "[#{Ractor.current}]\tStopping"
            break
          end

          system(msg['command'])
          Ractor.yield msg['identifier']
        end
      end
    end
  end

  def initialize_pipe
    Ractor.new do
      loop do
        msg = receive
        if msg == :stop
          puts "[#{Ractor.current}]\tStopping"
          break
        end

        Ractor.yield msg
      end
    end
  end

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
    return :already_done if data["round"] >= settings["tournament_rounds"].to_i

    loop do
      play_round
      setup_next_round

      break if data["round"] >= settings["tournament_rounds"].to_i
    end
    puts "\rPlaying ... done".ljust(70)
  end

  def setup_next_round
    games = if data["round"].succ >= settings["tournament_rounds"].to_i
      []
    else
      games_from_ranking(data['ranking'])
    end

    new_data = data.merge(
      'round' => data['round'] + 1,
      'games' => games
    )
    save_data(new_data)
  end

  def play_round
    # Put all games into the pipe
    data['games'].each do |game|
      game_data = prepare_game(game)
      if game_data['winner']
        update_data(game, game_data['winner'])
        refresh_progress
      else
        pipe << game_data
      end
    end

    loop do
      break if data["games"].empty?

      _r, completed_game = Ractor.select(*ractors)
      result = score_game(completed_game)
      update_data(completed_game, result['winner'])
      refresh_progress
    end
  end

  def update_data(game, winner)
    # Update score
    new_ranking = data['ranking'].map do |s|
      if s['name'] == winner
        s.merge('score' => s['score'] + 1)
      else
        s
      end
    end #.sort_by {|s| -s['score'] }
    # Group by same score
    new_ranking = new_ranking.group_by {|s| s['score'] }
    # Randomize within the same score and flatten again
    new_ranking = new_ranking.keys.sort.reverse.flat_map {|s| new_ranking[s].shuffle }
    new_data = data.merge(
      "games" => data["games"].reject {|g| g == game},
      "ranking" => new_ranking
    )
    save_data(new_data)
  end

  def refresh_progress
    current_round = data['round'] + 1
    total_rounds = settings['tournament_rounds'].to_i
    total_games_in_round = (data['players'].length/2.0).ceil
    current_game_in_round = total_games_in_round - data['games'].length
    overall_total = total_games_in_round * total_rounds
    overall_current_game = (total_games_in_round * data['round']) + current_game_in_round
    overall_percentage = (overall_current_game.to_f/overall_total*100).round(2)

    print "\rPlaying ... Game: #{current_game_in_round}/#{total_games_in_round} Round: #{current_round}/#{total_rounds} Total: #{overall_current_game}/#{overall_total} [#{overall_percentage}%]".ljust(70)
  end

  def prepare_game(game)
    # Odd number of players. Received a bye
    return { 'winner' => game['black']} unless game['white']

    black = data['players'][game["black"]]['command']
    white = data['players'][game["white"]]['command']
    size = settings["board_size"]
    maxmoves = settings["max_moves"]
    prefix = prefix_from(game)
    time = settings["game_length"]
    cmd = %|gogui-twogtp -black "#{black}" -white "#{white}" -referee "gnugo --mode gtp" -size #{size} -auto -games 1 -sgffile #{prefix} -time #{time} -force -maxmoves #{maxmoves}|

    {'command' => cmd, 'identifier' => game}
  end

  def score_game(game)
    # Odd number of players. Received a bye
    return { 'winner' => game['black']} unless game['white']

    prefix = prefix_from(game)
    result = File.readlines("#{prefix}.dat").last.split
    winner = result[3].start_with?('B') ? game['black'] : game['white']
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
      # Make better score _much_ more likely to be picked.
      [player_name] * (player['score']**3)
    end.compact
    # Generate the new population
    total = settings['population_size'].to_i
    total.times do |i|
      print "\rGenerating population ... #{i+1}/#{total}"
      `../evolve #{settings["cross_over_rate"]} ../#{previous_generation}/#{picks.sample} ../#{previous_generation}/#{picks.sample}`
      FileUtils.mv("child.ann", "#{i}.ann")
    end
    puts "\rGenerating population ... done         "
    clean_up_generation(previous_generation)
    save_data(setup_tournament)
  end

  def clean_up_generation(g)
    Dir.chdir("../#{g}") do
      previous_data = JSON.load_file("data.json")
      best_player = previous_data["ranking"].find {|player| !previous_data["players"][player["name"]]["external"]}
      best_player_name = best_player["name"]
      FileUtils.rm(Dir["*.ann"].reject {|nn| nn == best_player_name })
      FileUtils.rm(Dir["*.sgf"])
    end
  end

  EXTERNAL_PLAYERS = [
    {'name' => 'Brown', 'command' => 'brown'},
    {'name' => 'AmiGo', 'command' => 'amigogtp'},
    {'name' => 'GnuGoLevel0', 'command' => 'gnugo --level 0 --mode gtp'},
    {'name' => 'GnuGoLevel10', 'command' => 'gnugo --level 10 --mode gtp'},
  ]

  def setup_tournament
    data = {
      'round' => 0,
      'players' => setup_players,
      'setup_complete' => true
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
