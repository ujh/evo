# Evo: open work

This file lists only work still to do: defects, cleanup, proposed experiments, and open questions. Delete an item when a change finishes it. Facts a future agent needs go into the relevant reference in `docs/`.

**Proposed first milestone:** repeatable improvement on a small board, under a fixed and trustworthy evaluation procedure.

**Current recommendation:** the longer `bigrun` and `even-bigger` experiments show improvement against AmiGo but leave a large gap to GNU Go level 0. Prioritize the arena speedup and tournament rework below, then find and calibrate a fast intermediate opponent and test whether low mutation rates limit further progress. Improve checkpoint comparisons and repeat controlled runs with several seeds before attributing a gain to a setting. Do the [cleanup](#code-cleanup) alongside. Treat search as a possible follow-on that needs its own control experiment.

**Further arena speedup and tournament rework:** Loading is faster but still costs about 1.5 s for one 250-game chunk of `even-bigger` (see `docs/performance.md`). Measure full-round and generation time, then consider keeping arenas alive across a generation's rounds so each network is loaded once. Check memory use, since each arena process could eventually load much of the population (4.59 GB of networks in `even-bigger`'s generation 0 and the large workload's generations, 4.89–4.91 GB in `even-bigger`'s generations 100–310), and preserve interruption and resume behavior. Profile the small and large experiments separately: bot games dominate `bigrun`'s recorded worker time, while arena games dominate `even-bigger`'s.

Move **all tournament games**, including network–bot and bot–bot games, into the arena. Give it a small GTP controller for external players (`boardsize`, `komi`, `clear_board`, `genmove`, `play`, `quit`; handle response framing and errors), so tournament games no longer launch GoGui or a GNU Go referee. Use the arena's Tromp–Taylor score for every tournament game; the owner accepts the possible difference from GNU Go's Chinese-rules adjudication. Keep the checkpoint benchmark's fixed procedure and referee so it remains comparable across runs. Work through these details when implementing it:

- Reuse the existing arena ending rule: two consecutive passes or the `max_moves` limit. The arena currently plays at most `max_moves + 1` moves, matching `gogui-twogtp`'s limit; passes count. Handle a bot's resignation, illegal move, GTP error, crash, or stalled response explicitly.
- Give each player the configured `game_length` of main time. Send `time_settings` and updated `time_left` to bots that support them, and maintain a monotonic clock and enforce the limit in the controller. Brown and AmiGo currently support neither time command, so telling the bot its allowance is insufficient. Decide and record how a time loss is scored.
- Preserve per-game seeds, color and move records, timings, SGFs at kept checkpoints, and interruption/resume behavior. A bot failure should remain a failed game rather than an undeserved network win. Record the new scorer and bump the tournament scoring-rules version; do not mix old and new rules within a started experiment. Measure the speedup on complete generations before adding more bots.

**Reduce the Ruby side of a tournament round for large populations.** Besides the games, the Ruby code that pairs networks, launches games, and records results has costs of its own (owner, 27 Sep 2026). Measured on the fixed workloads (`docs/performance.md`, 28 Sep 2026): with 1,000 networks the runner spends about 57 s of an 82–87 s tournament outside waiting for jobs, about 11 ms a game, and allocates about 240 million objects a generation, so it dominates the rounds; with 50 networks it is about 1.3 s and the bot games dominate. Find where the time goes, change it, and measure again on the large workload.

**Next step: benchmark against more past champions.** A checkpoint's benchmark plays only two networks: generation 0's champion (`initial_champion`) and the previous checkpoint's (`previous_checkpoint`). That makes progress hard to see (owner, 27 Sep 2026): a win against the previous checkpoint says little about the run as a whole, and a loss can hide steady gains against older champions. Play the top network against more of the earlier checkpoints' champions, or all of them, so each checkpoint gets a row of results against the whole line of its ancestors. Only checkpoint champions count, since theirs are the networks kept (owner, 27 Sep 2026). Open questions, to decide later:

Start by comparing the retained champions within each of `bigrun` and `even-bigger` out of band, across several openings with both colors, to see whether later checkpoints beat older ones consistently or cycle between strengths. Keep AmiGo and GNU Go as external anchors. Do not infer steady progress from the previous-checkpoint result alone, which has stayed near even while AmiGo results have risen and fallen.

- How many champions: all, or the last N, given the benchmark's cost.
- Whether games against past champions go to the arena instead of GoGui, which would make them nearly free. The scoring differs little: the referee's Chinese rules are area scoring too, and differ from the arena's Tromp–Taylor only where dead stones stay on the board (GNU Go removes them, Tromp–Taylor counts them), which happens often while networks pass early and less once they finish games. The arena lacks openings, though, which the benchmark needs because networks play deterministically; it would have to learn to start games from one.
- Whether to play these games inline at all. The checkpoint champions are kept anyway, so a separate analysis tool could play them later, out of band. The one reason to play them inline is that the results then show in the stats viewer (see [Replace `stats` with a graphical viewer](#replace-stats-with-a-graphical-viewer)) as the run goes.

## What most affects the experiment

### 1. Fitness needs a clearer meaning

The tournament has a useful idea: match roughly comparable players while including fixed external bots. However, different networks can face very different schedules, colors are randomized rather than paired, and repeat pairings are allowed. A tournament score measures success in that particular schedule; it is not a stable measure of strength across generations. The benchmark (see `docs/experiment-reference.md`) measures strength instead.

**Proposed experiment:** now that progress is measured apart from the tournament, test whether bots belong in the tournament at all. Compare an experiment with the default `opponents` panel against one with an empty `opponents` table, on the benchmark, at equal game budgets. If the bot-free run drifts or cycles (the usual coevolution pathologies), try a hall of fame of frozen past champions in the tournament instead; games between networks are cheap, since the arena plays them (see `docs/experiment-reference.md`).

### 2. Selection pressure is a guess

Parents are chosen by tournament selection with a default size of 3 (`tournament_size`). Nothing yet shows whether that keeps enough variation or selects too weakly to make progress.

**Proposed response:** measure it with the [recorded data](#6-test-the-assumptions-with-the-recorded-data) below, compare a few tournament sizes, and consider preserving a small number of elites. Re-evaluate top-ranked networks and some lower-ranked ones on the same independent openings to estimate how much the ten-game tournament schedule misorders parents and checkpoint champions.

### 3. Mutation and crossover deserve separate experiments

A mutated child changes each weight with probability `weight_changes / total_weights`, by a uniform amount within `±weight_step`, and with probability `copy_chance` a child is an unchanged copy instead. All three are genes of each network (see the last paragraph). Because `weight_changes` is a count, the expected number of changed weights per child does not grow with the network. With few changes per child, many children differ from their parent in only a weight or two, and changes in weights can also leave the chosen moves unchanged, so genetic and behavioral diversity are different measurements.

Crossover and mutation are mutually exclusive in `breed()` (`evolve/evolve.c`), and parents of different shapes always give a mutation. Increasing the crossover rate reduces the number of mutation attempts. Crossing identical parents produces an identical child, which becomes relevant if selection concentrates the population.

Crossing raw weight arrays also assumes that hidden units occupy compatible roles in both parents. They need not: equivalent networks can place their internal features in different orders. This is a known issue discussed in the [original NEAT paper](https://nn.cs.utexas.edu/downloads/papers/stanley.ec02.pdf). Whether it is a major problem for Evo should be measured rather than assumed.

**Proposed response:** establish a mutation-only baseline and compare it with the present crossover scheme at equal game budgets. Treat the number of mutated weights and the size of each perturbation as separate controls. The share of unchanged children is recorded in `births`; optionally also measure their move agreement on a small bank of positions.

The genes start from the `initial_*` settings (defaults: `copy_chance` 1%, 0.0004 weight changes per weight, `weight_step` ±0.5) and adapt at the pace of `meta_rate`. None of those values was chosen from evidence. Question them in these experiments: compare starting values, and a `meta_rate` of 0 (fixed genes) against self-adaptation, at equal game budgets.

**Open question: do the self-adaptive genes drift to their clamps?** Under noisy selection a gene can drift toward a bound, for example `copy_chance` to its maximum of 0.1, which would make a tenth of the mutated children plain copies. A 20-generation seeded run with the default genes (9×9, 20 networks of 1×50, 5 rounds, 25 Sep 2026) hit no clamp, but the medians moved: `copy_chance` from 0.01 to about 0.005, `activation_rate` from 0.02 to about 0.01, `structure_rate` up to 0.04 and back to 0.016, `weight_changes` from 3.3 to 4.2, and `weight_step`'s median rose to about 0.74 around generations 14–17 and fell back to 0.48 (all births: 0.23–1.21). Only three structural changes and seven activation switches happened, and none spread: no generation had more than two networks with another activation or one with another shape than 1×50. Twenty generations cannot tell drift from selection. The same settings with every feature group (26 Sep 2026; the stones-only run gave the numbers above again) also hit no clamp: `weight_changes` fell from 21.2 to 12.5, `weight_step` to about 0.34, and `structure_rate` to about 0.008, and `copy_chance` and `activation_rate` to about 0.008 and 0.016. Watch the Genes table in longer runs; if genes reach a clamp, try a lower `meta_rate`, or fix `copy_chance` (and perhaps the other probabilities) while `weight_changes` and `weight_step` adapt. If shapes are to be explored, start with a higher `initial_structure_rate`.

**Next diagnostic for structural exploration:** The larger ongoing run adopted an 11×200 shape from 10×200 early, but only 42 of 50,000 births in generations 100–149 changed structure. The longer small-population run also had stretches with almost no structural or activation changes. Low adaptive rates mean the runs scarcely test alternative shapes; they do not establish a local optimum. Compare a maintained minimum structural-change rate against the current self-adaptation, with other settings fixed, and measure both how many different shapes are tried and how often they survive. Test selection pressure, weight mutation size, and crossover separately rather than changing them together. Evaluate at equal generations as well as equal games and elapsed time.

**Proposed experiment: cross the rest of the genome apart from the weights.** A crossover child takes all of the non-weight genome (the mutation genes, both activations, the feature weights, and `feature_step`) from the picked parent, the one whose weights come first. Instead, cross it separately: for example take each gene from either parent at random, or average the numeric ones. These genes do not depend on the network's shape, so they could mix even between parents of different shapes, which today always give a mutation. Compare against the present scheme at equal game budgets.

**Settings that could become genes.** Candidates, each a proposed experiment:

- `cross_over_rate` as a per-network `crossover_chance`: the picked parent's decides, and it mutates on the logit scale like `copy_chance`. Pairs with crossing the rest of the genome (above).
- A pass bias added to the pass output's score, a move weight for passing, since saturated ties pass today.
- Move temperature (see item 7).
- Switching feature groups on or off per network. That changes the input count, so it blocks crossover between networks that differ; worth it only if a feature turns out to hurt.

The other settings define the experiment or its measurement and stay settings: the board, komi, move and time limits, population, rounds, seeds, the benchmark, the shape bounds, `tournament_size`, and `meta_rate` (the τ that evolution strategies usually keep fixed).

### 4. The policy has to learn Go structure from very little guidance

The dense network receives the board and komi, and, with feature groups, per-point shape and tactical features, chain liberties, the last move, and whether the opponent passed, plus shared feature weights added to its move scores (the `features` setting, `all` by default). A `features none` network has none of that: only a flat board and komi. Neither has more move history than the last move or spatial weight sharing. The engine's legality checks handle immediate constraints, but the policy has no lookahead to examine consequences.

That makes a compact policy an interesting learning experiment, with substantial representational demands. In particular, a two-neuron hidden layer such as the bundled fixture compresses the whole board very aggressively; it should not be taken as a recommended training architecture.

None of the network's settings was chosen for a reason: the number and size of hidden layers, the hidden and output activations (sigmoid through a lookup table, for both), and the inputs and outputs. Generation 0's sizes and activations are experiment settings and defaults; from there, activations and sizes evolve as genes of each network. Cached sigmoid outputs, for one, create artificial score ties that favor earlier intersections or passing; a network that evolved a linear output layer would not have them.

**Check whether the dense network still influences move choice.** In late `bigrun`, the population has tanh outputs (bounded by −1 and 1) while some added feature weights are around 7–10. This may make the feature terms decide many moves, even as the dense weights mutate. On a saved bank of positions, measure move agreement with the feature terms removed and with the dense output removed; inspect score margins and test the resulting policies on held-out games. Large feature weights alone do not establish that they hurt play.

Search remains a choice to discuss.

### 5. Long runs need recoverable evidence

Networks and SGFs are kept only for every `keep_every`-th generation. That saves space but limits comparisons with early ancestors to those generations. Each experiment keeps copies of its executables and records the code revision they came from.

**Proposed response:** also keep each generation's top-ranked network, if the `keep_every` generations turn out too sparse.

### 6. Test the assumptions with the recorded data

Many settings rest on assumptions nobody has checked: the tournament size, whether one point per win (bot or network) rewards the right games, the mutation rate and perturbation size, whether crossover helps, and how much a score depends on pairing and color rather than play. The experiment database records what is needed (`games`, `births`, and `rankings` in `experiment.sqlite3`), and `stats` reports it, including children per parent and where the bots rank. Still to do: run a few seeded experiments that vary one setting at a time.

**Investigate the color gap before tuning around it.** Against AmiGo after generation 0, `bigrun`'s checkpoint champions won 444/1,140 games as Black and 688/1,140 as White; `even-bigger` showed the same direction in its first four checkpoints (11/40 and 20/40). The benchmark pairs colors, so its combined rate is still useful, but these results call for checking outcomes by opening, game length, passing, and komi. Do not assume yet whether the cause is the policy, the openings, or the opponent.

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

### Go features: what is still open

The networks get 3×3 shapes, tactical features, the last move, and chain liberties as inputs and as feature weights that evolve (`docs/features.md`). One seeded 20-generation comparison with a stones-only run (26 Sep 2026, in `docs/features.md`) leaves these open:

- **Does the head start last, and does it help beyond Brown?** The feature run beat Brown 6–9 times in 10 against 0–5 for the stones-only run, but neither beat AmiGo or GNU Go level 0 at any checkpoint, and the feature run's checkpoints beat the previous one only 5 times in 10. One seed and 10 games per opponent: repeat with several seeds, more benchmark games, and longer runs (see "Proposed sequence" item 2).
- **The feature weights hardly evolve.** Their medians moved in the first five generations, faster than mutation can move them, so selection picked among generation 0's noise; afterwards they barely moved and `feature_step` fell from 0.01 to 0.005. Try a larger `initial_feature_step` or `initial_feature_noise`, and check whether selection, not the lineage that carries them, moves the weights (for example several seeds, or a run with the weights fixed at their starting values).
- **Which groups help?** The `features` setting takes single groups; compare them one at a time against `all` and `none`.
- Shapes only around the last move, instead of at every point, as MoGo used them.
- More move history than the last move: planes for how many turns ago each stone was played, as AlphaGo's inputs had.
- **Later: a `ladders` feature group.** Ladder capture and ladder escape per point, mainly for bigger boards, where ladders matter more. It needs a ladder reader on Brown's board: play the ladder out with trial moves and undo them with `brown_save`/`brown_restore`.

### A network inside UCT-style search

Search and local patterns can be combined. There are three distinct roles for a network:

| Network role | What it supplies | Implication for Evo |
| --- | --- | --- |
| Guide exploration | A preference over candidate moves when expanding a search node. | The network's move scores could provide these preferences; incorporating policy priors requires a corresponding tree-selection rule rather than plain UCT alone. |
| Guide rollouts | Move choices during simulated games. | Calls to the policy occur repeatedly inside simulations, making their speed and effect on rollout outcomes important. |
| Evaluate leaves | An estimate of who will win from a position. | Requires a position-value output with consistent player perspective; existing move scores do not supply this value. |

There is direct precedent for combining learned knowledge with Go search. Gelly and Silver's [Combining Online and Offline Knowledge in UCT](https://www.davidsilver.uk/wp-content/uploads/2020/03/combining_uct.pdf) examines simulation policies and prior knowledge in 9×9 Go. One relevant finding is that a stronger standalone policy did not necessarily make a better simulation policy. Their work used reinforcement learning, so it motivates an experiment here without establishing a result for evolution.

For this repository, search also needs a way to copy or restore full board state, correct treatment of simulation endings and ko, and reliable simulation scoring. Brown can save and restore its whole game state (`brown_save`/`brown_restore`), but has no incremental undo, so each restore copies about 4 kB. Its inherited scorer cannot simply be used on arbitrary search leaves.

The recommendation is to consider using the network's move scores to guide exploration after establishing a useful direct policy. A subsequent experiment must compare search with evolved guidance against the same search with uniform or frozen initial guidance. Use equal simulation budgets to study guidance quality, and equal elapsed-time budgets to measure practical benefit; report both. Search adds work per move, but whether it reduces total compute needed to reach a target strength is an empirical question.

### Slow experiments: identify the cost before choosing the remedy

Games between two networks run in the arena and cost almost nothing. Every game with a bot still launches a new GoGui process, two players, and a GNU Go referee, and that overhead is now nearly all of a profiled small generation's game time (see `docs/performance.md`): a median of 0.27 s per game, against 0.005 s in the arena. The large population spends most of its recorded worker time in arena games instead. Once GNU Go opponents return through the ladder, each of their games takes about 7 s under the current path. The arena tournament rework above targets the GoGui/referee overhead; it will not eliminate a bot's own thinking time.

The tournament also plays games between copies of the same bot. Brown and AmiGo are deterministic, so such a game repeats itself and its point goes to whichever copy got the winning color. That adds noise to the bots' ranking, not information. (Games between different bots are intended; they place the bots in the ranking.)

Other tournament improvements:

- Skip pairings between two copies of the same bot. This is mainly for accuracy, but games between bots are also a large share of the remaining GoGui games (41 of 101 in the profile).
- Later, a ladder of opponents: add the next stronger bot only once the networks beat the strongest one in the panel. The panel starts with Brown (random moves) and AmiGo; it lives in each experiment's `opponents` table, which the runner reads every generation, so a ladder can add rows. A measured intermediate bot should come before GNU Go level 0, then GNU Go level 10. Keep it simple until networks actually get past AmiGo. A changing panel changes what a tournament score means; the benchmark panel is stored apart (`benchmark_opponents`), so checkpoints stay comparable while the ladder moves.

The first experiment should have a comfortable elapsed-time cap and checkpoint results within that cap.

### More engines for the tournament

The opponent ladder needs bots between AmiGo and GNU Go, and beyond GNU Go once networks get there. Candidates: michi, Pachi, Fuego, GNU Go at levels 0–10, and others. GNU Go level 0 is already too strong here, so its higher levels are unlikely to fill the AmiGo-to-GNU-Go gap. First try an adjustable playout limit on Pachi or a C version of Michi. For each candidate, find out whether it builds on macOS (clang) and Linux (GCC), speaks the GTP commands the arena controller needs, accepts or ignores time controls, and how strong and fast each setting is on 9×9 (against AmiGo, GNU Go level 0, and the other candidates, with varied openings and both colours). Calibrate candidates in separate matches, then include a qualifying bot in new experiments' fixed benchmark panels before deciding whether to use it for tournament selection. Each one that qualifies goes into the external tools release (`scripts/external-tools.txt`) and the installer.

**Next: a fast bot stronger than AmiGo for the normal rounds.** GNU Go is strong but slow in our settings (about 7 s per game), and the networks do not need an opponent that strong yet (owner, 27 Sep 2026). Look for a bot that is somewhat stronger than AmiGo but plays quickly, and add it to the default `opponents` panel.

## Code cleanup

The code was written quickly as a side project. The C/Ruby split can stay. Protect each cleanup step with tests, so the experiments built on the code do not inherit its defects.

### Backwards compatibility

Old experiments need not keep working (owner, 26 Sep 2026). Find and remove the code that keeps them working, for example `scorer` defaulting rows from before migration 009 to `gnugo`, and `stats` handling gene columns missing before migration 010.

### Remove the `ranking` script

The owner finds `ranking` of little use (26 Sep 2026). Remove the script and every mention of it (`README.md`, docs, tests).

### Replace `stats` with a graphical viewer

`stats`' text tables are not useful as they are (owner, 26 Sep 2026). Replace them with a proper app, for example a web app run locally, that reads the experiment database read-only and shows graphs: benchmark results per checkpoint, gene and feature-weight trends, shapes and activations over time, and where the bots rank, plus whatever else turns out to be interesting. Open questions: the technology (a small local Ruby web server with a charting library, or something else), what to show, and whether the CSV output stays.

### `run`: compiling is probably no longer useful

`run` compiles the executables, but experiments now use their own copied-over executables (owner, 27 Sep 2026), so the build step is probably wasted. Check that nothing still depends on it, then remove it.

### Convert the C code to Rust?

Consider porting Evo's own C code to Rust, keeping the libraries it uses (such as GENANN and `pcg-c`) as they are and linking them rather than rewriting them (owner, 27 Sep 2026). The Rust compiler gives better error messages, and LLM-assisted work may go more smoothly there. The owner already wrote a Rust Go bot, [Iomrascálaí](https://github.com/ujh/iomrascalai) (GPL-3.0, last pushed January 2018, so pre-2018-edition Rust). Its board, rule set, scoring, GTP, and SGF modules may be reusable here (owner, 27 Sep 2026). Open questions: how much code that is, whether the tests carry over, and what it does to the build and CI.

### Neural network library

GENANN stays: it is small, tested upstream, and does what the experiments need. It already has per-network hidden and output activations (sigmoid, cached sigmoid, linear, threshold, and since v1.1 `tanh` and ReLU). Extra feature inputs only widen the input layer, and inference is negligible next to adjudication, so batching is not needed. The `.ann` file records a network's sizes, both activations, its genes, and its feature set with its feature weights (format version 2). GENANN's hidden layers must all have the same width; revisit that only if an experiment needs different widths.

## Proposed sequence

These are candidate milestones for discussion, rather than an implementation commitment.

0. **Clean up the code under test.** Carry out the remaining [cleanup](#code-cleanup) alongside milestone 1.
1. **Make a short experiment interpretable and affordable.** Choose 5×5 or 9×9 and the komi, and verify a short run can resume safely. Measure runtime per generation and the fraction of unchanged offspring.
2. **Measure the features' effect.** Compare a feature run with a stones-only run and with random search using the same inputs and game budget, with the same breeding procedure. Use several independent seeds; three is a practical starting point, not a guarantee of statistical confidence. Report raw game counts, uncertainty, elapsed time, and diversity. Reserve additional opponents or openings for final evaluation.
3. **Choose the next experiment from the evidence.** Operator comparisons, additional features, and UCT-style search are candidates. For search, test the contribution of evolved guidance against the same search without that guidance. If there is still no learning, use the measured offspring variation, lineage diversity, game records, and runtime breakdown to narrow the next change.

Repeated deterministic games from the same starting position do not provide independent evidence. Evaluation needs controlled variation in openings or opponent seeds, with color-balanced comparisons. Report progress at equal generations as well as equal games and compute consumed: `even-bigger` reached similar AmiGo benchmark performance in only 300 generations, but it also changed population size and architecture, so those effects need separate comparisons.

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

The goal is a strong player reached through evolution, and head starts such as features and search are part of it. These remain possible extensions:

| Direction | What it would emphasize | Main tradeoff |
| --- | --- | --- |
| Explore evolving structures | Investigate topology evolution, indirect encodings, or program evolution after establishing a baseline. | Larger experimental and implementation scope. |

There is precedent for training substantial neural policies with genetic algorithms: [Such et al., Deep Neuroevolution](https://arxiv.org/abs/1712.06567) demonstrated this on Atari and locomotion tasks. That supports taking the idea seriously, but does not establish how well the present Go setup should learn or what compute it needs.

## Questions to settle together

- Should the owner's parked elitism and champion-retention work on [`wip/elitism-and-champion-retention`](https://github.com/ujh/evo/tree/wip/elitism-and-champion-retention) come back once selection is reworked and tested? Its commit message describes what it changes.
- Which network sizes, populations, and approximate runtimes were used before? Do historical results or champions exist elsewhere?
- What hardware, compute budget, and unattended runtime are comfortable for a single experiment?
- Which board size and first opponent would make a satisfying initial milestone?
- For the opponent ladder: what promotes a network to the next bot (for example, a win rate over a number of games in both colors, sustained for some generations), whether beaten bots leave the panel, and which bots fill the gaps?
