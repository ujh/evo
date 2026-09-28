require_relative 'game_result'

# The outcome of one game the arena (engine/arena) played, read from its
# stdout. It answers what GameResult answers, so the runner scores both
# alike, plus the game's own arena time and its moves.
#
# The arena writes one tab-separated line per game, flushed complete and
# ending in the field "ok", then "done N". A line that does not match the
# format exactly (cut off when the arena died, for example) is not a result,
# and a scheduled game without a result fails with NO_RESULT, so a chunk
# always yields a result for every game in it. ArenaResult.chunk reads the
# legacy invocation's output, ArenaResult.mixed_chunk that of
# `arena --mixed`, whose format engine/arena.c's header comment defines.
class ArenaResult
  NO_RESULT = 'arena: no result'.freeze
  NEITHER_PLAYS = 'arena: neither network can play'.freeze

  TIME = /\A\d+\.\d{6}\z/
  VERTEX = /\A(?:pass|[A-HJ-Z][1-9]\d?)\z/
  PLAYED = /\A([^\t]+)\tresult=([BW]\+\d+\.\d|0)\tend=(passes|limit)\tlength=(\d+)\t
            time_black=(\d+\.\d{6})\ttime_white=(\d+\.\d{6})\tduration=(\d+\.\d{6})\t
            moves=([^\t]*)\tok\z/x
  ERRORED = /\A([^\t]+)\terror=(black|white|both)\tmessage=([^\t]+)\tok\z/
  TRAILER = /\Adone (\d+)\z/

  # `arena --mixed`, protocol 3.
  HEADER = 'arena protocol 3 ready'.freeze
  MIXED_PLAYED = /\A([^\t]+)\tresult=([BW]\+(?:\d+\.\d|[RT])|0)\tend=(passes|limit|resign|time)\tlength=(\d+)\t
                  time_black=(\d+\.\d{6})\ttime_white=(\d+\.\d{6})\tduration=(\d+\.\d{6})\t
                  moves=([^\t]*)\tok\z/x
  NETWORK_ERROR = /\A([^\t]+)\tend=network_error\terror=(black|white|both)\tmessage=([^\t]+)\tok\z/
  BOT_FAILED = /\A([^\t]+)\tend=(timeout|illegal|crash|launch)\terror=(black|white)\tlength=(\d+)\t
                time_black=(\d+\.\d{6})\ttime_white=(\d+\.\d{6})\tduration=(\d+\.\d{6})\t
                moves=([^\t]*)\tmessage=([^\t]+)\tok\z/x
  SCORE = /\A(?:[BW]\+\d+\.\d|0)\z/

  # The results of one chunk's games: results maps every scheduled ID, in
  # schedule order, to its ArenaResult; complete? says the arena finished
  # the chunk normally (every line valid and scheduled, once each, then a
  # trailer counting the schedule, and nothing after it).
  #
  # A second line for the same ID cannot say which is true, so that game
  # gets NO_RESULT. A line for an ID not in the schedule is ignored. Both
  # leave the chunk incomplete; the arena writes neither.
  Chunk = Struct.new(:results, :complete) do
    def complete?
      complete
    end
  end

  # The results of one `arena --mixed` chunk, as Chunk has them, plus what
  # the runner needs to decide whether to go on:
  #
  # header? says the output starts with HEADER; trailer is the count of the
  # trailer "done N", nil without one; complete? says the arena finished
  # the chunk normally, as Chunk#complete? does, with the header too.
  #
  # failures maps each failure record's ID, in schedule order, to its
  # result (failed? true): a game the arena could not finish, which is
  # never stored. missing lists the scheduled IDs without a valid record
  # (NO_RESULT). A chunk may be complete and still have failures; either
  # a failure or an incomplete chunk means its other games cannot be
  # trusted to have been played.
  MixedChunk = Struct.new(:results, :header, :trailer, :complete) do
    def header?
      header
    end

    def complete?
      complete
    end

    def failures
      results.select { |_, result| result.failed? }
    end

    def missing
      results.select { |_, result| result.failure == NO_RESULT }.keys
    end
  end

  attr_reader :winner, :failure, :length, :referee, :error_message, :time_black, :time_white, :duration, :moves,
              :end_reason, :error_side

  def self.chunk(text, ids)
    lines, trailer = split(text)
    results, valid = collect(lines.map { |line| parse_line(line) }, ids)
    Chunk.new(results, valid && trailer == ids.size)
  end

  # Reads `arena --mixed` output. Bytes that are not UTF-8 (a bot's answer
  # in a message) become U+FFFD.
  def self.mixed_chunk(text, ids)
    lines, trailer = split(text.dup.force_encoding(Encoding::UTF_8).scrub)
    header = lines.first == HEADER
    lines.shift if header
    results, valid = collect(lines.map { |line| parse_mixed_line(line) }, ids)
    MixedChunk.new(results, header, trailer, header && valid && trailer == ids.size)
  end

  # The lines of `text` without the trailer, and the trailer's count or nil.
  def self.split(text)
    lines = text.split("\n", -1)
    lines.pop if lines.last == ''
    trailer = lines.last && lines.last[TRAILER, 1]
    lines.pop if trailer
    [lines, trailer && Integer(trailer, 10)]
  end

  # The result of every scheduled ID from the parsed lines ([ID,
  # ArenaResult] or nil), and whether every line was valid and scheduled,
  # once each.
  def self.collect(parsed, ids)
    counts = parsed.compact.map(&:first).tally
    found = parsed.compact.to_h { |id, result| [id, counts[id] == 1 ? result : new(failure: NO_RESULT)] }
    results = ids.to_h { |id| [id, found.fetch(id) { new(failure: NO_RESULT) }] }
    valid = parsed.none?(&:nil?) && counts.keys.sort == ids.sort && counts.values.all?(1)
    [results, valid]
  end

  # [ID, ArenaResult] for a line in the arena's format, or nil.
  def self.parse_line(line)
    if (m = PLAYED.match(line))
      played(m)
    elsif (m = ERRORED.match(line))
      errored(m)
    end
  end

  def self.played(match)
    id, referee, finish, length, time_black, time_white, duration, moves = match.captures
    moves = moves(moves, length)
    return unless moves

    winner = { 'B' => :black, 'W' => :white }[referee[0]]
    [id, new(winner:, length: moves.size, referee:, moves:,
                  error_message: finish == 'limit' ? GameResult::MOVE_LIMIT : nil,
                  time_black: Float(time_black), time_white: Float(time_white), duration: Float(duration))]
  end

  # A network that cannot play loses, as an evo that crashes does through
  # GoGui; if neither can, the game has no result.
  def self.errored(match)
    id, side, message = match.captures
    return [id, new(failure: NEITHER_PLAYS, error_message: message)] if side == 'both'

    [id, new(winner: side == 'black' ? :white : :black, crashed: true, error_message: message)]
  end

  # [ID, ArenaResult] for a record of `arena --mixed`, or nil.
  def self.parse_mixed_line(line)
    if (m = MIXED_PLAYED.match(line))
      mixed_played(m)
    elsif (m = NETWORK_ERROR.match(line))
      network_error(m)
    elsif (m = BOT_FAILED.match(line))
      bot_failed(m)
    end
  end

  def self.mixed_played(match)
    id, referee, finish, length, time_black, time_white, duration, moves = match.captures
    moves = moves(moves, length)
    return unless moves && fits_end?(referee, finish, moves.size)

    winner = { 'B' => :black, 'W' => :white }[referee[0]]
    [id, new(winner:, length: moves.size, referee:, moves:, end_reason: finish,
             error_message: finish == 'limit' ? GameResult::MOVE_LIMIT : nil,
             time_black: Float(time_black), time_white: Float(time_white), duration: Float(duration))]
  end

  # Whether the result fits how the game ended. Black moves first, so after
  # an even number of moves black was to move: a bot resigns on its turn,
  # and a network loses on time with the move just played, so the game has
  # at least one.
  def self.fits_end?(referee, finish, length)
    case finish
    when 'resign' then referee == (length.even? ? 'W+R' : 'B+R')
    when 'time' then length.positive? && referee == (length.odd? ? 'W+T' : 'B+T')
    else SCORE.match?(referee)
    end
  end

  # One network that cannot be loaded loses, as in the legacy invocation;
  # if neither can, the game fails.
  def self.network_error(match)
    id, side, message = match.captures
    if side == 'both'
      return [id, new(failure: NEITHER_PLAYS, failed: true, end_reason: 'network_error', error_side: :both,
                      error_message: message)]
    end

    [id, new(winner: side == 'black' ? :white : :black, crashed: true, end_reason: 'network_error',
             error_side: side.to_sym, error_message: message)]
  end

  # A bot that failed: the game has no result, only the moves and times up
  # to the failure.
  def self.bot_failed(match)
    id, finish, side, length, time_black, time_white, duration, moves, message = match.captures
    moves = moves(moves, length)
    return unless moves

    [id, new(failure: "arena: #{side} bot #{finish}", failed: true, end_reason: finish, error_side: side.to_sym,
             error_message: message, length: moves.size, moves:,
             time_black: Float(time_black), time_white: Float(time_white), duration: Float(duration))]
  end

  # The comma-separated GTP vertices as an array, or nil unless there are
  # `length` of them.
  def self.moves(text, length)
    moves = text.split(',', -1)
    moves if moves.size == Integer(length, 10) && moves.all?(VERTEX)
  end

  def initialize(winner: nil, failure: nil, crashed: false, failed: false, length: nil, referee: nil,
                 error_message: nil, time_black: nil, time_white: nil, duration: nil, moves: [],
                 end_reason: nil, error_side: nil)
    @winner = winner
    @failure = failure
    @crashed = crashed
    @length = length
    @referee = referee
    @error_message = error_message
    @time_black = time_black
    @time_white = time_white
    @duration = duration
    @moves = moves
    @failed = failed
    @end_reason = end_reason
    @error_side = error_side
  end

  # True when the loser lost because its network could not play.
  def crashed?
    @crashed
  end

  # True for a failure record of `arena --mixed`: a game the arena could
  # not finish (end_reason timeout, illegal, crash or launch, or
  # network_error with error_side :both), which is never stored. A game
  # without a record (NO_RESULT) is not one.
  def failed?
    @failed
  end

  # The game as SGF, black first, passes as empty moves; nil without a
  # game. A bot that resigned before any move leaves a game without moves.
  # GTP columns skip I and rows count from the bottom; SGF letters run from
  # the top left without a gap.
  def sgf(size:, komi:)
    return unless referee

    nodes = moves.each_with_index.map do |vertex, k|
      "#{k.even? ? 'B' : 'W'}[#{sgf_point(vertex, size)}]"
    end
    "(;GM[1]FF[4]SZ[#{size}]KM[#{komi}]RE[#{referee}]#{nodes.map { |node| ";#{node}" }.join})"
  end

  private

  def sgf_point(vertex, size)
    return '' if vertex == 'pass'

    column = vertex[0].ord - 'A'.ord
    column -= 1 if vertex[0] > 'I'
    row = Integer(vertex[1..], 10)
    raise ArgumentError, "#{vertex} is not on a #{size}x#{size} board" unless column < size && row.between?(1, size)

    ('a'.ord + column).chr + ('a'.ord + size - row).chr
  end
end
