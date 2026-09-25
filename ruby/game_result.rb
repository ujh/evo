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
  ERR = 11
  ERR_MSG = 12
  MOVE_LIMIT = 'move limit exceeded'.freeze

  # length is the number of moves played, and referee and error_message are
  # the RES_R and ERR_MSG columns; all three are nil without a game line.
  attr_reader :winner, :failure, :length, :referee, :error_message

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
    columns = { length:, referee: fields[RES_R], error_message: fields[ERR_MSG] }

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

  def initialize(winner: nil, failure: nil, crashed: false, length: nil, referee: nil, error_message: nil)
    @winner = winner
    @failure = failure
    @crashed = crashed
    @length = length
    @referee = referee
    @error_message = error_message
  end

  # True when the loser lost by crashing rather than on the board.
  def crashed?
    @crashed
  end
end
