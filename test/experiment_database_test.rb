require 'minitest/autorun'
require 'tmpdir'
require_relative '../ruby/experiment_database'

class ExperimentDatabaseTest < Minitest::Test
  GAME = {
    generation: 3, round: 1, black: '0.ann', white: 'Brown1', black_external: false, white_external: true,
    winner: '0.ann', failure: nil, length: 93, referee_result: 'B+R', error_message: '', stderr: '', sgf: '(;SZ[9])'
  }.freeze

  def with_store
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'experiment.sqlite3')
      store = ExperimentDatabase.new(path)
      yield store, path
    ensure
      store&.close
    end
  end

  def test_records_and_returns_a_game
    with_store do |store|
      store.record(**GAME)
      assert_equal [GAME], store.games(3)
      assert_empty store.games(2)
    end
  end

  def test_a_replayed_game_replaces_its_row
    # Resuming replays a game whose row was written just before a crash.
    with_store do |store|
      store.record(**GAME)
      store.record(**GAME, winner: 'Brown1', referee_result: 'W+3.5')
      assert_equal [GAME.merge(winner: 'Brown1', referee_result: 'W+3.5')], store.games(3)
    end
  end

  def test_a_read_only_store_sees_rows_while_the_writer_is_open
    with_store do |store, path|
      store.record(**GAME)
      reader = ExperimentDatabase.new(path, readonly: true)
      assert_equal [GAME], reader.games(3)
      reader.close
    end
  end

  BIRTH = {
    generation: 2, child: '0.ann', first_parent: '../1/3.ann', second_parent: '../1/5.ann', operator: 'mutation',
    differs_from_first: 0, differs_from_second: 907, seed: 2**62 + 5, genome: 'ab' * 32
  }.freeze

  def test_records_births_and_replaces_a_rebred_child
    with_store do |store|
      store.record_birth(**BIRTH)
      store.record_birth(**BIRTH, operator: 'crossover')
      assert_equal [BIRTH.merge(operator: 'crossover')], store.births(2)
    end
  end

  def test_initial_networks_are_births_without_parents
    with_store do |store|
      initial = BIRTH.merge(generation: 0, child: '0001.ann', first_parent: nil, second_parent: nil,
                            operator: 'initial', differs_from_first: nil, differs_from_second: nil)
      store.record_birth(**initial)
      assert_equal [initial], store.births(0)
    end
  end

  STATE = {
    'round' => 1, 'setup_complete' => true,
    'players' => { '0.ann' => { 'command' => '../evo 0.ann' }, 'Brown1' => { 'command' => 'brown', 'external' => true } },
    'ranking' => [{ 'name' => 'Brown1', 'score' => 1 }, { 'name' => '0.ann', 'score' => 0 }],
    'games' => [{ 'black' => '0.ann', 'white' => 'Brown1' }, { 'black' => '1.ann', 'white' => nil }]
  }.freeze

  def test_saves_and_loads_a_generations_state
    with_store do |store|
      store.save_state(2, STATE)
      assert_equal STATE, store.state(2)
      assert_nil store.state(3)
    end
  end

  def test_saving_a_state_replaces_the_previous_one
    with_store do |store|
      store.save_state(2, STATE)
      store.save_state(2, STATE.merge('round' => 2, 'games' => [], 'ranking' => STATE['ranking'].reverse))
      assert_equal STATE.merge('round' => 2, 'games' => [], 'ranking' => STATE['ranking'].reverse), store.state(2)
    end
  end

  def test_the_state_accepts_symbol_keys_for_games
    with_store do |store|
      store.save_state(2, STATE.merge('games' => [{ black: '0.ann', white: nil }]))
      assert_equal [{ 'black' => '0.ann', 'white' => nil }], store.state(2)['games']
    end
  end

  def test_the_standings_are_the_ranking
    with_store do |store|
      store.save_state(2, STATE)
      assert_equal [[1, 'Brown1', 1, true], [2, '0.ann', 0, false]], store.ranking(2).map { |r| r.values_at(:rank, :name, :score, :external) }
    end
  end

  def test_lists_generations_in_order
    with_store do |store|
      [3, 0, 1].each { |g| store.save_state(g, STATE) }
      assert_equal [0, 1, 3], store.generations
    end
  end

  def test_settings_round_trip_as_strings
    with_store do |store|
      assert_empty store.settings
      store.save_settings('board_size' => '9', 'seed' => '7')
      assert_equal({ 'board_size' => '9', 'seed' => '7' }, store.settings)
    end
  end

  def test_stores_and_exports_networks
    with_store do |store|
      store.record_network(2, '0.ann', "\x00\x01weights".b)
      store.record_network(2, '1.ann', 'other'.b)
      store.record_network(3, '0.ann', 'next'.b)
      Dir.mktmpdir do |dir|
        assert_equal %w[0.ann 1.ann], store.export_networks(2, dir)
        assert_equal "\x00\x01weights".b, File.binread(File.join(dir, '0.ann'))
        assert_equal 'other'.b, File.binread(File.join(dir, '1.ann'))
      end
      assert_equal %w[0.ann], store.network_names(3)
    end
  end

  def test_recording_a_network_again_replaces_it
    with_store do |store|
      store.record_network(2, '0.ann', 'old'.b)
      store.record_network(2, '0.ann', 'new'.b)
      Dir.mktmpdir { |dir| store.export_networks(2, dir) && assert_equal('new', File.binread(File.join(dir, '0.ann'))) }
    end
  end

  def test_saving_a_state_can_retire_another_generations_networks_in_the_same_transaction
    with_store do |store|
      store.record_network(1, '0.ann', 'parent'.b)
      store.record_network(2, '0.ann', 'child'.b)
      store.save_state(2, STATE, retire_networks_of: 1)
      assert_empty store.network_names(1)
      assert_equal %w[0.ann], store.network_names(2)
    end
  end

  def test_a_failed_save_keeps_the_networks
    with_store do |store|
      store.record_network(1, '0.ann', 'parent'.b)
      assert_raises(StandardError) { store.save_state(2, STATE.merge('ranking' => nil), retire_networks_of: 1) }
      assert_equal %w[0.ann], store.network_names(1)
    end
  end

  def test_a_read_only_store_does_not_create_a_database
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'missing.sqlite3')
      assert_raises(Sequel::DatabaseConnectionError) { ExperimentDatabase.new(path, readonly: true) }
      refute File.exist?(path)
    end
  end
end
