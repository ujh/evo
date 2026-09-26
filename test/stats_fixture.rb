require 'fileutils'
require_relative '../ruby/experiment_database'
require_relative '../ruby/setup_experiment'

# A small experiment written the way the runner writes it: generations 0 to
# 3 with two rounds each and a checkpoint every second generation.
# Generation 0 is a checkpoint whose benchmark has not been played,
# generation 1 is no checkpoint, generation 2 is a checkpoint whose
# benchmark is half played (of 4 games per opponent, AmiGo has all, Brown
# and Gen0Champion 2, GnuGoLevel0 none), and generation 3 is still in its
# first round. Generation 1 has children of two shapes and several
# activations. The networks see the shapes and tactics groups, so they have
# no near_last weight. ExperimentStats and the stats script are tested on
# it.
module StatsFixture
  PLAYERS = { 'a.ann' => {}, 'b.ann' => {}, 'c.ann' => {}, 'Brown1' => { 'external' => true } }.freeze
  # Generation 0's genes and activations: the initial values (c.ann's
  # output activation differs, so that generation 1's c.ann, which copied
  # it, is identical).
  FEATURES = 'shapes,tactics'.freeze
  GENES = { act_hidden: 'sigmoid_cached', act_output: 'sigmoid_cached', copy_chance: 0.01, weight_changes: 1.0,
            weight_step: 0.5, activation_rate: 0.02, structure_rate: 0.02, features: FEATURES, feature_step: 0.01,
            fw_hane: 0.05, fw_cut: 0.05, fw_edge: 0.05, fw_capture: 1.0, fw_self_atari: -1.0, fw_saves_atari: 0.8 }.freeze
  GENERATION_1_GENES = {
    'a.ann' => GENES,
    'b.ann' => GENES.merge(act_hidden: 'tanh', copy_chance: 0.02, weight_changes: 2.5, weight_step: 0.4, structure_rate: 0.03,
                           feature_step: 0.012, fw_capture: 0.99, fw_hane: 0.06),
    'c.ann' => GENES.merge(act_output: 'relu', copy_chance: 0.005, weight_changes: 4.0, weight_step: 0.6, structure_rate: 0.01,
                           feature_step: 0.008, fw_capture: 1.02, fw_self_atari: -0.97)
  }.freeze
  SETTINGS = { 'tournament_rounds' => 2, 'keep_every' => 2, 'benchmark_games' => 4, 'seed' => 1, 'board_size' => 9,
               'features' => FEATURES }.freeze

  # Writes the experiment database at `path`.
  def self.create(path)
    FileUtils.mkdir_p(File.dirname(path))
    writer = ExperimentDatabase.new(path)
    SetupExperiment.save_rules(writer)
    writer.save_settings(SETTINGS)
    populate(writer)
    writer.close
  end

  def self.populate(db)
    ranking = ->(*scores) { %w[Brown1 c.ann a.ann b.ann].zip(scores).map { |name, score| { 'name' => name, 'score' => score } } }
    db.save_state(0, { 'round' => 2, 'setup_complete' => true, 'players' => PLAYERS, 'ranking' => ranking.call(5, 3, 1, 2) })
    db.save_state(1, { 'round' => 2, 'setup_complete' => true, 'players' => PLAYERS, 'ranking' => ranking.call(0, 4, 4, 1) })
    db.save_state(2, { 'round' => 2, 'setup_complete' => true, 'players' => PLAYERS, 'ranking' => ranking.call(9, 7, 2, 0) })
    db.save_state(3, { 'round' => 1, 'setup_complete' => true, 'players' => PLAYERS, 'ranking' => ranking.call(1, 0, 0, 0),
                       'games' => [{ 'black' => 'a.ann', 'white' => 'b.ann' }] })

    %w[a.ann b.ann c.ann].each_with_index do |child, i|
      db.record_birth(generation: 0, child:, first_parent: nil, second_parent: nil, operator: 'initial',
                      differs_from_first: nil, differs_from_second: nil, seed: i, genome: "g#{i}", layers: 1, width: 10,
                      **GENES, **(child == 'c.ann' ? { act_output: 'relu' } : {}))
    end
    # Generation 1: a crossover, a mutation that widened its parent, so it
    # has no differs counts, and a crossover that copied its second parent,
    # so it has the same genome as that parent.
    # Their genes and activations are in GENERATION_1_GENES.
    [['a.ann', 'c.ann', 'a.ann', 'crossover', 5, 7, 'h0', 'none', 10],
     ['b.ann', 'c.ann', 'c.ann', 'mutation', nil, nil, 'h1', 'widen', 11],
     ['c.ann', 'b.ann', 'c.ann', 'crossover', 4, 0, 'g2', 'none', 10]].each do |child, first, second, operator, one, two, genome, structure, width|
      db.record_birth(generation: 1, child:, first_parent: first, second_parent: second, operator:, parent: 'first',
                      differs_from_first: one, differs_from_second: two, seed: 9, genome:, structure:, layers: 1, width:,
                      **GENERATION_1_GENES.fetch(child))
    end

    game = lambda do |generation, round, black, white, **rest|
      db.record(generation:, round:, black:, white:, black_external: black == 'Brown1', white_external: white == 'Brown1',
                winner: nil, failure: nil, length: 50, scorer: 'gnugo', **rest)
    end
    game.call(1, 0, 'a.ann', 'Brown1', winner: 'a.ann', duration: 1.5)
    game.call(1, 0, 'b.ann', 'c.ann') # draw
    game.call(1, 1, 'c.ann', 'Brown1', failure: 'Brown1 crashed', duration: 2.25)
    game.call(1, 1, 'b.ann', 'a.ann', winner: 'b.ann')
    # Recorded before games had timings.
    game.call(0, 0, 'a.ann', 'b.ann', winner: 'b.ann')

    bench = lambda do |opponent, opening, network_color, winner, failure = nil, opponent_network = nil|
      db.record_benchmark_game(generation: 2, opponent:, opening:, network_color:, network: 'c.ann',
                               opponent_network:, winner:, failure:, length: 30, duration: 1.0)
    end
    bench.call('AmiGo', 0, 'black', 'network')
    bench.call('AmiGo', 0, 'white', 'opponent')
    bench.call('AmiGo', 1, 'black', 'network')
    bench.call('AmiGo', 1, 'white', nil) # draw
    bench.call('Brown', 0, 'black', nil, 'Brown crashed')
    bench.call('Brown', 0, 'white', 'network')
    bench.call('Gen0Champion', 0, 'black', 'opponent', nil, '0:c.ann')
    bench.call('Gen0Champion', 0, 'white', 'opponent', nil, '0:c.ann')
  end
end
