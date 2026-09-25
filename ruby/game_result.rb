# The outcome of one gogui-twogtp game, read from its .dat file and the stderr
# twogtp wrote to the .err file next to it.
#
# winner is :black, :white, or nil. A nil winner with no failure is a draw. A
# failure means the game has no usable result and must not award points.
class GameResult
  # The .dat file is tab-separated and columns can be empty, so the line must
  # be split on tabs, not whitespace.
  RES_R = 3
  LEN = 6
  TIME_B = 7
  TIME_W = 8
  ERR = 11
  ERR_MSG = 12
  MOVE_LIMIT = 'move limit exceeded'.freeze
  # The referee whose score RES_R holds, in the tournament and the
  # benchmark. It scores by area (Chinese rules), as the arena does; twogtp
  # sends it the experiment's komi. Callers append its --seed.
  REFEREE = 'gnugo --mode gtp --chinese-rules'.freeze

  # length is the number of moves played, referee and error_message are the
  # RES_R and ERR_MSG columns, and time_black and time_white the seconds each
  # player used; all are nil without a game line.
  attr_reader :winner, :failure, :length, :referee, :error_message, :time_black, :time_white

  def self.read(prefix)
    dat = "#{prefix}.dat"
    return new(failure: 'no result file') unless File.exist?(dat)

    line = File.readlines(dat, chomp: true).reject { |l| l.start_with?('#') || l.empty? }.last
    return new(failure: 'no game in result file') unless line

    err = "#{prefix}.err"
    parse(line, File.exist?(err) ? File.read(err) : '')
  end

  def self.parse(line, stderr = '')
    fields = line.split("\t", -1)
    length = Integer(fields[LEN], exception: false)
    columns = { length:, referee: fields[RES_R], error_message: fields[ERR_MSG],
                time_black: Float(fields[TIME_B], exception: false),
                time_white: Float(fields[TIME_W], exception: false) }

    # twogtp says which program died only on stderr; the .dat file just says
    # "The Go program terminated unexpectedly."
    return new(winner: :white, crashed: true, **columns) if stderr.include?('Black program died')
    return new(winner: :black, crashed: true, **columns) if stderr.include?('White program died')

    error = fields[ERR]
    message = fields[ERR_MSG]
    return new(failure: "error: #{message}", **columns) if error != '0' && message != MOVE_LIMIT

    referee = fields[RES_R]
    case referee
    when /\AB\+/ then new(winner: :black, **columns)
    when /\AW\+/ then new(winner: :white, **columns)
    when '0' then new(**columns)
    else new(failure: "no referee score: #{referee}", **columns)
    end
  end

  def initialize(winner: nil, failure: nil, crashed: false, length: nil, referee: nil, error_message: nil,
                 time_black: nil, time_white: nil)
    @winner = winner
    @failure = failure
    @crashed = crashed
    @length = length
    @referee = referee
    @error_message = error_message
    @time_black = time_black
    @time_white = time_white
  end

  # True when the loser lost by crashing rather than on the board.
  def crashed?
    @crashed
  end
end
