require 'digest'
require 'open3'
require_relative 'arena_result'
require_relative 'checkpoint_benchmark'
require_relative 'feature_groups'
require_relative 'generation_timings'
require_relative 'progress_line'
require_relative 'seeds'
require_relative 'worker_pool'

class RunGeneration
  include ProgressLine

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
    @clock || GenerationTimings::AWAKE
  end

  # The scratch directory the generation works in. It is emptied at the
  # start of every generation; everything worth keeping is in the database
  # and in NETWORKS.
  WORK = 'work'.freeze

  # Each generation's networks, in the experiment directory beside work/:
  # networks/N/ once complete, networks/N.partial/ while setup writes them.
  # As the generation sees it from work/, where it runs.
  NETWORKS = '../networks'.freeze
  EXPERIMENT = '..'.freeze

  # Raised when a run cannot go on; the message is the report the run stops
  # with (RunExperiment prints it and exits 1).
  Stopped = Class.new(StandardError)

  # Raised when a generation's saved setup lacks networks/N/ or a network
  # that matches its birth. Its parents are gone, so it cannot be bred again.
  NetworksDamaged = Class.new(Stopped)

  # Raised when evolve or initial-population did not breed the population.
  # The setup is not saved, so a resume breeds it again with the same seeds.
  BreedingFailed = Class.new(Stopped)

  def setup
    timings.time(:setup) do
      timings.time(:setup_clear) { empty_work }
      Dir.chdir(WORK) do
        resumed = data['setup_complete']
        timings.time(:setup_retire) { sweep_networks }
        if generation == '0'
          setup_initial_population
        else
          evolve_from_previous_population
        end
        # A generation set up by an earlier session plays networks it did
        # not write; one whose tournament is over plays nothing.
        timings.time(:setup_verify) { verify_networks } if resumed && data['round'] < settings['tournament_rounds']
      end
      end_line('Setup ... done') if @shown
    end
    Dir.chdir(WORK) { yield }
  end

  def network_dir(number) = File.join(NETWORKS, number.to_s)

  def partial_dir = "#{network_dir(generation)}.partial"

  def network_path(name) = File.join(network_dir(generation), name)

  # Deletes every networks/K/ and networks/K.partial/ but the one this
  # setup needs: networks/N/ once N's setup is saved, else the parents'
  # networks/N-1/. So a partial or complete networks/N/ of a setup that was
  # never saved goes (it is bred again), and so do parents a crash or Ctrl-C
  # left after the save.
  def sweep_networks
    return unless Dir.exist?(NETWORKS)

    needed = data['setup_complete'] ? generation : (generation.to_i - 1).to_s
    stale = Dir.children(NETWORKS).select { |entry| entry.match?(/\A\d+(\.partial)?\z/) && entry != needed }
    return if stale.empty?

    show('Deleting old networks ...')
    stale.each { |entry| FileUtils.rm_rf(File.join(NETWORKS, entry)) }
  end

  # An empty networks/N.partial/ for setup to write into.
  def prepare_partial
    FileUtils.rm_rf(partial_dir)
    FileUtils.mkdir_p(partial_dir)
  end

  # Makes networks/N.partial/ networks/N/ for good: syncs every network and
  # the directory, renames it, and syncs networks/ and the experiment
  # directory (which holds networks/ since the first generation), so the
  # rename is on disk before the setup that relies on it is saved.
  def publish_networks
    show('Syncing networks ...')
    Dir.children(partial_dir).sort.each { |name| fsync(File.join(partial_dir, name)) }
    fsync(partial_dir)
    File.rename(partial_dir, network_dir(generation))
    fsync(NETWORKS)
    fsync(EXPERIMENT)
  end

  def fsync(path)
    File.open(path) { |file| file.fsync }
  end

  # Deletes the parents' networks once the generation bred from them is saved.
  def retire_networks(number)
    show("Deleting generation #{number}'s networks ...")
    FileUtils.rm_rf(network_dir(number))
  end

  # Checks networks/N/ against the generation's births: each is there and
  # has the SHA-256 its birth recorded.
  def verify_networks
    show('Verifying networks ...')
    directory = network_dir(generation)
    shown = "networks/#{generation}/"
    unless Dir.exist?(directory)
      raise NetworksDamaged, "#{shown} is missing, but generation #{generation}'s setup is saved. " \
                             "#{cannot_breed_again}"
    end

    missing = []
    changed = []
    store.births(generation.to_i).each do |birth|
      path = File.join(directory, birth[:child])
      if !File.file?(path) then missing << birth[:child]
      elsif Digest::SHA256.file(path).hexdigest != birth[:genome] then changed << birth[:child]
      end
    end
    return if missing.empty? && changed.empty?

    problems = { 'missing' => missing, 'changed' => changed }.reject { |_, names| names.empty? }
    raise NetworksDamaged, "#{shown} does not match generation #{generation}'s births " \
                           "(#{problems.map { |kind, names| "#{kind}: #{listed(names)}" }.join('; ')}). " \
                           "#{cannot_breed_again}"
  end

  # Names up to 20, then how many more.
  def listed(names)
    shown = names.first(20).join(', ')
    names.size > 20 ? "#{shown} and #{names.size - 20} more" : shown
  end

  def cannot_breed_again
    'Its parents are gone, so it cannot be bred again. The run stopped.'
  end

  def empty_work
    FileUtils.rm_rf(WORK)
    FileUtils.mkdir(WORK)
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
    end_line('Playing ... done')
  end

  # After the last round, a checkpoint's champion is stored with the state
  # that ends its tournament.
  def setup_next_round
    round = data['round'] + 1
    ranking = shuffle_ties(data['ranking'], round)
    state = data.merge('round' => round, 'ranking' => ranking)
    if round < settings['tournament_rounds']
      show("Pairing round #{round + 1}/#{settings['tournament_rounds']} ...")
      save_data(state.merge('games' => games_from_ranking(ranking, state['players'], colors_rng(round))))
    elsif keep?(generation.to_i)
      show('Storing the champion ...')
      timings.time(:champion) { save_data(state.merge('games' => []), champion: champion(ranking)) }
    else
      show('Saving the final ranking ...')
      save_data(state.merge('games' => []))
    end
  end

  # [name, bytes] of the first network of the ranking that is not a bot,
  # as CheckpointBenchmark#top_network and ArchiveExperiment pick it.
  def champion(ranking)
    name = ranking.map { |entry| entry['name'] }.find { |player| !external?(player) }
    raise "generation #{generation} has no ranked network to keep" unless name

    [name, File.binread(network_path(name))]
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
  # (`arena --mixed`), in chunks of a few games, one streaming pool job
  # each, and each game is scored as its record arrives.
  def play_round
    byes, games = data['games'].partition { |game| game['white'].nil? }
    # The odd player out sits the round out and gets the bye points.
    byes.each { |game| save_game(game, { 'winner' => nil }) }
    # Every manifest is written before the first chunk starts, so one the
    # arena could not read stops the round before any game. Until the first
    # game is in, the line shows the chunks starting: each arena loads its
    # networks first.
    dealt = arena_chunks(games)
    unless dealt.empty?
      show("Round #{data['round'] + 1}/#{settings['tournament_rounds']}: starting #{dealt.size} arena chunks ...")
    end
    chunks = dealt.map { |chunk| [chunk, prepare_chunk(chunk)] }
    chunks.each { |chunk, command| pool.submit_streaming(command, chunk) }

    # The round's chunks not yet ended, running or queued (stop_for counts
    # those it did not signal as not started).
    @unended = chunks.size
    while @unended.positive?
      event = timings.wait { pool.next_finished }
      # Ctrl-C also stops the running chunks. A record read after the trap
      # is dropped and its game stays pending, since the arena may have been
      # killed while the game was played; the games stored before stay.
      exit if $stop_now
      if event.is_a?(WorkerPool::Line)
        receive_record(event.identifier, event.text)
      else
        @unended -= 1
        finish_chunk(event.identifier, event.duration, event.status)
      end
    end
  end

  # One arena run: `games` maps each game's ID in the manifest to the game,
  # and `stream` reads its stdout as it arrives. The files are named after
  # the chunk.
  ArenaChunk = Struct.new(:name, :games, :stream) do
    def manifest = "#{name}.txt"
    def err = "#{name}.err"
    def files = [manifest, err]
  end

  # Chunks per worker. More, smaller chunks let a worker that finishes early
  # take the next one instead of idling; each costs only a process start,
  # as each network still plays once a round and so is loaded once.
  CHUNKS_PER_WORKER = 4

  # Deals the games out in turn into chunks_per_worker chunks per worker
  # (fewer if there are fewer games), so chunks differ by at most one game;
  # the games with a bot are dealt first, so chunks also differ by at most
  # one of those, wherever the bots stand in the ranking, and they land in
  # the first chunks queued, which start first. A game's ID is its file
  # prefix, which has no whitespace and, since each player plays once a
  # round, is distinct within the round.
  def arena_chunks(games)
    count = [chunks_per_worker * settings['concurrency'], games.size].min
    with_bot, without = games.partition { |game| external?(game['black']) || external?(game['white']) }
    (with_bot + without).each_with_index.group_by { |_, i| i % count }.values.each_with_index.map do |dealt, k|
      chunk_games = dealt.to_h { |game, _| [prefix_from(game), game] }
      ArenaChunk.new("arena-#{k}", chunk_games, ArenaResult::MixedStream.new(chunk_games.keys))
    end
  end

  # Overridden in tests.
  def chunks_per_worker = CHUNKS_PER_WORKER

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
  # SIGTERM and leave the arena running. Its stdout is the pool's pipe.
  def prepare_chunk(chunk)
    File.write(chunk.manifest, manifest(chunk))
    "exec ../arena --mixed #{settings['board_size']} #{settings.fetch('komi')} #{settings['max_moves']} " \
      "#{settings['game_length'] * 60} #{RESPONSE_DEADLINE} #{GENMOVE_GRACE} " \
      "#{chunk.manifest} 2> #{chunk.err}"
  end

  # The chunk's players, a network by its file in networks/N/ and a bot by
  # its name, then each game, followed by the command of each of its bots.
  def manifest(chunk)
    players = chunk.games.values.flat_map { |game| game.values_at('black', 'white') }.uniq
    lines = players.map { |player| external?(player) ? ['bot', player] : ['network', player, network_path(player)] }
    chunk.games.each do |id, game|
      lines << ['game', id, game['black'], game['white']]
      seed = bot_seed(game)
      %w[black white].each do |color|
        player = game[color]
        lines << ['command', id, color, Seeds.with_bot_seed(data['players'][player]['command'], seed)] if external?(player)
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

  # GNU Go and michi pick moves at random unless they get a seed; one per
  # game makes every game repeatable. The label is the one GNU Go's seeds
  # have always had, so its games stay as they were.
  def bot_seed(game)
    Seeds.gnugo(experiment_seed, 'game', generation.to_i, data['round'], game['black'], game['white'])
  end

  # Raised when an arena chunk did not finish every game: a game the arena
  # could not finish (a failure record) is never scored, and neither is one
  # without a record. The chunk's other games are stored; the rest stay
  # pending, so a resume replays them. The message is the report the run
  # stops with (RunExperiment prints it and exits 1).
  ArenaStopped = Class.new(Stopped)

  # Reads one line of the chunk's stdout and scores and stores the game of
  # a record at once, with the game's own time (finish_chunk adds its share
  # of the chunk's overhead). A failure record is kept for finish_chunk.
  # Output the arena never writes stops the run here (stop_for).
  def receive_record(chunk, line)
    id, result = chunk.stream.add(line)
    return unless id && result.failure.nil?

    game = chunk.games.fetch(id)
    scored = score_game(game, result)
    timings.game(nil)
    save_game(game, scored) { store_arena_game(game, result, scored, result.duration || 0) }
  rescue ArenaResult::Broken => e
    stop_for(chunk, broken: e.message)
  end

  # Once the chunk has ended: shares its time beyond its records out among
  # its stored games, then stops the run (ArenaStopped) if any game has no
  # result, else deletes the chunk's files. A crash before that replays the
  # games not yet stored, and leaves the stored ones without their share.
  def finish_chunk(chunk, duration, status)
    timings.job(duration)
    # A chunk can end before the trap has set the flag; its status tells.
    if WorkerPool.interrupted?(status)
      WorkerPool.exit_interrupted("arena chunk #{chunk.name} (#{chunk.games.keys.join(', ')})",
                                  'its games not stored stay pending')
    end
    add_overhead(chunk, duration)
    stream = chunk.stream
    stop_for(chunk, status) unless stream.complete? && stream.failures.empty? && status&.success?
    FileUtils.rm_f(chunk.files)
  end

  # The chunk's time beyond all its records' (starting the arena, loading
  # the networks, and any game left without a record) is shared out equally
  # among the stored games, so the rows add up to the worker's time. A
  # failure record's own time is not shared: the game is replayed.
  def add_overhead(chunk, duration)
    results = chunk.stream.results
    stored = results.select { |_, result| result.failure.nil? }.keys
    return if stored.empty?

    played = results.values.sum { |result| result.duration || 0 }
    share = [duration - played, 0].max / stored.size
    games = stored.map { |id| chunk.games.fetch(id).values_at('black', 'white') }
    store.add_duration(generation.to_i, data['round'], games, share)
  end

  def read_utf8(path)
    File.exist?(path) ? File.read(path, encoding: 'UTF-8').scrub : ''
  end

  # Stops the run for a chunk whose games did not all finish: once it
  # ended (`status`), or, `broken`, at once, as it wrote what the arena
  # never writes (the reason), so it may still run. First it sends SIGTERM
  # to the round's chunks still running, whose output would not be read
  # (they are arenas, exec'd, so the signal reaches them and they stop
  # their bots), instead of waiting out their bots' deadlines; their games
  # not yet stored stay pending too, and nothing reads their statuses, which
  # would look like Ctrl-C. Then it raises ArenaStopped with the report:
  # each game left pending and why, and the chunk's stderr. The chunk's
  # files stay in work/ until the resume empties it. The round is counted
  # from 0, as in the game IDs.
  def stop_for(chunk, status = nil, broken: nil)
    terminated = pool.terminate
    not_started = not_started(terminated, itself: broken)
    stream = chunk.stream
    reasons = []
    if broken
      reasons << broken
    else
      reasons << 'wrote no header' unless stream.header?
      reasons << 'did not finish its output' unless stream.complete? || !stream.header?
    end
    reasons << 'could not finish a game' if stream.failures.any?
    reasons << exit_reason(status) unless broken || status&.success?
    withheld = stream.results.reject { |_, result| result.failure.nil? }.map do |id, result|
      if result.failed?
        "  #{id}: #{result.end_reason} (#{result.error_side}): #{result.error_message}\n"
      else
        "  #{id}: no record\n"
      end
    end
    stderr = read_utf8(chunk.err)
    raise ArenaStopped, "Arena chunk #{chunk.name} of generation #{generation}, round #{data['round']} " \
                        "#{reasons.join(', ')}. #{withheld.size} of its #{chunk.games.size} games stay pending" \
                        "#{withheld.empty? ? '.' : ":\n#{withheld.join.chomp}"}\n" \
                        "#{stderr.empty? ? 'Its stderr is empty.' : "Its stderr:\n#{stderr.chomp}"}\n" \
                        "The games it finished are stored. #{terminated_note(terminated, not_started, itself: broken)}\n" \
                        'The run stopped; resume after fixing the cause.'
  end

  def exit_reason(status)
    if status.nil? then 'has no exit status'
    elsif status.signaled? then "was killed by #{Signal.signame(status.termsig).then { |name| "SIG#{name}" }}"
    else "exited with status #{status.exitstatus}"
    end
  end

  # How many of the round's other chunks had not started when the stop
  # halted the pool: those not yet ended that it did not signal. `itself`
  # when the stopping chunk had not ended, so it is taken to be among the
  # signalled ones (unless none was). A chunk that had ended before the
  # stop without its end read yet also counts, since the runner reads
  # nothing more; its unread records' games stay pending as well.
  def not_started(terminated, itself: false)
    others = itself ? @unended - 1 : @unended
    others_running = itself && terminated.positive? ? terminated - 1 : terminated
    [others - others_running, 0].max
  end

  # How many chunks the stop sent SIGTERM and how many had not started;
  # `itself` when the stopping chunk had not ended, so it may be one of the
  # signalled ones.
  def terminated_note(count, not_started = 0, itself: false)
    [signalled_note(count, itself:), not_started_note(not_started)].compact.join(' ')
  end

  def signalled_note(count, itself:)
    chunks = count == 1 ? 'chunk' : 'chunks'
    their = count == 1 ? 'its' : 'their'
    if itself
      return 'No chunk was still running.' if count.zero?

      return "Sent SIGTERM to #{count} #{chunks} still running, this one among them unless it had exited; " \
             "#{their} games not stored stay pending."
    end
    return 'No other chunk was running.' if count.zero?

    "Sent SIGTERM to #{count} other #{chunks} still running; #{their} games not stored stay pending too."
  end

  def not_started_note(count)
    return if count.zero?

    return '1 chunk had not started; its games stay pending.' if count == 1

    "#{count} chunks had not started; their games stay pending."
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

    show("Playing ... Game: #{current_game_in_round}/#{total_games_in_round} Round: #{current_round}/#{total_rounds} " \
         "Total: #{overall_current_game}/#{overall_total} [#{overall_percentage}%]")
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

  # SGFs and the champion are kept for every keep_every-th generation (0
  # keeps none), so lineages can be revisited at regular points.
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
  # (save_game). `champion` goes into the same transaction (save_state).
  def save_data(hash, champion: nil)
    store.save_state(generation.to_i, hash, champion:)
    @data = hash
    exit if $stop_now
  end

  def setup_initial_population
    return if data['setup_complete']

    show('Generating initial population ...')
    timings.time(:setup_breed) { create_initial_population }
    timings.time(:setup_sync) { publish_networks }
    tournament = setup_tournament
    show('Saving the setup ...')
    timings.time(:setup_save) { save_data(tournament) }
  end

  # Runs initial-population in networks/0.partial/ and records the births,
  # all in one transaction.
  def create_initial_population
    seed = Seeds.derive(experiment_seed, 'initial-population')
    command = "../../initial-population #{self.class.initial_population_arguments(settings).join(' ')}"
    prepare_partial
    Dir.chdir(partial_dir) do
      # Stop before storing anything, so generation 0 never starts short of
      # networks, as breeding does when evolve fails.
      success, output, status = run_initial_population(command)
      stop_initial_population(status)
      initial_population_failed("initial-population failed: #{command}") unless success

      networks = Dir['*.ann'].sort
      expected = settings['population_size']
      unless networks.size == expected
        initial_population_failed("initial-population wrote #{networks.size} networks, expected #{expected}: #{command}")
      end

      show('Hashing the networks ...')
      births = networks.zip(initial_genes(output, networks.size, command)).map do |network, network_genes|
        genome = timings.time(:setup_hash) { Digest::SHA256.file(network).hexdigest }
        { generation: 0, child: network, first_parent: nil, second_parent: nil, operator: 'initial',
          differs_from_first: nil, differs_from_second: nil, seed:, genome:, **network_genes }
      end
      show('Storing births ...')
      timings.time(:setup_store) { store.record_births(births) }
    end
  end

  # Ctrl-C reaches initial-population too: stop as breeding does
  # (stop_breeding), not as a failure. Nothing is stored yet, so a resume
  # runs it again.
  def stop_initial_population(status)
    exit if $stop_now
    return unless WorkerPool.interrupted?(status)

    WorkerPool.exit_interrupted('initial-population', 'it runs again on resume')
  end

  # Stops the run for an initial-population run that failed or printed
  # output the runner cannot use. Nothing is stored, so a resume runs it again.
  def initial_population_failed(reason)
    raise BreedingFailed, "#{reason}\nThe run stopped; resume after fixing the cause."
  end

  # The settings with the genes of generation 0, in initial-population's
  # argument order.
  INITIAL_GENES = %w[
    initial_copy_chance initial_weight_changes initial_weight_step initial_activation_rate initial_structure_rate
  ].freeze

  # initial-population's arguments for the experiment's generation 0, from
  # its settings alone, so the same settings give the same networks.
  def self.initial_population_arguments(settings)
    [*settings.values_at('population_size', 'board_size', 'hidden_layers', 'layer_size'),
     *settings.values_at(*INITIAL_GENES), settings['features'], settings['initial_feature_noise'],
     settings['initial_feature_step'], Seeds.derive(settings.fetch('seed'), 'initial-population')].map(&:to_s)
  end

  # Returns [success, stdout, status]; stdout has a genes line per network.
  def run_initial_population(command)
    output, status = Open3.capture2(command)
    [status.success?, output, status]
  end

  # The genes of each generation-0 network, in file order (0001.ann,
  # 0002.ann, ... sort as initial-population writes them). There must be one
  # well-formed line per network, each of the generation-0 shape and the
  # experiment's feature set.
  def initial_genes(output, count, command)
    lines = output.lines.select { |line| line.start_with?('genes') }
    unless lines.size == count
      initial_population_failed("initial-population printed #{lines.size} genes lines for #{count} networks: #{command}")
    end

    shape = [settings['hidden_layers'], settings['hidden_layers'].zero? ? 0 : settings['layer_size']]
    lines.map do |line|
      genes = parse_genes(line, command)
      unless genes.values_at(:layers, :width) == shape
        initial_population_failed("initial-population printed genes of another shape: #{line.chomp}")
      end
      unless genes[:features] == experiment_features
        initial_population_failed("initial-population printed genes of the feature set #{genes[:features]}, " \
                                  "but the experiment's is #{experiment_features}: #{line.chomp}")
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
  # Anything else stops the run (BreedingFailed).
  def parse_genes(line, command)
    genes = parse_genes_fields(line.chomp)
    initial_population_failed("malformed genes line #{line.chomp.inspect}: #{command}") if genes.nil? || genes.value?(nil)

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
    prepare_partial
    total = settings['population_size']
    timings.time(:setup_breed) do
      # Every child's parents are drawn first, in child order, so the order
      # the children finish in cannot change them.
      jobs = Array.new(total) { |i| evolve_job(previous_generation, i, Array.new(2) { select_parent(candidates) }) }
      show("Breeding population ... 0/#{total}")
      jobs.each { |job| pool.submit(job.pool_command, job) }
      births = Array.new(total) do |finished|
        job, _duration, status = pool.next_finished
        stop_breeding(job, status)
        read_child(job, status).tap { show("Breeding population ... #{finished + 1}/#{total}") }
      end
      # One transaction for all, not a commit per birth. A stop before this
      # stores none; the setup is not saved then either, so a resume breeds
      # every child again.
      show('Storing births ...')
      timings.time(:setup_store) { store.record_births(births) }
    end
    timings.time(:setup_sync) { publish_networks }
    tournament = setup_tournament
    show('Saving the setup ...')
    timings.time(:setup_save) { save_data(tournament) }
    # Only once the new setup is saved: until then a resume breeds again.
    timings.time(:setup_retire) { retire_networks(previous_generation) }
  end

  # One child's evolve run: `command` breeds `child` from `parents` (names
  # in networks/N-1/) into networks/N.partial/ as `path`. The pool runs it
  # exec'd, so WorkerPool#terminate reaches evolve, with its stdout and
  # stderr in work/ (the pool captures neither).
  EvolveJob = Struct.new(:child, :parents, :seed, :path, :command) do
    def out = "#{File.basename(child, '.ann')}.out"
    def err = "#{File.basename(child, '.ann')}.err"
    def pool_command = "exec #{command} > #{out} 2> #{err}"
  end

  def evolve_job(previous_generation, index, parents)
    child = "#{index}.ann"
    path = File.join(partial_dir, child)
    seed = Seeds.derive(experiment_seed, 'birth', generation.to_i, index)
    parent_paths = parents.map { |parent| File.join(network_dir(previous_generation), parent) }
    command = "../evolve #{evolve_arguments.join(' ')} #{parent_paths.join(' ')} #{path} #{seed}"
    EvolveJob.new(child, parents, seed, path, command)
  end

  # The birth of a child evolve finished, to be stored with the others: it
  # wrote the child into networks/N.partial/, which setup emptied, so a
  # child exists only if this evolve wrote it. Deletes the job's output
  # files. Output breeding cannot use stops it (breeding_failed).
  def read_child(job, status)
    breeding_failed(job, status, "evolve failed to breed #{job.child}") unless status&.success? && File.exist?(job.path)

    output = read_utf8(job.out)
    summary = output.match(EVOLVE_SUMMARY)
    breeding_failed(job, status, "evolve printed no summary for #{job.child}") unless summary

    genes_lines = output.lines.select { |line| line.start_with?('genes') }
    unless genes_lines.size == 1
      breeding_failed(job, status, "evolve printed #{genes_lines.size} genes lines for #{job.child}")
    end

    genes = parse_child_genes(job, status, genes_lines.first)
    genome = timings.time(:setup_hash) { Digest::SHA256.file(job.path).hexdigest }
    FileUtils.rm_f([job.out, job.err])
    { generation: generation.to_i, child: job.child, first_parent: job.parents[0], second_parent: job.parents[1],
      operator: summary[:operator], differs_from_first: differs(summary[:first]),
      differs_from_second: differs(summary[:second]), seed: job.seed, genome:, parent: summary[:parent],
      structure: summary[:structure], activation_changed: summary[:activation_changed] == '1', **genes }
  end

  def parse_child_genes(job, status, line)
    genes = parse_genes_fields(line.chomp)
    breeding_failed(job, status, "malformed genes line #{line.chomp.inspect}") if genes.nil? || genes.value?(nil)
    unless genes[:features] == experiment_features
      breeding_failed(job, status, "evolve printed genes of the feature set #{genes[:features]} for #{job.child}, " \
                                   "but the experiment's is #{experiment_features}")
    end
    genes
  end

  # Stops breeding for a child evolve did not breed as it should: first
  # sends SIGTERM to the other evolves still running (exec'd, so the signal
  # reaches them), whose children would not be recorded, then raises with
  # the command, its exit status, and its stderr. The setup is not saved,
  # so a resume breeds every child again, with the same seeds; the job's
  # files stay in work/ until then.
  def breeding_failed(job, status, reason)
    pool.terminate
    stderr = read_utf8(job.err)
    raise BreedingFailed, "#{reason}: #{job.command}\n" \
                          "evolve #{exit_reason(status)}. " \
                          "#{stderr.empty? ? 'Its stderr is empty.' : "Its stderr:\n#{stderr.chomp}"}\n" \
                          'The run stopped; a resume breeds every child again.'
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

  # Ctrl-C reaches the running evolves too. Stop as the tournament does,
  # without an error: the generation's setup is saved only after the last
  # child, so a resume breeds every child again, with the same seeds. An
  # evolve can be back before the trap has set the flag; its status tells.
  def stop_breeding(job, status)
    exit if $stop_now
    return unless WorkerPool.interrupted?(status)

    WorkerPool.exit_interrupted("breeding #{job.child}", 'breeding starts over on resume')
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

  # The version of the tournament rules: who plays whom (games_from_ranking),
  # and the scoring logic below and in ArenaResult, what counts as a win or
  # a draw and what stops the run. 4: two copies of one bot do not play each
  # other while another player is left to pair. 3: every tournament game is
  # played in the arena and scored by Tromp-Taylor; a bot that resigns
  # loses, a network out of main time loses, and a game the arena could not
  # finish stops the run instead of being scored. (2: games with a bot went
  # through gogui-twogtp and its GNU Go referee, and failed games were
  # stored without points.) Bump it when any of these rules change, so an
  # experiment begun under other rules refuses to run. The points
  # themselves are in the experiment's scoring.
  SCORING_RULES = '4'.freeze

  def setup_tournament
    data = {
      'round' => 0,
      'players' => setup_players,
      'setup_complete' => true
    }
    data['ranking'] = shuffle_ties(data['players'].keys.map { |player| { 'name' => player, 'score' => 0 } }, 0)
    data['games'] = games_from_ranking(data['ranking'], data['players'], colors_rng(0))
    data
  end

  # Pairs the ranking from the top, each player with the next one, except
  # that two copies of one bot (the same 'opponent' in `players`) do not
  # play each other: the first plays the nearest later player that is not a
  # copy of it, and the copies it passed keep their places for the next
  # pairs. Only when nothing but copies of that bot is left are they paired
  # with each other. Networks have no 'opponent', so they are never copies.
  # `random` picks each pair's colours; the odd player out gets a bye.
  def games_from_ranking(ranking, players, random = colors_rng(0))
    games = []
    ranked_players = ranking.map { |r| r['name'] }
    until ranked_players.empty?
      first = ranked_players.shift
      partner = ranked_players.index { |player| !copies?(players, first, player) } || 0
      pair = [first, *ranked_players.delete_at(partner)].shuffle(random:)
      pair << nil if pair.length == 1
      games << { 'black' => pair.first, 'white' => pair.last }
    end
    games
  end

  def copies?(players, player, other)
    opponent = players.dig(player, 'opponent')
    !opponent.nil? && opponent == players.dig(other, 'opponent')
  end

  # The experiment's opponents, each copy numbered from 1 and recording
  # which opponent it is, then the networks in networks/N/.
  def setup_players
    players = store.opponents.each_with_object({}) do |opponent, hash|
      (1..opponent[:copies]).each do |i|
        hash["#{opponent[:name]}#{i}"] = { 'command' => opponent[:command], 'external' => true,
                                           'opponent' => opponent[:name] }
      end
    end
    networks = Dir.children(network_dir(generation)).select { |name| name.end_with?('.ann') }.sort
    players.merge!(networks.to_h { |player| [player, { 'command' => "../evo #{network_path(player)}" }] })
  end
end
