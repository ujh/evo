require 'minitest/autorun'
require 'tmpdir'
require_relative '../ruby/experiment_database'

class ExperimentDatabaseTest < Minitest::Test
  GAME = {
    generation: 3, round: 1, black: '0.ann', white: 'Brown1', black_external: false, white_external: true,
    winner: '0.ann', failure: nil, length: 93, referee_result: 'B+R', error_message: '', stderr: '', sgf: '(;SZ[9])',
    duration: 2.25, time_black: 0.5, time_white: 1.25, scorer: 'gnugo'
  }.freeze

  BENCHMARK_GAME = {
    generation: 10, opponent: 'Brown', opening: 3, network_color: 'white', network: '2.ann', opponent_network: nil,
    winner: 'network', failure: nil, length: 57, referee_result: 'W+12.5', error_message: '', stderr: '',
    duration: 1.5, time_black: 0.25, time_white: 0.5
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

  # stats counts games without loading their SGFs and stderr.
  def test_returns_only_the_given_columns_of_games
    with_store do |store|
      store.record(**GAME)
      store.record_benchmark_game(**BENCHMARK_GAME)
      assert_equal [{ winner: '0.ann', duration: 2.25 }], store.games(3, columns: %i[winner duration])
      assert_equal [{ opponent: 'Brown', winner: 'network' }], store.benchmark_games(10, columns: %i[opponent winner])
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

  # stats and ranking open the store read-only, which runs no migrations, so
  # they must still read a database the runner has not migrated yet.
  def test_a_read_only_store_reads_games_from_before_the_timing_columns
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'experiment.sqlite3')
      db = Sequel.sqlite(path)
      Sequel::Migrator.run(db, ExperimentDatabase::MIGRATIONS, target: 4)
      old_game = GAME.except(:duration, :time_black, :time_white, :scorer)
      db[:games].insert(old_game)
      db.disconnect
      reader = ExperimentDatabase.new(path, readonly: true)
      assert_equal [old_game], reader.games(3)
      reader.close
    end
  end

  def test_records_an_arena_game_with_its_scorer
    with_store do |store|
      store.record(**GAME, scorer: 'tromp_taylor')
      assert_equal ['tromp_taylor'], store.games(3).map { |row| row[:scorer] }
    end
  end

  # Every row says who scored it, so a missing or unknown scorer fails
  # instead of writing a row nobody can interpret.
  def test_a_game_without_a_known_scorer_is_refused
    with_store do |store|
      assert_raises(ArgumentError) { store.record(**GAME.except(:scorer)) }
      assert_raises(ArgumentError) { store.record(**GAME, scorer: nil) }
      assert_raises(ArgumentError) { store.record(**GAME, scorer: 'referee') }
      assert_empty store.games(3)
    end
  end

  # Games recorded before migration 009 were all GoGui games refereed by
  # GNU Go.
  def test_migration_marks_earlier_games_as_scored_by_gnu_go
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'experiment.sqlite3')
      db = Sequel.sqlite(path)
      Sequel::Migrator.run(db, ExperimentDatabase::MIGRATIONS, target: 8)
      db[:games].insert(GAME.except(:scorer))
      db.disconnect
      store = ExperimentDatabase.new(path)
      assert_equal [GAME], store.games(3)
      store.close
    end
  end

  BIRTH = {
    generation: 2, child: '0.ann', first_parent: '../1/3.ann', second_parent: '../1/5.ann', operator: 'mutation',
    differs_from_first: 0, differs_from_second: 907, seed: 2**62 + 5, genome: 'ab' * 32,
    parent: 'second', structure: 'none', activation_changed: false, layers: 2, width: 10, act_hidden: 'tanh',
    act_output: 'sigmoid_cached', copy_chance: 0.01, weight_changes: 1.5, weight_step: 0.5,
    activation_rate: 0.02, structure_rate: 0.125, features: 'tactics,last_move', feature_step: 0.015625,
    fw_hane: nil, fw_cut: nil, fw_edge: nil, fw_capture: 1.25, fw_self_atari: -0.5, fw_saves_atari: 0.75,
    fw_near_last: 0.0625
  }.freeze

  # Migration 011: the feature set, feature_step, and a column per feature
  # weight, in lib/ann.c's ANN_FEATURES order.
  def test_births_have_a_column_per_feature_weight
    assert_equal %i[fw_hane fw_cut fw_edge fw_capture fw_self_atari fw_saves_atari fw_near_last],
                 ExperimentDatabase::BIRTH_FEATURE_WEIGHT_COLUMNS
    with_store do |store, path|
      store.close
      db = Sequel.sqlite(path)
      columns = db.schema(:births).to_h
      assert_equal :string, columns[:features][:type]
      ExperimentDatabase::BIRTH_FEATURE_WEIGHT_COLUMNS.each { |column| assert_equal :float, columns[column][:type], column }
      assert_equal :float, columns[:feature_step][:type]
      db.disconnect
    end
  end

  # A birth recorded without some feature weights keeps them NULL.
  def test_a_birth_without_feature_weights_keeps_them_nil
    with_store do |store|
      store.record_birth(**BIRTH.except(:fw_capture, :fw_self_atari, :fw_saves_atari, :fw_near_last), features: 'none')
      assert_equal [nil] * 7, store.births(2).first.values_at(*ExperimentDatabase::BIRTH_FEATURE_WEIGHT_COLUMNS)
    end
  end

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
                            operator: 'initial', differs_from_first: nil, differs_from_second: nil,
                            parent: nil, structure: nil, activation_changed: nil)
      store.record_birth(**initial)
      assert_equal [initial], store.births(0)
    end
  end

  # A child whose shape differs from a parent has no count for it.
  def test_a_birth_without_differs_counts_keeps_them_nil
    with_store do |store|
      store.record_birth(**BIRTH, differs_from_first: nil)
      assert_nil store.births(2).first[:differs_from_first]
    end
  end

  # stats reads births of a database the runner has not migrated to 010.
  def test_a_read_only_store_reads_births_from_before_the_genes_columns
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'experiment.sqlite3')
      db = Sequel.sqlite(path)
      Sequel::Migrator.run(db, ExperimentDatabase::MIGRATIONS, target: 9)
      old_birth = BIRTH.slice(:generation, :child, :first_parent, :second_parent, :operator, :differs_from_first,
                              :differs_from_second, :seed, :genome)
      db[:births].insert(old_birth)
      db.disconnect
      reader = ExperimentDatabase.new(path, readonly: true)
      assert_equal [old_birth], reader.births(2)
      reader.close
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

  def test_exports_one_network_to_a_path
    with_store do |store|
      store.record_network(2, '0.ann', 'mine'.b)
      store.record_network(3, '0.ann', 'next'.b)
      Dir.mktmpdir do |dir|
        path = File.join(dir, '2-0.ann')
        assert_equal path, store.export_network(2, '0.ann', path)
        assert_equal 'mine'.b, File.binread(path)
        assert_nil store.export_network(2, '1.ann', File.join(dir, 'missing.ann'))
        refute File.exist?(File.join(dir, 'missing.ann'))
      end
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

  def test_benchmark_opponents_round_trip_in_order
    with_store do |store|
      panel = [
        { name: 'GnuGoLevel0', kind: 'bot', command: 'gnugo --level 0 --mode gtp' },
        { name: 'Gen0Champion', kind: 'initial_champion', command: nil },
        { name: 'Brown', kind: 'bot', command: 'brown' }
      ]
      store.save_benchmark_opponents(panel)
      assert_equal panel, store.benchmark_opponents
    end
  end

  def test_records_and_returns_benchmark_games_of_one_generation
    with_store do |store|
      store.record_benchmark_game(**BENCHMARK_GAME)
      other = BENCHMARK_GAME.merge(opponent: 'AmiGo', opening: 0, network_color: 'black', winner: nil,
                                   failure: 'referee gave no score', referee_result: '?')
      store.record_benchmark_game(**other)
      store.record_benchmark_game(**BENCHMARK_GAME, generation: 20)
      assert_equal [other, BENCHMARK_GAME], store.benchmark_games(10)
      assert_empty store.benchmark_games(0)
    end
  end

  def test_a_replayed_benchmark_game_replaces_its_row
    with_store do |store|
      store.record_benchmark_game(**BENCHMARK_GAME)
      replayed = BENCHMARK_GAME.merge(winner: 'opponent', referee_result: 'B+3.5')
      store.record_benchmark_game(**replayed)
      assert_equal [replayed], store.benchmark_games(10)
    end
  end
end
