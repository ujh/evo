require 'minitest/autorun'
require_relative '../scripts/calibrate-bots'

# The pure parts of scripts/calibrate-bots.rb: reading one arena game,
# writing its SGF for the referee, the 95 % interval, and the counts of the
# endings and ladder tables.
class CalibrateBotsTest < Minitest::Test
  C = CalibrateBots

  PLAYED = "arena protocol 3 ready\n" \
           "g1\tresult=B+12.5\tend=passes\tlength=3\ttime_black=0.1\ttime_white=0.2\tduration=0.3\t" \
           "moves=E5,pass,pass\tok\ndone 1\n".freeze

  def test_reads_a_played_game
    game = C.parse_arena(PLAYED, 'g1')
    assert_equal({ result: 'B+12.5', end: 'passes', moves: %w[E5 pass pass] }, game)
  end

  def test_reads_a_game_without_moves
    text = "arena protocol 3 ready\ng1\tresult=W+R\tend=resign\tlength=0\ttime_black=0.1\ttime_white=0\t" \
           "duration=0.1\tmoves=\tok\ndone 1\n"
    assert_equal({ result: 'W+R', end: 'resign', moves: [] }, C.parse_arena(text, 'g1'))
  end

  def test_a_failure_record_is_a_failure
    text = "arena protocol 3 ready\ng1\tend=crash\terror=white\tlength=4\ttime_black=0.1\ttime_white=0.1\t" \
           "duration=0.2\tmoves=E5,C3,D4,F6\tmessage=bot died\tok\n"
    assert_equal({ failure: 'crash white: bot died' }, C.parse_arena(text, 'g1'))
  end

  def test_a_one_sided_network_error_is_a_failure
    text = "arena protocol 3 ready\ng1\tend=network_error\terror=black\tmessage=cannot load\tok\ndone 1\n"
    assert_equal({ failure: 'network_error black: cannot load' }, C.parse_arena(text, 'g1'))
  end

  def test_output_without_the_game_is_a_failure
    assert_equal({ failure: 'no record for g1' }, C.parse_arena("arena protocol 3 ready\n", 'g1'))
    assert_equal({ failure: 'no record for g1' }, C.parse_arena('', 'g1'))
  end

  def test_a_played_game_without_the_trailer_is_a_failure
    assert_equal({ failure: 'no trailer' }, C.parse_arena(PLAYED.sub("done 1\n", ''), 'g1'))
  end

  def test_writes_the_moves_as_sgf
    sgf = C.sgf(%w[A9 J1 pass E5 H2], 9, 6.5)
    assert_equal '(;GM[1]FF[4]SZ[9]KM[6.5];B[aa];W[ii];B[];W[ee];B[hh])', sgf
  end

  def test_the_interval_is_wilsons
    low, high = C.wilson(7, 10)
    assert_in_delta 0.3968, low, 0.0001
    assert_in_delta 0.8922, high, 0.0001
  end

  def test_the_interval_reaches_the_ends
    assert_equal 0.0, C.wilson(0, 20).first
    assert_equal 1.0, C.wilson(20, 20).last
    assert_nil C.wilson(0, 0)
  end

  def endings_game(bot_color, finish, result, referee = nil)
    { bot_color:, end: finish, result:, referee: }
  end

  def test_counts_winner_changes_by_whom_the_arena_favours
    games = [
      endings_game('W', 'passes', 'W+3.5', 'B+2.5'),  # arena gives the bot the win
      endings_game('B', 'passes', 'W+3.5', 'B+2.5'),  # arena gives the network the win
      endings_game('B', 'passes', 'B+10.5', 'B+4.5'), # margin differs, winner the same
      endings_game('W', 'passes', 'W+30.5', 'W+30.5')
    ]
    row = C.endings_row(games)
    assert_equal 4, row[:games]
    assert_equal 4, row[:passes]
    assert_equal 2, row[:changed]
    assert_equal 1, row[:to_bot]
    assert_equal 1, row[:to_network]
    assert_equal 1, row[:margin_only]
  end

  def test_counts_resignations_and_the_move_limit_apart
    games = [
      endings_game('W', 'resign', 'W+R'),                 # the network resigned: never, but counted
      endings_game('B', 'resign', 'W+R'),                 # the bot resigned
      endings_game('W', 'limit', 'W+3.5', 'B+2.5'),
      endings_game('W', 'limit', 'W+3.5', 'W+2.5'),
      endings_game('W', 'passes', 'B+3.5', 'W+2.5'),  # arena gives the network the win
      { bot_color: 'B', failure: 'crash black: bot died' }
    ]
    row = C.endings_row(games)
    assert_equal 6, row[:games]
    assert_equal 2, row[:resigned]
    assert_equal 1, row[:bot_resigned]
    assert_equal 2, row[:limit]
    assert_equal 1, row[:limit_changed]
    assert_equal 1, row[:passes]
    assert_equal 1, row[:changed]
    assert_equal 1, row[:to_network]
    assert_equal 0, row[:to_bot]
    assert_equal 1, row[:failures]
  end

  def ladder_game(a_color, finish, result)
    { a_color:, end: finish, result: }
  end

  def test_counts_a_pairings_wins_by_player_whatever_the_color
    games = [
      ladder_game('B', 'passes', 'B+3.5'), # a wins
      ladder_game('W', 'resign', 'W+R'),   # a wins, b resigned
      ladder_game('W', 'limit', 'B+0.5'),  # b wins at the move limit
      ladder_game('B', 'resign', 'W+R'),   # b wins, a resigned
      ladder_game('B', 'passes', '0'),     # a draw
      { a_color: 'W', failure: 'timeout black: no answer' }
    ]
    row = C.ladder_row(games)
    assert_equal 6, row[:games]
    assert_equal 2, row[:a_wins]
    assert_equal 2, row[:b_wins]
    assert_equal 1, row[:draws]
    assert_equal 1, row[:failures]
    assert_equal 1, row[:a_resigned]
    assert_equal 1, row[:b_resigned]
    assert_equal 1, row[:limit]
  end
end
