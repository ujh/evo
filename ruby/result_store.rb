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
  end

  def record(**game)
    @games.insert_conflict(:replace).insert(game.slice(*COLUMNS))
  end

  # Every game of a generation, as hashes with the keys of `record`.
  def games(generation)
    @games.where(generation:).order(:round, :black, :white).select(*COLUMNS).all
  end

  def close
    @db.disconnect
  end
end
