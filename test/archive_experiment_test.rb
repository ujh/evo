require 'minitest/autorun'
require 'digest'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'stringio'
require 'timeout'
require 'sequel'
require 'tmpdir'
require_relative '../ruby/archive_experiment'
require_relative '../ruby/setup_experiment'
require_relative 'hot_journal'
require_relative 'stats_fixture'

# Archives the experiment of StatsFixture, grown to six generations: 0 and
# 2 are finished checkpoints (keep_every 2), whose first networks by rank
# are c.ann (after the bot Brown1) and a.ann; 1 and 3 are no checkpoints
# (3 is unfinished); 4 is a checkpoint still in its first round; 5 has
# networks but no generations row, as after a crash while breeding. Every
# generation has networks. The experiment's arena is a shell script that
# logs what it was given.
class ArchiveExperimentTest < Minitest::Test
  include HotJournal

  ROOT = File.expand_path('..', __dir__)
  ENV_VARS = { 'BUNDLE_GEMFILE' => File.join(ROOT, 'Gemfile') }.freeze
  CHAMPIONS = { [0, 'c.ann'] => 'net-0-c.ann', [2, 'a.ann'] => 'net-2-a.ann' }.freeze

  def setup
    @root = Dir.mktmpdir('evo-archive-test')
    @dir = File.join(@root, 'experiments/x')
    create_experiment(@dir)
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def database_path(dir = @dir) = File.join(dir, 'experiment.sqlite3')
  def arena_log(dir = @dir) = File.join(dir, 'arena.log')

  def create_experiment(dir, keep_every: 2)
    path = database_path(dir)
    StatsFixture.create(path)
    db = ExperimentDatabase.new(path)
    db.save_settings(db.settings.merge('keep_every' => keep_every, 'komi' => '6.5', 'max_moves' => '200'))
    players = StatsFixture::PLAYERS
    db.save_ranking(2, [['a.ann', 9], ['Brown1', 7], ['c.ann', 2], ['b.ann', 0]].map { |name, score| { 'name' => name, 'score' => score } },
                    players)
    db.save_state(4, { 'round' => 1, 'setup_complete' => true, 'players' => players,
                       'ranking' => %w[a.ann b.ann c.ann Brown1].map { |name| { 'name' => name, 'score' => 0 } } })
    (0..5).each do |generation|
      %w[a.ann b.ann c.ann].each { |name| db.record_network(generation, name, "net-#{generation}-#{name}") }
    end
    db.close
    FileUtils.mkdir_p(File.join(dir, 'work/parents'))
    File.write(File.join(dir, 'work/parents/0.ann'), 'scratch')
    FileUtils.mkdir_p(File.join(dir, 'networks/4'))
    File.write(File.join(dir, 'networks/4/a.ann'), 'net-4-a.ann')
    install_arena(dir, :plays)
  end

  # The experiment's arena: it logs its arguments and each network it was
  # given, then plays every game (:plays), plays them but ends without its
  # trailer (:no_trailer), cannot load the networks (:cannot_load), or
  # signals that it started and hangs (:hangs).
  def install_arena(dir, mode)
    log = arena_log(dir)
    record = case mode
             when :plays, :no_trailer then %(printf '%s\\tresult=B+6.5\\tend=passes\\tlength=2\\ttime_black=0.000001\\ttime_white=0.000001\\tduration=0.000002\\tmoves=pass,pass\\tok\\n' "$id")
             when :cannot_load then %(printf '%s\\terror=both\\tmessage=cannot read %s\\tok\\n' "$id" "$black")
             end
    script = if mode == :hangs
               "#!/bin/sh\ntouch '#{dir}/arena.started'\nexec sleep 60\n"
             else
               <<~SH
                 #!/bin/sh
                 echo "$*" >> '#{log}'
                 n=0
                 while read id black white; do
                   { cat "$black"; echo " as black"; cat "$white"; echo " as white"; } >> '#{log}'
                   #{record}
                   n=$((n + 1))
                 done < "$4"
                 #{mode == :no_trailer ? 'exit 0' : 'echo "done $n"'}
               SH
             end
    File.write(File.join(dir, 'arena'), script)
    File.chmod(0o755, File.join(dir, 'arena'))
  end

  def archive(dir = @dir, confirm: ->(_question) { true })
    ArchiveExperiment.new(dir, out: StringIO.new).call(confirm:)
  end

  def sha(path) = Digest::SHA256.file(path).hexdigest

  def read(dir = @dir)
    db = Sequel.sqlite(database_path(dir), readonly: true)
    yield db
  ensure
    db&.disconnect
  end

  def networks(dir = @dir)
    read(dir) { |db| db[:networks].order(:generation, :name).to_hash(%i[generation name], :weights) }
  end

  TABLES = %i[schema_info games births rankings settings generations players pending_games provenance opponents
              scoring benchmark_opponents benchmark_games].freeze

  def row_counts(dir = @dir)
    read(dir) { |db| TABLES.to_h { |table| [table, db[table].count] } }
  end

  def stats(dir_name = 'x')
    out, err, status = Open3.capture3(ENV_VARS, RbConfig.ruby, File.join(ROOT, 'stats'), dir_name, chdir: @root)
    assert status.success?, err
    out
  end

  def test_only_each_kept_finished_generations_first_network_is_kept
    assert_equal :archived, archive
    assert_equal CHAMPIONS, networks
    refute File.exist?(File.join(@dir, 'work')), 'work/ is deleted'
    refute File.exist?(File.join(@dir, 'networks')), 'networks/ is deleted'
    refute File.exist?(File.join(@dir, ArchiveExperiment::COPY))
  end

  def test_every_other_table_keeps_its_rows_and_the_copy_is_marked_archived
    before = row_counts
    settings = read { |db| db[:settings].to_hash(:key, :value) }
    version = read { |db| db[:schema_info].select_map(:version) }
    archive
    assert_equal before.merge(settings: before[:settings] + 1), row_counts
    after = read { |db| db[:settings].to_hash(:key, :value) }
    assert_equal settings, after.except('archived')
    assert after['archived'], 'no archived setting'
    read { |db| assert_equal version, db[:schema_info].select_map(:version) }
  end

  def test_stats_prints_the_same_after_the_archive
    before = stats
    archive
    assert_equal before, stats
  end

  def test_the_runner_refuses_an_archived_experiment
    archive
    error = assert_raises(SetupExperiment::Refused) { capture_io { SetupExperiment.call(@dir) { flunk } } }
    assert_includes error.message, 'archived'
  end

  def test_each_champion_plays_itself_with_the_experiments_arena
    archive
    assert_equal ['9 6.5 200 schedule.txt', 'net-0-c.ann as black', 'net-0-c.ann as white',
                  'net-2-a.ann as black', 'net-2-a.ann as white'], File.readlines(arena_log, chomp: true)
  end

  # An archive whose copy goes wrong after it is built: `fault` gets the
  # connection (the copy as main, the original as src) and spoils the copy,
  # which the checks must catch.
  class FaultyArchive < ArchiveExperiment
    def initialize(dir, fault)
      super(dir, out: StringIO.new)
      @fault = fault
    end

    private

    def build(db, original)
      super
      @fault.call(db)
    end
  end

  # Archiving refuses with `message`, and leaves the original as it was
  # and no copy behind.
  def assert_refused_untouched(message, &)
    before = sha(database_path)
    error = assert_raises(ArchiveExperiment::Refused, &)
    assert_includes error.message, message
    assert_equal before, sha(database_path)
    assert File.exist?(File.join(@dir, 'work/parents/0.ann'))
    assert File.exist?(File.join(@dir, 'networks/4/a.ann'))
    refute File.exist?(File.join(@dir, ArchiveExperiment::COPY))
    refute File.exist?(arena_log), 'the arena ran before the copy was checked'
  end

  def archive_with_fault(&fault)
    FaultyArchive.new(@dir, fault).call(confirm: ->(_) { true })
  end

  def test_a_copy_that_fails_its_integrity_check_is_refused
    assert_refused_untouched('integrity check') do
      archive_with_fault do |db|
        # An index whose stored SQL no longer matches its entries.
        db.execute('CREATE TABLE main.spoiled (a, b)')
        db.execute('CREATE INDEX main.spoiled_a ON spoiled (a)')
        db.execute('INSERT INTO main.spoiled VALUES (1, 2)')
        version = db.get_first_value('PRAGMA main.schema_version')
        db.execute('PRAGMA writable_schema = 1')
        db.execute("UPDATE main.sqlite_master SET sql = 'CREATE INDEX spoiled_a ON spoiled (b)' WHERE name = 'spoiled_a'")
        db.execute("PRAGMA main.schema_version = #{version + 1}")
        db.execute('PRAGMA writable_schema = 0')
      end
    end
  end

  def test_a_copy_with_another_schema_is_refused
    assert_refused_untouched('another schema') do
      archive_with_fault { |db| db.execute('CREATE INDEX main.games_by_winner ON games (winner)') }
    end
  end

  def test_a_copy_missing_rows_is_refused
    assert_refused_untouched("the copy's games has 4 rows, the original's 5") do
      archive_with_fault { |db| db.execute('DELETE FROM main.games WHERE rowid = (SELECT min(rowid) FROM main.games)') }
    end
  end

  def test_a_copy_with_other_settings_is_refused
    assert_refused_untouched("the copy's settings differs") do
      archive_with_fault { |db| db.execute("UPDATE main.settings SET value = '3' WHERE key = 'keep_every'") }
    end
  end

  def test_a_copy_whose_network_differs_from_the_stored_one_is_refused
    assert_refused_untouched('1 of them as stored, for 2 champions') do
      archive_with_fault { |db| db.execute("UPDATE main.networks SET weights = x'00' WHERE generation = 0") }
    end
  end

  def test_a_copy_with_a_network_that_is_no_champion_is_refused
    assert_refused_untouched('the copy has 3 networks') do
      archive_with_fault { |db| db.execute("INSERT INTO main.networks SELECT * FROM src.networks WHERE generation = 1 AND name = 'a.ann'") }
    end
  end

  def test_a_champion_without_a_stored_network_is_refused
    read_write { |db| db[:networks].where(generation: 2, name: 'a.ann').delete }
    assert_refused_untouched("generation 2's champion a.ann has no stored network") { archive }
  end

  def test_a_kept_generation_without_a_ranked_network_is_refused
    read_write { |db| db[:rankings].where(generation: 2, external: false).delete }
    assert_refused_untouched('generation 2 has no ranked network') { archive }
  end

  def read_write
    db = Sequel.sqlite(database_path)
    yield db
  ensure
    db&.disconnect
  end

  def test_a_champion_that_cannot_be_loaded_leaves_the_original_as_it_was
    install_arena(@dir, :cannot_load)
    before = sha(database_path)
    error = assert_raises(ArchiveExperiment::Refused) { archive }
    assert_includes error.message, 'generation 0'
    assert_includes error.message, 'cannot read 0-c.ann'
    assert_equal before, sha(database_path)
    assert File.exist?(File.join(@dir, 'work/parents/0.ann'))
    refute File.exist?(File.join(@dir, ArchiveExperiment::COPY))
  end

  def test_an_arena_output_without_its_trailer_refuses_the_archive
    install_arena(@dir, :no_trailer)
    before = sha(database_path)
    error = assert_raises(ArchiveExperiment::Refused) { archive }
    assert_includes error.message, 'did not finish'
    assert_equal before, sha(database_path)
  end

  def test_a_held_lock_refuses_the_archive
    lock = ExperimentLock.acquire(@dir)
    before = sha(database_path)
    error = assert_raises(ArchiveExperiment::Refused) { archive }
    assert_includes error.message, ExperimentLock::FILE
    assert_equal before, sha(database_path)
    refute File.exist?(arena_log)
  ensure
    lock&.close
  end

  def test_a_hot_journal_refuses_the_archive_and_says_how_to_fix_it
    leave_hot_journal(database_path, "update settings set value = 'broken'")
    before = [sha(database_path), sha("#{database_path}-journal")]
    error = assert_raises(ArchiveExperiment::Refused) { archive }
    assert_includes error.message, 'hot journal'
    assert_includes error.message, "sqlite3 #{database_path} 'pragma schema_version'"
    assert_equal before, [sha(database_path), sha("#{database_path}-journal")]
    refute File.exist?(File.join(@dir, ArchiveExperiment::COPY))
  end

  def test_a_cold_journal_is_deleted
    leave_cold_journal(database_path)
    assert_equal :archived, archive
    refute File.exist?("#{database_path}-journal")
    assert_equal CHAMPIONS, networks
  end

  # Killed while it checks the copy: the original is as it was, and the
  # next archive replaces the copy the killed one left.
  def test_an_interrupted_archive_leaves_the_original_as_it_was
    install_arena(@dir, :hangs)
    before = sha(database_path)
    script = "require 'bundler/setup'; require #{File.join(ROOT, 'ruby/archive_experiment').inspect}; " \
             "ArchiveExperiment.new(#{@dir.inspect}, out: File.open(File::NULL, 'w')).call(confirm: ->(_) { true })"
    pid = Process.spawn(ENV_VARS, RbConfig.ruby, '-e', script, pgroup: true)
    Timeout.timeout(30) { sleep 0.05 until File.exist?(File.join(@dir, 'arena.started')) }
    Process.kill(:KILL, -pid)
    Process.wait(pid)
    assert_equal before, sha(database_path)
    assert File.exist?(File.join(@dir, ArchiveExperiment::COPY)), 'the killed archive left no copy'
    assert File.exist?(File.join(@dir, 'work/parents/0.ann'))

    install_arena(@dir, :plays)
    assert_equal :archived, archive
    assert_equal CHAMPIONS, networks
    refute File.exist?(File.join(@dir, ArchiveExperiment::COPY))
  end

  def test_declining_changes_nothing
    before = sha(database_path)
    question = nil
    assert_equal :declined, archive(confirm: ->(text) { question = text; false })
    assert_includes question, 'generations 0..2'
    assert_includes question, 'cannot be undone'
    assert_includes question, "it deletes #{File.join(@dir, 'work')} and #{File.join(@dir, 'networks')}"
    assert_equal before, sha(database_path)
    assert File.exist?(File.join(@dir, 'work'))
    assert File.exist?(File.join(@dir, 'networks'))
    refute File.exist?(File.join(@dir, ArchiveExperiment::COPY))
  end

  def test_keep_every_0_keeps_no_network
    FileUtils.rm_rf(@dir)
    create_experiment(@dir, keep_every: 0)
    assert_equal :archived, archive
    assert_empty networks
    refute File.exist?(arena_log), 'nothing to play'
  end

  def test_an_archived_experiment_is_not_archived_again
    archive
    before = sha(database_path)
    FileUtils.mkdir_p(File.join(@dir, 'work'))
    FileUtils.mkdir_p(File.join(@dir, 'networks/5'))
    assert_equal :already_archived, archive(confirm: ->(_) { flunk })
    assert_equal before, sha(database_path)
    refute File.exist?(File.join(@dir, 'work'))
    refute File.exist?(File.join(@dir, 'networks'))
  end

  def test_a_directory_name_that_a_uri_would_misread
    odd = File.join(@root, 'experiments', 'odd %3F #? name')
    create_experiment(odd)
    assert_equal :archived, archive(odd)
    assert_equal CHAMPIONS, networks(odd)
  end

  def script(*arguments, stdin: '')
    Open3.capture3(ENV_VARS, RbConfig.ruby, File.join(ROOT, 'archive-experiment'), *arguments, chdir: @root,
                                                                                               stdin_data: stdin)
  end

  def test_the_script_asks_before_it_archives
    before = sha(database_path)
    out, _err, status = script('x', stdin: "no\n")
    refute status.success?
    assert_includes out, 'Type yes'
    assert_equal before, sha(database_path)

    out, err, status = script('x', stdin: "yes\n")
    assert status.success?, err
    assert_includes out, 'Archived'
    assert_equal CHAMPIONS, networks
  end

  def test_the_script_archives_without_asking_given_yes
    out, err, status = script('x', '--yes')
    assert status.success?, err
    refute_includes out, 'Type yes'
    assert_equal CHAMPIONS, networks
  end

  def test_the_script_reports_a_refusal
    lock = ExperimentLock.acquire(@dir)
    _out, err, status = script('x', '--yes')
    refute status.success?
    assert_includes err, 'in use'
    assert_includes err, 'Nothing was changed'
  ensure
    lock&.close
  end
end
