require_relative 'test_helper'
require 'timeout'

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

  # Scores a game from its record in the output of `arena --mixed`.
  def score(line, game = NETWORK_VS_NETWORK)
    in_experiment do
      write_data('round' => 0, 'players' => players)
      result = ArenaResult.mixed_chunk("#{ArenaResult::HEADER}\n#{line}\ndone 1\n", ['g']).results.fetch('g')
      build_generation.send(:score_game, game, result)
    end
  end

  def test_black_win_names_black_as_winner
    assert_equal({ 'winner' => '0001.ann' }, score(arena_played('g', result: 'B+3.5')))
  end

  def test_white_win_names_white_as_winner
    assert_equal({ 'winner' => 'GnuGoLevel101' }, score(arena_played('g', result: 'W+0.5'), NETWORK_VS_BOT))
  end

  def test_draw_gives_no_points_and_is_not_a_failure
    assert_equal({ 'winner' => nil }, score(arena_played('g', result: '0')))
  end

  def test_move_limit_uses_the_count_on_the_board
    assert_equal({ 'winner' => '0002.ann' }, score(arena_played('g', result: 'W+6.5', finish: 'limit')))
  end

  # Owner decision: a bot's resignation is a win for its opponent.
  def test_a_bot_that_resigns_loses
    assert_equal({ 'winner' => '0001.ann' }, score(arena_played('g', result: 'B+R', finish: 'resign', moves: %w[C3]),
                                                   NETWORK_VS_BOT))
  end

  def test_a_network_out_of_main_time_loses
    assert_equal({ 'winner' => 'GnuGoLevel101' }, score(arena_played('g', result: 'W+T', finish: 'time', moves: %w[C3]),
                                                        NETWORK_VS_BOT))
  end

  def test_a_network_that_cannot_be_loaded_loses
    assert_equal({ 'winner' => '0002.ann' }, score(arena_network_error('g', side: 'black')))
    assert_equal({ 'winner' => '0001.ann' }, score(arena_network_error('g', side: 'white')))
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

  # Writes generation 0's networks into networks/0/ and its state into the
  # database, then runs the breeding step for generation 1 in the current
  # directory (work/) with `../evolve` replaced by the given block, run on
  # an evolve_pool (`pool` are its options). The block returns [success,
  # stdout, status, stderr] (the last two optional). `stale_child` is
  # left in networks/1.partial/0.ann, as an interrupted earlier run would.
  # `prepare` gets the database before breeding, to stub it.
  def breed(scores:, settings: {}, stale_child: nil, pool: {}, prepare: nil, &evolve)
    settings = { 'keep_every' => 0 }.merge(settings)
    # A database of its own, so a test can breed more than once.
    @database = nil
    in_experiment do
      if stale_child
        FileUtils.mkdir_p('../networks/1.partial')
        File.write('../networks/1.partial/0.ann', stale_child)
      end
      write_networks(0, scores.keys.to_h { |name| [name, name] })
      write_data({
                   'players' => scores.keys.to_h { |name| [name, {}] },
                   'ranking' => scores.map { |name, score| { 'name' => name, 'score' => score } }
                 }, generation: 0)

      commands = []
      store = database
      prepare&.call(store)
      gen = build_generation(settings: settings, store:)
      fake = evolve_pool(**pool) do |cmd|
        commands << cmd
        evolve ? evolve.call(cmd) : [true, SUMMARY]
      end
      gen.instance_variable_set(:@pool, fake)
      error = nil
      err = nil
      out = nil
      begin
        out, err = capture_io { gen.send(:evolve_from_previous_population) }
      rescue StandardError, SystemExit => e
        error = e
      end
      {
        commands: commands,
        pool: fake,
        out: out,
        error: error,
        err: err,
        children: files_in('../networks/1'),
        partial: files_in('../networks/1.partial'),
        parents: files_in('../networks/0').keys,
        rows: database.network_names(0) + database.network_names(1),
        work: Dir.children('.').sort,
        data: database.state(1),
        memory: gen.send(:data),
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
  # The parents are read from networks/0/, beside work/.
  PARENTS = %r{\A\.\./evolve 0\.5 0\.2 4 200 10 \.\./networks/0/000[12]\.ann \.\./networks/0/000[12]\.ann}

  # Each child is written into networks/1.partial/, which becomes
  # networks/1/ once every child is there; the parents' networks/0/ is
  # deleted once the setup is saved. No network goes into the database.
  def test_breeds_children_from_selected_parents_and_deletes_the_parents
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }) { |cmd| write_child(cmd) }
    assert_nil state[:error]
    assert_equal 2, state[:commands].size
    state[:commands].each_with_index do |cmd, i|
      assert_match(%r{#{PARENTS} \.\./networks/1\.partial/#{i}\.ann #{Seeds.derive(1, 'birth', 1, i)}\z}, cmd)
    end
    assert_equal %w[0.ann 1.ann], state[:children].keys
    assert_empty state[:partial]
    assert_empty state[:parents]
    assert_empty state[:rows]
    assert_empty state[:work]
    assert_equal({ '0.ann' => '../evo ../networks/1/0.ann', '1.ann' => '../evo ../networks/1/1.ann' },
                 state[:data]['players'].select { |name, _| name.end_with?('.ann') }.transform_values { |p| p['command'] })
    assert state[:data]['setup_complete']
    assert_equal 0, state[:data]['round']
    # The runner goes on with the state it saved, not a reload.
    assert_equal state[:data], state[:memory]
  end

  def test_all_zero_scores_still_breed_from_real_parents
    state = breed(scores: { '0001.ann' => 0, '0002.ann' => 0 }) { |cmd| write_child(cmd) }
    assert_nil state[:error]
    state[:commands].each { |cmd| assert_match PARENTS, cmd }
  end

  def test_evolve_failing_stops_breeding_before_the_parents_are_deleted
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }) { [false, ''] }
    assert_match(/evolve failed to breed 0\.ann/, state[:error].message)
    assert_includes state[:parents], '0001.ann'
    assert_nil state[:data]
  end

  # Each child is one pool job: evolve exec'd, so WorkerPool#terminate
  # reaches it, with its stdout and stderr in work/, deleted once read.
  def test_each_child_is_a_pool_job_whose_output_files_are_deleted
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }) { |cmd| write_child(cmd) }
    assert_nil state[:error]
    assert_equal(state[:commands].each_with_index.map { |cmd, i| "exec #{cmd} > #{i}.out 2> #{i}.err" },
                 state[:pool].commands)
    assert_empty state[:work]
  end

  # evolve writing the child and its output does not make up for a failing exit.
  def test_evolve_exiting_with_an_error_stops_breeding_though_it_wrote_the_child
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }) do |cmd|
      _, stdout = write_child(cmd)
      [false, stdout, exit_status(1)]
    end
    assert_match(/evolve failed to breed 0\.ann/, state[:error]&.message)
    assert_includes state[:error].message, 'exited with status 1'
    assert_nil state[:data]
  end

  # Every child's parents are drawn before any evolve runs, two per child in
  # child order, as serial breeding drew them, so the order children finish
  # in changes neither their parents nor their bytes.
  def test_children_finishing_in_any_order_get_the_same_parents_and_bytes
    scores = (1..6).to_h { |i| [format('%04d.ann', i), i % 3] }
    settings = { 'population_size' => 5 }
    in_order = breed(scores:, settings:) { |cmd| write_child(cmd) }
    reversed = breed(scores:, settings:, pool: { reverse: true }) { |cmd| write_child(cmd) }
    assert_nil reversed[:error]
    assert_equal in_order[:births], reversed[:births]
    assert_equal in_order[:children], reversed[:children]
    assert_equal %w[4.ann 3.ann 2.ann 1.ann 0.ann], reversed[:commands].map { |cmd| File.basename(cmd.split[-2]) }

    gen = build_generation(settings:)
    candidates = gen.send(:parent_candidates, database.state(0))
    draws = Array.new(5) { Array.new(2) { gen.send(:select_parent, candidates) } }
    assert_equal draws, in_order[:births].map { |birth| birth.values_at(:first_parent, :second_parent) }
  end

  # The progress line counts the children that finished.
  def test_the_progress_line_counts_finished_children
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }, settings: { 'population_size' => 3 },
                  pool: { reverse: true }) { |cmd| write_child(cmd) }
    assert_equal ['0/3', '1/3', '2/3', '3/3'], state[:out].scan(%r{\d+/3})
  end

  # A failed evolve stops the others still running (WorkerPool#terminate)
  # and names its exit status and stderr; its setup is not saved.
  def test_a_failed_evolve_terminates_the_others_and_reports_its_stderr
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }, settings: { 'population_size' => 3 }) do |cmd|
      cmd.split[-2].end_with?('/0.ann') ? [false, '', exit_status(3), "cannot read parent\n"] : write_child(cmd)
    end
    message = state[:error].message
    assert_match(/evolve failed to breed 0\.ann/, message)
    assert_includes message, 'exited with status 3'
    assert_includes message, 'cannot read parent'
    assert_equal 2, state[:pool].terminated.size
    assert_equal 1, state[:commands].size
    assert_includes state[:parents], '0001.ann'
    assert_empty state[:children]
    assert_nil state[:data]
  end

  # Output breeding cannot use stops the other evolves too.
  def test_evolve_output_without_a_summary_terminates_the_others
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }, settings: { 'population_size' => 3 }) do |cmd|
      File.write(cmd.split[-2], cmd)
      [true, "Loading ...\n", nil, 'a warning']
    end
    assert_match(/no summary/, state[:error].message)
    assert_includes state[:error].message, 'a warning'
    assert_equal 2, state[:pool].terminated.size
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
    assert_includes state[:parents], '0001.ann'
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
      assert_includes state[:parents], '0001.ann', how
      assert_nil state[:data], how
    end
  end

  def test_evolve_writing_nothing_stops_breeding
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }) { [true, SUMMARY] }
    assert_match(/evolve failed to breed 0\.ann/, state[:error].message)
    assert_includes state[:parents], '0001.ann'
  end

  def test_child_left_by_an_interrupted_run_is_not_reused
    state = breed(scores: { '0001.ann' => 1 }, settings: { 'population_size' => 1 }, stale_child: 'stale') { [true, SUMMARY] }
    assert_match(/evolve failed to breed 0\.ann/, state[:error].message)
    assert_empty state[:partial]
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

  # The births are stored together once the last child is back, not one
  # commit each as the children finish.
  def test_births_are_stored_once_every_child_finished
    stored = []
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }, settings: { 'population_size' => 3 }) do |cmd|
      stored << database.births(1).size
      write_child(cmd)
    end
    assert_nil state[:error]
    assert_equal [0, 0, 0], stored
    assert_equal %w[0.ann 1.ann 2.ann], state[:births].map { |b| b[:child] }
  end

  # A birth that cannot be stored leaves none: they share one transaction.
  def test_a_birth_that_cannot_be_stored_leaves_none
    calls = 0
    prepare = lambda do |store|
      store.define_singleton_method(:record_birth) do |**birth|
        raise Sequel::Error, 'disk full' if (calls += 1) == 2

        super(**birth)
      end
    end
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }, prepare:) { |cmd| write_child(cmd) }
    assert_match(/disk full/, state[:error].message)
    assert_empty state[:births]
    assert_nil state[:data]
  end

  # A breeding failure stops the run with its report, as an arena stop does.
  def test_a_breeding_failure_is_a_stop
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }) { [false, '', exit_status(2), "bad parent\n"] }
    assert_kind_of RunGeneration::Stopped, state[:error]
    assert_instance_of RunGeneration::BreedingFailed, state[:error]
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
      assert_includes state[:parents], '0001.ann'
      assert_empty state[:children]
    end
  end

  ALL_GROUPS = 'shapes,tactics,last_move,liberties'.freeze
  ALL_WEIGHTS = 'fw_hane=0.05 fw_cut=0.0625 fw_edge=0.04 fw_capture=1.25 fw_self_atari=-1 fw_saves_atari=0.75 ' \
                'fw_near_last=0.03125'.freeze
  ALL_BIRTH = { features: ALL_GROUPS, feature_step: 0.02, fw_hane: 0.05, fw_cut: 0.0625, fw_edge: 0.04,
                fw_capture: 1.25, fw_self_atari: -1.0, fw_saves_atari: 0.75, fw_near_last: 0.03125 }.freeze

  # A child's feature set, feature_step, and feature weights go into its birth.
  def test_records_the_childs_feature_genes
    summary = SUMMARY.lines[1]
    genes = GENES_LINE.sub('features=none feature_step=0.01', "features=#{ALL_GROUPS} feature_step=0.02 #{ALL_WEIGHTS}")
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }, settings: { 'features' => ALL_GROUPS }) do |cmd|
      File.write(cmd.split[-2], cmd)
      [true, "Loading ...\n#{summary}#{genes}"]
    end
    assert_nil state[:error]
    state[:births].each { |birth| assert_equal ALL_BIRTH, birth.slice(*ALL_BIRTH.keys) }
  end

  # A feature weight the child's groups lack is NULL; feature_step is kept.
  def test_a_child_without_some_features_has_null_feature_weights
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }) { |cmd| write_child(cmd) }
    assert_nil state[:error]
    birth = state[:births].first
    assert_equal ['none', 0.01], birth.values_at(:features, :feature_step)
    assert_equal [nil] * 7, birth.values_at(*ExperimentDatabase::BIRTH_FEATURE_WEIGHT_COLUMNS)
  end

  # A child's genes line must have the experiment's feature set.
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
    assert_includes state[:parents], '0001.ann'
    assert_empty state[:children]
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
    state[:commands].each { |cmd| assert_match(%r{\A\.\./evolve 0\.5 0\.2 3 20 10 \.\./networks/0/}, cmd) }
  end

  # A network without hidden layers that gains one gets the generation-0
  # width, but never more than max_layer_size.
  def test_an_added_first_layer_is_at_most_max_layer_size_wide
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 },
                  settings: { 'hidden_layers' => 0, 'layer_size' => 500, 'max_layer_size' => 200 }) do |cmd|
      write_child(cmd)
    end
    state[:commands].each { |cmd| assert_match(%r{\A\.\./evolve 0\.5 0\.2 4 200 200 \.\./networks/0/}, cmd) }
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
    assert_includes state[:parents], '0001.ann'
  end

  # A checkpoint keeps only its champion, stored when its tournament ends,
  # so its networks go like any other generation's.
  def test_the_parents_of_a_kept_generation_are_deleted_too
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }, settings: { 'keep_every' => 10 }) { |cmd| write_child(cmd) }
    assert_nil state[:error]
    assert_empty state[:parents]
    assert_empty state[:rows]
  end

  def test_children_are_kept_with_the_bytes_evolve_wrote
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }) { |cmd| write_child(cmd) }
    assert_equal state[:commands][0], state[:children]['0.ann']
  end

  def test_skips_breeding_once_setup_is_complete
    in_experiment do
      write_data('setup_complete' => true)
      gen = build_generation
      gen.instance_variable_set(:@pool, evolve_pool { flunk 'evolve should not run' })
      gen.send(:evolve_from_previous_population)
      assert_empty gen.instance_variable_get(:@pool).commands
    end
  end
end

# Breeding on a real WorkerPool, with ../evolve a shell script that writes
# each child from its parents' bytes and its seed, as evolve would the same
# child from the same draws.
class BreedOnWorkerPoolTest < Minitest::Test
  include RunGenerationHelpers

  PARENTS = (1..6).to_h { |i| [format('%04d.ann', i), "parent #{i}\n"] }.freeze

  # The first children are the slowest, so at concurrency 4 they finish
  # after later ones. $6 and $7 are the parents, $8 the child, $9 its seed.
  BREEDS = <<~SH.freeze
    case "$8" in
      */0.ann) sleep 0.4 ;;
      */1.ann) sleep 0.2 ;;
    esac
    cat "$6" "$7" > "$8"
    echo "$9" >> "$8"
    echo "a warning about $8" >&2
    cat <<'EOF'
    #{EvolveFromPreviousPopulationTest::SUMMARY.chomp}
    EOF
  SH

  # Child 0 fails at once; the others would run for a minute.
  FAILS = <<~SH.freeze
    case "$8" in
      */0.ann) echo "cannot read $6" >&2; exit 3 ;;
    esac
    exec sleep 60
  SH

  # Breeds generation 1 of 8 children at `concurrency` with `script` as
  # ../evolve; returns the births in the order they were recorded, the
  # births, the children, the error, and the seconds it took.
  def breed_on(concurrency, script, pool: WorkerPool.new(concurrency))
    @database = nil
    in_experiment do
      File.write('../evolve', "#!/bin/sh\n#{script}")
      File.chmod(0o755, '../evolve')
      write_networks(0, PARENTS)
      write_data({ 'players' => PARENTS.keys.to_h { |name| [name, {}] },
                   'ranking' => PARENTS.keys.map.with_index { |name, i| { 'name' => name, 'score' => i % 3 } } },
                 generation: 0)
      recorded = []
      database.define_singleton_method(:record_birth) do |**birth|
        recorded << birth[:child]
        super(**birth)
      end
      gen = build_generation(settings: { 'population_size' => 8, 'keep_every' => 0, 'concurrency' => concurrency })
      gen.instance_variable_set(:@pool, pool)
      error = nil
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        capture_io { gen.send(:evolve_from_previous_population) }
      rescue StandardError, SystemExit => e
        error = e
      ensure
        pool.stop
      end
      { recorded:, births: database.births(1), children: files_in('../networks/1'), error:,
        seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, work: Dir.children('.') }
    end
  end

  def test_the_same_births_and_networks_at_any_concurrency
    serial = breed_on(1, BREEDS)
    parallel = breed_on(4, BREEDS)
    assert_nil serial[:error]
    assert_nil parallel[:error]
    assert_equal (0...8).map { |i| "#{i}.ann" }, serial[:recorded]
    # Finished out of order, and still the same.
    refute_equal serial[:recorded], parallel[:recorded]
    assert_equal serial[:births], parallel[:births]
    assert_equal serial[:children], parallel[:children]
    assert_equal 8, serial[:children].size
    assert_empty parallel[:work]
  end

  # Ctrl-C just before breeding: the trap halted the pool before the
  # evolves were queued. None runs, and the runner exits quietly.
  def test_ctrl_c_before_the_evolves_are_queued_exits_quietly
    $stop_now = true
    pool = WorkerPool.new(2)
    pool.halt
    state = Timeout.timeout(10) { breed_on(2, BREEDS, pool:) }
    assert_instance_of SystemExit, state[:error]
    assert_equal 0, state[:error].status
    assert_empty state[:recorded]
  ensure
    $stop_now = false
  end

  def test_a_failed_evolve_terminates_the_running_ones
    state = breed_on(4, FAILS)
    assert_match(/evolve failed to breed 0\.ann/, state[:error].message)
    assert_includes state[:error].message, 'cannot read ../networks/0/'
    assert_operator state[:seconds], :<, 20
    assert_empty state[:children]
    assert_empty state[:births]
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
      error = assert_raises(RunGeneration::BreedingFailed, line) { parse(line) }
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

  # String keys, as ExperimentDatabase#state loads them: the runner keeps
  # the state it saved, and play_round and update_data read string keys.
  def test_pairs_neighbours_in_ranking_order_with_string_keys
    result = games(%w[a.ann b.ann c.ann d.ann])
    assert_equal 2, result.size
    assert(result.all? { |game| game.keys == %w[black white] })
    assert_equal [%w[a.ann b.ann], %w[c.ann d.ann]], result.map { |game| game.values.sort }
  end

  def test_odd_player_out_sits_the_round_out
    assert_equal [{ 'black' => 'c.ann', 'white' => nil }], games(%w[a.ann b.ann c.ann]).drop(1)
  end

  # Bots play in the ranking like networks, so their place in it can be compared.
  def test_external_players_are_paired_like_networks
    assert_equal %w[Brown1 Brown2], games(%w[Brown1 Brown2 a.ann b.ann]).first.values.sort
  end

  # Early networks are far too weak for GNU Go, and its games set most of a
  # generation's wall time.
  def test_tournament_has_no_gnu_go_player
    in_experiment do
      write_networks(1, { '0001.ann' => '' })
      commands = build_generation.send(:setup_tournament)['players'].values.map { |player| player['command'] }
      assert_includes commands, 'amigogtp'
      refute(commands.any? { |command| command.start_with?('gnugo') })
    end
  end


  # The opponents come from the experiment's database, not from the code, so
  # an experiment keeps its panel when the defaults change.
  def test_the_opponents_come_from_the_experiment
    in_experiment do
      store = ExperimentDatabase.new(':memory:')
      write_networks(1, { '0001.ann' => '' }, store:)
      store.save_opponents([{ name: 'Pachi', command: 'pachi --playouts 10', copies: 2 }])
      store.save_scoring(SetupExperiment::DEFAULT_SCORING)
      players = build_generation(store:).send(:setup_players)
      assert_equal({ 'Pachi1' => { 'command' => 'pachi --playouts 10', 'external' => true },
                     'Pachi2' => { 'command' => 'pachi --playouts 10', 'external' => true },
                     '0001.ann' => { 'command' => '../evo ../networks/1/0001.ann' } }, players)
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
        gen.send(:update_data, games[3], { 'winner' => 'g.ann' })
      end
      scores = gen.send(:data)['ranking'].to_h { |r| r.values_at('name', 'score') }
      assert_equal({ 'a.ann' => 3, 'b.ann' => 0, 'c.ann' => 1, 'd.ann' => 1, 'e.ann' => 2, 'f.ann' => 0, 'g.ann' => 3 }, scores)
    end
  end

  def test_tournament_includes_every_external_player_and_a_bye_for_odd_counts
    in_experiment do
      write_networks(1, %w[0001.ann 0002.ann 0003.ann 0004.ann].to_h { |name| [name, name] })
      tournament = build_generation.send(:setup_tournament)
      # 4 networks, 5 Brown, and 10 AmiGo.
      assert_equal 19, tournament['players'].size
      assert_equal 10, tournament['games'].size
      assert_equal 1, tournament['games'].count { |game| game['white'].nil? }
      assert_equal '../evo ../networks/1/0001.ann', tournament['players']['0001.ann']['command']
    end
  end
end

class PlayRoundTest < Minitest::Test
  include RunGenerationHelpers

  NETWORKS = %w[a.ann b.ann c.ann d.ann e.ann f.ann g.ann h.ann i.ann j.ann].freeze
  BOTS = { 'Brown1' => 'brown', 'Brown2' => 'brown', 'GnuGo1' => 'gnugo --level 0 --mode gtp',
           'GnuGo2' => 'gnugo --level 0 --mode gtp' }.freeze

  # A round with the given games among the networks and bots above.
  def setup_round(games, generation: 1, round: 0, bots: BOTS)
    players = NETWORKS.to_h { |name| [name, { 'command' => "../evo #{name}" }] }
    bots.each { |name, command| players[name] = { 'command' => command, 'external' => true } }
    write_data(generation:, 'round' => round, 'players' => players,
               'games' => games.map { |black, white| { 'black' => black, 'white' => white } },
               'ranking' => players.keys.map { |name| { 'name' => name, 'score' => 0 } })
  end

  # a.ann against b.ann, c.ann against Brown1, and d.ann sits out.
  MIXED = [%w[a.ann b.ann], ['c.ann', 'Brown1'], ['d.ann', nil]].freeze

  def build_with(pool, generation: '1', settings: {}, store: nil)
    gen = build_generation(generation:, settings:)
    gen.instance_variable_set(:@pool, pool)
    gen.instance_variable_set(:@store, store || database)
    gen
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
    pool.identifiers.select { |identifier| identifier.respond_to?(:manifest) }
  end

  def pending(gen = nil)
    games = gen ? gen.send(:data)['games'] : database.state(1)['games']
    games.map { |game| game.values_at('black', 'white') }
  end

  def test_every_game_of_a_round_is_played_in_the_arena
    in_experiment do
      pool = FakePool.new
      gen = play(MIXED, pool)
      assert_empty gen.send(:data)['games']
      # a.ann and c.ann won as black, and d.ann sat the round out and gets
      # nothing for it.
      assert_equal({ 'a.ann' => 1, 'b.ann' => 0, 'c.ann' => 1, 'd.ann' => 0, 'Brown1' => 0 },
                   scores(gen).slice('a.ann', 'b.ann', 'c.ann', 'd.ann', 'Brown1'))
      assert_equal ['exec ../arena --mixed 9 6.5 200 600 10 10 arena-0.txt > arena-0.out 2> arena-0.err'], pool.commands
      assert_equal({ %w[a.ann b.ann] => 'tromp_taylor', %w[c.ann Brown1] => 'tromp_taylor' },
                   database.games(1).to_h { |row| [row.values_at(:black, :white), row[:scorer]] })
    end
  end

  def test_the_arena_gets_the_experiments_board_komi_move_limit_and_main_time
    in_experiment do
      pool = FakePool.new
      play([%w[a.ann b.ann]], pool, settings: { 'board_size' => 7, 'komi' => 7.0, 'max_moves' => 50, 'game_length' => 3 })
      assert_equal ['exec ../arena --mixed 7 7.0 50 180 10 10 arena-0.txt > arena-0.out 2> arena-0.err'], pool.commands
    end
  end

  # The players of the chunk's games first, a network with its file and a
  # bot by its name; then each game, followed by the command of each of its
  # bots. GNU Go gets the game's seed, derived as for every game since the
  # tournament began; other bots take none.
  def test_the_manifest_declares_the_players_then_each_game_with_its_bots_commands
    in_experiment do
      manifest = nil
      pool = FakePool.new(arena: lambda { |id, _game|
        manifest ||= File.read(chunks(pool).first.manifest)
        arena_played(id)
      })
      setup_round([%w[a.ann b.ann], %w[GnuGo1 c.ann], %w[d.ann Brown1], %w[Brown2 GnuGo2]], round: 2)
      capture_io { build_with(pool).send(:play_round) }
      seed = ->(black, white) { Seeds.gnugo(1, 'game', 1, 2, black, white) }
      assert_equal [
        %w[bot GnuGo1], %w[network c.ann ../networks/1/c.ann], %w[network d.ann ../networks/1/d.ann], %w[bot Brown1],
        %w[bot Brown2], %w[bot GnuGo2], %w[network a.ann ../networks/1/a.ann], %w[network b.ann ../networks/1/b.ann],
        %w[game GnuGo1xcR2 GnuGo1 c.ann], ['command', 'GnuGo1xcR2', 'black', "gnugo --level 0 --mode gtp --seed #{seed.('GnuGo1', 'c.ann')}"],
        %w[game dxBrown1R2 d.ann Brown1], %w[command dxBrown1R2 white brown],
        %w[game Brown2xGnuGo2R2 Brown2 GnuGo2], %w[command Brown2xGnuGo2R2 black brown],
        ['command', 'Brown2xGnuGo2R2', 'white', "gnugo --level 0 --mode gtp --seed #{seed.('Brown2', 'GnuGo2')}"],
        %w[game axbR2 a.ann b.ann]
      ], manifest.lines(chomp: true).map { |line| line.split("\t", -1) }
    end
  end

  # The arena splits a manifest line at tabs, and refuses control characters.
  def test_a_bot_command_the_manifest_cannot_hold_is_refused_before_any_game
    ["brown\t--level 1", "brown\n", "brown\x7f", ''].each do |command|
      in_experiment do
        @database = nil
        # The second chunk has the command, and neither starts.
        setup_round([%w[a.ann Brown2], %w[c.ann Brown1]], bots: { 'Brown1' => command, 'Brown2' => 'brown' })
        pool = FakePool.new
        gen = build_with(pool, settings: { 'concurrency' => 2 })
        error = assert_raises(ArgumentError) { capture_io { gen.send(:play_round) } }
        assert_includes error.message, command.inspect
        assert_empty pool.commands, command.inspect
        assert_empty database.games(1)
      end
    end
  end

  def test_a_bot_game_is_stored_with_its_players_sides_and_how_it_ended
    in_experiment(generation: '10') do
      store = database
      arena = lambda do |id, _game|
        case id
        when 'cxBrown1R0' then arena_played(id, result: 'B+R', finish: 'resign', moves: %w[C3], time_black: 0.04,
                                                time_white: 0.26, duration: 0.5)
        when 'Brown2xdR0' then arena_played(id, result: 'B+T', finish: 'time', moves: %w[C3 D4], time_black: 0.01,
                                                time_white: 600.04, duration: 600.25)
        else arena_network_error(id, side: 'white', message: 'cannot open b.ann')
        end
      end
      pool = FakePool.new(arena:, duration: 601.25, arena_stderr: 'a warning')
      gen = play([%w[a.ann b.ann], %w[c.ann Brown1], %w[Brown2 d.ann]], pool, generation: '10', store:)
      # The chunk's 0.5 s beyond its games' is shared by its three games.
      row = { generation: 10, round: 0, failure: nil, stderr: nil, scorer: 'tromp_taylor' }
      assert_equal [
        row.merge(black: 'Brown2', white: 'd.ann', black_external: true, white_external: false, winner: 'Brown2',
                  length: 2, referee_result: 'B+T', error_message: nil, duration: 600.25 + (0.5 / 3),
                  time_black: 0.0, time_white: 600.0, end_reason: 'time',
                  sgf: '(;GM[1]FF[4]SZ[9]KM[6.5]RE[B+T];B[cg];W[df])'),
        row.merge(black: 'a.ann', white: 'b.ann', black_external: false, white_external: false, winner: 'a.ann',
                  length: nil, referee_result: nil, error_message: 'cannot open b.ann', duration: 0.5 / 3,
                  time_black: nil, time_white: nil, end_reason: 'network_error', sgf: nil),
        row.merge(black: 'c.ann', white: 'Brown1', black_external: false, white_external: true, winner: 'c.ann',
                  length: 1, referee_result: 'B+R', error_message: nil, duration: 0.5 + (0.5 / 3),
                  time_black: 0.0, time_white: 0.3, end_reason: 'resign', sgf: '(;GM[1]FF[4]SZ[9]KM[6.5]RE[B+R];B[cg])')
      ], store.games(10)
      assert_equal({ 'a.ann' => 1, 'c.ann' => 1, 'Brown2' => 1, 'b.ann' => 0, 'd.ann' => 0, 'Brown1' => 0 },
                   scores(gen).slice('a.ann', 'b.ann', 'c.ann', 'd.ann', 'Brown1', 'Brown2'))
      assert_empty Dir['arena-*']
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
              time_black: 0.3, time_white: 0.0, scorer: 'tromp_taylor', end_reason: 'passes' }
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
      assert_equal ['b.ann', 'move limit exceeded', 'limit'],
                   store.games(1).first.values_at(:winner, :error_message, :end_reason)
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

  def test_keeps_the_arena_sgf_every_keep_every_generations
    in_experiment(generation: '10') do
      store = database
      play([%w[a.ann b.ann]], FakePool.new, generation: '10', store:)
      assert_equal '(;GM[1]FF[4]SZ[9]KM[6.5]RE[B+3.5];B[cg];W[df];B[];W[])', store.games(10).first[:sgf]
    end
  end

  def test_games_go_into_at_most_concurrency_chunks_covering_each_game_once
    games = NETWORKS.each_slice(2).to_a + [%w[Brown1 Brown2]]
    { 1 => 1, 2 => 2, 3 => 3, 6 => 6, 8 => 6 }.each do |concurrency, expected|
      in_experiment do
        @database = nil
        pool = FakePool.new
        gen = play(games + [['GnuGo1', nil]], pool, settings: { 'concurrency' => concurrency })
        assert_equal expected, chunks(pool).size, "concurrency #{concurrency}"
        assert_equal expected, pool.commands.size
        sizes = chunks(pool).map { |chunk| chunk.games.size }
        assert_operator sizes.max - sizes.min, :<=, 1
        scheduled = chunks(pool).flat_map { |chunk| chunk.games.values.map { |g| g.values_at('black', 'white') } }
        assert_equal games.sort, scheduled.sort
        assert_equal games.map(&:first).sort, scores(gen).select { |_, score| score == 1 }.keys.sort
        assert_equal games.size, database.games(1).size
      end
    end
  end

  # Wherever the bots stand in the ranking, a chunk gets at most one bot
  # game more than another, so the slow games run side by side.
  def test_bot_games_are_dealt_out_in_turn_like_the_others
    in_experiment do
      pool = FakePool.new
      play([%w[a.ann Brown1], %w[b.ann c.ann], %w[d.ann e.ann], %w[f.ann Brown2], %w[g.ann h.ann], %w[i.ann j.ann]],
           pool, settings: { 'concurrency' => 3 })
      bot_games = chunks(pool).map { |chunk| chunk.games.keys.count { |id| id.include?('Brown') } }
      assert_equal [1, 1, 0], bot_games
      assert_equal [2, 2, 2], chunks(pool).map { |chunk| chunk.games.size }
    end
  end

  # Ctrl-C just before a round: the trap halted the pool before its chunks
  # were queued. No arena runs, and the runner exits quietly.
  def test_ctrl_c_before_the_chunks_are_queued_exits_quietly
    in_experiment do
      setup_round([['a.ann', 'Brown1'], %w[b.ann c.ann]])
      $stop_now = true
      pool = WorkerPool.new(2)
      pool.halt
      gen = build_with(pool, settings: { 'concurrency' => 2 })
      error = Timeout.timeout(10) { assert_raises(SystemExit) { capture_io { gen.send(:play_round) } } }
      pool.stop
      assert_equal 0, error.status
      assert_empty database.games(1)
      assert_equal [['a.ann', 'Brown1'], %w[b.ann c.ann]], pending
    ensure
      $stop_now = false
    end
  end

  def test_ctrl_c_while_a_chunk_runs_leaves_its_games_to_be_replayed
    in_experiment do
      setup_round([['a.ann', 'Brown1'], %w[b.ann c.ann]])
      pool = FakePool.new(arena: lambda { |id, _game|
        $stop_now = true
        arena_played(id)
      })
      gen = build_with(pool)
      capture_io { assert_raises(SystemExit) { gen.send(:play_round) } }
      assert_empty database.games(1)
      assert_equal [['a.ann', 'Brown1'], %w[b.ann c.ann]], pending
    ensure
      $stop_now = false
    end
  end

  # Ctrl-C while a finished chunk's games are stored keeps the ones stored
  # and leaves the rest pending.
  def test_ctrl_c_between_a_chunks_games_keeps_those_stored
    in_experiment do
      setup_round([['a.ann', 'Brown1'], %w[b.ann c.ann]])
      store = database
      store.define_singleton_method(:record) do |**row|
        super(**row)
        $stop_now = true
      end
      gen = build_with(FakePool.new, store:)
      capture_io { assert_raises(SystemExit) { gen.send(:play_round) } }
      assert_equal [%w[a.ann Brown1]], store.games(1).map { |row| row.values_at(:black, :white) }
      assert_equal [%w[b.ann c.ann]], pending
    ensure
      $stop_now = false
    end
  end

  # Brown1 against a.ann, then c.ann against Brown2, then d.ann against
  # e.ann, in one chunk.
  THREE_GAMES = [%w[Brown1 a.ann], %w[c.ann Brown2], %w[d.ann e.ann]].freeze
  IDS = %w[Brown1xaR0 cxBrown2R0 dxeR0].freeze

  # Plays THREE_GAMES in one chunk whose output `arena_output` makes of the
  # records `arena` gives, with `status`, and expects it to stop the run.
  # Returns the games stored (black players), the games left pending, the
  # scores, and the error's message.
  def stopped_chunk(arena: ->(id, _game) { arena_played(id) }, arena_output: ->(text) { text },
                    status: exit_status(0), stderr: 'Segmentation fault', duration: 1.5)
    store = database
    setup_round(THREE_GAMES)
    pool = FakePool.new(arena:, arena_output:, arena_stderr: stderr, status:, duration:)
    gen = build_with(pool, store:)
    error = nil
    capture_io { error = assert_raises(RunGeneration::ArenaStopped) { gen.send(:play_round) } }
    assert_equal pending, pending(gen), 'the state in memory is the stored one'
    # Every stop says where it happened (the round as in the game IDs), how
    # to go on, and what the arena said, and stops the other chunks.
    assert_includes error.message, 'Arena chunk arena-0 of generation 1, round 0 '
    assert_includes error.message, "Its stderr:\n#{stderr}" unless stderr.empty?
    assert_includes error.message, 'No other chunk was running.'
    assert_match(/resume after fixing the cause\.\z/, error.message)
    assert_equal [], pool.terminated
    [store.games(1).map { |row| row[:black] }, pending.map(&:first),
     scores(gen).values_at('a.ann', 'c.ann', 'd.ann', 'Brown1'), error.message]
  end

  # The arena stops at a failure: a record, and nothing after it.
  def failing_at(failed_id, record)
    ->(id, _game) { id == failed_id ? record : arena_played(id) if IDS.index(id) <= IDS.index(failed_id) }
  end

  def test_a_bot_failure_stops_the_run_and_keeps_the_games_before_it
    %w[timeout illegal crash launch].each do |finish|
      in_experiment do
        @database = nil
        stored, left, points, message =
          stopped_chunk(arena: failing_at('cxBrown2R0', arena_failed('cxBrown2R0', finish:, message: "brown: #{finish}")),
                        status: exit_status(2), duration: 20.3)
        assert_equal ['Brown1'], stored, finish
        # The chunk's 20.3 s less its records' 0.05 s and 10.25 s go to the
        # one game stored.
        assert_in_delta 10.05, database.games(1).first[:duration], 1e-9, finish
        assert_equal %w[c.ann d.ann], left, finish
        assert_equal [0, 0, 0, 1], points, finish
        assert_includes message, "cxBrown2R0: #{finish} (white): brown: #{finish}", finish
        assert_includes message, 'dxeR0: no record', finish
        assert_includes message, 'Segmentation fault', finish
      end
    end
  end

  def test_neither_network_loading_stops_the_run
    in_experiment do
      stored, left, = stopped_chunk(arena: failing_at('dxeR0', arena_network_error('dxeR0', side: 'both')),
                                    status: exit_status(2))
      assert_equal %w[Brown1 c.ann], stored
      assert_equal %w[d.ann], left
    end
  end

  # The arena never writes one, but a failure record is a failure wherever
  # it stands.
  def test_a_failure_record_in_a_complete_chunk_stops_the_run
    in_experiment do
      arena = ->(id, _game) { id == 'Brown1xaR0' ? arena_failed(id, side: 'black') : arena_played(id) }
      stored, left, points, message = stopped_chunk(arena:)
      assert_equal %w[c.ann d.ann], stored
      assert_equal %w[Brown1], left
      assert_equal [0, 1, 1, 0], points
      assert_includes message, 'Brown1xaR0: timeout (black)'
    end
  end

  def test_an_arena_that_died_stops_the_run_and_keeps_its_valid_records
    { 'records cut off' => ->(text) { text.lines.first(2).join },
      'a record cut off mid-field' => ->(text) { text.lines.first(2).join + text.lines[2][0, 30] },
      'a missing trailer' => ->(text) { text.lines[0..-2].join } }.each do |how, output|
      in_experiment do
        @database = nil
        stored, left, points, message = stopped_chunk(arena_output: output, status: signal_status('KILL'))
        assert_equal ['Brown1'], stored.first(1), how
        assert_includes message, 'cxBrown2R0: no record', how unless how == 'a missing trailer'
        assert_equal IDS.size, stored.size + left.size, how
        assert_equal stored.size, points.sum, how
      end
    end
  end

  def test_output_that_is_not_the_arenas_stops_the_run_and_stores_nothing
    { 'garbage' => ->(_text) { "\xff\xfe garbage\nmore\tgarbage\n" }, 'nothing' => ->(_text) { '' },
      'no file' => ->(_text) {} }.each do |how, output|
      in_experiment do
        @database = nil
        stored, left, _, message = stopped_chunk(arena_output: output, status: exit_status(1))
        assert_empty stored, how
        assert_equal %w[Brown1 c.ann d.ann], left, how
        assert_includes message, 'arena-0', how
      end
    end
  end

  def test_records_without_a_header_are_kept_but_stop_the_run
    in_experiment do
      stored, left, = stopped_chunk(arena_output: ->(text) { text.lines.drop(1).join })
      assert_equal %w[Brown1 c.ann d.ann], stored
      assert_empty left
    end
  end

  def test_a_game_with_two_records_is_not_stored
    in_experiment do
      output = ->(text) { text.sub(/^(dxeR0\t.*\n)/) { "#{::Regexp.last_match(1)}#{::Regexp.last_match(1)}" } }
      stored, left, = stopped_chunk(arena_output: output)
      assert_equal %w[Brown1 c.ann], stored
      assert_equal %w[d.ann], left
    end
  end

  def test_a_complete_chunk_that_exited_with_an_error_stops_the_run
    in_experiment do
      stored, left, _, message = stopped_chunk(status: exit_status(1))
      assert_equal %w[Brown1 c.ann d.ann], stored
      assert_empty left
      assert_includes message, 'exited with status 1'
    end
  end

  # Each way a chunk can end without all its games: the valid records are
  # stored, the others stay pending, each named in the report.
  def test_every_way_a_chunk_can_fall_short_stops_the_run
    header_only = ->(_text) { "#{ArenaResult::HEADER}\ndone 0\n" }
    cut = ->(text) { text.lines.first(2).join }
    {
      'exit 1 with no records' => [{ arena_output: header_only, status: exit_status(1) }, [], %w[Brown1 c.ann d.ann],
                                   'did not finish its output, exited with status 1. 3 of its 3 games stay pending:'],
      'a crash mid-chunk' => [{ arena_output: cut, status: signal_status('SEGV') }, %w[Brown1], %w[c.ann d.ann],
                              'did not finish its output, was killed by SIGSEGV.'],
      'SIGKILL' => [{ arena_output: cut, status: signal_status('KILL') }, %w[Brown1], %w[c.ann d.ann],
                    'was killed by SIGKILL. 2 of its 3 games stay pending:'],
      'SIGSEGV after the last record' => [{ status: signal_status('SEGV') }, %w[Brown1 c.ann d.ann], [],
                                          "round 0 was killed by SIGSEGV. 0 of its 3 games stay pending.\nIts stderr"],
      'a malformed line' => [{ arena_output: ->(text) { text.sub(/^cxBrown2R0\t.*$/, "cxBrown2R0\tgarbage") } },
                             %w[Brown1 d.ann], %w[c.ann], 'did not finish its output. 1 of its 3 games'],
      'a missing header' => [{ arena_output: ->(text) { text.lines.drop(1).join } }, %w[Brown1 c.ann d.ann], [],
                             'wrote no header. 0 of its 3 games stay pending.']
    }.each do |how, (options, stored_games, left_games, says)|
      in_experiment do
        @database = nil
        stored, left, _, message = stopped_chunk(**options)
        assert_equal stored_games, stored, how
        assert_equal left_games, left, how
        assert_includes message, says, how
        (IDS - database.games(1).map { |row| "#{row[:black].delete_suffix('.ann')}x#{row[:white].delete_suffix('.ann')}R0" })
          .each { |id| assert_includes message, "  #{id}: no record", how }
      end
    end
  end

  # With one chunk per game, the first chunk to finish stops the run; the
  # others, still running, are terminated and never read, so their games
  # stay pending with no row, whatever they would have given.
  def test_chunks_still_running_at_the_stop_are_terminated_and_not_stored
    in_experiment do
      setup_round(THREE_GAMES)
      pool = FakePool.new(arena: ->(id, _game) { id == 'Brown1xaR0' ? arena_failed(id, side: 'black') : arena_played(id) },
                          status: ->(chunk) { chunk.name == 'arena-0' ? exit_status(2) : signal_status('TERM') })
      gen = build_with(pool, settings: { 'concurrency' => 3 })
      error = nil
      capture_io { error = assert_raises(RunGeneration::ArenaStopped) { gen.send(:play_round) } }
      assert_equal %w[arena-1 arena-2], pool.terminated.map(&:name)
      assert_empty database.games(1)
      assert_equal THREE_GAMES, pending
      assert_includes error.message, 'Sent SIGTERM to 2 other chunks still running; their games stay pending too.'
    end
  end

  # Ctrl-C while the stop terminates the other chunks changes nothing: the
  # run still stops with the report, and no game of theirs is scored.
  def test_ctrl_c_during_the_stop_leaves_the_other_chunks_games_pending
    in_experiment do
      setup_round(THREE_GAMES)
      pool = FakePool.new(arena: ->(id, _game) { id == 'Brown1xaR0' ? arena_failed(id, side: 'black') : arena_played(id) },
                          on_terminate: -> { $stop_now = true })
      gen = build_with(pool, settings: { 'concurrency' => 3 })
      capture_io { assert_raises(RunGeneration::ArenaStopped) { gen.send(:play_round) } }
      assert_equal %w[arena-1 arena-2], pool.terminated.map(&:name)
      assert_empty database.games(1)
      assert_equal THREE_GAMES, pending
    ensure
      $stop_now = false
    end
  end

  def test_the_report_says_how_many_other_chunks_were_terminated
    gen = build_generation
    assert_equal 'No other chunk was running.', gen.send(:terminated_note, 0)
    assert_equal 'Sent SIGTERM to 1 other chunk still running; its games stay pending too.', gen.send(:terminated_note, 1)
  end

  # A stand-in for ../arena: a shell script that plays the chunk named
  # `failing` by writing the header and `record` and exiting 2, and never
  # finishes any other chunk; on SIGTERM it exits 143, as a shell reports a
  # program the signal killed.
  def fake_arena(failing, record)
    File.write('../failing', "#{ArenaResult::HEADER}\n#{record}\n")
    File.write('../arena', <<~SH)
      #!/bin/sh
      for last; do :; done
      if [ "$last" = #{failing}.txt ]; then cat ../failing; exit 2; fi
      echo '#{ArenaResult::HEADER}'
      trap 'kill $!; exit 143' TERM
      sleep 30 & wait
    SH
    File.chmod(0o755, '../arena')
  end

  # With the real pool and a stand-in arena: the stop sends SIGTERM to the
  # chunk still running before anything waits for it, and never reads its
  # status (143, which would count as an interrupt, exit 130).
  def test_the_stop_terminates_the_running_chunks_before_joining_them
    in_experiment do
      fake_arena('arena-0', arena_failed('Brown1xaR0'))
      setup_round(THREE_GAMES)
      pool = WorkerPool.new(3)
      gen = build_with(pool, settings: { 'concurrency' => 3 })
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      error = nil
      capture_io { error = assert_raises(RunGeneration::ArenaStopped) { gen.send(:play_round) } }
      pool.stop
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 10
      assert_includes error.message, 'Brown1xaR0: timeout (white)'
      assert_includes error.message, 'Sent SIGTERM to 2 other chunks still running'
      assert_empty database.games(1)
      assert_equal THREE_GAMES, pending
    ensure
      pool&.stop
    end
  end

  # Under LANG=C, File.read gives US-ASCII, and scrubbing that would turn
  # the arena's UTF-8 into question marks.
  def test_the_chunks_output_is_read_as_utf8_whatever_the_locale
    in_experiment do
      verbose, $VERBOSE = $VERBOSE, nil
      external = Encoding.default_external
      Encoding.default_external = Encoding::US_ASCII
      stored, _, _, message = stopped_chunk(arena: failing_at('dxeR0', arena_failed('dxeR0', message: 'Größe')),
                                            stderr: 'Zugriff verweigert: Größe')
      assert_equal %w[Brown1 c.ann], stored
      assert_includes message, 'dxeR0: timeout (white): Größe'
      assert_includes message, 'Zugriff verweigert: Größe'
    ensure
      Encoding.default_external = external
      $VERBOSE = verbose
    end
  end

  # Eight networks and two bots, so every round has bot games. The
  # alphabetically first player of a game wins it.
  EIGHT = %w[a.ann b.ann c.ann d.ann e.ann f.ann g.ann h.ann].freeze

  def arena_by_name
    ->(id, game) { arena_played(id, result: game['black'] < game['white'] ? 'B+1.5' : 'W+1.5') }
  end

  def setup_arena_generation
    players = EIGHT.to_h { |name| [name, { 'command' => "../evo #{name}" }] }
    players['Brown1'] = { 'command' => 'brown', 'external' => true }
    players['Brown2'] = { 'command' => 'brown', 'external' => true }
    names = players.keys
    write_data('round' => 0, 'players' => players,
               'games' => names.each_slice(2).map { |black, white| { 'black' => black, 'white' => white } },
               'ranking' => names.map { |name| { 'name' => name, 'score' => 0 } })
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

  def uninterrupted
    in_experiment do
      setup_arena_generation
      play_generation(FakePool.new(arena: arena_by_name))
      [untimed_games, database.ranking(1)]
    end
  ensure
    @database = nil
  end

  def test_a_resumed_generation_plays_only_its_pending_games_and_ends_as_if_uninterrupted
    expected = uninterrupted
    in_experiment do
      setup_arena_generation
      # Ctrl-C kills the second chunk of the first round.
      interrupted = FakePool.new(arena: arena_by_name,
                                 status: ->(job) { job.name == 'arena-1' ? signal_status('INT') : exit_status(0) })
      assert_raises(SystemExit) { play_generation(interrupted) }
      assert_equal 3, database.games(1).size
      assert_equal 2, database.state(1)['games'].size

      resumed = FakePool.new(arena: arena_by_name)
      play_generation(resumed)
      # The bot game comes first, so the chunks were Brown1-Brown2,
      # c.ann-d.ann and g.ann-h.ann, then a.ann-b.ann and e.ann-f.ann; the
      # second one's games are dealt out again.
      assert_equal [['axbR0'], ['exfR0']], resumed.identifiers.first(2).map { |chunk| chunk.games.keys }
      assert_equal expected, [untimed_games, database.ranking(1)]
    end
  end

  # A failure stops the run with the failed game and those after it
  # pending; resuming plays exactly those, and no game is stored twice.
  def test_a_resumed_generation_replays_only_the_games_a_failure_withheld
    expected = uninterrupted
    in_experiment do
      setup_arena_generation
      # The second chunk of the first round is a.ann-b.ann, then e.ann-f.ann.
      failing = FakePool.new(arena: ->(id, game) { id == 'exfR0' ? arena_failed(id) : arena_by_name.call(id, game) })
      assert_raises(RunGeneration::ArenaStopped) { play_generation(failing) }
      assert_equal 4, database.games(1).size
      assert_equal [%w[e.ann f.ann]], database.state(1)['games'].map { |g| g.values_at('black', 'white') }

      resumed = FakePool.new(arena: arena_by_name)
      play_generation(resumed)
      assert_equal [['exfR0']], resumed.identifiers.first(1).map { |chunk| chunk.games.keys }
      assert_equal expected, [untimed_games, database.ranking(1)]
      assert_equal 15, database.games(1).size
    end
  end

  # When the first chunk to finish is the one that fails, the other chunk
  # is terminated unread: resuming plays the failed chunk's withheld games
  # and all of the other's, and ends as if nothing had stopped.
  def test_a_stop_by_the_first_chunk_to_finish_is_resumed_as_well
    expected = uninterrupted
    in_experiment do
      setup_arena_generation
      # The first chunk of the first round is Brown1-Brown2, c.ann-d.ann,
      # then g.ann-h.ann; the arena stops at the failure.
      arena = lambda do |id, game|
        case id
        when 'cxdR0' then arena_failed(id)
        when 'gxhR0' then nil
        else arena_by_name.call(id, game)
        end
      end
      failing = FakePool.new(arena:)
      assert_raises(RunGeneration::ArenaStopped) { play_generation(failing) }
      assert_equal %w[arena-1], failing.terminated.map(&:name)
      assert_equal [%w[Brown1 Brown2]], database.games(1).map { |row| row.values_at(:black, :white) }
      assert_equal [%w[a.ann b.ann], %w[c.ann d.ann], %w[e.ann f.ann], %w[g.ann h.ann]],
                   database.state(1)['games'].map { |g| g.values_at('black', 'white') }

      play_generation(FakePool.new(arena: arena_by_name))
      assert_equal expected, [untimed_games, database.ranking(1)]
      assert_equal 15, database.games(1).size
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
        setup_round([%w[a.ann b.ann], %w[c.ann Brown1]])
        pool = FakePool.new(status:, arena_output: ->(text) { text.lines.first(2).join })
        gen = build_with(pool)
        _, err = capture_io { assert_equal 130, assert_raises(SystemExit, how) { gen.send(:play_round) }.status, how }
        assert_includes err, 'arena chunk arena-0 (cxBrown1R0, axbR0) was interrupted; its games stay pending', how
        # An interrupt, not a stop: no report, and nothing is terminated.
        refute_includes err, 'resume after fixing', how
        assert_empty pool.terminated, how
        assert_empty database.games(1), how
        assert_equal 2, database.state(1)['games'].size, how
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
        write_networks(1, %w[0001.ann 0002.ann 0003.ann].to_h { |name| [name, name] })
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
  # writes `networks` into the directory it runs in and prints `output` (by
  # default a genes line for each network), and returns `result`. Returns
  # the commands, each with the directory it ran in.
  def populate(gen, networks: %w[0001.ann 0002.ann], output: nil, result: true)
    commands = []
    output ||= "population_size = 2\n#{initial_genes_line * networks.size}"
    gen.define_singleton_method(:run_initial_population) do |cmd|
      commands << cmd
      @ran_in = File.basename(Dir.pwd)
      networks.each { |name| File.write(name, name) }
      [result, output]
    end
    capture_io { gen.send(:setup_initial_population) }
    commands
  end

# scripts/compare-arena-scoring.rb regenerates an archived experiment's
# generation 0 from its settings with the arguments the runner gives.
def test_the_initial_population_arguments_come_from_the_settings_alone
  seed = Seeds.derive(1, 'initial-population')
  assert_equal %W[2 9 1 10 0.01 1.0 0.5 0.02 0.02 none 0.3 0.01 #{seed}],
               RunGeneration.initial_population_arguments(RunGenerationHelpers::SETTINGS)
end

def test_the_initial_population_gets_its_seed_and_is_recorded
    in_experiment(generation: '0') do
      store = database
      gen = build_generation(generation: '0', store:)
      commands = populate(gen)
      seed = Seeds.derive(1, 'initial-population')
      # It runs in networks/0.partial/, which becomes networks/0/.
      assert_equal ["../../initial-population 2 9 1 10 0.01 1.0 0.5 0.02 0.02 none 0.3 0.01 #{seed}"], commands
      assert_equal '0.partial', gen.instance_variable_get(:@ran_in)
      assert_equal [%w[0001.ann initial], %w[0002.ann initial]], store.births(0).map { |b| b.values_at(:child, :operator) }
      assert_equal [seed, seed], store.births(0).map { |b| b[:seed] }
      assert_equal Digest::SHA256.hexdigest('0001.ann'), store.births(0).first[:genome]
      assert_equal({ '0001.ann' => '0001.ann', '0002.ann' => '0002.ann' }, files_in('../networks/0'))
      assert_equal %w[0], Dir.children('../networks')
      assert_empty store.network_names(0)
      assert_equal '../evo ../networks/0/0001.ann', store.state(0)['players']['0001.ann']['command']
      # The runner goes on with the state it saved, not a reload.
      assert_equal store.state(0), gen.send(:data)
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

  # The feature set, the noise on the feature weights, and the initial
  # feature_step are the experiment's settings.
  def test_the_initial_population_gets_the_feature_settings
    in_experiment(generation: '0') do
      gen = build_generation(generation: '0', settings: { 'features' => 'shapes,liberties', 'initial_feature_noise' => 0.25,
                                                          'initial_feature_step' => 0.0001 })
      line = initial_genes_line.sub('features=none', 'features=shapes,liberties')
                               .sub('feature_step=0.01', 'feature_step=0.0001 fw_hane=0.05 fw_cut=0.05 fw_edge=0.05')
      assert_equal 'shapes,liberties 0.25 0.0001', populate(gen, output: line * 2).first.split[10, 3].join(' ')
    end
  end

  # Generation 0's births hold each network's feature genes, NULL for the
  # feature weights its groups lack.
  def test_the_initial_births_record_the_feature_genes
    in_experiment(generation: '0') do
      store = database
      line = initial_genes_line.sub('features=none feature_step=0.01', 'features=tactics feature_step=0.02 ' \
                                                                       'fw_capture=1.25 fw_self_atari=-1 fw_saves_atari=0.75')
      populate(build_generation(generation: '0', store:, settings: { 'features' => 'tactics' }), output: line * 2)
      assert_equal [{ features: 'tactics', feature_step: 0.02, fw_hane: nil, fw_cut: nil, fw_edge: nil, fw_capture: 1.25,
                      fw_self_atari: -1.0, fw_saves_atari: 0.75, fw_near_last: nil }] * 2,
                   store.births(0).map { |b| b.slice(:features, :feature_step, *ExperimentDatabase::BIRTH_FEATURE_WEIGHT_COLUMNS) }
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
        error = assert_raises(RunGeneration::BreedingFailed, output) { populate(gen, output:) }
        assert_match(/genes/, error.message)
        assert_empty store.births(0)
        refute Dir.exist?('../networks/0')
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
      error = assert_raises(RunGeneration::BreedingFailed) { populate(gen, networks:, result:) }
      assert_empty store.births(0)
      refute Dir.exist?('../networks/0')
      assert_nil store.state(0)
      error.message
    end
  end

  # Generation 0's births share one transaction too: one that cannot be
  # stored leaves none, and no saved setup.
  def test_an_initial_birth_that_cannot_be_stored_leaves_none
    in_experiment(generation: '0') do
      store = database
      calls = 0
      store.define_singleton_method(:record_birth) do |**birth|
        raise Sequel::Error, 'disk full' if (calls += 1) == 2

        super(**birth)
      end
      gen = build_generation(generation: '0', store:)
      assert_raises(Sequel::Error) { populate(gen) }
      assert_empty store.births(0)
      assert_nil store.state(0)
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

  # Its networks stay in networks/2/; work/ starts empty.
  def test_a_resumed_generation_plays_in_a_fresh_work_directory
    in_experiment do
      FileUtils.mkdir_p('work')
      File.write('work/stale.ann', 'left over')
      write_networks(2, { '0.ann' => 'weights of 0', '1.ann' => 'weights of 1' }, experiment: '.')
      write_data({ 'setup_complete' => true, 'round' => 0 }, generation: 2)
      seen = nil
      build_generation(generation: '2').send(:setup) { seen = [File.basename(Dir.pwd), Dir.children('.')] }
      assert_equal ['work', []], seen
      assert_equal({ '0.ann' => 'weights of 0', '1.ann' => 'weights of 1' }, files_in('networks/2'))
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
      write_networks(generation, { 'a.ann' => 'a.ann', 'b.ann' => 'b.ann' }, experiment: '.', store:)
      # A finished checkpoint stored its champion with its last round.
      store.record_network(generation, 'b.ann', 'b.ann') if round.positive? && keep?(generation, settings)
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

  def keep?(generation, settings)
    every = settings.fetch('keep_every', SETTINGS['keep_every'])
    every.positive? && (generation % every).zero?
  end

  # The benchmark reads the champion the tournament's end stored.
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
      write_networks(10, { 'a.ann' => 'a.ann', 'b.ann' => 'b.ann' }, experiment: '.', store:)
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

# The timings printed at the end of a generation (GenerationTimings formats
# them; its own tests pin the format).
class GenerationTimingsReportTest < Minitest::Test
  include RunGenerationHelpers

  EIGHT = %w[a.ann b.ann c.ann d.ann e.ann f.ann g.ann h.ann].freeze

  def setup
    @clock = FakeClock.new
  end

  def with_clock(gen)
    gen.instance_variable_set(:@clock, @clock)
    gen
  end

  # Eight networks with their files in networks/N/ and their births, and
  # round 0 of their tournament.
  def setup_eight(generation: 1, **state)
    write_networks(generation, EIGHT.to_h { |name| [name, name] }, experiment: '.')
    write_data({ 'round' => 0, 'players' => EIGHT.to_h { |name| [name, { 'command' => "../evo #{name}" }] },
                 'games' => EIGHT.each_slice(2).map { |black, white| { 'black' => black, 'white' => white } },
                 'ranking' => EIGHT.map { |name| { 'name' => name, 'score' => 0 } } }.merge(state), generation:)
  end

  # Replaces CheckpointBenchmark.call with `stub` for the duration of the block.
  def with_benchmark(stub)
    original = CheckpointBenchmark.method(:call)
    CheckpointBenchmark.define_singleton_method(:call, stub)
    yield
  ensure
    CheckpointBenchmark.singleton_class.send(:remove_method, :call)
    CheckpointBenchmark.define_singleton_method(:call, original)
  end

  def test_each_round_is_timed_with_its_worker_time_and_games
    in_experiment do
      setup_eight
      # Two chunks a round, 1.5 s each.
      pool = FakePool.new(clock: @clock)
      gen = with_clock(build_generation(settings: { 'tournament_rounds' => 2, 'concurrency' => 2 }))
      gen.instance_variable_set(:@pool, pool)
      # Saving takes 0.125 s: after each of a round's 4 games and once more
      # for the next round's pairing, all of it Ruby time.
      clock = @clock
      %i[remove_pending_game save_state].each do |save|
        database.define_singleton_method(save) do |*args, **options|
          clock.advance(0.125)
          super(*args, **options)
        end
      end
      capture_io { gen.send(:play_games) }
      assert_equal 'timings generation=1 partial=0 ' \
                   'round_1=3.625 worker_round_1=3.000 ruby_round_1=0.625 games_round_1=4 failures_round_1=0 ' \
                   'round_2=3.625 worker_round_2=3.000 ruby_round_2=0.625 games_round_2=4 failures_round_2=0 ' \
                   'tournament=7.250 worker=6.000 ruby=1.250 games=8 failures=0',
                   gen.send(:timings).line
    end
  end

  # Emptying work/ takes 0.25 s and verifying the networks 0.5 s of setup,
  # and pairing the next round 0.25 s of the round's Ruby time.
  def slow_bookkeeping(gen)
    clock = @clock
    gen.define_singleton_method(:empty_work) do
      clock.advance(0.25)
      super()
    end
    gen.define_singleton_method(:verify_networks) do
      clock.advance(0.5)
      super()
    end
    gen.define_singleton_method(:setup_next_round) do
      clock.advance(0.25)
      super()
    end
    gen
  end

  def test_a_resumed_generation_prints_what_this_session_ran_as_partial
    in_experiment do
      setup_eight('setup_complete' => true)
      gen = slow_bookkeeping(with_clock(build_generation(settings: { 'concurrency' => 2 })))
      gen.instance_variable_set(:@pool, FakePool.new(clock: @clock))
      out, = capture_io { gen.call }
      lines = out.lines.map(&:chomp)
      assert_equal ['Generation 1 took 4.00 s: setup 0.75 s, tournament 3.25 s, no benchmark.',
                    'Setup: emptying work/ 0.25 s, deleting old networks 0.00 s, verifying 0.50 s.',
                    'Tournament: 1 round, 4 games, none failed; workers 3.00 s, Ruby 0.25 s outside waiting for them.',
                    'Resumed: the times cover only what this session ran.',
                    'timings generation=1 partial=1 setup=0.750 setup_clear=0.250 setup_retire=0.000 setup_verify=0.500 ' \
                    'round_1=3.250 worker_round_1=3.000 ' \
                    'ruby_round_1=0.250 games_round_1=4 failures_round_1=0 tournament=3.250 worker=3.000 ' \
                    'ruby=0.250 games=4 failures=0 total=4.000'], lines.last(5)
    end
  end

  def test_a_generation_stopped_mid_round_prints_no_timings
    in_experiment do
      setup_eight('setup_complete' => true)
      gen = with_clock(build_generation(settings: { 'concurrency' => 2 }))
      gen.instance_variable_set(:@pool, FakePool.new(clock: @clock, status: signal_status('INT')))
      out, = capture_io { assert_raises(SystemExit) { gen.call } }
      refute_includes out, 'timings'
      refute_includes out, 'took'
    end
  end

  def test_a_generation_this_session_had_nothing_left_to_do_prints_no_timings
    in_experiment do
      setup_eight('setup_complete' => true, 'round' => 1, 'games' => [])
      gen = with_clock(build_generation)
      gen.instance_variable_set(:@pool, FakePool.new(clock: @clock))
      out, = capture_io { assert_equal :already_done, gen.call }
      refute_includes out, 'timings'
      refute_includes out, 'took'
    end
  end

  def test_a_new_generation_times_its_setup_and_its_benchmark
    in_experiment(generation: '0') do
      gen = with_clock(build_generation(generation: '0', settings: { 'keep_every' => 1, 'population_size' => 2,
                                                                     'concurrency' => 8 }))
      clock = @clock
      gen.define_singleton_method(:run_initial_population) do |_command|
        %w[0001.ann 0002.ann].each { |name| File.write(name, name) }
        clock.advance(2.0)
        genes = 'genes layers=1 width=10 act_hidden=sigmoid_cached act_output=sigmoid_cached copy_chance=0.01 ' \
                "weight_changes=1 weight_step=0.5 activation_rate=0.02 structure_rate=0.02 features=none feature_step=0.01\n"
        [true, genes * 2]
      end
      # The 2 networks and the 15 bots: 8 games, one chunk of 1.5 s each, and a bye.
      gen.instance_variable_set(:@pool, FakePool.new(clock: @clock))
      # Storing a game's row takes 0.25 s of Ruby time, storing a birth
      # 0.25 s of setup, within breeding, and the last round's save with
      # the champion 0.125 s, within that round.
      database.define_singleton_method(:record) do |**row|
        clock.advance(0.25)
        super(**row)
      end
      database.define_singleton_method(:record_birth) do |**birth|
        clock.advance(0.25)
        super(**birth)
      end
      database.define_singleton_method(:save_state) do |*args, **options|
        clock.advance(0.125) if options[:champion]
        super(*args, **options)
      end
      out, = with_benchmark(lambda { |*_args|
        clock.advance(5.0)
        true
      }) { capture_io { gen.call } }
      assert_includes out.lines.map(&:chomp),
                      'timings generation=0 partial=0 setup=2.500 setup_clear=0.000 setup_breed=2.500 ' \
                      'setup_hash=0.000 setup_store=0.500 setup_sync=0.000 setup_save=0.000 setup_retire=0.000 ' \
                      'round_1=14.125 worker_round_1=12.000 ruby_round_1=2.125 games_round_1=8 failures_round_1=0 ' \
                      'tournament=14.125 worker=12.000 ruby=2.125 games=8 failures=0 champion=0.125 benchmark=5.000 ' \
                      'total=21.625'
      refute_includes out, 'Resumed'
    end
  end

  def test_a_bred_generation_times_the_parts_of_its_setup
    in_experiment do
      write_networks(0, { '0001.ann' => '0001.ann', '0002.ann' => '0002.ann' }, experiment: '.')
      write_data({ 'players' => { '0001.ann' => {}, '0002.ann' => {} },
                   'ranking' => [{ 'name' => '0001.ann', 'score' => 1 }, { 'name' => '0002.ann', 'score' => 0 }] },
                 generation: 0)
      gen = slow_bookkeeping(with_clock(build_generation(settings: { 'keep_every' => 0 })))
      clock = @clock
      # Each child takes evolve 1 s and storing its birth 0.25 s; syncing
      # the networks takes 0.5 s and saving the state 0.75 s.
      gen.instance_variable_set(:@pool, evolve_pool(clock:, duration: 1.0) do |cmd|
        File.write(cmd.split[-2], cmd)
        [true, EvolveFromPreviousPopulationTest::SUMMARY]
      end)
      database.define_singleton_method(:record_birth) do |**birth|
        clock.advance(0.25)
        super(**birth)
      end
      gen.define_singleton_method(:publish_networks) do
        clock.advance(0.5)
        super()
      end
      database.define_singleton_method(:save_state) do |*args, **options|
        clock.advance(0.75)
        super(*args, **options)
      end
      capture_io { gen.send(:setup) {} }
      assert_equal 'timings generation=1 partial=0 setup=4.000 setup_clear=0.250 setup_breed=2.500 setup_hash=0.000 ' \
                   'setup_store=0.500 setup_sync=0.500 setup_save=0.750 setup_retire=0.000',
                   gen.send(:timings).line
      assert_equal 'Setup: emptying work/ 0.25 s, breeding 2.50 s (hashing 0.00 s and storing 0.50 s during it), ' \
                   'syncing 0.50 s, saving 0.75 s, deleting old networks 0.00 s.', gen.send(:timings).summary[1]
    end
  end
end

# The runner keeps a generation's state in memory while it plays it. After
# every save that state must be what the database gives a resumed run, and
# the stored ranking what a full save of it would write.
class InMemoryStateTest < Minitest::Test
  include RunGenerationHelpers

  NETWORKS = %w[a.ann b.ann c.ann d.ann e.ann f.ann].freeze
  # Draws and byes give points too, so they move players.
  SCORING = SetupExperiment::DEFAULT_SCORING.merge('win' => 3, 'draw' => 1, 'bye' => 2)
  ROUNDS = 3
  GAMES = 12

  # A fresh experiment database with round 0 of generation 1 set up: six
  # networks and Brown1, so every round has a bye. The ranking is not in
  # [-score, name] order, as setup_tournament's shuffled ties are not.
  def fresh_store
    store = ExperimentDatabase.new(':memory:')
    SetupExperiment.save_rules(store)
    store.save_scoring(SCORING)
    players = NETWORKS.to_h { |name| [name, { 'command' => "../evo #{name}" }] }
    players['Brown1'] = { 'command' => 'brown', 'external' => true }
    ranking = players.keys.reverse.map { |name| { 'name' => name, 'score' => 0 } }
    games = ranking.map { |r| r['name'] }.each_slice(2).map { |black, white| { 'black' => black, 'white' => white } }
    store.save_state(1, { 'setup_complete' => true, 'round' => 0, 'players' => players, 'ranking' => ranking,
                          'games' => games })
    store
  end

  # Every game's result depends only on its players, so a resumed run plays
  # the same games as an uninterrupted one. Some networks draw.
  ARENA = lambda do |id, game|
    black, white = game.values_at('black', 'white')
    result = if ((black.ord + white.ord) % 3).zero? then '0'
             elsif black < white then 'B+1.5'
             else 'W+1.5'
             end
    arena_played(id, result:)
  end
  # How the game of each network against Brown1 ends: wins, draws, a
  # resignation, and a time loss. Black moves first, so the one move
  # leaves white to resign and black out of time.
  BOT = { 'a' => { result: 'B+2.5' }, 'b' => { result: 'W+0.5' }, 'c' => { result: '0' }, 'd' => { result: '0' },
          'e' => { result: 'B+R', finish: 'resign', moves: %w[C3] },
          'f' => { result: 'W+T', finish: 'time', moves: %w[C3] } }.freeze
  PLAY = lambda do |id, game|
    network = [game['black'], game['white']].find { |name| name.end_with?('.ann') }
    game.value?('Brown1') ? arena_played(id, **BOT.fetch(network[0])) : ARENA.call(id, game)
  end

  def build(store)
    gen = build_generation(settings: { 'tournament_rounds' => ROUNDS, 'concurrency' => 2 }, store:)
    pool = FakePool.new(arena: PLAY)
    gen.instance_variable_set(:@pool, pool)
    gen
  end

  # Calls `check` with a label after every game and after every round's
  # pairing, once each is saved.
  def watch(gen, &check)
    gen.define_singleton_method(:refresh_progress) do
      super()
      check.call(:game)
    end
    gen.define_singleton_method(:setup_next_round) do
      super()
      check.call(:round)
    end
  end

  def play(gen)
    capture_io { gen.send(:play_games) }
  end

  # The stored games without their timings, which depend on the chunks.
  def untimed_games(store)
    store.games(1).map { |row| row.except(:duration, :time_black, :time_white) }
  end

  def final(store)
    [store.ranking(1), untimed_games(store), store.state(1)]
  end

  def test_after_every_save_the_state_in_memory_is_what_the_database_holds
    store = fresh_store
    in_experiment do
      gen = build(store)
      saves = []
      watch(gen) do |kind|
        data = gen.send(:data)
        assert_equal store.state(1), data, "after save #{saves.size + 1} (#{kind})"
        full = ExperimentDatabase.new(':memory:')
        full.save_state(1, data)
        assert_equal full.ranking(1), store.ranking(1), "after save #{saves.size + 1} (#{kind})"
        saves << kind
      end
      play(gen)
      assert_equal [*[:game] * (GAMES / ROUNDS), :round] * ROUNDS, saves
    end
    # Draws and byes moved players: not every score is a multiple of the win.
    assert(store.ranking(1).any? { |row| (row[:score] % 3).nonzero? })
    assert_operator store.games(1).map { |row| row[:end_reason] }.uniq.size, :>, 1
  end

  def test_the_state_is_loaded_once_per_generation
    store = fresh_store
    loads = 0
    store.define_singleton_method(:state) do |generation|
      loads += 1
      super(generation)
    end
    in_experiment { play(build(store)) }
    assert_equal 1, loads
  end

  # A game saves its own changes; only the round's pairing saves the whole
  # state, since its shuffled ties drive the next pairing.
  def test_only_the_rounds_pairings_save_the_whole_state
    store = fresh_store
    saves = 0
    store.define_singleton_method(:save_state) do |*args, **options|
      saves += 1
      super(*args, **options)
    end
    in_experiment { play(build(store)) }
    assert_equal ROUNDS, saves
  end

  # The first game of a round re-sorts the shuffled ties, so it rewrites the
  # ranking; later games only move the players whose score changed.
  def test_the_ranking_is_rewritten_at_most_once_a_round
    store = fresh_store
    rewrites = 0
    store.define_singleton_method(:save_ranking) do |*args|
      rewrites += 1
      super(*args)
    end
    in_experiment { play(build(store)) }
    assert_includes 1..ROUNDS, rewrites
  end

  Crash = Class.new(StandardError)

  # A crash after the game's row is written, before the rest of its save,
  # leaves neither: the game is still pending and gets replayed.
  def test_a_games_row_and_the_state_it_changes_are_saved_together
    store = fresh_store
    before = store.state(1)
    store.define_singleton_method(:record) do |**row|
      super(**row)
      raise Crash
    end
    in_experiment { assert_raises(Crash) { play(build(store)) } }
    assert_empty store.games(1)
    # Only the bye, scored before any game, is saved.
    bye = { 'black' => 'a.ann', 'white' => nil }
    assert_equal before['games'] - [bye], store.state(1)['games']
    assert_equal({ 'a.ann' => 2 }, store.ranking(1).to_h { |r| r.values_at(:name, :score) }.select { |_, s| s.positive? })
  end

  # Ctrl-C stops the runner after the game's save commits, not inside it,
  # where exiting would roll the finished game back.
  def test_ctrl_c_after_a_game_finished_keeps_it
    store = fresh_store
    store.define_singleton_method(:record) do |**row|
      super(**row)
      $stop_now = true
    end
    in_experiment { assert_raises(SystemExit) { play(build(store)) } }
    assert_equal 1, store.games(1).size
    game = store.games(1).first.values_at(:black, :white)
    pending = store.state(1)['games'].map { |g| g.values_at('black', 'white') }
    assert_equal 2, pending.size
    refute_includes pending, game
    refute_includes pending, ['a.ann', nil]
  ensure
    $stop_now = false
  end

  def test_a_crash_between_any_two_saves_resumes_to_the_same_end
    store = fresh_store
    in_experiment { play(build(store)) }
    expected = final(store)
    (1..(GAMES + ROUNDS)).each do |crash_after|
      store = fresh_store
      in_experiment do
        gen = build(store)
        saves = 0
        watch(gen) { raise Crash if (saves += 1) == crash_after }
        assert_raises(Crash) { play(gen) }
        play(build(store))
      end
      assert_equal expected, final(store), "crash after save #{crash_after}"
    end
  end

  # One game on a ranking already in [-score, name] order, then the stored
  # ranking against a full save of the new state.
  def after_one_game(ranking, game, result)
    store = fresh_store
    players = ranking.to_h { |name, _| [name, name == 'Brown1' ? { 'command' => 'brown', 'external' => true } : { 'command' => "../evo #{name}" }] }
    store.save_state(1, { 'setup_complete' => true, 'round' => 1, 'players' => players,
                          'ranking' => ranking.map { |name, score| { 'name' => name, 'score' => score } },
                          'games' => [game] })
    gen = build_generation(store:)
    capture_io { gen.send(:update_data, game, result) }
    full = ExperimentDatabase.new(':memory:')
    full.save_state(1, gen.send(:data))
    assert_equal full.ranking(1), store.ranking(1)
    assert_equal store.state(1), gen.send(:data)
    store.ranking(1).map { |r| r.values_at(:rank, :name, :score) }
  end

  SORTED = [['Brown1', 6], ['a.ann', 4], ['b.ann', 4], ['c.ann', 3], ['d.ann', 1], ['e.ann', 0], ['f.ann', 0]].freeze

  # SORTED with `name` at `score`, in order.
  def sorted_with(name, score)
    SORTED.map { |n, s| [n, n == name ? score : s] }.sort_by { |n, s| [-s, n] }
  end

  def ranks(*entries)
    entries.each_with_index.map { |(name, score), i| [i + 1, name, score] }
  end

  def test_a_win_moves_the_winner_past_everyone_it_now_outscores
    moved = after_one_game(sorted_with('f.ann', 6), { 'black' => 'f.ann', 'white' => 'e.ann' }, { 'winner' => 'f.ann' })
    assert_equal ranks(['f.ann', 9], ['Brown1', 6], ['a.ann', 4], ['b.ann', 4], ['c.ann', 3], ['d.ann', 1],
                       ['e.ann', 0]), moved
  end

  def test_a_draw_moves_both_players_and_ties_go_by_name
    moved = after_one_game(SORTED, { 'black' => 'f.ann', 'white' => 'e.ann' }, { 'winner' => nil })
    assert_equal ranks(['Brown1', 6], ['a.ann', 4], ['b.ann', 4], ['c.ann', 3], ['d.ann', 1], ['e.ann', 1],
                       ['f.ann', 1]), moved
  end

  def test_a_bye_moves_its_player
    moved = after_one_game(SORTED, { 'black' => 'c.ann', 'white' => nil }, { 'winner' => nil })
    assert_equal ranks(['Brown1', 6], ['c.ann', 5], ['a.ann', 4], ['b.ann', 4], ['d.ann', 1], ['e.ann', 0],
                       ['f.ann', 0]), moved
  end

  def test_a_player_who_scores_but_stays_last_keeps_its_place
    moved = after_one_game([['a.ann', 2], ['b.ann', 0]], { 'black' => 'b.ann', 'white' => nil }, { 'winner' => nil })
    assert_equal ranks(['a.ann', 2], ['b.ann', 2]), moved
  end

  def test_a_win_that_ties_others_puts_the_winner_among_them_by_name
    moved = after_one_game(SORTED, { 'black' => 'd.ann', 'white' => 'e.ann' }, { 'winner' => 'd.ann' })
    assert_equal ranks(['Brown1', 6], ['a.ann', 4], ['b.ann', 4], ['d.ann', 4], ['c.ann', 3], ['e.ann', 0],
                       ['f.ann', 0]), moved
    moved = after_one_game(sorted_with('a.ann', 1), { 'black' => 'a.ann', 'white' => 'e.ann' }, { 'winner' => 'a.ann' })
    assert_equal ranks(*SORTED), moved
  end
end

# A generation's networks live in networks/N/ beside work/: setup writes
# them into networks/N.partial/, syncs and renames it, saves the setup, and
# only then deletes the parents' networks/N-1/. A crash at any point
# resumes to the same networks and leaves no stale directory; a resumed
# generation checks its networks against their births before it plays.
class NetworksOnDiskTest < Minitest::Test
  include RunGenerationHelpers

  PARENTS = { '0001.ann' => 'parent 1', '0002.ann' => 'parent 2' }.freeze
  Crash = Class.new(StandardError)

  # Generation 0 finished, with its networks in networks/0/.
  def finished_generation_zero
    write_networks(0, PARENTS, experiment: '.')
    write_data({ 'round' => 1, 'setup_complete' => true, 'players' => PARENTS.keys.to_h { |name| [name, {}] },
                 'games' => [], 'ranking' => [{ 'name' => '0001.ann', 'score' => 1 }, { 'name' => '0002.ann', 'score' => 0 }] },
               generation: 0)
  end

  # Generation 1, whose evolve writes each child from its seed and parents,
  # so the same draws give the same bytes. The commands go to @evolved.
  def generation_one(settings: {})
    @evolved = []
    evolved = @evolved
    gen = build_generation(settings:)
    gen.instance_variable_set(:@pool, evolve_pool do |cmd|
      evolved << cmd
      File.write(cmd.split[-2], "child #{cmd.split[-1]} of #{cmd.split[6, 2].map { |path| File.basename(path) }.join(' ')}")
      [true, EvolveFromPreviousPopulationTest::SUMMARY]
    end)
    gen
  end

  # Runs the generation's setup; returns the directory the block ran in.
  def set_up(gen)
    seen = nil
    capture_io { gen.send(:setup) { seen = File.basename(Dir.pwd) } }
    seen
  end

  def outcome
    [files_in('networks/1'), database.births(1), database.state(1)]
  end

  def uninterrupted
    in_experiment do
      finished_generation_zero
      set_up(generation_one)
      outcome
    end
  ensure
    @database = nil
  end

  # A new session sets generation 1 up again and ends as if uninterrupted,
  # with only networks/1/ left.
  def assert_resumes_to(expected)
    assert_equal 'work', set_up(generation_one)
    assert_equal %w[1], Dir.children('networks')
    assert_equal expected, outcome
  end

  def test_a_bred_generation_moves_its_networks_into_place_and_deletes_the_parents
    in_experiment do
      finished_generation_zero
      assert_equal 'work', set_up(generation_one)
      assert_equal %w[1], Dir.children('networks')
      networks = files_in('networks/1')
      assert_equal %w[0.ann 1.ann], networks.keys
      assert_equal(networks.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) },
                   database.births(1).to_h { |birth| birth.values_at(:child, :genome) })
      assert_equal '../evo ../networks/1/0.ann', database.state(1)['players']['0.ann']['command']
      assert_empty database.network_names(0) + database.network_names(1)
      assert_empty Dir.children('work')
    end
  end

  # Every child, then networks/1.partial/, is synced before the rename, and
  # networks/ and the experiment directory after it.
  def test_the_networks_are_synced_around_the_rename
    in_experiment do
      finished_generation_zero
      gen = generation_one
      synced = []
      gen.define_singleton_method(:fsync) { |path| synced << [path, Dir.exist?('../networks/1')] }
      set_up(gen)
      assert_equal [['../networks/1.partial/0.ann', false], ['../networks/1.partial/1.ann', false],
                    ['../networks/1.partial', false], ['../networks', true], ['..', true]], synced
    end
  end

  def test_a_crash_before_the_rename_breeds_again
    expected = uninterrupted
    in_experiment do
      finished_generation_zero
      gen = generation_one
      gen.define_singleton_method(:publish_networks) { raise Crash }
      assert_raises(Crash) { set_up(gen) }
      assert_equal %w[0 1.partial], Dir.children('networks').sort
      assert_nil database.state(1)
      assert_resumes_to(expected)
      assert_equal 2, @evolved.size
    end
  end

  # The stale networks/1/ is deleted before breeding, so the rename works.
  def test_a_crash_after_the_rename_before_the_save_breeds_again
    expected = uninterrupted
    in_experiment do
      finished_generation_zero
      gen = generation_one
      gen.define_singleton_method(:save_data) { |*| raise Crash }
      assert_raises(Crash) { set_up(gen) }
      assert_equal %w[0 1], Dir.children('networks').sort
      assert_nil database.state(1)
      assert_resumes_to(expected)
      assert_equal 2, @evolved.size
    end
  end

  # The saved setup keeps networks/1/; the parents left behind go.
  def test_a_crash_after_the_save_before_deleting_the_parents_keeps_the_setup
    expected = uninterrupted
    in_experiment do
      finished_generation_zero
      gen = generation_one
      gen.define_singleton_method(:retire_networks) { |*| raise Crash }
      assert_raises(Crash) { set_up(gen) }
      assert_equal %w[0 1], Dir.children('networks').sort
      assert database.state(1)['setup_complete']
      assert_resumes_to(expected)
      assert_empty @evolved
    end
  end

  def test_directories_no_setup_needs_are_deleted_first
    in_experiment do
      finished_generation_zero
      %w[networks/3 networks/7.partial networks/1.partial networks/1.partial.old].each { |dir| FileUtils.mkdir_p(dir) }
      File.write('networks/1.partial/5.ann', 'left over')
      # Entries not named as a generation's directory are not the runner's.
      File.write('networks/keep-me', 'mine')
      set_up(generation_one)
      assert_equal %w[1 1.partial.old keep-me], Dir.children('networks').sort
      assert_equal %w[0.ann 1.ann], files_in('networks/1').keys
    end
  end

  def test_a_new_generation_zero_is_written_into_place
    in_experiment(generation: '0') do
      FileUtils.mkdir_p('networks/0.partial')
      File.write('networks/0.partial/0003.ann', 'left over')
      gen = build_generation(generation: '0')
      gen.define_singleton_method(:run_initial_population) do |_cmd|
        %w[0001.ann 0002.ann].each { |name| File.write(name, name) }
        genes = 'genes layers=1 width=10 act_hidden=sigmoid_cached act_output=sigmoid_cached copy_chance=0.01 ' \
                "weight_changes=1 weight_step=0.5 activation_rate=0.02 structure_rate=0.02 features=none feature_step=0.01\n"
        [true, genes * 2]
      end
      set_up(gen)
      assert_equal %w[0], Dir.children('networks')
      assert_equal({ '0001.ann' => '0001.ann', '0002.ann' => '0002.ann' }, files_in('networks/0'))
      assert database.state(0)['setup_complete']
    end
  end

  def test_a_resumed_generation_verifies_its_networks_and_plays_them_where_they_are
    in_experiment do
      finished_generation_zero
      set_up(generation_one)
      gen = build_generation
      @manifests = []
      manifests = @manifests
      gen.instance_variable_set(:@pool, FakePool.new(arena: lambda { |id, _game|
        manifests << File.read('arena-0.txt')
        arena_played(id)
      }))
      verified = 0
      gen.define_singleton_method(:verify_networks) do
        verified += 1
        super()
      end
      capture_io { gen.call }
      assert_equal 1, verified
      assert_equal 1, database.state(1)['round']
      assert_includes manifests.first, "network\t0.ann\t../networks/1/0.ann\n"
    end
  end

  def damaged_networks_stop_the_run
    in_experiment do
      finished_generation_zero
      set_up(generation_one)
      yield
      gen = build_generation
      pool = FakePool.new
      gen.instance_variable_set(:@pool, pool)
      error = assert_raises(RunGeneration::NetworksDamaged) { capture_io { gen.call } }
      assert_empty pool.commands
      assert_equal 0, database.state(1)['round']
      error.message
    end
  end

  def test_a_changed_or_missing_network_stops_the_run_naming_it
    message = damaged_networks_stop_the_run do
      File.write('networks/1/0.ann', 'changed')
      File.delete('networks/1/1.ann')
    end
    assert_includes message, 'networks/1/'
    assert_includes message, 'missing: 1.ann'
    assert_includes message, 'changed: 0.ann'
    assert_includes message, 'The run stopped'
  end

  def test_a_missing_networks_directory_stops_the_run
    message = damaged_networks_stop_the_run { FileUtils.rm_rf('networks/1') }
    assert_includes message, 'networks/1/ is missing'
  end

  # A one-generation run re-enters the last finished generation, which
  # plays nothing, so its networks are not needed.
  def test_a_finished_generation_is_re_entered_without_its_networks
    in_experiment do
      finished_generation_zero
      FileUtils.rm_rf('networks/0')
      gen = build_generation(generation: '0', settings: { 'keep_every' => 0 })
      gen.instance_variable_set(:@pool, FakePool.new)
      result = nil
      capture_io { result = gen.call }
      assert_equal :already_done, result
    end
  end

  # The champion (the first network of the final ranking that is not a bot)
  # is stored with the state the last round saves, and only at checkpoints.
  def champion_rows(keep_every)
    in_experiment do
      finished_generation_zero
      set_up(generation_one)
      saves = []
      database.define_singleton_method(:save_state) do |generation, state, **options|
        saves << [state['round'], options[:champion]&.first]
        super(generation, state, **options)
      end
      gen = build_generation(settings: { 'keep_every' => keep_every, 'tournament_rounds' => 2 })
      gen.instance_variable_set(:@pool, FakePool.new)
      capture_io { gen.send(:setup) { gen.send(:play_games) } }
      champion = database.ranking(1).find { |row| !row[:external] }[:name]
      rows = database.network_names(1).to_h do |name|
        [name, File.binread(database.export_network(1, name, "row-#{name}"))]
      end
      [saves, champion, rows, files_in('networks/1')]
    end
  end

  def test_a_checkpoint_stores_its_champion_with_its_last_rounds_state
    saves, champion, rows, files = champion_rows(1)
    assert_equal [[1, nil], [2, champion]], saves
    assert_equal({ champion => files.fetch(champion) }, rows)
  end

  def test_other_generations_store_no_network
    saves, _champion, rows, = champion_rows(10)
    assert_equal [[1, nil], [2, nil]], saves
    assert_empty rows
  end
end
