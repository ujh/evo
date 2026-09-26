require_relative 'test_helper'

# Characterization tests: they pin down what the runner does today, including
# the defects listed in PROJECT_NOTES.md. A test that documents a defect says
# so in its name; fixing the defect means changing that test first.
class ScoreGameTest < Minitest::Test
  include RunGenerationHelpers

  NETWORK_VS_BOT = { 'black' => '0001.ann', 'white' => 'GnuGoLevel101' }.freeze
  NETWORK_VS_NETWORK = { 'black' => '0001.ann', 'white' => '0002.ann' }.freeze

  def players
    {
      '0001.ann' => { 'command' => '../evo 0001.ann' },
      '0002.ann' => { 'command' => '../evo 0002.ann' },
      'GnuGoLevel101' => { 'command' => 'gnugo --level 10 --mode gtp', 'external' => true }
    }
  end

  def score(fixture, game = NETWORK_VS_BOT)
    in_experiment do
      write_data('round' => 0, 'players' => players)
      gen = build_generation
      copy_dat(fixture, gen.send(:prefix_from, game)) if fixture
      yield gen.send(:prefix_from, game) if block_given?
      gen.send(:score_game, game, GameResult.read(gen.send(:prefix_from, game)))
    end
  end

  # Scores an arena game from its line in the arena's output.
  def score_arena(line, game = NETWORK_VS_NETWORK)
    in_experiment do
      write_data('round' => 0, 'players' => players)
      result = ArenaResult.chunk("#{line}\ndone 1\n", ['g']).results.fetch('g')
      build_generation.send(:score_game, game, result)
    end
  end

  def test_arena_black_win_names_black_as_winner
    assert_equal({ 'winner' => '0001.ann' }, score_arena(arena_played('g', result: 'B+3.5')))
  end

  def test_arena_draw_gives_no_points_and_is_not_a_failure
    assert_equal({ 'winner' => nil }, score_arena(arena_played('g', result: '0')))
  end

  def test_arena_network_that_cannot_play_loses
    assert_equal({ 'winner' => '0002.ann' }, score_arena(arena_errored('g', side: 'black')))
  end

  def test_arena_game_neither_network_can_play_is_a_failure
    assert_equal({ 'winner' => nil, 'failure' => 'arena: neither network can play' },
                 score_arena(arena_errored('g', side: 'both')))
  end

  def test_black_win_names_black_as_winner
    assert_equal({ 'winner' => '0001.ann' }, score('black_wins'))
  end

  def test_white_win_names_white_as_winner
    assert_equal({ 'winner' => 'GnuGoLevel101' }, score('white_wins'))
  end

  def test_draw_gives_no_points_and_is_not_a_failure
    assert_equal({ 'winner' => nil }, score('draw'))
  end

  def test_missing_referee_score_gives_no_points_and_is_flagged
    assert_equal({ 'winner' => nil, 'failure' => 'no referee score: ?' }, score('no_referee_score'))
  end

  def test_crashed_network_loses_whatever_the_referee_said
    # Evo exited on its first move, yet GNU Go scored the position B+17.5.
    assert_equal({ 'winner' => 'GnuGoLevel101' }, score('black_crashed'))
  end

  def test_crashed_white_network_loses_to_black
    assert_equal({ 'winner' => '0001.ann' }, score('white_crashed', NETWORK_VS_NETWORK))
  end

  def test_crashed_external_bot_gives_no_points_and_is_flagged
    assert_equal({ 'winner' => nil, 'failure' => 'GnuGoLevel101 crashed' }, score('white_crashed'))
  end

  def test_crash_without_stderr_gives_no_points_and_is_flagged
    assert_equal({ 'winner' => nil, 'failure' => 'error: The Go program terminated unexpectedly.' },
                 score('crash_without_stderr'))
  end

  def test_illegal_move_gives_no_points_and_is_flagged
    # This line also has an empty RES_W column, which must not shift RES_R.
    assert_equal({ 'winner' => nil, 'failure' => 'error: Brown: illegal move' }, score('illegal_move'))
  end

  def test_move_limit_uses_the_referee_score
    assert_equal({ 'winner' => 'GnuGoLevel101' }, score('move_limit'))
  end

  def test_missing_result_file_gives_no_points_and_is_flagged
    assert_equal({ 'winner' => nil, 'failure' => 'no result file' }, score(nil))
  end

  def test_result_file_without_a_game_line_gives_no_points_and_is_flagged
    result = score(nil) { |prefix| File.write("#{prefix}.dat", "# Black: Brown\n#GAME\tRES_B\n") }
    assert_equal({ 'winner' => nil, 'failure' => 'no game in result file' }, result)
  end

  def test_result_file_prefix_uses_basenames_and_round
    in_experiment do
      write_data('round' => 3, 'players' => players)
      assert_equal '0001xGnuGoLevel101R3', build_generation.send(:prefix_from, NETWORK_VS_BOT)
    end
  end
end

class ParentSelectionTest < Minitest::Test
  include RunGenerationHelpers

  PICKS = 30_000

  def previous_data(scores)
    {
      'players' => scores.keys.to_h do |name|
        [name, name.end_with?('.ann') ? {} : { 'external' => true }]
      end,
      'ranking' => scores.map { |name, score| { 'name' => name, 'score' => score } }
    }
  end

  # Returns how often each network was picked, as a share of PICKS.
  def shares(scores, settings: {})
    gen = build_generation(settings: settings)
    candidates = gen.send(:parent_candidates, previous_data(scores))
    picks = Array.new(PICKS) { gen.send(:select_parent, candidates) }
    picks.tally.transform_values { |n| n.fdiv(PICKS) }
  end

  def assert_shares(expected, actual)
    assert_equal expected.keys.sort, actual.keys.sort
    expected.each { |name, share| assert_in_delta share, actual[name], 0.015, name }
  end

  def test_external_players_are_never_candidates
    candidates = build_generation.send(:parent_candidates, previous_data('a.ann' => 3, 'Brown1' => 5, 'b.ann' => 0))
    assert_equal %w[a.ann b.ann], candidates.map { |c| c['name'] }
  end

  def test_better_ranks_win_more_of_their_draws
    # With k = 3 and ranks A > B > C, A wins 19/27, B 7/27, C 1/27.
    assert_shares({ 'a.ann' => 19 / 27.0, 'b.ann' => 7 / 27.0, 'c.ann' => 1 / 27.0 },
                  shares({ 'a.ann' => 51, 'b.ann' => 3, 'c.ann' => 1 }))
  end

  def test_only_the_order_of_scores_matters
    assert_shares(shares({ 'a.ann' => 51, 'b.ann' => 3, 'c.ann' => 1 }),
                  shares({ 'a.ann' => 4, 'b.ann' => 3, 'c.ann' => 1 }))
  end

  def test_all_zero_scores_pick_uniformly
    assert_shares({ 'a.ann' => 1 / 3.0, 'b.ann' => 1 / 3.0, 'c.ann' => 1 / 3.0 },
                  shares({ 'a.ann' => 0, 'b.ann' => 0, 'c.ann' => 0 }))
  end

  def test_tied_networks_share_their_wins
    tied = (1 - (1 / 3.0)**3) / 2
    assert_shares({ 'a.ann' => tied, 'b.ann' => tied, 'c.ann' => 1 / 27.0 },
                  shares({ 'a.ann' => 5, 'b.ann' => 5, 'c.ann' => 0 }))
  end

  def test_tournament_size_sets_the_selection_pressure
    assert_shares({ 'a.ann' => 1 / 3.0, 'b.ann' => 1 / 3.0, 'c.ann' => 1 / 3.0 },
                  shares({ 'a.ann' => 51, 'b.ann' => 3, 'c.ann' => 1 }, settings: { 'tournament_size' => 1 }))
    assert_shares({ 'a.ann' => 5 / 9.0, 'b.ann' => 3 / 9.0, 'c.ann' => 1 / 9.0 },
                  shares({ 'a.ann' => 51, 'b.ann' => 3, 'c.ann' => 1 }, settings: { 'tournament_size' => 2 }))
  end

  def test_parent_selection_is_seeded_by_experiment_seed_and_generation
    picks = lambda do |generation, seed|
      gen = build_generation(generation:, settings: { 'seed' => seed }, rng: nil)
      candidates = gen.send(:parent_candidates, previous_data((1..9).to_h { |i| ["#{i}.ann", i % 3] }))
      Array.new(20) { gen.send(:select_parent, candidates) }
    end
    assert_equal picks.call('2', 1), picks.call('2', 1)
    refute_equal picks.call('2', 1), picks.call('3', 1)
    refute_equal picks.call('2', 1), picks.call('2', 7)
  end

  def test_tournament_size_below_one_is_rejected
    gen = build_generation(settings: { 'tournament_size' => 0 })
    candidates = gen.send(:parent_candidates, previous_data('a.ann' => 1))
    assert_raises(ArgumentError) { gen.send(:select_parent, candidates) }
  end
end

class EvolveFromPreviousPopulationTest < Minitest::Test
  include RunGenerationHelpers

  # Stores generation 0's networks and state in the database, then runs the breeding step for
  # generation 1 in the current directory (the scratch directory) with `../evolve` replaced by the
  # given block. The block returns what run_evolve does: [success, stdout]. `stale_child` is left in
  # 0.ann, as an interrupted earlier run would. keep_every 0 retires generation 0 after breeding.
  def breed(scores:, settings: {}, stale_child: nil, &evolve)
    settings = { 'keep_every' => 0 }.merge(settings)
    in_experiment do
      File.write('0.ann', stale_child) if stale_child
      scores.each_key { |name| database.record_network(0, name, name) }
      write_data({
                   'players' => scores.keys.to_h { |name| [name, {}] },
                   'ranking' => scores.map { |name, score| { 'name' => name, 'score' => score } }
                 }, generation: 0)

      commands = []
      store = database
      gen = build_generation(settings: settings, store:)
      gen.define_singleton_method(:run_evolve) do |cmd|
        commands << cmd
        evolve ? evolve.call(cmd) : [true, SUMMARY]
      end
      error = nil
      err = nil
      begin
        _, err = capture_io { gen.send(:evolve_from_previous_population) }
      rescue StandardError, SystemExit => e
        error = e
      end
      {
        commands: commands,
        error: error,
        err: err,
        children: Dir['*.ann'].sort.to_h { |f| [f, File.read(f)] },
        parent_files: Dir['parents/*'].sort,
        previous_networks: database.network_names(0),
        networks: database.network_names(1),
        data: database.state(1),
        births: store.births(1)
      }
    end
  end

  GENES_LINE = 'genes layers=1 width=10 act_hidden=sigmoid_cached act_output=sigmoid_cached copy_chance=0.01 ' \
               "weight_changes=1 weight_step=0.5 activation_rate=0.02 structure_rate=0.02 features=none feature_step=0.01\n".freeze
  SUMMARY = "Loading ...\nsummary operator=mutation parent=first structure=none activation_changed=0 " \
            "differs_from_first=0 differs_from_second=907\n#{GENES_LINE}".freeze

  # Writes the child to the output path, evolve's second-to-last argument, and succeeds.
  def write_child(cmd)
    File.write(cmd.split[-2], cmd)
    [true, SUMMARY]
  end

  # The crossover rate, the meta rate, the bounds on the child's shape
  # (max_hidden_layers, max_layer_size), and the width of a layer added to
  # a network without one, then the parents.
  PARENTS = %r{\A\.\./evolve 0\.5 0\.2 4 200 10 parents/000[12]\.ann parents/000[12]\.ann}

  def test_breeds_children_from_selected_parents_and_deletes_the_parents
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }) { |cmd| write_child(cmd) }
    assert_nil state[:error]
    assert_equal 2, state[:commands].size
    state[:commands].each_with_index { |cmd, i| assert_match(/#{PARENTS} #{i}\.ann #{Seeds.derive(1, 'birth', 1, i)}\z/, cmd) }
    assert_equal %w[0.ann 1.ann], state[:children].keys
    assert_equal %w[0.ann 1.ann], state[:networks]
    assert_equal %w[parents/0001.ann parents/0002.ann], state[:parent_files]
    assert_empty state[:previous_networks]
    assert state[:data]['setup_complete']
    assert_equal 0, state[:data]['round']
  end

  def test_all_zero_scores_still_breed_from_real_parents
    state = breed(scores: { '0001.ann' => 0, '0002.ann' => 0 }) { |cmd| write_child(cmd) }
    assert_nil state[:error]
    state[:commands].each { |cmd| assert_match PARENTS, cmd }
  end

  def test_evolve_failing_stops_breeding_before_the_parents_are_deleted
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }) { [false, ''] }
    assert_match(/evolve failed to breed 0\.ann/, state[:error].message)
    assert_includes state[:previous_networks], '0001.ann'
    assert_nil state[:data]
  end

  # Ctrl-C reaches evolve too. Breeding stops like the tournament does, with
  # no error: the setup is saved only after the last child, so a resume
  # breeds again from the first.
  def test_ctrl_c_during_breeding_exits_quietly
    $stop_now = false
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }) do
      $stop_now = true
      [false, '']
    end
    assert_instance_of SystemExit, state[:error]
    assert_equal 0, state[:error].status
    assert_equal 1, state[:commands].size
    assert_includes state[:previous_networks], '0001.ann'
    assert_nil state[:data]
  ensure
    $stop_now = false
  end

  # evolve can be back before the trap has set the flag; its status tells.
  def test_evolve_interrupted_before_the_trap_ran_exits_with_130
    PlayRoundTest::INTERRUPTED.each do |how, status|
      state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }) { [false, '', status] }
      assert_instance_of SystemExit, state[:error], how
      assert_equal 130, state[:error].status, how
      assert_includes state[:previous_networks], '0001.ann', how
      assert_nil state[:data], how
    end
  end

  def test_evolve_writing_nothing_stops_breeding
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }) { [true, SUMMARY] }
    assert_match(/evolve failed to breed 0\.ann/, state[:error].message)
    assert_includes state[:previous_networks], '0001.ann'
  end

  def test_child_left_by_an_interrupted_run_is_not_reused
    state = breed(scores: { '0001.ann' => 1 }, settings: { 'population_size' => 1 }, stale_child: 'stale') { [true, SUMMARY] }
    assert_match(/evolve failed to breed 0\.ann/, state[:error].message)
    assert_empty state[:children]
  end

  def test_records_a_birth_for_each_child
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }) { |cmd| write_child(cmd) }
    assert_equal %w[0.ann 1.ann], state[:births].map { |b| b[:child] }
    state[:births].each_with_index do |birth, i|
      parents = state[:commands][i].split[6, 2].map { |path| File.basename(path) }
      assert_equal [1, parents, 'mutation', 0, 907, Seeds.derive(1, 'birth', 1, i)],
                   [birth[:generation], birth.values_at(:first_parent, :second_parent), birth[:operator],
                    birth[:differs_from_first], birth[:differs_from_second], birth[:seed]]
      assert_equal Digest::SHA256.hexdigest(state[:children]["#{i}.ann"]), birth[:genome]
    end
  end

  # The summary and the child's genes line fill the rest of its birth.
  def test_records_the_summary_and_the_childs_genes
    summary = 'summary operator=mutation parent=second structure=none activation_changed=1 ' \
              'differs_from_first=12 differs_from_second=3'
    genes = 'genes layers=1 width=10 act_hidden=relu act_output=linear copy_chance=0.012345678901234567 ' \
            'weight_changes=2.5 weight_step=1.0000000000000001e-04 activation_rate=0.25 structure_rate=0.03 ' \
            'features=none feature_step=0.01'
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }) do |cmd|
      File.write(cmd.split[-2], cmd)
      [true, "Loading ...\n#{summary}\n#{genes}\n"]
    end
    assert_nil state[:error]
    assert_equal({ parent: 'second', structure: 'none', activation_changed: true, layers: 1, width: 10,
                   act_hidden: 'relu', act_output: 'linear', copy_chance: 0.012345678901234567, weight_changes: 2.5,
                   weight_step: 1.0000000000000001e-04, activation_rate: 0.25, structure_rate: 0.03 },
                 state[:births].first.slice(:parent, :structure, :activation_changed,
                                            *ExperimentDatabase::BIRTH_GENE_COLUMNS))
  end

  def test_a_missing_or_malformed_genes_line_stops_breeding
    summary = SUMMARY.lines[1]
    ['', GENES_LINE.sub('weight_step=0.5', 'weight_step=inf'), GENES_LINE.sub('layers=1', 'layers=one'),
     GENES_LINE.sub(' activation_rate=0.02', ''), GENES_LINE.sub('act_output=sigmoid_cached', 'act_output=gauss'),
     GENES_LINE.sub(' feature_step=0.01', ''), GENES_LINE.sub('features=none', 'features=all'),
     GENES_LINE + GENES_LINE].each do |genes|
      state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }) do |cmd|
        File.write(cmd.split[-2], cmd)
        [true, "Loading ...\n#{summary}#{genes}"]
      end
      assert_match(/genes/, state[:error]&.message, genes)
      assert_includes state[:previous_networks], '0001.ann'
      assert_empty state[:networks]
    end
  end

  # A child's genes line must have the experiment's feature set, none for now.
  def test_a_child_of_another_feature_set_stops_breeding
    summary = SUMMARY.lines[1]
    genes = GENES_LINE.sub('features=none feature_step=0.01', 'features=tactics feature_step=0.01 fw_capture=1 ' \
                                                               'fw_self_atari=-1 fw_saves_atari=0.8')
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }) do |cmd|
      File.write(cmd.split[-2], cmd)
      [true, "Loading ...\n#{summary}#{genes}"]
    end
    assert_match(/evolve printed genes of the feature set tactics for 0\.ann, but the experiment's is none/,
                 state[:error]&.message)
    assert_includes state[:previous_networks], '0001.ann'
    assert_empty state[:networks]
  end

  def test_the_meta_rate_comes_from_the_settings
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }, settings: { 'meta_rate' => 0.35 }) { |cmd| write_child(cmd) }
    state[:commands].each { |cmd| assert_match(/\A\.\.\/evolve 0\.5 0\.35 4 200 10 /, cmd) }
  end

  # Writes the child and prints the given summary line.
  def write_child_with(summary)
    lambda do |cmd|
      File.write(cmd.split[-2], cmd)
      [true, "Loading ...\n#{summary}\n#{GENES_LINE}"]
    end
  end

  def test_the_bounds_on_the_shape_come_from_the_settings
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 },
                  settings: { 'max_hidden_layers' => 3, 'max_layer_size' => 20 }) { |cmd| write_child(cmd) }
    state[:commands].each { |cmd| assert_match(%r{\A\.\./evolve 0\.5 0\.2 3 20 10 parents/}, cmd) }
  end

  # A network without hidden layers that gains one gets the generation-0
  # width, but never more than max_layer_size.
  def test_an_added_first_layer_is_at_most_max_layer_size_wide
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 },
                  settings: { 'hidden_layers' => 0, 'layer_size' => 500, 'max_layer_size' => 200 }) do |cmd|
      write_child(cmd)
    end
    state[:commands].each { |cmd| assert_match(%r{\A\.\./evolve 0\.5 0\.2 4 200 200 parents/}, cmd) }
  end

  # Each structural change is stored with the child's new shape; a parent
  # of another shape has no differs count.
  def test_records_each_structural_change_with_the_childs_shape
    changes = [['widen', 1, 11], ['narrow', 1, 9], ['add_layer', 2, 10], ['remove_layer', 0, 0]]
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }, settings: { 'population_size' => 4 }) do |cmd|
      child = cmd.split[-2]
      File.write(child, cmd)
      structure, layers, width = changes.fetch(Integer(File.basename(child, '.ann')))
      [true, "Loading ...\nsummary operator=mutation parent=first structure=#{structure} activation_changed=0 " \
             "differs_from_first=-1 differs_from_second=-1\n" \
             "#{GENES_LINE.sub('layers=1 width=10', "layers=#{layers} width=#{width}")}"]
    end
    assert_nil state[:error]
    assert_equal(changes.map { |change| change + [nil, nil] },
                 state[:births].map { |birth| birth.values_at(:structure, :layers, :width, :differs_from_first, :differs_from_second) })
  end

  def test_records_copies_and_counts_for_other_shapes_as_unknown
    summary = 'summary operator=copy parent=second structure=none activation_changed=0 ' \
              'differs_from_first=-1 differs_from_second=0'
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }, &write_child_with(summary))
    assert_nil state[:error]
    state[:births].each do |birth|
      assert_equal ['copy', nil, 0], birth.values_at(:operator, :differs_from_first, :differs_from_second)
    end
  end

  def test_summary_with_an_unknown_field_value_stops_breeding
    ['summary operator=mutation differs_from_first=0 differs_from_second=907',
     'summary operator=clone parent=first structure=none activation_changed=0 differs_from_first=0 differs_from_second=1',
     'summary operator=mutation parent=third structure=none activation_changed=0 differs_from_first=0 differs_from_second=1',
     'summary operator=mutation parent=first structure=grow activation_changed=0 differs_from_first=0 differs_from_second=1',
     'summary operator=mutation parent=first structure=none activation_changed=2 differs_from_first=0 differs_from_second=1',
     'summary operator=mutation parent=first structure=none activation_changed=0 differs_from_first=-2 differs_from_second=1'].each do |summary|
      state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }, &write_child_with(summary))
      assert_match(/no summary/, state[:error]&.message, summary)
    end
  end

  def test_evolve_without_a_summary_stops_breeding
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }) { |cmd| write_child(cmd) && [true, "Loading ...\n"] }
    assert_match(/no summary/, state[:error].message)
    assert_includes state[:previous_networks], '0001.ann'
  end

  def test_parents_of_a_kept_generation_stay_in_the_database
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }, settings: { 'keep_every' => 10 }) { |cmd| write_child(cmd) }
    assert_equal %w[0001.ann 0002.ann], state[:previous_networks]
  end

  def test_children_are_stored_with_their_bytes
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }) { |cmd| write_child(cmd) }
    Dir.mktmpdir do |dir|
      database.export_networks(1, dir)
      assert_equal state[:children]['0.ann'], File.read(File.join(dir, '0.ann'))
    end
  end

  def test_skips_breeding_once_setup_is_complete
    in_experiment do
      write_data('setup_complete' => true)
      gen = build_generation
      gen.define_singleton_method(:run_evolve) { |*| flunk 'evolve should not run' }
      gen.send(:evolve_from_previous_population)
    end
  end
end

# initial-population's and evolve's genes line (ann_print_genes_line in
# lib/ann.c), parsed strictly.
class GenesLineTest < Minitest::Test
  PREFIX = 'genes layers=1 width=10 act_hidden=sigmoid_cached act_output=relu copy_chance=0.01 weight_changes=1 ' \
           'weight_step=0.5 activation_rate=0.02 structure_rate=0.02'.freeze
  GENES = { layers: 1, width: 10, act_hidden: 'sigmoid_cached', act_output: 'relu', copy_chance: 0.01,
            weight_changes: 1.0, weight_step: 0.5, activation_rate: 0.02, structure_rate: 0.02 }.freeze
  ALL = "#{PREFIX} features=shapes,tactics,last_move,liberties feature_step=0.0625 fw_hane=0.5 fw_cut=-0.25 " \
        'fw_edge=1.5 fw_capture=9.75 fw_self_atari=-10 fw_saves_atari=10 fw_near_last=-0.03125'.freeze

  def parse(line)
    RunGeneration.allocate.send(:parse_genes, "#{line}\n", 'cmd')
  end

  def test_a_network_without_features_has_only_its_feature_step
    assert_equal GENES.merge(features: 'none', feature_step: 0.01), parse("#{PREFIX} features=none feature_step=0.01")
  end

  def test_every_move_feature_of_every_group_has_its_weight
    assert_equal GENES.merge(features: 'shapes,tactics,last_move,liberties', feature_step: 0.0625, fw_hane: 0.5,
                             fw_cut: -0.25, fw_edge: 1.5, fw_capture: 9.75, fw_self_atari: -10.0, fw_saves_atari: 10.0,
                             fw_near_last: -0.03125),
                 parse(ALL)
  end

  # Only the groups' move features, in the table's order; liberties has none.
  def test_some_groups_have_only_their_features
    assert_equal GENES.merge(features: 'tactics,liberties', feature_step: 0.1, fw_capture: 1.0, fw_self_atari: -1.0,
                             fw_saves_atari: 0.8),
                 parse("#{PREFIX} features=tactics,liberties feature_step=0.10000000000000001 fw_capture=1 " \
                       'fw_self_atari=-1 fw_saves_atari=0.80000000000000004')
    assert_equal GENES.merge(features: 'liberties', feature_step: 0.5), parse("#{PREFIX} features=liberties feature_step=0.5")
  end

  def test_anything_else_is_malformed
    none = "#{PREFIX} features=none feature_step=0.01"
    [
      PREFIX,
      "#{PREFIX} feature_step=0.01",
      "#{PREFIX} features=none",
      "#{none} ",
      "#{none} fw_hane=0.05",
      none.sub('0.01', 'nan'),
      none.sub('0.01', ''),
      none.sub('none', 'all'),
      none.sub('none', ''),
      none.sub('none', 'ladders'),
      none.sub('none', 'liberties,'),
      none.sub('none', 'liberties,liberties'),
      none.sub('none', 'liberties,shapes'),
      none.sub('none', 'none,liberties'),
      ALL.sub(' fw_near_last=-0.03125', ''),
      ALL.sub(' fw_hane=0.5', ''),
      ALL.sub('fw_hane=0.5 fw_cut=-0.25', 'fw_cut=-0.25 fw_hane=0.5'),
      "#{ALL} fw_near_last=1",
      "#{ALL} fw_ladder=1",
      ALL.sub('fw_capture=9.75', 'fw_capture=inf'),
      ALL.sub('fw_capture=9.75', 'fw_capture=9.75x'),
      ALL.sub('fw_capture=9.75', 'fw_capture='),
      ALL.sub('liberties feature_step', 'liberties  feature_step')
    ].each do |line|
      error = assert_raises(RuntimeError, line) { parse(line) }
      assert_match(/malformed genes line/, error.message)
    end
  end
end

class GamesFromRankingTest < Minitest::Test
  include RunGenerationHelpers

  def ranking(names)
    names.map { |name| { 'name' => name, 'score' => 0 } }
  end

  def games(names)
    build_generation.send(:games_from_ranking, ranking(names))
  end

  def test_pairs_neighbours_in_ranking_order_with_symbol_keys
    result = games(%w[a.ann b.ann c.ann d.ann])
    assert_equal 2, result.size
    assert(result.all? { |game| game.keys == %i[black white] })
    assert_equal [%w[a.ann b.ann], %w[c.ann d.ann]], result.map { |game| game.values.sort }
  end

  def test_odd_player_out_sits_the_round_out
    assert_equal [{ black: 'c.ann', white: nil }], games(%w[a.ann b.ann c.ann]).drop(1)
  end

  # Bots play in the ranking like networks, so their place in it can be compared.
  def test_external_players_are_paired_like_networks
    assert_equal %w[Brown1 Brown2], games(%w[Brown1 Brown2 a.ann b.ann]).first.values.sort
  end

  # Early networks are far too weak for GNU Go, and its games set most of a
  # generation's wall time.
  def test_tournament_has_no_gnu_go_player
    in_experiment do
      File.write('0001.ann', '')
      commands = build_generation.send(:setup_tournament)['players'].values.map { |player| player['command'] }
      assert_includes commands, 'amigogtp'
      refute(commands.any? { |command| command.start_with?('gnugo') })
    end
  end

  def test_game_keys_become_strings_after_saving
    in_experiment do
      gen = build_generation
      gen.send(:save_data, { 'games' => games(%w[a.ann b.ann]) })
      assert_equal %w[black white], gen.send(:data)['games'].first.keys
    end
  end

  # The opponents come from the experiment's database, not from the code, so
  # an experiment keeps its panel when the defaults change.
  def test_the_opponents_come_from_the_experiment
    in_experiment do
      File.write('0001.ann', '')
      store = ExperimentDatabase.new(':memory:')
      store.save_opponents([{ name: 'Pachi', command: 'pachi --playouts 10', copies: 2 }])
      store.save_scoring(SetupExperiment::DEFAULT_SCORING)
      players = build_generation(store:).send(:setup_players)
      assert_equal({ 'Pachi1' => { 'command' => 'pachi --playouts 10', 'external' => true },
                     'Pachi2' => { 'command' => 'pachi --playouts 10', 'external' => true },
                     '0001.ann' => { 'command' => '../evo 0001.ann' } }, players)
    end
  end

  # Points for a win, a draw, and a bye come from the experiment too.
  def test_points_come_from_the_experiments_scoring
    in_experiment do
      store = ExperimentDatabase.new(':memory:')
      store.save_opponents([])
      store.save_scoring(SetupExperiment::DEFAULT_SCORING.merge('win' => 3, 'draw' => 1, 'bye' => 2))
      games = [{ 'black' => 'a.ann', 'white' => 'b.ann' }, { 'black' => 'c.ann', 'white' => 'd.ann' },
               { 'black' => 'e.ann', 'white' => nil }, { 'black' => 'f.ann', 'white' => 'g.ann' }]
      store.save_state(1, { 'round' => 0, 'games' => games,
                            'players' => %w[a b c d e f g].to_h { |n| ["#{n}.ann", { 'command' => "../evo #{n}.ann" }] },
                            'ranking' => %w[a b c d e f g].map { |n| { 'name' => "#{n}.ann", 'score' => 0 } } })
      gen = build_generation(store:)
      capture_io do
        gen.send(:update_data, games[0], { 'winner' => 'a.ann' })
        gen.send(:update_data, games[1], { 'winner' => nil })
        gen.send(:update_data, games[2], { 'winner' => nil })
        gen.send(:update_data, games[3], { 'winner' => nil, 'failure' => 'no referee score: ?' })
      end
      scores = gen.send(:data)['ranking'].to_h { |r| r.values_at('name', 'score') }
      assert_equal({ 'a.ann' => 3, 'b.ann' => 0, 'c.ann' => 1, 'd.ann' => 1, 'e.ann' => 2, 'f.ann' => 0, 'g.ann' => 0 }, scores)
    end
  end

  def test_tournament_includes_every_external_player_and_a_bye_for_odd_counts
    in_experiment do
      %w[0001.ann 0002.ann 0003.ann 0004.ann].each { |name| File.write(name, '') }
      tournament = build_generation.send(:setup_tournament)
      # 4 networks, 5 Brown, and 10 AmiGo.
      assert_equal 19, tournament['players'].size
      assert_equal 10, tournament['games'].size
      assert_equal 1, tournament['games'].count { |game| game[:white].nil? }
      assert_equal '../evo 0001.ann', tournament['players']['0001.ann']['command']
    end
  end
end

class PlayRoundTest < Minitest::Test
  include RunGenerationHelpers

  NETWORKS = %w[a.ann b.ann c.ann d.ann e.ann f.ann g.ann h.ann i.ann j.ann].freeze

  # A round with the given games among the networks above and Brown1.
  def setup_round(games, generation: 1)
    players = NETWORKS.to_h { |name| [name, { 'command' => "../evo #{name}" }] }
    players['Brown1'] = { 'command' => 'brown', 'external' => true }
    write_data(generation:, 'round' => 0, 'players' => players,
               'games' => games.map { |black, white| { 'black' => black, 'white' => white } },
               'ranking' => players.keys.map { |name| { 'name' => name, 'score' => 0 } })
  end

  # a.ann against b.ann in the arena, c.ann against Brown1 through GoGui, and
  # d.ann sits out.
  MIXED = [%w[a.ann b.ann], ['c.ann', 'Brown1'], ['d.ann', nil]].freeze

  def build_with(pool, generation: '1', settings: {}, store: nil)
    gen = build_generation(generation:, settings:)
    gen.instance_variable_set(:@pool, pool)
    gen.instance_variable_set(:@store, store || database)
    gen
  end

  def prefix(game)
    "#{File.basename(game['black'], '.*')}x#{File.basename(game['white'], '.*')}R0"
  end

  # A pool that leaves what gogui-twogtp leaves: result, SGF, and stderr.
  def playing_pool(fixture = 'black_wins', **arena)
    FakePool.new(**arena) do |game|
      copy_dat(fixture, prefix(game))
      File.write("#{prefix(game)}-0.sgf", '(;SZ[9];B[ee])')
      File.write("#{prefix(game)}.err", '')
    end
  end

  def play(games, pool, **options)
    setup_round(games, generation: options.fetch(:generation, '1').to_i)
    gen = build_with(pool, **options)
    capture_io { gen.send(:play_round) }
    gen
  end

  def scores(gen)
    gen.send(:data)['ranking'].to_h { |r| r.values_at('name', 'score') }
  end

  def chunks(pool)
    pool.identifiers.select { |identifier| identifier.respond_to?(:schedule) }
  end

  def test_stores_each_gogui_game_and_deletes_its_files
    in_experiment do
      store = database
      play([['a.ann', 'Brown1']], playing_pool, store:)
      assert_equal [{ generation: 1, round: 0, black: 'a.ann', white: 'Brown1', black_external: false,
                      white_external: true, winner: 'a.ann', failure: nil, length: 93, referee_result: 'B+R',
                      error_message: '', stderr: '', sgf: nil, duration: 1.5, time_black: 0.0,
                      time_white: 0.0, scorer: 'gnugo' }], store.games(1)
      assert_empty Dir['axBrown1R0*']
    end
  end

  def test_keeps_the_gogui_sgf_every_keep_every_generations
    in_experiment(generation: '10') do
      store = database
      play([['a.ann', 'Brown1']], playing_pool, generation: '10', store:)
      assert_equal '(;SZ[9];B[ee])', store.games(10).first[:sgf]
    end
  end

  def test_a_mixed_round_plays_networks_in_the_arena_and_bots_through_gogui
    in_experiment do
      pool = playing_pool('white_wins')
      gen = play(MIXED, pool)
      assert_empty gen.send(:data)['games']
      # a.ann beat b.ann in the arena, Brown1 beat c.ann, and d.ann sat the
      # round out and gets nothing for it.
      assert_equal({ 'a.ann' => 1, 'b.ann' => 0, 'c.ann' => 0, 'd.ann' => 0, 'Brown1' => 1 },
                   scores(gen).slice('a.ann', 'b.ann', 'c.ann', 'd.ann', 'Brown1'))
      assert_equal 2, pool.commands.size
      assert_equal ['../arena 9 6.5 200 arena-0.txt > arena-0.out 2> arena-0.err'],
                   pool.commands.grep(/arena/)
      gogui = pool.commands.grep(/gogui-twogtp/)
      assert_equal 1, gogui.size
      assert_includes gogui.first, '-black "../evo c.ann" -white "brown"'
      assert_equal({ %w[a.ann b.ann] => 'tromp_taylor', %w[c.ann Brown1] => 'gnugo' },
                   database.games(1).to_h { |row| [row.values_at(:black, :white), row[:scorer]] })
    end
  end

  def test_the_schedule_names_each_game_and_its_networks
    in_experiment do
      schedule = nil
      pool = FakePool.new(arena: lambda { |id, _game|
        schedule = File.read(chunks(pool).first.schedule)
        arena_played(id)
      })
      play([%w[a.ann b.ann], %w[d.ann c.ann]], pool, settings: { 'komi' => 7.0, 'max_moves' => 50 })
      assert_equal "axbR0 a.ann b.ann\ndxcR0 d.ann c.ann\n", schedule
      assert_equal ['../arena 9 7.0 50 arena-0.txt > arena-0.out 2> arena-0.err'], pool.commands
    end
  end

  def test_stores_arena_rows_and_deletes_the_chunks_files
    in_experiment do
      store = database
      # Two games of 0.25 s in a chunk of 1.5 s: each gets half the 1.0 s overhead.
      pool = FakePool.new(arena: ->(id, _game) { arena_played(id, time_black: 0.26, time_white: 0.04, duration: 0.25) },
                          arena_stderr: 'a warning')
      play([%w[a.ann b.ann], %w[c.ann d.ann]], pool, store:)
      row = { generation: 1, round: 0, black_external: false, white_external: false, failure: nil, length: 4,
              referee_result: 'B+3.5', error_message: nil, stderr: nil, sgf: nil, duration: 0.75,
              time_black: 0.3, time_white: 0.0, scorer: 'tromp_taylor' }
      assert_equal [row.merge(black: 'a.ann', white: 'b.ann', winner: 'a.ann'),
                    row.merge(black: 'c.ann', white: 'd.ann', winner: 'c.ann')], store.games(1)
      assert_empty Dir['arena-*']
    end
  end

  def test_a_chunk_faster_than_its_games_adds_no_overhead
    in_experiment do
      store = database
      pool = FakePool.new(arena: ->(id, _game) { arena_played(id, duration: 0.25) }, duration: 0.1)
      play([%w[a.ann b.ann], %w[c.ann d.ann]], pool, store:)
      assert_equal [0.25, 0.25], store.games(1).map { |row| row[:duration] }
    end
  end

  def test_a_game_stopped_at_the_move_limit_is_scored_on_the_board
    in_experiment do
      store = database
      pool = FakePool.new(arena: ->(id, _game) { arena_played(id, result: 'W+6.5', finish: 'limit') })
      gen = play([%w[a.ann b.ann]], pool, store:)
      assert_equal ['b.ann', 'move limit exceeded'], store.games(1).first.values_at(:winner, :error_message)
      assert_equal 1, scores(gen)['b.ann']
    end
  end

  def test_an_arena_draw_gives_no_points
    in_experiment do
      store = database
      pool = FakePool.new(arena: ->(id, _game) { arena_played(id, result: '0') })
      gen = play([%w[a.ann b.ann]], pool, store:)
      assert_equal [nil, nil, '0'], store.games(1).first.values_at(:winner, :failure, :referee_result)
      assert_equal [0, 0], scores(gen).values_at('a.ann', 'b.ann')
    end
  end

  def test_a_network_that_cannot_play_loses
    in_experiment do
      store = database
      pool = FakePool.new(arena: ->(id, _game) { arena_errored(id, side: 'white', message: 'b.ann is missing') },
                          arena_stderr: 'a warning')
      gen = play([%w[a.ann b.ann]], pool, store:)
      row = store.games(1).first
      assert_equal ['a.ann', nil, nil, nil, 'b.ann is missing', nil, 'tromp_taylor'],
                   row.values_at(:winner, :failure, :length, :referee_result, :error_message, :stderr, :scorer)
      assert_equal [1, 0], scores(gen).values_at('a.ann', 'b.ann')
    end
  end

  def test_a_failed_arena_game_keeps_the_chunks_stderr
    in_experiment do
      store = database
      pool = FakePool.new(arena: ->(id, _game) { arena_errored(id, side: 'both') }, arena_stderr: 'a warning')
      gen = play([%w[a.ann b.ann]], pool, store:)
      assert_equal ['arena: neither network can play', 'a warning'], store.games(1).first.values_at(:failure, :stderr)
      assert_equal [0, 0], scores(gen).values_at('a.ann', 'b.ann')
    end
  end

  def test_a_failed_arena_game_with_empty_stderr_stores_none
    in_experiment do
      store = database
      pool = FakePool.new(arena: ->(id, _game) { arena_errored(id, side: 'both') })
      play([%w[a.ann b.ann]], pool, store:)
      assert_nil store.games(1).first[:stderr]
    end
  end

  def test_keeps_the_arena_sgf_every_keep_every_generations
    in_experiment(generation: '10') do
      store = database
      play([%w[a.ann b.ann]], FakePool.new, generation: '10', store:)
      assert_equal '(;GM[1]FF[4]SZ[9]KM[6.5]RE[B+3.5];B[cg];W[df];B[];W[])', store.games(10).first[:sgf]
    end
  end

  def test_arena_games_go_into_at_most_concurrency_chunks_covering_each_game_once
    games = NETWORKS.each_slice(2).to_a
    { 1 => 1, 2 => 2, 3 => 3, 5 => 5, 8 => 5 }.each do |concurrency, expected|
      in_experiment do
        pool = FakePool.new
        gen = play(games + [['Brown1', nil]], pool, settings: { 'concurrency' => concurrency })
        assert_equal expected, chunks(pool).size, "concurrency #{concurrency}"
        assert_equal expected, pool.commands.size
        scheduled = chunks(pool).flat_map { |chunk| chunk.games.values.map { |g| g.values_at('black', 'white') } }
        assert_equal games.sort, scheduled.sort
        assert_equal games.map(&:first).sort, scores(gen).select { |_, score| score == 1 }.keys.sort
        assert_equal games.size, database.games(1).size
      end
    end
  end

  def test_stopping_leaves_the_finished_game_to_be_replayed
    in_experiment do
      setup_round([['a.ann', 'Brown1']])
      pool = FakePool.new { $stop_now = true }
      gen = build_with(pool)
      capture_io { assert_raises(SystemExit) { gen.send(:play_round) } }
      data = database.state(1)
      assert_equal [{ 'black' => 'a.ann', 'white' => 'Brown1' }], data['games']
    ensure
      $stop_now = false
    end
  end

  # a.ann against b.ann, then c.ann against d.ann, in one chunk.
  TWO_ARENA_GAMES = [%w[a.ann b.ann], %w[c.ann d.ann]].freeze

  # Plays TWO_ARENA_GAMES in one chunk that the arena left as `arena_output`
  # makes of its output, killed, with `stderr`. Returns each game's winner,
  # failure, and stderr by its black player, the scores, and the runner's
  # stderr.
  def play_broken_chunk(arena_output, stderr: 'Segmentation fault')
    store = database
    setup_round(TWO_ARENA_GAMES)
    gen = build_with(FakePool.new(arena_output:, arena_stderr: stderr, status: signal_status('KILL')), store:)
    _, err = capture_io { gen.send(:play_round) }
    assert_empty gen.send(:data)['games']
    rows = store.games(1).to_h { |row| [row[:black], row.values_at(:winner, :failure, :stderr)] }
    [rows, scores(gen).values_at('a.ann', 'b.ann', 'c.ann', 'd.ann'), err]
  end

  SCORED = ['a.ann', nil, nil].freeze
  NO_RESULT = [nil, 'arena: no result', 'Segmentation fault'].freeze

  def test_a_game_the_dead_arena_left_out_fails_and_the_others_count
    in_experiment do
      rows, points, err = play_broken_chunk(->(text) { text.lines.first })
      assert_equal({ 'a.ann' => SCORED, 'c.ann' => NO_RESULT }, rows)
      assert_equal [1, 0, 0, 0], points
      assert_includes err, 'cxdR0: arena: no result'
    end
  end

  def test_a_line_cut_off_mid_field_is_no_result
    in_experiment do
      rows, points, = play_broken_chunk(->(text) { text.lines[0] + text.lines[1][0, 30] })
      assert_equal({ 'a.ann' => SCORED, 'c.ann' => NO_RESULT }, rows)
      assert_equal [1, 0, 0, 0], points
    end
  end

  def test_games_with_valid_lines_count_without_the_trailer
    in_experiment do
      rows, points, = play_broken_chunk(->(text) { text.lines[0, 2].join })
      assert_equal({ 'a.ann' => SCORED, 'c.ann' => ['c.ann', nil, nil] }, rows)
      assert_equal [1, 0, 1, 0], points
    end
  end

  def test_garbage_from_the_arena_is_no_result
    in_experiment do
      rows, points, err = play_broken_chunk(->(_text) { "\xff\xfe garbage\nmore\tgarbage\n" })
      assert_equal({ 'a.ann' => NO_RESULT, 'c.ann' => NO_RESULT }, rows)
      assert_equal [0, 0, 0, 0], points
      assert_includes err, 'axbR0: arena: no result'
      assert_includes err, 'cxdR0: arena: no result'
    end
  end

  def test_an_arena_that_wrote_nothing_or_no_file_gives_no_result
    [->(_text) { '' }, ->(_text) {}].each do |output|
      in_experiment do
        @database = nil
        rows, points, = play_broken_chunk(output, stderr: '')
        assert_equal({ 'a.ann' => [nil, 'arena: no result', nil], 'c.ann' => [nil, 'arena: no result', nil] }, rows)
        assert_equal [0, 0, 0, 0], points
      end
    end
  end

  def test_an_errored_and_a_played_game_in_one_chunk_are_both_scored
    in_experiment do
      arena = ->(id, _game) { id == 'axbR0' ? arena_errored(id, side: 'both') : arena_errored(id, side: 'black') }
      gen = play(TWO_ARENA_GAMES, FakePool.new(arena:))
      assert_equal({ 'a.ann' => [nil, 'arena: neither network can play'], 'c.ann' => ['d.ann', nil] },
                   database.games(1).to_h { |row| [row[:black], row.values_at(:winner, :failure)] })
      assert_equal [0, 0, 0, 1], scores(gen).values_at('a.ann', 'b.ann', 'c.ann', 'd.ann')
    end
  end

  # Under LANG=C, File.read gives US-ASCII, and scrubbing that would turn
  # the arena's UTF-8 into question marks.
  def test_the_chunks_output_is_read_as_utf8_whatever_the_locale
    in_experiment do
      verbose, $VERBOSE = $VERBOSE, nil
      external = Encoding.default_external
      Encoding.default_external = Encoding::US_ASCII
      rows, = play_broken_chunk(->(text) { text.lines.first }, stderr: 'Zugriff verweigert: Größe')
      assert_equal 'Zugriff verweigert: Größe', rows['c.ann'].last
    ensure
      Encoding.default_external = external
      $VERBOSE = verbose
    end
  end

  # Eight networks and no bot, so every game is played in the arena. The
  # alphabetically first network of a game wins it.
  EIGHT = %w[a.ann b.ann c.ann d.ann e.ann f.ann g.ann h.ann].freeze

  def arena_by_name
    ->(id, game) { arena_played(id, result: game['black'] < game['white'] ? 'B+1.5' : 'W+1.5') }
  end

  def setup_arena_generation
    players = EIGHT.to_h { |name| [name, { 'command' => "../evo #{name}" }] }
    write_data('round' => 0, 'players' => players,
               'games' => EIGHT.each_slice(2).map { |black, white| { 'black' => black, 'white' => white } },
               'ranking' => EIGHT.map { |name| { 'name' => name, 'score' => 0 } })
  end

  ARENA_SETTINGS = { 'tournament_rounds' => 3, 'concurrency' => 2 }.freeze

  def play_generation(pool)
    gen = build_with(pool, settings: ARENA_SETTINGS)
    capture_io { gen.send(:play_games) }
    gen
  end

  # The rows without their timings, which depend on how the games were chunked.
  def untimed_games
    database.games(1).map { |row| row.except(:duration, :time_black, :time_white) }
  end

  def test_rounds_go_on_after_an_arena_that_gave_no_result
    in_experiment do
      setup_arena_generation
      gen = play_generation(FakePool.new(arena_output: ->(_text) { 'garbage' }))
      assert_equal 3, gen.send(:data)['round']
      assert_equal 12, database.games(1).size
      assert(database.games(1).all? { |row| row[:failure] == 'arena: no result' })
    end
  end

  def test_a_resumed_generation_plays_only_its_pending_arena_games_and_ends_as_if_uninterrupted
    in_experiment do
      setup_arena_generation
      play_generation(FakePool.new(arena: arena_by_name))
      @expected = [untimed_games, database.ranking(1)]
    end
    @database = nil
    in_experiment do
      setup_arena_generation
      # Ctrl-C kills the second chunk of the first round.
      interrupted = FakePool.new(arena: arena_by_name,
                                 status: ->(job) { job.name == 'arena-1' ? signal_status('INT') : exit_status(0) })
      assert_raises(SystemExit) { play_generation(interrupted) }
      assert_equal 2, database.games(1).size
      assert_equal 2, database.state(1)['games'].size

      resumed = FakePool.new(arena: arena_by_name)
      play_generation(resumed)
      # The chunks were a.ann-b.ann and e.ann-f.ann, then c.ann-d.ann and
      # g.ann-h.ann; the second one's games are dealt out again.
      assert_equal [['cxdR0'], ['gxhR0']], resumed.identifiers.first(2).map { |chunk| chunk.games.keys }
      assert_equal @expected, [untimed_games, database.ranking(1)]
    end
  end

  # What Ruby reports for a command that Ctrl-C (SIGINT) or SIGTERM ended:
  # killed by the signal, or, for a program that catches it and exits (the
  # JVM that runs gogui-twogtp), 128 plus the signal.
  INTERRUPTED = { 'SIGINT' => signal_status('INT'), 'SIGTERM' => signal_status('TERM'),
                  'exit 130' => exit_status(130), 'exit 143' => exit_status(143) }.freeze

  def test_an_interrupted_chunk_is_left_to_be_replayed_before_the_trap_ran
    INTERRUPTED.each do |how, status|
      in_experiment do
        @database = nil
        setup_round(TWO_ARENA_GAMES)
        gen = build_with(FakePool.new(status:, arena_output: ->(text) { text.lines.first }))
        _, err = capture_io { assert_equal 130, assert_raises(SystemExit, how) { gen.send(:play_round) }.status, how }
        assert_includes err, 'arena chunk arena-0 (axbR0, cxdR0) was interrupted; its games stay pending', how
        assert_empty database.games(1), how
        assert_equal 2, database.state(1)['games'].size, how
      end
    end
  end

  def test_an_interrupted_gogui_game_is_left_to_be_replayed_before_the_trap_ran
    INTERRUPTED.each do |how, status|
      in_experiment do
        @database = nil
        setup_round([['a.ann', 'Brown1']])
        pool = FakePool.new(status:) { |game| File.write("#{prefix(game)}.err", 'Interrupted') }
        gen = build_with(pool)
        _, err = capture_io { assert_equal 130, assert_raises(SystemExit, how) { gen.send(:play_round) }.status, how }
        assert_includes err, 'game axBrown1R0 was interrupted; it stays pending', how
        assert_empty database.games(1), how
        assert_equal [{ 'black' => 'a.ann', 'white' => 'Brown1' }], database.state(1)['games'], how
      end
    end
  end
end

class ReproducibleRoundsTest < Minitest::Test
  include RunGenerationHelpers

  def ranking(order)
    order.map { |name, score| { 'name' => name, 'score' => score } }
  end

  def next_round_games(order)
    in_experiment do
      write_data('round' => 0, 'players' => {}, 'games' => [], 'ranking' => ranking(order))
      gen = build_generation(settings: { 'tournament_rounds' => 3 })
      gen.send(:setup_next_round)
      gen.send(:data).values_at('games', 'ranking')
    end
  end

  def test_pairings_depend_on_the_scores_not_on_the_order_ties_are_listed_in
    scores = { 'a.ann' => 2, 'b.ann' => 1, 'c.ann' => 1, 'd.ann' => 1, 'e.ann' => 0, 'f.ann' => 0 }
    assert_equal next_round_games(scores.to_a), next_round_games(scores.to_a.reverse)
  end

  def test_tournaments_are_the_same_for_the_same_seed
    tournament = lambda do |seed|
      in_experiment do
        %w[0001.ann 0002.ann 0003.ann].each { |name| File.write(name, '') }
        build_generation(settings: { 'seed' => seed }).send(:setup_tournament).values_at('ranking', 'games')
      end
    end
    assert_equal tournament.call(1), tournament.call(1)
    refute_equal tournament.call(1), tournament.call(2)
  end

  # initial-population's genes line for a network of the given shape.
  def initial_genes_line(layers: 1, width: 10)
    "genes layers=#{layers} width=#{width} act_hidden=sigmoid_cached act_output=sigmoid_cached copy_chance=0.01 " \
      "weight_changes=1 weight_step=0.5 activation_rate=0.02 structure_rate=0.02 features=none feature_step=0.01\n"
  end

  # Runs setup_initial_population with initial-population replaced: it
  # writes `networks` and prints `output` (by default a genes line for each
  # network), and returns `result`.
  def populate(gen, networks: %w[0001.ann 0002.ann], output: nil, result: true)
    commands = []
    output ||= "population_size = 2\n#{initial_genes_line * networks.size}"
    gen.define_singleton_method(:run_initial_population) do |cmd|
      commands << cmd
      networks.each { |name| File.write(name, name) }
      [result, output]
    end
    capture_io { gen.send(:setup_initial_population) }
    commands
  end

  def test_the_initial_population_gets_its_seed_and_is_recorded
    in_experiment(generation: '0') do
      store = database
      gen = build_generation(generation: '0', store:)
      commands = populate(gen)
      seed = Seeds.derive(1, 'initial-population')
      # No feature groups yet, with the default noise and feature_step.
      assert_equal ["../initial-population 2 9 1 10 0.01 1.0 0.5 0.02 0.02 none 0.3 0.01 #{seed}"], commands
      assert_equal [%w[0001.ann initial], %w[0002.ann initial]], store.births(0).map { |b| b.values_at(:child, :operator) }
      assert_equal [seed, seed], store.births(0).map { |b| b[:seed] }
      assert_equal Digest::SHA256.hexdigest('0001.ann'), store.births(0).first[:genome]
      assert_equal %w[0001.ann 0002.ann], store.network_names(0)
    end
  end

  # The initial genes are the experiment's settings.
  def test_the_initial_population_gets_the_initial_genes
    in_experiment(generation: '0') do
      gen = build_generation(generation: '0', settings: { 'initial_copy_chance' => 0.03, 'initial_weight_changes' => 7.5,
                                                          'initial_weight_step' => 0.25, 'initial_activation_rate' => 0.04,
                                                          'initial_structure_rate' => 0.05 })
      assert_equal '0.03 7.5 0.25 0.04 0.05', populate(gen).first.split[5, 5].join(' ')
    end
  end

  # Each network's genes line, in file order, fills its birth.
  def test_the_initial_births_record_each_networks_genes
    in_experiment(generation: '0') do
      store = database
      lines = [initial_genes_line, initial_genes_line.sub('copy_chance=0.01', 'copy_chance=0.0625')]
      populate(build_generation(generation: '0', store:), output: lines.join)
      births = store.births(0)
      assert_equal [0.01, 0.0625], births.map { |b| b[:copy_chance] }
      assert_equal({ parent: nil, structure: nil, activation_changed: nil, layers: 1, width: 10,
                     act_hidden: 'sigmoid_cached', act_output: 'sigmoid_cached', copy_chance: 0.01,
                     weight_changes: 1.0, weight_step: 0.5, activation_rate: 0.02, structure_rate: 0.02 },
                   births.first.slice(*ExperimentDatabase::BIRTH_GENE_COLUMNS, :parent, :structure, :activation_changed))
    end
  end

  # A genes line per network, each well formed and of the generation-0
  # shape, or the run stops before anything is stored.
  def test_initial_genes_lines_that_do_not_match_the_networks_stop_the_run
    [initial_genes_line,
     initial_genes_line * 3,
     initial_genes_line + initial_genes_line.sub('copy_chance=0.01', 'copy_chance=nan'),
     initial_genes_line + initial_genes_line.sub('act_hidden=sigmoid_cached', 'act_hidden=softmax'),
     initial_genes_line + initial_genes_line.sub(' structure_rate=0.02', ''),
     initial_genes_line + initial_genes_line(width: 11),
     initial_genes_line + initial_genes_line(layers: 2),
     initial_genes_line + initial_genes_line.sub('feature_step=0.01', 'feature_step=inf'),
     initial_genes_line + initial_genes_line.sub('features=none feature_step=0.01',
                                                 'features=last_move feature_step=0.01 fw_near_last=0.05')].each do |output|
      in_experiment(generation: '0') do
        store = database
        gen = build_generation(generation: '0', store:)
        error = assert_raises(RuntimeError, output) { populate(gen, output:) }
        assert_match(/genes/, error.message)
        assert_empty store.births(0)
        assert_empty store.network_names(0)
      end
      @database = nil
    end
  end

  def test_initial_genes_lines_without_hidden_layers_have_width_0
    in_experiment(generation: '0') do
      store = database
      gen = build_generation(generation: '0', store:, settings: { 'hidden_layers' => 0 })
      populate(gen, output: initial_genes_line(layers: 0, width: 0) * 2)
      assert_equal [[0, 0], [0, 0]], store.births(0).map { |b| b.values_at(:layers, :width) }
    end
  end

  # Generation 0 must never start short of networks: a failed or incomplete
  # initial-population stops the runner before anything is stored.
  def initial_population_with(result, networks)
    in_experiment(generation: '0') do
      store = database
      gen = build_generation(generation: '0', store:)
      error = assert_raises(RuntimeError) { populate(gen, networks:, result:) }
      assert_empty store.births(0)
      assert_empty store.network_names(0)
      assert_nil store.state(0)
      error.message
    end
  end

  def test_a_failed_initial_population_stops_the_run
    assert_match(/initial-population failed/, initial_population_with(false, %w[0001.ann]))
  end

  def test_an_initial_population_short_of_networks_stops_the_run
    assert_match(/wrote 1 networks, expected 2/, initial_population_with(true, %w[0001.ann]))
  end

  def test_a_finished_generation_resumed_later_still_gets_its_ranking
    # The runner can stop after saving the last round but before storing the ranking.
    in_experiment do
      write_data('round' => 1, 'games' => [], 'players' => { 'a.ann' => {} },
                 'ranking' => [{ 'name' => 'a.ann', 'score' => 1 }])
      store = database
      assert_equal :already_done, build_generation(store:).send(:play_games)
      assert_equal [[1, 'a.ann', 1]], store.ranking(1).map { |r| r.values_at(:rank, :name, :score) }
    end
  end

  def test_a_resumed_generation_plays_with_its_stored_networks_in_a_fresh_work_directory
    in_experiment do
      FileUtils.mkdir_p('work')
      File.write('work/stale.ann', 'left over')
      database.record_network(2, '0.ann', 'weights of 0')
      database.record_network(2, '1.ann', 'weights of 1')
      write_data({ 'setup_complete' => true, 'round' => 0 }, generation: 2)
      seen = nil
      build_generation(generation: '2').send(:setup) { seen = Dir.children('.').sort.to_h { |f| [f, File.read(f)] } }
      assert_equal({ '0.ann' => 'weights of 0', '1.ann' => 'weights of 1' }, seen)
    end
  end

  def test_the_final_ranking_is_stored_when_the_generation_ends
    in_experiment do
      write_data('round' => 0, 'games' => [],
                 'players' => { 'a.ann' => {}, 'Brown1' => { 'external' => true } },
                 'ranking' => [{ 'name' => 'Brown1', 'score' => 1 }, { 'name' => 'a.ann', 'score' => 0 }])
      store = database
      gen = build_generation(store:)
      gen.instance_variable_set(:@pool, FakePool.new {})
      capture_io { gen.send(:play_games) }
      assert_equal [[1, 'Brown1', 1, true], [2, 'a.ann', 0, false]],
                   store.ranking(1).map { |r| r.values_at(:rank, :name, :score, :external) }
    end
  end
end

class PlayRoundBookkeepingTest < Minitest::Test
  include RunGenerationHelpers

  def test_prepare_game_builds_the_twogtp_command_with_a_seeded_referee_and_saves_stderr
    in_experiment do
      write_data('round' => 0, 'players' => {
                   'a.ann' => { 'command' => '../evo a.ann' },
                   'Brown1' => { 'command' => 'brown' }
                 })
      game = { 'black' => 'a.ann', 'white' => 'Brown1' }
      prepared = build_generation.send(:prepare_game, game)
      seed = Seeds.gnugo(1, 'game', 1, 0, 'a.ann', 'Brown1')
      assert_equal game, prepared['identifier']
      assert_equal %(gogui-twogtp -black "../evo a.ann" -white "brown" ) +
                   %(-referee "gnugo --mode gtp --chinese-rules --seed #{seed}" -size 9 -komi 6.5 ) +
                   '-auto -games 1 -sgffile axBrown1R0 -time 10 -force -maxmoves 200 2> axBrown1R0.err',
                   prepared['command']
    end
  end

  def test_prepare_game_gives_the_experiment_komi
    in_experiment do
      write_data('round' => 0, 'players' => {
                   'a.ann' => { 'command' => '../evo a.ann' },
                   'Brown1' => { 'command' => 'brown' }
                 })
      command = build_generation(settings: { 'komi' => 7.0 }).send(:prepare_game, { 'black' => 'a.ann', 'white' => 'Brown1' })['command']
      assert_includes command, ' -komi 7.0 '
    end
  end

  def test_gnugo_players_get_a_seed_per_game
    in_experiment do
      write_data('round' => 2, 'players' => {
                   'a.ann' => { 'command' => '../evo a.ann' },
                   'GnuGoLevel01' => { 'command' => 'gnugo --level 0 --mode gtp' }
                 })
      command = build_generation.send(:prepare_game, { 'black' => 'GnuGoLevel01', 'white' => 'a.ann' })['command']
      seed = Seeds.gnugo(1, 'game', 1, 2, 'GnuGoLevel01', 'a.ann')
      assert_includes command, %(-black "gnugo --level 0 --mode gtp --seed #{seed}" -white "../evo a.ann")
      assert_includes command, %(-referee "gnugo --mode gtp --chinese-rules --seed #{seed}")
    end
  end

  def test_update_data_gives_the_winner_one_point_removes_the_game_and_sorts_the_ranking
    in_experiment do
      game = { 'black' => 'a.ann', 'white' => 'b.ann' }
      write_data('games' => [game, { 'black' => 'c.ann', 'white' => nil }],
                 'ranking' => [{ 'name' => 'a.ann', 'score' => 0 }, { 'name' => 'b.ann', 'score' => 2 },
                               { 'name' => 'c.ann', 'score' => 1 }])
      gen = build_generation
      gen.send(:update_data, game, { 'winner' => 'a.ann' })
      data = gen.send(:data)
      assert_equal [{ 'black' => 'c.ann', 'white' => nil }], data['games']
      assert_equal 'b.ann', data['ranking'].first['name']
      assert_equal({ 'a.ann' => 1, 'b.ann' => 2, 'c.ann' => 1 }, data['ranking'].to_h { |r| r.values_at('name', 'score') })
    end
  end

  def test_update_data_records_a_failed_game_without_awarding_points
    in_experiment do
      game = { 'black' => 'a.ann', 'white' => 'b.ann' }
      write_data('round' => 2, 'games' => [game],
                 'ranking' => [{ 'name' => 'a.ann', 'score' => 1 }, { 'name' => 'b.ann', 'score' => 0 }])
      gen = build_generation
      _out, err = capture_io { gen.send(:update_data, game, { 'winner' => nil, 'failure' => 'no result file' }) }
      data = gen.send(:data)
      assert_empty data['games']
      assert_equal [['a.ann', 1], ['b.ann', 0]], data['ranking'].map(&:values)
      assert_includes err, 'axbR2: no result file'
    end
  end

  def test_update_data_defaults_to_one_point
    in_experiment do
      game = { 'black' => 'a.ann', 'white' => nil }
      write_data('games' => [game], 'ranking' => [{ 'name' => 'a.ann', 'score' => 0 }])
      gen = build_generation
      gen.send(:update_data, game, { 'winner' => 'a.ann' })
      assert_equal 1, gen.send(:data)['ranking'].first['score']
    end
  end
end

class GenerationBenchmarkTest < Minitest::Test
  include RunGenerationHelpers

  # Runs a whole generation, with its networks already bred and a panel of
  # Brown alone, and returns what call returned and the benchmark's rows.
  # `round` 1 means the tournament is already over, as on a resume.
  # With `benchmarked`, the benchmark's games are stored already.
  def run_generation(generation, round:, settings: {}, benchmarked: false)
    in_experiment do
      store = ExperimentDatabase.new(':memory:')
      store.save_benchmark_opponents([{ name: 'Brown', kind: 'bot', command: 'brown' }])
      %w[a.ann b.ann].each { |name| store.record_network(generation, name, name) }
      store.save_state(generation, { 'setup_complete' => true, 'round' => round, 'games' => [],
                                     'players' => { 'a.ann' => {}, 'b.ann' => {} },
                                     'ranking' => [{ 'name' => 'b.ann', 'score' => 1 }, { 'name' => 'a.ann', 'score' => 0 }] })
      if benchmarked
        { 'black' => 'network', 'white' => 'opponent' }.each do |color, winner|
          store.record_benchmark_game(generation:, opponent: 'Brown', opening: 0, network_color: color, network: 'b.ann', winner:)
        end
      end
      gen = build_generation(generation: generation.to_s, settings: { 'benchmark_games' => 2 }.merge(settings), store:)
      gen.instance_variable_set(:@pool, FakePool.new { |game| copy_dat('black_wins', game.prefix) })
      result = nil
      capture_io { result = gen.call }
      [result, store.benchmark_games(generation).map { |row| row.values_at(:network, :network_color, :winner) }]
    end
  end

  def test_a_checkpoint_benchmarks_its_top_network_after_the_tournament
    assert_equal [nil, [%w[b.ann black network], %w[b.ann white opponent]]], run_generation(10, round: 0)
  end

  # b.ann leads before the tournament, and a.ann takes the lead by beating
  # it, so benchmarking before the tournament would pick b.ann.
  def test_a_checkpoint_benchmarks_the_leader_after_its_tournament
    in_experiment do
      store = ExperimentDatabase.new(':memory:')
      store.save_scoring(SetupExperiment::DEFAULT_SCORING)
      store.save_benchmark_opponents([{ name: 'Brown', kind: 'bot', command: 'brown' }])
      %w[a.ann b.ann].each { |name| store.record_network(10, name, name) }
      store.save_state(10, { 'setup_complete' => true, 'round' => 0, 'games' => [{ 'black' => 'a.ann', 'white' => 'b.ann' }],
                             'players' => { 'a.ann' => { 'command' => '../evo a.ann' }, 'b.ann' => { 'command' => '../evo b.ann' } },
                             'ranking' => [{ 'name' => 'b.ann', 'score' => 0 }, { 'name' => 'a.ann', 'score' => 0 }] })
      gen = build_generation(generation: '10', settings: { 'benchmark_games' => 2 }, store:)
      # a.ann plays black in the arena and wins.
      gen.instance_variable_set(:@pool, FakePool.new { |game| copy_dat('black_wins', game.prefix) })
      capture_io { gen.call }
      assert_equal %w[a.ann a.ann], store.benchmark_games(10).map { |row| row[:network] }
    end
  end

  # Not :already_done, so a one-generation run stops after this generation
  # instead of playing the next one too.
  def test_a_resumed_checkpoint_finishes_its_benchmark
    assert_equal [nil, [%w[b.ann black network], %w[b.ann white opponent]]], run_generation(10, round: 1)
  end

  def test_a_resumed_checkpoint_with_a_finished_benchmark_is_already_done
    played = [%w[b.ann black network], %w[b.ann white opponent]]
    assert_equal [:already_done, played], run_generation(10, round: 1, benchmarked: true)
  end

  def test_other_generations_are_not_benchmarked
    assert_equal [:already_done, []], run_generation(5, round: 1)
  end

  def test_keep_every_zero_benchmarks_no_generation
    assert_equal [:already_done, []], run_generation(0, round: 1, settings: { 'keep_every' => 0 })
  end
end
