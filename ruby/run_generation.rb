require 'digest'
require 'open3'
require_relative 'arena_result'
require_relative 'checkpoint_benchmark'
require_relative 'feature_groups'
require_relative 'generation_timings'
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
    # The generation's state is saved once its population is set up, so a
    # generation with state was begun by an earlier session.
    @timings = GenerationTimings.new(generation.to_i, partial: !data.empty?, clock:)
    result = timings.time(:total) do
      setup do
        played = play_games
        # After the tournament, whose final ranking names the network to
        # benchmark, and on resume too, so a checkpoint finishes its benchmark.
        benchmarked = keep?(generation.to_i) &&
                      timings.time(:benchmark) { CheckpointBenchmark.call(generation.to_i, settings, pool, store) }
        # A generation that played no game is done, and a one-generation run
        # moves on to the next one; one that finished its benchmark is not.
        benchmarked ? nil : played
      end
    end
    # A generation this session had nothing left to do in (a one-generation
    # run re-enters the last finished one) prints nothing, so the timing
    # lines are those of generations that ran.
    timings.report unless result == :already_done
    result
  end

  private

  attr_accessor :generation, :settings, :pool, :store

  # The generation's GenerationTimings, set by call; tests of a part alone
  # get one when they first use it.
  def timings
    @timings ||= GenerationTimings.new(generation.to_i, partial: false, clock:)
  end

  # Tests set @clock to a FakeClock.
  def clock
    @clock || GenerationTimings::MONOTONIC
  end

  # The scratch directory the generation works in. It is emptied at the
  # start of every generation; everything worth keeping is in the database.
  WORK = 'work'.freeze

  def setup
    FileUtils.rm_rf(WORK)
    FileUtils.mkdir(WORK)
    Dir.chdir(WORK) do
      timings.time(:setup) do
        if generation == '0'
          setup_initial_population
        else
          evolve_from_previous_population
        end
        # On resume the networks come from the database, not from breeding.
        store.export_networks(generation.to_i, '.')
      end
      yield
    end
  end

  def play_games
    return :already_done if data['round'] >= settings['tournament_rounds']

    loop do
      timings.round(data['round'] + 1) do
        play_round
        setup_next_round
      end

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

  # Byes are scored at once. Every other game is played in the arena
  # (`arena --mixed`), in at most `concurrency` chunks, one pool job each,
  # and each chunk's games are scored when it finishes.
  def play_round
    byes, games = data['games'].partition { |game| game['white'].nil? }
    # The odd player out sits the round out and gets the bye points.
    byes.each { |game| save_game(game, { 'winner' => nil }) }
    # Every manifest is written before the first chunk starts, so one the
    # arena could not read stops the round before any game.
    chunks = arena_chunks(games).to_h { |chunk| [chunk, prepare_chunk(chunk)] }
    chunks.each { |chunk, command| pool.submit(command, chunk) }

    chunks.size.times do
      chunk, duration, status = timings.wait { pool.next_finished }
      timings.job(duration)
      # Ctrl-C also stops the running chunks. Leave their games unscored so
      # that resuming plays them again instead of counting a killed game.
      # A chunk can be back before the trap has set the flag; its status tells.
      exit if $stop_now
      if WorkerPool.interrupted?(status)
        WorkerPool.exit_interrupted("arena chunk #{chunk.name} (#{chunk.games.keys.join(', ')})",
                                    'its games stay pending')
      end
      finish_chunk(chunk, duration, status)
    end
  end

  # One arena run: `games` maps each game's ID in the manifest to the game.
  # The files are named after the chunk.
  ArenaChunk = Struct.new(:name, :games) do
    def manifest = "#{name}.txt"
    def out = "#{name}.out"
    def err = "#{name}.err"
    def files = [manifest, out, err]
  end

  # Deals the games out in turn, so chunks differ by at most one game; the
  # games with a bot are dealt first, so chunks also differ by at most one
  # of those, wherever the bots stand in the ranking, and the slow games run
  # side by side. A game's ID is its file prefix, which has no whitespace
  # and, since each player plays once a round, is distinct within the round.
  def arena_chunks(games)
    count = [settings['concurrency'], games.size].min
    with_bot, without = games.partition { |game| external?(game['black']) || external?(game['white']) }
    (with_bot + without).each_with_index.group_by { |_, i| i % count }.values.each_with_index.map do |dealt, k|
      ArenaChunk.new("arena-#{k}", dealt.to_h { |game, _| [prefix_from(game), game] })
    end
  end

  # How long the arena waits for a bot's answer to any command but genmove,
  # and past a bot's main time for its genmove answer, in seconds. Both are
  # hang guards with a wide margin, since one missed deadline stops the run;
  # engine/arena.c's header comment has the measured answer times.
  RESPONSE_DEADLINE = 10
  GENMOVE_GRACE = 10

  # Writes the chunk's manifest and returns the arena command that plays it.
  # Each side has game_length minutes of main time. The shell execs the
  # arena, so the job's pid is the arena's and WorkerPool#terminate reaches
  # it (the arena then stops its bots); a shell that stayed would take the
  # SIGTERM and leave the arena running.
  def prepare_chunk(chunk)
    File.write(chunk.manifest, manifest(chunk))
    "exec ../arena --mixed #{settings['board_size']} #{settings.fetch('komi')} #{settings['max_moves']} " \
      "#{settings['game_length'] * 60} #{RESPONSE_DEADLINE} #{GENMOVE_GRACE} " \
      "#{chunk.manifest} > #{chunk.out} 2> #{chunk.err}"
  end

  # The chunk's players, a network by its file in work/ and a bot by its
  # name, then each game, followed by the command of each of its bots.
  def manifest(chunk)
    players = chunk.games.values.flat_map { |game| game.values_at('black', 'white') }.uniq
    lines = players.map { |player| external?(player) ? ['bot', player] : ['network', player, player] }
    chunk.games.each do |id, game|
      lines << ['game', id, game['black'], game['white']]
      seed = gnugo_seed(game)
      %w[black white].each do |color|
        player = game[color]
        lines << ['command', id, color, Seeds.with_gnugo_seed(data['players'][player]['command'], seed)] if external?(player)
      end
    end
    lines.map { |fields| "#{manifest_fields(fields).join("\t")}\n" }.join
  end

  # A manifest line's fields are separated by tabs, and the arena refuses
  # an empty field or one with a control character (a tab or newline
  # included), so the runner does too, before any game starts.
  def manifest_fields(fields)
    fields.each do |field|
      next unless field.empty? || field.match?(/[\x00-\x1f\x7f]/)

      raise ArgumentError, "the arena's manifest cannot hold #{field.inspect}: " \
                           'a field must not be empty or hold a tab or another control character'
    end
  end

  # GNU Go picks moves at random unless it gets a seed; one per game makes
  # every game repeatable.
  def gnugo_seed(game)
    Seeds.gnugo(experiment_seed, 'game', generation.to_i, data['round'], game['black'], game['white'])
  end

  # Raised when an arena chunk did not finish every game: a game the arena
  # could not finish (a failure record) is never scored, and neither is one
  # without a record. The chunk's other games are stored; the rest stay
  # pending, so a resume replays them.
  ArenaStopped = Class.new(StandardError)

  # Scores and stores every game of the chunk the arena finished, then
  # deletes the chunk's files; stops the run (ArenaStopped) if any game has
  # no result. A crash before the files are deleted replays the games not
  # yet scored.
  def finish_chunk(chunk, duration, status)
    # A dying arena may leave bytes that are not text; they match no line.
    # UTF-8 whatever the locale, which under LANG=C would be US-ASCII.
    output = read_utf8(chunk.out)
    parsed = ArenaResult.mixed_chunk(output, chunk.games.keys)
    stored = parsed.results.select { |_, result| result.failure.nil? }
    # The chunk's time beyond its records' (starting the arena, loading the
    # networks, and the games that failed) is shared out equally among the
    # stored games, so the rows add up to the worker's time.
    played = parsed.results.values.sum { |result| result.duration || 0 }
    share = stored.empty? ? 0 : [duration - played, 0].max / stored.size
    stored.each do |id, result|
      game = chunk.games.fetch(id)
      scored = score_game(game, result)
      timings.game(nil)
      save_game(game, scored) { store_arena_game(game, result, scored, (result.duration || 0) + share) }
    end
    stop_for(chunk, parsed, status) unless parsed.complete? && parsed.failures.empty? && status&.success?
    FileUtils.rm_f(chunk.files)
  end

  def read_utf8(path)
    File.exist?(path) ? File.read(path, encoding: 'UTF-8').scrub : ''
  end

  # Stops the run for a chunk whose games did not all finish, naming each
  # game left pending and why, with the chunk's stderr. Its files stay in
  # work/ until the resume empties it.
  def stop_for(chunk, parsed, status)
    reasons = []
    reasons << 'wrote no header' unless parsed.header?
    reasons << 'did not finish its output' unless parsed.complete? || !parsed.header?
    reasons << 'could not finish a game' if parsed.failures.any?
    reasons << "exited with #{status || 'no status'}" unless status&.success?
    withheld = parsed.results.reject { |_, result| result.failure.nil? }.map do |id, result|
      if result.failed?
        "  #{id}: #{result.end_reason} (#{result.error_side}): #{result.error_message}"
      else
        "  #{id}: no record"
      end
    end
    stderr = read_utf8(chunk.err)
    raise ArenaStopped, "Arena chunk #{chunk.name} of generation #{generation}, round #{data['round'] + 1} " \
                        "#{reasons.join(', ')}. #{withheld.size} of its #{chunk.games.size} games stay pending:\n" \
                        "#{withheld.join("\n")}\n" \
                        "#{stderr.empty? ? 'Its stderr is empty.' : "Its stderr:\n#{stderr.chomp}"}\n" \
                        'The games it finished are stored; resume after fixing the cause.'
  end

  # A stored game never failed, and the chunk's stderr, shared by all its
  # games, is not stored with any of them; a stop prints it.
  def store_arena_game(game, result, scored, duration)
    store.record(
      generation: generation.to_i, round: data['round'], black: game['black'], white: game['white'],
      black_external: external?(game['black']), white_external: external?(game['white']),
      winner: scored['winner'], failure: nil, length: result.length, end_reason: result.end_reason,
      referee_result: result.referee, error_message: result.error_message, duration:,
      # To a tenth, as twogtp gave the times of GoGui games.
      time_black: result.time_black&.round(1), time_white: result.time_white&.round(1), scorer: 'tromp_taylor',
      stderr: nil, sgf: keep_sgf? ? result.sgf(size: settings['board_size'], komi: settings.fetch('komi')) : nil
    )
  end

  # Stores a scored game in one transaction: its row (the block writes it;
  # a bye has none), its removal from the pending games, and the change to
  # the ranking, so a crash keeps all of it or none. Ctrl-C stops the runner
  # only once that has committed: exiting inside the transaction would roll
  # it back and throw the finished game away.
  def save_game(game, scored)
    store.transaction do
      yield if block_given?
      update_data(game, scored)
    end
    exit if $stop_now
    refresh_progress
  end

  # Scores one game in the state: it leaves the pending games and its points
  # move its players. Saves only what changed, in a transaction of its own or
  # save_game's.
  def update_data(game, result)
    points = points_for(game, result)
    ranking = data['ranking']
    new_ranking = ranking.map do |s|
      s.merge('score' => s['score'] + points.fetch(s['name'], 0))
    end
    # A stable order while the round is played; ties are shuffled once per
    # round in setup_next_round, so the order games finish in does not matter.
    new_ranking = new_ranking.sort_by { |s| ranking_key(s) }
    store.transaction do
      store.remove_pending_game(generation.to_i, game['black'], game['white'])
      save_ranking_change(ranking, new_ranking, points)
    end
    @data = data.merge(
      'games' => data['games'].reject { |g| g == game },
      'ranking' => new_ranking
    )
  end

  def ranking_key(entry)
    [-entry['score'], entry['name']]
  end

  # Keeps the stored ranking the one in memory, rank for rank: the ranking
  # CLI shows it. When the ranking was in ranking_key order before the game,
  # only the players whose score changed move. Otherwise (the first game
  # after a full save, whose ties setup_next_round shuffled, or after a
  # resume that loaded such a ranking) sorting reorders players who did not
  # play too, so the whole ranking is rewritten, about once a round.
  def save_ranking_change(ranking, new_ranking, points)
    if in_order?(ranking)
      ranking_moves(ranking, points).each do |name, score, from, to|
        store.raise_in_ranking(generation.to_i, name, score, from:, to:)
      end
    else
      store.save_ranking(generation.to_i, new_ranking, data['players'])
    end
  end

  def in_order?(ranking)
    ranking.each_cons(2).all? { |a, b| (ranking_key(a) <=> ranking_key(b)).negative? }
  end

  # [name, new score, old rank, new rank] for each player whose score rose,
  # moved one after the other in a copy of the ranking, which stays in
  # ranking_key order. Points are never negative, so a player only moves up.
  def ranking_moves(ranking, points)
    order = ranking.dup
    points.filter_map do |name, gained|
      next if gained.zero?

      from = order.index { |s| s['name'] == name }
      entry = order.delete_at(from).then { |s| s.merge('score' => s['score'] + gained) }
      to = order.bsearch_index { |s| (ranking_key(s) <=> ranking_key(entry)).positive? } || order.size
      order.insert(to, entry)
      [name, entry['score'], from + 1, to + 1]
    end
  end

  # Points by player for one game, from the experiment's scoring: a win
  # counts the same against a network or a bot, the odd player out gets the
  # bye points, and both players of a draw get the draw points. A game
  # without a result is never scored.
  def points_for(game, result)
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

  # The winner of a game the arena finished; none for a draw. A bot that
  # resigned and a network out of main time or that could not be loaded
  # have lost.
  def score_game(game, result)
    return { 'winner' => nil } unless result.winner

    { 'winner' => result.winner == :black ? game['black'] : game['white'] }
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

  # The generation's tournament state: loaded from the experiment database
  # once, then kept in memory as it is saved; {} before the generation
  # starts. It is always what ExperimentDatabase#state would load.
  def data
    @data ||= store.state(generation.to_i) || {}
  end

  # Replaces the state in one transaction, so a crash leaves the old state or
  # the new one, never half of it, and keeps it as the state in memory. Used
  # at setup and at each round's pairing; a game saves only what it changed
  # (save_game).
  def save_data(hash, retire_networks_of: nil)
    store.save_state(generation.to_i, hash, retire_networks_of:)
    @data = hash
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

  # The version of the scoring logic below and in ArenaResult: what counts
  # as a win or a draw, and what stops the run. 3: every tournament game is
  # played in the arena and scored by Tromp-Taylor; a bot that resigns
  # loses, a network out of main time loses, and a game the arena could not
  # finish stops the run instead of being scored. (2: games with a bot went
  # through gogui-twogtp and its GNU Go referee, and failed games were
  # stored without points.) Bump it when that changes, so an experiment
  # begun under other rules refuses to run. The points themselves are in
  # the experiment's scoring.
  SCORING_RULES = '3'.freeze

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
      games << { 'black' => players.first, 'white' => players.last }
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
