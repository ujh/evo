require 'minitest/autorun'
require_relative '../ruby/benchmark_ratings'

class BenchmarkRatingsTest < Minitest::Test
  ELO = 400 / Math.log(10)

  def sigmoid(x) = 1 / (1 + Math.exp(-x))

  # `wins` of A's `n` games against B, the rest B's.
  def two_player_games(n, wins)
    Array.new(n) { |k| ['A', 'B', k < wins ? 1 : 0] }
  end

  def row(ratings, player) = ratings.rows.find { |r| r.player == player }

  # With the prior, the two players' posterior mode is symmetric, θB = −θA,
  # and A's gradient vanishes where w + 1 = n·σ(2θ) + 2σ(θ). Its right side
  # grows with θ, so bisection finds θ.
  def test_two_players_match_the_posterior_mode_found_by_bisection
    n = 20
    wins = 14
    low = -10.0
    high = 10.0
    100.times do
      middle = (low + high) / 2
      (n * sigmoid(2 * middle)) + (2 * sigmoid(middle)) < wins + 1 ? low = middle : high = middle
    end
    theta = (low + high) / 2
    curvature = (n * sigmoid(2 * theta) * (1 - sigmoid(2 * theta))) + (2 * sigmoid(theta) * (1 - sigmoid(theta)))

    ratings = BenchmarkRatings.new(two_player_games(n, wins), anchor: 'B')

    assert_equal (ELO * 2 * theta).round, row(ratings, 'A').rating
    assert_equal (ELO * 1.96 / Math.sqrt(curvature)).round, row(ratings, 'A').margin
  end

  def test_rows_give_games_and_score_share_strongest_first
    games = two_player_games(10, 7) + [%w[B A] + [Rational(1, 2)]]
    ratings = BenchmarkRatings.new(games, anchor: 'B')

    assert_equal %w[A B], ratings.rows.map(&:player)
    assert_equal [11, 11], ratings.rows.map(&:games)
    assert_in_delta 7.5 / 11, row(ratings, 'A').score
    assert_in_delta 3.5 / 11, row(ratings, 'B').score
  end

  def test_the_anchor_is_rated_0_with_no_margin
    ratings = BenchmarkRatings.new(two_player_games(10, 3), anchor: 'A')

    assert_equal 0, row(ratings, 'A').rating
    assert_nil row(ratings, 'A').margin
    assert_operator row(ratings, 'B').rating, :>, 0
    assert_operator row(ratings, 'B').margin, :>, 0
  end

  def test_an_anchor_without_games_is_rated_0_against_the_prior
    ratings = BenchmarkRatings.new(two_player_games(10, 5), anchor: 'AmiGo')

    assert_equal 0, row(ratings, 'AmiGo').rating
    assert_equal 0, row(ratings, 'AmiGo').games
    assert_nil row(ratings, 'AmiGo').score
  end

  def test_the_order_of_the_players_is_recovered
    games = [['A', 'B', 15, 20], ['B', 'C', 15, 20], ['A', 'C', 18, 20], ['C', 'D', 14, 20]].flat_map do |a, b, wins, n|
      Array.new(n) { |k| [a, b, k < wins ? 1 : 0] }
    end
    ratings = BenchmarkRatings.new(games, anchor: 'D')

    assert_equal %w[A B C D], ratings.rows.map(&:player)
  end

  def test_a_perfect_or_a_nil_record_gets_a_finite_rating
    ratings = BenchmarkRatings.new(two_player_games(40, 40), anchor: 'B')

    assert_operator row(ratings, 'A').rating, :>, 0
    assert_operator row(ratings, 'A').rating, :<, 2000
    assert_operator row(ratings, 'A').margin, :<, 2000
    assert_in_delta 1.0, row(ratings, 'A').score
    assert_in_delta 0.0, row(ratings, 'B').score
  end

  def test_the_margin_shrinks_with_more_games
    few = BenchmarkRatings.new(two_player_games(10, 5), anchor: 'B')
    many = BenchmarkRatings.new(two_player_games(100, 50), anchor: 'B')

    assert_operator row(many, 'A').margin, :<, row(few, 'A').margin
  end

  # C and D play only each other, so nothing links them to the anchor; the
  # prior still gives them a finite rating.
  def test_a_player_linked_to_no_one_gets_a_finite_rating
    games = two_player_games(10, 6) + Array.new(10) { |k| ['C', 'D', k < 8 ? 1 : 0] }
    ratings = BenchmarkRatings.new(games, anchor: 'B')

    assert_equal %w[A B C D], ratings.rows.map(&:player).sort
    assert_operator row(ratings, 'C').rating, :>, row(ratings, 'D').rating
    ratings.rows.each { |r| assert_operator r.rating.abs, :<, 2000 }
  end

  # Which player a game lists first must not matter: the fit stores each
  # pair once, so a game listed the other way round has its score flipped.
  def test_listing_a_game_the_other_way_round_changes_nothing
    games = [['A', 'B', 7, 10], ['B', 'C', 3, 12], ['A', 'C', 9, 10], ['C', 'D', 5, 6]].flat_map do |a, b, wins, n|
      Array.new(n) { |k| [a, b, k < wins ? 1 : 0] }
    end
    flipped = games.each_with_index.map { |(a, b, score), k| k.odd? ? [b, a, 1 - score] : [a, b, score] }

    assert_equal BenchmarkRatings.new(games, anchor: 'D').rows, BenchmarkRatings.new(flipped.reverse, anchor: 'D').rows
  end

  # Even records put every θ at 0, where H_ii = 2·¼ (the prior) plus a
  # quarter per game, so the margins follow from each player's games.
  def test_each_margin_comes_from_its_own_players_games
    games = two_player_games(10, 5) + Array.new(30) { |k| ['A', 'C', k < 15 ? 1 : 0] }
    ratings = BenchmarkRatings.new(games, anchor: 'B')

    assert_equal (ELO * 1.96 / Math.sqrt(0.5 + (40 / 4.0))).round, row(ratings, 'A').margin
    assert_equal (ELO * 1.96 / Math.sqrt(0.5 + (30 / 4.0))).round, row(ratings, 'C').margin
  end

  # One win of A over B: the prior's win and loss for each player against
  # the virtual player at 0, plus the game.
  def test_the_log_posterior_counts_the_prior_and_the_games
    ratings = BenchmarkRatings.new([['A', 'B', 1]], anchor: 'B')
    log_sigmoid = ->(x) { Math.log(sigmoid(x)) }
    expected = log_sigmoid.(1) + log_sigmoid.(-1) + log_sigmoid.(-0.5) + log_sigmoid.(0.5) + log_sigmoid.(1.5)

    assert_in_delta expected, ratings.send(:log_posterior, [1.0, -0.5]), 1e-12
  end

  def test_a_newton_step_that_would_lose_posterior_is_shortened
    ratings = BenchmarkRatings.new([['A', 'B', 1]], anchor: 'B')
    moved = ratings.send(:ascend, [0.0, 0.0], [100.0, -100.0])

    assert_operator moved[0], :<, 100
    assert_operator ratings.send(:log_posterior, moved), :>=, ratings.send(:log_posterior, [0.0, 0.0])
  end

  def test_a_score_other_than_a_win_a_loss_or_a_draw_is_refused
    assert_raises(ArgumentError) { BenchmarkRatings.new([['A', 'B', 2]], anchor: 'A') }
  end

  def test_a_fit_that_needs_more_steps_than_allowed_raises
    assert_raises(BenchmarkRatings::NotConverged) do
      BenchmarkRatings.new(two_player_games(20, 14), anchor: 'B', max_newton_steps: 1)
    end
    assert_raises(BenchmarkRatings::NotConverged) do
      BenchmarkRatings.new(champion_chain(20), anchor: 'AmiGo', max_cg_steps: 1)
    end
  end

  # An experiment with keep_every 10 run to generation 5000: every
  # checkpoint's champion plays the 6 bots, Gen0Champion and the 10 champions
  # before it 20 games each, and the bots play each other 40 games a pair.
  # Its long chain of champions is what makes a slow fit slow. The bound is
  # on work, not time, so a busy machine cannot fail it.
  def test_500_champions_converge_within_a_bound_on_work
    ratings = BenchmarkRatings.new(champion_chain(500), anchor: 'AmiGo')

    assert_equal 506, ratings.rows.size
    assert_operator ratings.newton_steps, :<=, 20
    assert_operator ratings.cg_steps, :<=, 1_000
  end

  def test_the_anchor_is_amigo_else_the_first_bot_else_the_initial_champion
    amigo = { name: 'AmiGo', kind: 'bot' }
    brown = { name: 'Brown', kind: 'bot' }
    gen0 = { name: 'Gen0Champion', kind: 'initial_champion' }
    past = { name: 'PastChampions', kind: 'past_champions' }

    assert_equal 'AmiGo', BenchmarkRatings.anchor([gen0, brown, amigo, past])
    assert_equal 'Brown', BenchmarkRatings.anchor([gen0, brown, past])
    assert_equal 'Gen0Champion', BenchmarkRatings.anchor([gen0, past])
  end

  BOTS = { 'Brown' => -600, 'AmiGo' => 0, 'MichiWeak' => 150, 'MichiMid' => 300, 'MichiStrong' => 450,
           'GnuGoLevel0' => 600 }.freeze

  # Champions spread evenly from Brown's strength to 1400 Elo above it.
  def champion_chain(champions)
    random = Random.new(1)
    elo = BOTS.dup
    champions.times { |c| elo["Gen#{c * 10}Champion"] = -600 + (1400.0 * c / (champions - 1)) + random.rand(-50.0..50.0) }
    play = ->(a, b) { random.rand < 1 / (1 + (10**((elo[b] - elo[a]) / 400.0))) ? 1 : 0 }
    games = BOTS.keys.combination(2).flat_map { |a, b| Array.new(20) { [[a, b, play.(a, b)], [b, a, play.(b, a)]] }.flatten(1) }
    champions.times do |c|
      opponents = BOTS.keys + (c.positive? ? ['Gen0Champion'] : []) + (1..10).map { |back| c - back }.select(&:positive?).map { |x| "Gen#{x * 10}Champion" }
      opponents.each { |o| 20.times { games << ["Gen#{c * 10}Champion", o, play.("Gen#{c * 10}Champion", o)] } }
    end
    games
  end
end
