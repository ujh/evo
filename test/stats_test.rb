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
    # Gen, done, games, draws, game time, copies, parents, genomes, score
    # min, median, max.
    assert_equal %w[Gen Done Games Draws Time Copies Parents Genomes Min Med Max],
                 cells(out.lines.find { |l| l.include?('Done') })
    assert_equal %w[0 no 1 0 0.5s - 0 3 1 2 3], row(out, 0)
    assert_equal %w[1 yes 4 1 3.8s 33% 2 3 1 4 4], row(out, 1)
    assert_equal %w[2 no 0 0 - - 0 0 0 2 7], row(out, 2)
    assert_equal %w[3 no], row(out, 3).first(2)
    refute_includes out, "\e[2J", 'once mode does not clear the screen'
  end

  # One table for every benchmark player, from every checkpoint's games and
  # the bots' games against each other (StatsFixture), strongest first,
  # rated against AmiGo. Games and Score leave failures out.
  def test_prints_the_benchmark_ratings_of_every_player
    out, err, status = stats('x')
    assert status.success?, err
    benchmark = out[out.index('Benchmark')..]
    assert_equal 'Benchmark ratings (all checkpoints, AmiGo = 0)', benchmark.lines.first.chomp
    assert_equal %w[Rank Player Rating ± Games Score], cells(benchmark.lines.find { |l| l.include?('Player') })
    rows = benchmark.lines.select { |l| l.match?(/\A\|\s*\d/) }.map { |l| cells(l) }
    database = ExperimentDatabase.new(File.join(@experiment, 'experiment.sqlite3'), readonly: true)
    expected = ExperimentStats.new(database).benchmark_ratings[:rows]
    database.close
    assert_equal expected.map(&:player), rows.map { |r| r[1] }
    assert_equal %w[1 2 3 4 5], rows.map(&:first)
    by_player = rows.to_h { |r| [r[1], r] }
    assert_equal %w[0 -], by_player['AmiGo'][2, 2], 'the anchor'
    expected.each { |row| assert_equal [row.rating.to_s, row.margin&.to_s || '-'], by_player[row.player][2, 2] }
    assert_equal({ 'Gen2Champion' => %w[7 50%], 'AmiGo' => %w[6 58%], 'Brown' => %w[4 13%], 'Gen0Champion' => %w[2 100%],
                   'GnuGoLevel0' => %w[1 50%] }, by_player.transform_values { |r| r[4, 2] })
    note = benchmark.lines.drop_while { |l| !l.start_with?('+') }.drop_while { |l| l.start_with?('+', '|') }.join
    assert_includes note, 'about 95 %'
    assert_includes note, 'narrower than the uncertainty against AmiGo'
    assert_includes note, 'held finite only by'
  end

  # On a terminal the latest champion's row is bold, and only that row; the
  # table is no generation's, so nothing in it is grey.
  def test_the_latest_champions_row_is_bold_on_a_terminal
    database = ExperimentDatabase.new(File.join(@experiment, 'experiment.sqlite3'), readonly: true)
    stats = ExperimentStats.new(database)
    figures = ExperimentStats::Report.figures(stats)
    ratings = stats.benchmark_ratings
    database.close
    rows = ExperimentStats::Report.text(figures, ratings:, dim: true).split('Benchmark').last.lines.grep(/\A\|/).drop(1)
    bold = rows.select { |l| l.include?("\e[1m") }
    assert_equal 1, bold.size
    assert_includes bold.first, 'Gen2Champion'
    assert_equal 6, bold.first.scan("\e[1m").size, 'every cell'
    refute(rows.any? { |l| l.include?(DIM) })
    refute_includes ExperimentStats::Report.text(figures, ratings:), "\e[1m"
  end

  TITLES = /\A(Generations|Genes|Feature weights|Shapes|Breeding|Networks against bots|Benchmark)/

  # The table titled `title`: its title line up to the next table's.
  def section(out, title)
    lines = out.lines
    start = lines.index { |l| l.start_with?(title) }
    assert start, "no #{title} table in\n#{out}"
    rest = lines[(start + 1)..]
    [lines[start], *rest.take_while { |l| !l.match?(TITLES) }].join
  end

  def rows_of(text)
    text.lines.select { |l| l.start_with?('|') }.map { |l| cells(l) }.drop(1)
  end

  # Medians per generation, and the range of the latest generation with
  # births. Generations 2 and 3 have no births.
  def test_prints_the_genes_of_each_generation
    out, = stats('x')
    genes = section(out, 'Genes')
    assert_includes genes.lines.first, 'generation 1'
    assert_equal %w[Gen Copy Changes Step Act Struct Layers Width Weights], cells(genes.lines.find { |l| l.include?('Copy') })
    rows = rows_of(genes)
    assert_equal %w[0 0.01 1 0.5 0.02 0.02 1 10 6592], rows[0]
    assert_equal %w[1 0.01 2.5 0.5 0.02 0.02 1 10 6592], rows[1]
    assert_equal %w[2 - - - - - - - -], rows[2]
    assert_equal %w[min 0.005 1 0.4 0.02 0.01 1 10 6592], rows.find { |r| r.first == 'min' }
    assert_equal %w[max 0.02 4 0.6 0.02 0.03 1 11 7243], rows.find { |r| r.first == 'max' }
  end

  # feature_step and a column per move feature of the experiment's set (the
  # fixture's has no near_last), with the same medians and range.
  def test_prints_the_feature_weights_of_each_generation
    out, = stats('x')
    features = section(out, 'Feature weights')
    assert_includes features.lines.first, 'generation 1'
    assert_equal %w[Gen Step Hane Cut Edge Capture SelfAtari SavesAtari],
                 cells(features.lines.find { |l| l.include?('Step') })
    rows = rows_of(features)
    assert_equal %w[0 0.01 0.05 0.05 0.05 1 -1 0.8], rows[0]
    assert_equal %w[1 0.01 0.05 0.05 0.05 1 -1 0.8], rows[1]
    assert_equal %w[2 - - - - - - -], rows[2]
    assert_equal %w[min 0.008 0.05 0.05 0.05 0.99 -1 0.8], rows.find { |r| r.first == 'min' }
    assert_equal %w[max 0.012 0.06 0.05 0.05 1.02 -0.97 0.8], rows.find { |r| r.first == 'max' }
  end

  # Without features no network has a feature weight, and feature_step
  # never changes, so there is no table.
  def test_prints_no_feature_weights_without_features
    database = ExperimentDatabase.new(File.join(@experiment, 'experiment.sqlite3'))
    database.save_settings(StatsFixture::SETTINGS.merge('features' => 'none'))
    database.close
    out, err, status = stats('x')
    assert status.success?, err
    refute_includes out, 'Feature weights'
  end

  def test_an_experiment_without_features_exits_1_with_the_missing_setting
    database = ExperimentDatabase.new(File.join(@experiment, 'experiment.sqlite3'))
    database.save_settings(StatsFixture::SETTINGS.except('features'))
    database.close
    %w[x --csv].each do |mode|
      out, err, status = stats(*[mode, 'x'].uniq)
      assert_equal 1, status.exitstatus
      assert_empty out
      assert_equal "features is missing\n", err
    end
  end

  # A database the runner has not migrated since the benchmark's bot games
  # is refused in every mode; stats cannot migrate it.
  def test_a_database_without_the_bot_games_exits_1_in_every_mode
    Sequel.sqlite(File.join(@experiment, 'experiment.sqlite3')) { |db| db.drop_table(:benchmark_bot_games) }
    [%w[x], %w[--csv x], %w[--watch x], %w[--watch --extended x]].each do |args|
      out, err, status = stats(*args)
      assert_equal 1, status.exitstatus, args.inspect
      assert_empty out, args.inspect
      assert_equal "the database predates the benchmark's bot games (migration 016): run the experiment once to migrate it; " \
                   "an archived experiment cannot be migrated\n", err, args.inspect
    end
  end

  def test_prints_the_shapes_and_activations_of_each_generation
    out, = stats('x')
    shapes = section(out, 'Shapes')
    assert_equal %w[Gen Shapes Hidden Output], cells(shapes.lines.find { |l| l.include?('Hidden') })
    rows = rows_of(shapes)
    assert_equal ['0', '1x10 3', 'sigc 3', 'sigc 2, relu 1'], rows[0]
    assert_equal ['1', '1x10 2, 1x11 1', 'sigc 2, tanh 1', 'sigc 2, relu 1'], rows[1]
    assert_equal %w[2 - - -], rows[2]
  end

  # Bot cells: the best copy's rank, and in brackets the networks above it.
  def test_prints_breeding_and_bot_ranks_of_each_generation
    out, = stats('x')
    breeding = section(out, 'Breeding')
    assert_equal %w[Gen Kids Childless Widen Narrow Add Remove Bots Brown AmiGo],
                 cells(breeding.lines.find { |l| l.include?('Childless') })
    rows = rows_of(breeding)
    assert_equal ['0', '-', '-', '-', '-', '-', '-', '1 (0)', '1 (0)', '-'], rows[0]
    assert_equal ['1', '3', '0', '1', '0', '0', '0', '4 (3)', '4 (3)', '-'], rows[1]
    assert_equal ['2', '-', '-', '-', '-', '-', '-', '1 (0)', '1 (0)', '-'], rows[2]
  end

  # Per bot group the networks' wins of their games against it. Only generation 1 has games
  # with Brown1 (a.ann won, c.ann lost); AmiGo has no copy.
  def test_prints_the_networks_results_against_each_bot
    out, = stats('x')
    against = section(out, 'Networks against bots')
    assert_equal %w[Gen Brown AmiGo], cells(against.lines.find { |l| l.include?('Brown') })
    rows = rows_of(against)
    assert_equal [%w[0 - -], ['1', '1/2 50%', '-'], %w[2 - -], %w[3 - -]], rows
  end

  def test_once_mode_fits_in_100_columns
    out, = stats('x')
    long = out.lines.map(&:chomp).select { |l| l.size > 100 }
    assert_empty long, "lines over 100 characters:\n#{long.join("\n")}"
  end

  # Every feature weight, with numbers near 0 and 1000 in every gene cell.
  def test_the_gene_tables_of_all_features_fit_in_100_columns
    database = ExperimentDatabase.new(File.join(@experiment, 'experiment.sqlite3'), readonly: true)
    figures = ExperimentStats::Report.figures(ExperimentStats.new(database))
    database.close
    genes = ExperimentStats::GENES + [ExperimentStats::FEATURE_STEP] + ExperimentStats::FEATURE_WEIGHTS
    figures.each do |f|
      f[:genes] = genes.to_h { |gene| [gene, { min: -1.23e-05, median: 999.7, max: -0.00123 }] }
    end
    text = ExperimentStats::Report.text(figures)
    assert_includes section(text, 'Feature weights'), 'NearLast'
    ['Genes', 'Feature weights'].each do |title|
      long = section(text, title).lines.map(&:chomp).select { |l| l.size > 100 }
      assert_empty long, "#{title} lines over 100 characters:\n#{long.join("\n")}"
    end
  end

  # Three significant digits below 1000, in at most 6 characters positive
  # and 7 negative; whole numbers from 999.5.
  # The networks' wins, not their losses, of the games played.
  def test_wins_cell
    assert_equal '2/3 67%', ExperimentStats::Report.wins_cell({ games: 3, wins: 2, draws: 0 })
    assert_equal '-', ExperimentStats::Report.wins_cell(nil)
  end

  def test_numbers_keep_their_width
    {
      12.3 => '12.3', 0.5 => '0.5', 0.0123 => '0.0123', -0.0123 => '-0.0123', 0 => '0', 0.005 => '0.005',
      -0.0015 => '-0.0015', 0.00123 => '0.0012', -0.00123 => '-0.0012', -0.00999 => '-0.01',
      0.000123 => '1.2e-4', 1e-05 => '1e-5', -1.23e-05 => '-1.2e-5', 1.23e-12 => '1e-12', -1.23e-12 => '-1e-12',
      -9.96e-10 => '-1e-9', 999.4 => '999', 999.7 => '1000', -999.7 => '-1000', 12_345.6 => '12346', nil => '-'
    }.each do |value, text|
      assert_equal text, ExperimentStats::Report.number(value), "number(#{value.inspect})"
    end
  end

  # Only the latest generations; the ratings are shown whichever generations
  # are.
  def test_the_tables_show_only_the_latest_generations
    database = ExperimentDatabase.new(File.join(@experiment, 'experiment.sqlite3'), readonly: true)
    stats = ExperimentStats.new(database)
    figures = ExperimentStats::Report.figures(stats)
    ratings = stats.benchmark_ratings
    database.close
    generations = ->(text) { text.lines.grep(/\A\|\s*\d/).map { |l| cells(l).first }.uniq }
    text = ExperimentStats::Report.text(figures, ratings:, limit: 3)
    assert_includes text, 'latest 3 of 4'
    generation_table, benchmark = text.split('Benchmark')
    assert_equal %w[1 2 3], generations.call(generation_table)
    assert benchmark.start_with?(' ratings (all checkpoints')
    generation_table, benchmark = ExperimentStats::Report.text(figures, ratings:, limit: 1).split('Benchmark')
    assert_equal %w[3], generations.call(generation_table)
    assert benchmark.start_with?(' ratings (all checkpoints')
    refute_includes ExperimentStats::Report.text(figures), 'Benchmark', 'no table without ratings'
  end

  DIM = "\e[3;90m".freeze

  # With `dim`, every cell of a generation that is not done is grey and
  # italic in the tables whose figures change while it plays, but for the
  # ratings, which are no one generation's; the genome tables come
  # from births, which a generation has before it plays. In the fixture
  # generations 0 and 2 wait for their benchmarks and 3 is playing.
  def test_dim_marks_the_generations_not_done_in_the_live_tables
    database = ExperimentDatabase.new(File.join(@experiment, 'experiment.sqlite3'), readonly: true)
    stats = ExperimentStats.new(database)
    figures = ExperimentStats::Report.figures(stats)
    brief_figures = ExperimentStats::Report.figures(stats, brief: true)
    ratings = stats.benchmark_ratings
    database.close
    text = ExperimentStats::Report.text(figures, ratings:, dim: true)
    dimmed = ->(title) { rows_of(section(text, title)).reject(&:empty?).group_by { |r| r.all? { |c| c.start_with?(DIM) && c.end_with?("\e[23;39m") } } }
    ['Generations', 'Breeding', 'Networks against bots'].each do |title|
      rows = dimmed.call(title)
      assert_equal %w[0 2 3], rows[true].map { |r| r.first.delete_prefix(DIM).to_i.to_s }, title
      assert_equal %w[1], rows[false].map(&:first), title
    end
    benchmark = text[text.index('Benchmark')..].lines.select { |l| l.start_with?('|') }.drop(1)
    refute(benchmark.any? { |l| l.include?(DIM) }, 'the ratings are no generation\'s')
    %w[Genes Shapes].each { |title| refute_includes section(text, title), DIM, title }
    refute_includes ExperimentStats::Report.text(figures), DIM
    # The brief --watch greys the same rows of its two tables.
    brief = ExperimentStats::Report.brief_text(brief_figures, ratings:, dim: true)
    ['Breeding', 'Networks against bots'].each do |title|
      rows = rows_of(section(brief, title)).reject(&:empty?).group_by { |r| r.all? { |c| c.start_with?(DIM) && c.end_with?("\e[23;39m") } }
      assert_equal %w[0 2 3], rows[true].map { |r| r.first.delete_prefix(DIM).to_i.to_s }, "brief #{title}"
    end
  end

  # Piped output (not a terminal) has no escape codes.
  def test_piped_output_is_plain
    out, = stats('x')
    refute_includes out, "\e["
  end

  def test_csv_has_one_row_per_generation_with_dotted_keys
    out, err, status = stats('--csv', 'x')
    assert status.success?, err
    rows = CSV.parse(out, headers: true)
    assert_equal %w[0 1 2 3], rows.map { |r| r['generation'] }
    assert_equal %w[false true false false], rows.map { |r| r['finished'] }
    assert_equal '3.75', rows[1]['tournament.play_seconds']
    assert_equal '1', rows[1]['population.identical']
    assert_equal '2', rows[1]['population.operators.crossover']
    assert_equal '4', rows[1]['population.scores.median']
    assert_equal 'c.ann', rows[2]['benchmark.network']
    assert_equal '2', rows[2]['benchmark.AmiGo.black.win']
    assert_equal '1', rows[2]['benchmark.Brown.black.failure']
  end

  def test_csv_has_the_genome_breeding_and_bot_columns
    out, = stats('--csv', 'x')
    row = CSV.parse(out, headers: true)[1]
    assert_equal '0.5', row['genes.weight_step.median']
    assert_equal '0.005', row['genes.copy_chance.min']
    assert_equal '4.0', row['genes.weight_changes.max']
    assert_equal '11', row['shape.width.max']
    assert_equal '6592', row['shape.weights.median']
    assert_equal '0.008', row['genes.feature_step.min']
    assert_equal '0.01', row['genes.feature_step.median']
    assert_equal '1.02', row['genes.fw_capture.max']
    assert_equal '-1.0', row['genes.fw_self_atari.min']
    assert_equal '1', row['activation.hidden.tanh']
    assert_equal '0', row['activation.hidden.relu']
    assert_equal '1', row['activation.output.relu']
    assert_equal '1', row['structure.widen']
    assert_equal '2', row['structure.none']
    assert_equal %w[3 0 3], row.values_at('parents.max_children', 'parents.childless', 'parents.used')
    assert_equal %w[4 3 4 3], row.values_at('bots.best_rank', 'bots.networks_above', 'bots.Brown.best_rank',
                                            'bots.Brown.networks_above')
    assert_equal %w[2 1 0], row.values_at('against_bots.Brown.games', 'against_bots.Brown.wins',
                                          'against_bots.Brown.draws')
  end

  def test_csv_leaves_genome_cells_empty_where_a_generation_lacks_them
    out, = stats('--csv', 'x')
    rows = CSV.parse(out, headers: true)
    assert_nil rows[2]['genes.weight_step.median']
    assert_nil rows[2]['genes.feature_step.median']
    # The fixture's feature set has no near_last.
    assert_nil rows[1]['genes.fw_near_last.median']
    assert_nil rows[2]['shape.layers.median']
    assert_nil rows[2]['activation.hidden.relu']
    assert_nil rows[0]['structure.none']
    assert_nil rows[0]['parents.childless']
    assert_nil rows[1]['bots.AmiGo.best_rank']
    assert_nil rows[0]['against_bots.Brown.games']
    assert_equal '1', rows[0]['bots.Brown.best_rank']
  end

  # The same columns for every experiment with the same panel, whatever it
  # has played so far.
  def test_csv_header_is_fixed_by_the_panel
    out, = stats('--csv', 'x')
    # No checkpoint here has a past champion (generation 2's would be
    # generation 0), so PastChampions adds no columns yet.
    benchmark = %w[Brown AmiGo GnuGoLevel0 Gen0Champion].flat_map do |opponent|
      %w[black white].flat_map { |color| %w[win loss draw failure].map { |result| "benchmark.#{opponent}.#{color}.#{result}" } }
    end
    assert_equal %w[
      generation finished tournament.games tournament.draws tournament.play_seconds
      population.children population.operators.initial population.operators.crossover population.operators.mutation
      population.operators.copy
      population.identical population.distinct_parents population.unique_genomes
      population.scores.min population.scores.median population.scores.max
    ] + genome_columns + %w[
      bots.best_rank bots.networks_above bots.Brown.best_rank bots.Brown.networks_above
      bots.AmiGo.best_rank bots.AmiGo.networks_above
      against_bots.Brown.games against_bots.Brown.wins against_bots.Brown.draws
      against_bots.AmiGo.games against_bots.AmiGo.wins against_bots.AmiGo.draws
      benchmark.network benchmark.complete
    ] + benchmark, CSV.parse(out).first
  end

  def genome_columns
    activations = %w[sigmoid sigmoid_cached threshold linear tanh relu]
    [
      *%w[copy_chance weight_changes weight_step activation_rate structure_rate feature_step fw_hane fw_cut fw_edge
          fw_capture fw_self_atari fw_saves_atari fw_near_last].flat_map do |gene|
        %w[min median max].map { |key| "genes.#{gene}.#{key}" }
      end,
      *%w[layers width].flat_map { |part| %w[min median max].map { |key| "shape.#{part}.#{key}" } }, 
      *%w[min median max].map { |key| "shape.weights.#{key}" },
      *%w[hidden output].flat_map { |layer| activations.map { |name| "activation.#{layer}.#{name}" } },
      *%w[none widen narrow add_layer remove_layer].map { |op| "structure.#{op}" },
      'parents.max_children', 'parents.childless', 'parents.used'
    ]
  end

  def test_csv_leaves_the_benchmark_empty_where_there_is_none
    out, = stats('--csv', 'x')
    rows = CSV.parse(out, headers: true)
    assert_nil rows[1]['benchmark.AmiGo.black.win']
    assert_nil rows[1]['benchmark.network']
    assert_nil rows[1]['benchmark.complete']
    assert_equal 'false', rows[2]['benchmark.complete']
    # Generation 0 plays no Gen0Champion.
    assert_equal '0', rows[0]['benchmark.Brown.white.win']
    assert_nil rows[0]['benchmark.Gen0Champion.black.win']
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

  # --csv is no table to redraw, and without --watch every table is shown
  # already.
  def test_extended_without_watch_or_watch_with_csv_exits_1_with_usage
    [%w[--csv --watch x], %w[--extended x], %w[--csv --extended x]].each do |args|
      out, err, status = stats(*args)
      assert_equal 1, status.exitstatus, args.inspect
      assert_includes out + err, 'Usage', args.inspect
      assert_includes out + err, '--extended', args.inspect
    end
  end

  # --watch shows only the breeding and bots, the networks against bots,
  # and the ratings tables, for the latest generations, as the once mode
  # shows them, with a note that --extended shows the rest.
  def test_watch_shows_only_the_bot_tables_and_the_ratings
    out, err, status = stats('x')
    assert status.success?, err
    database = ExperimentDatabase.new(File.join(@experiment, 'experiment.sqlite3'), readonly: true)
    io = StringIO.new
    watch(ExperimentStats.new(database), io)
    database.close
    brief = io.string.split(ExperimentStats::Report::CLEAR).last
    assert_equal ['Breeding', 'Networks against bots', 'Benchmark'], brief.lines.grep(TITLES).map { |l| l[TITLES] }
    assert_includes brief.lines.first, '--extended'
    ['Breeding', 'Networks against bots'].each { |title| assert_equal section(out, title), section(brief, title), title }
    assert_equal section(out, 'Benchmark'), section(brief, 'Benchmark').sub(/\nUpdated .*\n\z/, ''), 'Benchmark'
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
    io = StringIO.new
    database = ExperimentDatabase.new(File.join(@experiment, 'experiment.sqlite3'), readonly: true)
    watch(ExperimentStats.new(database), io)
    database.close
    assert_includes io.string, "#{ExperimentStats::Report::CLEAR}No generations yet.\n", 'in --watch too'
  end

  def test_stats_writes_and_deletes_nothing
    before = Dir.glob('**/*', base: @experiment).sort
    stats('x')
    stats('--csv', 'x')
    watch_until_first_table
    assert_equal before, Dir.glob('**/*', base: @experiment).sort
  end

  def test_watch_stops_cleanly_on_ctrl_c
    status, = watch_until_first_table
    assert status.success?, "exit status #{status.inspect}"
  end

  # --watch is brief, --watch --extended shows every table.
  def test_watch_shows_every_table_with_extended
    _, brief = watch_until_first_table
    refute_includes brief, 'Generations'
    status, extended = watch_until_first_table('--extended')
    assert status.success?, "exit status #{status.inspect}"
    %w[Generations Genes Shapes Breeding].each { |title| assert_includes extended, title }
  end

  # Starts `stats --watch x` with `options`, waits for its ratings table,
  # sends SIGINT, and returns the exit status and the output.
  def watch_until_first_table(*options)
    Open3.popen2e(ENV_VARS, 'ruby', File.join(ROOT, 'stats'), '--watch', *options, 'x', chdir: @dir) do |_in, out, thread|
      output = +''
      Timeout.timeout(20) do
        output << out.readpartial(4096) until output.include?('Ctrl-C')
        Process.kill('INT', thread.pid)
        [thread.value, output]
      end
    end
  end

  # Brief every 5 s, extended every 30 s.
  def test_watch_redraws_after_each_pause
    database = ExperimentDatabase.new(File.join(@experiment, 'experiment.sqlite3'), readonly: true)
    { false => 5, true => 30 }.each do |extended, interval|
      io = StringIO.new
      pauses = watch(ExperimentStats.new(database), io, extended:)
      assert_equal [interval, interval], pauses
      assert_equal 2, io.string.scan("\e[2J\e[H").size
      assert_equal 2, io.string.scan('Benchmark ratings').size
      assert_equal extended ? 2 : 0, io.string.scan('Generations').size
      assert_equal extended ? 2 : 0, io.string.scan('Genes').size
      assert_equal 2, io.string.scan('Breeding and bots').size
      refute_includes io.string, DIM, 'a StringIO is no terminal'
    end
    database.close
  end

  # Runs the watch loop on `stats` for two draws; returns the pauses.
  def watch(stats, io, **options)
    pauses = []
    pause = lambda do |seconds|
      pauses << seconds
      raise Done if pauses.size == 2
    end
    assert_raises(Done) { ExperimentStats::Report.watch(stats, io, pause:, **options) }
    pauses
  end

  NOT_CONVERGED = 'Benchmark ratings: the fit did not converge (no fit after 50 Newton steps)'.freeze

  # A fit that does not converge is a line in place of the ratings table,
  # and the other tables are still shown.
  def test_a_fit_that_does_not_converge_is_a_line_in_place_of_the_ratings
    database = ExperimentDatabase.new(File.join(@experiment, 'experiment.sqlite3'), readonly: true)
    stats = ExperimentStats.new(database)
    stats.define_singleton_method(:benchmark_ratings) { raise BenchmarkRatings::NotConverged, 'no fit after 50 Newton steps' }
    ratings = ExperimentStats::Report.ratings(stats)
    [ExperimentStats::Report.text(ExperimentStats::Report.figures(stats), ratings:),
     ExperimentStats::Report.brief_text(ExperimentStats::Report.figures(stats, brief: true), ratings:)].each do |text|
      assert_equal NOT_CONVERGED, text.lines.last.chomp
      assert_includes text, 'Networks against bots'
      refute_includes text, 'Rank'
    end
    [false, true].each do |extended|
      io = StringIO.new
      watch(stats, io, extended:)
      assert_equal 2, io.string.scan(NOT_CONVERGED).size, 'watch goes on'
    end
    database.close
  end

  # Brief figures only of the latest generations, and only the brief ones.
  def test_brief_figures_are_of_the_latest_generations_only
    calls = []
    fake = Object.new
    fake.define_singleton_method(:generations) { (0..14).to_a }
    fake.define_singleton_method(:generation) { |_| raise 'full figures computed' }
    fake.define_singleton_method(:brief_generation) { |g| calls << g; { generation: g } }
    cache = {}
    assert_equal (5..14).to_a, ExperimentStats::Report.figures(fake, cache, brief: true).map { |f| f[:generation] }
    ExperimentStats::Report.figures(fake, cache, brief: true)
    assert_equal (5..14).to_a + [14], calls
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
