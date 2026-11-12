require 'digest'
require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../ruby/experiment_database'
require_relative '../scripts/compare-runs'

# Four small runs of 1,000 generations, written the way the runner writes
# them: four networks a generation (generation 0's named 0001.ann to
# 0004.ann, later ones 0.ann to 3.ann), two bot copies in the tournament, a
# checkpoint every 100 generations, 4 benchmark games an opponent, and a
# benchmark panel stored out of name order (Brown before AmiGo, rows
# inserted out of position order).
#
# - base: generations 0–1000.
# - copy: at schema 17 (no elite_share), base's births, rankings and
#   benchmark through generation 500; its generation 501, stopped in round
#   1 of 2, has other births and rankings.
# - twin: base's through generation 400. From 401 its 3.ann has another
#   genome, from 451 every child; its rankings differ from 403. Its
#   champions lose to the GenNChampion opponents at 500 and 600, and its
#   checkpoint 600 stored only 2 of its 4 games against MichiMid.
# - elite: elite_share 0.25, its 3.ann an elite from generation 1 on. It
#   shares generation 0, and generation 1's bred children, with base. The
#   elite of 201–300 is generation 200's champion carried on, so the
#   champion of 300 has the genome of its opponent Gen200Champion. One
#   bot-against-bot game has another winner, and one game of the
#   champion of 700 against MichiMid failed.
module CompareRunsFixture
  PANEL = [{ position: 3, name: 'MichiMid', kind: 'bot', command: 'michi gtp --sims 300' },
           { position: 0, name: 'Brown', kind: 'bot', command: 'brown' },
           { position: 4, name: 'Gen0Champion', kind: 'initial_champion', command: nil },
           { position: 1, name: 'AmiGo', kind: 'bot', command: 'amigogtp' },
           { position: 5, name: 'PastChampions', kind: 'past_champions', command: nil },
           { position: 2, name: 'MichiWeak', kind: 'bot', command: 'michi gtp --sims 80' }].freeze
  BOTS = %w[Brown AmiGo MichiWeak MichiMid].freeze
  OPS = %w[mutation crossover mutation copy].freeze

  # Wins against Brown, AmiGo, MichiWeak and MichiMid, of 4 each, per
  # checkpoint.
  BASE_WINS = {
    0 => [3, 0, 0, 0], 100 => [4, 1, 1, 0], 200 => [4, 2, 1, 0], 300 => [4, 2, 2, 1], 400 => [4, 3, 2, 1],
    500 => [4, 3, 2, 1], 600 => [4, 3, 3, 1], 700 => [4, 2, 3, 1], 800 => [4, 3, 3, 2], 900 => [4, 4, 3, 1],
    1000 => [4, 4, 3, 2]
  }.freeze
  TWIN_WINS = BASE_WINS.select { |generation, _| generation <= 400 }.merge(500 => [4, 2, 2, 1], 600 => [4, 3, 2, 2]).freeze
  ELITE_WINS = {
    0 => [3, 0, 0, 0], 100 => [4, 2, 1, 1], 200 => [4, 2, 2, 1], 300 => [4, 3, 2, 1], 400 => [4, 3, 3, 1],
    500 => [4, 3, 3, 2], 600 => [4, 3, 3, 2], 700 => [4, 4, 3, 1], 800 => [4, 3, 3, 2], 900 => [4, 4, 3, 2],
    1000 => [4, 4, 4, 2]
  }.freeze
  # Bot strength for the bot games: the stronger wins, except that
  # AmiGo and MichiWeak each win as Black.
  STRENGTH = { 'Brown' => 0, 'AmiGo' => 1, 'MichiWeak' => 1, 'MichiMid' => 2 }.freeze

  module_function

  def dir = @dir ||= Dir.mktmpdir('evo-compare-runs-test')

  def path(name)
    @paths ||= {}
    @paths[name] ||= build(name)
  end

  def name(generation, i) = generation.zero? ? format('%04d.ann', i + 1) : "#{i}.ann"

  def champion(generation) = name(generation, (generation / 100) % 4)

  def genome(tag, generation, i) = Digest::SHA256.hexdigest("#{tag} #{generation} #{i}")

  def last(run) = { 'base' => 1000, 'copy' => 501, 'twin' => 600, 'elite' => 1000 }.fetch(run)

  # The tag a child's genome is hashed from; elites are worked out apart.
  def tag(run, generation, i)
    case run
    when 'copy' then generation <= 500 ? 'base' : 'copy'
    when 'twin' then generation <= 400 || (generation <= 450 && i < 3) ? 'base' : 'twin'
    when 'elite' then generation.zero? || generation == 1 ? 'base' : 'elite'
    else 'base'
    end
  end

  def births(run)
    genomes = {}
    rows = (0..last(run)).flat_map do |generation|
      (0..3).map do |i|
        elite = run == 'elite' && generation.positive? && i == 3
        source = generation.between?(201, 300) ? [200, 2] : [generation - 1, 0]
        genomes[[generation, i]] = elite ? genomes.fetch(source) : genome(tag(run, generation, i), generation, i)
        operator = if generation.zero? then 'initial'
                   elsif elite then 'elite'
                   else OPS[(generation + i) % 4]
                   end
        { generation:, child: name(generation, i), operator:, seed: generation + i, genome: genomes[[generation, i]],
          first_parent: generation.zero? ? nil : name(generation - 1, (i + 1) % 4),
          second_parent: generation.zero? ? nil : name(generation - 1, (i + 2) % 4),
          parent: generation.zero? ? nil : 'first' }
      end
    end
    rows.sort_by { |row| [-row[:generation], row[:child]] }
  end

  def score(run, generation, i)
    base = (generation + i) % 3
    case run
    when 'copy' then generation > 500 && i.zero? ? base + 10 : base
    when 'twin' then generation >= 403 && i.zero? ? base + 10 : base
    when 'elite' then generation.positive? && i == 3 ? 3 : base
    else base
    end
  end

  def rankings(run)
    (0..last(run)).flat_map do |generation|
      players = (0..3).map { |i| [name(generation, i), score(run, generation, i), false] } +
                [['Brown1', 0, true], ['AmiGo1', 2, true]]
      players.sort_by { |player, score, _| [-score, player] }.each_with_index.map do |(player, score, external), rank|
        { generation:, rank: rank + 1, name: player, score:, external: }
      end
    end
  end

  def wins(run)
    { 'base' => BASE_WINS, 'copy' => BASE_WINS.select { |generation, _| generation <= 500 }, 'twin' => TWIN_WINS,
      'elite' => ELITE_WINS }.fetch(run)
  end

  def benchmark_games(run)
    wins(run).flat_map do |generation, won|
      network = champion(generation)
      bot_games = BOTS.zip(won).flat_map do |bot, count|
        games = 0.upto(3).map do |k|
          { opponent: bot, opening: k / 2, network_color: k.even? ? 'black' : 'white', winner: k < count ? 'network' : 'opponent' }
        end
        games = games.first(2) if run == 'twin' && generation == 600 && bot == 'MichiMid'
        games[-1] = games[-1].merge(winner: nil, failure: 'crash (white)') if run == 'elite' && generation == 700 && bot == 'MichiMid'
        games
      end
      past = [0, *(100...generation).step(100)].select { |source| generation.positive? && generation - source <= 1000 }
      champion_games = past.flat_map do |source|
        opponent = source.zero? ? 'Gen0Champion' : "Gen#{source}Champion"
        lost = run == 'twin' && generation >= 500
        0.upto(3).map do |k|
          { opponent:, opponent_network: "#{source}:#{champion(source)}", opening: k / 2,
            network_color: k.even? ? 'black' : 'white', winner: lost ? 'opponent' : 'network' }
        end
      end
      # multi_insert takes its columns from the first row, so every row has them all.
      (champion_games + bot_games).map { |game| { opponent_network: nil, failure: nil }.merge(game, generation:, network:) }
    end.reverse
  end

  def bot_games(run)
    BOTS.combination(2).flat_map do |a, b|
      [[a, b], [b, a]].map do |black, white|
        winner = if STRENGTH[black] == STRENGTH[white] then 'black'
                 else STRENGTH[black] > STRENGTH[white] ? 'black' : 'white'
                 end
        winner = 'black' if run == 'elite' && black == 'MichiWeak' && white == 'MichiMid'
        { generation: 0, black:, white:, opening: 0, winner: }
      end
    end
  end

  def build(run)
    path = File.join(dir, run, 'experiment.sqlite3')
    FileUtils.mkdir_p(File.dirname(path))
    settings = { 'tournament_rounds' => '2', 'keep_every' => '100', 'benchmark_games' => '4',
                 'benchmark_bot_games' => '2', 'benchmark_champions' => '10', 'population_size' => '4',
                 'seed' => '7' }
    if run == 'copy'
      db = Sequel.sqlite(path)
      Sequel::Migrator.run(db, ExperimentDatabase::MIGRATIONS, target: 17)
    else
      ExperimentDatabase.new(path)
      db = Sequel.sqlite(path)
      settings['elite_share'] = run == 'elite' ? '0.25' : '0.0'
    end
    db[:settings].multi_insert(settings.map { |key, value| { key:, value: } })
    db[:benchmark_opponents].multi_insert(PANEL)
    db[:generations].multi_insert((0..last(run)).map do |generation|
      { generation:, round: run == 'copy' && generation == 501 ? 1 : 2, setup_complete: true }
    end)
    db[:births].multi_insert(births(run))
    db[:rankings].multi_insert(rankings(run))
    db[:benchmark_games].multi_insert(benchmark_games(run))
    db[:benchmark_bot_games].multi_insert(bot_games(run))
    db.disconnect
    path
  end
end

Minitest.after_run { FileUtils.rm_rf(CompareRunsFixture.dir) }

# scripts/compare-runs.rb on the fixture runs above.
class CompareRunsTest < Minitest::Test
  C = CompareRuns
  F = CompareRunsFixture
  SCRIPT = File.expand_path('../scripts/compare-runs.rb', __dir__)

  def run_named(name)
    db = Sequel.sqlite(F.path(name), readonly: true)
    C.load(db, name)
  ensure
    db&.disconnect
  end

  def runs(*names) = names.map { |name| run_named(name) }

  # The whole report: AmiGo is rated 0 though Brown comes first in the
  # panel; copy's unfinished generation 501 is left out, so base and copy
  # never differ; base, copy and twin share their champions' games through
  # 400 and so their ratings; twin's 600 is incomplete and elite's 700 has
  # a failed game. base's 500..1000 window by hand: wins 6, 7, 6, 8, 8, 9,
  # mean 7.33, slope 1000 / 175000 a generation (+0.57 per 100), residual
  # SD √(1.619 / 4) = 0.64.
  def test_the_report_on_four_runs
    assert_equal <<~REPORT, C.report(runs('base', 'copy', 'twin', 'elite'))
      Runs: base, copy, twin, elite.
      Left out everywhere, their tournament unfinished: copy generation 501 (round 1 of 2).

      ## Ratings from the games against the bots

      One rating fit (BenchmarkRatings) over every run's champion-against-bot games and base's bot-against-bot games, AmiGo rated 0. Each bot is one player in all runs; each run's champions are players of their own. Games against Gen0Champion and the GenNChampion opponents are left out, so champions are linked only through the bots. The bots are rated from all given runs' champions, so a champion's rating still moves with the other champions given, and ratings compare only within one invocation of this script. ± is the 95 % half-width with the other ratings held fixed; a checkpoint missing some of its games against the bots is marked incomplete.

      Bot-against-bot games with another result than in base: copy 0 of 12, twin 0 of 12, elite 1 of 12.

      | Checkpoint | base | copy | twin | elite |
      | --- | ---: | ---: | ---: | ---: |
      | 0 | -406 ± 295 | -406 ± 295 | -406 ± 295 | -406 ± 295 |
      | 100 | -115 ± 217 | -115 ± 217 | -115 ± 217 | 10 ± 195 |
      | 200 | -49 ± 203 | -49 ± 203 | -49 ± 203 | 66 ± 192 |
      | 300 | 66 ± 192 | 66 ± 192 | 66 ± 192 | 121 ± 191 |
      | 400 | 121 ± 191 | 121 ± 191 | 121 ± 191 | 177 ± 194 |
      | 500 | 121 ± 191 | 121 ± 191 | 66 ± 192 | 235 ± 201 |
      | 600 | 177 ± 194 | — | 220 ± 217, incomplete | 235 ± 201 |
      | 700 | 121 ± 191 | — | — | 262 ± 215 |
      | 800 | 235 ± 201 | — | — | 235 ± 201 |
      | 900 | 235 ± 201 | — | — | 299 ± 213 |
      | 1000 | 299 ± 213 | — | — | 373 ± 233 |

      | Bot | Rating |
      | --- | ---: |
      | MichiMid | 310 ± 71 |
      | MichiWeak | 83 ± 63 |
      | AmiGo | 0 |
      | Brown | -657 ± 163 |

      ## Wins against AmiGo, MichiWeak, MichiMid

      Per checkpoint, the champion's wins against these bots (games a checkpoint: base 12, copy 12, twin 12, elite 12). After ±, how far one champion's wins would move over another sample of openings and bot seeds: the 95 % half-width of the binomial spread, summed over the bots at the champion's own win rate against each. Replaying the same games would not move them: the openings repeat at every checkpoint, AmiGo plays deterministically, and the michi levels repeat for their seed.

      Failed games against these bots (no winner, so not wins; left out of the ratings): elite 1.

      | Checkpoint | base | copy | twin | elite |
      | --- | ---: | ---: | ---: | ---: |
      | 0 | 0 ± 0 | 0 ± 0 | 0 ± 0 | 0 ± 0 |
      | 100 | 2 ± 2 | 2 ± 2 | 2 ± 2 | 4 ± 3 |
      | 200 | 3 ± 3 | 3 ± 3 | 3 ± 3 | 5 ± 3 |
      | 300 | 5 ± 3 | 5 ± 3 | 5 ± 3 | 6 ± 3 |
      | 400 | 6 ± 3 | 6 ± 3 | 6 ± 3 | 7 ± 3 |
      | 500 | 6 ± 3 | 6 ± 3 | 5 ± 3 | 8 ± 3 |
      | 600 | 7 ± 3 | — | 7 of 10, incomplete | 8 ± 3 |
      | 700 | 6 ± 3 | — | — | 8 ± 2 |
      | 800 | 8 ± 3 | — | — | 8 ± 3 |
      | 900 | 8 ± 2 | — | — | 9 ± 3 |
      | 1000 | 9 ± 3 | — | — | 10 ± 2 |

      Per run and window, over its checkpoints: the mean wins, the least-squares slope in wins per 100 generations, and the residual standard deviation around that line. A slope describes a straight line over the window, not its shape. A run whose complete checkpoints do not cover the whole window gets no figures.

      | Run | Window | Checkpoints | Mean wins | Slope per 100 generations | Residual SD |
      | --- | ---: | ---: | ---: | ---: | ---: |
      | base | 500..1000 | 6 | 7.3 | +0.6 | 0.6 |
      | base | 200..1000 | 9 | 6.4 | +0.6 | 0.7 |
      | copy | 500..1000 | does not cover | — | — | — |
      | copy | 200..1000 | does not cover | — | — | — |
      | twin | 500..1000 | does not cover | — | — | — |
      | twin | 200..1000 | does not cover | — | — | — |
      | elite | 500..1000 | 6 | 8.5 | +0.4 | 0.5 |
      | elite | 200..1000 | 9 | 7.7 | +0.5 | 0.5 |

      ## Where the runs diverge

      Per pair of runs, over the finished generations both have: the first whose births differ (a child with another genome, or a child in one run only) and how many births (same child, same genome) the two still share there, the last generation with any shared birth, and the first whose rankings differ (a player with another score, or a player in one run only). A genome hashes the network file, which holds the genes too, so a different genome can mean different stored genes only (networks bred from the same draws): no shared birth does not mean no shared network play.

      | Runs | Generations both have | Births first differ | Shared births there | Last shared birth | Rankings first differ |
      | --- | ---: | ---: | ---: | ---: | ---: |
      | base, copy | 0–500 | never | — | 500 | never |
      | base, twin | 0–600 | 401 | 3 | 450 | 403 |
      | base, elite | 0–1000 | 1 | 3 | 1 | 1 |
      | copy, twin | 0–500 | 401 | 3 | 450 | 403 |
      | copy, elite | 0–500 | 1 | 3 | 1 | 1 |
      | twin, elite | 0–600 | 1 | 3 | 1 | 1 |

      ## Champions benchmarked against themselves

      Per run, each checkpoint champion's operator (its birth), and the checkpoints whose champion has the same genome as a network it was benchmarked against (Gen0Champion or a GenNChampion).

      - base: 0 initial, 100 crossover, 200 mutation, 300 copy, 400 mutation, 500 crossover, 600 mutation, 700 copy, 800 mutation, 900 crossover, 1000 mutation; same genome as an opponent: none
      - copy: 0 initial, 100 crossover, 200 mutation, 300 copy, 400 mutation, 500 crossover; same genome as an opponent: none
      - twin: 0 initial, 100 crossover, 200 mutation, 300 copy, 400 mutation, 500 crossover, 600 mutation; same genome as an opponent: none
      - elite: 0 initial, 100 crossover, 200 mutation, 300 elite, 400 mutation, 500 crossover, 600 mutation, 700 elite, 800 mutation, 900 crossover, 1000 mutation; same genome as an opponent: 300 (Gen200Champion)
    REPORT
  end

  # Given two runs, the report adds their differences; the first run's bot
  # games are the fit's.
  def test_the_report_on_two_runs
    assert_equal <<~REPORT, C.report(runs('twin', 'base'))
      Runs: twin, base.
      Left out everywhere, their tournament unfinished: none.

      ## Ratings from the games against the bots

      One rating fit (BenchmarkRatings) over every run's champion-against-bot games and twin's bot-against-bot games, AmiGo rated 0. Each bot is one player in all runs; each run's champions are players of their own. Games against Gen0Champion and the GenNChampion opponents are left out, so champions are linked only through the bots. The bots are rated from all given runs' champions, so a champion's rating still moves with the other champions given, and ratings compare only within one invocation of this script. ± is the 95 % half-width with the other ratings held fixed; a checkpoint missing some of its games against the bots is marked incomplete.

      Bot-against-bot games with another result than in twin: base 0 of 12.

      | Checkpoint | twin | base |
      | --- | ---: | ---: |
      | 0 | -401 ± 287 | -401 ± 287 |
      | 100 | -121 ± 215 | -121 ± 215 |
      | 200 | -56 ± 202 | -56 ± 202 |
      | 300 | 58 ± 191 | 58 ± 191 |
      | 400 | 113 ± 191 | 113 ± 191 |
      | 500 | 58 ± 191 | 113 ± 191 |
      | 600 | 211 ± 217, incomplete | 169 ± 195 |
      | 700 | — | 113 ± 191 |
      | 800 | — | 228 ± 202 |
      | 900 | — | 228 ± 202 |
      | 1000 | — | 292 ± 213 |

      | Bot | Rating |
      | --- | ---: |
      | MichiMid | 306 ± 101 |
      | MichiWeak | 74 ± 85 |
      | AmiGo | 0 |
      | Brown | -637 ± 210 |

      ## Wins against AmiGo, MichiWeak, MichiMid

      Per checkpoint, the champion's wins against these bots (games a checkpoint: twin 12, base 12). After ±, how far one champion's wins would move over another sample of openings and bot seeds: the 95 % half-width of the binomial spread, summed over the bots at the champion's own win rate against each. Replaying the same games would not move them: the openings repeat at every checkpoint, AmiGo plays deterministically, and the michi levels repeat for their seed.

      | Checkpoint | twin | base |
      | --- | ---: | ---: |
      | 0 | 0 ± 0 | 0 ± 0 |
      | 100 | 2 ± 2 | 2 ± 2 |
      | 200 | 3 ± 3 | 3 ± 3 |
      | 300 | 5 ± 3 | 5 ± 3 |
      | 400 | 6 ± 3 | 6 ± 3 |
      | 500 | 5 ± 3 | 6 ± 3 |
      | 600 | 7 of 10, incomplete | 7 ± 3 |
      | 700 | — | 6 ± 3 |
      | 800 | — | 8 ± 3 |
      | 900 | — | 8 ± 2 |
      | 1000 | — | 9 ± 3 |

      Per run and window, over its checkpoints: the mean wins, the least-squares slope in wins per 100 generations, and the residual standard deviation around that line. A slope describes a straight line over the window, not its shape. A run whose complete checkpoints do not cover the whole window gets no figures.

      | Run | Window | Checkpoints | Mean wins | Slope per 100 generations | Residual SD |
      | --- | ---: | ---: | ---: | ---: | ---: |
      | twin | 500..1000 | does not cover | — | — | — |
      | twin | 200..1000 | does not cover | — | — | — |
      | base | 500..1000 | 6 | 7.3 | +0.6 | 0.6 |
      | base | 200..1000 | 9 | 6.4 | +0.6 | 0.7 |

      ## Differences, twin − base

      Per checkpoint both runs have complete, the champions' wins against AmiGo, MichiWeak, MichiMid and their difference.

      | Checkpoint | twin | base | Difference |
      | --- | ---: | ---: | ---: |
      | 0 | 0 | 0 | +0 |
      | 100 | 2 | 2 | +0 |
      | 200 | 3 | 3 | +0 |
      | 300 | 5 | 5 | +0 |
      | 400 | 6 | 6 | +0 |
      | 500 | 5 | 6 | -1 |

      ## Where the runs diverge

      Per pair of runs, over the finished generations both have: the first whose births differ (a child with another genome, or a child in one run only) and how many births (same child, same genome) the two still share there, the last generation with any shared birth, and the first whose rankings differ (a player with another score, or a player in one run only). A genome hashes the network file, which holds the genes too, so a different genome can mean different stored genes only (networks bred from the same draws): no shared birth does not mean no shared network play.

      | Runs | Generations both have | Births first differ | Shared births there | Last shared birth | Rankings first differ |
      | --- | ---: | ---: | ---: | ---: | ---: |
      | twin, base | 0–600 | 401 | 3 | 450 | 403 |

      ## Champions benchmarked against themselves

      Per run, each checkpoint champion's operator (its birth), and the checkpoints whose champion has the same genome as a network it was benchmarked against (Gen0Champion or a GenNChampion).

      - twin: 0 initial, 100 crossover, 200 mutation, 300 copy, 400 mutation, 500 crossover, 600 mutation; same genome as an opponent: none
      - base: 0 initial, 100 crossover, 200 mutation, 300 copy, 400 mutation, 500 crossover, 600 mutation, 700 copy, 800 mutation, 900 crossover, 1000 mutation; same genome as an opponent: none
    REPORT
  end

  # base, copy and twin share their champions' games through 400 (copy
  # through 500). twin's champions of 500 and 600 lost every game to the
  # earlier champions, so a fit that kept those games would rate twin's
  # earlier champions higher than base's.
  def test_identical_champions_get_identical_ratings
    rows = C.ratings(runs('base', 'copy', 'twin', 'elite'))
    (0..500).step(100) do |generation|
      assert_equal rows.fetch("base:Gen#{generation}"), rows.fetch("copy:Gen#{generation}").with(player: "base:Gen#{generation}")
    end
    (0..400).step(100) do |generation|
      assert_equal rows.fetch("base:Gen#{generation}"), rows.fetch("twin:Gen#{generation}").with(player: "base:Gen#{generation}")
    end
  end

  # elite first: its 11 checkpoints' 16 bot games but the failed one,
  # base's 11 times 16, and elite's 12 bot-against-bot games, in which
  # MichiWeak beat MichiMid as Black (in base's, MichiMid won).
  def test_the_fit_takes_bot_games_only_and_the_bots_own_games_from_the_first_run
    games = C.rating_games(runs('elite', 'base'))
    assert_equal (11 * 16) - 1 + (11 * 16) + 12, games.size
    assert_empty(games.select { |_, opponent, _| opponent.start_with?('Gen') })
    assert_includes games, ['MichiWeak', 'MichiMid', 1]
    refute_includes games, ['MichiWeak', 'MichiMid', 0]
    assert_includes games, ['elite:Gen300', 'AmiGo', 1]
  end

  # A failed game has no winner; it is no loss either, so the spread
  # leaves it out: AmiGo 1 of 2 and MichiMid 1 of 1 give 1.96 * sqrt(0.5),
  # where counting the failed game as a loss would give 1.96.
  def test_the_spread_leaves_failed_games_out
    elite, = runs('elite')
    games = [{ opponent: 'AmiGo', winner: 'network' }, { opponent: 'AmiGo', winner: 'opponent' },
             { opponent: 'MichiMid', winner: 'network' }, { opponent: 'MichiMid', winner: nil, failure: 'crash (white)' }]
    run = elite.with(champion_games: games.map { |game| { failure: nil, generation: 0 }.merge(game) })
    result = C.wins(run, %w[AmiGo MichiMid]).fetch(0)
    assert_equal [2, 4, 1], [result.wins, result.games, result.failures]
    assert_in_delta 1.96 * Math.sqrt(0.5), result.spread, 1e-9
  end

  # The sentence on replays holds for the default bots only: AmiGo plays
  # deterministically and michi repeats for its seed, which a bot outside
  # them, such as an unpinned GNU Go, need not.
  def test_the_replay_sentence_only_for_the_default_bots
    base, elite = runs('base', 'elite')
    assert_includes C.report([base, elite]), 'Replaying the same games would not move them'
    refute_includes C.report([base, elite], %w[AmiGo Brown]), 'Replaying the same games'
    # A superset of the default bots holds a bot the sentence is not true
    # of; a subset or another order of them is still covered by it.
    refute_includes C.report([base, elite], %w[AmiGo MichiWeak MichiMid Brown]), 'Replaying the same games'
    assert_includes C.report([base, elite], %w[MichiMid AmiGo]), 'Replaying the same games would not move them'
  end

  # A run still being benchmarked can have its games against the chosen
  # bots complete and those against a later panel bot not yet: its rating
  # is then from partial games, so the ratings table marks it, while the
  # wins table, counting the chosen bots only, does not.
  def test_ratings_mark_a_checkpoint_missing_games_against_any_panel_bot
    base, elite = runs('base', 'elite')
    dropped = base.champion_games.find { |game| game[:generation] == 800 && game[:opponent] == 'Brown' }
    partial = base.with(champion_games: base.champion_games - [dropped])
    report = C.report([partial, elite])
    ratings = report[/## Ratings.*?(?=## Wins)/m]
    wins = report[/## Wins.*?(?=Per run and window)/m]
    assert_match(/^\| 800 \| [^|]*, incomplete \|/, ratings)
    assert_match(/^\| 800 \| \d+ ± \d+ \|/, wins)
  end

  def test_bot_agreement_compares_game_by_game
    base, elite = runs('base', 'elite')
    assert_equal [1, 12, 0], C.bot_agreement(base, elite)
    # A failed game differs from a draw, though neither has a winner; a
    # game base did not play has no counterpart.
    draw = base.with(bot_games: base.bot_games.map { |game| game.merge(winner: nil) })
    failed = base.with(bot_games: base.bot_games.map { |game| game.merge(winner: nil, failure: 'crash (black)') })
    assert_equal [12, 12, 0], C.bot_agreement(draw, failed)
    extra = elite.with(bot_games: elite.bot_games + [{ black: 'Brown', white: 'GnuGo', opening: 0, winner: 'white', failure: nil }])
    assert_equal [1, 12, 1], C.bot_agreement(base, extra)
    assert_includes C.report([base, extra]), 'Bot-against-bot games with another result than in base: elite 1 of 12; 1 not in base.'
  end

  def test_refuses_runs_it_cannot_compare
    base, elite = runs('base', 'elite')
    other = elite.with(panel: elite.panel.map { |row| row[:name] == 'AmiGo' ? row.merge(command: 'amigogtp --x') : row })
    error = assert_raises(C::Refused) { C.report([base, other]) }
    assert_equal 'bot AmiGo is `amigogtp` in base but `amigogtp --x` in elite', error.message
    error = assert_raises(C::Refused) { C.report([base, base]) }
    assert_equal 'two runs are named base', error.message
    error = assert_raises(C::Refused) { C.report([base, elite], %w[AmiGo GnuGo]) }
    assert_equal 'base has no benchmark bot GnuGo', error.message
  end

  # Wins 1, 2, 5, 6 at 0..3: mean 3.5, slope 9 / 5, residuals 0.2, -0.6,
  # 0.6, -0.2, so 0.8 over 2 degrees of freedom.
  def test_least_squares_line
    mean, slope, residual_sd = C.line([[0, 1], [1, 2], [2, 5], [3, 6]])
    assert_in_delta 3.5, mean
    assert_in_delta 1.8, slope
    assert_in_delta Math.sqrt(0.4), residual_sd
    assert_equal [3.0, 2.0, nil], C.line([[0, 2], [1, 4]])
    assert_equal [5.0, nil, nil], C.line([[100, 5]])
  end

  # 1 of 4, 2 of 4 and 4 of 4: variances 3/4, 1 and 0.
  def test_spread_sums_the_binomial_variances_over_the_bots
    assert_in_delta 1.96 * Math.sqrt(1.75), C.spread([[1, 4], [2, 4], [4, 4]])
    assert_equal 0, C.spread([[0, 0]])
  end

  def test_a_window_needs_every_checkpoint_there_and_complete
    base = run_named('base')
    wins = C.wins(base, C::DEFAULT_BOTS)
    window = C.window(base, wins, 500..1000)
    assert_equal 6, window.checkpoints
    assert_in_delta 44 / 6r, window.mean
    assert_in_delta 100 * 1000 / 175_000r, window.slope
    assert_nil C.window(base, wins.except(700), 500..1000)
    assert_nil C.window(base, wins.merge(700 => wins[700].with(complete: false)), 500..1000)
    assert_nil C.window(base.with(keep_every: 0), wins, 500..1000)
    # keep_every 300 puts only 600 and 900 in the window: 7 and 8 wins.
    window = C.window(base.with(keep_every: 300), wins, 500..1000)
    assert_equal [2, 7.5, 1 / 3r], [window.checkpoints, window.mean, window.slope.rationalize(1e-9)]
    assert_nil window.residual_sd
  end

  def test_rosters_with_other_names
    a = C::Roster.new(names: %w[0.ann 1.ann 2.ann], values: [1, 2, 3])
    b = C::Roster.new(names: %w[0.ann 2.ann 3.ann], values: [1, 3, 4])
    assert_equal 2, C.shared(a, b)
    assert C.differ?(a, b)
    refute C.differ?(a, a.with(names: a.names.dup))
    fewer = C::Roster.new(names: %w[0.ann 1.ann], values: [1, 2])
    assert_equal 2, C.shared(a, fewer)
    assert C.differ?(a, fewer)
    assert C.differ?(fewer, a)
  end

  def test_runs_without_a_generation_in_common
    base, copy = runs('base', 'copy')
    assert_includes C.report([base.with(finished: []), copy]), '| base, copy | none | — | — | — | — |'
  end

  def test_one_run_has_no_pairs_and_no_other_bot_games
    report = C.report(runs('copy'))
    assert_includes report, "\n\nOne run: no pairs.\n"
    refute_includes report, 'Bot-against-bot games with another result'
    refute_includes report, '## Differences'
  end

  # Opened read-only, a mistyped path fails instead of creating an empty
  # database inside an experiment.
  def test_the_script_creates_no_database_at_a_missing_path
    missing = File.join(F.dir, 'missing.sqlite3')
    _out, err, status = Open3.capture3(RbConfig.ruby, SCRIPT, F.path('base'), missing)
    refute status.success?
    assert_match(/\Acannot open #{Regexp.escape(missing)}: /, err)
    refute File.exist?(missing)
  end

  def test_the_script_prints_the_report_and_leaves_the_databases_alone
    paths = [F.path('base'), F.path('copy')]
    before = paths.map { |path| File.binread(path) }
    out, err, status = Open3.capture3(RbConfig.ruby, SCRIPT, *paths)
    assert status.success?, err
    assert_equal C.report(runs('base', 'copy')), out
    assert_equal before, paths.map { |path| File.binread(path) }
    paths.each { |path| refute File.exist?("#{path}-journal") || File.exist?("#{path}-wal") }
  end

  def test_the_script_takes_other_bots
    out, err, status = Open3.capture3(RbConfig.ruby, SCRIPT, '--bots', 'Brown,AmiGo', F.path('base'))
    assert status.success?, err
    assert_equal C.report(runs('base'), %w[Brown AmiGo]), out
    assert_includes out, "## Wins against Brown, AmiGo\n\nPer checkpoint, the champion's wins against these bots " \
                         '(games a checkpoint: base 8).'
    assert_includes out, "| 0 | 3 ± 2 |\n| 100 | 5 ± 2 |\n"
  end

  def test_the_script_refuses_what_it_cannot_compare
    _out, err, status = Open3.capture3(RbConfig.ruby, SCRIPT, '--bots', 'GnuGo', F.path('base'))
    refute status.success?
    assert_equal "base has no benchmark bot GnuGo\n", err
    _out, err, status = Open3.capture3(RbConfig.ruby, SCRIPT, F.path('base'), F.path('base'))
    refute status.success?
    assert_equal "two runs are named base\n", err
  end

  def test_the_script_needs_a_database
    _out, err, status = Open3.capture3(RbConfig.ruby, SCRIPT)
    refute status.success?
    assert_match(/usage/, err)
    _out, err, status = Open3.capture3(RbConfig.ruby, SCRIPT, '--colour', F.path('base'))
    refute status.success?
    assert_match(/invalid option: --colour\nusage/, err)
  end
end
