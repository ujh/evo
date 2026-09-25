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

  def test_a_missing_result_file_has_no_length
    assert_nil GameResult.read(File.join(FIXTURES, 'does_not_exist')).length
  end
end
