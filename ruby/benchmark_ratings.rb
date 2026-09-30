require_relative 'checkpoint_benchmark'

# Rates every benchmark player (bots and champions of every checkpoint) on
# one Elo scale from all their games, so players that never met are
# compared through those they both played.
#
# The model is Bradley–Terry: player i beats j with probability
# 1 / (1 + exp(θj − θi)), and a draw is half a win to each. As a prior,
# every player also has one win and one loss against a virtual player fixed
# at θ = 0, so a 100 % or 0 % record, or a player linked to no one, still
# gets a finite rating. The fit is the posterior mode, by Newton's method:
# each step solves H x = gradient by conjugate gradient with the Hessian's
# diagonal as preconditioner, and H times a vector runs over the pairs of
# players that met, so no matrix is ever built. A long chain of champions,
# each playing only the few before it, makes simpler fits (MM) converge
# slowly.
class BenchmarkRatings
  # The fit did not reach TOLERANCE within its step limits.
  class NotConverged < StandardError; end

  ELO = 400 / Math.log(10)
  # A normal distribution's 95 % half-width, in standard deviations.
  Z95 = 1.96
  # The fit stops when no player's gradient is larger.
  TOLERANCE = 1e-9
  # Each conjugate gradient solve stops when no residual is larger.
  SOLVE_TOLERANCE = 1e-10
  # Halvings of a Newton step before the fit gives up; the log posterior
  # is concave, so a short enough step always gains.
  MAX_HALVINGS = 50

  # `rating` is Elo above the anchor, rounded. `margin` is the 95 %
  # half-width in Elo with the other ratings held fixed (nil for the
  # anchor). `score` is points per game (nil without games).
  Row = Data.define(:player, :rating, :margin, :games, :score)

  # The player rated 0 for a benchmark panel
  # (ExperimentDatabase#benchmark_opponents): the bot AmiGo, else the
  # panel's first bot, else the initial champion.
  def self.anchor(panel)
    bots = panel.select { |row| row[:kind] == 'bot' }
    (bots.find { |row| row[:name] == 'AmiGo' } || bots.first)&.fetch(:name) || CheckpointBenchmark.champion_name(0)
  end

  # The rows, strongest first (ties by name), and the Newton and conjugate
  # gradient steps the fit took.
  attr_reader :rows, :newton_steps, :cg_steps

  # `games` lists [player, other player, player's score], the score 1, 0,
  # or 1/2; failed games have no place in it. The anchor gets a row even
  # without games.
  def initialize(games, anchor:, max_newton_steps: 50, max_cg_steps: 1_000)
    tally(games, anchor)
    fit(max_newton_steps, max_cg_steps)
    @rows = rate(@players.index(anchor))
  end

  private

  # Points and games per player, and per pair of players that met (i < j)
  # the games and i's points.
  def tally(games, anchor)
    @players = (games.flat_map { |a, b, _| [a, b] } + [anchor]).uniq
    index = @players.each_with_index.to_h
    @points = Array.new(@players.size, 0.0)
    @games = Array.new(@players.size, 0)
    pairs = Hash.new { |hash, key| hash[key] = [0, 0.0] }
    games.each do |a, b, score|
      unless [0, 1, 0.5].include?(score) && a != b
        raise ArgumentError, "#{a} against #{b}: a game is between two players and scores 1, 0, or 1/2, not #{score.inspect}"
      end

      i, j = index.values_at(a, b)
      i, j, score = j, i, 1 - score if i > j
      @points[i] += score
      @points[j] += 1 - score
      @games[i] += 1
      @games[j] += 1
      pairs[[i, j]][0] += 1
      pairs[[i, j]][1] += score
    end
    @pairs = pairs.map { |(i, j), (count, points)| [i, j, count, points.to_f] }
  end

  def fit(max_newton_steps, max_cg_steps)
    @newton_steps = 0
    @cg_steps = 0
    @theta = Array.new(@players.size, 0.0)
    loop do
      gradient, @diagonal, weights = derivatives(@theta)
      return if gradient.map(&:abs).max < TOLERANCE
      raise NotConverged, "no fit after #{max_newton_steps} Newton steps" if @newton_steps == max_newton_steps

      @newton_steps += 1
      @theta = ascend(@theta, solve(@diagonal, weights, gradient, max_cg_steps))
    end
  end

  # The log posterior's gradient, the diagonal of the negative log
  # posterior's Hessian H, and per pair the pair's off-diagonal weight
  # (H_ij = −weight).
  def derivatives(theta)
    gradient = @points.each_with_index.map { |points, i| points + 1 - (2 * sigmoid(theta[i])) }
    diagonal = theta.map { |t| 2 * sigmoid(t) * (1 - sigmoid(t)) }
    weights = @pairs.map do |i, j, count, _|
      p = sigmoid(theta[i] - theta[j])
      gradient[i] -= count * p
      gradient[j] -= count * (1 - p)
      weight = count * p * (1 - p)
      diagonal[i] += weight
      diagonal[j] += weight
      weight
    end
    [gradient, diagonal, weights]
  end

  # x with H x = gradient, by preconditioned conjugate gradient.
  def solve(diagonal, weights, gradient, max_cg_steps)
    x = Array.new(gradient.size, 0.0)
    residual = gradient.dup
    z = residual.each_with_index.map { |r, i| r / diagonal[i] }
    direction = z.dup
    rz = dot(residual, z)
    max_cg_steps.times do
      @cg_steps += 1
      product = hessian_times(diagonal, weights, direction)
      step = rz / dot(direction, product)
      x.each_index do |i|
        x[i] += step * direction[i]
        residual[i] -= step * product[i]
      end
      return x if residual.map(&:abs).max < SOLVE_TOLERANCE

      z = residual.each_with_index.map { |r, i| r / diagonal[i] }
      next_rz = dot(residual, z)
      direction = z.each_with_index.map { |zi, i| zi + (next_rz / rz * direction[i]) }
      rz = next_rz
    end
    raise NotConverged, "no Newton step after #{max_cg_steps} conjugate gradient steps"
  end

  def hessian_times(diagonal, weights, vector)
    product = diagonal.each_with_index.map { |d, i| d * vector[i] }
    @pairs.each_with_index do |(i, j, _), k|
      product[i] -= weights[k] * vector[j]
      product[j] -= weights[k] * vector[i]
    end
    product
  end

  # theta moved by the Newton step, halved while that loses posterior
  # (a step far from the mode can overshoot). Rounding hides a gain near
  # the mode, so a step that loses no more than rounding is taken.
  def ascend(theta, step)
    current = log_posterior(theta)
    slack = 1e-12 * (1 + current.abs)
    scale = 1.0
    MAX_HALVINGS.times do
      moved = theta.each_with_index.map { |t, i| t + (scale * step[i]) }
      return moved if log_posterior(moved) >= current - slack

      scale /= 2
    end
    raise NotConverged, "no Newton step gains after #{MAX_HALVINGS} halvings"
  end

  def log_posterior(theta)
    prior = theta.sum { |t| log_sigmoid(t) + log_sigmoid(-t) }
    prior + @pairs.sum do |i, j, count, points|
      difference = theta[i] - theta[j]
      (points * log_sigmoid(difference)) + ((count - points) * log_sigmoid(-difference))
    end
  end

  def rate(anchor)
    rows = @players.each_with_index.map do |player, i|
      Row.new(player:, rating: (ELO * (@theta[i] - @theta[anchor])).round,
              margin: i == anchor ? nil : (ELO * Z95 / Math.sqrt(@diagonal[i])).round,
              games: @games[i], score: @games[i].zero? ? nil : @points[i] / @games[i])
    end
    rows.sort_by { |row| [-row.rating, row.player] }
  end

  def dot(a, b) = a.each_index.sum { |i| a[i] * b[i] }

  def sigmoid(x) = 1 / (1 + Math.exp(-x))

  # log σ(x) without overflow for large |x|.
  def log_sigmoid(x) = x.negative? ? x - Math.log(1 + Math.exp(x)) : -Math.log(1 + Math.exp(-x))
end
