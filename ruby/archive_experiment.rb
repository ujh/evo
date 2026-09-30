require 'fileutils'
require 'open3'
require 'sqlite3'
require 'tmpdir'
require_relative 'arena_result'
require_relative 'experiment_database'
require_relative 'experiment_lock'

# Shrinks a finished experiment the owner will not run again
# (`mise run archive-experiment NAME`). Every table is kept whole except
# `networks`, which keeps only the champion of each kept generation that
# finished its tournament: the first network by rank that is not a bot, as
# CheckpointBenchmark#top_network picks it. Nothing of an unfinished
# generation is kept, nor networks of a generation interrupted while
# breeding. The copy gets the `archived` setting, which makes the runner
# refuse the experiment; `stats` still reads it.
#
# The original is only ever read, through a read-only ATTACH, and never
# migrated. The copy is built in a new file next to it, checked, synced,
# and renamed over it, so an archive stopped at any point before the
# rename leaves the original as it was. Then work/ and networks/ (the
# last generations' networks, which the runner keeps as files) are deleted.
class ArchiveExperiment
  # The archive cannot run, or its copy failed a check; the original is
  # unchanged.
  class Refused < StandardError; end

  DATABASE = 'experiment.sqlite3'.freeze
  # The copy being built. One left by an interrupted archive is deleted
  # when the next one starts.
  COPY = 'experiment.sqlite3.archive'.freeze

  attr_reader :dir, :out

  def initialize(experiment_dir, out: $stdout)
    @dir = File.expand_path(experiment_dir)
    @out = out
  end

  def path = File.join(dir, DATABASE)
  def copy_path = File.join(dir, COPY)
  def journal = "#{path}-journal"
  def work = File.join(dir, 'work')
  def networks = File.join(dir, 'networks')

  # `confirm` is called with the question and returns whether to go on.
  # Returns :archived, :declined, or :already_archived.
  def call(confirm:)
    raise Refused, "#{path} does not exist" unless File.exist?(path)

    lock = ExperimentLock.acquire(dir)
    raise Refused, "#{dir} is in use: a runner, or another archive, holds #{File.join(dir, ExperimentLock::FILE)}" unless lock

    remove_copy
    archive(confirm)
  ensure
    lock&.close
  end

  private

  def archive(confirm)
    db = open_copy
    original = read_original(db)
    return already_archived(db, original) if original.archived

    unless confirm.call(question(original))
      out.puts 'Nothing was changed.'
      return :declined
    end

    delete_cold_journal
    build(db, original)
    check(db, original)
    db.close
    replace(original)
    :archived
  ensure
    db&.close unless db&.closed?
    remove_copy
  end

  # A new file as main, with the original attached read-only: a read-only
  # connection cannot attach a new file, and the stored CREATE statements
  # run unqualified, so they must create into the copy.
  def open_copy
    flags = SQLite3::Constants::Open::READWRITE | SQLite3::Constants::Open::CREATE | SQLite3::Constants::Open::URI
    db = SQLite3::Database.new(copy_path, flags:)
    db.busy_timeout = 5_000
    refusing_a_hot_journal { db.execute('ATTACH DATABASE ? AS src', [read_only_uri(path)]) }
    db
  end

  # The ATTACH, or the first read after it, fails with SQLITE_READONLY
  # when a hot journal is next to the original: a read-only connection
  # cannot roll it back.
  def refusing_a_hot_journal
    yield
  rescue SQLite3::ReadOnlyException
    raise Refused, "#{journal} is a hot journal, left by a writer that was killed: open the database " \
                   'read-write once while no runner is active, which rolls it back, for example ' \
                   "sqlite3 #{path} 'pragma schema_version'; then archive again"
  end

  # A URI filename escapes %, ? and #.
  def read_only_uri(file)
    "file:#{file.gsub(/[%?#]/) { |c| format('%%%02X', c.ord) }}?mode=ro"
  end

  Original = Data.define(:settings, :tables, :schema, :champions, :size, :network_count, :archived)

  # What the copy needs from the original.
  def read_original(db)
    schema = refusing_a_hot_journal do
      db.execute('SELECT type, name, tbl_name, sql FROM src.sqlite_master WHERE sql IS NOT NULL ' \
                 "ORDER BY type = 'table' DESC, rowid")
    end
    settings = db.execute('SELECT key, value FROM src.settings').to_h
    # Internal tables (sqlite_sequence, sqlite_stat1) are not created by
    # their SQL; the experiment databases have none.
    schema = schema.reject { |_type, name| name.start_with?('sqlite_') }
    tables = schema.filter_map { |type, name| name if type == 'table' }
    Original.new(settings:, tables:, schema:, champions: champions(db, settings), size: File.size(path),
                 network_count: db.get_first_value('SELECT count(*) FROM src.networks'),
                 archived: settings[ExperimentDatabase::ARCHIVED])
  end

  # Each kept, finished generation's first network by rank, in generation
  # order, as [generation, name].
  def champions(db, settings)
    return [] if settings[ExperimentDatabase::ARCHIVED]

    keep_every = Integer(settings.fetch('keep_every'))
    return [] unless keep_every.positive?

    finished = db.execute('SELECT generation FROM src.generations WHERE round >= ? ORDER BY generation',
                          [Integer(settings.fetch('tournament_rounds'))]).flatten
    finished.select { |generation| (generation % keep_every).zero? }.map do |generation|
      name = db.get_first_value('SELECT name FROM src.rankings WHERE generation = ? AND NOT external ORDER BY rank LIMIT 1',
                                [generation])
      raise Refused, "generation #{generation} has no ranked network" unless name

      [generation, name]
    end
  end

  def already_archived(db, original)
    db.close
    out.puts "#{dir} was already archived on #{original.archived}."
    [work, networks].each do |path|
      next unless File.exist?(path)

      FileUtils.rm_rf(path)
      out.puts "Deleted the #{path} an interrupted archive left."
    end
    :already_archived
  end

  def question(original)
    generations = original.champions.map(&:first)
    kept = generations.empty? ? 'no networks' : "#{generations.size} networks, the champions of generations " \
                                                "#{generations.first}..#{generations.last} (every #{original.settings['keep_every']})"
    "Archive #{dir}? It keeps every table but networks, and of the #{original.network_count} networks only #{kept}; " \
      "it deletes #{work} and #{networks}. This cannot be undone."
  end

  # A zeroed-header journal of a writer killed before its first journal
  # sync: SQLite ignores it, and no open removes it. The read above
  # succeeded, so a journal still there is such a cold one, and the lock
  # says no writer is running.
  def delete_cold_journal
    return unless File.exist?(journal)

    File.delete(journal)
    out.puts "Deleted the cold journal #{journal}."
  end

  def build(db, original)
    %w[page_size auto_vacuum user_version].each do |pragma|
      db.execute("PRAGMA main.#{pragma} = #{Integer(db.get_first_value("PRAGMA src.#{pragma}"))}")
    end
    # A copy that is not finished is deleted, never used, so it needs no
    # journal on disk; the copy starts empty, so its journal stays small.
    db.execute('PRAGMA main.journal_mode = MEMORY')
    db.execute('PRAGMA main.synchronous = OFF')
    db.transaction do
      original.schema.each { |_type, _name, _table, sql| db.execute(sql) }
      (original.tables - ['networks']).each do |table|
        db.execute("INSERT INTO main.#{quote(table)} SELECT * FROM src.#{quote(table)}")
      end
      original.champions.each do |generation, name|
        db.execute('INSERT INTO main.networks SELECT * FROM src.networks WHERE generation = ? AND name = ?', [generation, name])
        raise Refused, "generation #{generation}'s champion #{name} has no stored network" unless db.changes == 1
      end
      db.execute('INSERT INTO main.settings (key, value) VALUES (?, ?)', [ExperimentDatabase::ARCHIVED, Time.now.to_s])
    end
  end

  def quote(identifier) = %("#{identifier.gsub('"', '""')}")

  def check(db, original)
    result = db.execute('PRAGMA main.integrity_check').flatten
    raise Refused, "the copy failed its integrity check: #{result.join('; ')}" unless result == ['ok']

    check_schema(db)
    check_rows(db, original)
    check_networks(db, original)
    play_champions(db, original)
  end

  def check_schema(db)
    query = "SELECT type, name, tbl_name, sql FROM %s.sqlite_master WHERE name NOT LIKE 'sqlite\\_%%' ESCAPE '\\' " \
            "OR type = 'index' ORDER BY name"
    raise Refused, 'the copy has another schema' unless db.execute(format(query, 'main')) == db.execute(format(query, 'src'))
  end

  def check_rows(db, original)
    (original.tables - %w[networks settings]).each do |table|
      counts = %w[main src].map { |schema| db.get_first_value("SELECT count(*) FROM #{schema}.#{quote(table)}") }
      raise Refused, "the copy's #{table} has #{counts[0]} rows, the original's #{counts[1]}" unless counts.uniq.size == 1
    end
    %w[schema_info settings].each do |table|
      rows = %w[main src].map do |schema|
        db.execute("SELECT * FROM #{schema}.#{quote(table)} ORDER BY 1").reject { |row| row[0] == ExperimentDatabase::ARCHIVED }
      end
      raise Refused, "the copy's #{table} differs from the original's" unless rows[0] == rows[1]
    end
  end

  def check_networks(db, original)
    same = db.get_first_value('SELECT count(*) FROM main.networks m JOIN src.networks s USING (generation, name) ' \
                              'WHERE m.weights = s.weights')
    total = db.get_first_value('SELECT count(*) FROM main.networks')
    return if same == original.champions.size && total == same

    raise Refused, "the copy has #{total} networks, #{same} of them as stored, for #{original.champions.size} champions"
  end

  # Each kept network, exported from the copy, plays itself once with the
  # experiment's own arena, which must give a result: the arena exits 0
  # and prints error=both for a network it cannot load.
  def play_champions(db, original)
    return if original.champions.empty?

    Dir.mktmpdir('evo-archive') do |scratch|
      ids = original.champions.map do |generation, name|
        file = "#{generation}-#{name}"
        weights = db.get_first_value('SELECT weights FROM main.networks WHERE generation = ? AND name = ?', [generation, name])
        File.binwrite(File.join(scratch, file), weights)
        ["g#{generation}", file]
      end
      File.write(File.join(scratch, 'schedule.txt'), ids.map { |id, file| "#{id} #{file} #{file}\n" }.join)
      arguments = %w[board_size komi max_moves].map { |key| original.settings.fetch(key) }
      stdout, stderr, status = begin
        Open3.capture3(File.join(dir, 'arena'), *arguments, 'schedule.txt', chdir: scratch)
      rescue SystemCallError => e
        raise Refused, "the experiment's arena cannot run: #{e.message}"
      end
      check_arena(ids.map(&:first), stdout, stderr, status)
    end
  end

  def check_arena(ids, stdout, stderr, status)
    raise Refused, "the arena failed (#{status}): #{stderr.strip}" unless status.success?

    # Read as the legacy runner read it: a game played has a result.
    chunk = ArenaResult.chunk(stdout, ids)
    chunk.results.each do |id, result|
      next if result.referee

      raise Refused, "the champion of generation #{id.delete_prefix('g')} did not play: " \
                     "#{result.error_message || result.failure}"
    end
    raise Refused, "the arena did not finish its schedule: #{stdout.lines.last.inspect}" unless chunk.complete?
  end

  def replace(original)
    File.open(copy_path) { |file| file.fsync }
    File.rename(copy_path, path)
    File.open(dir) { |directory| directory.fsync }
    FileUtils.rm_rf([work, networks])
    out.puts "Archived #{dir}: #{megabytes(original.size)} before, #{megabytes(File.size(path))} after; " \
             "kept #{original.champions.size} of #{original.network_count} stored networks and deleted #{work} " \
             "and #{networks}."
    out.puts 'A stats still reading the old file holds its space until it exits.'
  end

  def megabytes(bytes) = format('%.1f MB', bytes / 1_000_000.0)

  def remove_copy
    FileUtils.rm_f([copy_path, "#{copy_path}-journal"])
  end
end
