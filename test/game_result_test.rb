require 'minitest/autorun'
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
end
