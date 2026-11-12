require 'digest'
require 'fileutils'
require 'tmpdir'
require_relative '../ruby/experiment_database'

# Three small runs for scripts/gene-trajectories.rb, their births written
# the way the runner writes them (generation 0's networks 0001.ann on,
# later ones 0.ann on, an elite in the last place; both drawn parents
# stored on every mutation and copy, `parent` naming the one used), rows
# inserted out of order.
#
# - elite: 6 networks, elite_share 0.2 (one elite, 5.ann, from generation
#   1), meta_rate 0.2. Generations 0–5 finished; 6 stopped in round 1 of 2
#   and has births of every kind, all to be left out. Its bred children
#   take every branch: copies with `parent` 'first' and 'second',
#   self-crossovers, crossovers equal to the picked parent and to the
#   other one, structural mutations (differs NULL against the picked
#   parent), mutations with differs 0 against the picked parent, one of
#   them switching an activation, and one with differs 0 against the
#   parent not picked. Genes near every clamp, on both sides of 1 %.
# - meta0: at schema 17 (no elite_share), 4 networks, meta_rate 0, no
#   elites, generations 0–3: the fixed genes are generation 0's 0.01 and
#   0.02 exactly, bred births' 0.010000000000000002 and
#   0.020000000000000004 (evolve's genes line), and a copy or crossover of a
#   generation-0 network keeps the exact value. Its feature set lacks
#   near_last (fw_near_last NULL).
# - nocopy: 4 networks, one elite, initial_copy_chance 0 (every copy_chance
#   exactly 0), generations 0–2.
module GeneTrajectoriesFixture
  FEATURE_WEIGHTS = ExperimentDatabase::BIRTH_FEATURE_WEIGHT_COLUMNS
  GENES = %i[copy_chance weight_changes weight_step activation_rate structure_rate feature_step].freeze
  INEXACT = { copy_chance: 0.010000000000000002, activation_rate: 0.020000000000000004,
              structure_rate: 0.020000000000000004 }.freeze

  RUNS = {
    'elite' => {
      schema: nil, population: 6, finished: 5, unfinished: 6,
      settings: { 'elite_share' => '0.2', 'meta_rate' => '0.2', 'initial_copy_chance' => '0.01' },
      genes: { copy_chance: 0.01, weight_changes: 100.0, weight_step: 0.5, activation_rate: 0.02,
               structure_rate: 0.02, feature_step: 0.01 },
      fw: 0.5,
      births: {
        0 => [{ genes: { weight_step: 0.5 } }, { genes: { weight_step: 0.4 } }, { genes: { weight_step: 0.3 } },
              { genes: { weight_step: 0.2 } }, { genes: { weight_step: 0.1 } },
              { genes: { weight_step: 0.6, copy_chance: 0.0999 } }],
        1 => [
          { op: 'copy', first: '0003.ann', second: '0005.ann', parent: 'second', dff: 31, dfs: 0 },
          { op: 'crossover', first: '0004.ann', second: '0004.ann', parent: 'first', dff: 0, dfs: 0, same: '0004.ann' },
          { op: 'mutation', first: '0001.ann', second: '0002.ann', parent: 'first', dff: nil, dfs: nil,
            structure: 'add_layer', layers: 11, genes: { weight_step: 0.25, weight_changes: 1.0 } },
          { op: 'mutation', first: '0006.ann', second: '0001.ann', parent: 'first', dff: 12, dfs: 30,
            genes: { weight_step: 0.15, weight_changes: 1.005 } },
          { op: 'crossover', first: '0002.ann', second: '0003.ann', parent: 'second', dff: 40, dfs: 25,
            genes_of: '0003.ann' },
          { op: 'elite', first: '0002.ann' }
        ],
        2 => [
          { op: 'crossover', first: '3.ann', second: '4.ann', parent: 'second', dff: 9, dfs: 0, same: '4.ann' },
          { op: 'crossover', first: '4.ann', second: '3.ann', parent: 'first', dff: 6, dfs: 0, same: '3.ann' },
          { op: 'mutation', first: '5.ann', second: '1.ann', parent: 'second', dff: 50, dfs: 0,
            genes: { weight_step: 0.0001, copy_chance: 0.0001 }, fw: { fw_cut: 0.504, fw_edge: 0.493 } },
          { op: 'mutation', first: '4.ann', second: '0.ann', parent: 'second', dff: 0, dfs: 8,
            genes: { weight_step: 0.0001009, weight_changes: 1.02 } },
          { op: 'mutation', first: '2.ann', second: '0.ann', parent: 'first', dff: 0, dfs: nil, act: true,
            layers: 11, genes: { weight_step: 9.95, activation_rate: 0.496 } },
          { op: 'elite', first: '0.ann' }
        ],
        3 => [
          { op: 'mutation', first: '0.ann', second: '4.ann', parent: 'first', dff: 0, dfs: nil,
            genes: { weight_step: 0.000102, feature_step: 1.0 }, fw: { fw_hane: 0.5002 } },
          { op: 'crossover', first: '1.ann', second: '0.ann', parent: 'first', dff: 0, dfs: 4, same: '1.ann' },
          { op: 'mutation', first: '3.ann', second: '3.ann', parent: 'first', dff: nil, dfs: nil, structure: 'widen',
            width: 201, genes: { weight_step: 9.8, structure_rate: 0.0001 }, fw: { fw_hane: 0.9 } },
          { op: 'copy', first: '2.ann', second: '5.ann', parent: 'first', dff: 0, dfs: 21 },
          { op: 'mutation', first: '4.ann', second: '0.ann', parent: 'first', dff: nil, dfs: 77,
            structure: 'remove_layer', genes: { weight_step: 2.0 } },
          { op: 'elite', first: '3.ann' }
        ],
        4 => [
          { op: 'crossover', first: '1.ann', second: '1.ann', parent: 'second', dff: 0, dfs: 0, same: '1.ann' },
          { op: 'crossover', first: '0.ann', second: '0.ann', parent: 'first', dff: 0, dfs: 0, same: '0.ann' },
          { op: 'mutation', first: '3.ann', second: '4.ann', parent: 'second', dff: 5, dfs: 3,
            genes: { weight_step: 0.05 } },
          { op: 'mutation', first: '2.ann', second: '1.ann', parent: 'second', dff: nil, dfs: 0,
            genes: { weight_step: 0.06 }, fw: { fw_hane: 0.503 } },
          { op: 'crossover', first: '0.ann', second: '1.ann', parent: 'first', dff: 2, dfs: 2, genes_of: '0.ann' },
          { op: 'elite', first: '5.ann' }
        ],
        5 => [
          { op: 'copy', first: '4.ann', second: '2.ann', parent: 'first', dff: 0, dfs: 6 },
          { op: 'crossover', first: '2.ann', second: '3.ann', parent: 'second', dff: 0, dfs: 6, same: '2.ann' },
          { op: 'mutation', first: '0.ann', second: '1.ann', parent: 'first', dff: 3, dfs: 9,
            genes: { weight_step: 3.0 } },
          { op: 'mutation', first: '1.ann', second: '0.ann', parent: 'first', dff: 0, dfs: 4,
            genes: { weight_step: 0.07 }, fw: { fw_saves_atari: 0.55 } },
          { op: 'mutation', first: '3.ann', second: '4.ann', parent: 'second', dff: 7, dfs: 7,
            genes: { weight_step: 0.08 } },
          { op: 'elite', first: '0.ann' }
        ],
        6 => [
          { op: 'copy', first: '0.ann', second: '1.ann', parent: 'first', dff: 0, dfs: 5 },
          { op: 'crossover', first: '2.ann', second: '2.ann', parent: 'first', dff: 0, dfs: 0, same: '2.ann' },
          { op: 'mutation', first: '3.ann', second: '4.ann', parent: 'first', dff: 0, dfs: 3,
            genes: { weight_step: 7.0 }, fw: { fw_cut: 0.9 } },
          { op: 'mutation', first: '4.ann', second: '3.ann', parent: 'first', dff: nil, dfs: nil, structure: 'widen',
            width: 201, genes: { weight_step: 7.0, copy_chance: 0.0001 } },
          { op: 'mutation', first: '1.ann', second: '0.ann', parent: 'second', dff: 4, dfs: 4,
            layers: 12, genes: { weight_step: 7.0 } },
          { op: 'elite', first: '5.ann' }
        ]
      }
    },
    'meta0' => {
      schema: 17, population: 4, finished: 3, unfinished: nil,
      settings: { 'meta_rate' => '0', 'initial_copy_chance' => '0.01' },
      genes: { copy_chance: 0.01, weight_changes: 229.3128, weight_step: 0.5, activation_rate: 0.02,
               structure_rate: 0.02, feature_step: 0.01 },
      bred_genes: INEXACT,
      fw: 0.3, missing_fw: %i[fw_near_last],
      births: {
        0 => [{ fw: { fw_hane: 0.8 } }, {}, {}, {}],
        1 => [
          { op: 'mutation', first: '0001.ann', second: '0002.ann', parent: 'first', dff: 30, dfs: 40 },
          { op: 'copy', first: '0003.ann', second: '0004.ann', parent: 'second', dff: 17, dfs: 0 },
          { op: 'crossover', first: '0002.ann', second: '0001.ann', parent: 'first', dff: 0, dfs: 12, same: '0002.ann' },
          { op: 'mutation', first: '0001.ann', second: '0003.ann', parent: 'second', dff: 9, dfs: 0,
            fw: { fw_near_last: nil, fw_capture: 0.31 } }
        ],
        2 => [
          { op: 'crossover', first: '1.ann', second: '1.ann', parent: 'second', dff: 0, dfs: 0, same: '1.ann' },
          { op: 'mutation', first: '0.ann', second: '2.ann', parent: 'first', dff: nil, dfs: nil,
            structure: 'add_layer', layers: 11 },
          { op: 'mutation', first: '3.ann', second: '0.ann', parent: 'second', dff: 4, dfs: 6 },
          { op: 'crossover', first: '0.ann', second: '3.ann', parent: 'second', dff: 5, dfs: 5, genes_of: '3.ann' }
        ],
        3 => [
          { op: 'mutation', first: '2.ann', second: '1.ann', parent: 'first', dff: 0, dfs: nil,
            fw: { fw_capture: 0.28 } },
          { op: 'crossover', first: '3.ann', second: '2.ann', parent: 'first', dff: 7, dfs: 0, same: '2.ann' },
          { op: 'copy', first: '0.ann', second: '3.ann', parent: 'first', dff: 0, dfs: 8 },
          { op: 'mutation', first: '1.ann', second: '0.ann', parent: 'first', dff: 3, dfs: nil, layers: 11 }
        ]
      }
    },
    'nocopy' => {
      schema: nil, population: 4, finished: 2, unfinished: nil,
      settings: { 'elite_share' => '0.25', 'meta_rate' => '0.2', 'initial_copy_chance' => '0' },
      genes: { copy_chance: 0.0, weight_changes: 229.3128, weight_step: 0.5, activation_rate: 0.02,
               structure_rate: 0.02, feature_step: 0.01 },
      fw: 0.2,
      births: {
        0 => [{ genes: { weight_step: 0.5 } }, { genes: { weight_step: 0.4 } }, { genes: { weight_step: 0.3 } },
              { genes: { weight_step: 0.2 } }],
        1 => [
          { op: 'mutation', first: '0001.ann', second: '0002.ann', parent: 'first', dff: 10, dfs: 20,
            genes: { weight_step: 0.45 } },
          { op: 'crossover', first: '0002.ann', second: '0003.ann', parent: 'second', dff: 8, dfs: 9,
            genes_of: '0003.ann' },
          { op: 'mutation', first: '0003.ann', second: '0001.ann', parent: 'first', dff: 0, dfs: 14,
            genes: { weight_step: 0.35 }, fw: { fw_self_atari: 0.2042 } },
          { op: 'elite', first: '0002.ann' }
        ],
        2 => [
          { op: 'crossover', first: '0.ann', second: '0.ann', parent: 'first', dff: 0, dfs: 0, same: '0.ann' },
          { op: 'mutation', first: '2.ann', second: '1.ann', parent: 'second', dff: nil, dfs: nil,
            structure: 'narrow', width: 199, genes: { weight_step: 0.25 } },
          { op: 'mutation', first: '3.ann', second: '0.ann', parent: 'first', dff: 6, dfs: 11,
            genes: { weight_step: 0.38 } },
          { op: 'elite', first: '3.ann' }
        ]
      }
    }
  }.freeze

  module_function

  def dir = @dir ||= Dir.mktmpdir('evo-gene-trajectories-test')

  def path(name)
    @paths ||= {}
    @paths[name] ||= build(name)
  end

  def name(generation, i) = generation.zero? ? format('%04d.ann', i + 1) : "#{i}.ann"

  # The births of a run, every row with every column (multi_insert takes
  # its columns from the first row), in no particular order.
  def births(run)
    spec = RUNS.fetch(run)
    stored = {}
    spec[:births].sort.flat_map do |generation, rows|
      previous = stored
      stored = {}
      rows.each_with_index.map do |row, i|
        child = name(generation, i)
        stored[child] = birth(run, spec, generation, child, row, previous)
      end
    end.sort_by { |row| [-row[:generation], row[:child]] }
  end

  def birth(run, spec, generation, child, row, previous)
    op = row.fetch(:op, 'initial')
    picked = row[:parent] == 'second' ? row[:second] : row[:first]
    same = row[:same] || (%w[copy elite].include?(op) ? picked : nil)
    source = same || row[:genes_of]
    base = if source then previous.fetch(source)
           else
             genes = spec[:genes].merge(generation.zero? ? {} : spec.fetch(:bred_genes, {}))
             fw = FEATURE_WEIGHTS.to_h { |column| [column, spec.fetch(:missing_fw, []).include?(column) ? nil : spec[:fw]] }
             { layers: 10, width: 200, **genes, **fw }
           end
    birth = { generation:, child:, operator: op, seed: generation + child.to_i,
              genome: same ? previous.fetch(same)[:genome] : Digest::SHA256.hexdigest("#{run} #{generation} #{child}"),
              first_parent: row[:first], second_parent: op == 'elite' ? nil : row[:second],
              parent: generation.zero? ? nil : row.fetch(:parent, 'first'),
              differs_from_first: op == 'elite' ? 0 : row[:dff], differs_from_second: row[:dfs],
              structure: generation.zero? ? nil : row.fetch(:structure, 'none'),
              activation_changed: generation.zero? ? nil : row.fetch(:act, false),
              act_hidden: 'sigmoid', act_output: 'sigmoid_cached',
              features: spec[:missing_fw] ? 'shapes,tactics,liberties' : 'shapes,tactics,last_move,liberties' }
    birth.merge!(base.slice(:layers, :width, *GENES, *FEATURE_WEIGHTS))
    birth.merge!(row.slice(:layers, :width), row.fetch(:genes, {}), row.fetch(:fw, {}))
    birth
  end

  def build(run)
    spec = RUNS.fetch(run)
    path = File.join(dir, run, 'experiment.sqlite3')
    FileUtils.mkdir_p(File.dirname(path))
    db = Sequel.sqlite(path)
    Sequel::Migrator.run(db, ExperimentDatabase::MIGRATIONS, **(spec[:schema] ? { target: spec[:schema] } : {}))
    settings = { 'tournament_rounds' => '2', 'population_size' => spec[:population].to_s, 'seed' => '7' }
    db[:settings].multi_insert(settings.merge(spec[:settings]).map { |key, value| { key:, value: } })
    generations = (0..spec[:finished]).map { |generation| { generation:, round: 2, setup_complete: true } }
    generations << { generation: spec[:unfinished], round: 1, setup_complete: true } if spec[:unfinished]
    db[:generations].multi_insert(generations.reverse)
    db[:births].multi_insert(births(run))
    db.disconnect
    path
  end
end

Minitest.after_run { FileUtils.rm_rf(GeneTrajectoriesFixture.dir) } if defined?(Minitest)
