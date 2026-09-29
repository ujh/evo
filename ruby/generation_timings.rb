require_relative 'awake_clock'

# Times the parts of one generation with AwakeClock, the clock WorkerPool
# times its jobs by (it stops while the machine sleeps), for the
# summary and the machine-readable line printed when it ends. Nothing is
# stored: a generation resumed part-way (`partial`) is timed only for what
# this session ran, and its summary says so.
#
# The line is `timings` followed by key=value fields, seconds with three
# decimals, and only the parts that ran:
#   generation=N partial=0|1 setup=S
#   setup_clear=S setup_breed=S setup_hash=S setup_store=S setup_sync=S setup_save=S
#   setup_retire=S setup_verify=S  (the parts of setup)
#   round_K=S worker_round_K=S ruby_round_K=S games_round_K=N failures_round_K=N  (each round played, K from 1)
#   tournament=S worker=S ruby=S games=N failures=N  (over those rounds)
#   champion=S benchmark=S total=S
# A round's time runs from the first game it queues to its next round's
# pairing. Its worker time is the summed wall time of its pool jobs (arena
# chunks), so above the round's time when jobs run in parallel. Its Ruby
# time is the round's time the runner spent not waiting for the pool:
# pairing, queueing, and reading, scoring, and storing each arena record as
# it arrives, while the arenas play.
# The parts of setup are within `setup` and, but for setup_hash and
# setup_store, come one after another: emptying work/, breeding the
# children or running initial-population, syncing networks/N.partial/ and
# renaming it to networks/N/, saving the state, deleting network
# directories no longer needed (stale ones at the start, the parents after
# the save; the two add up), and, on resume, verifying networks/N/ against
# the births. They leave small untimed gaps (loading the previous
# generation's state, pairing round 1), so they add up to a little less
# than `setup`. setup_hash and setup_store, the summed time of hashing each
# network and of storing the births in one transaction, are within
# setup_breed. `champion`, at a checkpoint, is reading its champion's file
# and the last round's save that stores it, within that round's time.
class GenerationTimings
  AWAKE = -> { AwakeClock.now }

  # The parts of setup in the line's order, with their summary names.
  SETUP_PARTS = { setup_clear: 'emptying work/', setup_breed: 'breeding', setup_hash: 'hashing',
                  setup_store: 'storing', setup_sync: 'syncing', setup_save: 'saving',
                  setup_retire: 'deleting old networks', setup_verify: 'verifying' }.freeze
  # The parts of setup timed within setup_breed.
  WITHIN_BREED = %i[setup_hash setup_store].freeze

  Round = Struct.new(:number, :wall, :waiting, :worker, :games, :failures) do
    def ruby = wall - waiting
  end

  # `clock` returns seconds when called; tests pass one that stands still.
  def initialize(generation, partial:, clock: AWAKE)
    @generation = generation
    @partial = partial
    @clock = clock
    @parts = {}
    @rounds = []
  end

  # Times the block as the part `name` (:setup, a part of SETUP_PARTS,
  # :champion, :benchmark, or :total). A part timed more than once adds up.
  def time(name)
    started = @clock.call
    yield
  ensure
    @parts[name] = @parts.fetch(name, 0.0) + (@clock.call - started)
  end

  # Times the block as tournament round `number`, counted from 1.
  def round(number)
    @current = Round.new(number, 0.0, 0.0, 0.0, 0, 0)
    started = @clock.call
    yield
  ensure
    @current.wall = @clock.call - started
    @rounds << @current
    @current = nil
  end

  # Times the block as waiting for the workers.
  def wait
    started = @clock.call
    yield
  ensure
    @current.waiting += @clock.call - started if @current
  end

  # A job of the round took `seconds` on its worker.
  def job(seconds)
    @current.worker += seconds if @current
  end

  # A game of the round was scored, failed when `failure` is set.
  def game(failure)
    return unless @current

    @current.games += 1
    @current.failures += 1 if failure
  end

  def report(io = $stdout)
    io.puts(summary, line)
  end

  def line
    fields = { 'generation' => @generation, 'partial' => @partial ? 1 : 0 }
    (%i[setup] + SETUP_PARTS.keys).each { |name| fields[name.to_s] = seconds(@parts[name]) if @parts.key?(name) }
    @rounds.each do |r|
      k = r.number
      fields.merge!("round_#{k}" => seconds(r.wall), "worker_round_#{k}" => seconds(r.worker),
                    "ruby_round_#{k}" => seconds(r.ruby), "games_round_#{k}" => r.games,
                    "failures_round_#{k}" => r.failures)
    end
    unless @rounds.empty?
      fields.merge!('tournament' => seconds(tournament), 'worker' => seconds(total_of(:worker)),
                    'ruby' => seconds(total_of(:ruby)), 'games' => total_of(:games), 'failures' => total_of(:failures))
    end
    %i[champion benchmark total].each { |name| fields[name.to_s] = seconds(@parts[name]) if @parts.key?(name) }
    "timings #{fields.map { |key, value| "#{key}=#{value}" }.join(' ')}"
  end

  def summary
    parts = [("setup #{human(@parts[:setup])}" if @parts.key?(:setup)),
             @rounds.empty? ? 'no tournament round' : "tournament #{human(tournament)}",
             @parts.key?(:benchmark) ? "benchmark #{human(@parts[:benchmark])}" : 'no benchmark'].compact
    lines = ["Generation #{@generation} took #{human(@parts.fetch(:total, 0))}: #{parts.join(', ')}."]
    lines << setup_summary if SETUP_PARTS.keys.any? { |name| @parts.key?(name) }
    lines << tournament_summary unless @rounds.empty?
    lines << 'Resumed: the times cover only what this session ran.' if @partial
    lines
  end

  private

  def setup_summary
    parts = SETUP_PARTS.except(*WITHIN_BREED).filter_map do |name, label|
      next unless @parts.key?(name)

      "#{label} #{human(@parts[name])}#{within_breed if name == :setup_breed}"
    end
    "Setup: #{parts.join(', ')}."
  end

  def within_breed
    parts = WITHIN_BREED.filter_map { |name| "#{SETUP_PARTS[name]} #{human(@parts[name])}" if @parts.key?(name) }
    " (#{parts.join(' and ')} during it)" unless parts.empty?
  end

  def tournament_summary
    failed = @rounds.select { |r| r.failures.positive? }
    failures = if failed.empty?
                 'none failed'
               else
                 "#{total_of(:failures)} failed (#{failed.map { |r| "round #{r.number}: #{r.failures}" }.join(', ')})"
               end
    champion = "; storing the champion #{human(@parts[:champion])} of it" if @parts.key?(:champion)
    "Tournament: #{count(@rounds.size, 'round')}, #{count(total_of(:games), 'game')}, #{failures}; " \
      "workers #{human(total_of(:worker))}, Ruby #{human(total_of(:ruby))} outside waiting for them#{champion}."
  end

  def tournament = total_of(:wall)

  def total_of(field) = @rounds.sum(&field)

  def count(number, noun) = "#{number} #{noun}#{'s' unless number == 1}"

  def seconds(value) = format('%.3f', value)

  def human(value) = format('%.2f s', value)
end
