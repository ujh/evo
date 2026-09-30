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

  # White counts [1, 1, 2, 2] against wins [1, 2, 1, 2]: uncorrelated.
  def test_colour_r2_is_zero_when_colour_and_wins_are_unrelated
    games = [%w[c a a], %w[d b b], %w[a c c], %w[b c b], %w[a d d], %w[b d d]].map do |black, white, winner|
      { round: 0, black:, white:, winner: }
    end
    assert_equal({ 'a' => 1, 'b' => 2, 'c' => 1, 'd' => 2 }, R.wins(games, %w[a b c d]))
    assert_in_delta 0.0, R.colour_r2(games, %w[a b c d])
  end

  # White always wins, and a is White twice as often as b and c.
  def test_colour_r2_is_one_when_white_always_wins
    games = [%w[b a a], %w[c a a], %w[a b b], %w[a c c]].map do |black, white, winner|
      { round: 0, black:, white:, winner: }
    end
    assert_in_delta 1.0, R.colour_r2(games, %w[a b c])
  end

  # The odd rounds (stored as 0 and 2) order a > b > c and the even ones
  # c > b > a, so they disagree completely; the first and the second half
  # would agree.
  def test_split_half_compares_odd_with_even_rounds
    games = [0, 1, 2, 3].flat_map do |round|
      order = round.even? ? %w[a b c] : %w[c b a]
      order.combination(2).map { |winner, loser| { round:, black: winner, white: loser, winner: } }
    end
    assert_in_delta(-1.0, R.split_half(games, %w[a b c], %w[a b c]))
  end

  def test_top_common_takes_the_stored_order_not_the_ratings_for_ties
    ranking = %w[a b c d]
    assert_equal 0, R.top_common(ranking, { 'a' => 1, 'b' => 2, 'c' => 3, 'd' => 4 }, 2)
    assert_equal 1, R.top_common(ranking, { 'a' => 4, 'b' => 1, 'c' => 3, 'd' => 2 }, 2)
    assert_equal 4, R.top_common(ranking, { 'a' => 1, 'b' => 2, 'c' => 3, 'd' => 4 }, 4)
  end

  # The odd rounds order a > b > c > d, the even ones a > b > d > c, so the
  # halves agree at Spearman 0.8, and the whole at 2 × 0.8 / 1.8.
  def test_the_reliability_projects_the_halves_agreement
    games = [0, 1, 2, 3].flat_map do |round|
      order = round.even? ? %w[a b c d] : %w[a b d c]
      order.combination(2).map { |winner, loser| { round:, black: winner, white: loser, winner: } }
    end
    f = R.figures(games, %w[a b c d])
    assert_in_delta 0.8, f[:half]
    assert_in_delta 16 / 18r, f[:reliability][4]
    assert_in_delta 3.2 / 3.4, f[:reliability][8]
  end

  # a, b, and c each win once, but a beat b, who beat d, while c beat only
  # d: the win count ties them, the rating does not.
  def test_wins_against_rating_differs_when_opponents_differ
    games = [%w[a b], %w[b d], %w[c d]].map { |winner, loser| { round: 0, black: winner, white: loser, winner: } }
    f = R.figures(games + games.map { |g| g.merge(round: 1) }, %w[a b c d])
    won = R.wins(games, %w[a b c d])
    rating = R.ratings(games + games.map { |g| g.merge(round: 1) }, %w[a b c d])
    assert_in_delta R.spearman(%w[a b c d].map { won[_1] }, %w[a b c d].map { rating[_1] }), f[:wins_rating]
    assert_operator f[:wins_rating], :<, 0.99
  end

  # a beats b, c, and d, b beats c and d, c beats d, in every round, with
  # the colours swapping each round.
  def test_figures_of_a_tournament_with_a_clear_order
    games = (0...4).flat_map do |round|
      %w[a b c d].combination(2).map do |winner, loser|
        black, white = round.even? ? [winner, loser] : [loser, winner]
        { round:, black:, white:, winner: }
      end
    end
    f = R.figures(games, %w[d c b a], top: 2)
    assert_equal 24, f[:games]
    assert_equal 4, f[:networks]
    assert_equal 4, f[:rounds]
    assert_in_delta 0.5, f[:white_share]
    assert_in_delta 1.0, f[:half]
    assert_equal({ 4 => 1.0, 8 => 1.0, 16 => 1.0 }, f[:reliability].transform_values { |r| r.round(6) })
    assert_in_delta 1.0, f[:wins_rating]
    # The stored order puts the two worst first.
    assert_equal 0, f[:top_common]
  end
end
