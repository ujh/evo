require 'minitest/autorun'
require 'tmpdir'
require_relative '../ruby/game_result'

class GameResultTest < Minitest::Test
  FIXTURES = File.expand_path('fixtures/dat', __dir__)

  def read(fixture)
    GameResult.read(File.join(FIXTURES, fixture))
  end

  def test_reads_the_game_length
    assert_equal 93, read('black_wins').length
  end

  def test_an_empty_column_does_not_shift_the_game_length
    # RES_W is empty in this line; splitting on whitespace would read 0.
    assert_equal 2, read('illegal_move').length
  end

  def test_a_failed_game_still_has_its_length
    result = read('illegal_move')
    refute_nil result.failure
    assert_equal 2, result.length
  end

  # A real game of GNU Go level 10 against Brown: twogtp writes each
  # player's time in seconds, to a tenth.
  def test_reads_the_time_each_player_used
    result = read('timed')
    assert_in_delta 4.5, result.time_black
    assert_in_delta 0.0, result.time_white
  end

  def test_a_missing_result_file_has_no_times
    result = GameResult.read(File.join(FIXTURES, 'does_not_exist'))
    assert_nil result.time_black
    assert_nil result.time_white
  end

  def test_a_missing_result_file_has_no_length
    assert_nil GameResult.read(File.join(FIXTURES, 'does_not_exist')).length
  end

  # What each kind of twogtp result means, as the benchmark scores it.
  def outcome(fixture)
    result = read(fixture)
    [result.winner, result.failure, result.crashed?]
  end

  def test_the_referee_names_the_winner
    assert_equal [:black, nil, false], outcome('black_wins')
    assert_equal [:white, nil, false], outcome('white_wins')
    assert_equal [nil, nil, false], outcome('draw')
  end

  def test_a_missing_referee_score_is_a_failure
    assert_equal [nil, 'no referee score: ?', false], outcome('no_referee_score')
  end

  # Evo exited on its first move, yet GNU Go scored the position B+17.5.
  def test_a_crashed_program_loses_whatever_the_referee_said
    assert_equal [:white, nil, true], outcome('black_crashed')
    assert_equal [:black, nil, true], outcome('white_crashed')
  end

  def test_a_crash_without_stderr_is_a_failure
    assert_equal [nil, 'error: The Go program terminated unexpectedly.', false], outcome('crash_without_stderr')
  end

  def test_an_illegal_move_is_a_failure
    assert_equal [nil, 'error: Brown: illegal move', false], outcome('illegal_move')
  end

  def test_the_move_limit_uses_the_referee_score
    assert_equal [:white, nil, false], outcome('move_limit')
  end

  def test_a_result_file_without_a_game_line_is_a_failure
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'g.dat'), "# Black: Brown\n#GAME\tRES_B\n")
      assert_equal 'no game in result file', GameResult.read(File.join(dir, 'g')).failure
    end
  end

  def test_a_missing_result_file_is_a_failure
    assert_equal 'no result file', GameResult.read(File.join(FIXTURES, 'does_not_exist')).failure
  end
end
