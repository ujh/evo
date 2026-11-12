require 'digest'
require 'fileutils'
require 'tmpdir'
require_relative '../ruby/experiment_database'

# Two small runs for scripts/population-strength.rb, written the way the
# runner writes them: generation 0's networks 0001.ann on, later ones 0.ann
# on, the elites in the last places, the best first; both drawn parents
# stored on every mutation and copy, `parent` naming the one used; each
# generation's ranking over networks and bot copies (players.opponent
# naming a copy's bot, in a stored order that is not alphabetical: AmiGo10
# before AmiGo2), with ties broken neither by name nor by its reverse (the
# later network first); rows inserted out of order.
#
# Births are written as tokens: an operator (m mutation, k copy, c
# crossover), the first and second drawn parents as indexes into the
# previous generation, `s` when `parent` is 'second', and for a crossover
# `=f` or `=s` when its genome is the first or second parent's. A copy has
# its picked parent's genome, an elite its parent's; every other child a
# genome of its own.
#
# - elite: 15 networks, elite_share 0.2 (3 elites, from generation 1,
#   chosen as the runner chooses them: the previous generation's first 3
#   networks by stored rank), so the first 10 % of networks by rank are 2.
#   Generations 0–5 finished; 6 stopped in round 1 of 2, with births of
#   every kind and a partial ranking, all to be left out. Elites stay elite
#   for up to 4 generations and drop; a tie at generation 3's third place;
#   crossovers of a network with itself; copies with `parent` 'second';
#   crossovers with the genome of the parent not picked; a crossover of two
#   distinct parents that share one genome (generation 3's 0.ann: 1.ann and
#   3.ann of generation 2, both clones of generation 1's 14.ann, with
#   different scores).
# - plain: at schema 17 (no elite_share), 8 networks, no elites,
#   generations 0–3.
module PopulationStrengthFixture
  # A bot copy's name, then its group: players.opponent.
  BOTS = %w[AmiGo10 MichiMid2 AmiGo1 MichiWeak2 GnuGo1 MichiMid1 AmiGo2 MichiWeak1 MichiMid3].freeze

  RUNS = {
    'elite' => {
      schema: nil, population: 15, elites: 3, finished: 5, unfinished: 6,
      settings: { 'elite_share' => '0.2' },
      births: {
        1 => %w[m0/1 k3/4s c6/6=f c7/8s=f m9/2 m11/5s c13/3 m1/9 k7/2 m4/1s c0/14 m3/3],
        2 => %w[c14/6 c14/14=f m12/6s k13/14s m6/13 m1/12s c6/12s=f m3/14 m8/0 c4/8 m11/2s k1/8],
        3 => %w[c1/3s=s c12/12=f m13/3s k14/2s c3/14 m12/0 m5/13 c0/13=s m13/13s m6/12s c3/3=f m9/14s],
        4 => %w[c12/8 m14/12s k13/0 m8/8 c14/14=f m1/12 m3/6s c12/14 m2/13s k5/12s m0/4 c7/12=s],
        5 => %w[c7/14 m7/2 m14/3s k12/7s c14/14=f m0/1 c13/9s=f m5/12s m7/7s c11/4 m6/8 k2/14],
        6 => %w[m14/6 k6/12s c12/12=f m3/1 c14/6 m6/14s k14/0 m2/2 c5/9 m10/12s m8/7 m0/13]
      },
      # Per generation, the networks' scores by index, then the bots' in
      # BOTS order.
      scores: {
        0 => [[20, 31, 12, 25, 31, 8, 17, 22, 14, 27, 5, 19, 11, 24, 16], [22, 29, 18, 17, 40, 25, 20, 14, 24]],
        1 => [[18, 26, 15, 21, 23, 9, 30, 12, 24, 13, 17, 20, 28, 19, 33], [23, 27, 21, 15, 38, 26, 19, 16, 25]],
        2 => [[22, 25, 14, 27, 16, 19, 23, 12, 18, 10, 20, 15, 29, 21, 24], [19, 28, 20, 18, 39, 26, 24, 13, 24]],
        3 => [[21, 26, 17, 24, 13, 19, 23, 16, 26, 11, 20, 18, 30, 22, 26], [24, 25, 22, 18, 37, 26, 20, 17, 27]],
        4 => [[19, 23, 25, 17, 21, 14, 18, 27, 16, 22, 12, 24, 20, 15, 28], [19, 23, 20, 16, 40, 24, 21, 15, 25]],
        5 => [[16, 22, 19, 24, 13, 20, 26, 18, 21, 15, 23, 17, 25, 14, 27], [21, 26, 23, 19, 36, 25, 25, 18, 24]],
        6 => [[1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 2, 1, 0], [1, 2, 0, 1, 2, 1, 0, 2, 1]]
      }
    },
    'plain' => {
      schema: 17, population: 8, elites: 0, finished: 3, unfinished: nil,
      settings: {},
      births: {
        1 => %w[k0/4s m1/2 c3/5=s c2/2=f m4/6s k7/1 c1/4 m6/0s],
        2 => %w[k3/0s k5/4 c6/6=f m0/2 c4/1s=f m2/7 c0/4 m7/1s],
        3 => %w[k1/2s m0/3 c4/4=f k0/0 m6/5s c2/0=s m3/7 c1/6]
      },
      scores: {
        0 => [[12, 18, 9, 15, 21, 15, 7, 13], [12, 20, 14, 11, 30, 16, 10, 8, 18]],
        1 => [[19, 14, 17, 10, 22, 11, 16, 8], [17, 19, 15, 12, 31, 18, 13, 9, 17]],
        2 => [[20, 13, 18, 12, 17, 9, 15, 11], [15, 19, 14, 10, 29, 17, 16, 10, 18]],
        3 => [[16, 14, 19, 21, 10, 18, 12, 15], [18, 20, 16, 12, 33, 19, 14, 11, 21]]
      }
    }
  }.freeze

  TOKEN = %r{\A(?<op>[mkc])(?<first>\d+)/(?<second>\d+)(?<second_picked>s?)(?:=(?<genome_of>[fs]))?\z}
  OPERATORS = { 'm' => 'mutation', 'k' => 'copy', 'c' => 'crossover' }.freeze

  module_function

  def dir = @dir ||= Dir.mktmpdir('evo-population-strength-test')

  def path(name)
    @paths ||= {}
    @paths[name] ||= build(name)
  end

  def name(generation, i) = generation.zero? ? format('%04d.ann', i + 1) : "#{i}.ann"

  # Players of a generation in stored rank order: by score, ties the later
  # player first (networks by index, then the bots in BOTS order).
  def ranking(run, generation)
    networks, bots = RUNS.fetch(run)[:scores].fetch(generation)
    players = networks.each_with_index.map { |score, i| [name(generation, i), score, false] } +
              bots.zip(BOTS).map { |score, bot| [bot, score, true] }
    players.each_with_index.sort_by { |(_, score, _), position| [-score, -position] }.map(&:first)
  end

  def births(run)
    spec = RUNS.fetch(run)
    previous = Array.new(spec[:population]) do |i|
      { generation: 0, child: name(0, i), operator: 'initial', seed: i, genome: genome(run, 0, i) }
    end
    rows = previous.dup
    spec[:births].sort.each do |generation, tokens|
      parents = previous.to_h { |birth| [birth[:child], birth] }
      bred = tokens.each_with_index.map { |token, i| bred(run, generation, i, token, parents) }
      elites = ranking(run, generation - 1).reject(&:last).first(spec[:elites]).each_with_index.map do |player, i|
        parent = player.first
        index = tokens.size + i
        { generation:, child: name(generation, index), operator: 'elite', first_parent: parent, second_parent: nil,
          parent: 'first', seed: index, genome: parents.fetch(parent)[:genome] }
      end
      previous = bred + elites
      rows.concat(previous)
    end
    rows.map { |row| { first_parent: nil, second_parent: nil, parent: nil, **row } }
        .sort_by { |row| [-row[:generation], row[:child]] }
  end

  def bred(run, generation, i, token, parents)
    m = TOKEN.match(token) || raise("bad token #{token}")
    first, second = [m[:first], m[:second]].map { |index| name(generation - 1, Integer(index)) }
    picked = m[:second_picked].empty? ? first : second
    source = { 'f' => first, 's' => second }[m[:genome_of]] || (m[:op] == 'k' ? picked : nil)
    { generation:, child: name(generation, i), operator: OPERATORS.fetch(m[:op]), first_parent: first,
      second_parent: second, parent: m[:second_picked].empty? ? 'first' : 'second', seed: i,
      genome: source ? parents.fetch(source)[:genome] : genome(run, generation, i) }
  end

  def genome(run, generation, i) = Digest::SHA256.hexdigest("#{run} #{generation} #{i}")

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
    rankings = []
    players = []
    spec[:scores].each_key do |generation|
      ranking(run, generation).each_with_index do |(name, score, external), i|
        rankings << { generation:, rank: i + 1, name:, score:, external: }
        players << { generation:, name:, command: external ? "bot #{name}" : name, external:,
                     opponent: external ? name.sub(/\d+\z/, '') : nil }
      end
    end
    db[:rankings].multi_insert(rankings.sort_by { |row| [-row[:generation], row[:name]] })
    db[:players].multi_insert(players.sort_by { |row| [row[:generation], row[:name]] }.reverse)
    db.disconnect
    path
  end
end

Minitest.after_run { FileUtils.rm_rf(PopulationStrengthFixture.dir) } if defined?(Minitest)
