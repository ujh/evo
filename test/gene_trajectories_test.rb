require 'minitest/autorun'
require 'open3'
require_relative 'gene_trajectories_fixture'
require_relative '../scripts/gene-trajectories'

# scripts/gene-trajectories.rb on the fixture runs (gene_trajectories_fixture.rb).
class GeneTrajectoriesTest < Minitest::Test
  G = GeneTrajectories
  F = GeneTrajectoriesFixture
  SCRIPT = File.expand_path('../scripts/gene-trajectories.rb', __dir__)

  def run_named(name, width = 2)
    db = Sequel.sqlite(F.path(name), readonly: true)
    G.load(db, name, width)
  ensure
    db&.disconnect
  end

  def runs(*names, width: 2) = names.map { |name| run_named(name, width) }

  # The whole report, in windows of 2 generations. elite's unfinished
  # generation 6 is left out (its births would add a copy, a
  # self-crossover, a mutation with no weight changed and weight_step 7);
  # its 5–6 holds one generation, meta0's 3–4 likewise. By hand, elite's
  # weight_step over all networks of 1–2: generation 1's median 0.225,
  # generation 2's 0.125, so 0.175; sorted, the 12 values run 0.0001,
  # 0.0001009, 0.1, …, 0.4, 9.95, so the 10th percentile (nearest rank:
  # the 2nd) is 0.0001009 and the 90th (the 11th) 0.4; 0.0001 and 0.0001009
  # are within 1 % of the minimum (2 of 12), 9.95 of the maximum. Its
  # clones of 1–2: the copy 0.ann of generation 1; the self-crossover 1.ann
  # of generation 1; with differs 0 against the picked parent that one and
  # generation 2's 0.ann (picked 'second'); with a parent's genome those and
  # generation 2's 1.ann (the genome of its parent not picked); 1 + 3 exact
  # clones. Generation 2's 2.ann changed no network weight against its
  # picked parent (second), its feature weights by +0.004 and -0.007;
  # 3.ann has differs 0 only against the parent not picked, 4.ann switched
  # an activation. nocopy's copy_chance 0 is Exactly 0, not at the
  # minimum; its weight_step median of medians over 1–2 is 0.3825, which
  # Ruby's %g prints as 0.382 (the tie to even of its shortest decimal).
  def test_the_report_on_three_runs
    assert_equal <<~REPORT, G.report(runs('elite', 'meta0', 'nocopy'))
      Runs: elite, meta0, nocopy.
      Left out everywhere, their tournament unfinished: elite generation 6 (round 1 of 2).
      Elites (births with operator elite) in the generations kept: elite 5, meta0 none, nocopy 2.
      Windows: generation 0 on its own, then 2 generations each (1–2, 3–4, …). A run's last window can hold fewer; the Generations column says how many each row holds.

      ## Genes

      Per run and window, from every kept generation's births, for each gene: the median of the per-generation medians; the 10th and 90th percentiles over the window's networks (nearest rank); and the share of networks within 1 % of a clamp of lib/ann.h (at most 1.01 times the minimum, at least 0.99 times the maximum). weight_changes has no fixed maximum (its limit is the network's own weight count), so only its minimum is counted. A copy_chance of exactly 0 (initial_copy_chance 0: never copy) lies below the clamp range; it is counted as Exactly 0, never as within 1 % of the minimum. Three populations: all networks (every birth, as stats counts genes), the bred children (the initial population and the elites left out), and the elites alone. Values to 3 significant figures, from 100 on to the nearest whole number.

      ### copy_chance

      #### All networks

      | Run | Window | Generations | Networks | Median of medians | 10th percentile | 90th percentile | Within 1 % of 0.0001 | Within 1 % of 0.1 | Exactly 0 |
      | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
      | elite | 0 | 1 | 6 | 0.01 | 0.01 | 0.0999 | 0.0 % | 16.7 % | 0.0 % |
      | elite | 1–2 | 2 | 12 | 0.01 | 0.01 | 0.01 | 8.3 % | 0.0 % | 0.0 % |
      | elite | 3–4 | 2 | 12 | 0.01 | 0.01 | 0.01 | 8.3 % | 0.0 % | 0.0 % |
      | elite | 5–6 | 1 | 6 | 0.01 | 0.01 | 0.01 | 0.0 % | 0.0 % | 0.0 % |
      | meta0 | 0 | 1 | 4 | 0.01 | 0.01 | 0.01 | 0.0 % | 0.0 % | 0.0 % |
      | meta0 | 1–2 | 2 | 8 | 0.01 | 0.01 | 0.01 | 0.0 % | 0.0 % | 0.0 % |
      | meta0 | 3–4 | 1 | 4 | 0.01 | 0.01 | 0.01 | 0.0 % | 0.0 % | 0.0 % |
      | nocopy | 0 | 1 | 4 | 0 | 0 | 0 | 0.0 % | 0.0 % | 100.0 % |
      | nocopy | 1–2 | 2 | 8 | 0 | 0 | 0 | 0.0 % | 0.0 % | 100.0 % |

      #### Bred children

      | Run | Window | Generations | Networks | Median of medians | 10th percentile | 90th percentile | Within 1 % of 0.0001 | Within 1 % of 0.1 | Exactly 0 |
      | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
      | elite | 0 | 1 | 0 | — | — | — | — | — | — |
      | elite | 1–2 | 2 | 10 | 0.01 | 0.0001 | 0.01 | 10.0 % | 0.0 % | 0.0 % |
      | elite | 3–4 | 2 | 10 | 0.01 | 0.0001 | 0.01 | 10.0 % | 0.0 % | 0.0 % |
      | elite | 5–6 | 1 | 5 | 0.01 | 0.01 | 0.01 | 0.0 % | 0.0 % | 0.0 % |
      | meta0 | 0 | 1 | 0 | — | — | — | — | — | — |
      | meta0 | 1–2 | 2 | 8 | 0.01 | 0.01 | 0.01 | 0.0 % | 0.0 % | 0.0 % |
      | meta0 | 3–4 | 1 | 4 | 0.01 | 0.01 | 0.01 | 0.0 % | 0.0 % | 0.0 % |
      | nocopy | 0 | 1 | 0 | — | — | — | — | — | — |
      | nocopy | 1–2 | 2 | 6 | 0 | 0 | 0 | 0.0 % | 0.0 % | 100.0 % |

      #### Elites

      Runs without elites: meta0.

      | Run | Window | Generations | Networks | Median of medians | 10th percentile | 90th percentile | Within 1 % of 0.0001 | Within 1 % of 0.1 | Exactly 0 |
      | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
      | elite | 0 | 1 | 0 | — | — | — | — | — | — |
      | elite | 1–2 | 2 | 2 | 0.01 | 0.01 | 0.01 | 0.0 % | 0.0 % | 0.0 % |
      | elite | 3–4 | 2 | 2 | 0.01 | 0.01 | 0.01 | 0.0 % | 0.0 % | 0.0 % |
      | elite | 5–6 | 1 | 1 | 0.01 | 0.01 | 0.01 | 0.0 % | 0.0 % | 0.0 % |
      | nocopy | 0 | 1 | 0 | — | — | — | — | — | — |
      | nocopy | 1–2 | 2 | 2 | 0 | 0 | 0 | 0.0 % | 0.0 % | 100.0 % |

      ### weight_changes

      #### All networks

      | Run | Window | Generations | Networks | Median of medians | 10th percentile | 90th percentile | Within 1 % of 1 |
      | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
      | elite | 0 | 1 | 6 | 100 | 100 | 100 | 0.0 % |
      | elite | 1–2 | 2 | 12 | 100 | 1 | 100 | 25.0 % |
      | elite | 3–4 | 2 | 12 | 100 | 1 | 100 | 16.7 % |
      | elite | 5–6 | 1 | 6 | 100 | 1 | 100 | 16.7 % |
      | meta0 | 0 | 1 | 4 | 229 | 229 | 229 | 0.0 % |
      | meta0 | 1–2 | 2 | 8 | 229 | 229 | 229 | 0.0 % |
      | meta0 | 3–4 | 1 | 4 | 229 | 229 | 229 | 0.0 % |
      | nocopy | 0 | 1 | 4 | 229 | 229 | 229 | 0.0 % |
      | nocopy | 1–2 | 2 | 8 | 229 | 229 | 229 | 0.0 % |

      #### Bred children

      | Run | Window | Generations | Networks | Median of medians | 10th percentile | 90th percentile | Within 1 % of 1 |
      | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
      | elite | 0 | 1 | 0 | — | — | — | — |
      | elite | 1–2 | 2 | 10 | 100 | 1 | 100 | 30.0 % |
      | elite | 3–4 | 2 | 10 | 100 | 1 | 100 | 20.0 % |
      | elite | 5–6 | 1 | 5 | 100 | 100 | 100 | 0.0 % |
      | meta0 | 0 | 1 | 0 | — | — | — | — |
      | meta0 | 1–2 | 2 | 8 | 229 | 229 | 229 | 0.0 % |
      | meta0 | 3–4 | 1 | 4 | 229 | 229 | 229 | 0.0 % |
      | nocopy | 0 | 1 | 0 | — | — | — | — |
      | nocopy | 1–2 | 2 | 6 | 229 | 229 | 229 | 0.0 % |

      #### Elites

      Runs without elites: meta0.

      | Run | Window | Generations | Networks | Median of medians | 10th percentile | 90th percentile | Within 1 % of 1 |
      | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
      | elite | 0 | 1 | 0 | — | — | — | — |
      | elite | 1–2 | 2 | 2 | 100 | 100 | 100 | 0.0 % |
      | elite | 3–4 | 2 | 2 | 1.02 | 1.02 | 1.02 | 0.0 % |
      | elite | 5–6 | 1 | 1 | 1 | 1 | 1 | 100.0 % |
      | nocopy | 0 | 1 | 0 | — | — | — | — |
      | nocopy | 1–2 | 2 | 2 | 229 | 229 | 229 | 0.0 % |

      ### weight_step

      #### All networks

      | Run | Window | Generations | Networks | Median of medians | 10th percentile | 90th percentile | Within 1 % of 0.0001 | Within 1 % of 10 |
      | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
      | elite | 0 | 1 | 6 | 0.35 | 0.1 | 0.6 | 0.0 % | 0.0 % |
      | elite | 1–2 | 2 | 12 | 0.175 | 0.000101 | 0.4 | 16.7 % | 8.3 % |
      | elite | 3–4 | 2 | 12 | 0.0501 | 0.000101 | 2 | 25.0 % | 0.0 % |
      | elite | 5–6 | 1 | 6 | 0.075 | 0.000102 | 3 | 0.0 % | 0.0 % |
      | meta0 | 0 | 1 | 4 | 0.5 | 0.5 | 0.5 | 0.0 % | 0.0 % |
      | meta0 | 1–2 | 2 | 8 | 0.5 | 0.5 | 0.5 | 0.0 % | 0.0 % |
      | meta0 | 3–4 | 1 | 4 | 0.5 | 0.5 | 0.5 | 0.0 % | 0.0 % |
      | nocopy | 0 | 1 | 4 | 0.35 | 0.2 | 0.5 | 0.0 % | 0.0 % |
      | nocopy | 1–2 | 2 | 8 | 0.382 | 0.25 | 0.45 | 0.0 % | 0.0 % |

      #### Bred children

      | Run | Window | Generations | Networks | Median of medians | 10th percentile | 90th percentile | Within 1 % of 0.0001 | Within 1 % of 10 |
      | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
      | elite | 0 | 1 | 0 | — | — | — | — | — |
      | elite | 1–2 | 2 | 10 | 0.175 | 0.0001 | 0.3 | 20.0 % | 10.0 % |
      | elite | 3–4 | 2 | 10 | 0.1 | 0.0001 | 2 | 10.0 % | 0.0 % |
      | elite | 5–6 | 1 | 5 | 0.07 | 0.000102 | 3 | 0.0 % | 0.0 % |
      | meta0 | 0 | 1 | 0 | — | — | — | — | — |
      | meta0 | 1–2 | 2 | 8 | 0.5 | 0.5 | 0.5 | 0.0 % | 0.0 % |
      | meta0 | 3–4 | 1 | 4 | 0.5 | 0.5 | 0.5 | 0.0 % | 0.0 % |
      | nocopy | 0 | 1 | 0 | — | — | — | — | — |
      | nocopy | 1–2 | 2 | 6 | 0.365 | 0.25 | 0.45 | 0.0 % | 0.0 % |

      #### Elites

      Runs without elites: meta0.

      | Run | Window | Generations | Networks | Median of medians | 10th percentile | 90th percentile | Within 1 % of 0.0001 | Within 1 % of 10 |
      | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
      | elite | 0 | 1 | 0 | — | — | — | — | — |
      | elite | 1–2 | 2 | 2 | 0.25 | 0.1 | 0.4 | 0.0 % | 0.0 % |
      | elite | 3–4 | 2 | 2 | 0.000101 | 0.000101 | 0.000101 | 100.0 % | 0.0 % |
      | elite | 5–6 | 1 | 1 | 0.15 | 0.15 | 0.15 | 0.0 % | 0.0 % |
      | nocopy | 0 | 1 | 0 | — | — | — | — | — |
      | nocopy | 1–2 | 2 | 2 | 0.4 | 0.4 | 0.4 | 0.0 % | 0.0 % |

      ### activation_rate

      #### All networks

      | Run | Window | Generations | Networks | Median of medians | 10th percentile | 90th percentile | Within 1 % of 0.0001 | Within 1 % of 0.5 |
      | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
      | elite | 0 | 1 | 6 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |
      | elite | 1–2 | 2 | 12 | 0.02 | 0.02 | 0.02 | 0.0 % | 8.3 % |
      | elite | 3–4 | 2 | 12 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |
      | elite | 5–6 | 1 | 6 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |
      | meta0 | 0 | 1 | 4 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |
      | meta0 | 1–2 | 2 | 8 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |
      | meta0 | 3–4 | 1 | 4 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |
      | nocopy | 0 | 1 | 4 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |
      | nocopy | 1–2 | 2 | 8 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |

      #### Bred children

      | Run | Window | Generations | Networks | Median of medians | 10th percentile | 90th percentile | Within 1 % of 0.0001 | Within 1 % of 0.5 |
      | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
      | elite | 0 | 1 | 0 | — | — | — | — | — |
      | elite | 1–2 | 2 | 10 | 0.02 | 0.02 | 0.02 | 0.0 % | 10.0 % |
      | elite | 3–4 | 2 | 10 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |
      | elite | 5–6 | 1 | 5 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |
      | meta0 | 0 | 1 | 0 | — | — | — | — | — |
      | meta0 | 1–2 | 2 | 8 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |
      | meta0 | 3–4 | 1 | 4 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |
      | nocopy | 0 | 1 | 0 | — | — | — | — | — |
      | nocopy | 1–2 | 2 | 6 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |

      #### Elites

      Runs without elites: meta0.

      | Run | Window | Generations | Networks | Median of medians | 10th percentile | 90th percentile | Within 1 % of 0.0001 | Within 1 % of 0.5 |
      | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
      | elite | 0 | 1 | 0 | — | — | — | — | — |
      | elite | 1–2 | 2 | 2 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |
      | elite | 3–4 | 2 | 2 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |
      | elite | 5–6 | 1 | 1 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |
      | nocopy | 0 | 1 | 0 | — | — | — | — | — |
      | nocopy | 1–2 | 2 | 2 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |

      ### structure_rate

      #### All networks

      | Run | Window | Generations | Networks | Median of medians | 10th percentile | 90th percentile | Within 1 % of 0.0001 | Within 1 % of 0.5 |
      | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
      | elite | 0 | 1 | 6 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |
      | elite | 1–2 | 2 | 12 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |
      | elite | 3–4 | 2 | 12 | 0.02 | 0.02 | 0.02 | 8.3 % | 0.0 % |
      | elite | 5–6 | 1 | 6 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |
      | meta0 | 0 | 1 | 4 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |
      | meta0 | 1–2 | 2 | 8 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |
      | meta0 | 3–4 | 1 | 4 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |
      | nocopy | 0 | 1 | 4 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |
      | nocopy | 1–2 | 2 | 8 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |

      #### Bred children

      | Run | Window | Generations | Networks | Median of medians | 10th percentile | 90th percentile | Within 1 % of 0.0001 | Within 1 % of 0.5 |
      | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
      | elite | 0 | 1 | 0 | — | — | — | — | — |
      | elite | 1–2 | 2 | 10 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |
      | elite | 3–4 | 2 | 10 | 0.02 | 0.0001 | 0.02 | 10.0 % | 0.0 % |
      | elite | 5–6 | 1 | 5 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |
      | meta0 | 0 | 1 | 0 | — | — | — | — | — |
      | meta0 | 1–2 | 2 | 8 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |
      | meta0 | 3–4 | 1 | 4 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |
      | nocopy | 0 | 1 | 0 | — | — | — | — | — |
      | nocopy | 1–2 | 2 | 6 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |

      #### Elites

      Runs without elites: meta0.

      | Run | Window | Generations | Networks | Median of medians | 10th percentile | 90th percentile | Within 1 % of 0.0001 | Within 1 % of 0.5 |
      | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
      | elite | 0 | 1 | 0 | — | — | — | — | — |
      | elite | 1–2 | 2 | 2 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |
      | elite | 3–4 | 2 | 2 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |
      | elite | 5–6 | 1 | 1 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |
      | nocopy | 0 | 1 | 0 | — | — | — | — | — |
      | nocopy | 1–2 | 2 | 2 | 0.02 | 0.02 | 0.02 | 0.0 % | 0.0 % |

      ### feature_step

      #### All networks

      | Run | Window | Generations | Networks | Median of medians | 10th percentile | 90th percentile | Within 1 % of 0.0001 | Within 1 % of 1 |
      | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
      | elite | 0 | 1 | 6 | 0.01 | 0.01 | 0.01 | 0.0 % | 0.0 % |
      | elite | 1–2 | 2 | 12 | 0.01 | 0.01 | 0.01 | 0.0 % | 0.0 % |
      | elite | 3–4 | 2 | 12 | 0.01 | 0.01 | 1 | 0.0 % | 25.0 % |
      | elite | 5–6 | 1 | 6 | 0.01 | 0.01 | 1 | 0.0 % | 16.7 % |
      | meta0 | 0 | 1 | 4 | 0.01 | 0.01 | 0.01 | 0.0 % | 0.0 % |
      | meta0 | 1–2 | 2 | 8 | 0.01 | 0.01 | 0.01 | 0.0 % | 0.0 % |
      | meta0 | 3–4 | 1 | 4 | 0.01 | 0.01 | 0.01 | 0.0 % | 0.0 % |
      | nocopy | 0 | 1 | 4 | 0.01 | 0.01 | 0.01 | 0.0 % | 0.0 % |
      | nocopy | 1–2 | 2 | 8 | 0.01 | 0.01 | 0.01 | 0.0 % | 0.0 % |

      #### Bred children

      | Run | Window | Generations | Networks | Median of medians | 10th percentile | 90th percentile | Within 1 % of 0.0001 | Within 1 % of 1 |
      | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
      | elite | 0 | 1 | 0 | — | — | — | — | — |
      | elite | 1–2 | 2 | 10 | 0.01 | 0.01 | 0.01 | 0.0 % | 0.0 % |
      | elite | 3–4 | 2 | 10 | 0.01 | 0.01 | 1 | 0.0 % | 30.0 % |
      | elite | 5–6 | 1 | 5 | 0.01 | 0.01 | 1 | 0.0 % | 20.0 % |
      | meta0 | 0 | 1 | 0 | — | — | — | — | — |
      | meta0 | 1–2 | 2 | 8 | 0.01 | 0.01 | 0.01 | 0.0 % | 0.0 % |
      | meta0 | 3–4 | 1 | 4 | 0.01 | 0.01 | 0.01 | 0.0 % | 0.0 % |
      | nocopy | 0 | 1 | 0 | — | — | — | — | — |
      | nocopy | 1–2 | 2 | 6 | 0.01 | 0.01 | 0.01 | 0.0 % | 0.0 % |

      #### Elites

      Runs without elites: meta0.

      | Run | Window | Generations | Networks | Median of medians | 10th percentile | 90th percentile | Within 1 % of 0.0001 | Within 1 % of 1 |
      | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
      | elite | 0 | 1 | 0 | — | — | — | — | — |
      | elite | 1–2 | 2 | 2 | 0.01 | 0.01 | 0.01 | 0.0 % | 0.0 % |
      | elite | 3–4 | 2 | 2 | 0.01 | 0.01 | 0.01 | 0.0 % | 0.0 % |
      | elite | 5–6 | 1 | 1 | 0.01 | 0.01 | 0.01 | 0.0 % | 0.0 % |
      | nocopy | 0 | 1 | 0 | — | — | — | — | — |
      | nocopy | 1–2 | 2 | 2 | 0.01 | 0.01 | 0.01 | 0.0 % | 0.0 % |

      ## Structural changes and shapes

      Per run and window: the bred children, how many had a structural change (structure set and not none; crossovers, copies and elites store none), and the distinct shapes (hidden layers by width) among all the window's networks.

      | Run | Window | Generations | Bred children | Structural changes | Distinct shapes |
      | --- | ---: | ---: | ---: | ---: | ---: |
      | elite | 0 | 1 | 0 | 0 | 1 |
      | elite | 1–2 | 2 | 10 | 1 | 2 |
      | elite | 3–4 | 2 | 10 | 2 | 2 |
      | elite | 5–6 | 1 | 5 | 0 | 1 |
      | meta0 | 0 | 1 | 0 | 0 | 1 |
      | meta0 | 1–2 | 2 | 8 | 1 | 2 |
      | meta0 | 3–4 | 1 | 4 | 0 | 2 |
      | nocopy | 0 | 1 | 0 | 0 | 1 |
      | nocopy | 1–2 | 2 | 6 | 1 | 2 |

      ## Clones

      Bred children that equal a parent or come from one parent alone, per run and window. Copies: operator copy. Self-crossovers: crossovers of a network with itself (first_parent = second_parent). Differs 0: crossovers whose differs count against the picked parent (the differs_from_first or differs_from_second column that parent names) is 0. A parent's genome: crossovers whose genome equals either parent's (exact clones, feature weights and genes included). The three crossover columns nest, each within the next (a crossover can also have the genome of the parent not picked), so they are never to be added. Exact clones: copies plus crossovers with a parent's genome.

      | Run | Window | Generations | Bred children | Copies | Self-crossovers | Differs 0 | A parent's genome | Exact clones |
      | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
      | elite | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 |
      | elite | 1–2 | 2 | 10 | 1 | 1 | 2 | 3 | 4 |
      | elite | 3–4 | 2 | 10 | 1 | 2 | 3 | 3 | 4 |
      | elite | 5–6 | 1 | 5 | 1 | 0 | 0 | 1 | 2 |
      | meta0 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 |
      | meta0 | 1–2 | 2 | 8 | 1 | 1 | 2 | 2 | 3 |
      | meta0 | 3–4 | 1 | 4 | 1 | 0 | 0 | 1 | 2 |
      | nocopy | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 |
      | nocopy | 1–2 | 2 | 6 | 0 | 1 | 1 | 1 | 1 |

      Crossovers outside that nesting (a self-crossover without differs 0, or differs 0 without a parent's genome): elite 0, meta0 0, nocopy 0.

      ## No network weight changed

      Counted apart from the clones, and neither as clones nor as not clones: mutation children whose differs count against their picked parent is 0, with no structural or activation change. No network weight changed; feature weights and genes may differ from the parent's (the feature-weight change is below); whether they play like the parent is not measured. Per run and window, of each such child's largest feature-weight change against its picked parent (its fw_* columns against the parent's, where both have one), the median and the maximum. stats' Copies column counts them.

      | Run | Window | Generations | Mutation children | No network weight changed | Largest feature-weight change, median | Largest feature-weight change, maximum |
      | --- | ---: | ---: | ---: | ---: | ---: | ---: |
      | elite | 0 | 1 | 0 | 0 | — | — |
      | elite | 1–2 | 2 | 5 | 1 | 0.007 | 0.007 |
      | elite | 3–4 | 2 | 5 | 2 | 0.0016 | 0.003 |
      | elite | 5–6 | 1 | 3 | 1 | 0.05 | 0.05 |
      | meta0 | 0 | 1 | 0 | 0 | — | — |
      | meta0 | 1–2 | 2 | 4 | 1 | 0.01 | 0.01 |
      | meta0 | 3–4 | 1 | 2 | 1 | 0.02 | 0.02 |
      | nocopy | 0 | 1 | 0 | 0 | — | — |
      | nocopy | 1–2 | 2 | 4 | 1 | 0.0042 | 0.0042 |
    REPORT
  end

  # Elites are told by their operator alone: meta0, at schema 17, has no
  # elite_share setting.
  def test_a_report_without_elites
    report = G.report(runs('meta0'))
    assert_includes report, "Elites (births with operator elite) in the generations kept: meta0 none.\n"
    assert_includes report, "#### Elites\n\nNo run has elites.\n\n### weight_changes\n"
    refute_includes report, 'Runs without elites'
  end

  # Nearest rank: the smallest value with at least that share of the
  # values at or below it.
  def test_percentiles_by_nearest_rank_and_medians
    twenty = (1..20).to_a
    assert_equal [2, 18], [G.percentile(twenty, 1 / 10r), G.percentile(twenty, 9 / 10r)]
    ten = (1..10).to_a
    assert_equal [1, 9], [G.percentile(ten, 1 / 10r), G.percentile(ten, 9 / 10r)]
    assert_equal [7, 7], [G.percentile([7], 1 / 10r), G.percentile([7], 9 / 10r)]
    assert_equal [2.5, 2], [G.median([1, 2, 3, 4]), G.median([1, 2, 3])]
  end

  def test_clamps
    assert_equal :zero, G.clamp('copy_chance', 0.0)
    assert_equal :min, G.clamp('copy_chance', 1e-4)
    assert_equal :min, G.clamp('copy_chance', 1.0099e-4)
    assert_nil G.clamp('copy_chance', 1.02e-4)
    assert_equal :max, G.clamp('copy_chance', 0.0991)
    assert_nil G.clamp('copy_chance', 0.098)
    assert_equal :min, G.clamp('weight_changes', 1.0)
    assert_nil G.clamp('weight_changes', 1e6)
    assert_equal :max, G.clamp('weight_step', 9.91)
    assert_nil G.clamp('weight_step', 9.8)
    assert_equal :max, G.clamp('activation_rate', 0.5)
    assert_equal :min, G.clamp('structure_rate', 1e-4)
    assert_equal :max, G.clamp('feature_step', 1.0)
    assert_nil G.clamp('feature_step', 0.98)
  end

  # From 100 on, a whole number: three significant figures would print
  # 999.7 as 1e+03.
  def test_numbers
    assert_equal %w[0 229 1000 1235 0.000101 0.01 0.0016 1.02 1],
                 [0.0, 229.3128, 999.7, 1234.6, 0.0001009, 0.010000000000000002, 0.0016, 1.02, 1.005].map { |v| G.number(v) }
  end

  def birth(child, **fields)
    { child:, operator: 'crossover', first_parent: 'a', second_parent: 'b', parent: 'first', differs_from_first: 3,
      differs_from_second: 4, genome: "g-#{child}", structure: 'none', activation_changed: false, layers: 10,
      width: 200, copy_chance: 0.01, weight_changes: 100.0, weight_step: 0.5, activation_rate: 0.02,
      structure_rate: 0.02, feature_step: 0.01, **F::FEATURE_WEIGHTS.to_h { |column| [column, 0.5] } }.merge(fields)
  end

  # By how evolve breeds, a self-crossover has differs 0 against its
  # picked parent and such a crossover the parent's genome; the report
  # counts the crossovers for which that does not hold.
  def test_crossovers_outside_the_nesting
    previous = { 'a' => birth('a', genome: 'ga'), 'b' => birth('b', genome: 'gb') }
    births = [birth('0.ann', second_parent: 'a', differs_from_first: 2, differs_from_second: 2),
              birth('1.ann', differs_from_first: 0, genome: 'other'),
              birth('2.ann', differs_from_first: 0, genome: 'ga'),
              birth('3.ann', differs_from_second: 0, genome: 'gb')]
    figures = G.generation(1, births, previous)
    assert_equal [1, 2, 2, 2], [figures.self_crossovers, figures.differs_zero, figures.parent_genome, figures.outside_nesting]
    elite, meta0 = runs('elite', 'meta0')
    outside = elite.with(windows: elite.windows.map { |window| window.with(outside_nesting: window.outside_nesting + 1) })
    assert_includes G.report([outside, meta0]), "\n\nCrossovers outside that nesting (a self-crossover without differs 0, " \
                                                "or differs 0 without a parent's genome): elite 4, meta0 0.\n\n"
  end

  # A mutation child with differs 0 against its picked parent changed no
  # network weight only without a structural or activation change. (evolve
  # stores a structural change's differs as NULL, a change of shape, so the
  # first case pins the rule rather than data evolve writes.)
  def test_no_network_weight_changed_needs_no_structural_or_activation_change
    previous = { 'a' => birth('a'), 'b' => birth('b', fw_cut: 0.9) }
    births = [birth('0.ann', operator: 'mutation', differs_from_first: 0, structure: 'widen'),
              birth('1.ann', operator: 'mutation', differs_from_first: 0, activation_changed: true),
              birth('2.ann', operator: 'mutation', parent: 'second', differs_from_first: 0, differs_from_second: 5),
              birth('3.ann', operator: 'mutation', parent: 'second', differs_from_second: 0, fw_cut: 0.85, fw_edge: 0.48)]
    figures = G.generation(1, births, previous)
    assert_equal 4, figures.mutations
    assert_equal [0.05], figures.no_weight_changes.map { |change| change.round(12) }
  end

  def test_refuses_what_it_cannot_describe
    error = assert_raises(G::Refused) { G.generation(3, [birth('0.ann', second_parent: 'c')], { 'a' => birth('a') }) }
    assert_equal 'generation 3: 0.ann has no parent c in generation 2', error.message
    error = assert_raises(G::Refused) { G.generation(3, [birth('0.ann', weight_step: nil)], { 'a' => birth('a'), 'b' => birth('b') }) }
    assert_equal 'generation 3: 0.ann has no weight_step', error.message
    elite, = runs('elite')
    error = assert_raises(G::Refused) { G.report([elite, elite]) }
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
    paths = [F.path('elite'), F.path('meta0')]
    before = paths.map { |path| File.binread(path) }
    out, err, status = Open3.capture3(RbConfig.ruby, SCRIPT, *paths)
    assert status.success?, err
    assert_equal G.report(runs('elite', 'meta0', width: 50)), out
    assert_includes out, "then 50 generations each (1–50, 51–100, …)."
    assert_includes out, "\n| elite | 1–50 | 5 | 30 | 0.0751 | 0.000101 | 2 | 16.7 % | 3.3 % |\n"
    assert_equal before, paths.map { |path| File.binread(path) }
    paths.each { |path| refute File.exist?("#{path}-journal") || File.exist?("#{path}-wal") }
  end

  def test_the_script_takes_a_window
    out, err, status = Open3.capture3(RbConfig.ruby, SCRIPT, '--window', '3', F.path('elite'))
    assert status.success?, err
    assert_equal G.report(runs('elite', width: 3)), out
    assert_includes out, "\n| elite | 4–6 | 2 | 10 | 1 | 2 | 2 | 3 | 4 |\n"
  end

  def test_the_script_needs_a_database_and_a_whole_window
    ['', '--window 0', '--window 2.5', '--colour'].each do |arguments|
      _out, err, status = Open3.capture3(RbConfig.ruby, SCRIPT, *arguments.split, *(F.path('elite') unless arguments.empty?))
      refute status.success?, arguments
      assert_match(/usage: scripts\/gene-trajectories.rb \[--window W\] DATABASE\.\.\.\n\z/, err, arguments)
    end
  end
end
