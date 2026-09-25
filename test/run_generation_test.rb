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
      '0001.ann' => { 'command' => '../evo 0001.ann', 'points' => 1 },
      '0002.ann' => { 'command' => '../evo 0002.ann', 'points' => 1 },
      'GnuGoLevel101' => { 'command' => 'gnugo --level 10 --mode gtp', 'points' => 100, 'external' => true }
    }
  end

  def score(fixture, game = NETWORK_VS_BOT)
    in_experiment do
      write_data('round' => 0, 'players' => players)
      gen = build_generation
      copy_dat(fixture, gen.send(:prefix_from, game)) if fixture
      yield gen.send(:prefix_from, game) if block_given?
      gen.send(:score_game, game)
    end
  end

  def test_black_win_earns_the_losers_points
    assert_equal({ 'winner' => '0001.ann', 'points' => 100 }, score('black_wins'))
  end

  def test_white_win_earns_the_losers_points
    assert_equal({ 'winner' => 'GnuGoLevel101', 'points' => 1 }, score('white_wins'))
  end

  def test_draw_gives_no_points_and_is_not_a_failure
    assert_equal({ 'winner' => nil }, score('draw'))
  end

  def test_missing_referee_score_gives_no_points_and_is_flagged
    assert_equal({ 'winner' => nil, 'failure' => 'no referee score: ?' }, score('no_referee_score'))
  end

  def test_crashed_network_loses_whatever_the_referee_said
    # Evo exited on its first move, yet GNU Go scored the position B+17.5.
    assert_equal({ 'winner' => 'GnuGoLevel101', 'points' => 1 }, score('black_crashed'))
  end

  def test_crashed_white_network_loses_to_black
    assert_equal({ 'winner' => '0001.ann', 'points' => 1 }, score('white_crashed', NETWORK_VS_NETWORK))
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
    assert_equal({ 'winner' => 'GnuGoLevel101', 'points' => 1 }, score('move_limit'))
  end

  def test_missing_result_file_gives_no_points_and_is_flagged
    assert_equal({ 'winner' => nil, 'failure' => 'no result file' }, score(nil))
  end

  def test_result_file_without_a_game_line_gives_no_points_and_is_flagged
    result = score(nil) { |prefix| File.write("#{prefix}.dat", "# Black: Brown\n#GAME\tRES_B\n") }
    assert_equal({ 'winner' => nil, 'failure' => 'no game in result file' }, result)
  end

  def test_bye_goes_to_black_without_reading_a_result
    assert_equal({ 'winner' => '0001.ann' }, score(nil, { 'black' => '0001.ann', 'white' => nil }))
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
        [name, name.end_with?('.ann') ? { 'points' => 1 } : { 'points' => 1, 'external' => true }]
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
                  shares({ 'a.ann' => 51, 'b.ann' => 3, 'c.ann' => 1 }, settings: { 'tournament_size' => '1' }))
    assert_shares({ 'a.ann' => 5 / 9.0, 'b.ann' => 3 / 9.0, 'c.ann' => 1 / 9.0 },
                  shares({ 'a.ann' => 51, 'b.ann' => 3, 'c.ann' => 1 }, settings: { 'tournament_size' => '2' }))
  end

  def test_tournament_size_below_one_is_rejected
    gen = build_generation(settings: { 'tournament_size' => '0' })
    candidates = gen.send(:parent_candidates, previous_data('a.ann' => 1))
    assert_raises(ArgumentError) { gen.send(:select_parent, candidates) }
  end
end

class EvolveFromPreviousPopulationTest < Minitest::Test
  include RunGenerationHelpers

  # Sets up generation 0 with the given networks, an SGF, and twogtp stderr files, then runs the breeding
  # step for generation 1 with `../evolve` replaced by the given block. The block's result is the exit
  # status `system` reports. `stale_child` is left in 0.ann, as an interrupted earlier run would.
  def breed(scores:, settings: {}, stale_child: nil, &evolve)
    in_experiment do |dir|
      File.write('0.ann', stale_child) if stale_child
      gen0 = File.join(dir, '0')
      FileUtils.mkdir_p(gen0)
      scores.each_key { |name| File.write(File.join(gen0, name), name) }
      File.write(File.join(gen0, 'game.sgf'), '')
      File.write(File.join(gen0, 'quiet.err'), '')
      File.write(File.join(gen0, 'crashed.err'), "Black program died\n")
      write_data({
                   'players' => scores.keys.to_h { |name| [name, { 'points' => 1 }] },
                   'ranking' => scores.map { |name, score| { 'name' => name, 'score' => score } }
                 }, File.join(gen0, 'data.json'))

      commands = []
      gen = build_generation(settings: settings)
      gen.define_singleton_method(:system) do |cmd, **_options|
        commands << cmd
        evolve ? evolve.call(cmd) : true
      end
      error = nil
      begin
        capture_io { gen.send(:evolve_from_previous_population) }
      rescue StandardError => e
        error = e
      end
      {
        commands: commands,
        error: error,
        children: Dir['*.ann'].sort.to_h { |f| [f, File.read(f)] },
        previous_files: Dir.children(gen0).sort,
        data: File.exist?('data.json') ? JSON.load_file('data.json') : nil
      }
    end
  end

  # Writes the child to the output path, evolve's last argument, and succeeds.
  def write_child(cmd)
    File.write(cmd.split.last, cmd)
    true
  end

  PARENTS = %r{\A\.\./evolve 0\.5 \.\./0/000[12]\.ann \.\./0/000[12]\.ann}

  def test_breeds_children_from_selected_parents_and_deletes_the_parents
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }) { |cmd| write_child(cmd) }
    assert_nil state[:error]
    assert_equal 2, state[:commands].size
    state[:commands].each_with_index { |cmd, i| assert_match(/#{PARENTS} #{i}\.ann\z/, cmd) }
    assert_equal %w[0.ann 1.ann], state[:children].keys
    assert_equal ['crashed.err', 'data.json'], state[:previous_files]
    assert state[:data]['setup_complete']
    assert_equal 0, state[:data]['round']
  end

  def test_all_zero_scores_still_breed_from_real_parents
    state = breed(scores: { '0001.ann' => 0, '0002.ann' => 0 }) { |cmd| write_child(cmd) }
    assert_nil state[:error]
    state[:commands].each { |cmd| assert_match PARENTS, cmd }
  end

  def test_evolve_failing_stops_breeding_before_the_parents_are_deleted
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }) { false }
    assert_match(/evolve failed to breed 0\.ann/, state[:error].message)
    assert_includes state[:previous_files], '0001.ann'
    assert_nil state[:data]
  end

  def test_evolve_writing_nothing_stops_breeding
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }) { true }
    assert_match(/evolve failed to breed 0\.ann/, state[:error].message)
    assert_includes state[:previous_files], '0001.ann'
  end

  def test_child_left_by_an_interrupted_run_is_not_reused
    state = breed(scores: { '0001.ann' => 1 }, settings: { 'population_size' => '1' }, stale_child: 'stale') { true }
    assert_match(/evolve failed to breed 0\.ann/, state[:error].message)
    assert_empty state[:children]
  end

  def test_skips_breeding_once_setup_is_complete
    in_experiment do
      write_data('setup_complete' => true)
      gen = build_generation
      gen.define_singleton_method(:system) { |*| flunk 'evolve should not run' }
      gen.send(:evolve_from_previous_population)
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

  def test_odd_player_out_gets_a_bye_defect
    assert_equal [{ black: 'c.ann', white: nil }], games(%w[a.ann b.ann c.ann]).drop(1)
  end

  def test_external_players_are_paired_with_each_other_defect
    assert_equal %w[Brown1 Brown2], games(%w[Brown1 Brown2 a.ann b.ann]).first.values.sort
  end

  def test_game_keys_become_strings_after_saving
    in_experiment do
      gen = build_generation
      gen.send(:save_data, 'games' => games(%w[a.ann b.ann]))
      assert_equal %w[black white], gen.send(:data)['games'].first.keys
    end
  end

  def test_tournament_includes_every_external_player_and_a_bye_for_odd_counts
    in_experiment do
      %w[0001.ann 0002.ann 0003.ann 0004.ann].each { |name| File.write(name, '') }
      tournament = build_generation.send(:setup_tournament)
      assert_equal 23, tournament['players'].size
      assert_equal 12, tournament['games'].size
      assert_equal 1, tournament['games'].count { |game| game[:white].nil? }
      assert_equal '../evo 0001.ann', tournament['players']['0001.ann']['command']
    end
  end
end

class PlayRoundTest < Minitest::Test
  include RunGenerationHelpers

  # Stands in for WorkerPool: "runs" a game by calling the block, which writes
  # its result file, and hands the games back in the order they were queued.
  class FakePool
    attr_reader :commands

    def initialize(&run)
      @run = run
      @queued = []
      @commands = []
    end

    def submit(command, identifier)
      @commands << command
      @queued << identifier
    end

    def next_finished
      identifier = @queued.shift
      @run.call(identifier)
      identifier
    end
  end

  def setup_round
    write_data('round' => 0,
               'players' => {
                 'a.ann' => { 'command' => '../evo a.ann', 'points' => 1 },
                 'b.ann' => { 'command' => '../evo b.ann', 'points' => 1 },
                 'c.ann' => { 'command' => '../evo c.ann', 'points' => 1 }
               },
               'games' => [{ 'black' => 'a.ann', 'white' => 'b.ann' }, { 'black' => 'c.ann', 'white' => nil }],
               'ranking' => %w[a.ann b.ann c.ann].map { |name| { 'name' => name, 'score' => 0 } })
  end

  def build_with(pool)
    gen = build_generation
    gen.instance_variable_set(:@pool, pool)
    gen
  end

  def test_plays_and_scores_every_game_of_the_round
    in_experiment do
      setup_round
      pool = FakePool.new { |game| copy_dat('black_wins', "#{File.basename(game['black'], '.*')}x#{File.basename(game['white'], '.*')}R0") }
      gen = build_with(pool)
      capture_io { gen.send(:play_round) }
      data = gen.send(:data)
      assert_empty data['games']
      assert_equal({ 'a.ann' => 1, 'b.ann' => 0, 'c.ann' => 1 }, data['ranking'].to_h { |r| r.values_at('name', 'score') })
      assert_equal 1, pool.commands.size
      assert_includes pool.commands.first, '-black "../evo a.ann" -white "../evo b.ann"'
    end
  end

  def test_stopping_leaves_the_finished_game_to_be_replayed
    in_experiment do
      setup_round
      pool = FakePool.new { $stop_now = true }
      gen = build_with(pool)
      capture_io { assert_raises(SystemExit) { gen.send(:play_round) } }
      data = JSON.load_file('data.json')
      assert_equal [{ 'black' => 'a.ann', 'white' => 'b.ann' }], data['games']
      assert_nil data['unscored']
    ensure
      $stop_now = false
    end
  end
end

class PlayRoundBookkeepingTest < Minitest::Test
  include RunGenerationHelpers

  def test_prepare_game_builds_the_twogtp_command_with_an_unseeded_referee_and_saves_stderr
    in_experiment do
      write_data('round' => 0, 'players' => {
                   'a.ann' => { 'command' => '../evo a.ann' },
                   'Brown1' => { 'command' => 'brown' }
                 })
      game = { 'black' => 'a.ann', 'white' => 'Brown1' }
      prepared = build_generation.send(:prepare_game, game)
      assert_equal game, prepared['identifier']
      assert_equal 'gogui-twogtp -black "../evo a.ann" -white "brown" -referee "gnugo --mode gtp" ' \
                   '-size 9 -auto -games 1 -sgffile axBrown1R0 -time 10 -force -maxmoves 200 2> axBrown1R0.err',
                   prepared['command']
    end
  end

  def test_prepare_game_awards_a_bye_one_point
    in_experiment do
      write_data('round' => 0, 'players' => {})
      assert_equal({ 'winner' => 'a.ann', 'points' => 1 },
                   build_generation.send(:prepare_game, { 'black' => 'a.ann', 'white' => nil }))
    end
  end

  def test_update_data_adds_points_removes_the_game_and_sorts_the_ranking
    in_experiment do
      game = { 'black' => 'a.ann', 'white' => 'b.ann' }
      write_data('games' => [game, { 'black' => 'c.ann', 'white' => nil }],
                 'ranking' => [{ 'name' => 'a.ann', 'score' => 0 }, { 'name' => 'b.ann', 'score' => 2 },
                               { 'name' => 'c.ann', 'score' => 1 }])
      gen = build_generation
      gen.send(:update_data, game, { 'winner' => 'a.ann', 'points' => 50 })
      data = gen.send(:data)
      assert_equal [{ 'black' => 'c.ann', 'white' => nil }], data['games']
      assert_equal [['a.ann', 50], ['b.ann', 2], ['c.ann', 1]], data['ranking'].map(&:values)
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
      assert_equal [game.merge('round' => 2, 'failure' => 'no result file')], data['unscored']
      assert_includes err, 'axbR2: no result file'
    end
  end

  def test_update_data_appends_to_earlier_failures
    in_experiment do
      game = { 'black' => 'a.ann', 'white' => 'b.ann' }
      earlier = { 'black' => 'c.ann', 'white' => 'd.ann', 'round' => 0, 'failure' => 'draw' }
      write_data('round' => 1, 'games' => [game], 'unscored' => [earlier],
                 'ranking' => [{ 'name' => 'a.ann', 'score' => 0 }, { 'name' => 'b.ann', 'score' => 0 }])
      gen = build_generation
      capture_io { gen.send(:update_data, game, { 'winner' => nil, 'failure' => 'no result file' }) }
      assert_equal [earlier, game.merge('round' => 1, 'failure' => 'no result file')], gen.send(:data)['unscored']
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
