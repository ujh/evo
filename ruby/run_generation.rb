require 'digest'
require 'open3'
require_relative 'arena_result'
require_relative 'checkpoint_benchmark'
require_relative 'feature_groups'
require_relative 'game_result'
require_relative 'seeds'
require_relative 'worker_pool'

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
      result = play_games
      # After the tournament, whose final ranking names the network to
      # benchmark, and on resume too, so a checkpoint finishes its benchmark.
      benchmarked = keep?(generation.to_i) && CheckpointBenchmark.call(generation.to_i, settings, pool, store)
      # A generation that played no game is done, and a one-generation run
      # moves on to the next one; one that finished its benchmark is not.
      benchmarked ? nil : result
    end
  end

  private

  attr_accessor :generation, :settings, :pool, :store

  # The scratch directory the generation works in. It is emptied at the
  # start of every generation; everything worth keeping is in the database.
  WORK = 'work'.freeze

  def setup
    FileUtils.rm_rf(WORK)
    FileUtils.mkdir(WORK)
    Dir.chdir(WORK) do
      if generation == '0'
        setup_initial_population
      else
        evolve_from_previous_population
      end
      # On resume the networks come from the database, not from breeding.
      store.export_networks(generation.to_i, '.')
      yield
    end
  end

  def play_games
    return :already_done if data['round'] >= settings['tournament_rounds']

    loop do
      play_round
      setup_next_round

      break if data['round'] >= settings['tournament_rounds']
    end
    puts "\rPlaying ... done".ljust(70)
  end

  def setup_next_round
    round = data['round'] + 1
    ranking = shuffle_ties(data['ranking'], round)
    games = if round >= settings['tournament_rounds']
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

  # Byes are scored at once. Games between two networks go to the arena in
  # at most `concurrency` chunks, one pool job each; games with a bot go to
  # gogui-twogtp, one job each. Both kinds share the pool, and each job is
  # scored when it finishes.
  def play_round
    byes, games = data['games'].partition { |game| game['white'].nil? }
    byes.each do |game|
      # The odd player out sits the round out and gets the bye points.
      update_data(game, { 'winner' => nil })
      refresh_progress
    end
    arena, gogui = games.partition { |game| arena_game?(game) }
    jobs = arena_chunks(arena).each { |chunk| pool.submit(prepare_chunk(chunk), chunk) }
    gogui.each do |game|
      game_data = prepare_game(game)
      pool.submit(game_data['command'], game_data['identifier'])
    end

    (jobs.size + gogui.size).times do
      finished, duration, status = pool.next_finished
      # Ctrl-C also stops the running games. Leave them unscored so that
      # resuming plays them again instead of counting a killed game. The
      # game can be back before the trap has set the flag; its status tells.
      exit if $stop_now
      exit_interrupted(finished) if WorkerPool.interrupted?(status)
      if finished.is_a?(ArenaChunk)
        finish_chunk(finished, duration)
      else
        finish_game(finished, duration)
      end
    end
  end

  def exit_interrupted(job)
    if job.is_a?(ArenaChunk)
      WorkerPool.exit_interrupted("arena chunk #{job.name} (#{job.games.keys.join(', ')})", 'its games stay pending')
    else
      WorkerPool.exit_interrupted("game #{prefix_from(job)}", 'it stays pending')
    end
  end

  def finish_game(game, duration)
    result = GameResult.read(prefix_from(game))
    scored = score_game(game, result)
    store_game(game, result, scored, duration)
    update_data(game, scored)
    refresh_progress
  end

  # One arena run: `games` maps each game's ID in the schedule to the game.
  # The files are named after the chunk.
  ArenaChunk = Struct.new(:name, :games) do
    def schedule = "#{name}.txt"
    def out = "#{name}.out"
    def err = "#{name}.err"
    def files = [schedule, out, err]
  end

  def arena_game?(game)
    !external?(game['black']) && !external?(game['white'])
  end

  # Deals the games out in turn, so chunks differ by at most one game. A
  # game's ID is its file prefix, which has no whitespace and, since each
  # player plays once a round, is distinct within the round.
  def arena_chunks(games)
    count = [settings['concurrency'], games.size].min
    games.each_with_index.group_by { |_, i| i % count }.values.each_with_index.map do |dealt, k|
      ArenaChunk.new("arena-#{k}", dealt.to_h { |game, _| [prefix_from(game), game] })
    end
  end

  def prepare_chunk(chunk)
    File.write(chunk.schedule, chunk.games.map { |id, game| "#{id} #{game['black']} #{game['white']}\n" }.join)
    "../arena #{settings['board_size']} #{settings.fetch('komi')} #{settings['max_moves']} " \
      "#{chunk.schedule} > #{chunk.out} 2> #{chunk.err}"
  end

  # Scores and stores every game of the chunk, with a result or, when the
  # arena gave none, a failure, then deletes the chunk's files. A crash
  # before the files are deleted replays the games not yet scored.
  def finish_chunk(chunk, duration)
    # A dying arena may leave bytes that are not text; they match no line.
    # UTF-8 whatever the locale, which under LANG=C would be US-ASCII.
    output = File.exist?(chunk.out) ? File.read(chunk.out, encoding: 'UTF-8').scrub : ''
    results = ArenaResult.chunk(output, chunk.games.keys).results
    stderr = File.exist?(chunk.err) ? File.read(chunk.err, encoding: 'UTF-8').scrub : ''
    # The chunk's time beyond its games' (starting the arena, loading the
    # networks) is shared out equally, so the rows add up to the worker's time.
    played = results.values.sum { |result| result.duration || 0 }
    share = [duration - played, 0].max / chunk.games.size
    chunk.games.each do |id, game|
      result = results.fetch(id)
      scored = score_game(game, result)
      store_arena_game(game, result, scored, (result.duration || 0) + share, stderr)
      update_data(game, scored)
      refresh_progress
    end
    FileUtils.rm_f(chunk.files)
  end

  def store_arena_game(game, result, scored, duration, stderr)
    store.record(
      generation: generation.to_i, round: data['round'], black: game['black'], white: game['white'],
      black_external: false, white_external: false,
      winner: scored['winner'], failure: scored['failure'], length: result.length,
      referee_result: result.referee, error_message: result.error_message, duration:,
      # To a tenth, as twogtp gives the times of GoGui games.
      time_black: result.time_black&.round(1), time_white: result.time_white&.round(1), scorer: 'tromp_taylor',
      stderr: scored['failure'] && !stderr.empty? ? stderr : nil,
      sgf: keep_sgf? ? result.sgf(size: settings['board_size'], komi: settings.fetch('komi')) : nil
    )
  end

  def update_data(game, result)
    points = points_for(game, result)
    new_ranking = data['ranking'].map do |s|
      s.merge('score' => s['score'] + points.fetch(s['name'], 0))
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

  # Points by player for one game, from the experiment's scoring: a win
  # counts the same against a network or a bot, the odd player out gets the
  # bye points, both players of a draw get the draw points, and a failed game
  # gives none.
  def points_for(game, result)
    return {} if result['failure']
    return { result['winner'] => scoring['win'] } if result['winner']
    return { game['black'] => scoring['bye'] } if game['white'].nil?

    { game['black'] => scoring['draw'], game['white'] => scoring['draw'] }
  end

  def scoring
    @scoring ||= store.scoring
  end

  def refresh_progress
    current_round = data['round'] + 1
    total_rounds = settings['tournament_rounds']
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
    black = Seeds.with_gnugo_seed(data['players'][game['black']]['command'], seed)
    white = Seeds.with_gnugo_seed(data['players'][game['white']]['command'], seed)
    size = settings['board_size']
    maxmoves = settings['max_moves']
    prefix = prefix_from(game)
    time = settings['game_length']
    cmd = %(gogui-twogtp -black "#{black}" -white "#{white}" -referee "#{GameResult::REFEREE} --seed #{seed}" ) +
          %(-size #{size} -komi #{settings.fetch('komi')} -auto -games 1 -sgffile #{prefix} -time #{time} ) +
          %(-force -maxmoves #{maxmoves} 2> #{prefix}.err)

    { 'command' => cmd, 'identifier' => game }
  end

  # `result` is a GameResult or an ArenaResult; both answer alike.
  def score_game(game, result)
    return { 'winner' => nil, 'failure' => result.failure } if result.failure
    return { 'winner' => nil } unless result.winner

    winner, loser = result.winner == :black ? [game['black'], game['white']] : [game['white'], game['black']]
    # A bot crashing says nothing about the network that played it.
    return { 'winner' => nil, 'failure' => "#{loser} crashed" } if result.crashed? && data['players'][loser]['external']

    { 'winner' => winner }
  end

  # Writes the game to the experiment database, then deletes the files gogui-twogtp
  # left, so an experiment does not pile up three files per game. The SGF is
  # kept for every keep_every-th generation only. A crash between the two
  # steps replays the game, and its row is replaced.
  def store_game(game, result, scored, duration)
    prefix = prefix_from(game)
    sgf_file = "#{prefix}-0.sgf"
    err_file = "#{prefix}.err"
    store.record(
      generation: generation.to_i, round: data['round'], black: game['black'], white: game['white'],
      black_external: external?(game['black']), white_external: external?(game['white']),
      winner: scored['winner'], failure: scored['failure'], length: result.length,
      referee_result: result.referee, error_message: result.error_message,
      duration:, time_black: result.time_black, time_white: result.time_white, scorer: 'gnugo',
      stderr: File.exist?(err_file) ? File.read(err_file) : nil,
      sgf: keep_sgf? && File.exist?(sgf_file) ? File.read(sgf_file) : nil
    )
    FileUtils.rm_f(["#{prefix}.dat", sgf_file, err_file])
  end

  def keep_sgf?
    keep?(generation.to_i)
  end

  # SGFs and networks are kept for every keep_every-th generation (0 keeps
  # none), so lineages can be revisited at regular points.
  def keep?(generation_number)
    every = settings['keep_every']
    every.positive? && (generation_number % every).zero?
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
  def save_data(hash, retire_networks_of: nil)
    store.save_state(generation.to_i, hash, retire_networks_of:)
    @data = nil
    exit if $stop_now
  end

  def setup_initial_population
    return if data['setup_complete']

    puts 'Generating initial population ...'
    seed = Seeds.derive(experiment_seed, 'initial-population')
    genes = settings.values_at(*INITIAL_GENES)
    command = "../initial-population #{settings['population_size']} #{settings['board_size']} " \
              "#{settings['hidden_layers']} #{settings['layer_size']} #{genes.join(' ')} " \
              "#{experiment_features} #{settings['initial_feature_noise']} #{settings['initial_feature_step']} #{seed}"
    # Stop before storing anything, so generation 0 never starts short of
    # networks, as breeding does when evolve fails.
    success, output = run_initial_population(command)
    raise "initial-population failed: #{command}" unless success

    networks = Dir['*.ann'].sort
    expected = settings['population_size']
    raise "initial-population wrote #{networks.size} networks, expected #{expected}: #{command}" unless networks.size == expected

    births = networks.zip(initial_genes(output, networks.size, command)).map do |network, network_genes|
      { generation: 0, child: network, first_parent: nil, second_parent: nil, operator: 'initial',
        differs_from_first: nil, differs_from_second: nil, seed:, genome: Digest::SHA256.file(network).hexdigest,
        **network_genes }
    end
    networks.zip(births) do |network, birth|
      store.record_network(0, network, File.binread(network))
      store.record_birth(**birth)
    end
    save_data(setup_tournament)
  end

  # The settings with the genes of generation 0, in initial-population's
  # argument order.
  INITIAL_GENES = %w[
    initial_copy_chance initial_weight_changes initial_weight_step initial_activation_rate initial_structure_rate
  ].freeze

  # Returns [success, stdout]; stdout has a genes line per network.
  def run_initial_population(command)
    output, status = Open3.capture2(command)
    [status.success?, output]
  end

  # The genes of each generation-0 network, in file order (0001.ann,
  # 0002.ann, ... sort as initial-population writes them). There must be one
  # well-formed line per network, each of the generation-0 shape and the
  # experiment's feature set.
  def initial_genes(output, count, command)
    lines = output.lines.select { |line| line.start_with?('genes') }
    raise "initial-population printed #{lines.size} genes lines for #{count} networks: #{command}" unless lines.size == count

    shape = [settings['hidden_layers'], settings['hidden_layers'].zero? ? 0 : settings['layer_size']]
    lines.map do |line|
      genes = parse_genes(line, command)
      raise "initial-population printed genes of another shape: #{line.chomp}" unless genes.values_at(:layers, :width) == shape
      unless genes[:features] == experiment_features
        raise "initial-population printed genes of the feature set #{genes[:features]}, " \
              "but the experiment's is #{experiment_features}: #{line.chomp}"
      end

      genes
    end
  end

  # The feature set every network of the experiment has, as the genes line
  # writes it; the setting is stored that way.
  def experiment_features
    settings['features']
  end

  # A genes line of initial-population or evolve (ann_print_genes_line in
  # lib/ann.h) as a birth's gene columns, plus :features (the feature set as
  # written), :feature_step, and :fw_NAME for each move feature of the set.
  # Anything else raises.
  def parse_genes(line, command)
    genes = parse_genes_fields(line.chomp)
    raise "malformed genes line #{line.chomp.inspect}: #{command}" if genes.nil? || genes.value?(nil)

    genes
  end

  # The fields of a genes line, with nil for a number that is not finite, or
  # nil when the line has other fields, or other feature weights than its
  # feature set's move features in their order.
  def parse_genes_fields(line)
    match = GENES_LINE.match(line) or return nil
    move_features = FeatureGroups.move_features(match[:features]) or return nil
    weights = match[:weights].scan(FEATURE_WEIGHT)
    return nil unless weights.map(&:first) == move_features

    genes = GENE_FIELDS.to_h { |field, kind| [field, parse_gene(kind, match[field])] }
    genes.merge(features: match[:features], feature_step: parse_gene(:number, match[:feature_step]),
                **weights.to_h { |name, text| [:"fw_#{name}", parse_gene(:number, text)] })
  end

  # nil for a number that is not finite.
  def parse_gene(kind, text)
    case kind
    when :integer then Integer(text, 10)
    when :number then Float(text, exception: false)&.then { |value| value.finite? ? value : nil }
    else text
    end
  end

  # Each field of a genes line, in order, and its kind.
  GENE_FIELDS = {
    layers: :integer, width: :integer, act_hidden: :activation, act_output: :activation, copy_chance: :number,
    weight_changes: :number, weight_step: :number, activation_rate: :number, structure_rate: :number
  }.freeze
  GENE_PATTERNS = { integer: '\d+', activation: 'sigmoid|sigmoid_cached|threshold|linear|tanh|relu', number: '\S+' }.freeze
  # The genes, the feature set and feature_step, then the feature weights,
  # each as " fw_NAME=G", checked against the feature set by parse_genes_fields.
  GENES_LINE = /
    \Agenes\ #{GENE_FIELDS.map { |field, kind| "#{field}=(?<#{field}>#{GENE_PATTERNS.fetch(kind)})" }.join('\ ')}
    \ features=(?<features>[a-z_,]+)\ feature_step=(?<feature_step>\S+)(?<weights>(?:\ fw_[a-z_]+=\S+)*)\z
  /x
  FEATURE_WEIGHT = / fw_([a-z_]+)=(\S+)/

  def evolve_from_previous_population
    return if data['setup_complete']

    previous_generation = generation.to_i - 1
    previous_data = store.state(previous_generation)
    candidates = parent_candidates(previous_data)
    FileUtils.mkdir_p(PARENTS)
    store.export_networks(previous_generation, PARENTS)
    # Generate the new population
    total = settings['population_size']
    total.times do |i|
      print "\rGenerating population ... #{i + 1}/#{total}"
      breed_child(previous_generation, candidates, i)
    end
    puts "\rGenerating population ... done         "
    # The parents are dropped in the same transaction that saves the new
    # generation, unless their generation is one to keep.
    save_data(setup_tournament, retire_networks_of: keep?(previous_generation) ? nil : previous_generation)
  end

  # The previous generation's networks, written out for evolve. They are
  # named like this generation's children, so they need their own directory.
  PARENTS = 'parents'.freeze

  # Writes one child straight to `child`. A file left there by an interrupted
  # run is removed first, so a child exists only if this evolve wrote it. On
  # failure, breeding stops before the parents are deleted.
  def breed_child(previous_generation, candidates, index)
    child = "#{index}.ann"
    FileUtils.rm_f(child)
    parents = Array.new(2) { select_parent(candidates) }
    seed = Seeds.derive(experiment_seed, 'birth', generation.to_i, index)
    command = "../evolve #{evolve_arguments.join(' ')} #{parents.map { |p| "#{PARENTS}/#{p}" }.join(' ')} #{child} #{seed}"
    success, output, status = run_evolve(command)
    stop_breeding(child, status) unless success
    raise "evolve failed to breed #{child}: #{command}" unless success && File.exist?(child)

    summary = output.match(EVOLVE_SUMMARY)
    raise "evolve printed no summary for #{child}: #{command}" unless summary

    genes_lines = output.lines.select { |line| line.start_with?('genes') }
    raise "evolve printed #{genes_lines.size} genes lines for #{child}: #{command}" unless genes_lines.size == 1

    genes = parse_genes(genes_lines.first, command)
    unless genes[:features] == experiment_features
      raise "evolve printed genes of the feature set #{genes[:features]} for #{child}, " \
            "but the experiment's is #{experiment_features}: #{command}"
    end
    store.record_network(generation.to_i, child, File.binread(child))
    store.record_birth(generation: generation.to_i, child:, first_parent: parents[0], second_parent: parents[1],
                       operator: summary[:operator], differs_from_first: differs(summary[:first]),
                       differs_from_second: differs(summary[:second]), seed:,
                       genome: Digest::SHA256.file(child).hexdigest, parent: summary[:parent],
                       structure: summary[:structure], activation_changed: summary[:activation_changed] == '1',
                       **genes)
  end

  # evolve's summary line. differs is -1 when the child's shape differs from
  # that parent's.
  EVOLVE_SUMMARY = /
    ^summary
    \ operator=(?<operator>crossover|mutation|copy)
    \ parent=(?<parent>first|second)
    \ structure=(?<structure>none|widen|narrow|add_layer|remove_layer)
    \ activation_changed=(?<activation_changed>[01])
    \ differs_from_first=(?<first>-1|\d+)
    \ differs_from_second=(?<second>-1|\d+)$
  /x

  # evolve's arguments before the parents: the crossover rate, the meta rate,
  # the bounds on a child's shape, and the width of a layer added to a
  # network without hidden layers: the generation-0 width, within the bound.
  def evolve_arguments
    max_width = settings['max_layer_size']
    [settings['cross_over_rate'], settings['meta_rate'], settings['max_hidden_layers'], max_width,
     [settings['layer_size'], max_width].min]
  end

  # A differs count as stored: nil when the shapes differ.
  def differs(count)
    count == '-1' ? nil : count.to_i
  end

  # Returns [success, stdout, Process::Status]; evolve's last stdout line is its summary.
  def run_evolve(command)
    output, status = Open3.capture2(command)
    [status.success?, output, status]
  end

  # Ctrl-C reaches the running evolve too. Stop as the tournament does,
  # without an error: the generation's setup is saved only after the last
  # child, so a resume breeds every child again, with the same seeds. evolve
  # can be back before the trap has set the flag; its status tells.
  def stop_breeding(child, status)
    exit if $stop_now
    WorkerPool.exit_interrupted("breeding #{child}", 'breeding starts over on resume') if WorkerPool.interrupted?(status)
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
    size = settings['tournament_size']
    raise ArgumentError, "tournament_size must be at least 1, got #{size}" if size < 1

    Array.new(size) { candidates.sample(random: rng) }.max_by { |c| c['score'] }['name']
  end

  def rng
    @rng ||= Random.new(Seeds.derive(experiment_seed, 'selection', generation.to_i))
  end

  # The version of the scoring logic below and in GameResult and ArenaResult:
  # what counts as a win, a draw, or a failure. 2: games between networks
  # are played in the arena and scored by Tromp-Taylor. Bump it when that changes, so an experiment
  # begun under other rules refuses to run. The points themselves are in
  # the experiment's scoring.
  SCORING_RULES = '2'.freeze

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

  # The experiment's opponents, each copy numbered from 1, then the networks.
  def setup_players
    players = store.opponents.each_with_object({}) do |opponent, hash|
      (1..opponent[:copies]).each do |i|
        hash["#{opponent[:name]}#{i}"] = { 'command' => opponent[:command], 'external' => true }
      end
    end
    players.merge!(Dir['*.ann'].each_with_object({}) do |player, hash|
                     hash[player] = { 'command' => "../evo #{player}" }
                   end)
    players
  end
end
