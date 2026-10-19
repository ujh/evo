require 'minitest/autorun'
require_relative '../ruby/elitism'

# The elite count E of an elite share, alone: the runner loads it without
# SetupExperiment.
class ElitismTest < Minitest::Test
  def test_no_share_carries_no_network_over
    assert_equal 0, Elitism.count(0.0, 1000)
    assert_equal 0, Elitism.count(0.0, 1)
  end

  def test_the_share_of_the_population_is_rounded
    assert_equal 10, Elitism.count(0.01, 1000)
    assert_equal 2, Elitism.count(0.2, 12)
    assert_equal 11, Elitism.count(0.95, 12)
    assert_equal 12, Elitism.count(1.0, 12)
    # 0.07 x 100 is 7.000000000000001 and 0.29 x 100 is 28.999999999999996
    # in floating point: ceil would give 8 and floor 28.
    assert_equal 7, Elitism.count(0.07, 100)
    assert_equal 29, Elitism.count(0.29, 100)
    # A half rounds up, also from an even floor, where rounding half to
    # even would round down: 0.125 x 12 is 1.5 and 0.25 x 10 is 2.5.
    assert_equal 2, Elitism.count(0.125, 12)
    assert_equal 3, Elitism.count(0.25, 10)
    assert_equal 3, Elitism.count(0.2, 14)
  end

  def test_any_share_carries_at_least_one_network_over
    assert_equal 1, Elitism.count(0.01, 12)
    assert_equal 1, Elitism.count(0.0001, 1000)
    assert_equal 1, Elitism.count(0.01, 1)
  end
end
