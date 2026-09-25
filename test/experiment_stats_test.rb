require 'minitest/autorun'
require 'tmpdir'
require_relative '../ruby/experiment_database'
require_relative '../ruby/experiment_stats'
require_relative '../ruby/setup_experiment'

# ExperimentStats on a small experiment written the way the runner writes
# it: generations 0 to 3 with two rounds each and a checkpoint every second
# generation. Generation 0 is a checkpoint whose benchmark has not been
# played, generation 1 is no checkpoint, generation 2 is a benchmarked
# checkpoint, and generation 3 is still in its first round.
class ExperimentStatsTest < Minitest::Test
  PLAYERS = { 'a.ann' => {}, 'b.ann' => {}, 'c.ann' => {}, 'Brown1' => { 'external' => true } }.freeze

  def setup
    @dir = Dir.mktmpdir('evo-stats')
    path = File.join(@dir, 'experiment.sqlite3')
    writer = ExperimentDatabase.new(path)
    SetupExperiment.save_rules(writer)
    writer.save_settings('tournament_rounds' => 2, 'keep_every' => 2, 'seed' => 1)
    build(writer)
    writer.close
    @database = ExperimentDatabase.new(path, readonly: true)
    @stats = ExperimentStats.new(@database)
  end

  def teardown
    @database.close
    FileUtils.rm_rf(@dir)
  end

  def build(db)
    ranking = ->(*scores) { %w[Brown1 c.ann a.ann b.ann].zip(scores).map { |name, score| { 'name' => name, 'score' => score } } }
    db.save_state(0, { 'round' => 2, 'setup_complete' => true, 'players' => PLAYERS, 'ranking' => ranking.call(5, 3, 1, 2) })
    db.save_state(1, { 'round' => 2, 'setup_complete' => true, 'players' => PLAYERS, 'ranking' => ranking.call(0, 4, 4, 1) })
    db.save_state(2, { 'round' => 2, 'setup_complete' => true, 'players' => PLAYERS, 'ranking' => ranking.call(9, 7, 2, 0) })
    db.save_state(3, { 'round' => 1, 'setup_complete' => true, 'players' => PLAYERS, 'ranking' => ranking.call(1, 0, 0, 0),
                       'games' => [{ 'black' => 'a.ann', 'white' => 'b.ann' }] })

    %w[a.ann b.ann c.ann].each_with_index do |child, i|
      db.record_birth(generation: 0, child:, first_parent: nil, second_parent: nil, operator: 'initial',
                      differs_from_first: nil, differs_from_second: nil, seed: i, genome: "g#{i}")
    end
    # Generation 1: a crossover, a mutation, and a crossover that copied its
    # second parent, so it has the same genome as that parent.
    [['a.ann', 'c.ann', 'a.ann', 'crossover', 5, 7, 'h0'],
     ['b.ann', 'c.ann', 'c.ann', 'mutation', 3, 3, 'h1'],
     ['c.ann', 'b.ann', 'c.ann', 'crossover', 4, 0, 'g2']].each do |child, first, second, operator, one, two, genome|
      db.record_birth(generation: 1, child:, first_parent: first, second_parent: second, operator:,
                      differs_from_first: one, differs_from_second: two, seed: 9, genome:)
    end

    game = lambda do |generation, round, black, white, **rest|
      db.record(generation:, round:, black:, white:, black_external: black == 'Brown1', white_external: white == 'Brown1',
                winner: nil, failure: nil, length: 50, **rest)
    end
    game.call(1, 0, 'a.ann', 'Brown1', winner: 'a.ann', duration: 1.5)
    game.call(1, 0, 'b.ann', 'c.ann') # draw
    game.call(1, 1, 'c.ann', 'Brown1', failure: 'Brown1 crashed', duration: 2.25)
    game.call(1, 1, 'b.ann', 'a.ann', winner: 'b.ann')
    # Recorded before games had timings.
    game.call(0, 0, 'a.ann', 'b.ann', winner: 'b.ann')

    bench = lambda do |opponent, opening, network_color, winner, failure = nil, opponent_network = nil|
      db.record_benchmark_game(generation: 2, opponent:, opening:, network_color:, network: 'c.ann',
                               opponent_network:, winner:, failure:, length: 30, duration: 1.0)
    end
    bench.call('AmiGo', 0, 'black', 'network')
    bench.call('AmiGo', 0, 'white', 'opponent')
    bench.call('AmiGo', 1, 'black', 'network')
    bench.call('AmiGo', 1, 'white', nil) # draw
    bench.call('Brown', 0, 'black', nil, 'Brown crashed')
    bench.call('Brown', 0, 'white', 'network')
    bench.call('Gen0Champion', 0, 'black', 'opponent', nil, '0:c.ann')
    bench.call('Gen0Champion', 0, 'white', 'opponent', nil, '0:c.ann')
  end

  def counts(win: 0, loss: 0, draw: 0, failure: 0) = { win:, loss:, draw:, failure: }

  def test_generations_come_from_the_database
    assert_equal [0, 1, 2, 3], @stats.generations
  end

  def test_a_generation_is_finished_once_it_played_every_round
    assert_equal [true, true, true, false], @stats.generations.map { |g| @stats.generation(g)[:finished] }
    assert_equal 3, @stats.generation(3)[:generation]
  end

  def test_tournament_counts_games_draws_failures_and_time
    assert_equal({ games: 4, draws: 1, failures: 1, game_seconds: 3.75 }, @stats.generation(1)[:tournament])
  end

  def test_game_time_is_nil_without_timings
    assert_equal({ games: 1, draws: 0, failures: 0, game_seconds: nil }, @stats.generation(0)[:tournament])
    assert_equal({ games: 0, draws: 0, failures: 0, game_seconds: nil }, @stats.generation(3)[:tournament])
  end

  def test_population_of_a_bred_generation
    population = @stats.generation(1)[:population]
    assert_equal 3, population[:children]
    assert_equal({ 'crossover' => 2, 'mutation' => 1 }, population[:operators])
    assert_equal 1, population[:identical]
    assert_equal 3, population[:distinct_parents]
    assert_equal 3, population[:unique_genomes]
    # Only the networks' scores, not Brown1's 0.
    assert_equal({ min: 1, median: 4, max: 4 }, population[:scores])
  end

  def test_population_of_the_initial_generation
    population = @stats.generation(0)[:population]
    assert_equal 3, population[:children]
    assert_equal({ 'initial' => 3 }, population[:operators])
    assert_equal 0, population[:identical]
    assert_equal 0, population[:distinct_parents]
    assert_equal 3, population[:unique_genomes]
    # Brown1's 5 is the highest score but no network's.
    assert_equal({ min: 1, median: 2, max: 3 }, population[:scores])
  end

  def test_population_without_births
    population = @stats.generation(2)[:population]
    assert_equal 0, population[:children]
    assert_equal({}, population[:operators])
    assert_equal 0, population[:unique_genomes]
    assert_equal({ min: 0, median: 2, max: 7 }, population[:scores])
  end

  def test_median_of_an_even_count_is_the_mean_of_the_middle_two
    @database.close
    writer = ExperimentDatabase.new(File.join(@dir, 'experiment.sqlite3'))
    writer.save_state(4, { 'round' => 0, 'players' => PLAYERS.merge('d.ann' => {}),
                           'ranking' => [{ 'name' => 'c.ann', 'score' => 4 }, { 'name' => 'd.ann', 'score' => 3 },
                                         { 'name' => 'a.ann', 'score' => 2 }, { 'name' => 'b.ann', 'score' => 0 }] })
    writer.close
    @database = ExperimentDatabase.new(File.join(@dir, 'experiment.sqlite3'), readonly: true)
    assert_equal({ min: 0, median: 2.5, max: 4 }, ExperimentStats.new(@database).generation(4)[:population][:scores])
  end

  def test_scores_are_nil_without_ranked_networks
    @database.close
    writer = ExperimentDatabase.new(File.join(@dir, 'experiment.sqlite3'))
    writer.save_state(4, { 'round' => 0, 'players' => PLAYERS, 'ranking' => [] })
    writer.close
    @database = ExperimentDatabase.new(File.join(@dir, 'experiment.sqlite3'), readonly: true)
    assert_equal({ min: nil, median: nil, max: nil }, ExperimentStats.new(@database).generation(4)[:population][:scores])
  end

  def test_benchmark_of_a_checkpoint_counts_by_the_networks_color_in_panel_order
    benchmark = @stats.generation(2)[:benchmark]
    assert_equal 'c.ann', benchmark[:network]
    assert_equal(
      {
        network: 'c.ann',
        'Brown' => { black: counts(failure: 1), white: counts(win: 1) },
        'AmiGo' => { black: counts(win: 2), white: counts(loss: 1, draw: 1) },
        'Gen0Champion' => { black: counts(loss: 1), white: counts(loss: 1) }
      },
      benchmark
    )
    assert_equal ['Brown', 'AmiGo', 'Gen0Champion'], benchmark.keys.drop(1)
  end

  def test_no_benchmark_for_a_checkpoint_without_games_or_a_generation_that_is_no_checkpoint
    assert_nil @stats.generation(0)[:benchmark]
    assert_nil @stats.generation(1)[:benchmark]
    assert_nil @stats.generation(3)[:benchmark]
  end
end
