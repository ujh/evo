require 'sequel'

Sequel.extension :migration

# One SQLite database per experiment (experiments/NAME/experiment.sqlite3) that
# holds every scored game, so an experiment keeps its evidence in one file
# instead of a .dat, .sgf and .err file per game. The runner writes and keeps
# the schema current with the migrations in db/migrations; stats and ranking
# open it read-only while the runner is still writing.
class ExperimentDatabase
  MIGRATIONS = File.expand_path('../db/migrations', __dir__)
  COLUMNS = %i[
    generation round black white black_external white_external
    winner failure length referee_result error_message stderr sgf duration time_black time_white
  ].freeze

  def initialize(path, readonly: false)
    # The timeout (ms) lets a reader wait while the runner writes.
    @db = Sequel.sqlite(path, readonly:, timeout: 5_000)
    Sequel::Migrator.run(@db, MIGRATIONS) unless readonly
    @games = @db[:games]
    @births = @db[:births]
    @rankings = @db[:rankings]
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

  # A network's .ann bytes. Storing it again replaces it.
  def record_network(generation, name, weights)
    @db[:networks].insert_conflict(:replace).insert(generation:, name:, weights: Sequel.blob(weights))
  end

  def network_names(generation)
    @db[:networks].where(generation:).order(:name).select_map(:name)
  end

  # Writes the generation's networks into `directory` as .ann files, for the
  # programs that read them, and returns their names.
  def export_networks(generation, directory)
    @db[:networks].where(generation:).order(:name).map do |row|
      File.binwrite(File.join(directory, row[:name]), row[:weights])
      row[:name]
    end
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
  # leaves either the old state or the new one. `retire_networks_of` deletes
  # that generation's networks in the same transaction, so parents are only
  # dropped once the generation bred from them is saved.
  def save_state(generation, state, retire_networks_of: nil)
    players = state.fetch('players', {})
    @db.transaction do
      @db[:networks].where(generation: retire_networks_of).delete if retire_networks_of
      @db[:generations].insert_conflict(:replace).insert(
        generation:, round: state.fetch('round', 0), setup_complete: state.fetch('setup_complete', false)
      )
      [@db[:players], @rankings, @db[:pending_games]].each { |table| table.where(generation:).delete }
      @db[:players].multi_insert(players.map do |name, player|
        { generation:, name:, command: player.fetch('command', ''), external: player['external'] ? true : false }
      end)
      @rankings.multi_insert(state.fetch('ranking', []).each_with_index.map do |entry, i|
        { generation:, rank: i + 1, name: entry['name'], score: entry['score'],
          external: players.dig(entry['name'], 'external') ? true : false }
      end)
      @db[:pending_games].multi_insert(state.fetch('games', []).each_with_index.map do |game, i|
        { generation:, position: i, black: game['black'] || game[:black], white: game['white'] || game[:white] }
      end)
    end
  end

  def record(**game)
    @games.insert_conflict(:replace).insert(game.slice(*COLUMNS))
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

  BIRTH_COLUMNS = %i[
    generation child first_parent second_parent operator differs_from_first differs_from_second seed genome
  ].freeze

  # A child bred again after a crash replaces its row.
  def record_birth(**birth)
    @births.insert_conflict(:replace).insert(birth.slice(*BIRTH_COLUMNS))
  end

  def births(generation)
    @births.where(generation:).order(:child).select(*BIRTH_COLUMNS).all
  end

  # The standings, as rows with rank, name, score, and external.
  def ranking(generation)
    @rankings.where(generation:).order(:rank).select(:rank, :name, :score, :external, :generation).all
  end

  def close
    @db.disconnect
  end

  private

  def read_state(generation)
    row = @db[:generations].where(generation:).first
    return nil unless row

    players = @db[:players].where(generation:).order(:name).all.to_h do |player|
      [player[:name], { 'command' => player[:command] }.merge(player[:external] ? { 'external' => true } : {})]
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
