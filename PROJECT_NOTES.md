# Evo: open work

This file lists only work still to do: defects, cleanup, proposed experiments, and open questions. Delete an item when a change finishes it. Facts a future agent needs go into the relevant reference in `docs/`.

**Proposed first milestone:** repeatable improvement on a small board, under a fixed and trustworthy evaluation procedure.

**Current recommendation:** the longer `bigrun` and `even-bigger` experiments (both deleted 30 Sep 2026; `even-bigger2` is the only one left) showed improvement against AmiGo but leave a large gap to GNU Go level 0. New experiments now play a calibrated ladder between AmiGo and GNU Go level 0 (three michi-c2 levels) and GNU Go level 0 itself in the tournament (`docs/experiment-reference.md`); next, run experiments with it and test whether low mutation rates limit further progress. Improve checkpoint comparisons and repeat controlled runs with several seeds before attributing a gain to a setting. Do the [cleanup](#code-cleanup) alongside. Treat search as a possible follow-on that needs its own control experiment.

**Reduce the Ruby side of a tournament round for large populations (only if it gets in the way again).** The runner's Ruby side is still O(population) work per game: `RunGeneration#update_data` re-sorts the whole ranking, `in_order?` and `ranking_moves` walk it, and the rank shift in `ExperimentDatabase#raise_in_ranking` scans the generation's `rankings` rows, which have no index on `rank`. Since `925e51a` the runner scores each record as it arrives, while the arenas play, and on the large workload at concurrency 3 that work no longer lengthens the tournament: it keeps the main thread busy 14–15 s of a 50–60 s tournament, and the tournament ends within 1 s of the summed worker time divided by 3 (`docs/performance.md`). It would matter again if the main thread fell behind the records, for example at a higher concurrency (at 8 it was busy 23–27 s of a 32–46 s tournament) or with more games a round: then a round's `round_K` rises well above `worker_round_K` divided by the concurrency. Candidates: move only the changed players in memory instead of re-sorting (the order must stay `update_data`'s), and an index on `(generation, rank)` (a new migration). Measure again on the large workload after any change; with 50 networks Ruby is under 1 s and not worth changing.

**Next step: benchmark against more past champions.** A checkpoint's benchmark plays only two networks: generation 0's champion (`initial_champion`) and the previous checkpoint's (`previous_checkpoint`). That makes progress hard to see (owner, 27 Sep 2026): a win against the previous checkpoint says little about the run as a whole, and a loss can hide steady gains against older champions. Play the top network against more of the earlier checkpoints' champions, or all of them, so each checkpoint gets a row of results against the whole line of its ancestors. Only checkpoint champions count, since theirs are the networks kept (owner, 27 Sep 2026). Open questions, to decide later:

Once `even-bigger2` (or a later run) has several checkpoints (`even-bigger2` keeps a champion every 100 generations), start by comparing its retained champions out of band, across several openings with both colors, to see whether later checkpoints beat older ones consistently or cycle between strengths. Keep AmiGo and GNU Go as external anchors. Do not infer steady progress from the previous-checkpoint result alone, which has stayed near even while AmiGo results have risen and fallen.

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

**Check whether the dense network still influences move choice.** In late `bigrun` (since deleted), the population had tanh outputs (bounded by −1 and 1) while some added feature weights were around 7–10. This may make the feature terms decide many moves, even as the dense weights mutate. On a saved bank of positions, measure move agreement with the feature terms removed and with the dense output removed; inspect score margins and test the resulting policies on held-out games. Large feature weights alone do not establish that they hurt play. Check first whether `even-bigger2`'s champions show the same pattern.

Search remains a choice to discuss.

### 5. Long runs need recoverable evidence

SGFs are kept only for every `keep_every`-th generation, and of its networks only one, the champion; the other networks of a generation are deleted once the next generation is bred, and an archived experiment (`mise run archive-experiment`) keeps the same champions. That saves space but limits comparisons with early ancestors to those champions. Each experiment keeps copies of its executables and records the code revision they came from.

**Proposed response:** also keep each generation's top-ranked network, if the `keep_every` generations turn out too sparse.

### 6. Test the assumptions with the recorded data

Many settings rest on assumptions nobody has checked: the tournament size, whether one point per win (bot or network) rewards the right games, the mutation rate and perturbation size, whether crossover helps, and how much a score depends on pairing and color rather than play. The experiment database records what is needed (`games`, `births`, and `rankings` in `experiment.sqlite3`), and `stats` reports it, including children per parent and where the bots rank. Still to do: run a few seeded experiments that vary one setting at a time.

**Investigate the color gap before tuning around it.** Against AmiGo after generation 0, `bigrun`'s checkpoint champions won 444/1,140 games as Black and 688/1,140 as White; `even-bigger` showed the same direction in its first four checkpoints (11/40 and 20/40). Both runs are deleted, so repeat the check on `even-bigger2` and later runs. The benchmark pairs colors, so its combined rate is still useful, but these results call for checking outcomes by opening, game length, passing, and komi. Do not assume yet whether the cause is the policy, the openings, or the opponent.

### 7. Move choice is deterministic

A network always plays its highest-scoring allowed move, so the same two networks with the same colors play the same game every time, and a tie between saturated outputs always goes the same way (usually a pass). Repeat pairings in the tournament and benchmark games without openings therefore add no information.

**Idea to think about:** make the move choice a little random with a temperature parameter: pick among the allowed moves with probability proportional to `exp(score / T)`, so T near 0 comes close to today's behavior (except that today a tie goes to the pass or the lower index, while sampling would split it) and a larger T plays more varied moves. Questions before building it:

- Where the randomness comes from: a per-game seed passed to `evo` and the arena, derived from the experiment seed like the GNU Go seeds, so runs stay reproducible.
- Whether T applies to the tournament only, with the benchmark kept at T = 0 so checkpoints stay comparable, or to both.
- Whether T is an experiment setting or another gene that evolves per network.
- Whether the pass is one of the sampled moves, or keeps its own rule.
- Whether varied games make tournament scores less noisy (more distinct games per pairing) or just weaker (worse moves on purpose).

## Go rules and scoring boundary

Brown's internal final-status algorithm assumes the board has been filled according to Brown's original move policy. Evo can pass earlier, so those assumptions do not generally hold. The arena scores every tournament game by Tromp–Taylor instead, but the GNU Go referee still decides the whole benchmark.

Before treating results as reliable, specify the board size, suicide policy, ko rule, and how GNU Go adjudicates unfinished benchmark games. The local engine uses simple ko and accepts suicide through `play`, although its generated moves exclude suicide. Those conventions should agree with the surrounding match system.

**Optional positional superko for networks.** A network may play a move that repeats an earlier whole-board position: its move filter (`move_allowed`, `engine/features.c`) and the arena forbid only a simple ko retake. Opponents with a superko rule refuse such a move; michi-c2 answers `play` with `? … Positional Superko rule violation`, which the arena treats as a crash (found 29 Sep 2026 while trying michi-c2 as an opponent). Depending on where evo ends up playing, it may need a mode that tracks earlier positions and avoids moves that repeat one (owner, 29 Sep 2026). Make it optional, off by default, so current experiments keep their rules; the arena would then have to apply the same rule to decide legality.

**Owner question: Tromp–Taylor rewards capturing dead stones.** A network that passes with AmiGo's dead stones still in its area loses by the arena's Tromp–Taylor count games the GNU Go referee gives it (7 of 50 in the comparison in `docs/experiment-reference.md`), so the tournament selects for capturing dead stones before passing. The bots' side is settled: the tournament's GNU Go and michi play on until the dead stones are captured (`--capture-all-dead`, `--play-until-end`), which took their winner changes against random networks from 45 and 13 of 110 games to 0 (the endings run in `docs/experiment-reference.md`). Still open: whether selecting networks for capturing dead stones before they pass is wanted, or whether their games need another ending or a referee.

## Comparing the owner's two proposed directions

### Go features: what is still open

The networks get 3×3 shapes, tactical features, the last move, and chain liberties as inputs and as feature weights that evolve (`docs/features.md`). One seeded 20-generation comparison with a stones-only run (26 Sep 2026, in `docs/features.md`) leaves these open:

- **Does the head start last, and does it help beyond Brown?** The feature run beat Brown 6–9 times in 10 against 0–5 for the stones-only run, but neither beat AmiGo or GNU Go level 0 at any checkpoint, and the feature run's checkpoints beat the previous one only 5 times in 10. One seed and 10 games per opponent: repeat with several seeds, more benchmark games, and longer runs (see "Proposed sequence" item 2).
- **The feature weights hardly evolve.** Their medians moved in the first five generations, faster than mutation can move them, so selection picked among generation 0's noise; afterwards they barely moved and `feature_step` fell from 0.01 to 0.005. Try a larger `initial_feature_step` or `initial_feature_noise`, and check whether selection, not the lineage that carries them, moves the weights (for example several seeds, or a run with the weights fixed at their starting values).
- **Which groups help?** The `features` setting takes single groups; compare them one at a time against `all` and `none`.
- Shapes only around the last move, instead of at every point, as MoGo used them.
- More move history than the last move: planes for how many turns ago each stone was played, as AlphaGo's inputs had.
- **Should `remove_layer` go down to 0 layers with features?** Removing a feature network's only hidden layer makes it bigger, not smaller: with 974 inputs on 9×9 a 0×0 network has 79,950 weights against 10,652 for 1×10 (every input connects to every output), and such networks spread to 5 of 12 in a seeded run (`docs/features.md`, `docs/genes.md`). Decide whether structural mutation should stop at one hidden layer when the experiment has features, or whether a large flat network is a fine thing to evolve.
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

The idea is to use the network in place of the random moves of plain Monte Carlo playouts (owner, 29 Sep 2026): UCT as usual, but each simulated game is played by the network instead of by uniformly random moves. This is the "guide rollouts" role above. Gelly and Silver's finding above applies: a stronger standalone policy need not make a better simulation policy.

### Slow experiments: identify the cost before choosing the remedy

The benchmark takes about 28 of a small generation's 30 s: it still plays every game through `gogui-twogtp` with the GNU Go referee, most of its time in the games against GNU Go level 0. Moving its games into the arena needs openings, which the arena lacks (see the past-champions question above), and changes their scoring from the referee's to Tromp–Taylor. GNU Go level 0 is back in the default tournament, with the michi levels; On the large workload the new panel makes a generation 40–54 % slower, nearly all of it in the tournament, where a round waits for its GNU Go games (`docs/performance.md`).

Another tournament improvement:

- Later, a ladder that moves: the default panel now holds the whole ladder from the start (Brown, AmiGo, three michi levels, GNU Go level 0; `docs/experiment-reference.md`), so selection keeps a signal once networks beat AmiGo. Above GNU Go level 0 nothing is calibrated yet (GNU Go level 10, Pachi). The panel lives in each experiment's `opponents` table, which the runner reads every generation, so a ladder could add rows, or drop beaten bots, as networks get stronger. A changing panel changes what a tournament score means; the benchmark panel is stored apart (`benchmark_opponents`), so checkpoints stay comparable while the ladder moves.

The first experiment should have a comfortable elapsed-time cap and checkpoint results within that cap.

### More engines for the tournament

michi-c2 at fixed playouts fills the gap between AmiGo and GNU Go level 0 (three levels in the default panels, `docs/experiment-reference.md`). The ladder needs bots beyond GNU Go level 0 once networks get there. Candidates: Pachi, Fuego, GNU Go at higher levels, and others. Pachi 12.90 builds on macOS (`make MAC=1 DCNN=0 JOSEKIFIX=0`), but its UCT engine refuses fewer than 500 playouts (`GJ_MINGAMES`) and does not repeat with `-s 42 threads=1`: playouts per move varied from 852 to 1,940 at `-t =500` between runs, and the moves differed (29 Sep 2026); so it is a later rung above GNU Go, not a repeatable intermediate one. For each candidate, find out whether it builds on macOS (clang) and Linux (GCC), speaks the GTP commands the arena controller needs, accepts or ignores time controls, and how strong and fast each setting is on 9×9 (against AmiGo, GNU Go level 0, and the other candidates, with varied openings and both colours). Calibrate candidates in separate matches, then include a qualifying bot in new experiments' fixed benchmark panels before deciding whether to use it for tournament selection. Each one that qualifies goes into the external tools release (`scripts/external-tools.txt`) and the installer.

**Owner question: the 10 s bot deadlines as settings.** The arena waits at most 10 s for a bot's answer to setup, `play` and `quit`, and 10 s past its main time for `genmove` (`RunGeneration::RESPONSE_DEADLINE` and `GENMOVE_GRACE`, constants; `docs/experiment-reference.md`). They do not limit thinking, but a bot that loads a large model at startup (KataGo, for example) could miss the first setup deadline and stop the run as `launch`. When such a bot, or search with per-move time control, is added, make both experiment settings, and revisit that the clock is absolute main time only (no byo-yomi, no `time_left`).

**Calibrate the michi levels for 13×13 and 19×19.** The three michi levels were calibrated on 9×9 only, so `SetupExperiment` refuses any other board size for an experiment whose panels hold michi (owner, 29 Sep 2026: "Best to abort even playing on 13x13 or 19x19 until such measurements have been taken"). Before lifting the refusal for a size, calibrate there with `scripts/calibrate-bots.rb` (its board size is fixed at 9 now): the endings run for the flags, then the ladder against AmiGo and GNU Go level 0. Bigger boards may need more levels, and games longer than 1 minute a side (owner). Until then evo plays 9×9 only; smaller boards are for tests (owner).

## Code cleanup

The code was written quickly as a side project. The C/Ruby split can stay. Protect each cleanup step with tests, so the experiments built on the code do not inherit its defects.

### Replace `stats` with a graphical viewer

`stats`' text tables are not useful as they are (owner, 26 Sep 2026). Replace them with a proper app, for example a web app run locally, that reads the experiment database read-only and shows graphs: benchmark results per checkpoint, gene and feature-weight trends, shapes and activations over time, and where the bots rank, plus whatever else turns out to be interesting. Open questions: the technology (a small local Ruby web server with a charting library, or something else), what to show, and whether the CSV output stays. Whatever replaces it should group a bot's copies by `players.opponent` (migration 013), not by name: `ExperimentStats#bots` (`ruby/experiment_stats.rb:254`) matches copies with `/\A#{group}\d*\z/`, so an opponent whose name ends in a digit (such as `Michi100`) would also count `Michi1000`'s copies, and nothing but the comment at `ruby/setup_experiment.rb:165` makes names end in a letter.

### Let `new-experiment` set the panels

`mise run new-experiment` takes only the settings (`SetupExperiment.option_parser`, `ruby/setup_experiment.rb:327`); the `opponents` and `benchmark_opponents` tables always start as `DEFAULT_OPPONENTS` and `DEFAULT_BENCHMARK` (`:172`, `:187`). A run with another panel edits them with `sqlite3` before its first run, as `scripts/profile-workload.sh:108-125` does to pin its panels. The michi and run-speed work needed this several times (a smoke run with an added michi row, a seeded comparison with every bot at 1 copy, a run against a fake bot, which also needs the `players` rows edited once a generation is set up), and the bot-free experiment under "1. Fitness needs a clearer meaning" needs an empty `opponents` table. Options such as `--opponent NAME=COMMAND:COPIES`, `--no-opponents`, and the same for the benchmark would make these runs one command, without hand-written SQL.

### Quiet and split `test/run_generation_test.rb`

`ReproducibleRoundsTest#next_round_games` (`test/run_generation_test.rb:1806`) calls `setup_next_round` without `capture_io`, so `test_pairings_depend_on_the_scores_not_on_the_order_ties_are_listed_in` prints "Pairing round 2/3 ..." twice into the test output, where it can hide a real warning. The file is also 3,075 lines; its classes (for example `PlayRoundTest` from `:937`, `InMemoryStateTest` from `:2414`, `NetworksOnDiskTest` from `:2689`) could move to their own files, so an agent reads only the part it needs.

### Convert the C code to Rust?

Consider porting Evo's own C code to Rust, keeping the libraries it uses (such as GENANN and `pcg-c`) as they are and linking them rather than rewriting them (owner, 27 Sep 2026). The Rust compiler gives better error messages, and LLM-assisted work may go more smoothly there. The owner already wrote a Rust Go bot, [Iomrascálaí](https://github.com/ujh/iomrascalai) (GPL-3.0, last pushed January 2018, so pre-2018-edition Rust). Its board, rule set, scoring, GTP, and SGF modules may be reusable here (owner, 27 Sep 2026). Open questions: how much code that is, whether the tests carry over, and what it does to the build and CI.

### Neural network library

GENANN stays: it is small, tested upstream, and does what the experiments need. It already has per-network hidden and output activations (sigmoid, cached sigmoid, linear, threshold, and since v1.1 `tanh` and ReLU). Extra feature inputs only widen the input layer, and inference is negligible next to adjudication, so batching is not needed. The `.ann` file records a network's sizes, both activations, its genes, and its feature set with its feature weights (format version 2). GENANN's hidden layers must all have the same width; revisit that only if an experiment needs different widths.

## Tooling for agents

**Owner request: check running subagents automatically.** In a planned run the orchestrator checks every running agent by hand for progress (its commits, working tree, worktrees and processes; `docs/orchestration.md`, "Watching running agents"), since an agent once finished its work and never reported. Build tooling that does it without being asked: for example a heartbeat or watchdog script, a Claude Code hook, or a plugin that tracks subagent liveness and prompts the orchestrator when an agent stops making progress. Open questions: what counts as progress for a step that runs a long measurement, and whether a hook can see subagents at all.

## Proposed sequence

These are candidate milestones for discussion, rather than an implementation commitment.

0. **Clean up the code under test.** Carry out the remaining [cleanup](#code-cleanup) alongside milestone 1.
1. **Make a short experiment interpretable and affordable.** Choose 5×5 or 9×9 and the komi, and verify a short run can resume safely. Measure runtime per generation and the fraction of unchanged offspring.
2. **Measure the features' effect.** Compare a feature run with a stones-only run and with random search using the same inputs and game budget, with the same breeding procedure. Use several independent seeds; three is a practical starting point, not a guarantee of statistical confidence. Report raw game counts, uncertainty, elapsed time, and diversity. Reserve additional opponents or openings for final evaluation.
3. **Choose the next experiment from the evidence.** Operator comparisons, additional features, and UCT-style search are candidates. For search, test the contribution of evolved guidance against the same search without that guidance. If there is still no learning, use the measured offspring variation, lineage diversity, game records, and runtime breakdown to narrow the next change.

Repeated deterministic games from the same starting position do not provide independent evidence. Evaluation needs controlled variation in openings or opponent seeds, with color-balanced comparisons. Report progress at equal generations as well as equal games and compute consumed: `even-bigger` (since deleted) reached similar AmiGo benchmark performance in only 300 generations, but it also changed population size and architecture, so those effects need separate comparisons.

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
- For the opponent ladder: what promotes a network to the next bot (for example, a win rate over a number of games in both colors, sustained for some generations), whether beaten bots leave the panel, and which bots go above GNU Go level 0?
