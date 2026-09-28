require 'minitest/autorun'
require_relative '../scripts/compare-arena-scoring'

# The pure parts of scripts/compare-arena-scoring.rb: reading twogtp's SGF
# moves and the arena's records, the Tromp–Taylor count with and without
# GNU Go's dead stones, and why a referee result differs.
class CompareArenaScoringTest < Minitest::Test
  C = CompareArenaScoring

  def test_reads_sgf_moves_as_the_arena_writes_them
    sgf = "(;FF[4]SZ[9]C[B[aa] in a comment\n];B[aa];W[ii]\n;B[];W[tt];B[ei])"
    assert_equal %w[A9 J1 pass pass E1], C.sgf_moves(sgf, 9)
  end

  def test_a_game_without_moves_has_none
    assert_equal [], C.sgf_moves('(;FF[4]SZ[9]RE[W+R])', 9)
  end

  def test_tromp_taylor_counts_stones_and_regions_that_touch_one_color
    # A black wall on column C, a white one on column E: A–B belong to
    # black (18 + 9 stones), F–J to white (36 + 9), column D is neutral.
    black = (1..9).map { |y| "C#{y}" }
    white = (1..9).map { |y| "E#{y}" }
    assert_equal 'W+24.5', C.tromp_taylor(9, 6.5, black, white)
  end

  def test_tromp_taylor_counts_a_dead_stone_for_its_owner
    # One white stone in black's area left of the wall makes that area
    # neutral: black has its 9 stones and the 54 points right of the wall.
    black = (1..9).map { |y| "C#{y}" }
    assert_equal 'B+55.5', C.tromp_taylor(9, 6.5, black, %w[A1])
    assert_equal 'B+74.5', C.tromp_taylor(9, 6.5, black, %w[A1], dead: %w[A1])
  end

  def test_an_empty_board_is_komi_for_white
    assert_equal 'W+6.5', C.tromp_taylor(9, 6.5, [], [])
    assert_equal '0', C.tromp_taylor(9, 0, [], [])
  end

  def test_margin_is_black_minus_white
    assert_in_delta 3.5, C.margin('B+3.5')
    assert_in_delta(-0.5, C.margin('W+0.5'))
    assert_in_delta 0.0, C.margin('0')
    assert_nil C.margin('B+R')
  end

  def test_winner
    assert_equal 'B', C.winner('B+R')
    assert_equal 'W', C.winner('W+2.5')
    assert_equal '0', C.winner('0')
  end

  def test_twogtp_end_from_the_referee_and_the_error
    assert_equal 'resign', C.twogtp_end(GameResult.new(referee: 'W+R'))
    assert_equal 'limit', C.twogtp_end(GameResult.new(referee: 'B+3.5', error_message: GameResult::MOVE_LIMIT))
    assert_equal 'passes', C.twogtp_end(GameResult.new(referee: 'B+3.5', error_message: ''))
  end

  def test_parses_played_records_and_refuses_failure_records
    text = "arena protocol 3 ready\n" \
           "g1\tresult=B+3.5\tend=passes\tlength=3\ttime_black=0.1\ttime_white=0.2\tduration=0.3\t" \
           "moves=E5,pass,pass\tok\n" \
           "g2\tresult=W+R\tend=resign\tlength=0\ttime_black=0.1\ttime_white=0.0\tduration=0.1\tmoves=\tok\n" \
           "done 2\n"
    games = C.parse_arena(text, %w[g1 g2])
    assert_equal({ result: 'B+3.5', end: 'passes', moves: %w[E5 pass pass] }, games['g1'])
    assert_equal({ result: 'W+R', end: 'resign', moves: [] }, games['g2'])

    failed = "arena protocol 3 ready\ng1\tend=timeout\terror=white\tlength=0\ttime_black=0\ttime_white=0\t" \
             "duration=0\tmoves=\tmessage=slow\tok\n"
    assert_raises(C::ArenaFailed) { C.parse_arena(failed, %w[g1]) }
    assert_raises(C::ArenaFailed) { C.parse_arena("arena protocol 3 ready\ndone 1\n", %w[g1]) }
  end

  def test_filling_dame_gives_the_side_to_move_the_odd_point
    assert_equal 'B+2.5', C.fill_dame('B+1.5', 1, 'black')
    assert_equal 'B+0.5', C.fill_dame('B+1.5', 3, 'white')
    assert_equal 'B+1.5', C.fill_dame('B+1.5', 2, 'white')
    assert_equal 'W+0.5', C.fill_dame('B+0.5', 1, 'white')
  end

  def test_cause_of_a_difference
    base = { end: 'passes', dead: [], seki: [], arena: 'B+3.5', referee: 'B+3.5', without_dead: 'B+3.5',
             filled: 'B+3.5' }
    assert_equal :same, C.cause(**base)
    assert_equal :resign, C.cause(**base, end: 'resign', arena: 'B+R', referee: 'B+R')
    assert_equal :move_limit, C.cause(**base, end: 'limit', referee: 'W+0.5')
    assert_equal :dame, C.cause(**base, referee: 'B+4.5', filled: 'B+4.5')
    assert_equal :seki, C.cause(**base, seki: %w[A1 A2], referee: 'W+2.5')
    assert_equal :judgement, C.cause(**base, referee: 'B+5.5')
    dead = base.merge(dead: %w[A1], referee: 'W+2.5')
    assert_equal :dead_stones, C.cause(**dead, without_dead: 'W+2.5', filled: 'W+2.5')
    assert_equal :dead_stones_and_dame, C.cause(**dead, without_dead: 'W+1.5', filled: 'W+2.5')
    assert_equal :dead_stones_and_judgement, C.cause(**dead, without_dead: 'W+0.5', filled: 'W+1.5')
  end
end
