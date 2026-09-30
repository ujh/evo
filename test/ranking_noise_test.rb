require 'minitest/autorun'
require_relative '../scripts/ranking-noise'

# The pure parts of scripts/ranking-noise.rb.
class RankingNoiseTest < Minitest::Test
  R = RankingNoise

  def test_ties_share_their_mean_rank
    assert_equal [2.0, 0.5, 0.5, 3.0], R.ranks([5, 1, 1, 9])
  end

  def test_spearman_uses_the_order_only
    assert_in_delta 1.0, R.spearman([1, 2, 3, 4], [10, 20, 300, 4000])
    assert_in_delta(-1.0, R.spearman([1, 2, 3, 4], [4, 3, 2, 1]))
    # Ranks [0.5, 0.5, 2, 3] against [0, 1, 2, 3].
    assert_in_delta 0.9487, R.spearman([1, 1, 2, 3], [1, 2, 3, 4]), 1e-4
  end

  def test_spearman_brown
    assert_in_delta 0.5, R.spearman_brown(1 / 3r, 2)
    assert_in_delta 2 / 3r, R.spearman_brown(1 / 3r, 4)
    assert_in_delta 0.25, R.spearman_brown(0.25, 1)
  end

  def test_counts_wins_and_games_as_white
    games = [{ black: 'a', white: 'b', winner: 'b' }, { black: 'b', white: 'c', winner: 'b' }]
    assert_equal({ 'a' => 0, 'b' => 2, 'c' => 0 }, R.wins(games, %w[a b c]))
    assert_equal({ 'a' => 0, 'b' => 1, 'c' => 1 }, R.games_as_white(games, %w[a b c]))
  end

  # a beats b and d, b beats c, c beats d, in every round, with b and c
  # swapping colours. Odd and even rounds then rate the four the same way.
  def test_figures_of_a_tournament_with_a_clear_order
    games = (0...4).flat_map do |round|
      [{ round:, black: 'a', white: 'd', winner: 'a' },
       { round:, black: round.even? ? 'b' : 'c', white: round.even? ? 'c' : 'b', winner: 'b' },
       { round:, black: 'a', white: 'b', winner: 'a' },
       { round:, black: 'c', white: 'd', winner: 'c' }]
    end
    f = R.figures(games, %w[a b c d])
    assert_equal 16, f[:games]
    assert_equal 4, f[:rounds]
    assert_in_delta 0.125, f[:white_share]
    assert_operator f[:half], :>, 0.9
    assert_equal [4, 8, 16], f[:reliability].keys
    assert_in_delta R.spearman_brown(f[:half], 2), f[:reliability][4]
    assert_operator f[:wins_rating], :>, 0.9
    assert_equal 4, f[:top_common]
  end

  # Odd rounds against even ones, not halves: here a beats b in the first
  # two rounds and b beats a in the last two, so the halves order a and b
  # differently while the odd and even rounds tie them alike.
  def test_splits_by_odd_and_even_rounds
    games = [0, 1, 2, 3].map do |round|
      winner = round < 2 ? 'a' : 'b'
      { round:, black: 'a', white: 'b', winner: }
    end
    games += [0, 1, 2, 3].map { |round| { round:, black: 'c', white: 'a', winner: 'a' } }
    games += [0, 1, 2, 3].map { |round| { round:, black: 'c', white: 'b', winner: 'b' } }
    f = R.figures(games, %w[a b c])
    assert_in_delta 1.0, f[:half]
  end
end
