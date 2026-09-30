require 'sequel'
require_relative 'feature_groups'

Sequel.extension :migration

# One SQLite database per experiment (experiments/NAME/experiment.sqlite3) that
# holds every scored game, so an experiment keeps its evidence in one file
# instead of a .dat, .sgf and .err file per game. The runner writes and keeps
# the schema current with the migrations in db/migrations; stats opens it
# read-only while the runner is still writing.
class ExperimentDatabase
  MIGRATIONS = File.expand_path('../db/migrations', __dir__)
  COLUMNS = %i[
    generation round black white black_external white_external
    winner failure length referee_result error_message stderr sgf duration time_black time_white scorer end_reason
  ].freeze
  # Who decided a game; see migration 009. The arena's Tromp-Taylor count
  # decides every tournament game; the `gnugo` rows (GoGui games refereed by
  # GNU Go) belonged to experiments that are gone.
  SCORERS = %w[tromp_taylor].freeze

  def initialize(path, readonly: false)
    # The timeout (ms) lets a reader wait while the runner writes.
    @db = Sequel.sqlite(path, readonly:, timeout: 5_000)
    Sequel::Migrator.run(@db, MIGRATIONS) unless readonly
    @games = @db[:games]
    @births = @db[:births]
    @rankings = @db[:rankings]
  end

  # The setting the archive writes into an experiment it shrank.
  ARCHIVED = 'archived'.freeze

  # The `archived` setting of the database at `path` (when it was archived),
  # or nil, read without migrating; nil too for a database without a
  # settings table.
  def self.archived_on(path, readonly:)
    db = Sequel.sqlite(path, readonly:, timeout: 5_000)
    # Not table_exists?, which takes any failed query, a hot journal's
    # included, for a missing table.
    return nil if db[:sqlite_master].where(type: 'table', name: 'settings').empty?

    db[:settings].where(key: ARCHIVED).get(:value)
  ensure
    db&.disconnect
  end

  # Settings are stored as strings.
  def settings
    @db[:settings].to_hash(:key, :value)
  end

  def save_settings(settings)
    @db.transaction do
      @db[:settings].delete
      @db[:settings].multi_insert(settings.map { |key, value| { key: key.to_s, value: value.to_s } })
    end
  end

  # Runs the block in one transaction; nested writes join it.
  def transaction(&)
    @db.transaction(&)
  end

  # The bots the experiment plays against, in order; see migration 007.
  def opponents
    @db[:opponents].order(:position).select(:name, :command, :copies).all
  end

  def save_opponents(opponents)
    @db[:opponents].multi_insert(opponents.each_with_index.map { |o, i| o.slice(:name, :command, :copies).merge(position: i) })
  end

  # The benchmark panel, in order; see migration 008.
  def benchmark_opponents
    @db[:benchmark_opponents].order(:position).select(:name, :kind, :command).all
  end

  def save_benchmark_opponents(opponents)
    @db[:benchmark_opponents].multi_insert(opponents.each_with_index.map { |o, i| o.slice(:name, :kind, :command).merge(position: i) })
  end

  SCORING_POINTS = %w[win draw bye].freeze

  # The points for a win, a draw, and a bye as Integers, and the scoring
  # logic's version as `rules`.
  def scoring
    @db[:scoring].to_hash(:key, :value).to_h { |key, value| [key, SCORING_POINTS.include?(key) ? Integer(value) : value] }
  end

  def save_scoring(scoring)
    @db[:scoring].insert_conflict(:replace).multi_insert(scoring.map { |key, value| { key: key.to_s, value: value.to_s } })
  end

  # Where the experiment's executables came from; see migration 006.
  def provenance
    @db[:provenance].to_hash(:key, :value)
  end

  def save_provenance(provenance)
    @db[:provenance].multi_insert(provenance.map { |key, value| { key: key.to_s, value: value.to_s } })
  end

  def generations
    @db[:generations].order(:generation).select_map(:generation)
  end

  # A generation's tournament state in the shape data.json had: round,
  # setup_complete, players, ranking, and games (pending, in pairing order).
  # nil for a generation that has not started.
  def state(generation)
    # One read transaction, so a reader never mixes two saves.
    @db.transaction { read_state(generation) }
  end

  # A network's .ann bytes. Storing it again replaces it. The runner stores
  # only each checkpoint's champion (save_state's `champion`); the other
  # networks live in the experiment's networks/ directory.
  def record_network(generation, name, weights)
    @db[:networks].insert_conflict(:replace).insert(generation:, name:, weights: Sequel.blob(weights))
  end

  def network_names(generation)
    @db[:networks].where(generation:).order(:name).select_map(:name)
  end

  # Writes one network to `path` and returns the path; nil, writing nothing,
  # when the generation has no such network.
  def export_network(generation, name, path)
    weights = @db[:networks].where(generation:, name:).get(:weights)
    return nil unless weights

    File.binwrite(path, weights)
    path
  end

  # Replaces the generation's whole state in one transaction, so a crash
  # leaves either the old state or the new one. `champion`, [name, bytes],
  # stores that network of the generation in the same transaction, so the
  # state that ends a checkpoint's tournament never lacks its champion.
  def save_state(generation, state, champion: nil)
    players = state.fetch('players', {})
    @db.transaction do
      record_network(generation, *champion) if champion
      @db[:generations].insert_conflict(:replace).insert(
        generation:, round: state.fetch('round', 0), setup_complete: state.fetch('setup_complete', false)
      )
      [@db[:players], @rankings, @db[:pending_games]].each { |table| table.where(generation:).delete }
      @db[:players].multi_insert(players.map do |name, player|
        { generation:, name:, command: player.fetch('command', ''), external: player['external'] ? true : false,
          opponent: player['opponent'] }
      end)
      insert_ranking(generation, state.fetch('ranking', []), players)
      @db[:pending_games].multi_insert(state.fetch('games', []).each_with_index.map do |game, i|
        { generation:, position: i, black: game['black'], white: game['white'] }
      end)
    end
  end

  # What one scored game changes in the saved state, for the runner to call
  # in the transaction that also stores the game's row. The rest of the
  # state (round, players, the other pending games) stays as it is.

  # Removes a finished game from the pending games; a bye's has no white.
  def remove_pending_game(generation, black, white)
    @db[:pending_games].where(generation:, black:, white:).delete
  end

  # Gives the player at rank `from` its new score and moves it up to rank
  # `to`, shifting the players from `to` to just above `from` down one, so
  # the ranks stay 1 to n. Win, draw, and bye points are never negative, so
  # a score only rises and a player never moves down.
  def raise_in_ranking(generation, name, score, from:, to:)
    raise ArgumentError, "#{name} would move down from rank #{from} to #{to}" if to > from

    @rankings.where(generation:, rank: to...from).update(rank: Sequel[:rank] + 1)
    @rankings.where(generation:, name:).update(rank: to, score:)
  end

  # Replaces the generation's ranking with `ranking`, in order, as
  # save_state writes it; `players` says who is external.
  def save_ranking(generation, ranking, players)
    @db.transaction do
      @rankings.where(generation:).delete
      insert_ranking(generation, ranking, players)
    end
  end

  # How a stored game ended; see migration 012. A game the arena could not
  # finish (timeout, illegal, crash, launch) is never stored.
  END_REASONS = %w[passes limit resign time network_error].freeze

  # A replayed game replaces its row. The scorer is required, so a row always
  # says who decided it, and so is the end reason, so it always says how the
  # game ended.
  def record(**game)
    unless SCORERS.include?(game[:scorer])
      raise ArgumentError, "unknown scorer #{game[:scorer].inspect}, expected one of #{SCORERS.join(', ')}"
    end
    unless END_REASONS.include?(game[:end_reason])
      raise ArgumentError, "a game cannot end by #{game[:end_reason].inspect}, expected one of #{END_REASONS.join(', ')}"
    end

    @games.insert_conflict(:replace).insert(game.slice(*COLUMNS))
  end

  # Adds `seconds` to the duration of each of `games` ([black, white]) of
  # the generation's round, in one transaction: an arena chunk's overhead,
  # shared out among the games it stored once it ends. A row at a time, by
  # its key: one statement over a whole chunk's games would nest an OR per
  # game, and SQLite limits how deep an expression may nest.
  def add_duration(generation, round, games, seconds)
    transaction do
      games.each do |black, white|
        @games.where(generation:, round:, black:, white:).update(duration: Sequel[:duration] + seconds)
      end
    end
  end

  # Every game of a generation, as hashes with the keys of `record`, or
  # only the given `columns`. A database opened read-only before the runner
  # migrated it lacks the newer columns, and its rows lack those keys.
  def games(generation, columns: COLUMNS)
    @games.where(generation:).order(:round, :black, :white).select(*(columns & @games.columns)).all
  end

  BENCHMARK_COLUMNS = %i[
    generation opponent opening network_color network opponent_network
    winner failure length referee_result error_message stderr duration time_black time_white
  ].freeze

  # A replayed benchmark game replaces its row.
  def record_benchmark_game(**game)
    @db[:benchmark_games].insert_conflict(:replace).insert(game.slice(*BENCHMARK_COLUMNS))
  end

  # A generation's benchmark games, with every column or only the given
  # `columns`.
  def benchmark_games(generation, columns: BENCHMARK_COLUMNS)
    @db[:benchmark_games].where(generation:).order(:opponent, :opening, :network_color).select(*columns).all
  end

  # A network's genes, as the genes line of initial-population and evolve
  # names them; see migration 010.
  BIRTH_GENE_COLUMNS = %i[
    layers width act_hidden act_output copy_chance weight_changes weight_step activation_rate structure_rate
  ].freeze
  # A column per move feature's weight, NULL when the network's feature
  # set lacks that feature (migration 011).
  BIRTH_FEATURE_WEIGHT_COLUMNS = FeatureGroups::GROUPS.values.flatten.map { |name| :"fw_#{name}" }.freeze
  BIRTH_COLUMNS = [
    *%i[generation child first_parent second_parent operator differs_from_first differs_from_second seed genome
        parent structure activation_changed],
    *BIRTH_GENE_COLUMNS, :features, :feature_step, *BIRTH_FEATURE_WEIGHT_COLUMNS
  ].freeze

  # A child bred again after a crash replaces its row.
  def record_birth(**birth)
    @births.insert_conflict(:replace).insert(birth.slice(*BIRTH_COLUMNS))
  end

  # A generation's births, in one transaction: all or none.
  def record_births(births)
    @db.transaction { births.each { |birth| record_birth(**birth) } }
  end

  # A database opened read-only before the runner migrated it lacks the
  # newer columns, and its rows lack those keys.
  def births(generation)
    @births.where(generation:).order(:child).select(*(BIRTH_COLUMNS & @births.columns)).all
  end

  # The standings, as rows with rank, name, score, and external.
  def ranking(generation)
    @rankings.where(generation:).order(:rank).select(:rank, :name, :score, :external, :generation).all
  end

  def close
    @db.disconnect
  end

  private

  def insert_ranking(generation, ranking, players)
    @rankings.multi_insert(ranking.each_with_index.map do |entry, i|
      { generation:, rank: i + 1, name: entry['name'], score: entry['score'],
        external: players.dig(entry['name'], 'external') ? true : false }
    end)
  end

  def read_state(generation)
    row = @db[:generations].where(generation:).first
    return nil unless row

    players = @db[:players].where(generation:).order(:name).all.to_h do |player|
      entry = { 'command' => player[:command] }
      entry['external'] = true if player[:external]
      entry['opponent'] = player[:opponent] if player[:opponent]
      [player[:name], entry]
    end
    {
      'round' => row[:round],
      'setup_complete' => row[:setup_complete],
      'players' => players,
      'ranking' => @rankings.where(generation:).order(:rank).all.map { |r| { 'name' => r[:name], 'score' => r[:score] } },
      'games' => @db[:pending_games].where(generation:).order(:position).all.map { |g| { 'black' => g[:black], 'white' => g[:white] } }
    }
  end
end
