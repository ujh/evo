# Evo: open work

This file lists only work still to do: defects, cleanup, proposed experiments, and open questions.
Delete an item when a change finishes it.
Facts a future agent needs go into the relevant reference in `docs/`, and results into `docs/findings.md`.
Each item gives the problem, why it matters, the next step, and the owner's decision if there is one.

- [What most affects the experiment](#what-most-affects-the-experiment)
- [Go rules and scoring boundary](#go-rules-and-scoring-boundary)
- [Comparing the owner's two proposed directions](#comparing-the-owners-two-proposed-directions)
- [Code cleanup](#code-cleanup)
- [Tooling for agents](#tooling-for-agents)
- [Proposed sequence](#proposed-sequence)
- [Questions to settle together](#questions-to-settle-together)

**Proposed first milestone:** repeatable improvement on a small board, under a fixed and trustworthy evaluation procedure.

**Current recommendation:** new experiments play a calibrated ladder in the tournament: Brown, AmiGo, three michi-c2 levels, and GNU Go at levels 0 and 10 (`docs/experiment-reference.md`, "The default panels and the michi ladder").
Next, run experiments with it and test whether low mutation rates limit further progress.
Improve checkpoint comparisons, and repeat controlled runs with several seeds before attributing a gain to a setting.
Do the [cleanup](#code-cleanup) alongside.
Treat search as a possible follow-on that needs its own control experiment.

**Reduce the Ruby side of a tournament round for large populations (only if it gets in the way again).**
The runner's Ruby side is O(population) work per game: `RunGeneration#update_data` re-sorts the whole ranking, `in_order?` and `ranking_moves` walk it, and `ExperimentDatabase#raise_in_ranking` scans the generation's `rankings` rows, which have no index on `rank`.
At concurrency 3 on the large workload the main thread keeps up with the arenas (`docs/performance.md`, "The runner's main thread"); it would matter if it fell behind, at a higher concurrency or with more games a round, when a round's `round_K` rises well above `worker_round_K` divided by the concurrency.
Then move only the changed players in memory instead of re-sorting (the order must stay `update_data`'s), add an index on `(generation, rank)` in a new migration, and measure again on the large workload.

**Read the benchmark ratings as they come in.**
`stats` rates every checkpoint's champion, generation 0's, and the panel's bots on one Elo scale (`docs/experiment-reference.md`, "stats", says how to read ± and the prior).
Once `even-bigger2` (a champion every 100 generations) has several checkpoints, check whether the champions' ratings rise steadily or cycle, and whether the rise holds against the bots, not only against past champions.

## What most affects the experiment

### 1. Fitness needs a clearer meaning

A tournament score measures success in one schedule (different opponents, random rather than paired colours, repeat pairings), so it is no stable measure of strength across generations; the benchmark (`docs/experiment-reference.md`, "Benchmark") measures strength instead.

**Proposed experiment:** compare the default `opponents` panel against an empty `opponents` table, on the benchmark, at equal game budgets, to test whether bots belong in the tournament.
If the bot-free run drifts or cycles, try a hall of fame of frozen past champions in the tournament instead.

**Later fitness-side ideas** (`docs/literature.md`, "Ranked experiments", item 10), each a single change: bots with some randomness so the networks win 20–80 % against them; an even number of rounds with balanced colours; raising the rounds when a measured statistic calls for it rather than at fixed generations.

### 2. Selection pressure is a guess

Parents are chosen by tournament selection of size 3 (`tournament_size`), and nothing shows whether that keeps enough variation or selects too weakly.

**Proposed response:**
- Measure it with the [recorded data](#6-test-the-assumptions-with-the-recorded-data).
- Compare tournament size 5 as a single change (`docs/literature.md`, "Ranked experiments", experiment 7), with low priority as a cure for the shrinking mutation genes.
- Re-evaluate top-ranked and some lower-ranked networks on the same independent openings, to estimate how much the tournament schedule misorders parents and checkpoint champions.

Elitism is built (`elite_share`); its first six runs, one per setting, cannot tell its effect (`docs/findings.md`, "Elitism (`elite_share`)"); its open variants are under [Questions to settle together](#questions-to-settle-together).

**Rank by the rating fit instead of the win count?**
Predicted about 6 % better selection at no cost in games (`docs/findings.md`, "How noisy the tournament's ranking is"); untested, and it needs its own pair of runs if wanted.
The owner would rather keep the tournament and the benchmark alike (owner, 30 Sep 2026: "On a theoretical level I'd prefer to keep both tournaments (actual ones and benchmark) the same, just because that's easier to reason about. If raising the rounds to 20 would already help then that would be preferrable. But it all depends on the data, I guess").

### 3. Mutation and crossover deserve separate experiments

How a child is made is in `docs/genes.md`, "How `evolve` makes a child".
Many children differ from their parent in a weight or two, and changed weights can leave the moves unchanged, so genetic and behavioural diversity are different measurements.
Crossover and mutation are mutually exclusive in `breed()` (`evolve/evolve.c`), and crossing raw weight arrays assumes hidden units have compatible roles in both parents, which they need not (the [original NEAT paper](https://nn.cs.utexas.edu/downloads/papers/stanley.ec02.pdf)); measure whether that matters rather than assume it.

**Proposed response:** a mutation-only baseline, `cross_over_rate` 0 as a single change against `seed2-rounds20` at equal game budgets; none of the large-scale neuroevolution successes crossed weights (`docs/literature.md`, "Large-scale neuroevolution compared with evo").
Treat the number of mutated weights and the size of each perturbation as separate controls, and optionally measure unchanged children's move agreement on a small bank of positions.
None of the `initial_*` gene defaults was chosen from evidence, so compare starting values at equal game budgets.
With one run per setting, the fixed-gene runs (`meta_rate` 0) cannot tell whether freezing the genes helps (`docs/findings.md`, "Fixed mutation genes").

**Open question: do the shrinking mutation genes limit progress?**
Under noisy selection a gene can drift toward a bound, for example `copy_chance` to its maximum of 0.1, which would make a tenth of the mutated children plain copies.
In the 500-generation runs `weight_step`'s median fell from 0.5 to between 0.018 and 0.0004 (`docs/findings.md`, "10, 20 and 40 rounds"), and in `seed2-rounds40` `copy_chance` rose to 0.02–0.07; with one run per round count, whether the rounds set that order cannot tell.
Past generation 500 the median rose again in `seed2-rounds20-b` (to 2.65 in generations 751–800, same finding), so the shrinking need not last.
The `weight_step` clamp (0.0001) is reached: the generation's minimum sits at it in `rounds20` from generation 200 and in `seed2-rounds40` from generation 337, and touches it in many generations of `seed2-rounds10` (from 352) and `seed2-rounds20`.
`seed2-rounds20-b` and `seed2-meta0-b`, second runs of `seed2-rounds20`'s and `seed2-meta0`'s settings, reach generation 1000 (`docs/findings.md`, "Elitism (`elite_share`)", has the commands that print their genes and population strength).
Still open:
- whether another seed agrees with the single-seed results in `docs/findings.md`, "Fixed mutation genes" and "How brittle a champion is";
- how the populations of `seed2-meta0` (step 0.5) and `seed2-meta0-step015` (step 0.15) changed against the bots (`docs/findings.md`, "Fixed mutation genes"), and whether elitism changes that (owner, 9 Oct 2026: without elitism, children that change little are the only way a good network's play survives, which may be what favours small weight steps); the elitism runs cannot tell, with one run per setting, and telling it needs more seeds of each setting;
- whether the shapes are what kept the self-adaptive run gaining: a fixed-gene run with a higher `initial_structure_rate` would tell;
- whether larger steps still sometimes give better children, which the brittleness test could miss (`docs/findings.md`, "How brittle a champion is").

If shapes are to be explored, start with a higher `initial_structure_rate`.
Also open (owner, 12 Nov 2026): whether `feature_step` shrinks as `weight_step` did in the 500-generation runs; `scripts/gene-trajectories.rb` prints its per-run medians and clamp shares (`docs/findings.md`, "Elitism (`elite_share`)", has the command).

**Next diagnostic for structural exploration.**
Low adaptive structure rates can leave a run scarcely testing other shapes (one large run changed structure in 42 of 50,000 births in generations 100–149), which does not establish a local optimum.
Compare a maintained minimum structural-change rate against the current self-adaptation, other settings fixed, and measure how many shapes are tried and how often they survive, at equal generations as well as equal games and elapsed time.

**Proposed experiment: cross the rest of the genome apart from the weights.**
A crossover child takes all of the non-weight genome (mutation genes, activations, feature weights, `feature_step`) from the parent whose weights come first.
Instead, take each gene from either parent at random or average the numeric ones, for every child, crossover or mutation; these genes could mix even between parents of different shapes.
Prefer the arithmetic mean for the mutation genes (owner, 9 Oct 2026, likes it): it pulls the step up, which keeps self-adaptation stable where the geometric mean does not (`docs/literature.md`, "Fixes for self-adaptation").
Compare against the present scheme at equal game budgets.

**Proposed experiment: average the weights of related parents.**
Instead of one-point crossover, move one parent a fraction (say 5–20 %) of the way toward the other, weight by weight, then mutate; same shape only, against the present crossover at equal game budgets.
Averaging unrelated networks breaks them (Uriot & Izzo 2020), but between close relatives it worked (Pollack & Blair 1998; Runarsson & Lucas, via secondary sources), and late in a run evo's parents are close relatives.

**If self-adaptation stays, alternatives to test one at a time** (`docs/literature.md`, "Fixes for self-adaptation" and "Ranked experiments"):
- 10 % of mutation children made with the default genes, whatever the parent's;
- one shared step for the population under the 1/5 success rule, with a success measure other than the tournament score, since copies beat their parent's score about as often as mutation children do (`docs/findings.md`, "Fixed mutation genes");
- a small upward bias in the nudge (log-step plus about 0.01);
- a floor on the total perturbation √(weights changed × step² / 3) rather than on `weight_step`, since `rounds20` traded a tiny step for 30,000–250,000 changed weights of about 500,000;
- a smaller `meta_rate` such as 0.05, expected only to slow the collapse.

**Proposed experiment: heavy-tailed weight changes, without genes.**
Under `meta_rate` 0, draw each child's number of changed weights from a power law (probability ∝ k^−1.5 on 1 to half the weights), against `seed2-meta0` (`docs/literature.md`, "Ranked experiments", experiment 9).

**Settings that could become genes**, each a proposed experiment:
- `cross_over_rate` as a per-network `crossover_chance`, mutating on the logit scale like `copy_chance`;
- a pass bias added to the pass output's score, since saturated ties pass today;
- move temperature (item 7);
- feature groups switched on or off per network, worth it only if a feature turns out to hurt, since it blocks crossover between networks that differ.

The other settings define the experiment or its measurement and stay settings: the board, komi, move and time limits, population, rounds, seeds, the benchmark, the shape bounds, `tournament_size`, `elite_share`, and `meta_rate` (the τ that evolution strategies usually keep fixed).

### 4. The policy has to learn Go structure from very little guidance

The network gets the board, komi and, with feature groups, per-point features and feature weights (`docs/features.md`), but no move history beyond the last move, no spatial weight sharing, and no lookahead.
None of its settings (hidden layers and sizes, activations, inputs and outputs) was chosen for a reason, and cached sigmoid outputs create score ties that favour earlier intersections or passing.

**Check whether the dense network still influences move choice.**
A late population of the deleted `bigrun` had tanh outputs (between −1 and 1) while some feature weights were around 7–10, so the feature terms may decide many moves.
Check first whether `even-bigger2`'s champions show the same pattern; then, on a bank of positions, measure move agreement with the feature terms removed and with the dense output removed, and test the resulting policies on held-out games.

**Later head starts from the literature**, each compared with a run without it (`docs/literature.md`, "Ranked experiments", its head starts for later): score the position after each candidate move instead of picking a move; start from a network trained by temporal-difference learning; local shape features with weights shared across the board; small changes to all weights against large changes to a few at equal total perturbation.

### 5. Long runs need recoverable evidence

Only every `keep_every`-th generation keeps its champion and SGFs (`docs/experiment-reference.md`, "Storage"), which limits comparisons with early ancestors to those champions.

**Proposed response:** also keep each generation's top-ranked network, if the `keep_every` generations turn out too sparse.

### 6. Test the assumptions with the recorded data

The tournament size, one point per win, the mutation rate and size, crossover, and how much a score depends on pairing and colour rest on unchecked assumptions.
`experiment.sqlite3` records what is needed; next, run a few seeded experiments that vary one setting at a time.

**Cheap measurements before more long runs** (`docs/literature.md`, "Step 0: cheap measurements"):
- **Test-retest reliability:** replay one stored generation in a second, independent Swiss tournament at 10 and 20 rounds and correlate the rankings, since the split-half reliabilities in `docs/findings.md`, "How noisy the tournament's ranking is", may be artefacts of the pairing.
- **Drift control:** a few dozen generations with shuffled fitness, tracking the median log `weight_step`, to see how far the genes move with no selection.
- **Per-generation figures in `stats`:** the total perturbation, the share of mutation children scoring at least as well as their parent beside the same share for copies, scores by operator, weight size per layer and saturated neurons, and how often a child picks its parent's move on a bank of positions.

**Are the benchmark's fixed openings less informative than fresh ones?**
The brittleness test's faint hint (`docs/findings.md`, "How brittle a champion is") is that children led a champion on its benchmark openings while their controls trailed it on fresh ones.
If the fixed openings separate players poorly, every checkpoint comparison is weaker than it looks.
Next: an analysis script comparing each step's spread on the benchmark and on fresh openings with the spread per-game noise gives (`docs/orchestration.md`, "Analyses and results docs") (owner, 15 Oct 2026: into these notes).

**Investigate the colour gap before tuning around it.**
White wins 56–63 % of `even-bigger2`'s tournament games (`docs/findings.md`, "How noisy the tournament's ranking is"), and earlier runs' champions won more often as White against AmiGo.
Check outcomes by colour, opening, game length, passing, and komi on `even-bigger2` and later runs before assuming whether the cause is the policy, the openings, or the opponent.

### 7. Move choice is deterministic

A network always plays its highest-scoring allowed move, so two networks with the same colours play the same game every time, and repeat pairings add no information.
In the self-adaptive runs at 20 and 40 rounds a growing share of network games are clone repeats (`docs/findings.md`, "How often tournament games repeat"); at generation 500 of `seed2-rounds20` they are about 17 % of the network games.

**Proposed: random openings in the tournament, before any temperature.**
Start each tournament game from an opening drawn per game, as the benchmark does, so clone pairs and games against AmiGo and Brown differ while every network still plays its best move.
It makes the tournament and the benchmark alike, which the owner prefers, and gives the arena the openings that moving the benchmark into it needs ([Slow experiments](#slow-experiments-identify-the-cost-before-choosing-the-remedy)).
Against Wally, a fully deterministic Go program, SANE's networks learned tricks and then lost even to random players, and 10 % random moves in Wally fixed it (Richards, Moriarty & Miikkulainen 1998; `docs/literature.md`, "What helped").
Compare a run with openings against `seed2-rounds20`, only the openings changed.

**Open: does elitism keep the population more varied?**
The first elitism runs cannot tell, with one run per setting; telling it needs more seeds of each setting (`docs/findings.md`, "Elitism (`elite_share`)", has the `scripts/game-repeats.rb` commands).
The clone-repeat share is comparable only between runs with the same number of rounds, and elitism adds clones by construction (an elite and a bred copy of its parent).
`stats`' identical count compares activations only (`ExperimentStats#identical?`), so it is no exact clone count; `scripts/gene-trajectories.rb` counts exact clones by `genome`.

**Proposed: never cross a network with itself.**
Parents are drawn independently, with replacement (`RunGeneration#select_parent`), so a crossover child can have one network as both parents and be an exact clone, even at `copy_chance` 0 (1.8/N of the crossover children with a size-3 tournament over N networks whose scores all differ; `scripts/gene-trajectories.rb` counts them).
Redrawing the second parent when it equals the first would remove them, but changes every later draw, so test it as a change of its own, not inside the elitism arms (owner, 19 Oct 2026: keep it for now, note it for later).

**Proposed: `scripts/game-repeats.rb --rounds N`**, counting only the games of the first N rounds (`games.round` 0 to N − 1; `GameRepeats.games` counts every round).
The first N rounds of a Swiss tournament are a valid N-round tournament, so `seed2-rounds10`, `-rounds20` and `-rounds40` could be compared at equal rounds without new runs, telling whether their clone-repeat gradient comes from the genes or from the measure.
A reviewed script change comes before any of its numbers enter the docs (owner, 15 Oct 2026: into these notes).

The temperature idea below stays for later (owner, 9 Oct 2026: openings first).

**Idea to think about:** pick among the allowed moves with probability proportional to `exp(score / T)`.
Questions before building it:
- where the randomness comes from (a per-game seed derived from the experiment seed, so runs stay reproducible);
- whether T applies to the tournament only, keeping the benchmark at T = 0, or to both;
- whether T is a setting or a gene, and whether the pass is sampled or keeps its own rule;
- whether varied games make tournament scores less noisy or just weaker.

## Go rules and scoring boundary

The arena scores every tournament game by Tromp–Taylor, the GNU Go referee decides the benchmark, and Brown's own final-status algorithm assumes a board filled by Brown's move policy, which evo's early passes break.
Before treating results as reliable, specify the board size, suicide policy, ko rule, and how GNU Go adjudicates unfinished benchmark games; the engine uses simple ko and accepts suicide through `play`, though its generated moves exclude suicide.

**Optional positional superko for networks.**
A network's move filter (`move_allowed`, `engine/features.c`) and the arena forbid only a simple ko retake, so a network may repeat an earlier whole-board position, which michi-c2 refuses (`? … Positional Superko rule violation`) and the arena treats as a crash.
Depending on where evo ends up playing, it may need a mode that tracks earlier positions and avoids moves that repeat one (owner, 29 Sep 2026).
Make it optional, off by default, and have the arena apply the same rule.

**Owner question: Tromp–Taylor rewards capturing dead stones.**
A network that passes with AmiGo's dead stones in its area loses by the arena's count games the referee gives it (`docs/experiment-reference.md`, "Tromp–Taylor against the GNU Go referee on the same games"), so the tournament selects for capturing dead stones before passing; the bots already play on until dead stones are captured.
Still open: whether selecting networks for capturing dead stones before they pass is wanted, or whether their games need another ending or a referee.

## Comparing the owner's two proposed directions

### Go features: what is still open

One seeded 20-generation comparison of `features all` with a stones-only run (`docs/findings.md`, "What a comparison showed") leaves these open:

- **Does the head start last, and does it help beyond Brown?**
  Repeat with several seeds, more benchmark games, and longer runs ([Proposed sequence](#proposed-sequence) item 2).
- **The feature weights hardly evolve** after the first generations.
  Try a larger `initial_feature_step` or `initial_feature_noise`, and check whether selection, not the lineage that carries them, moves the weights (several seeds, or the weights fixed at their starting values).
- **Which groups help?**
  Compare single groups one at a time against `all` and `none`.
- Shapes only around the last move, as MoGo used them.
- More move history: planes for how many turns ago each stone was played, as AlphaGo's inputs had.
- **Should `remove_layer` go down to 0 layers with features?**
  With 974 inputs on 9×9 a 0×0 network has 79,950 weights against 10,652 for 1×10, and such networks spread to 5 of 12 in a seeded run (`docs/features.md`, `docs/genes.md`).
  Decide whether structural mutation should stop at one hidden layer when the experiment has features.
- **Later: a `ladders` feature group** (capture and escape per point, mainly for bigger boards), with a ladder reader that plays the ladder out on Brown's board and undoes it with `brown_save`/`brown_restore`.

### A network inside UCT-style search

A network could guide exploration (move preferences, which need a selection rule for priors), guide rollouts (move choices in simulated games, where its speed matters), or evaluate leaves (which needs a value output the move scores do not supply).
The idea is to use the network in place of the random moves of plain Monte Carlo playouts (owner, 29 Sep 2026): UCT as usual, but each simulated game is played by the network instead of by uniformly random moves.
A stronger standalone policy did not necessarily make a better simulation policy in 9×9 Go ([Gelly and Silver](https://www.davidsilver.uk/wp-content/uploads/2020/03/combining_uct.pdf), with reinforcement learning).
Search needs full board restore (Brown's `brown_save`/`brown_restore` copies about 4 kB, no incremental undo), correct simulation endings and ko, and a scorer for arbitrary leaves, which Brown's inherited one is not.
Build it after a useful direct policy exists, and compare against the same search with uniform or frozen guidance at equal simulation budgets and at equal elapsed time.

### Slow experiments: identify the cost before choosing the remedy

The benchmark takes about 28 of a small generation's 30 s (`docs/performance.md`, "The benchmark on the small workload"): 1,800 GoGui games a checkpoint at the defaults, through `gogui-twogtp` and the GNU Go referee.
Moving them into the arena would make them nearly free, but the arena needs openings first, since networks play deterministically (item 7), and the scoring would change from the referee's to Tromp–Taylor, which differ where dead stones stay on the board.
The default panel also makes a large-workload generation 40–54 % slower, nearly all of it in tournament rounds waiting for GNU Go games (`docs/performance.md`, "The default panel on the large workload").

**Later, a ladder that moves.**
The runner reads each experiment's `opponents` table every generation, so a ladder could add bots, or drop beaten ones, as networks get stronger, while the separate `benchmark_opponents` keeps checkpoints comparable.
A changing panel changes what a tournament score means; what promotes a network is under [Questions to settle together](#questions-to-settle-together).

### More engines for the tournament

The ladder needs bots beyond GNU Go level 10 once networks get there: Pachi, Fuego, GNU Go above level 10, and others.
Pachi 12.90 builds on macOS (`make MAC=1 DCNN=0 JOSEKIFIX=0`), but refuses fewer than 500 playouts (`GJ_MINGAMES`) and does not repeat with `-s 42 threads=1`, so it is a later rung, not a repeatable intermediate one.
For each candidate, check that it builds on macOS and Linux, speaks the GTP commands the arena needs, how it handles time controls, and how strong and fast each setting is on 9×9; calibrate it in separate matches, add a qualifying bot to the benchmark panel before using it for selection, and to the external tools release (`scripts/external-tools.txt`) and installer.

**Place the pinned GNU Go levels on the ladder.**
The michi levels were calibrated against the unpinned GNU Go, so where the pinned levels 0 and 10 stand against MichiMid, MichiStrong and each other is not measured (`docs/experiment-reference.md`, "The default panels and the michi ladder").
`scripts/calibrate-bots.rb ladder` with those pairings would tell, and whether the panels' order should change.

**Owner question: the 10 s bot deadlines as settings.**
The arena waits at most 10 s for a bot's answer to setup, `play` and `quit`, and 10 s past its main time for `genmove` (`RunGeneration::RESPONSE_DEADLINE` and `GENMOVE_GRACE`), so a bot that loads a large model at startup (KataGo) could stop the run as `launch`.
When such a bot, or search with per-move time control, is added, make both settings, and revisit that the clock is absolute main time only (no byo-yomi, no `time_left`).

**Calibrate the michi levels for 13×13 and 19×19.**
The michi levels were calibrated on 9×9 only, so `SetupExperiment` refuses other board sizes for panels with michi (owner, 29 Sep 2026: "Best to abort even playing on 13x13 or 19x19 until such measurements have been taken").
Before lifting the refusal for a size, calibrate there with `scripts/calibrate-bots.rb` (board size fixed at 9 now): the endings run, then the ladder.
Bigger boards may need more levels, and games longer than 1 minute a side (owner).
Until then evo plays 9×9 only; smaller boards are for tests (owner).

## Code cleanup

Protect each cleanup step with tests, so the experiments built on the code do not inherit its defects.

### Fold the C program checks into the Minitest suite

`mise run test-c` runs the `Makefile`'s `test` target, which stops at the first failing sub-make, so one failure hides the other suites' results (owner, 19 Oct 2026: move away from the Makefile for testing and fold these into the test suite).
Let `make` only build; turn each shell check (`enginetest`, `bottest.sh`, `play_test`, `evolvetest`, `perturbtest`, `arenatest`, `initial-population`'s `test`) into a Minitest test, and run each C unit-test binary from a thin Minitest test.
Group them by directory (for example `test/c/`) so CI can still run C and Ruby as separate jobs, and change `mise run test-ruby`'s glob `test/**/*_test.rb` with them.

### Watch: a possibly flaky stats test

`test/experiment_stats_test.rb` and `test/stats_test.rb` failed once together with a mutant applied, so the failure may have been the mutant's.
A candidate cause is the `stats --watch` test, which waits under a 20 s timeout and then sends SIGINT, which a loaded machine can upset.
Act only if it fails again (owner, 19 Oct 2026).

### Replace `stats` with a graphical viewer

`stats`' text tables are not useful as they are (owner, 26 Sep 2026).
Replace them with, for example, a local web app that reads the experiment database read-only and graphs benchmark results per checkpoint, gene and feature-weight trends, shapes and activations, and where the bots rank.
Open questions: the technology, what to show, and whether the CSV output stays.
Group a bot's copies by `players.opponent`, as `ExperimentStats#against_bots` does: `ExperimentStats#bots` matches copies by name with `/\A#{group}\d*\z/`, so `Michi100` would also count `Michi1000`'s copies.

### Let `new-experiment` set the panels

`mise run new-experiment` takes only the settings; the `opponents` and `benchmark_opponents` tables always start as `DEFAULT_OPPONENTS` and `DEFAULT_BENCHMARK`, so another panel (such as item 1's empty one) needs hand-written SQL, as `scripts/profile-workload.sh` uses.
Add options such as `--opponent NAME=COMMAND:COPIES`, `--no-opponents`, and the same for the benchmark.

### Quiet and split `test/run_generation_test.rb`

`ReproducibleRoundsTest#next_round_games` calls `setup_next_round` without `capture_io`, so a test prints "Pairing round 2/3 ..." twice into the output, where it can hide a real warning.
The file is about 3,300 lines; its classes (for example `PlayRoundTest`, `InMemoryStateTest`, `NetworksOnDiskTest`) could move to their own files.

### Convert the C code to Rust?

Consider porting Evo's own C code to Rust, keeping the libraries it uses (such as GENANN and `pcg-c`) as they are and linking them rather than rewriting them (owner, 27 Sep 2026).
The Rust compiler gives better error messages, and LLM-assisted work may go more smoothly there.
The owner already wrote a Rust Go bot, [Iomrascálaí](https://github.com/ujh/iomrascalai) (GPL-3.0, last pushed January 2018, so pre-2018-edition Rust).
Its board, rule set, scoring, GTP, and SGF modules may be reusable here (owner, 27 Sep 2026).
Open questions: how much code that is, whether the tests carry over, and what it does to the build and CI.

### Left by the elitism analysis

Owner, 12 Nov 2026: note all of these (triaged at the end of the elitism analysis, #133–#136).

- **`scripts/game-repeats.rb` counts a checkpoint whose tournament is still running.**
  `GameRepeats.games` does not check `generations.round` against `tournament_rounds`, as `scripts/gene-trajectories.rb` and `scripts/population-strength.rb` do, so on a running experiment its shares are quietly wrong.
  Refuse or name unfinished generations as the other two do, and have those two name a generation whose births are stored but which has no `generations` row.
- **GNU Go commands written out by hand.**
  `scripts/profile-workload.sh` and `scripts/calibrate-bots.rb` (`ENDINGS_BOTS`) use the unpinned `gnugo --level 0`, whose games depend on the machine's load, so the seeded "same results as `main`" comparison can differ for no reason.
  Five smoke scripts (`smoke-bot-patches.sh`, `smoke-external-tools.sh`, `smoke-arena-bots.sh`, `smoke-bot-controller.sh`, `bot-response-times.sh`) copy the pinned commands instead of reading `SetupExperiment::GNUGO_ZERO`/`GNUGO_TEN`, so they would silently keep testing old defaults.
- **Shared analysis helpers.**
  `scripts/gene-trajectories.rb` and `scripts/population-strength.rb` copy about ten helpers, and `scripts/compare-runs.rb` has its own table; one module would keep those rules identical and let a fix land once.

## Tooling for agents

**Owner request: check running subagents automatically.**
The orchestrator checks running agents by hand (`docs/orchestration.md`, "Watching running agents"), since an agent can finish and never report.
Build a watchdog script, Claude Code hook, or plugin that prompts the orchestrator when an agent stops making progress.
Open questions: what counts as progress for a long measurement, and whether a hook can see subagents at all.

**One command for "same results as `main`".**
A step that must not change results compares two seeded experiments' databases table by table (`docs/orchestration.md`, step 5, "Real runs"), and every agent writes those queries again.
`scripts/profile-workload.sh` takes no extra settings.
Add a settings pass-through and a `scripts/compare-experiments` that diffs two kept databases by that rule (owner, 19 Oct 2026).

**A mutant helper.**
A reverted C mutant's binaries can stay built (a stale `initial-population` kept refusing 0 until a clean rebuild; cause not established), and a `sed -i ''` mutant whose pattern does not match silently changes nothing.
A `scripts/mutant.sh` that applies the change, fails if the source did not change, builds clean, tests, reverts and rebuilds clean would remove both (owner, 19 Oct 2026).

**A fast multi-seed check for `evolve`.**
Each `evolve` process start costs about 0.24 s on macOS, so checking byte-identical children against `main` over many seeds outruns a foreground command's time limit.
A test-only mode that loops over seeds in one process would make it one command (owner, 19 Oct 2026).

## Proposed sequence

Candidate milestones for discussion, not a commitment:

0. **Clean up the code under test** alongside milestone 1.
1. **Make a short experiment interpretable and affordable:** choose the board and komi, verify a short run can resume safely, and measure runtime per generation and the fraction of unchanged offspring.
2. **Measure the features' effect:** compare a feature run with a stones-only run and with random search at the same inputs, game budget and breeding, with several seeds (three is a practical start), raw game counts, uncertainty, elapsed time, and diversity, keeping some opponents or openings for final evaluation.
3. **Choose the next experiment from the evidence:** operator comparisons, more features, or UCT-style search (against the same search without evolved guidance).

Evaluate with controlled variation in openings or opponent seeds, colour-balanced, at equal generations as well as equal games and compute.
A useful success statement: "Within an agreed CPU/time budget, evolution consistently beats equally budgeted random search and the initial population on opponents or positions not used to select parents."

**First experiment, proposed:** evolution against a random-search control that keeps the best of fresh random networks, at the same board, architecture, rules, komi and evaluation budget, chosen beforehand.
Start with mutation-only breeding, recording unchanged offspring; select initial champions without consulting test results; measure champions against a fixed validation panel in both colours at predetermined checkpoints; compare the final policies against the initial and random-search champions on reserved opponents or openings, repeated with independent seeds.
Agree on a meaningful gain, game budget and elapsed-time cap before collecting the final results.

Later, after a baseline: topology evolution, indirect encodings, or program evolution ([Such et al., Deep Neuroevolution](https://arxiv.org/abs/1712.06567), trained large policies with genetic algorithms on Atari and locomotion).

## Questions to settle together

- Elitism (`elite_share`) carries the top E networks of a generation's Swiss ranking unchanged into the next generation, scored on its tournament alone, while every parent is still drawn from the whole population (owner, 16 Oct 2026: a share, not a count, since the population size may change; the top E by Swiss; the latest tournament only).
  Its first runs, four arms (`elite_share` 0.01 × `meta_rate` {0.2, 0} × `initial_copy_chance` {0.01, 0}) with `seed2-rounds20`'s settings and seed (owner, 16 Oct 2026) and two baselines, cannot tell the hypothesis (`docs/literature.md`, "Ranked experiments", experiment 2) with one run per setting; telling it needs more seeds of each setting (`docs/findings.md`, "Elitism (`elite_share`)", names the scripts).
  Still open, to decide from those runs (`docs/literature.md`, "Elitism" and "Ranked experiments"):
  - a shortlist re-test: choose elites by extra games in both colours against a fixed panel for the top 10–50 and the current elites;
  - ranking an elite on its mean score over every tournament since it was selected, instead of the latest alone;
  - a margin: an elite replaced only by a clearly better challenger;
  - with `meta_rate` 0.2, a floor on `weight_step`, since an elite with collapsed genes can block exploration;
  - judging elites against the bots instead of within the network tournament.
- Which network sizes, populations, and runtimes were used before, and do historical results or champions exist elsewhere?
- What hardware, compute budget, and unattended runtime are comfortable for a single experiment?
- Which board size and first opponent would make a satisfying initial milestone?
- For the opponent ladder: what promotes a network to the next bot, whether beaten bots leave the panel, and which bots go above GNU Go level 10?
