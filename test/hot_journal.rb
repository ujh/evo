require 'rbconfig'

# Leaves the journals a writer killed during a transaction leaves.
# `leave_hot_journal`: a child opens the database at `path`, runs `sql` in a
# transaction, writes enough more that SQLite must sync the journal and
# spill pages into the database, and is killed with SIGKILL before it
# commits. `leave_cold_journal`: the journal of a writer killed before its
# first journal sync, a zeroed header, which SQLite ignores.
module HotJournal
  GEMFILE = File.expand_path('../Gemfile', __dir__)

  def leave_hot_journal(path, sql)
    script = "require 'bundler/setup'; require 'sqlite3'; db = SQLite3::Database.new(#{path.inspect}); " \
             "db.execute('begin'); db.execute(#{sql.inspect}); db.execute('create table hot_journal_filler(x)'); " \
             "3000.times { db.execute('insert into hot_journal_filler values (randomblob(4000))') }; " \
             'Process.kill(:KILL, $$)'
    system({ 'BUNDLE_GEMFILE' => GEMFILE }, RbConfig.ruby, '-e', script)
    raise "no journal next to #{path}" unless File.size?("#{path}-journal")
  end

  def leave_cold_journal(path)
    File.binwrite("#{path}-journal", "\0" * 512)
  end
end
