require 'minitest/autorun'
require_relative '../ruby/seeds'

class SeedsTest < Minitest::Test
  def test_the_same_parts_give_the_same_seed
    assert_equal Seeds.derive(42, 'birth', 3, 7), Seeds.derive(42, 'birth', 3, 7)
  end

  def test_other_parts_or_another_base_give_another_seed
    seeds = [Seeds.derive(42, 'birth', 3, 7), Seeds.derive(42, 'birth', 3, 8),
             Seeds.derive(42, 'birth', 4, 7), Seeds.derive(43, 'birth', 3, 7), Seeds.derive(42, 'selection', 3)]
    assert_equal seeds.size, seeds.uniq.size
  end

  def test_seeds_fit_a_signed_64_bit_integer
    # SQLite stores them as INTEGER, and evolve reads them as unsigned 64-bit.
    100.times { |i| assert_includes 0...(2**63), Seeds.derive(i, 'x') }
  end

  def test_gnugo_seeds_fit_a_c_int
    100.times { |i| assert_includes 0...(2**31), Seeds.gnugo(i, 'game') }
  end

  def test_new_experiment_seeds_differ
    assert_operator 5, :<=, Array.new(5) { Seeds.new_experiment_seed }.uniq.size
  end
end
