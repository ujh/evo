#!/usr/bin/env ruby
# How many of a generation's tournament games repeat another game of the
# generation move for move, from an experiment's recorded games alone
# (read-only; the experiment may run). Only the generations that keep their
# SGFs (every keep_every-th) can be counted.
#
#   mise exec -- scripts/game-repeats.rb [--without-elites] experiments/NAME/experiment.sqlite3 GEN...
#
# A game's move sequence is its SGF from Black's first move on
# (substr(sgf, instr(sgf, ';B['))), and its pairing is (Black, White), a
# bot's copies counted as the bot itself (players.opponent, so AmiGo2 is
# AmiGo). The games with one move sequence form a group; of a group of n
# games with p distinct pairings, the first in (round, black, white) order,
# the games key, is the original and the other n - 1 add no new game: p - 1
# of them are clone repeats (another pairing played the same game, so the
# networks move alike) and n - p rematches (a pairing met again and replayed
# its game). A game without moves (a bot resigned at once) is counted apart
# and is no one's repeat.
#
# One row per kind of game: network against network, against each bot
# (in the order of the opponents table), and bot against bot. A game counts
# in its own kind's row, also in a group that holds games of several kinds.
#
# --without-elites leaves out every game in which an elite of the
# generation plays (its births with operator elite), as if they had not
# been played: the groups are formed from the other games alone, so a
# group's first remaining game is its original, and a kind of game none of
# whose games remains gets no row. A generation without births is refused.
require 'optparse'
require 'sequel'

module GameRepeats
  NETWORKS = 'network against network'.freeze
  BOTS = 'bot against bot'.freeze

  # A generation that cannot be counted.
  class Refused < StandardError; end

  module_function

  # The game's moves from Black's first on, as SQL's
  # substr(sgf, instr(sgf, ';B[')) has them; nil for a game without moves.
  def moves(sgf)
    start = sgf.index(';B[')
    start && sgf[start..]
  end

  def kind(game, bots)
    black = game[:black_external] ? bots.fetch(game[:black], game[:black]) : nil
    white = game[:white_external] ? bots.fetch(game[:white], game[:white]) : nil
    return BOTS if black && white
    return NETWORKS unless black || white

    "against #{black || white}"
  end

  # `games` are Hashes with :round, :black, :white, :black_external,
  # :white_external and :sgf; `bots` maps a bot copy's name to its bot.
  # Returns per kind of game the games, those without moves, and the clone
  # repeats and rematches.
  def tally(games, bots)
    counts = Hash.new { |hash, kind| hash[kind] = { games: 0, no_moves: 0, clone_repeats: 0, rematches: 0 } }
    groups = Hash.new { |hash, moves| hash[moves] = [] }
    games.sort_by { |game| [game[:round], game[:black], game[:white]] }.each do |game|
      count = counts[kind(game, bots)]
      count[:games] += 1
      moves = moves(game[:sgf])
      if moves
        groups[moves] << [count, [game[:black], game[:white]].map { |name| bots.fetch(name, name) }]
      else
        count[:no_moves] += 1
      end
    end
    groups.each_value do |group|
      pairings = { group.first.last => true }
      group.drop(1).each do |count, pairing|
        count[pairings.key?(pairing) ? :rematches : :clone_repeats] += 1
        pairings[pairing] = true
      end
    end
    counts
  end

  # The generation's games from the database `db`. Refused unless every
  # game kept its SGF.
  def games(db, generation)
    games = db[:games].where(generation:).select(:round, :black, :white, :black_external, :white_external, :sgf).all
    raise Refused, "generation #{generation} has no games" if games.empty?

    kept = games.count { |game| game[:sgf] }
    if kept < games.size
      raise Refused, "generation #{generation}: #{kept} of #{games.size} games kept their SGF " \
                     '(only every keep_every-th generation keeps them)'
    end
    games
  end

  # The generation's counts from the database `db`, one row per kind in
  # the order: network against network, each stored opponent, bot against
  # bot (then any other bot). Refused unless every game kept its SGF.
  # Given `chosen` games, counts those instead of all the generation's.
  def counts(db, generation, chosen = games(db, generation))
    bots = db[:players].where(generation:).exclude(opponent: nil).to_hash(:name, :opponent)
    counts = tally(chosen, bots)
    order = [NETWORKS, *db[:opponents].order(:position).select_map(:name).map { |name| "against #{name}" }, BOTS]
    counts.sort_by { |kind, _| [order.index(kind) || order.size, kind] }.to_h
  end

  # The names of the generation's elites: its births with operator elite.
  # Refused for a generation without births, whose elites cannot be told.
  def elites(db, generation)
    births = db[:births].where(generation:)
    raise Refused, "generation #{generation} has no births, so its elites cannot be told" if births.empty?

    births.where(operator: 'elite').select_order_map(:child)
  end

  # The generation's counts as `counts` gives them, of the games in which
  # none of its elites plays, then the number of elites and of the games
  # left out.
  def counts_without_elites(db, generation)
    games = games(db, generation)
    elites = elites(db, generation).to_h { |name| [name, true] }
    kept = games.reject { |game| elites.key?(game[:black]) || elites.key?(game[:white]) }
    [counts(db, generation, kept), elites.size, games.size - kept.size]
  end

  def share(count, games) = format('%d (%.1f %%)', count, 100.0 * count / games)

  # The counts as a Markdown table under a line naming the generation;
  # given the number of elites and of the games left out
  # (counts_without_elites), the line says what was left out.
  def table(generation, counts, elites = nil, left_out = nil)
    games = counts.values.sum { |count| count[:games] }
    heading = "Generation #{generation}: #{games} games"
    if elites&.zero?
      heading += ", leaving out none: no birth of generation #{generation} has operator elite"
    elsif elites
      heading = "Generation #{generation}: #{games} of its #{games + left_out} games, leaving out the #{left_out} " \
                "in which an elite plays (elites: births of generation #{generation} with operator elite, " \
                "#{elites} of them)"
    end
    lines = [heading, '', '| Kind of game | Games | No moves | Clone repeats | Rematches |', '| --- | ---: | ---: | ---: | ---: |']
    counts.each do |kind, count|
      lines << "| #{kind} | #{count[:games]} | " \
               "#{%i[no_moves clone_repeats rematches].map { |key| share(count[key], count[:games]) }.join(' | ')} |"
    end
    "#{lines.join("\n")}\n"
  end
end

if $PROGRAM_NAME == __FILE__
  usage = 'usage: scripts/game-repeats.rb [--without-elites] DATABASE GENERATION...'
  without_elites = false
  begin
    parser = OptionParser.new { |options| options.on('--without-elites') { without_elites = true } }
    parser.require_exact = true
    parser.parse!(ARGV)
  rescue OptionParser::ParseError => e
    abort "#{e.message}\n#{usage}"
  end
  path, *generations = ARGV
  abort usage if path.nil? || generations.empty?

  db = Sequel.sqlite(path, readonly: true, timeout: 5_000)
  tables = generations.map do |generation|
    generation = Integer(generation)
    if without_elites
      GameRepeats.table(generation, *GameRepeats.counts_without_elites(db, generation))
    else
      GameRepeats.table(generation, GameRepeats.counts(db, generation))
    end
  rescue GameRepeats::Refused => e
    abort e.message
  end
  puts tables.join("\n")
end
