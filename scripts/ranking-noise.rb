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
# uses, agrees with a rating fit on all the games (Spearman, and the top
# 50 networks both put in their top 50).
#
# Odd against even rounds, not the first half against the second: the Swiss
# pairing gives a network that won early harder opponents later, so the
# halves' win counts correlate negatively whatever the skill.
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

  # The figures for one generation's games; `networks` are the players
  # measured (bots take part in the fits but are not measured).
  def figures(games, networks)
    players = games.flat_map { |game| [game[:black], game[:white]] }.uniq.sort
    rounds = games.map { |game| game[:round] }.max + 1
    won = wins(games, players)
    white = games_as_white(games, players)
    odd = ratings(games.select { |game| game[:round].even? }, players)
    even = ratings(games.reject { |game| game[:round].even? }, players)
    half = spearman(networks.map { |n| odd[n] }, networks.map { |n| even[n] })
    all = ratings(games, players)
    by_wins = networks.max_by(TOP) { |n| [won[n], all[n]] }
    by_rating = networks.max_by(TOP) { |n| all[n] }
    {
      games: games.size, networks: networks.size, rounds:,
      white_share: games.count { |game| game[:winner] == game[:white] }.fdiv(games.size),
      colour_r2: pearson(networks.map { |n| white[n] }, networks.map { |n| won[n] })**2,
      half:, reliability: [1, 2, 4].to_h { |times| [rounds * times, spearman_brown(half, 2 * times)] },
      wins_rating: spearman(networks.map { |n| won[n] }, networks.map { |n| all[n] }),
      top_common: (by_wins & by_rating).size
    }
  end
end

if $PROGRAM_NAME == __FILE__
  path, *generations = ARGV
  abort 'usage: scripts/ranking-noise.rb DATABASE GENERATION...' if path.nil? || generations.empty?

  db = Sequel.sqlite(path, readonly: true, timeout: 5_000)
  rows = generations.map do |generation|
    generation = Integer(generation)
    games = db[:games].where(generation:).exclude(winner: nil).select(:round, :black, :white, :winner).all
    abort "generation #{generation} has no scored games" if games.empty?

    networks = db[:players].where(generation:, external: false).select_map(:name)
    [generation, RankingNoise.figures(games, networks)]
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
