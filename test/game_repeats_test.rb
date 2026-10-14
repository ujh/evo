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
