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

class ParentPoolTest < Minitest::Test
  include RunGenerationHelpers

  def previous_data(scores)
    {
      'players' => scores.keys.to_h do |name|
        [name, name.end_with?('.ann') ? { 'points' => 1 } : { 'points' => 1, 'external' => true }]
      end,
      'ranking' => scores.map { |name, score| { 'name' => name, 'score' => score } }
    }
  end

  def test_each_network_appears_score_cubed_times_and_external_players_are_excluded
    pool = build_generation.send(:parent_pool, previous_data('a.ann' => 3, 'Brown1' => 5, 'b.ann' => 2, 'c.ann' => 0))
    assert_equal({ 'a.ann' => 27, 'b.ann' => 8 }, pool.tally)
  end

  def test_pool_size_grows_with_the_cube_of_the_score_defect
    pool = build_generation.send(:parent_pool, previous_data('a.ann' => 20))
    assert_equal 8000, pool.size
  end

  def test_all_zero_scores_give_an_empty_pool_defect
    pool = build_generation.send(:parent_pool, previous_data('a.ann' => 0, 'b.ann' => 0))
    assert_empty pool
    assert_nil pool.sample
  end
end

class EvolveFromPreviousPopulationTest < Minitest::Test
  include RunGenerationHelpers

  # Sets up generation 0 with the given networks, an SGF, and twogtp stderr files, then runs the breeding
  # step for generation 1 with `../evolve` replaced by the given block.
  def breed(scores:, settings: {}, stale_child: nil, &evolve)
    in_experiment do |dir|
      File.write('child.ann', stale_child) if stale_child
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
      gen.define_singleton_method(:`) do |cmd|
        commands << cmd
        evolve&.call(cmd)
        ''
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

  def write_child(cmd)
    File.write('child.ann', cmd)
  end

  def test_breeds_children_from_the_pool_and_deletes_the_parents
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }) { |cmd| write_child(cmd) }
    assert_nil state[:error]
    assert_equal ['../evolve 0.5 ../0/0001.ann ../0/0001.ann'] * 2, state[:commands]
    assert_equal %w[0.ann 1.ann], state[:children].keys
    assert_equal ['crashed.err', 'data.json'], state[:previous_files]
    assert state[:data]['setup_complete']
    assert_equal 0, state[:data]['round']
  end

  def test_all_zero_scores_call_evolve_without_parent_files_defect
    state = breed(scores: { '0001.ann' => 0, '0002.ann' => 0 }) { |cmd| write_child(cmd) }
    assert_equal ['../evolve 0.5 ../0/ ../0/'] * 2, state[:commands]
  end

  def test_stale_child_is_reused_when_evolve_writes_nothing_defect
    # evolve fails and writes nothing, but an interrupted earlier run left a child.ann behind.
    state = breed(scores: { '0001.ann' => 1 }, settings: { 'population_size' => '1' }, stale_child: 'stale') {}
    assert_nil state[:error]
    assert_equal({ '0.ann' => 'stale' }, state[:children])
  end

  def test_evolve_failure_stops_breeding_before_the_parents_are_deleted_defect
    state = breed(scores: { '0001.ann' => 1, '0002.ann' => 0 }) {}
    assert_kind_of Errno::ENOENT, state[:error]
    assert_includes state[:previous_files], '0001.ann'
    assert_nil state[:data]
  end

  def test_skips_breeding_once_setup_is_complete
    in_experiment do
      write_data('setup_complete' => true)
      gen = build_generation
      gen.define_singleton_method(:`) { |_cmd| flunk 'evolve should not run' }
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
