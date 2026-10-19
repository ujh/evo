require 'fileutils'
require_relative '../ruby/experiment_database'
require_relative '../ruby/setup_experiment'

# A small experiment with elites, written the way the runner writes it:
# 12 networks, elite_share 0.2 (E = 2), two finished generations without
# checkpoints. Generation 0 is initial-population's (0000.ann to 0011.ann).
# Generation 1 has ten bred children (0.ann to 9.ann) and, in the last two
# places, the elites 10.ann and 11.ann: the first two networks of
# generation 0's final ranking, 0009.ann and 0005.ann, tied and stored out
# of name order, a bot above them. Births sort by name, so the elites come
# between 1.ann and 2.ann. 0005.ann has no bred child, so only its elite
# makes it a parent. ExperimentStats and the stats script are tested on it.
module ElitesStatsFixture
  FEATURES = 'tactics'.freeze
  SETTINGS = { 'tournament_rounds' => 2, 'keep_every' => 0, 'benchmark_games' => 4, 'benchmark_champions' => 10,
               'seed' => 1, 'board_size' => 9, 'features' => FEATURES, 'population_size' => 12,
               'elite_share' => 0.2 }.freeze
  OPPONENTS = [{ name: 'Brown', command: 'brown', copies: 2 }, { name: 'AmiGo', command: 'amigogtp', copies: 1 }].freeze
  BENCHMARK = [{ name: 'Brown', kind: 'bot', command: 'brown' }].freeze
  BOTS = { 'Brown1' => 'Brown', 'Brown2' => 'Brown', 'AmiGo1' => 'AmiGo' }.freeze
  INITIAL = (0..11).map { |i| format('%04d.ann', i) }.freeze
  BRED = (0..11).map { |i| "#{i}.ann" }.freeze

  # Generation 0's genes per network, in index order.
  COPY_CHANCE = [0.01, 0.012, 0.008, 0.01, 0.011, 0.009, 0.01, 0.013, 0.01, 0.007, 0.01, 0.015].freeze
  WEIGHT_CHANGES = [1.0, 1.5, 2.0, 1.2, 3.0, 2.5, 1.1, 1.8, 4.0, 3.5, 1.3, 2.2].freeze
  WEIGHT_STEP = [0.5, 0.48, 0.52, 0.45, 0.55, 0.6, 0.4, 0.5, 0.47, 0.62, 0.51, 0.49].freeze
  SAVES_ATARI = [0.8, 0.81, 0.79, 0.8, 0.82, 0.78, 0.8, 0.83, 0.8, 0.77, 0.8, 0.84].freeze

  def self.initial_genes(i)
    { layers: 1, width: 10, act_hidden: i % 4 == 3 ? 'tanh' : 'sigmoid_cached',
      act_output: i % 5 == 4 ? 'relu' : 'sigmoid_cached', copy_chance: COPY_CHANCE[i],
      weight_changes: WEIGHT_CHANGES[i], weight_step: WEIGHT_STEP[i], activation_rate: 0.02, structure_rate: 0.02,
      features: FEATURES, feature_step: 0.01, fw_capture: 1.0, fw_self_atari: -1.0, fw_saves_atari: SAVES_ATARI[i] }
  end

  # Generation 1's bred children: [first, second, operator, parent,
  # differs_from_first, differs_from_second, structure, activation_changed,
  # genome, layers, width, act_hidden, act_output, weight_changes,
  # weight_step]. 2.ann is a copy; 4.ann a mutation that changed no weight;
  # 5.ann a crossover of 0007.ann with itself; 7.ann a crossover that took
  # all of its second parent's weights and its activations, so it equals the
  # elite 10.ann. So four bred children are identical to a parent. 6.ann
  # changed no weight either, but switched an activation. Selection picked
  # 0009.ann for four bred children, more than any other network; its elite
  # would make five.
  BREEDING = [
    ['0009.ann', '0002.ann', 'crossover', 'first', 30, 40, 'none', false, 'h0', 1, 10, 'sigmoid_cached', 'relu', 3.5, 0.62],
    ['0009.ann', '0003.ann', 'mutation', 'first', 12, 30, 'none', false, 'h1', 1, 10, 'sigmoid_cached', 'relu', 3.9, 0.66],
    ['0002.ann', '0007.ann', 'copy', 'first', 0, 50, 'none', false, 'g2', 1, 10, 'sigmoid_cached', 'sigmoid_cached', 2.0, 0.52],
    ['0007.ann', '0001.ann', 'mutation', 'first', nil, nil, 'widen', false, 'h3', 1, 11, 'tanh', 'sigmoid_cached', 1.6, 0.55],
    ['0002.ann', '0006.ann', 'mutation', 'first', 0, 44, 'none', false, 'h4', 1, 10, 'sigmoid_cached', 'sigmoid_cached', 2.2, 0.5],
    ['0007.ann', '0007.ann', 'crossover', 'first', 0, 0, 'none', false, 'g7', 1, 10, 'tanh', 'sigmoid_cached', 1.8, 0.5],
    ['0003.ann', '0010.ann', 'mutation', 'first', 0, 35, 'none', true, 'h6', 1, 10, 'relu', 'sigmoid_cached', 1.1, 0.44],
    ['0001.ann', '0009.ann', 'crossover', 'second', 15, 0, 'none', false, 'g9', 1, 10, 'sigmoid_cached', 'relu', 3.5, 0.62],
    ['0011.ann', '0008.ann', 'mutation', 'first', nil, nil, 'remove_layer', false, 'h8', 0, 0, 'tanh', 'sigmoid_cached', 2.4, 0.47],
    ['0004.ann', '0009.ann', 'mutation', 'second', 25, 3, 'none', false, 'h9', 1, 10, 'sigmoid_cached', 'relu', 3.2, 0.6]
  ].freeze
  ELITES = { '10.ann' => '0009.ann', '11.ann' => '0005.ann' }.freeze

  # Final rankings as stored: ties shuffled, so not in name order, and the
  # bots among the networks.
  RANKING_0 = [['Brown1', 9], ['0009.ann', 7], ['0005.ann', 7], ['AmiGo1', 7], ['0002.ann', 6], ['0007.ann', 5],
               ['0001.ann', 5], ['0003.ann', 4], ['Brown2', 4], ['0000.ann', 3], ['0004.ann', 3], ['0011.ann', 2],
               ['0006.ann', 2], ['0008.ann', 1], ['0010.ann', 0]].freeze
  RANKING_1 = [['10.ann', 8], ['AmiGo1', 7], ['4.ann', 7], ['11.ann', 6], ['0.ann', 6], ['Brown1', 5], ['2.ann', 5],
               ['7.ann', 4], ['1.ann', 4], ['9.ann', 3], ['5.ann', 3], ['Brown2', 2], ['3.ann', 2], ['6.ann', 1],
               ['8.ann', 0]].freeze

  # Writes the experiment database at `path`.
  def self.create(path)
    FileUtils.mkdir_p(File.dirname(path))
    writer = ExperimentDatabase.new(path)
    writer.save_opponents(OPPONENTS)
    writer.save_benchmark_opponents(BENCHMARK)
    writer.save_scoring(SetupExperiment::DEFAULT_SCORING)
    writer.save_settings(SETTINGS)
    populate(writer)
    writer.close
  end

  def self.players(networks)
    networks.to_h { |name| [name, {}] }.merge(BOTS.to_h { |bot, group| [bot, { 'external' => true, 'opponent' => group }] })
  end

  def self.populate(db)
    [[INITIAL, RANKING_0], [BRED, RANKING_1]].each_with_index do |(networks, ranking), generation|
      db.save_state(generation, { 'round' => 2, 'setup_complete' => true, 'players' => players(networks),
                                  'ranking' => ranking.map { |name, score| { 'name' => name, 'score' => score } } })
    end
    INITIAL.each_with_index do |child, i|
      db.record_birth(generation: 0, child:, first_parent: nil, second_parent: nil, operator: 'initial',
                      differs_from_first: nil, differs_from_second: nil, seed: 7, genome: "g#{i}", **initial_genes(i))
    end
    BREEDING.each_with_index do |row, i|
      first, second, operator, parent, one, two, structure, switched, genome, layers, width, hidden, output, changes, step = row
      genes = initial_genes(INITIAL.index(parent == 'first' ? first : second))
      db.record_birth(generation: 1, child: BRED[i], first_parent: first, second_parent: second, operator:, parent:,
                      differs_from_first: one, differs_from_second: two, seed: 100 + i, genome:, structure:,
                      activation_changed: switched,
                      **genes, layers:, width:, act_hidden: hidden, act_output: output, weight_changes: changes,
                      weight_step: step)
    end
    ELITES.each do |child, name|
      i = INITIAL.index(name)
      db.record_birth(generation: 1, child:, first_parent: name, second_parent: nil, operator: 'elite', parent: 'first',
                      differs_from_first: 0, differs_from_second: nil, seed: 200 + i, genome: "g#{i}", structure: 'none',
                      activation_changed: false, **initial_genes(i))
    end

    game = lambda do |generation, round, black, white, winner, duration|
      db.record(generation:, round:, black:, white:, black_external: BOTS.key?(black), white_external: BOTS.key?(white),
                winner:, failure: nil, length: 60, scorer: 'tromp_taylor', end_reason: 'passes', duration:)
    end
    game.call(0, 0, '0009.ann', 'Brown1', 'Brown1', 2.0)
    game.call(0, 0, '0005.ann', '0002.ann', '0005.ann', 1.5)
    game.call(0, 1, 'AmiGo1', '0009.ann', '0009.ann', 3.0)
    game.call(0, 1, '0007.ann', '0001.ann', nil, 1.0)
    game.call(1, 0, '10.ann', 'AmiGo1', '10.ann', 2.5)
    game.call(1, 0, '4.ann', '11.ann', '4.ann', 1.25)
    game.call(1, 1, 'Brown1', '0.ann', '0.ann', 2.0)
    game.call(1, 1, '2.ann', 'Brown2', 'Brown2', 1.75)
    game.call(1, 1, '7.ann', '1.ann', nil, 0.5)
  end
end
