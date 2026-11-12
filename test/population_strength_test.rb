require 'minitest/autorun'
require 'open3'
require_relative 'population_strength_fixture'
require_relative '../scripts/population-strength'

# scripts/population-strength.rb on the fixture runs
# (population_strength_fixture.rb). The whole report's text below came
# from an independent reading of the fixture databases, before the script
# existed.
class PopulationStrengthTest < Minitest::Test
  P = PopulationStrength
  F = PopulationStrengthFixture
  SCRIPT = File.expand_path('../scripts/population-strength.rb', __dir__)

  def run_named(name, width = 2)
    db = Sequel.sqlite(F.path(name), readonly: true)
    P.load(db, name, width)
  ensure
    db&.disconnect
  end

  def runs(*names, width: 2) = names.map { |name| run_named(name, width) }

  # The whole report, in windows of 2 generations. elite's unfinished
  # generation 6 is left out (its partial ranking and its births); so its
  # 5–6 holds one generation, and generation 5's elites, with no kept next
  # generation, are not followed. plain's 3–4 holds one generation. By
  # hand: elite's generation 0 has AmiGo copies at 22, 18 and 20 (mean 20),
  # and 6 of its 15 networks above that; 0001.ann's 20 is not. Generation
  # 1's elites (from 0005.ann, 0002.ann, 0010.ann) rank 3rd, 9th and 1st of
  # its networks (percentiles 2/14, 8/14, 0); 14.ann and 12.ann are carried
  # again, 13.ann not. In generation 2 14.ann has 3 bred children (a
  # crossover with 6.ann, a crossover with itself counted once, a copy
  # with parent 'second'; 7.ann, a mutation that drew it second but used
  # 3.ann, is not its child), 12.ann 2, 13.ann 0 (it was only drawn, never
  # used); 6.ann, generation 1's first network by rank that is not an
  # elite, has 4. Generation 3's tie at 26 is stored 14.ann, 8.ann, 1.ann,
  # so its first 2 networks are both elites. Elite chains: generation 1's
  # 14.ann is carried on as generation 2's 12.ann, 3's 12.ann and 4's
  # 12.ann (4 in a row), then drops. Generation 3's 0.ann, a crossover of
  # 1.ann and 3.ann of generation 2 (both with generation 1's 14.ann's
  # genome) that used 3.ann, is set against 3.ann's score (27), not
  # 1.ann's (25).
  def test_the_report_on_two_runs
    assert_equal <<~REPORT, P.report(runs('elite', 'plain'))
      Runs: elite, plain.
      Left out everywhere, their tournament unfinished: elite generation 6 (round 1 of 2).
      Elites (births with operator elite) in the generations kept: elite 15, plain none.
      Windows: generation 0 on its own, then 2 generations each (1–2, 3–4, …). A run's last window can hold fewer; the Generations column says how many each row holds.

      ## Population against the bots

      Per run and window, the share of networks whose tournament score is strictly above the mean score of a bot's copies in the same tournament, for AmiGo, MichiWeak and MichiMid (a bot's copies are the players whose players.opponent names it), over the window's generations; a network whose score equals the mean is not above it. Three populations: all networks, the bred networks (the initial population and the elites left out), and the elites alone.

      ### All networks

      | Run | Window | Generations | Networks | Above AmiGo | Above MichiWeak | Above MichiMid |
      | --- | ---: | ---: | ---: | ---: | ---: | ---: |
      | elite | 0 | 1 | 15 | 40.0 % | 66.7 % | 20.0 % |
      | elite | 1–2 | 2 | 30 | 40.0 % | 73.3 % | 16.7 % |
      | elite | 3–4 | 2 | 30 | 43.3 % | 76.7 % | 13.3 % |
      | elite | 5–6 | 1 | 15 | 26.7 % | 60.0 % | 13.3 % |
      | plain | 0 | 1 | 8 | 62.5 % | 75.0 % | 12.5 % |
      | plain | 1–2 | 2 | 16 | 43.8 % | 81.2 % | 18.8 % |
      | plain | 3–4 | 1 | 8 | 37.5 % | 87.5 % | 12.5 % |

      ### Bred networks

      | Run | Window | Generations | Networks | Above AmiGo | Above MichiWeak | Above MichiMid |
      | --- | ---: | ---: | ---: | ---: | ---: | ---: |
      | elite | 0 | 1 | 0 | — | — | — |
      | elite | 1–2 | 2 | 24 | 33.3 % | 66.7 % | 8.3 % |
      | elite | 3–4 | 2 | 24 | 41.7 % | 75.0 % | 8.3 % |
      | elite | 5–6 | 1 | 12 | 16.7 % | 58.3 % | 8.3 % |
      | plain | 0 | 1 | 0 | — | — | — |
      | plain | 1–2 | 2 | 16 | 43.8 % | 81.2 % | 18.8 % |
      | plain | 3–4 | 1 | 8 | 37.5 % | 87.5 % | 12.5 % |

      ### Elites

      Runs without elites: plain.

      | Run | Window | Generations | Networks | Above AmiGo | Above MichiWeak | Above MichiMid |
      | --- | ---: | ---: | ---: | ---: | ---: | ---: |
      | elite | 0 | 1 | 0 | — | — | — |
      | elite | 1–2 | 2 | 6 | 66.7 % | 100.0 % | 50.0 % |
      | elite | 3–4 | 2 | 6 | 50.0 % | 83.3 % | 33.3 % |
      | elite | 5–6 | 1 | 3 | 66.7 % | 66.7 % | 33.3 % |

      ## Elites

      Per run with elites and window, of the elites carried into the window's generations (births with operator elite), in the tournament they are carried into: their rank percentile among the generation's networks, mean and median (the share of the generation's other networks before it in the stored ranking, so 0 is the first network and 1 the last; bots left out); and the longest chain, the most generations in a row one network was carried as an elite, up to a generation of the window (counted from its first carry, which can lie in an earlier window). Of the elites whose next generation is kept (Elites followed; a run's last kept generation has none): the share carried again into the next generation (Stay elite), and their mean number of bred children in the next generation, against the same mean for the networks of the same generations that are among the generation's first 10 % of networks by stored rank (0.1 times the networks, rounded, a half up, at least 1; bots left out) and are not elites. Children are counted as stats counts them: a crossover once for each of its two distinct parents, a mutation or copy only for the parent it used (parent), never for both drawn parents.

      Runs without elites: plain.

      | Run | Window | Generations | Elites | Mean percentile | Median percentile | Longest chain | Elites followed | Stay elite | Children per elite | Top 10 % non-elites | Children per top 10 % non-elite |
      | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
      | elite | 0 | 1 | 0 | — | — | — | 0 | — | — | 0 | — |
      | elite | 1–2 | 2 | 6 | 0.226 | 0.179 | 2 | 6 | 50.0 % | 2 | 2 | 4 |
      | elite | 3–4 | 2 | 6 | 0.31 | 0.25 | 4 | 6 | 50.0 % | 2.17 | 1 | 4 |
      | elite | 5–6 | 1 | 3 | 0.357 | 0.143 | 2 | 0 | — | — | 0 | — |

      ## Score retest

      Networks that play two tournaments unchanged: the elites, and the exact clones (births with operator copy, and crossovers whose genome equals a parent's). Per run and window, each one's tournament score against the score, in the generation before, of the parent whose genome it equals (the parent it used when both parents have that genome): how many, the mean score before and after, and the mean change (after minus before); for the exact clones also the correlation of the scores before and after (Pearson; — below 2 or without spread). The elites are their generation's first networks by rank, so they get no correlation. Both compare two tournaments against different fields (the next generation's players), so neither the change nor the correlation is a reliability coefficient of one tournament.

      ### Elites

      Runs without elites: plain.

      | Run | Window | Generations | Elites | Mean before | Mean after | Mean change |
      | --- | ---: | ---: | ---: | ---: | ---: | ---: |
      | elite | 0 | 1 | 0 | — | — | — |
      | elite | 1–2 | 2 | 6 | 30 | 25.7 | -4.33 |
      | elite | 3–4 | 2 | 6 | 27.2 | 23.5 | -3.67 |
      | elite | 5–6 | 1 | 3 | 26.7 | 22 | -4.67 |

      ### Exact clones

      | Run | Window | Generations | Exact clones | Mean before | Mean after | Mean change | Correlation |
      | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
      | elite | 0 | 1 | 0 | — | — | — | — |
      | elite | 1–2 | 2 | 8 | 26.8 | 22 | -4.75 | 0.712 |
      | elite | 3–4 | 2 | 9 | 25.1 | 22.1 | -3 | 0.0924 |
      | elite | 5–6 | 1 | 4 | 25.5 | 20 | -5.5 | -0.645 |
      | plain | 0 | 1 | 0 | — | — | — | — |
      | plain | 1–2 | 2 | 8 | 15.8 | 15.6 | -0.125 | 0.834 |
      | plain | 3–4 | 1 | 4 | 18.8 | 18.5 | -0.25 | 0.374 |
    REPORT
  end

  # Elites are told by their operator alone: plain, at schema 17, has no
  # elite_share setting.
  def test_a_report_without_elites
    report = P.report(runs('plain'))
    assert_includes report, "Elites (births with operator elite) in the generations kept: plain none.\n"
    assert_equal 3, report.scan("\n\nNo run has elites.\n").size
    refute_includes report, 'Runs without elites'
    refute_includes report, 'Mean percentile'
  end

  # The first 10 % of networks: rounded as Elitism rounds a share, a half
  # up, and at least 1.
  def test_the_first_tenth
    assert_equal [100, 2, 3, 2, 1, 1], [1000, 15, 25, 24, 4, 1].map { |networks| P.first_tenth(networks) }
  end

  def birth(child, operator = 'mutation', first = 'a', second = 'b', parent = 'first', genome: "g-#{child}")
    { child:, operator:, first_parent: first, second_parent: second, parent:, genome: }
  end

  # As stats counts them: a crossover once for each of its distinct
  # parents, a mutation or copy for the parent it used alone, an elite not.
  def test_children
    births = [birth('0.ann', 'crossover', 'a', 'a'), birth('1.ann', 'crossover', 'a', 'b', 'second'),
              birth('2.ann', 'copy', 'a', 'c', 'second'), birth('3.ann', 'mutation', 'c', 'b'),
              birth('4.ann', 'mutation', 'd', 'd', 'second'), birth('5.ann', 'elite', 'b', nil)]
    assert_equal({ 'a' => 2, 'b' => 1, 'c' => 2, 'd' => 1 }, P.children(births))
  end

  def ranking(*networks, bots: { 'AmiGo1' => 'AmiGo', 'MichiWeak1' => 'MichiWeak', 'MichiMid1' => 'MichiMid' })
    [*networks.map { |name| { name:, score: 5, external: false } },
     *bots.keys.map { |name| { name:, score: 5, external: true } }]
  end

  def refusal(births, ranking, previous = nil, opponents: { 'AmiGo1' => 'AmiGo', 'MichiWeak1' => 'MichiWeak', 'MichiMid1' => 'MichiMid' })
    assert_raises(P::Refused) { P.generation(3, births, ranking, opponents, previous) }.message
  end

  def test_refuses_what_it_cannot_describe
    previous = { births: { 'a' => birth('a', genome: 'ga'), 'b' => birth('b', genome: 'gb') },
                 scores: { 'a' => 5, 'b' => 6 }, chains: {} }
    assert_equal 'generation 3: network x.ann has no birth', refusal([birth('0.ann')], ranking('0.ann', 'x.ann'))
    assert_equal 'generation 3: 1.ann is not ranked', refusal([birth('0.ann'), birth('1.ann')], ranking('0.ann'))
    assert_equal 'generation 3 has no copy of MichiMid',
                 refusal([birth('0.ann')], ranking('0.ann'), opponents: { 'AmiGo1' => 'AmiGo', 'MichiWeak1' => 'MichiWeak' })
    assert_equal 'generation 3: 0.ann has no parent c in generation 2',
                 refusal([birth('0.ann', 'copy', 'c', 'a', genome: 'ga')], ranking('0.ann'), previous)
    assert_equal "generation 3: 0.ann, a copy, has neither parent's genome",
                 refusal([birth('0.ann', 'copy', genome: 'gc')], ranking('0.ann'), previous)
    assert_equal "generation 3: 0.ann, an elite, has not its parent's genome",
                 refusal([birth('0.ann', 'elite', 'a', nil, genome: 'gb')], ranking('0.ann'), previous)
    elite, = runs('elite')
    error = assert_raises(P::Refused) { P.report([elite, elite]) }
    assert_equal 'two runs are named elite', error.message
  end

  # Opened read-only, a mistyped path fails instead of creating an empty
  # database inside an experiment.
  def test_the_script_creates_no_database_at_a_missing_path
    missing = File.join(F.dir, 'missing.sqlite3')
    _out, err, status = Open3.capture3(RbConfig.ruby, SCRIPT, F.path('elite'), missing)
    refute status.success?
    assert_match(/\Acannot open #{Regexp.escape(missing)}: /, err)
    refute File.exist?(missing)
  end

  # Windows of 50 by default: elite's five kept generations after 0 are in
  # 1–50.
  def test_the_script_prints_the_report_and_leaves_the_databases_alone
    paths = [F.path('elite'), F.path('plain')]
    before = paths.map { |path| File.binread(path) }
    out, err, status = Open3.capture3(RbConfig.ruby, SCRIPT, *paths)
    assert status.success?, err
    assert_equal P.report(runs('elite', 'plain', width: 50)), out
    assert_includes out, 'then 50 generations each (1–50, 51–100, …).'
    assert_includes out, "\n| elite | 1–50 | 5 | 15 | 0.286 | 0.143 | 4 | 12 | 50.0 % | 2.08 | 3 | 4 |\n"
    assert_equal before, paths.map { |path| File.binread(path) }
    paths.each { |path| refute File.exist?("#{path}-journal") || File.exist?("#{path}-wal") }
  end

  def test_the_script_takes_a_window
    out, err, status = Open3.capture3(RbConfig.ruby, SCRIPT, '--window', '3', F.path('elite'))
    assert status.success?, err
    assert_equal P.report(runs('elite', width: 3)), out
    assert_includes out, "\n| elite | 4–6 | 2 | 6 | 0.405 | 0.321 | 4 | 3 | 33.3 % | 1.33 | 1 | 4 |\n"
  end

  def test_the_script_needs_a_database_and_a_whole_window
    ['', '--window 0', '--window 2.5', '--colour'].each do |arguments|
      _out, err, status = Open3.capture3(RbConfig.ruby, SCRIPT, *arguments.split, *(F.path('elite') unless arguments.empty?))
      refute status.success?, arguments
      assert_match(/usage: scripts\/population-strength.rb \[--window W\] DATABASE\.\.\.\n\z/, err, arguments)
    end
  end
end
