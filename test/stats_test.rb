require 'minitest/autorun'
require 'csv'
require 'fileutils'
require 'open3'
require 'stringio'
require 'timeout'
require 'tmpdir'
require_relative '../ruby/experiment_database'
require_relative '../ruby/experiment_stats'
require_relative '../ruby/stats_report'
require_relative 'stats_fixture'

# Runs the stats script on the experiment in StatsFixture, and tests the
# watch loop directly.
class StatsTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  # Stops the watch loop in a test; `loop` would swallow StopIteration.
  class Done < StandardError; end

  ENV_VARS = { 'BUNDLE_GEMFILE' => File.join(ROOT, 'Gemfile') }.freeze

  def setup
    @dir = Dir.mktmpdir('evo-stats-script')
    @experiment = File.join(@dir, 'experiments/x')
    StatsFixture.create(File.join(@experiment, 'experiment.sqlite3'))
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def stats(*args)
    Open3.capture3(ENV_VARS, 'ruby', File.join(ROOT, 'stats'), *args, chdir: @dir)
  end

  def cells(line)
    line.split('|').map(&:strip)[1...-1]
  end

  # The table row that starts with the generation `generation`, as cells.
  def row(out, generation)
    line = out.lines.find { |l| l.match?(/\A\|\s*#{generation}\s*\|/) }
    assert line, "no row for generation #{generation} in\n#{out}"
    cells(line)
  end

  def test_prints_the_generation_table_once_and_exits
    out, err, status = stats('x')
    assert status.success?, err
    # Gen, done, games, draws, failed, game time, copies, parents, genomes,
    # score min, median, max.
    assert_equal %w[0 no 1 0 0 - - 0 3 1 2 3], row(out, 0).first(12)
    assert_equal %w[1 yes 4 1 1 3.8s 33% 2 3 1 4 4], row(out, 1).first(12)
    assert_equal %w[2 no 0 0 0 - - 0 0 0 2 7], row(out, 2).first(12)
    assert_equal %w[3 no], row(out, 3).first(2)
    refute_includes out, "\e[2J", 'once mode does not clear the screen'
  end

  # One row per checkpoint and opponent. Both checkpoints' benchmarks are
  # incomplete; generation 0 has played no game and plays only the bots.
  def test_prints_the_benchmark_of_each_checkpoint_by_opponent
    out, = stats('x')
    benchmark = out[out.index('Benchmark')..]
    header = cells(benchmark.lines.find { |l| l.include?('Network') })
    assert_equal %w[Gen Network Opponent Games Black White Draws Failed], header
    rows = benchmark.lines.select { |l| l.match?(/\A\|\s*\d/) }.map { |l| cells(l) }
    assert_equal [%w[0 - Brown 0/4 0-0 0-0 0 0], %w[0 - AmiGo 0/4 0-0 0-0 0 0], %w[0 - GnuGoLevel0 0/4 0-0 0-0 0 0],
                  %w[2 c.ann Brown 2/4 0-0 1-0 0 1], %w[2 c.ann AmiGo 4/4 2-0 0-1 1 0],
                  %w[2 c.ann GnuGoLevel0 0/4 0-0 0-0 0 0], %w[2 c.ann Gen0Champion 2/4 0-1 0-1 0 0]], rows
  end

  def test_once_mode_fits_in_100_columns
    out, = stats('x')
    long = out.lines.map(&:chomp).select { |l| l.size > 100 }
    assert_empty long, "lines over 100 characters:\n#{long.join("\n")}"
  end

  # Only the latest generations, and only the checkpoints among them.
  def test_the_tables_show_only_the_latest_generations
    database = ExperimentDatabase.new(File.join(@experiment, 'experiment.sqlite3'), readonly: true)
    figures = ExperimentStats::Report.figures(ExperimentStats.new(database))
    database.close
    generations = ->(text) { text.lines.grep(/\A\|\s*\d/).map { |l| cells(l).first }.uniq }
    text = ExperimentStats::Report.text(figures, limit: 3)
    assert_includes text, 'latest 3 of 4'
    generation_table, benchmark = text.split('Benchmark')
    assert_equal %w[1 2 3], generations.call(generation_table)
    assert_equal %w[2], generations.call(benchmark)
    text = ExperimentStats::Report.text(figures, limit: 1)
    assert_equal %w[3], generations.call(text)
    refute_includes text, 'Benchmark'
  end

  def test_csv_has_one_row_per_generation_with_dotted_keys
    out, err, status = stats('--csv', 'x')
    assert status.success?, err
    rows = CSV.parse(out, headers: true)
    assert_equal %w[0 1 2 3], rows.map { |r| r['generation'] }
    assert_equal %w[false true false false], rows.map { |r| r['finished'] }
    assert_equal '3.75', rows[1]['tournament.game_seconds']
    assert_equal '1', rows[1]['population.identical']
    assert_equal '2', rows[1]['population.operators.crossover']
    assert_equal '4', rows[1]['population.scores.median']
    assert_equal 'c.ann', rows[2]['benchmark.network']
    assert_equal '2', rows[2]['benchmark.AmiGo.black.win']
    assert_equal '1', rows[2]['benchmark.Brown.black.failure']
  end

  # The same columns for every experiment with the same panel, whatever it
  # has played so far.
  def test_csv_header_is_fixed_by_the_panel
    out, = stats('--csv', 'x')
    benchmark = %w[Brown AmiGo GnuGoLevel0 Gen0Champion PreviousCheckpoint].flat_map do |opponent|
      %w[black white].flat_map { |color| %w[win loss draw failure].map { |result| "benchmark.#{opponent}.#{color}.#{result}" } }
    end
    assert_equal %w[
      generation finished tournament.games tournament.draws tournament.failures tournament.game_seconds
      population.children population.operators.initial population.operators.crossover population.operators.mutation
      population.operators.copy
      population.identical population.distinct_parents population.unique_genomes
      population.scores.min population.scores.median population.scores.max benchmark.network benchmark.complete
    ] + benchmark, CSV.parse(out).first
  end

  def test_csv_leaves_the_benchmark_empty_where_there_is_none
    out, = stats('--csv', 'x')
    rows = CSV.parse(out, headers: true)
    assert_nil rows[1]['benchmark.AmiGo.black.win']
    assert_nil rows[1]['benchmark.network']
    assert_nil rows[1]['benchmark.complete']
    assert_equal 'false', rows[2]['benchmark.complete']
    # Generation 0 plays no Gen0Champion, and no checkpoint here plays the
    # previous one.
    assert_equal '0', rows[0]['benchmark.Brown.white.win']
    assert_nil rows[0]['benchmark.Gen0Champion.black.win']
    assert_nil rows[2]['benchmark.PreviousCheckpoint.black.win']
    assert_equal '0', rows[0]['population.operators.crossover']
    assert_equal '3', rows[0]['population.operators.initial']
    assert_equal '0', rows[1]['population.operators.initial']
    assert_equal '0', rows[1]['population.operators.copy']
  end

  def test_a_missing_experiment_exits_1_with_a_message
    out, err, status = stats('nope')
    assert_equal 1, status.exitstatus
    assert_includes out + err, 'nope'
    refute Dir.exist?(File.join(@dir, 'experiments/nope'))
  end

  def test_a_missing_name_exits_1_with_usage
    out, err, status = stats
    assert_equal 1, status.exitstatus
    assert_includes out + err, 'Usage'
  end

  def test_an_experiment_without_generations_says_so
    FileUtils.rm_rf(@experiment)
    FileUtils.mkdir_p(@experiment)
    db = ExperimentDatabase.new(File.join(@experiment, 'experiment.sqlite3'))
    db.save_settings('tournament_rounds' => 1, 'keep_every' => 10)
    db.close
    out, err, status = stats('x')
    assert status.success?, err
    assert_includes out, 'No generations yet'
  end

  def test_stats_writes_and_deletes_nothing
    before = Dir.glob('**/*', base: @experiment).sort
    stats('x')
    stats('--csv', 'x')
    watch_until_first_table
    assert_equal before, Dir.glob('**/*', base: @experiment).sort
  end

  def test_watch_stops_cleanly_on_ctrl_c
    status = watch_until_first_table
    assert status.success?, "exit status #{status.inspect}"
  end

  # Starts `stats --watch x`, waits for its first table, sends SIGINT, and
  # returns the exit status.
  def watch_until_first_table
    Open3.popen2e(ENV_VARS, 'ruby', File.join(ROOT, 'stats'), '--watch', 'x', chdir: @dir) do |_in, out, thread|
      output = +''
      Timeout.timeout(20) do
        output << out.readpartial(4096) until output.include?('Benchmark')
        Process.kill('INT', thread.pid)
        thread.value
      end
    end
  end

  def test_watch_redraws_after_each_pause
    database = ExperimentDatabase.new(File.join(@experiment, 'experiment.sqlite3'), readonly: true)
    io = StringIO.new
    pauses = []
    pause = lambda do |seconds|
      pauses << seconds
      raise Done if pauses.size == 2
    end
    assert_raises(Done) { ExperimentStats::Report.watch(ExperimentStats.new(database), io, pause:) }
    database.close
    assert_equal [5, 5], pauses
    assert_equal 2, io.string.scan("\e[2J\e[H").size
    assert_equal 2, io.string.scan('Benchmark').size
  end

  def test_figures_are_reused_for_generations_before_the_last
    calls = []
    fake = Object.new
    fake.define_singleton_method(:generations) { [0, 1] }
    fake.define_singleton_method(:generation) { |g| calls << g; { generation: g } }
    cache = {}
    2.times { ExperimentStats::Report.figures(fake, cache) }
    assert_equal [0, 1, 1], calls
  end
end
