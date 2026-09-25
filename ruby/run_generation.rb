require_relative 'game_result'

class RunGeneration
  def self.call(generation, settings, pool)
    new(generation, settings, pool).call
  end

  # `pool` is the WorkerPool that plays the games. It lives as long as the
  # experiment, so every generation shares the same threads.
  def initialize(generation, settings, pool)
    self.generation = generation
    self.settings = settings
    self.pool = pool
  end

  def call
    puts "\n*** GENERATION #{generation} [#{Time.now}] ***\n\n"
    setup do
      play_games
    end
  end

  private

  attr_accessor :generation, :settings, :pool

  def setup
    FileUtils.mkdir(generation) unless File.exist?(generation)
    Dir.chdir(generation) do
      if generation == '0'
        setup_initial_population
      else
        evolve_from_previous_population
      end
      yield
    end
  end

  def play_games
    return :already_done if data['round'] >= settings['tournament_rounds'].to_i

    loop do
      play_round
      setup_next_round

      break if data['round'] >= settings['tournament_rounds'].to_i
    end
    puts "\rPlaying ... done".ljust(70)
  end

  def setup_next_round
    games = if data['round'].succ >= settings['tournament_rounds'].to_i
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
    data['games'].each do |game|
      game_data = prepare_game(game)
      if game_data['winner']
        update_data(game, game_data)
        refresh_progress
      else
        pool.submit(game_data['command'], game_data['identifier'])
      end
    end

    until data['games'].empty?
      completed_game = pool.next_finished
      # Ctrl-C also stops the running games. Leave them unscored so that
      # resuming plays them again instead of counting a killed game.
      exit if $stop_now
      update_data(completed_game, score_game(completed_game))
      refresh_progress
    end
  end

  def update_data(game, result)
    winner = result['winner']
    points = result['points'] || 1
    # Update score
    new_ranking = data['ranking'].map do |s|
      if s['name'] == winner
        s.merge('score' => s['score'] + points)
      else
        s
      end
    end # .sort_by {|s| -s['score'] }
    # Group by same score
    new_ranking = new_ranking.group_by { |s| s['score'] }
    # Randomize within the same score and flatten again
    new_ranking = new_ranking.keys.sort.reverse.flat_map { |s| new_ranking[s].shuffle }
    new_data = data.merge(
      'games' => data['games'].reject { |g| g == game },
      'ranking' => new_ranking
    )
    if result['failure']
      warn "\n#{prefix_from(game)}: #{result['failure']}"
      new_data['unscored'] = data.fetch('unscored', []) + [game.merge('round' => data['round'], 'failure' => result['failure'])]
    end
    save_data(new_data)
  end

  def refresh_progress
    current_round = data['round'] + 1
    total_rounds = settings['tournament_rounds'].to_i
    total_games_in_round = (data['players'].length / 2.0).ceil
    current_game_in_round = total_games_in_round - data['games'].length
    overall_total = total_games_in_round * total_rounds
    overall_current_game = (total_games_in_round * data['round']) + current_game_in_round
    overall_percentage = (overall_current_game.to_f / overall_total * 100).round(2)

    print "\rPlaying ... Game: #{current_game_in_round}/#{total_games_in_round} Round: #{current_round}/#{total_rounds} Total: #{overall_current_game}/#{overall_total} [#{overall_percentage}%]".ljust(70)
  end

  def prepare_game(game)
    # Odd number of players. Received a bye
    return { 'winner' => game['black'], 'points' => 1 } unless game['white']

    black = data['players'][game['black']]['command']
    white = data['players'][game['white']]['command']
    size = settings['board_size']
    maxmoves = settings['max_moves']
    prefix = prefix_from(game)
    time = settings['game_length']
    cmd = %(gogui-twogtp -black "#{black}" -white "#{white}" -referee "gnugo --mode gtp" -size #{size} -auto -games 1 -sgffile #{prefix} -time #{time} -force -maxmoves #{maxmoves} 2> #{prefix}.err)

    { 'command' => cmd, 'identifier' => game }
  end

  def score_game(game)
    # Odd number of players. Received a bye
    return { 'winner' => game['black'] } unless game['white']

    result = GameResult.read(prefix_from(game))
    return { 'winner' => nil, 'failure' => result.failure } if result.failure
    return { 'winner' => nil } unless result.winner

    winner, loser = result.winner == :black ? [game['black'], game['white']] : [game['white'], game['black']]
    # A bot crashing says nothing about the network that played it.
    return { 'winner' => nil, 'failure' => "#{loser} crashed" } if result.crashed? && data['players'][loser]['external']

    { 'winner' => winner, 'points' => data['players'][loser]['points'] }
  end

  def prefix_from(game)
    "#{File.basename(game['black'], '.*')}x#{File.basename(game['white'], '.*')}R#{data['round']}"
  end

  def data
    return {} unless File.exist?('data.json')

    @data ||= JSON.load_file('data.json')
  end

  def save_data(hash)
    File.open('data.json', 'w') do |f|
      f.puts JSON.pretty_generate(hash)
    end
    @data = nil
    exit if $stop_now
  end

  def setup_initial_population
    return if data['setup_complete']

    puts 'Generating initial population ...'
    system("../initial-population #{settings['population_size']} #{settings['board_size']} #{settings['hidden_layers']} #{settings['layer_size']}")
    save_data(setup_tournament)
  end

  def evolve_from_previous_population
    return if data['setup_complete']

    previous_generation = generation.to_i - 1
    previous_data = JSON.load_file("../#{previous_generation}/data.json")
    candidates = parent_candidates(previous_data)
    # Generate the new population
    total = settings['population_size'].to_i
    total.times do |i|
      print "\rGenerating population ... #{i + 1}/#{total}"
      breed_child(previous_generation, candidates, "#{i}.ann")
    end
    puts "\rGenerating population ... done         "
    clean_up_generation(previous_generation)
    save_data(setup_tournament)
  end

  # Writes one child straight to `child`. A file left there by an interrupted
  # run is removed first, so a child exists only if this evolve wrote it. On
  # failure, breeding stops before the parents are deleted.
  def breed_child(previous_generation, candidates, child)
    FileUtils.rm_f(child)
    parents = Array.new(2) { "../#{previous_generation}/#{select_parent(candidates)}" }
    command = "../evolve #{settings['cross_over_rate']} #{parents.join(' ')} #{child}"
    return if system(command, out: File::NULL) && File.exist?(child)

    raise "evolve failed to breed #{child}: #{command}"
  end

  def parent_candidates(previous_data)
    previous_data['ranking'].reject { |player| previous_data['players'][player['name']]['external'] }
  end

  # Tournament selection: draw tournament_size candidates at random (with
  # replacement) and keep the one with the highest score. Only the order of
  # the scores matters, so one lucky high score cannot take over breeding,
  # and when every score is equal the pick is uniform. max_by keeps the first
  # of tied draws, which is a random one of the tied candidates.
  def select_parent(candidates)
    size = settings.fetch('tournament_size', '3').to_i
    raise ArgumentError, "tournament_size must be at least 1, got #{size}" if size < 1

    Array.new(size) { candidates.sample(random: rng) }.max_by { |c| c['score'] }['name']
  end

  def rng
    @rng ||= Random.new
  end

  def clean_up_generation(g)
    Dir.chdir("../#{g}") do
      # stdout, stderr, status = Open3.capture3('find . -name "*.ann" -print | tar cvfj anns.tar.bz2 -T -')
      # if status.success?
      FileUtils.rm(Dir['*.ann'])
      # else
      #   puts 'Failed to tar *.ann files'
      #   puts stdout
      #   puts stderr
      #   exit(1)
      # end
      FileUtils.rm(Dir['*.sgf'])
      # Keep twogtp stderr only where a program said something, such as a crash.
      FileUtils.rm(Dir['*.err'].select { |f| File.zero?(f) })
    end
  end

  AMIGO = { 'name' => 'AmiGo', 'command' => 'amigogtp', 'points' => 10 }
  BROWN = { 'name' => 'Brown', 'command' => 'brown', 'points' => 1 }
  GNUGO0 = { 'name' => 'GnuGoLevel0', 'command' => 'gnugo --level 0 --mode gtp', 'points' => 50 }
  GNUGO10 = { 'name' => 'GnuGoLevel10', 'command' => 'gnugo --level 10 --mode gtp', 'points' => 100 }
  # scripts/smoke-external-tools.sh plays each of these; add new opponents there too.
  EXTERNAL_PLAYERS = [
    *(1..5).map { |i| BROWN.merge('name' => BROWN['name'] + i.to_s) },
    *(1..10).map { |i| AMIGO.merge('name' => AMIGO['name'] + i.to_s) },
    *(1..2).map { |i| GNUGO0.merge('name' => GNUGO0['name'] + i.to_s) },
    *(1..2).map { |i| GNUGO10.merge('name' => GNUGO10['name'] + i.to_s) }
  ]

  def setup_tournament
    data = {
      'round' => 0,
      'players' => setup_players,
      'setup_complete' => true
    }
    data['ranking'] = data['players'].keys.map { |player| { 'name' => player, 'score' => 0 } }.shuffle
    data['games'] = games_from_ranking(data['ranking'])
    data
  end

  def games_from_ranking(ranking)
    games = []
    ranked_players = ranking.map { |r| r['name'] }
    loop do
      players = ranked_players.shift(2).shuffle
      break if players.empty?

      players << nil if players.length == 1
      games << { black: players.first, white: players.last }
    end
    games
  end

  def setup_players
    players = EXTERNAL_PLAYERS.each_with_object({}) do |player, hash|
      hash[player['name']] = { 'command' => player['command'], 'points' => player['points'], 'external' => true }
    end
    players.merge!(Dir['*.ann'].each_with_object({}) do |player, hash|
                     hash[player] = { 'command' => "../evo #{player}", 'points' => 1 }
                   end)
    players
  end
end
