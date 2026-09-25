require 'sequel'

Sequel.extension :migration

# One SQLite database per experiment (experiments/NAME/results.sqlite3) that
# holds every scored game, so an experiment keeps its evidence in one file
# instead of a .dat, .sgf and .err file per game. The runner writes and keeps
# the schema current with the migrations in db/migrations; stats and ranking
# open it read-only while the runner is still writing.
class ResultStore
  MIGRATIONS = File.expand_path('../db/migrations', __dir__)
  COLUMNS = %i[
    generation round black white black_external white_external
    winner failure length referee_result error_message stderr sgf
  ].freeze

  def initialize(path, readonly: false)
    # The timeout (ms) lets a reader wait while the runner writes.
    @db = Sequel.sqlite(path, readonly:, timeout: 5_000)
    Sequel::Migrator.run(@db, MIGRATIONS) unless readonly
    @games = @db[:games]
    @births = @db[:births]
    @rankings = @db[:rankings]
  end

  def record(**game)
    @games.insert_conflict(:replace).insert(game.slice(*COLUMNS))
  end

  # Every game of a generation, as hashes with the keys of `record`.
  def games(generation)
    @games.where(generation:).order(:round, :black, :white).select(*COLUMNS).all
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

  # Replaces the generation's ranking, so recording it again is harmless.
  # `entries` are hashes with rank, name, score, and external.
  def record_ranking(generation, entries)
    @db.transaction do
      @rankings.where(generation:).delete
      @rankings.multi_insert(entries.map { |entry| entry.merge(generation:) })
    end
  end

  def ranking(generation)
    @rankings.where(generation:).order(:rank).select(:rank, :name, :score, :external, :generation).all
  end

  def close
    @db.disconnect
  end
end
