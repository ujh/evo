require 'minitest/autorun'
require 'tmpdir'
require_relative '../ruby/experiment_database'

class ExperimentDatabaseTest < Minitest::Test
  GAME = {
    generation: 3, round: 1, black: '0.ann', white: 'Brown1', black_external: false, white_external: true,
    winner: '0.ann', failure: nil, length: 93, referee_result: 'B+R', error_message: '', stderr: '', sgf: '(;SZ[9])',
    duration: 2.25, time_black: 0.5, time_white: 1.25, scorer: 'gnugo', end_reason: 'resign'
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

  # An arena chunk's overhead is shared out once the chunk ends, among the
  # games it stored while it ran.
  def test_adds_seconds_to_the_duration_of_the_given_games
    with_store do |store|
      store.record(**GAME)
      store.record(**GAME, black: '1.ann', white: '2.ann', duration: 0.5)
      store.record(**GAME, black: '3.ann', white: '4.ann', duration: 0.75)
      store.record(**GAME, round: 2, duration: 1.0)
      store.add_duration(3, 1, [%w[0.ann Brown1], %w[3.ann 4.ann]], 0.125)
      assert_equal [2.375, 0.5, 0.875, 1.0], store.games(3).map { |row| row[:duration] }
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

  # stats opens the store read-only, which runs no migrations, so it must
  # still read a database the runner has not migrated yet.
  def test_a_read_only_store_reads_games_from_before_the_timing_columns
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'experiment.sqlite3')
      db = Sequel.sqlite(path)
      Sequel::Migrator.run(db, ExperimentDatabase::MIGRATIONS, target: 4)
      old_game = GAME.except(:duration, :time_black, :time_white, :scorer, :end_reason)
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
      db[:games].insert(GAME.except(:scorer, :end_reason))
      db.disconnect
      store = ExperimentDatabase.new(path)
      assert_equal [GAME.merge(end_reason: nil)], store.games(3)
      store.close
    end
  end

  # Migration 012: how an arena game ended, for games recorded from then on.
  def test_records_every_stored_end_reason
    with_store do |store|
      %w[passes limit resign time network_error].each_with_index do |end_reason, round|
        store.record(**GAME, round:, end_reason:)
      end
      assert_equal %w[passes limit resign time network_error], store.games(3).map { |row| row[:end_reason] }
    end
  end

  # An arena row says how the game ended, as every row says who scored it,
  # and a game that failed is never stored: its reason is refused whoever
  # scored it. A GoGui row has none.
  def test_an_arena_game_needs_the_end_of_a_game_that_counts
    with_store do |store|
      assert_raises(ArgumentError) { store.record(**GAME, scorer: 'tromp_taylor', end_reason: nil) }
      assert_raises(ArgumentError) { store.record(**GAME.except(:end_reason), scorer: 'tromp_taylor') }
      %w[timeout illegal crash launch other].each do |end_reason|
        %w[tromp_taylor gnugo].each do |scorer|
          assert_raises(ArgumentError, end_reason) { store.record(**GAME, scorer:, end_reason:) }
        end
      end
      assert_empty store.games(3)
      store.record(**GAME, end_reason: nil)
      assert_equal [nil], store.games(3).map { |row| row[:end_reason] }
    end
  end

  # Games recorded before migration 012 have no end reason.
  def test_migration_leaves_earlier_games_without_an_end_reason
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'experiment.sqlite3')
      db = Sequel.sqlite(path)
      Sequel::Migrator.run(db, ExperimentDatabase::MIGRATIONS, target: 11)
      db[:games].insert(GAME.except(:end_reason))
      db.disconnect
      store = ExperimentDatabase.new(path)
      assert_equal [GAME.merge(end_reason: nil)], store.games(3)
      store.record(**GAME, round: 2)
      assert_equal [nil, 'resign'], store.games(3).map { |row| row[:end_reason] }
      store.close
    end
  end

  def test_a_read_only_store_reads_games_from_before_the_end_reason
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'experiment.sqlite3')
      db = Sequel.sqlite(path)
      Sequel::Migrator.run(db, ExperimentDatabase::MIGRATIONS, target: 11)
      old_game = GAME.except(:end_reason)
      db[:games].insert(old_game)
      db.disconnect
      reader = ExperimentDatabase.new(path, readonly: true)
      assert_equal [old_game], reader.games(3)
      reader.close
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

  # A generation's births go in together, replacing a rebred child's row.
  def test_records_a_generations_births_together
    with_store do |store|
      store.record_birth(**BIRTH)
      store.record_births([BIRTH.merge(operator: 'crossover'), BIRTH.merge(child: '0002.ann')])
      assert_equal [BIRTH.merge(operator: 'crossover'), BIRTH.merge(child: '0002.ann')], store.births(2)
    end
  end

  # One transaction: a birth that cannot be stored leaves none of them.
  def test_records_a_generations_births_all_or_none
    with_store do |store|
      assert_raises(Sequel::Error) { store.record_births([BIRTH, BIRTH.merge(child: '0002.ann', genome: nil)]) }
      assert_empty store.births(2)
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
    'players' => { '0.ann' => { 'command' => '../evo 0.ann' },
                   'Brown1' => { 'command' => 'brown', 'external' => true, 'opponent' => 'Brown' } },
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

  # Migration 013: each copy of a bot records which opponent it is; a
  # network has none, so its state has no 'opponent' key at all.
  def test_a_bots_opponent_is_stored_and_a_network_has_none
    with_store do |store|
      store.save_state(2, STATE)
      assert_equal({ '0.ann' => nil, 'Brown1' => 'Brown' }, store.instance_variable_get(:@db)[:players].to_hash(:name, :opponent))
      refute store.state(2)['players']['0.ann'].key?('opponent')
    end
  end

  def test_saving_a_state_replaces_the_previous_one
    with_store do |store|
      store.save_state(2, STATE)
      store.save_state(2, STATE.merge('round' => 2, 'games' => [], 'ranking' => STATE['ranking'].reverse))
      assert_equal STATE.merge('round' => 2, 'games' => [], 'ranking' => STATE['ranking'].reverse), store.state(2)
    end
  end

  def test_the_standings_are_the_ranking
    with_store do |store|
      store.save_state(2, STATE)
      assert_equal [[1, 'Brown1', 1, true], [2, '0.ann', 0, false]], store.ranking(2).map { |r| r.values_at(:rank, :name, :score, :external) }
    end
  end

  # Four players in order, for the per-game saves below.
  FOUR = STATE.merge(
    'players' => STATE['players'].merge('1.ann' => { 'command' => '../evo 1.ann' }, 'Brown2' => { 'command' => 'brown', 'external' => true }),
    'ranking' => [{ 'name' => 'Brown1', 'score' => 3 }, { 'name' => '0.ann', 'score' => 2 },
                  { 'name' => '1.ann', 'score' => 1 }, { 'name' => 'Brown2', 'score' => 0 }]
  ).freeze

  def standings(store)
    store.ranking(2).map { |r| r.values_at(:rank, :name, :score, :external) }
  end

  def test_a_finished_game_leaves_the_pending_games_and_a_bye_is_the_one_without_white
    with_store do |store|
      store.save_state(2, STATE.merge('games' => STATE['games'] + [{ 'black' => '0.ann', 'white' => nil }]))
      store.remove_pending_game(2, '0.ann', nil)
      assert_equal STATE['games'], store.state(2)['games']
      store.remove_pending_game(2, '0.ann', 'Brown1')
      assert_equal [{ 'black' => '1.ann', 'white' => nil }], store.state(2)['games']
    end
  end

  def test_a_player_moving_up_shifts_the_players_it_passes_down_one
    with_store do |store|
      store.save_state(2, FOUR)
      store.raise_in_ranking(2, 'Brown2', 3, from: 4, to: 2)
      assert_equal [[1, 'Brown1', 3, true], [2, 'Brown2', 3, true], [3, '0.ann', 2, false], [4, '1.ann', 1, false]],
                   standings(store)
      store.raise_in_ranking(2, '1.ann', 4, from: 4, to: 1)
      assert_equal [[1, '1.ann', 4, false], [2, 'Brown1', 3, true], [3, 'Brown2', 3, true], [4, '0.ann', 2, false]],
                   standings(store)
      store.raise_in_ranking(2, '0.ann', 3, from: 4, to: 4)
      assert_equal [[1, '1.ann', 4, false], [2, 'Brown1', 3, true], [3, 'Brown2', 3, true], [4, '0.ann', 3, false]],
                   standings(store)
    end
  end

  def test_only_the_generations_ranking_shifts
    with_store do |store|
      store.save_state(2, FOUR)
      store.save_state(3, FOUR)
      store.raise_in_ranking(2, 'Brown2', 4, from: 4, to: 1)
      assert_equal [1, 2, 3, 4], store.ranking(3).map { |r| r[:rank] }
      assert_equal %w[Brown1 0.ann 1.ann Brown2], store.ranking(3).map { |r| r[:name] }
    end
  end

  # Points are never negative, so a player never moves down.
  def test_a_player_cannot_move_down
    with_store do |store|
      store.save_state(2, FOUR)
      assert_raises(ArgumentError) { store.raise_in_ranking(2, 'Brown1', 0, from: 1, to: 4) }
      assert_equal [[1, 'Brown1', 3, true], [2, '0.ann', 2, false], [3, '1.ann', 1, false], [4, 'Brown2', 0, true]],
                   standings(store)
    end
  end

  def test_saving_the_ranking_replaces_it_as_saving_the_state_would
    with_store do |store|
      store.save_state(2, FOUR)
      ranking = FOUR['ranking'].reverse
      store.save_ranking(2, ranking, FOUR['players'])
      rewritten = store.ranking(2)
      store.save_state(2, FOUR.merge('ranking' => ranking))
      assert_equal store.ranking(2), rewritten
      assert_equal [[1, 'Brown2', 0, true], [2, '1.ann', 1, false], [3, '0.ann', 2, false], [4, 'Brown1', 3, true]],
                   standings(store)
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

  def test_stores_networks_by_generation_and_name
    with_store do |store|
      store.record_network(2, '0.ann', "\x00\x01weights".b)
      store.record_network(2, '1.ann', 'other'.b)
      store.record_network(3, '0.ann', 'next'.b)
      assert_equal %w[0.ann 1.ann], store.network_names(2)
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
      Dir.mktmpdir { |dir| assert_equal 'new', File.binread(store.export_network(2, '0.ann', File.join(dir, 'n'))) }
    end
  end

  # A checkpoint's champion is stored with the state that ends its
  # tournament, so a finished checkpoint always has it.
  def test_saving_a_state_can_store_the_champion_in_the_same_transaction
    with_store do |store|
      store.save_state(2, STATE, champion: ['0.ann', "\x00champion".b])
      Dir.mktmpdir do |dir|
        assert_equal "\x00champion".b, File.binread(store.export_network(2, '0.ann', File.join(dir, 'c')))
      end
      assert_equal %w[0.ann], store.network_names(2)
    end
  end

  def test_a_failed_save_stores_no_champion
    with_store do |store|
      assert_raises(StandardError) { store.save_state(2, STATE.merge('ranking' => nil), champion: ['0.ann', 'c'.b]) }
      assert_empty store.network_names(2)
      assert_nil store.state(2)
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
