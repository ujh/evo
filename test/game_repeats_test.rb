require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../ruby/experiment_database'
require_relative '../scripts/game-repeats'

# scripts/game-repeats.rb on a fixture database with hand-made games.
class GameRepeatsTest < Minitest::Test
  R = GameRepeats
  SCRIPT = File.expand_path('../scripts/game-repeats.rb', __dir__)
  HEAD = '(;GM[1]FF[4]SZ[9]KM[6.5]RE[B+2.5]'.freeze
  NO_MOVES = '(;GM[1]FF[4]SZ[9]KM[6.5]RE[W+R])'.freeze

  def sgf(moves) = "#{HEAD}#{moves})"

  X = ';B[aa];W[bb];B[cc]'.freeze
  Y = ';B[ee];W[];B[]'.freeze
  Z = ';B[ab];W[ba]'.freeze
  W = ';B[gg];W[hh]'.freeze
  V = ';B[ii];W[aa]'.freeze

  # Generation 10's games, [round, black, white, moves]; a, b, c and d are
  # networks, AmiGo1 and AmiGo2 copies of AmiGo, Brown1 one of Brown. The
  # rows are stored out of (round, black, white) order, and the result
  # differs in two places from what a different order would give.
  GAMES = [
    [0, 'a', 'b', X],              # original
    [1, 'c', 'd', X],              # clone repeat: another pairing
    [2, 'a', 'b', X],              # rematch: the first game's pairing again
    [0, 'c', 'd', Y],              # original
    [1, 'a', 'c', Y],              # clone repeat
    [0, 'a', 'AmiGo1', Z],         # original
    [1, 'a', 'AmiGo2', Z],         # rematch: AmiGo2 is AmiGo again
    [1, 'b', 'c', W],              # clone repeat of the game against Brown, a round earlier
    [0, 'b', 'Brown1', W],         # original, though stored later
    [3, 'c', 'd', V],              # clone repeat: 'Brown1' sorts before 'c'
    [3, 'Brown1', 'd', V],         # original
    [4, 'a', 'AmiGo1', nil],       # no moves
    [5, 'a', 'AmiGo2', nil],       # no moves, not a repeat of the one before
    [0, 'AmiGo1', 'Brown1', ';B[dd]'], # bot against bot
    [5, 'd', 'a', ';B[ff]']        # original
  ].freeze

  BOTS = { 'AmiGo1' => 'AmiGo', 'AmiGo2' => 'AmiGo', 'Brown1' => 'Brown' }.freeze

  def setup
    @dir = Dir.mktmpdir('evo-game-repeats-test')
    @path = File.join(@dir, 'experiment.sqlite3')
    store = ExperimentDatabase.new(@path)
    store.save_opponents([{ name: 'Brown', command: 'brown', copies: 1 }, { name: 'AmiGo', command: 'amigo', copies: 2 }])
    db = Sequel.sqlite(@path)
    [10, 11].each do |generation|
      db[:players].multi_insert(%w[a b c d AmiGo1 AmiGo2 Brown1].map do |name|
        { generation:, name:, command: name, external: BOTS.key?(name), opponent: BOTS[name] }
      end)
    end
    db[:games].multi_insert(GAMES.map { |round, black, white, moves| game(10, round, black, white, moves ? sgf(moves) : NO_MOVES) })
    # Generation 11 is not a checkpoint: its games kept no SGF, but one,
    # so a partial set is refused too.
    db[:games].multi_insert(GAMES.first(3).each_with_index.map do |(round, black, white, moves), i|
      game(11, round, black, white, i.zero? ? sgf(moves) : nil)
    end)
    db.disconnect
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def game(generation, round, black, white, sgf)
    { generation:, round:, black:, white:, black_external: BOTS.key?(black), white_external: BOTS.key?(white),
      winner: black, sgf:, scorer: 'tromp_taylor', end_reason: 'passes' }
  end

  def counts(generation = 10)
    db = Sequel.sqlite(@path, readonly: true)
    R.counts(db, generation)
  ensure
    db&.disconnect
  end

  def test_moves_start_at_blacks_first_move
    assert_equal ';B[aa];W[bb])', R.moves('(;GM[1]SZ[9]RE[B+1];B[aa];W[bb])')
    assert_equal ';B[];W[])', R.moves('(;GM[1]SZ[9]RE[W+1];B[];W[])')
    assert_nil R.moves(NO_MOVES)
  end

  def test_counts_clone_repeats_and_rematches_per_kind_of_game
    assert_equal({
                   'network against network' => { games: 8, no_moves: 0, clone_repeats: 4, rematches: 1 },
                   'against Brown' => { games: 2, no_moves: 0, clone_repeats: 0, rematches: 0 },
                   'against AmiGo' => { games: 4, no_moves: 2, clone_repeats: 0, rematches: 1 },
                   'bot against bot' => { games: 1, no_moves: 0, clone_repeats: 0, rematches: 0 }
                 }, counts)
  end

  def test_rows_follow_the_stored_opponents_order
    assert_equal ['network against network', 'against Brown', 'against AmiGo', 'bot against bot'], counts.keys
  end

  # In any order the first game in (round, black, white) order is the
  # original, so the totals stay as above.
  def test_the_first_game_by_round_black_and_white_is_the_original
    games = GAMES.map do |round, black, white, moves|
      { round:, black:, white:, black_external: BOTS.key?(black), white_external: BOTS.key?(white),
        sgf: moves ? sgf(moves) : NO_MOVES }
    end
    [games, games.reverse, games.shuffle(random: Random.new(1))].each do |order|
      tally = R.tally(order, BOTS)
      assert_equal 4, tally['network against network'][:clone_repeats]
      assert_equal 0, tally['against Brown'][:clone_repeats]
    end
  end

  # Three games of one pairing, two of another, one of a third: of the
  # n - 1 = 5 games that add nothing, p - 1 = 2 are clone repeats and
  # n - p = 3 rematches.
  def test_a_group_of_n_games_with_p_pairings
    games = [%w[a b], %w[a b], %w[a b], %w[c d], %w[c d], %w[b a]].each_with_index.map do |(black, white), round|
      { round:, black:, white:, black_external: false, white_external: false, sgf: sgf(X) }
    end
    assert_equal({ 'network against network' => { games: 6, no_moves: 0, clone_repeats: 2, rematches: 3 } },
                 R.tally(games, {}))
  end

  def test_refuses_a_generation_without_sgfs
    error = assert_raises(GameRepeats::Refused) { counts(11) }
    assert_match(/generation 11: 1 of 3 games kept their SGF/, error.message)
    error = assert_raises(GameRepeats::Refused) { counts(12) }
    assert_match(/generation 12 has no games/, error.message)
  end

  def test_the_table_gives_counts_and_shares
    assert_equal <<~TABLE, R.table(10, counts)
      Generation 10: 15 games

      | Kind of game | Games | No moves | Clone repeats | Rematches |
      | --- | ---: | ---: | ---: | ---: |
      | network against network | 8 | 0 (0.0 %) | 4 (50.0 %) | 1 (12.5 %) |
      | against Brown | 2 | 0 (0.0 %) | 0 (0.0 %) | 0 (0.0 %) |
      | against AmiGo | 4 | 2 (50.0 %) | 0 (0.0 %) | 1 (25.0 %) |
      | bot against bot | 1 | 0 (0.0 %) | 0 (0.0 %) | 0 (0.0 %) |
    TABLE
  end

  # Opened read-only, a mistyped path fails instead of creating an empty
  # database inside an experiment.
  def test_the_script_creates_no_database_at_a_missing_path
    missing = File.join(@dir, 'missing.sqlite3')
    _out, _err, status = Open3.capture3(RbConfig.ruby, SCRIPT, missing, '10')
    refute status.success?
    refute File.exist?(missing)
  end

  def test_the_script_prints_each_generation_and_leaves_the_database_alone
    before = File.binread(@path)
    out, err, status = Open3.capture3(RbConfig.ruby, SCRIPT, @path, '10', '10')
    assert status.success?, err
    assert_equal "#{R.table(10, counts)}\n#{R.table(10, counts)}", out
    assert_equal before, File.binread(@path)
    refute File.exist?("#{@path}-journal")
    refute File.exist?("#{@path}-wal")
  end

  def test_the_script_refuses_a_generation_without_sgfs
    _, err, status = Open3.capture3(RbConfig.ruby, SCRIPT, @path, '10', '11')
    refute status.success?
    assert_match(/generation 11: 1 of 3 games kept their SGF/, err)
  end

  def test_the_script_needs_a_generation
    _, err, status = Open3.capture3(RbConfig.ruby, SCRIPT, @path)
    refute status.success?
    assert_match(/usage/, err)
  end
end

# scripts/game-repeats.rb --without-elites on two fixture runs: elite, with
# elites (births with operator elite) stored as RunGeneration#copy_elites
# stores them, and plain, at schema 17 (no elite_share setting) without
# elites.
class GameRepeatsWithoutElitesTest < Minitest::Test
  SCRIPT = GameRepeatsTest::SCRIPT
  HEAD = GameRepeatsTest::HEAD
  X = ';B[aa];W[bb];B[cc]'.freeze
  Y = ';B[ee];W[];B[]'.freeze
  Z = ';B[ab];W[ba]'.freeze
  W = ';B[gg];W[hh]'.freeze
  V = ';B[ii];W[aa]'.freeze
  T = ';B[jj]'.freeze
  NETWORKS = %w[7.ann 12.ann 3.ann 30.ann 28.ann 29.ann].freeze
  BOTS = { 'AmiGo1' => 'AmiGo', 'AmiGo2' => 'AmiGo', 'Brown1' => 'Brown' }.freeze

  # elite's generation 10, whose elites are 28.ann and 29.ann, as
  # [round, black, white, moves], stored out of (round, black, white)
  # order. The comments give each game's part with every game counted /
  # with the elites' games left out. The games left out are those of the
  # elites with networks (as Black and as White), with bots (both colours,
  # also a game without moves) and with each other. Without them each group
  # is counted among the games left: a group's first remaining game is its
  # original.
  GENERATION_10 = [
    [2, '7.ann', '12.ann', X],      # clone repeat / clone repeat
    [0, '28.ann', '12.ann', X],     # original / left out
    [4, '28.ann', '12.ann', X],     # rematch / left out
    [1, '3.ann', '30.ann', X],      # clone repeat / original
    [3, '3.ann', '30.ann', X],      # rematch / rematch
    [1, '29.ann', '7.ann', Y],      # clone repeat / left out
    [0, '3.ann', '7.ann', Y],       # original / original
    [2, '12.ann', '30.ann', Y],     # clone repeat / clone repeat
    [3, '30.ann', 'AmiGo1', Z],     # clone repeat against AmiGo / clone repeat
    [0, '28.ann', '29.ann', Z],     # original, network against network / left out
    [2, '7.ann', 'AmiGo2', Z],      # clone repeat against AmiGo / original
    [1, '29.ann', 'AmiGo1', Z],     # clone repeat against AmiGo / left out
    [5, '30.ann', 'AmiGo2', Z],     # rematch against AmiGo / rematch
    [2, '29.ann', 'Brown1', W],     # clone repeat against Brown / left out
    [1, 'Brown1', '28.ann', W],     # original / left out: no game of the group remains
    [4, '7.ann', '3.ann', V],       # clone repeat / original, the only one left
    [3, '12.ann', '29.ann', V],     # original / left out
    [4, '28.ann', 'AmiGo2', nil],   # no moves / left out
    [5, '3.ann', 'AmiGo1', nil],    # no moves / no moves
    [0, 'Brown1', '30.ann', T],     # original / original
    [0, 'AmiGo1', 'Brown1', ';B[dd]'] # bot against bot / the same
  ].freeze

  # elite's generation 20: its elites are 3.ann and 29.ann; 28.ann, an
  # elite in generation 10, is a bred network here and its games count.
  GENERATION_20 = [
    [2, '7.ann', '29.ann', X],      # left out: it would be a clone repeat
    [0, '28.ann', '7.ann', X],      # original
    [1, '12.ann', '30.ann', X],     # clone repeat
    [0, '3.ann', '29.ann', Y],      # left out: elite against elite
    [1, 'AmiGo1', '3.ann', Z],      # left out: no game against AmiGo remains
    [2, '30.ann', 'Brown1', W]      # original
  ].freeze

  # plain's generation 10: 28.ann and 29.ann are bred networks.
  PLAIN = [
    [0, '28.ann', '12.ann', X],     # original
    [1, '3.ann', '30.ann', X],      # clone repeat
    [3, '28.ann', '12.ann', X],     # rematch
    [1, '29.ann', 'AmiGo1', Z],     # original
    [2, '7.ann', 'AmiGo2', Z],      # clone repeat
    [0, 'AmiGo1', 'Brown1', ';B[dd]'] # bot against bot
  ].freeze

  def setup
    @dir = Dir.mktmpdir('evo-game-repeats-elites-test')
    @elite = database('elite', nil, { 'elite_share' => '0.2' },
                      10 => GENERATION_10, 20 => GENERATION_20, 30 => GENERATION_20)
    @plain = database('plain', 17, {}, 10 => PLAIN)
    # Births: elite's elites as RunGeneration#copy_elites stores them, a
    # new name (child) in their generation and the carried network's name
    # in the generation before (first_parent), mostly another name, which
    # here is that of a bred network playing in the elite's generation;
    # every other network bred; elite's generation 30 has games but no
    # births.
    births(@elite, 10, { '28.ann' => '7.ann', '29.ann' => '29.ann' })
    births(@elite, 20, { '3.ann' => '28.ann', '29.ann' => '12.ann' })
    births(@plain, 10, {})
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def database(name, schema, settings, generations)
    path = File.join(@dir, name, 'experiment.sqlite3')
    FileUtils.mkdir_p(File.dirname(path))
    db = Sequel.sqlite(path)
    Sequel::Migrator.run(db, ExperimentDatabase::MIGRATIONS, **(schema ? { target: schema } : {}))
    db[:settings].multi_insert({ 'tournament_rounds' => '6', 'keep_every' => '10' }.merge(settings)
                                 .map { |key, value| { key:, value: } })
    db[:opponents].multi_insert([{ name: 'Brown', command: 'brown', copies: 1, position: 0 },
                                 { name: 'AmiGo', command: 'amigo', copies: 2, position: 1 }])
    generations.each do |generation, games|
      db[:players].multi_insert([*NETWORKS, *BOTS.keys].map do |player|
        { generation:, name: player, command: player, external: BOTS.key?(player), opponent: BOTS[player] }
      end)
      db[:games].multi_insert(games.map do |round, black, white, moves|
        { generation:, round:, black:, white:, black_external: BOTS.key?(black), white_external: BOTS.key?(white),
          winner: black, sgf: moves ? "#{HEAD}#{moves})" : GameRepeatsTest::NO_MOVES, scorer: 'tromp_taylor',
          end_reason: 'passes' }
      end)
    end
    db.disconnect
    path
  end

  # `elites` maps each elite's name to the name it had in the generation
  # before.
  def births(path, generation, elites)
    db = Sequel.sqlite(path)
    operators = %w[mutation crossover copy mutation crossover mutation]
    db[:births].multi_insert(NETWORKS.each_with_index.map do |child, i|
      if elites.key?(child)
        { generation:, child:, first_parent: elites[child], second_parent: nil, operator: 'elite', parent: 'first',
          differs_from_first: 0, structure: 'none', seed: i, genome: "g#{generation}-#{child}" }
      else
        { generation:, child:, first_parent: NETWORKS[i - 1], second_parent: NETWORKS[i - 2], operator: operators[i],
          parent: 'first', differs_from_first: 1, structure: 'none', seed: i, genome: "g#{generation}-#{child}" }
      end
    end)
    db.disconnect
  end

  def script(*args)
    Open3.capture3(RbConfig.ruby, SCRIPT, *args)
  end

  # The games left out are counted apart, and each group's repeats are
  # counted among the games left. Without the option the same games give
  # the report as before.
  def test_leaves_out_every_game_an_elite_plays
    out, err, status = script('--without-elites', @elite, '10')
    assert status.success?, err
    assert_equal <<~REPORT, out
      Generation 10: 12 of its 21 games, leaving out the 9 in which an elite plays (elites: births of generation 10 with operator elite, 2 of them)

      | Kind of game | Games | No moves | Clone repeats | Rematches |
      | --- | ---: | ---: | ---: | ---: |
      | network against network | 6 | 0 (0.0 %) | 2 (33.3 %) | 1 (16.7 %) |
      | against Brown | 1 | 0 (0.0 %) | 0 (0.0 %) | 0 (0.0 %) |
      | against AmiGo | 4 | 1 (25.0 %) | 1 (25.0 %) | 1 (25.0 %) |
      | bot against bot | 1 | 0 (0.0 %) | 0 (0.0 %) | 0 (0.0 %) |
    REPORT
  end

  def test_without_the_option_every_game_counts
    out, err, status = script(@elite, '10')
    assert status.success?, err
    assert_equal <<~REPORT, out
      Generation 10: 21 games

      | Kind of game | Games | No moves | Clone repeats | Rematches |
      | --- | ---: | ---: | ---: | ---: |
      | network against network | 11 | 0 (0.0 %) | 5 (45.5 %) | 2 (18.2 %) |
      | against Brown | 3 | 0 (0.0 %) | 1 (33.3 %) | 0 (0.0 %) |
      | against AmiGo | 6 | 2 (33.3 %) | 3 (50.0 %) | 1 (16.7 %) |
      | bot against bot | 1 | 0 (0.0 %) | 0 (0.0 %) | 0 (0.0 %) |
    REPORT
  end

  # Each generation leaves out its own elites; a kind of game none of whose
  # games is left gets no row, as a kind without games has none.
  def test_each_generation_leaves_out_its_own_elites
    out, err, status = script('--without-elites', @elite, '20', '10')
    assert status.success?, err
    assert_equal <<~REPORT, out
      Generation 20: 3 of its 6 games, leaving out the 3 in which an elite plays (elites: births of generation 20 with operator elite, 2 of them)

      | Kind of game | Games | No moves | Clone repeats | Rematches |
      | --- | ---: | ---: | ---: | ---: |
      | network against network | 2 | 0 (0.0 %) | 1 (50.0 %) | 0 (0.0 %) |
      | against Brown | 1 | 0 (0.0 %) | 0 (0.0 %) | 0 (0.0 %) |

      Generation 10: 12 of its 21 games, leaving out the 9 in which an elite plays (elites: births of generation 10 with operator elite, 2 of them)

      | Kind of game | Games | No moves | Clone repeats | Rematches |
      | --- | ---: | ---: | ---: | ---: |
      | network against network | 6 | 0 (0.0 %) | 2 (33.3 %) | 1 (16.7 %) |
      | against Brown | 1 | 0 (0.0 %) | 0 (0.0 %) | 0 (0.0 %) |
      | against AmiGo | 4 | 1 (25.0 %) | 1 (25.0 %) | 1 (25.0 %) |
      | bot against bot | 1 | 0 (0.0 %) | 0 (0.0 %) | 0 (0.0 %) |
    REPORT
  end

  # Elites are told by their births alone: plain, at schema 17, has no
  # elite_share setting and no elite births, so nothing is left out.
  def test_a_run_without_elites
    out, err, status = script('--without-elites', @plain, '10')
    assert status.success?, err
    table = <<~TABLE

      | Kind of game | Games | No moves | Clone repeats | Rematches |
      | --- | ---: | ---: | ---: | ---: |
      | network against network | 3 | 0 (0.0 %) | 1 (33.3 %) | 1 (33.3 %) |
      | against AmiGo | 2 | 0 (0.0 %) | 1 (50.0 %) | 0 (0.0 %) |
      | bot against bot | 1 | 0 (0.0 %) | 0 (0.0 %) | 0 (0.0 %) |
    TABLE
    assert_equal "Generation 10: 6 games, leaving out none: no birth of generation 10 has operator elite\n#{table}", out
    out, err, status = script(@plain, '10')
    assert status.success?, err
    assert_equal "Generation 10: 6 games\n#{table}", out
  end

  # Without births the elites cannot be told.
  def test_refuses_a_generation_without_births
    out, err, status = script('--without-elites', @elite, '10', '30')
    refute status.success?
    assert_empty out
    assert_equal "generation 30 has no births, so its elites cannot be told\n", err
    _, err, status = script('--without-elites', @elite, '40')
    refute status.success?
    assert_equal "generation 40 has no games\n", err
  end

  def test_refuses_an_unknown_option
    _, err, status = script('--without-elite', @elite, '10')
    refute status.success?
    assert_match(/invalid option: --without-elite/, err)
    assert_match(/usage/, err)
  end

  def test_leaves_the_database_alone
    before = File.binread(@elite)
    _, err, status = script('--without-elites', @elite, '10', '20')
    assert status.success?, err
    assert_equal before, File.binread(@elite)
    refute File.exist?("#{@elite}-journal")
    refute File.exist?("#{@elite}-wal")
  end
end
