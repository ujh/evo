require 'digest'
require 'open3'
require_relative 'game_result'
require_relative 'seeds'

class RunGeneration
  def self.call(generation, settings, pool, store)
    new(generation, settings, pool, store).call
  end

  # `pool` is the WorkerPool that plays the games and `store` the ExperimentDatabase
  # that keeps their results. Both live as long as the experiment.
  def initialize(generation, settings, pool, store)
    self.generation = generation
    self.settings = settings
    self.pool = pool
    self.store = store
  end

  def call
    puts "\n*** GENERATION #{generation} [#{Time.now}] ***\n\n"
    setup do
      play_games
    end
  end

  private

  attr_accessor :generation, :settings, :pool, :store

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
    round = data['round'] + 1
    ranking = shuffle_ties(data['ranking'], round)
    games = if round >= settings['tournament_rounds'].to_i
              []
            else
              games_from_ranking(ranking, colors_rng(round))
            end

    save_data(data.merge('round' => round, 'games' => games, 'ranking' => ranking))
  end

  # Orders tied players with a generator seeded for this round, so the same
  # scores always give the same pairings.
  def shuffle_ties(ranking, round)
    random = Random.new(Seeds.derive(experiment_seed, 'ranking', generation.to_i, round))
    ranking.sort_by { |s| s['name'] }
           .group_by { |s| s['score'] }
           .sort_by { |score, _| -score }
           .flat_map { |_, tied| tied.shuffle(random:) }
  end

  def colors_rng(round)
    Random.new(Seeds.derive(experiment_seed, 'colors', generation.to_i, round))
  end

  def experiment_seed
    settings.fetch('seed')
  end

  def play_round
    data['games'].each do |game|
      if game['white'].nil?
        # The odd player out sits the round out and gets nothing for it.
        update_data(game, { 'winner' => nil })
        refresh_progress
      else
        game_data = prepare_game(game)
        pool.submit(game_data['command'], game_data['identifier'])
      end
    end

    until data['games'].empty?
      completed_game = pool.next_finished
      # Ctrl-C also stops the running games. Leave them unscored so that
      # resuming plays them again instead of counting a killed game.
      exit if $stop_now
      scored = score_game(completed_game)
      store_game(completed_game, scored)
      update_data(completed_game, scored)
      refresh_progress
    end
  end

  def update_data(game, result)
    winner = result['winner']
    # Every win is worth one point, against a network or a bot alike.
    new_ranking = data['ranking'].map do |s|
      if s['name'] == winner
        s.merge('score' => s['score'] + 1)
      else
        s
      end
    end
    # A stable order while the round is played; ties are shuffled once per
    # round in setup_next_round, so the order games finish in does not matter.
    new_ranking = new_ranking.sort_by { |s| [-s['score'], s['name']] }
    new_data = data.merge(
      'games' => data['games'].reject { |g| g == game },
      'ranking' => new_ranking
    )
    # The failure itself is in the game's row in the database.
    warn "\n#{prefix_from(game)}: #{result['failure']}" if result['failure']
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
    # GNU Go, as a player and as the referee, picks moves at random unless it
    # gets a seed; one per game makes every game repeatable.
    seed = Seeds.gnugo(experiment_seed, 'game', generation.to_i, data['round'], game['black'], game['white'])
    black = with_gnugo_seed(data['players'][game['black']]['command'], seed)
    white = with_gnugo_seed(data['players'][game['white']]['command'], seed)
    size = settings['board_size']
    maxmoves = settings['max_moves']
    prefix = prefix_from(game)
    time = settings['game_length']
    cmd = %(gogui-twogtp -black "#{black}" -white "#{white}" -referee "gnugo --mode gtp --seed #{seed}" -size #{size} -auto -games 1 -sgffile #{prefix} -time #{time} -force -maxmoves #{maxmoves} 2> #{prefix}.err)

    { 'command' => cmd, 'identifier' => game }
  end

  def with_gnugo_seed(command, seed)
    command.start_with?('gnugo ') ? "#{command} --seed #{seed}" : command
  end

  def score_game(game)
    result = GameResult.read(prefix_from(game))
    return { 'winner' => nil, 'failure' => result.failure } if result.failure
    return { 'winner' => nil } unless result.winner

    winner, loser = result.winner == :black ? [game['black'], game['white']] : [game['white'], game['black']]
    # A bot crashing says nothing about the network that played it.
    return { 'winner' => nil, 'failure' => "#{loser} crashed" } if result.crashed? && data['players'][loser]['external']

    { 'winner' => winner }
  end

  # Writes the game to the experiment database, then deletes the files gogui-twogtp
  # left, so an experiment does not pile up three files per game. The SGF is
  # kept for every sgf_every-th generation only. A crash between the two
  # steps replays the game, and its row is replaced.
  def store_game(game, scored)
    prefix = prefix_from(game)
    result = GameResult.read(prefix)
    sgf_file = "#{prefix}-0.sgf"
    err_file = "#{prefix}.err"
    store.record(
      generation: generation.to_i, round: data['round'], black: game['black'], white: game['white'],
      black_external: external?(game['black']), white_external: external?(game['white']),
      winner: scored['winner'], failure: scored['failure'], length: result.length,
      referee_result: result.referee, error_message: result.error_message,
      stderr: File.exist?(err_file) ? File.read(err_file) : nil,
      sgf: keep_sgf? && File.exist?(sgf_file) ? File.read(sgf_file) : nil
    )
    FileUtils.rm_f(["#{prefix}.dat", sgf_file, err_file])
  end

  def keep_sgf?
    every = settings.fetch('sgf_every', '10').to_i
    every.positive? && (generation.to_i % every).zero?
  end

  def external?(player)
    data['players'].fetch(player, {})['external'] ? true : false
  end

  def prefix_from(game)
    "#{File.basename(game['black'], '.*')}x#{File.basename(game['white'], '.*')}R#{data['round']}"
  end

  # The generation's tournament state, from the experiment database; {} before
  # the generation starts.
  def data
    @data ||= store.state(generation.to_i) || {}
  end

  # Replaces the state in one transaction, so a crash leaves the old state or
  # the new one, never half of it.
  def save_data(hash)
    store.save_state(generation.to_i, hash)
    @data = nil
    exit if $stop_now
  end

  def setup_initial_population
    return if data['setup_complete']

    puts 'Generating initial population ...'
    seed = Seeds.derive(experiment_seed, 'initial-population')
    system("../initial-population #{settings['population_size']} #{settings['board_size']} #{settings['hidden_layers']} #{settings['layer_size']} #{seed}")
    Dir['*.ann'].sort.each do |network|
      store.record_birth(generation: 0, child: network, first_parent: nil, second_parent: nil, operator: 'initial',
                         differs_from_first: nil, differs_from_second: nil, seed:,
                         genome: Digest::SHA256.file(network).hexdigest)
    end
    save_data(setup_tournament)
  end

  def evolve_from_previous_population
    return if data['setup_complete']

    previous_generation = generation.to_i - 1
    previous_data = store.state(previous_generation)
    candidates = parent_candidates(previous_data)
    # Generate the new population
    total = settings['population_size'].to_i
    total.times do |i|
      print "\rGenerating population ... #{i + 1}/#{total}"
      breed_child(previous_generation, candidates, i)
    end
    puts "\rGenerating population ... done         "
    clean_up_generation(previous_generation)
    save_data(setup_tournament)
  end

  # Writes one child straight to `child`. A file left there by an interrupted
  # run is removed first, so a child exists only if this evolve wrote it. On
  # failure, breeding stops before the parents are deleted.
  def breed_child(previous_generation, candidates, index)
    child = "#{index}.ann"
    FileUtils.rm_f(child)
    parents = Array.new(2) { select_parent(candidates) }
    seed = Seeds.derive(experiment_seed, 'birth', generation.to_i, index)
    command = "../evolve #{settings['cross_over_rate']} #{parents.map { |p| "../#{previous_generation}/#{p}" }.join(' ')} #{child} #{seed}"
    success, output = run_evolve(command)
    raise "evolve failed to breed #{child}: #{command}" unless success && File.exist?(child)

    summary = output.match(/^summary operator=(\w+) differs_from_first=(\d+) differs_from_second=(\d+)$/)
    raise "evolve printed no summary for #{child}: #{command}" unless summary

    store.record_birth(generation: generation.to_i, child:, first_parent: parents[0], second_parent: parents[1],
                       operator: summary[1], differs_from_first: summary[2].to_i, differs_from_second: summary[3].to_i,
                       seed:, genome: Digest::SHA256.file(child).hexdigest)
  end

  # Returns [success, stdout]; evolve's last stdout line is its summary.
  def run_evolve(command)
    output, status = Open3.capture2(command)
    [status.success?, output]
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
    @rng ||= Random.new(Seeds.derive(experiment_seed, 'selection', generation.to_i))
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

  AMIGO = { 'name' => 'AmiGo', 'command' => 'amigogtp' }
  BROWN = { 'name' => 'Brown', 'command' => 'brown' }
  GNUGO0 = { 'name' => 'GnuGoLevel0', 'command' => 'gnugo --level 0 --mode gtp' }
  GNUGO10 = { 'name' => 'GnuGoLevel10', 'command' => 'gnugo --level 10 --mode gtp' }
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
    data['ranking'] = shuffle_ties(data['players'].keys.map { |player| { 'name' => player, 'score' => 0 } }, 0)
    data['games'] = games_from_ranking(data['ranking'], colors_rng(0))
    data
  end

  def games_from_ranking(ranking, random = colors_rng(0))
    games = []
    ranked_players = ranking.map { |r| r['name'] }
    loop do
      players = ranked_players.shift(2).shuffle(random:)
      break if players.empty?

      players << nil if players.length == 1
      games << { black: players.first, white: players.last }
    end
    games
  end

  def setup_players
    players = EXTERNAL_PLAYERS.each_with_object({}) do |player, hash|
      hash[player['name']] = { 'command' => player['command'], 'external' => true }
    end
    players.merge!(Dir['*.ann'].each_with_object({}) do |player, hash|
                     hash[player] = { 'command' => "../evo #{player}" }
                   end)
    players
  end
end
