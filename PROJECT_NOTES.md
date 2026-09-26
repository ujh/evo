# Evo: open work

This file lists only work still to do: defects, cleanup, proposed experiments, and open questions. Delete an item when a change finishes it. Facts a future agent needs go into `CLAUDE.md`.

**Proposed first milestone:** repeatable improvement on a small board, under a fixed and trustworthy evaluation procedure.

**Current recommendation:** test evolution of a shared local pattern scorer, with the [cleanup](#code-cleanup) alongside. Treat search as a possible follow-on that needs its own control experiment.

## What most affects the experiment

### 1. Fitness needs a clearer meaning

The tournament has a useful idea: match roughly comparable players while including fixed external bots. However, different networks can face very different schedules, colors are randomized rather than paired, and repeat pairings are allowed. A tournament score measures success in that particular schedule; it is not a stable measure of strength across generations. The benchmark (see `CLAUDE.md`) measures strength instead.

**Proposed experiment:** now that progress is measured apart from the tournament, test whether bots belong in the tournament at all. Compare an experiment with the default `opponents` panel against one with an empty `opponents` table, on the benchmark, at equal game budgets. If the bot-free run drifts or cycles (the usual coevolution pathologies), try a hall of fame of frozen past champions in the tournament instead; games between networks are cheap, since the arena plays them (see `CLAUDE.md`).

### 2. Selection pressure is a guess

Parents are chosen by tournament selection with a default size of 3 (`tournament_size`). Nothing yet shows whether that keeps enough variation or selects too weakly to make progress.

**Proposed response:** measure it with the [recorded data](#6-test-the-assumptions-with-the-recorded-data) below, compare a few tournament sizes, and consider preserving a small number of elites.

### 3. Mutation and crossover deserve separate experiments

A mutated child changes each weight with probability `weight_changes / total_weights`, by a uniform amount within `±weight_step`, and with probability `copy_chance` a child is an unchanged copy instead. All three are genes of each network (see the last paragraph). Because `weight_changes` is a count, the expected number of changed weights per child does not grow with the network. With few changes per child, many children differ from their parent in only a weight or two, and changes in weights can also leave the chosen moves unchanged, so genetic and behavioral diversity are different measurements.

Crossover and mutation are mutually exclusive in `breed()` (`evolve/evolve.c`), and parents of different shapes always give a mutation. Increasing the crossover rate reduces the number of mutation attempts. Crossing identical parents produces an identical child, which becomes relevant if selection concentrates the population.

Crossing raw weight arrays also assumes that hidden units occupy compatible roles in both parents. They need not: equivalent networks can place their internal features in different orders. This is a known issue discussed in the [original NEAT paper](https://nn.cs.utexas.edu/downloads/papers/stanley.ec02.pdf). Whether it is a major problem for Evo should be measured rather than assumed.

**Proposed response:** establish a mutation-only baseline and compare it with the present crossover scheme at equal game budgets. Treat the number of mutated weights and the size of each perturbation as separate controls. The share of unchanged children is recorded in `births`; optionally also measure their move agreement on a small bank of positions.

The genes start from the `initial_*` settings (defaults: `copy_chance` 1%, 0.0004 weight changes per weight, `weight_step` ±0.5) and adapt at the pace of `meta_rate`. None of those values was chosen from evidence. Question them in these experiments: compare starting values, and a `meta_rate` of 0 (fixed genes) against self-adaptation, at equal game budgets.

**Open question: do the self-adaptive genes drift to their clamps?** Under noisy selection a gene can drift toward a bound, for example `copy_chance` to its maximum of 0.1, which would make a tenth of the mutated children plain copies. A 20-generation seeded run with the default genes (9×9, 20 networks of 1×50, 5 rounds, 25 Sep 2026) hit no clamp, but the medians moved: `copy_chance` from 0.01 to about 0.005, `activation_rate` from 0.02 to about 0.01, `structure_rate` up to 0.04 and back to 0.016, `weight_changes` from 3.3 to 4.2, and `weight_step`'s median rose to about 0.74 around generations 14–17 and fell back to 0.48 (all births: 0.23–1.21). Only three structural changes and seven activation switches happened, and none spread: no generation had more than two networks with another activation or one with another shape than 1×50. Twenty generations cannot tell drift from selection. Watch the Genes table in longer runs; if genes reach a clamp, try a lower `meta_rate`, or fix `copy_chance` (and perhaps the other probabilities) while `weight_changes` and `weight_step` adapt. If shapes are to be explored, start with a higher `initial_structure_rate`.

### 4. The policy has to learn Go structure from very little guidance

The dense network receives a flat board and komi. It has no explicit liberties, capture features, previous-pass input, move history, or spatial weight sharing. The engine's legality checks handle immediate constraints, but the policy has no lookahead to examine consequences.

That makes a compact policy an interesting learning experiment, with substantial representational demands. In particular, a two-neuron hidden layer such as the bundled fixture compresses the whole board very aggressively; it should not be taken as a recommended training architecture.

None of the network's settings was chosen for a reason: the number and size of hidden layers, the hidden and output activations (sigmoid through a lookup table, for both), and the inputs and outputs. Generation 0's sizes and activations are experiment settings and defaults; from there, activations and sizes evolve as genes of each network. Cached sigmoid outputs, for one, create artificial score ties that favor earlier intersections or passing; a network that evolved a linear output layer would not have them.

**Proposed representation experiment:** use a small shared scorer for the 3×3 neighborhood around each candidate move. Run it early, alongside a short check of scoring and variation. Additional tactical features and search remain choices to discuss.

### 5. Long runs need recoverable evidence

Networks and SGFs are kept only for every `keep_every`-th generation. That saves space but limits comparisons with early ancestors to those generations. Each experiment keeps copies of its executables and records the code revision they came from.

**Proposed response:** also keep each generation's top-ranked network, if the `keep_every` generations turn out too sparse.

### 6. Test the assumptions with the recorded data

Many settings rest on assumptions nobody has checked: the tournament size, whether one point per win (bot or network) rewards the right games, the mutation rate and perturbation size, whether crossover helps, and how much a score depends on pairing and color rather than play. The experiment database records what is needed (`games`, `births`, and `rankings` in `experiment.sqlite3`), and `stats` reports it, including children per parent and where the bots rank. Still to do: run a few seeded experiments that vary one setting at a time.

### 7. Move choice is deterministic

A network always plays its highest-scoring allowed move, so the same two networks with the same colors play the same game every time, and a tie between saturated outputs always goes the same way (usually a pass). Repeat pairings in the tournament and benchmark games without openings therefore add no information.

**Idea to think about:** make the move choice a little random with a temperature parameter: pick among the allowed moves with probability proportional to `exp(score / T)`, so T near 0 comes close to today's behavior (except that today a tie goes to the pass or the lower index, while sampling would split it) and a larger T plays more varied moves. Questions before building it:

- Where the randomness comes from: a per-game seed passed to `evo` and the arena, derived from the experiment seed like the GNU Go seeds, so runs stay reproducible.
- Whether T applies to the tournament only, with the benchmark kept at T = 0 so checkpoints stay comparable, or to both.
- Whether T is an experiment setting or another gene that evolves per network.
- Whether the pass is one of the sampled moves, or keeps its own rule.
- Whether varied games make tournament scores less noisy (more distinct games per pairing) or just weaker (worse moves on purpose).

## Go rules and scoring boundary

Brown's internal final-status algorithm assumes the board has been filled according to Brown's original move policy. Evo can pass earlier, so those assumptions do not generally hold. The arena scores network games by Tromp–Taylor instead, but the GNU Go referee still decides every game with a bot and the whole benchmark.

Before treating results as reliable, specify the board size, suicide policy, ko rule, and how GNU Go adjudicates unfinished bot and benchmark games. The local engine uses simple ko and accepts suicide through `play`, although its generated moves exclude suicide. Those conventions should agree with the surrounding match system.

## Comparing the owner's two proposed directions

### Shared 3×3 move scoring

The proposed design evaluates each legal candidate with the same small network:

`local board pattern + optional tactical/context features → shared network → move score`

Sharing the network is the key assumption: an evolved preference for a local shape applies wherever that shape occurs. Encoding board boundaries distinctly from empty intersections and treating colors relative to the player makes the inputs meaningful at edges and for either side. Equivalent rotations and reflections can share an encoding as well, provided associated features are transformed consistently.

Appending separate pattern inputs to the existing dense whole-board network would expose local structure, but would not by itself enforce this reuse. A shared scorer keeps the number of learned parameters independent of board area for a fixed feature set, although it must be evaluated at each candidate. Actual move speed relative to the present architecture needs measurement.

Pure 3×3 occupancy cannot describe all tactical situations. A neighboring chain can extend beyond the window and have liberties elsewhere. A small number of optional features—such as whether the move captures, saves a chain in atari, or leaves the played chain with one liberty—would expose this information. Passing also needs an explicit mechanism with enough whole-board context. Which features to supply is still open.

This is the recommended first representation experiment. The hypothesis is that reusable local features make useful behavior easier to evolve. Success must be measured as improvement within this representation from its own initial population, and against random search using the same representation. A stronger starting policy alone would not demonstrate learning through evolution.

### A network inside UCT-style search

Search and local patterns can be combined. There are three distinct roles for a network:

| Network role | What it supplies | Implication for Evo |
| --- | --- | --- |
| Guide exploration | A preference over candidate moves when expanding a search node. | A local move scorer could provide these preferences; incorporating policy priors requires a corresponding tree-selection rule rather than plain UCT alone. |
| Guide rollouts | Move choices during simulated games. | Calls to the policy occur repeatedly inside simulations, making their speed and effect on rollout outcomes important. |
| Evaluate leaves | An estimate of who will win from a position. | Requires a position-value output with consistent player perspective; existing move scores do not supply this value. |

There is direct precedent for combining learned knowledge with Go search. Gelly and Silver's [Combining Online and Offline Knowledge in UCT](https://www.davidsilver.uk/wp-content/uploads/2020/03/combining_uct.pdf) examines simulation policies and prior knowledge in 9×9 Go. One relevant finding is that a stronger standalone policy did not necessarily make a better simulation policy. Their work used reinforcement learning, so it motivates an experiment here without establishing a result for evolution.

For this repository, search also needs a way to copy or restore full board state, correct treatment of simulation endings and ko, and reliable simulation scoring. The current Brown board state is stored in static arrays and exposes neither a snapshot API nor undo. Its inherited scorer cannot simply be used on arbitrary search leaves.

The recommendation is to consider using the local scorer to guide exploration after establishing a useful direct policy. A subsequent experiment must compare search with evolved guidance against the same search with uniform or frozen initial guidance. Use equal simulation budgets to study guidance quality, and equal elapsed-time budgets to measure practical benefit; report both. Search adds work per move, but whether it reduces total compute needed to reach a target strength is an empirical question.

### Slow experiments: identify the cost before choosing the remedy

Games between two networks run in the arena and cost almost nothing. Every game with a bot still launches a new GoGui process, two players, and a GNU Go referee, and that overhead is now nearly all of a profiled generation's game time (see "Performance" in `CLAUDE.md`): a median of 0.27 s per game, against 0.005 s in the arena. Once GNU Go opponents return through the ladder, each of their games takes about 7 s.

The tournament also plays games between copies of the same bot. Brown and AmiGo are deterministic, so such a game repeats itself and its point goes to whichever copy got the winning color. That adds noise to the bots' ranking, not information. (Games between different bots are intended; they place the bots in the ranking.)

Candidate remedies, to decide between:

- Skip pairings between two copies of the same bot. This is mainly for accuracy, but games between bots are also a large share of the remaining GoGui games (41 of 101 in the profile).
- Later, a ladder of opponents: add the next stronger bot only once the networks beat the strongest one in the panel. The panel starts with Brown (random moves) and AmiGo; it lives in each experiment's `opponents` table, which the runner reads every generation, so a ladder can add rows; next come GNU Go level 0, then GNU Go level 10. Bots in between would make the steps smaller, such as GNU Go levels 1–9, or Pachi or Fuego with a small playout limit; their order needs measuring first. Keep it simple until networks actually get past AmiGo. A changing panel changes what a tournament score means; the benchmark panel is stored apart (`benchmark_opponents`), so checkpoints stay comparable while the ladder moves.

The first experiment should have a comfortable elapsed-time cap and checkpoint results within that cap.

## Code cleanup

The code was written quickly as a side project. The C/Ruby split can stay. Protect each cleanup step with tests, so the experiments built on the code do not inherit its defects.

### Neural network library

GENANN stays: it is small, tested upstream, and does what the experiments need. It already has per-network hidden and output activations (sigmoid, cached sigmoid, linear, threshold, and since v1.1 `tanh` and ReLU). A shared 3×3 scorer is just a small GENANN network evaluated once per candidate, and inference is negligible next to adjudication, so batching is not needed. The `.ann` file records a network's sizes and both activations. What is still missing:

- **Scorer metadata.** The shared 3×3 scorer will need more in the file, such as its feature set and symmetry handling. Add it under a new format version.

GENANN's hidden layers must all have the same width; revisit that only if an experiment needs different widths.

## Proposed sequence

These are candidate milestones for discussion, rather than an implementation commitment.

0. **Clean up the code under test.** Carry out the remaining [cleanup](#code-cleanup) alongside milestone 1.
1. **Make a short experiment interpretable and affordable.** Choose 5×5 or 9×9 and the komi, and verify a short run can resume safely. Measure runtime per generation and the fraction of unchanged offspring.
2. **Test evolution with shared local patterns.** Use a compact scorer and a simple mutation-based evolutionary baseline. Compare it with random search using the same representation and game budget. Preserve the original dense-policy implementation as a reference; if comparing representations, use the same breeding procedure and account explicitly for differing genome sizes. Use several independent seeds; three is a practical starting point, not a guarantee of statistical confidence. Report raw game counts, uncertainty, elapsed time, and diversity. Reserve additional opponents or openings for final evaluation.
3. **Choose the next experiment from the evidence.** Operator comparisons, additional features, and UCT-style search are candidates. For search, test the contribution of evolved guidance against the same search without that guidance. If there is still no learning, use the measured offspring variation, lineage diversity, game records, and runtime breakdown to narrow the next change.

Repeated deterministic games from the same starting position do not provide independent evidence. Evaluation needs controlled variation in openings or opponent seeds, with color-balanced comparisons. Compare methods by games and compute consumed, not merely generation count.

A useful success statement would be: “Within an agreed CPU/time budget, evolution consistently beats equally budgeted random search and the initial population on opponents or positions not used to select parents.” A later milestone could name a particular external bot and a target win rate once baseline results exist.

### First experiment: proposed evidence target

There are two useful questions: do descendants play better than the initial population, and does breeding find better players than simply generating and evaluating more random networks? The second comparison helps distinguish useful inheritance from finding a lucky network through a larger search.

| Element | Proposal |
| --- | --- |
| Fixed conditions | Within an evolution-versus-random-search comparison, use the same board size, network architecture, rules, komi, and candidate evaluation procedure. Choose these before running the comparison. Representation comparisons are separate experiments. |
| Starting point | Save each run's initial population and select an initial champion using the training evaluation, without consulting the final test results. |
| Random-search control | Generate fresh random networks and retain the best found so far, using the same candidate evaluation budget as evolution. |
| Evolution conditions | Start with mutation-only breeding and record actual changed offspring so a mostly cloning population is visible. Compare crossover separately once the first experiment is informative. |
| Progress measurement | At predetermined checkpoints, measure champions against a fixed validation panel in both colors. Show game counts and uncertainty alongside the learning curve. |
| Final comparison | Compare the chosen policies against the initial champion and random-search champion on reserved opponents or openings. Repeat the entire experiment with independent seeds. |
| Decision | Look for improvement across runs and on reserved evaluations, rather than a single best tournament result. Agree on a practically meaningful gain and game budget before collecting the final results. |

This design remains provisional. The acceptable feature set and available compute should determine the experiment's scale.

## Later directions

Understanding evolution through measurable improvement is the chosen direction. These remain possible extensions once it has results:

| Direction | What it would emphasize | Main tradeoff |
| --- | --- | --- |
| Build an enjoyable opponent | Add useful Go features and potentially search, with evolution optimizing the policy or evaluator. | More strength may come from authored Go knowledge and search. |
| Explore evolving structures | Investigate topology evolution, indirect encodings, or program evolution after establishing a baseline. | Larger experimental and implementation scope. |

There is precedent for training substantial neural policies with genetic algorithms: [Such et al., Deep Neuroevolution](https://arxiv.org/abs/1712.06567) demonstrated this on Atari and locomotion tasks. That supports taking the idea seriously, but does not establish how well the present Go setup should learn or what compute it needs.

## Questions to settle together

- Should the owner's parked elitism and champion-retention work on [`wip/elitism-and-champion-retention`](https://github.com/ujh/evo/tree/wip/elitism-and-champion-retention) come back once selection is reworked and tested? Its commit message describes what it changes.
- Which network sizes, populations, and approximate runtimes were used before? Do historical results or champions exist elsewhere?
- For a shared 3×3 scorer, should the first version use occupancy patterns alone or also a few tactical features such as liberties and captures?
- What hardware, compute budget, and unattended runtime are comfortable for a single experiment?
- Which board size and first opponent would make a satisfying initial milestone?
- For the opponent ladder: what promotes a network to the next bot (for example, a win rate over a number of games in both colors, sustained for some generations), whether beaten bots leave the panel, and which bots fill the gaps?
- How much built-in Go knowledge (features, search) is acceptable before improvement no longer counts as coming from evolution?
