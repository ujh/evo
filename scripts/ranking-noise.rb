#!/usr/bin/env ruby
# How much of a tournament's ranking is skill and how much luck, from an
# experiment's recorded games alone (read-only; the experiment may run).
#
#   mise exec -- scripts/ranking-noise.rb experiments/NAME/experiment.sqlite3 GEN...
#
# Per generation: White's share of wins; how much of the spread in the
# networks' win counts their number of games as White explains (r²); the
# split-half agreement of a rating fit (BenchmarkRatings, the benchmark's
# Bradley–Terry fit) on the odd rounds against one on the even rounds
# (Spearman over the networks), and from it the reliability of a rating
# from the whole tournament and from twice and four times as many rounds
# (Spearman–Brown); and how well the win count, which parent selection
# uses, agrees with a rating fit on all the games (Spearman, and how many of
# the stored ranking's top 50, its ties shuffled as selection sees them,
# the fit also puts in its top 50).
#
# The reliability is the rating fit's. The win count's own cannot be
# measured this way: under the Swiss pairing a network that won in one half
# meets harder opponents in the other, so the halves' win counts correlate
# slightly negatively whatever the skill. Odd against even rounds, not the
# first half against the second, so each half holds early and late rounds
# alike.
require 'sequel'
require_relative '../ruby/benchmark_ratings'

module RankingNoise
  TOP = 50

  module_function

  # Ranks from 0, ties sharing their mean rank.
  def ranks(values)
    order = values.each_index.sort_by { |i| values[i] }
    ranks = Array.new(values.size)
    first = 0
    while first < order.size
      last = first
      last += 1 while last + 1 < order.size && values[order[last + 1]] == values[order[first]]
      (first..last).each { |k| ranks[order[k]] = (first + last) / 2.0 }
      first = last + 1
    end
    ranks
  end

  def pearson(xs, ys)
    mx = xs.sum.fdiv(xs.size)
    my = ys.sum.fdiv(ys.size)
    cov = xs.zip(ys).sum { |x, y| (x - mx) * (y - my) }
    cov / Math.sqrt(xs.sum { |x| (x - mx)**2 } * ys.sum { |y| (y - my)**2 })
  end

  def spearman(xs, ys) = pearson(ranks(xs), ranks(ys))

  # The reliability of a measure `factor` times as long as one whose two
  # halves correlate `half`: Spearman–Brown, from the halves to the whole
  # (factor 2) and beyond.
  def spearman_brown(half, factor) = factor * half / (1 + ((factor - 1) * half))

  # `games` are Hashes with :black, :white, and :winner (a player's name).
  def wins(games, players)
    counts = players.to_h { |player| [player, 0] }
    games.each { |game| counts[game[:winner]] += 1 }
    counts
  end

  def games_as_white(games, players)
    counts = players.to_h { |player| [player, 0] }
    games.each { |game| counts[game[:white]] += 1 }
    counts
  end

  # Elo per player from the games, any anchor: only differences are used.
  def ratings(games, players)
    scored = games.map { |game| [game[:black], game[:white], game[:winner] == game[:black] ? 1 : 0] }
    BenchmarkRatings.new(scored, anchor: players.first).rows.to_h { |row| [row.player, row.rating] }
  end

  # How much of the spread in the networks' win counts their number of
  # games as White explains (r²).
  def colour_r2(games, networks)
    players = games.flat_map { |game| [game[:black], game[:white]] }.uniq
    won = wins(games, players)
    white = games_as_white(games, players)
    pearson(networks.map { |n| white[n] }, networks.map { |n| won[n] })**2
  end

  # Spearman over the networks between a rating fit on the odd rounds
  # (1, 3, ...; stored from 0, so even numbers) and one on the even rounds.
  def split_half(games, players, networks)
    odd = ratings(games.select { |game| game[:round].even? }, players)
    even = ratings(games.reject { |game| game[:round].even? }, players)
    spearman(networks.map { |n| odd[n] }, networks.map { |n| even[n] })
  end

  # How many of the first `top` of `ranking` (network names in the order
  # the runner stored, its ties shuffled as parent selection sees them) are
  # also among the `top` best rated.
  def top_common(ranking, rating, top)
    (ranking.first(top) & ranking.max_by(top) { |n| rating[n] }).size
  end

  # The figures for one generation's games; `ranking` is its networks in
  # stored order (bots take part in the fits but are not measured).
  def figures(games, ranking, top: TOP)
    players = games.flat_map { |game| [game[:black], game[:white]] }.uniq.sort
    rounds = games.map { |game| game[:round] }.max + 1
    won = wins(games, players)
    half = split_half(games, players, ranking)
    all = ratings(games, players)
    {
      games: games.size, networks: ranking.size, rounds:,
      white_share: games.count { |game| game[:winner] == game[:white] }.fdiv(games.size),
      colour_r2: colour_r2(games, ranking),
      half:, reliability: [1, 2, 4].to_h { |times| [rounds * times, spearman_brown(half, 2 * times)] },
      wins_rating: spearman(ranking.map { |n| won[n] }, ranking.map { |n| all[n] }),
      top_common: top_common(ranking, all, top)
    }
  end
end

if $PROGRAM_NAME == __FILE__
  path, *generations = ARGV
  abort 'usage: scripts/ranking-noise.rb DATABASE GENERATION...' if path.nil? || generations.empty?

  db = Sequel.sqlite(path, readonly: true, timeout: 5_000)
  rounds = Integer(db[:settings].where(key: 'tournament_rounds').get(:value))
  rows = generations.map do |generation|
    generation = Integer(generation)
    games = db[:games].where(generation:).exclude(winner: nil).select(:round, :black, :white, :winner).all
    abort "generation #{generation} has no scored games" if games.empty?
    # A tournament still running has fewer rounds, halves of unequal
    # length, and a ranking taken mid-round.
    played = games.map { |game| game[:round] }.max + 1
    abort "generation #{generation} has played #{played} of its #{rounds} rounds" if played < rounds

    ranking = db[:rankings].where(generation:, external: false).order(:rank).select_map(:name)
    [generation, RankingNoise.figures(games, ranking)]
  end
  reliability = rows.first.last[:reliability].keys
  puts "| Generation | Games | Networks | White wins | Colour r² | Odd/even Spearman | #{reliability.map { |r| "Reliability, #{r} rounds" }.join(' | ')} " \
       "| Wins vs rating | Top #{RankingNoise::TOP} in common |"
  puts "|#{' ---: |' * (8 + reliability.size)}"
  rows.each do |generation, f|
    puts "| #{generation} | #{f[:games]} | #{f[:networks]} | #{format('%.0f %%', 100 * f[:white_share])} " \
         "| #{format('%.2f', f[:colour_r2])} | #{format('%.2f', f[:half])} " \
         "| #{f[:reliability].values.map { |r| format('%.2f', r) }.join(' | ')} " \
         "| #{format('%.2f', f[:wins_rating])} | #{f[:top_common]} |"
  end
end
