require 'minitest/autorun'
require 'delegate'
require 'tmpdir'
require_relative '../ruby/experiment_database'
require_relative '../ruby/experiment_stats'
require_relative 'stats_fixture'

# ExperimentStats on the experiment in StatsFixture.
class ExperimentStatsTest < Minitest::Test
  PLAYERS = StatsFixture::PLAYERS

  def setup
    @dir = Dir.mktmpdir('evo-stats')
    path = File.join(@dir, 'experiment.sqlite3')
    StatsFixture.create(path)
    @database = ExperimentDatabase.new(path, readonly: true)
    @stats = ExperimentStats.new(@database)
  end

  def teardown
    @database.close
    FileUtils.rm_rf(@dir)
  end

  def counts(win: 0, loss: 0, draw: 0, failure: 0) = { win:, loss:, draw:, failure: }

  def test_generations_come_from_the_database
    assert_equal [0, 1, 2, 3], @stats.generations
  end

  def test_benchmark_opponents_are_the_panel_in_order
    assert_equal %w[Brown AmiGo GnuGoLevel0 Gen0Champion PreviousCheckpoint], @stats.benchmark_opponents
  end

  # Generations 0 and 2 played every round, but their benchmarks are not
  # complete.
  def test_a_generation_is_finished_once_it_played_every_round_and_its_benchmark
    assert_equal [false, true, false, false], @stats.generations.map { |g| @stats.generation(g)[:finished] }
    assert_equal 3, @stats.generation(3)[:generation]
  end

  def test_a_checkpoint_is_finished_once_every_benchmark_game_is_stored
    reopen_writing do |writer|
      [['Brown', 1], ['Gen0Champion', 1], ['GnuGoLevel0', 0], ['GnuGoLevel0', 1]].each do |opponent, opening|
        %w[black white].each do |network_color|
          writer.record_benchmark_game(generation: 2, opponent:, opening:, network_color:, network: 'c.ann', winner: 'network')
        end
      end
    end
    assert @stats.generation(2)[:benchmark][:complete]
    assert @stats.generation(2)[:finished]
  end

  # Only the columns the figures need, not every game's SGF and stderr.
  def test_reads_no_sgf_or_stderr
    recorder = Class.new(SimpleDelegator) do
      attr_reader :columns

      def games(generation, columns:) = (@columns ||= []).concat(columns) && super
      def benchmark_games(generation, columns:) = (@columns ||= []).concat(columns) && super
    end.new(@database)
    ExperimentStats.new(recorder).generation(2)
    refute_empty recorder.columns
    assert_empty recorder.columns & %i[sgf stderr error_message referee_result]
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
    assert_equal({ 'initial' => 0, 'crossover' => 2, 'mutation' => 1, 'copy' => 0 }, population[:operators])
    assert_equal 1, population[:identical]
    # a.ann and c.ann; b.ann's only child copied c.ann.
    assert_equal 2, population[:distinct_parents]
    assert_equal 3, population[:unique_genomes]
    # Only the networks' scores, not Brown1's 0.
    assert_equal({ min: 1, median: 4, max: 4 }, population[:scores])
  end

  def test_population_of_the_initial_generation
    population = @stats.generation(0)[:population]
    assert_equal 3, population[:children]
    assert_equal({ 'initial' => 3, 'crossover' => 0, 'mutation' => 0, 'copy' => 0 }, population[:operators])
    assert_equal 0, population[:identical]
    assert_equal 0, population[:distinct_parents]
    assert_equal 3, population[:unique_genomes]
    # Brown1's 5 is the highest score but no network's.
    assert_equal({ min: 1, median: 2, max: 3 }, population[:scores])
  end

  def test_population_without_births
    population = @stats.generation(2)[:population]
    assert_equal 0, population[:children]
    assert_equal({ 'initial' => 0, 'crossover' => 0, 'mutation' => 0, 'copy' => 0 }, population[:operators])
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

  # A mutation or a copy comes from the parent evolve picked.
  def test_distinct_parents_count_only_the_parent_a_mutation_or_copy_was_picked_from
    assert_equal 1, distinct_parents(['a.ann', 'b.ann', 'mutation', 3, 40, 'second'], ['b.ann', 'c.ann', 'mutation', 40, 3, 'first'])
    assert_equal 1, distinct_parents(['a.ann', 'b.ann', 'copy', 0, 7, 'first'], ['a.ann', 'c.ann', 'mutation', 3, 3, 'first'])
    assert_equal 2, distinct_parents(['a.ann', 'b.ann', 'copy', 7, 0, 'second'], ['a.ann', 'c.ann', 'mutation', 3, 3, 'first'])
  end

  # A child of another shape than a parent has no differs count for it.
  def test_distinct_parents_of_children_without_differs_counts
    assert_equal 2, distinct_parents(['a.ann', 'b.ann', 'mutation', nil, nil, 'first'],
                                     ['c.ann', 'b.ann', 'mutation', nil, 5, 'second'])
  end

  # Rows from before the parent column: a mutation came from the parent it
  # differs less from, the first when both are equal.
  def test_distinct_parents_of_mutations_without_a_parent_follow_the_differs_counts
    assert_equal 1, distinct_parents(['a.ann', 'b.ann', 'mutation', 40, 3], ['b.ann', 'c.ann', 'mutation', 3, 40])
    assert_equal 1, distinct_parents(['a.ann', 'b.ann', 'mutation', 3, 3], ['a.ann', 'c.ann', 'mutation', 3, 3])
  end

  def test_distinct_parents_count_both_parents_of_a_crossover
    assert_equal 2, distinct_parents(['a.ann', 'b.ann', 'crossover', 5, 7, 'first'])
  end

  def test_distinct_parents_count_only_the_parent_a_crossover_copied
    assert_equal 1, distinct_parents(['a.ann', 'b.ann', 'crossover', 0, 7, 'first'], ['a.ann', 'c.ann', 'crossover', 0, 7, 'second'])
    assert_equal 1, distinct_parents(['a.ann', 'b.ann', 'crossover', 5, 0, 'first'], ['c.ann', 'b.ann', 'crossover', 5, 0, 'first'])
  end

  def test_distinct_parents_count_a_parent_of_several_children_once
    assert_equal 3, distinct_parents(['a.ann', 'b.ann', 'mutation', 40, 3, 'second'], ['b.ann', 'c.ann', 'crossover', 5, 7, 'first'],
                                     ['a.ann', 'c.ann', 'crossover', 0, 7, 'first'], ['c.ann', 'd.ann', 'mutation', 2, 9, 'first'])
  end

  # Copies count as identical children, and a child without differs counts
  # (another shape) is not identical.
  def test_population_counts_copies_and_children_without_differs_counts
    population = population_of(['a.ann', 'b.ann', 'copy', 0, 4, 'first'], ['a.ann', 'b.ann', 'copy', nil, 0, 'second'],
                               ['a.ann', 'b.ann', 'mutation', nil, nil, 'first'], ['a.ann', 'b.ann', 'mutation', 2, 3, 'first'])
    assert_equal({ 'initial' => 0, 'crossover' => 0, 'mutation' => 2, 'copy' => 2 }, population[:operators])
    assert_equal 2, population[:identical]
    assert_equal 2, population[:distinct_parents]
  end

  # Every opponent the checkpoint plays, in panel order, whether played yet
  # or not. PreviousCheckpoint would be generation 0, so it is not played.
  def test_benchmark_of_a_checkpoint_counts_by_the_networks_color_in_panel_order
    benchmark = @stats.generation(2)[:benchmark]
    assert_equal(
      {
        network: 'c.ann',
        games: 4,
        complete: false,
        'Brown' => { black: counts(failure: 1), white: counts(win: 1) },
        'AmiGo' => { black: counts(win: 2), white: counts(loss: 1, draw: 1) },
        'GnuGoLevel0' => { black: counts, white: counts },
        'Gen0Champion' => { black: counts(loss: 1), white: counts(loss: 1) }
      },
      benchmark
    )
    assert_equal [:network, :games, :complete, 'Brown', 'AmiGo', 'GnuGoLevel0', 'Gen0Champion'], benchmark.keys
  end

  # Generation 0 plays only the bots.
  def test_benchmark_of_a_checkpoint_without_games_is_incomplete
    assert_equal(
      { network: nil, games: 4, complete: false, 'Brown' => { black: counts, white: counts },
        'AmiGo' => { black: counts, white: counts }, 'GnuGoLevel0' => { black: counts, white: counts } },
      @stats.generation(0)[:benchmark]
    )
  end

  def test_no_benchmark_for_a_generation_that_is_no_checkpoint
    assert_nil @stats.generation(1)[:benchmark]
    assert_nil @stats.generation(3)[:benchmark]
  end

  # Same weights with a switched activation is no copy.
  def test_a_mutation_that_switched_an_activation_is_not_identical
    reopen_writing do |writer|
      writer.record_birth(generation: 4, child: '0.ann', first_parent: 'a.ann', second_parent: 'b.ann',
                          operator: 'mutation', parent: 'first', activation_changed: true,
                          differs_from_first: 0, differs_from_second: 5, seed: 0, genome: 'x0')
      writer.save_state(4, { 'round' => 0, 'players' => PLAYERS, 'ranking' => [] })
    end
    assert_equal 0, @stats.generation(4)[:population][:identical]
  end

  # A crossover takes the picked parent's activations, so a child with all
  # of the other parent's weights still differs from both when their
  # activations differ.
  def test_a_crossover_with_one_parents_weights_and_the_others_activations_is_not_identical
    reopen_writing do |writer|
      [%w[m.ann tanh sigmoid], %w[p.ann sigmoid_cached sigmoid_cached]].each_with_index do |(child, hidden, output), i|
        writer.record_birth(generation: 3, child:, operator: 'initial', seed: i, genome: "p#{i}",
                            act_hidden: hidden, act_output: output)
      end
      [['0.ann', 'sigmoid_cached', 0], ['1.ann', 'tanh', 1]].each_with_index do |(child, hidden, seed), i|
        writer.record_birth(generation: 4, child:, first_parent: 'm.ann', second_parent: 'p.ann', operator: 'crossover',
                            parent: 'second', activation_changed: false, differs_from_first: 0,
                            differs_from_second: 3, seed:, genome: "c#{i}", act_hidden: hidden,
                            act_output: hidden == 'tanh' ? 'sigmoid' : 'sigmoid_cached')
      end
      writer.save_state(4, { 'round' => 0, 'players' => PLAYERS, 'ranking' => [] })
    end
    # 0.ann has m.ann's weights and p.ann's activations; 1.ann is m.ann.
    assert_equal 1, @stats.generation(4)[:population][:identical]
  end

  def test_genes_of_a_generation_by_median_and_range
    assert_equal(
      { 'copy_chance' => { min: 0.005, median: 0.01, max: 0.02 },
        'weight_changes' => { min: 1.0, median: 2.5, max: 4.0 },
        'weight_step' => { min: 0.4, median: 0.5, max: 0.6 },
        'activation_rate' => { min: 0.02, median: 0.02, max: 0.02 },
        'structure_rate' => { min: 0.01, median: 0.02, max: 0.03 },
        'feature_step' => { min: 0.008, median: 0.01, max: 0.012 },
        'fw_hane' => { min: 0.05, median: 0.05, max: 0.06 },
        'fw_cut' => { min: 0.05, median: 0.05, max: 0.05 },
        'fw_edge' => { min: 0.05, median: 0.05, max: 0.05 },
        'fw_capture' => { min: 0.99, median: 1.0, max: 1.02 },
        'fw_self_atari' => { min: -1.0, median: -1.0, max: -0.97 },
        'fw_saves_atari' => { min: 0.8, median: 0.8, max: 0.8 } },
      @stats.generation(1)[:genes]
    )
  end

  # Only the move features of the experiment's set have a weight; without
  # features there is only feature_step, which every network has.
  def test_feature_weights_follow_the_experiments_feature_set
    reopen_writing { |writer| writer.save_settings(StatsFixture::SETTINGS.merge('features' => 'none')) }
    genes = figures_of({ features: 'none', fw_hane: nil, fw_cut: nil, fw_edge: nil, fw_capture: nil,
                         fw_self_atari: nil, fw_saves_atari: nil })[:genes]
    assert_equal ExperimentStats::GENES + ['feature_step'], genes.keys
    assert_equal({ min: 0.01, median: 0.01, max: 0.01 }, genes['feature_step'])
    reopen_writing { |writer| writer.save_settings(StatsFixture::SETTINGS.merge('features' => FeatureGroups::ALL)) }
    genes = figures_of({ features: FeatureGroups::ALL, fw_near_last: 0.04 })[:genes]
    assert_equal %w[fw_hane fw_cut fw_edge fw_capture fw_self_atari fw_saves_atari fw_near_last], genes.keys.grep(/\Afw_/)
    assert_equal({ min: 0.04, median: 0.04, max: 0.04 }, genes['fw_near_last'])
  end

  # Total weights for 9x9 with the shapes and tactics groups: 82 inputs
  # (komi and the stones) plus six planes of 81, and 82 outputs.
  def test_shapes_of_a_generation
    assert_equal(
      { layers: { min: 1, median: 1, max: 1 }, width: { min: 10, median: 10, max: 11 }, weights: { min: 6592, median: 6592, max: 7243 },
        counts: { '1x10' => 2, '1x11' => 1 } },
      @stats.generation(1)[:shape]
    )
  end

  # Without hidden layers the network is one layer of (inputs + 1) x
  # outputs weights; with two, the second hidden layer adds (width + 1) x
  # width.
  def test_total_weights_of_other_depths
    shape = figures_of({ layers: 0, width: 0 }, { layers: 2, width: 10 }, { layers: 2, width: 10 })[:shape]
    assert_equal({ min: 6702, median: 6702, max: 46658 }, shape[:weights])
    assert_equal({ '0x0' => 1, '2x10' => 2 }, shape[:counts])
    assert_equal({ min: 0, median: 2, max: 2 }, shape[:layers])
  end

  # The weights count the inputs of the experiment's feature set: 1,732 for
  # a 9x9 1x10 network without features, 10,652 with all of them.
  def test_total_weights_count_the_feature_inputs
    { 'none' => 1732, FeatureGroups::ALL => 10_652 }.each do |features, weights|
      reopen_writing { |writer| writer.save_settings(StatsFixture::SETTINGS.merge('features' => features)) }
      assert_equal({ min: weights, median: weights, max: weights }, figures_of({})[:shape][:weights], features)
    end
  end

  # Without the setting the weights (and the feature weights shown) would
  # be guessed, so an experiment created before it fails as the runner
  # does.
  def test_an_experiment_without_features_fails
    reopen_writing { |writer| writer.save_settings(StatsFixture::SETTINGS.except('features')) }
    error = assert_raises(ExperimentStats::MissingSetting) { @stats.generation(1) }
    assert_equal 'features is missing', error.message
    reopen_writing { |writer| writer.save_settings(StatsFixture::SETTINGS.except('board_size')) }
    error = assert_raises(ExperimentStats::MissingSetting) { @stats.generation(1) }
    assert_equal 'board_size is missing', error.message
  end

  def test_activations_count_every_name
    activation = @stats.generation(1)[:activation]
    assert_equal({ 'sigmoid' => 0, 'sigmoid_cached' => 2, 'threshold' => 0, 'linear' => 0, 'tanh' => 1, 'relu' => 0 },
                 activation[:hidden])
    assert_equal({ 'sigmoid' => 0, 'sigmoid_cached' => 2, 'threshold' => 0, 'linear' => 0, 'tanh' => 0, 'relu' => 1 },
                 activation[:output])
    assert_equal 3, @stats.generation(0)[:activation][:hidden]['sigmoid_cached']
  end

  # The initial population is not bred, so it has no structure counts.
  def test_structure_counts_every_operation_of_the_bred_children
    assert_equal({ 'none' => 2, 'widen' => 1, 'narrow' => 0, 'add_layer' => 0, 'remove_layer' => 0 },
                 @stats.generation(1)[:structure])
    assert_nil @stats.generation(0)[:structure]
  end

  def test_a_generation_without_births_has_no_genome_figures
    figures = @stats.generation(2)
    assert_equal({ min: nil, median: nil, max: nil }, figures[:genes]['weight_step'])
    assert_equal({ min: nil, median: nil, max: nil }, figures[:shape][:layers])
    assert_equal({ min: nil, median: nil, max: nil }, figures[:shape][:weights])
    assert_empty figures[:shape][:counts]
    assert_nil figures[:activation]
    assert_nil figures[:structure]
    assert_nil figures[:parents]
  end

  # Of generation 0's a, b, and c: a crossover counts for both parents, a
  # mutation or a copy only for the parent evolve picked, so b.ann has one
  # child, a.ann three, and c.ann none.
  def test_children_per_parent_of_the_previous_generation
    parents = figures_of({ first_parent: 'a.ann', second_parent: 'b.ann', operator: 'crossover', parent: 'second' },
                         { first_parent: 'c.ann', second_parent: 'a.ann', operator: 'mutation', parent: 'second' },
                         { first_parent: 'a.ann', second_parent: 'b.ann', operator: 'copy', parent: 'first' })[:parents]
    assert_equal({ max_children: 3, childless: 1, used: 2 }, parents)
  end

  # Selection draws with replacement, so a network can be crossed with
  # itself: that is one child for it, not two.
  def test_a_crossover_of_a_network_with_itself_counts_once
    parents = figures_of({ first_parent: 'a.ann', second_parent: 'a.ann', operator: 'crossover', parent: 'first' },
                         { first_parent: 'b.ann', second_parent: 'c.ann', operator: 'mutation', parent: 'first' })[:parents]
    assert_equal({ max_children: 1, childless: 1, used: 2 }, parents)
  end

  # Births from before migration 010 do not say which parent a mutation
  # came from.
  def test_children_per_parent_are_nil_without_the_picked_parent
    assert_nil figures_of({ first_parent: 'a.ann', second_parent: 'b.ann', operator: 'crossover', parent: nil },
                          { first_parent: 'b.ann', second_parent: 'c.ann', operator: 'mutation', parent: nil })[:parents]
  end

  def test_children_per_parent_in_the_fixture
    assert_equal({ max_children: 3, childless: 0, used: 3 }, @stats.generation(1)[:parents])
    assert_nil @stats.generation(0)[:parents]
  end

  # Brown1 is the only bot. In generation 1 all three networks score more
  # than its 0; in generation 0 its 5 is the best score.
  def test_bot_ranks_in_the_fixture
    assert_equal({ best_rank: 4, networks_above: 3, 'Brown' => { best_rank: 4, networks_above: 3 }, 'AmiGo' => nil },
                 @stats.generation(1)[:bots])
    assert_equal({ best_rank: 1, networks_above: 0, 'Brown' => { best_rank: 1, networks_above: 0 }, 'AmiGo' => nil },
                 @stats.generation(0)[:bots])
  end

  # By score: a bot tied with a network ranks with it, and only networks
  # with more points count as above it. A group is the stored opponent
  # whose name the copy's name starts with, followed by its copy number.
  def test_bot_ranks_per_group_by_their_best_copy
    players = PLAYERS.merge('Brown2' => { 'external' => true }, 'AmiGo1' => { 'external' => true },
                            'AmiGo2' => { 'external' => true })
    ranking = [['AmiGo2', 6], ['c.ann', 6], ['Brown2', 5], ['a.ann', 5], ['Brown1', 3], ['AmiGo1', 1], ['b.ann', 0]]
    reopen_writing do |writer|
      writer.save_state(4, { 'round' => 0, 'players' => players,
                             'ranking' => ranking.map { |name, score| { 'name' => name, 'score' => score } } })
    end
    assert_equal({ best_rank: 1, networks_above: 0, 'Brown' => { best_rank: 3, networks_above: 1 },
                   'AmiGo' => { best_rank: 1, networks_above: 0 } }, @stats.generation(4)[:bots])
  end

  def test_bot_groups_are_the_stored_opponents
    assert_equal %w[Brown AmiGo], @stats.bot_groups
  end

  # The figures of a generation 4 whose births have the given columns, on
  # top of a mutation of 1x10 networks with default genes.
  def figures_of(*births)
    reopen_writing do |writer|
      births.each_with_index do |birth, i|
        writer.record_birth(generation: 4, child: "#{i}.ann", first_parent: 'a.ann', second_parent: 'b.ann',
                            operator: 'mutation', parent: 'first', seed: i, genome: "x#{i}", structure: 'none',
                            layers: 1, width: 10, **StatsFixture::GENES, **birth)
      end
      writer.save_state(4, { 'round' => 0, 'players' => PLAYERS, 'ranking' => [] })
    end
    @stats.generation(4)
  end

  # The population figures of a generation 4 whose births are the given
  # [first, second, operator, differs_from_first, differs_from_second, parent].
  def population_of(*births)
    reopen_writing do |writer|
      births.each_with_index do |(first, second, operator, one, two, parent), i|
        writer.record_birth(generation: 4, child: "#{i}.ann", first_parent: first, second_parent: second, operator:,
                            parent:, differs_from_first: one, differs_from_second: two, seed: i, genome: "x#{i}")
      end
      writer.save_state(4, { 'round' => 0, 'players' => PLAYERS, 'ranking' => [] })
    end
    @stats.generation(4)[:population]
  end

  def distinct_parents(*births)
    population_of(*births)[:distinct_parents]
  end

  # Replaces @database and @stats after the block has written to the
  # database.
  def reopen_writing
    @database.close
    path = File.join(@dir, 'experiment.sqlite3')
    writer = ExperimentDatabase.new(path)
    yield writer
    writer.close
    @database = ExperimentDatabase.new(path, readonly: true)
    @stats = ExperimentStats.new(@database)
  end
end
