require 'minitest/autorun'
require 'tmpdir'
require_relative '../ruby/result_store'

class ResultStoreTest < Minitest::Test
  GAME = {
    generation: 3, round: 1, black: '0.ann', white: 'Brown1', black_external: false, white_external: true,
    winner: '0.ann', failure: nil, length: 93, referee_result: 'B+R', error_message: '', stderr: '', sgf: '(;SZ[9])'
  }.freeze

  def with_store
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'results.sqlite3')
      store = ResultStore.new(path)
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
      reader = ResultStore.new(path, readonly: true)
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

  def test_records_the_final_ranking_of_a_generation_once
    with_store do |store|
      ranking = [{ rank: 1, name: '3.ann', score: 2, external: false }, { rank: 2, name: 'Brown1', score: 1, external: true }]
      store.record_ranking(4, ranking.reverse)
      store.record_ranking(4, ranking)
      assert_equal ranking.map { |r| r.merge(generation: 4) }, store.ranking(4)
    end
  end

  def test_a_read_only_store_does_not_create_a_database
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'missing.sqlite3')
      assert_raises(Sequel::DatabaseConnectionError) { ResultStore.new(path, readonly: true) }
      refute File.exist?(path)
    end
  end
end
