require_relative 'test_helper'
require 'open3'
require 'rbconfig'
require_relative '../ruby/checkpoint_benchmark'

class CheckpointBenchmarkTest < Minitest::Test
  include RunGenerationHelpers

  # Every generation that the tests benchmark or take a network from ranks
  # a bot first, then b.ann, then a.ann, so b.ann is its top network.
  def store_generations(*generations)
    generations.each do |g|
      %w[a.ann b.ann].each { |name| database.record_network(g, name, "#{name} of #{g}") }
      database.save_state(g, { 'players' => { 'Brown1' => { 'external' => true }, 'a.ann' => {}, 'b.ann' => {} },
                               'ranking' => [{ 'name' => 'Brown1', 'score' => 3 }, { 'name' => 'b.ann', 'score' => 2 },
                                             { 'name' => 'a.ann', 'score' => 1 }] })
    end
  end

  # A database whose panel has only these of the default opponents. Call it
  # before anything else uses the database.
  def only_opponents(*names)
    @database = ExperimentDatabase.new(':memory:')
    @database.save_benchmark_opponents(SetupExperiment::DEFAULT_BENCHMARK.select { |o| names.include?(o[:name]) })
  end

  # Runs the benchmark of `generation` in the current directory with a pool
  # that leaves the given fixture's files for every game (or the fixture the
  # block picks for the game), and returns the pool.
  def run_benchmark(generation, settings: {}, fixture: 'black_wins', &pick)
    pool = FakePool.new do |game|
      copy_dat(pick ? pick.call(game) : fixture, game.prefix)
      File.write("#{game.prefix}-0.sgf", '(;SZ[9])')
    end
    capture_io do
      @played_any = CheckpointBenchmark.new(generation, SETTINGS.merge('benchmark_games' => 2).merge(settings), pool,
                                            database).call
    end
    pool
  end

  def played(generation)
    database.benchmark_games(generation).map { |row| row.values_at(:opponent, :opening, :network_color, :opponent_network) }
  end

  def test_generation_zero_plays_only_the_bots
    in_experiment do
      store_generations(0)
      run_benchmark(0)
      assert_equal [['AmiGo', 0, 'black', nil], ['AmiGo', 0, 'white', nil], ['Brown', 0, 'black', nil],
                    ['Brown', 0, 'white', nil], ['GnuGoLevel0', 0, 'black', nil], ['GnuGoLevel0', 0, 'white', nil]],
                   played(0)
      assert @played_any
    end
  end

  # The previous checkpoint of the first checkpoint is generation 0, whose
  # champion is already on the panel.
  def test_the_first_checkpoint_plays_the_initial_champion_but_no_previous_checkpoint
    in_experiment(generation: '10') do
      only_opponents('Gen0Champion', 'PreviousCheckpoint')
      store_generations(0, 10)
      run_benchmark(10)
      assert_equal [['Gen0Champion', 0, 'black', '0:b.ann'], ['Gen0Champion', 0, 'white', '0:b.ann']], played(10)
    end
  end

  def test_later_checkpoints_play_the_previous_checkpoints_top_network
    in_experiment(generation: '20') do
      only_opponents('Gen0Champion', 'PreviousCheckpoint')
      store_generations(0, 10, 20)
      pool = run_benchmark(20)
      assert_equal %w[0:b.ann 0:b.ann 10:b.ann 10:b.ann], played(20).map(&:last)
      assert_includes pool.commands.first, '-black "../evo benchmark/20-b.ann" -white "../evo benchmark/0-b.ann"'
      assert_equal 'b.ann of 10', File.binread('benchmark/10-b.ann')
      assert_equal 'b.ann of 20', File.binread('benchmark/20-b.ann')
      assert_equal %w[b.ann], database.benchmark_games(20).map { |row| row[:network] }.uniq
    end
  end

  # ExperimentStats counts a checkpoint's benchmark as complete by the same
  # rule the runner plays it by.
  def test_the_opponents_of_a_checkpoint_depend_on_its_generation
    panel = SetupExperiment::DEFAULT_BENCHMARK
    names = ->(generation) { CheckpointBenchmark.opponents_for(generation, panel, 10).map { |o| o[:name] } }
    assert_equal %w[Brown AmiGo GnuGoLevel0], names.call(0)
    assert_equal %w[Brown AmiGo GnuGoLevel0 Gen0Champion], names.call(10)
    assert_equal %w[Brown AmiGo GnuGoLevel0 Gen0Champion PreviousCheckpoint], names.call(20)
    assert_raises(ArgumentError) { CheckpointBenchmark.opponents_for(0, [{ name: 'X', kind: 'nope' }], 10) }
  end

  def test_each_opening_is_played_once_with_each_color
    in_experiment do
      only_opponents('Brown')
      store_generations(0)
      run_benchmark(0, settings: { 'benchmark_games' => 4 })
      assert_equal [['Brown', 0, 'black', nil], ['Brown', 0, 'white', nil], ['Brown', 1, 'black', nil],
                    ['Brown', 1, 'white', nil]], played(0)
    end
  end

  def test_the_command_plays_the_opening_and_seeds_gnu_go
    in_experiment do
      only_opponents('GnuGoLevel0')
      store_generations(0)
      commands = run_benchmark(0).commands
      seed = ->(color) { Seeds.gnugo(1, 'benchmark', 0, 'GnuGoLevel0', 0, color) }
      gnugo = ->(color) { "gnugo --level 0 --mode gtp --seed #{seed.call(color)}" }
      # twogtp counts the opening's stones toward the move limit.
      assert_equal [%(gogui-twogtp -black "../evo benchmark/0-b.ann" -white "#{gnugo.call('black')}" ) +
                    %(-referee "gnugo --mode gtp --chinese-rules --seed #{seed.call('black')}" -size 9 -komi 6.5 ) +
                    '-auto -games 1 -sgffile benchmark/GnuGoLevel0-0-black -time 10 -force -maxmoves 204 ' \
                    '-openings benchmark/openings/0 2> benchmark/GnuGoLevel0-0-black.err',
                    %(gogui-twogtp -black "#{gnugo.call('white')}" -white "../evo benchmark/0-b.ann" ) +
                    %(-referee "gnugo --mode gtp --chinese-rules --seed #{seed.call('white')}" -size 9 -komi 6.5 ) +
                    '-auto -games 1 -sgffile benchmark/GnuGoLevel0-0-white -time 10 -force -maxmoves 204 ' \
                    '-openings benchmark/openings/0 2> benchmark/GnuGoLevel0-0-white.err'], commands
      assert_equal Openings.sgf(9, Openings.moves(1, 0, 9, 4)), File.read('benchmark/openings/0/opening.sgf')
    end
  end

  def test_the_command_gives_the_experiment_komi
    in_experiment do
      only_opponents('Brown')
      store_generations(0)
      commands = run_benchmark(0, settings: { 'komi' => -3.0 }).commands
      commands.each { |command| assert_includes command, ' -komi -3.0 ' }
    end
  end

  def test_without_opening_moves_the_games_start_on_an_empty_board
    in_experiment do
      only_opponents('Brown')
      store_generations(0)
      commands = run_benchmark(0, settings: { 'benchmark_opening_moves' => 0 }).commands
      assert_equal 2, commands.size
      commands.each do |command|
        refute_includes command, '-openings'
        assert_includes command, '-maxmoves 200 '
      end
      refute Dir.exist?('benchmark/openings')
    end
  end

  def test_the_openings_are_the_same_at_every_checkpoint
    in_experiment(generation: '20') do
      only_opponents('Brown')
      store_generations(0, 10, 20)
      run_benchmark(10)
      first = File.read('benchmark/openings/0/opening.sgf')
      FileUtils.rm_rf('benchmark')
      run_benchmark(20)
      assert_equal first, File.read('benchmark/openings/0/opening.sgf')
    end
  end

  def outcomes(opponents, fixtures)
    in_experiment(generation: '10') do
      only_opponents(*opponents)
      store_generations(0, 10)
      run_benchmark(10) { |game| fixtures.fetch(game.color) }
      database.benchmark_games(10).map { |row| row.values_at(:network_color, :winner, :failure) }
    end
  end

  def test_the_referee_decides_whichever_color_the_network_has
    assert_equal [['black', 'network', nil], ['white', 'opponent', nil]],
                 outcomes(%w[Brown], 'black' => 'black_wins', 'white' => 'black_wins')
  end

  def test_a_draw_has_no_winner_and_is_no_failure
    assert_equal [['black', nil, nil], ['white', nil, nil]], outcomes(%w[Brown], 'black' => 'draw', 'white' => 'draw')
  end

  def test_a_crashed_network_loses
    # Black crashed in black_crashed, white in white_crashed.
    assert_equal [['black', 'opponent', nil], ['white', 'opponent', nil]],
                 outcomes(%w[Brown], 'black' => 'black_crashed', 'white' => 'white_crashed')
  end

  def test_a_crashed_opponent_network_loses
    assert_equal [['black', 'network', nil], ['white', 'network', nil]],
                 outcomes(%w[Gen0Champion], 'black' => 'white_crashed', 'white' => 'black_crashed')
  end

  def test_a_crashed_bot_is_a_failure
    assert_equal [['black', nil, 'Brown crashed'], ['white', nil, 'Brown crashed']],
                 outcomes(%w[Brown], 'black' => 'white_crashed', 'white' => 'black_crashed')
  end

  def test_a_game_without_a_result_is_a_failure
    assert_equal [['black', nil, 'no referee score: ?'], ['white', nil, 'error: Brown: illegal move']],
                 outcomes(%w[Brown], 'black' => 'no_referee_score', 'white' => 'illegal_move')
  end

  def test_stores_each_game_and_deletes_its_files
    in_experiment do
      only_opponents('Brown')
      store_generations(0)
      run_benchmark(0) { |game| game.color == 'black' ? 'black_wins' : 'white_crashed' }
      assert_equal [{ generation: 0, opponent: 'Brown', opening: 0, network_color: 'black', network: 'b.ann',
                      opponent_network: nil, winner: 'network', failure: nil, length: 93, referee_result: 'B+R',
                      error_message: '', stderr: nil, duration: 1.5, time_black: 0.0, time_white: 0.0 },
                    { generation: 0, opponent: 'Brown', opening: 0, network_color: 'white', network: 'b.ann',
                      opponent_network: nil, winner: 'opponent', failure: nil, length: 5, referee_result: 'W+71.5',
                      error_message: 'The Go program terminated unexpectedly.', stderr: "White program died\n",
                      duration: 1.5, time_black: 0.0, time_white: 0.0 }],
                   database.benchmark_games(0)
      assert_empty Dir['benchmark/Brown-*']
    end
  end

  def test_a_resumed_benchmark_plays_only_the_missing_games
    in_experiment do
      only_opponents('Brown', 'AmiGo')
      store_generations(0)
      database.record_benchmark_game(generation: 0, opponent: 'Brown', opening: 0, network_color: 'white',
                                     network: 'b.ann', winner: 'opponent')
      commands = run_benchmark(0).commands
      assert_equal %w[AmiGo-0-black AmiGo-0-white Brown-0-black],
                   commands.map { |c| c[%r{-sgffile benchmark/(\S+)}, 1] }.sort
      assert_equal 'opponent', database.benchmark_games(0).find { |r| r[:network_color] == 'white' && r[:opponent] == 'Brown' }[:winner]
    end
  end

  def test_a_finished_benchmark_plays_nothing
    in_experiment do
      only_opponents('Brown')
      store_generations(0)
      %w[black white].each do |color|
        database.record_benchmark_game(generation: 0, opponent: 'Brown', opening: 0, network_color: color, network: 'b.ann')
      end
      assert_empty run_benchmark(0).commands
      refute @played_any
    end
  end

  def test_stopping_leaves_the_finished_game_to_be_replayed
    in_experiment do
      only_opponents('Brown')
      store_generations(0)
      pool = FakePool.new { $stop_now = true }
      capture_io { assert_raises(SystemExit) { CheckpointBenchmark.new(0, SETTINGS.merge('benchmark_games' => 2), pool, database).call } }
      assert_empty database.benchmark_games(0)
    ensure
      $stop_now = false
    end
  end

  # Ruby's benchmark library defines a Benchmark module, so the class has
  # another name. A fresh process, because this one has loaded the class
  # already, and outside Bundler, which hides the gem since Ruby 4.0.
  def test_loads_together_with_rubys_benchmark_library
    script = <<~RUBY
      begin
        require 'benchmark'
      rescue LoadError
        exit 2
      end
      require #{File.expand_path('../ruby/checkpoint_benchmark', __dir__).inspect}
      print CheckpointBenchmark.class
    RUBY
    run = -> { Open3.capture3(RbConfig.ruby, '-e', script) }
    out, err, status = defined?(Bundler) ? Bundler.with_unbundled_env(&run) : run.call
    skip "Ruby's benchmark library is not installed" if status.exitstatus == 2
    assert status.success?, err
    assert_equal 'Class', out
  end
end
