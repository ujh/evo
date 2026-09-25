require_relative 'game_result'

# The outcome of one game the arena (engine/arena) played, read from its
# stdout. It answers what GameResult answers, so the runner scores both
# alike, plus the game's own arena time and its moves.
#
# The arena writes one tab-separated line per game, flushed complete and
# ending in the field "ok", then "done N". A line that does not match the
# format exactly (cut off when the arena died, for example) is not a result,
# and a scheduled game without a result fails with NO_RESULT, so a chunk
# always yields a result for every game in it.
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

  attr_reader :winner, :failure, :length, :referee, :error_message, :time_black, :time_white, :duration, :moves

  def self.chunk(text, ids)
    lines = text.split("\n", -1)
    lines.pop if lines.last == ''
    trailer = lines.last && lines.last[TRAILER, 1]
    lines.pop if trailer

    parsed = lines.map { |line| parse_line(line) }
    counts = parsed.compact.map(&:first).tally
    found = parsed.compact.to_h { |id, result| [id, counts[id] == 1 ? result : new(failure: NO_RESULT)] }
    results = ids.to_h { |id| [id, found.fetch(id) { new(failure: NO_RESULT) }] }

    complete = !trailer.nil? && Integer(trailer, 10) == ids.size && parsed.none?(&:nil?) &&
               counts.keys.sort == ids.sort && counts.values.all?(1)
    Chunk.new(results, complete)
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
    moves = moves.split(',', -1)
    return unless moves.size == Integer(length, 10) && moves.all?(VERTEX)

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

  def initialize(winner: nil, failure: nil, crashed: false, length: nil, referee: nil, error_message: nil,
                 time_black: nil, time_white: nil, duration: nil, moves: [])
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
  end

  # True when the loser lost because its network could not play.
  def crashed?
    @crashed
  end

  # The game as SGF, black first, passes as empty moves; nil without a game.
  # GTP columns skip I and rows count from the bottom; SGF letters run from
  # the top left without a gap.
  def sgf(size:, komi:)
    return if moves.empty?

    nodes = moves.each_with_index.map do |vertex, k|
      "#{k.even? ? 'B' : 'W'}[#{sgf_point(vertex, size)}]"
    end
    "(;GM[1]FF[4]SZ[#{size}]KM[#{komi}]RE[#{referee}];#{nodes.join(';')})"
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
