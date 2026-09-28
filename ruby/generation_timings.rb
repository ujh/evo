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
#   round_K=S worker_round_K=S ruby_round_K=S games_round_K=N failures_round_K=N  (each round played, K from 1)
#   tournament=S worker=S ruby=S games=N failures=N  (over those rounds)
#   benchmark=S total=S
# A round's time runs from the first game it queues to its next round's
# pairing. Its worker time is the summed wall time of its pool jobs (arena
# chunks), so above the round's time when jobs run in parallel. Its Ruby time is the round's time the runner spent not waiting
# for a job: pairing, queueing, reading results, scoring, and storing.
class GenerationTimings
  AWAKE = -> { AwakeClock.now }

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

  # Times the block as the part `name` (:setup, :benchmark, or :total).
  def time(name)
    started = @clock.call
    yield
  ensure
    @parts[name] = @clock.call - started
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
    fields['setup'] = seconds(@parts[:setup]) if @parts.key?(:setup)
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
    %i[benchmark total].each { |name| fields[name.to_s] = seconds(@parts[name]) if @parts.key?(name) }
    "timings #{fields.map { |key, value| "#{key}=#{value}" }.join(' ')}"
  end

  def summary
    parts = [("setup #{human(@parts[:setup])}" if @parts.key?(:setup)),
             @rounds.empty? ? 'no tournament round' : "tournament #{human(tournament)}",
             @parts.key?(:benchmark) ? "benchmark #{human(@parts[:benchmark])}" : 'no benchmark'].compact
    lines = ["Generation #{@generation} took #{human(@parts.fetch(:total, 0))}: #{parts.join(', ')}."]
    lines << tournament_summary unless @rounds.empty?
    lines << 'Resumed: the times cover only what this session ran.' if @partial
    lines
  end

  private

  def tournament_summary
    failed = @rounds.select { |r| r.failures.positive? }
    failures = if failed.empty?
                 'none failed'
               else
                 "#{total_of(:failures)} failed (#{failed.map { |r| "round #{r.number}: #{r.failures}" }.join(', ')})"
               end
    "Tournament: #{count(@rounds.size, 'round')}, #{count(total_of(:games), 'game')}, #{failures}; " \
      "workers #{human(total_of(:worker))}, Ruby #{human(total_of(:ruby))} outside waiting for them."
  end

  def tournament = total_of(:wall)

  def total_of(field) = @rounds.sum(&field)

  def count(number, noun) = "#{number} #{noun}#{'s' unless number == 1}"

  def seconds(value) = format('%.3f', value)

  def human(value) = format('%.2f s', value)
end
