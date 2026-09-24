# Evo: assessment and next experiments

Working draft, 23 September 2026; code review, timing sample, and cleanup plan added 24 September. This records an assessment of the current checkout and proposals for discussion. The owner has chosen measurable improvement from evolution as the objective; the experiment design and milestones remain proposals. No implementation changes were made for this assessment.

Assessment scope: commit `621f367` plus the owner's existing uncommitted changes in `ruby/run_generation.rb` and `stats`. Those local changes affect elitism, opponent counts, and champion retention; findings about those behaviors describe the assessed working copy. This document is being published separately from those implementation changes. The `pcg-c` submodule also reported untracked local files.

## Overall assessment

Evo has a functioning foundation for experiments in neuroevolution: a C policy engine, a Go protocol interface, population generation and breeding, and a Ruby tournament runner. The separation between these components is useful and does not currently justify a rewrite.

The main weakness is our ability to tell whether evolution is producing broadly better Go players. Tournament results mix changing opponents, unequal opportunities to face external bots, aggressive selection, and some incorrect handling of game outcomes. Historical evidence is also discarded. These issues make an apparent improvement or plateau difficult to interpret.

The owner reports that play never visibly improved and experiments took a long time. Before pausing the project, the intended next step was to give the engine a better representation using 3×3 patterns, or use a neural network inside a UCT-style search. This is useful observational evidence, although actual playing strength and the cause of stagnation remain unmeasured: the local `experiments/` directory is empty, and no historical run settings, learning curves, or evolved champions were available for inspection. The bundled example can play complete games, but it is a test fixture with no established training history.

The agreed objective is: **show that evolution produces measurable improvement in Go.** The proposed first milestone is repeatable improvement on a small board under a fixed, trustworthy evaluation procedure.

## What exists today

| Component | Current behavior |
| --- | --- |
| [C engine](engine/generate_move.c) | Encodes each intersection as own stone, empty, or opponent stone, plus signed komi. A dense feedforward network produces one score per intersection and one for passing. |
| Move selection | Selects the highest scoring permitted move. Brown's board code handles captures and simple ko; extra filtering excludes suicide and some moves into the player's own territory. There is no lookahead. |
| [Initial population](initial-population/main.c) | Creates randomly initialized networks with a fixed architecture chosen in experiment settings. |
| [Breeding](evolve/evolve.c) | Either crosses two flattened weight arrays at one position, or copies a parent and mutates individual weights. Network topology does not evolve. |
| [Tournament harness](ruby/run_generation.rb) | Pairs neighboring entries in the ranking each round, randomizes colors, and runs games through GoGui with GNU Go as referee. |
| Selection | Awards 1 point for beating another network or Brown, 10 for AmiGo, 50 for GNU Go level 0, and 100 for level 10. Parent sampling is proportional to the cube of the score. |
| Local, uncommitted additions | Preserve the top player into the next generation, copy another selected player for about 10% of other births, preserve a previous champion as `best.ann`, and increase the number of Brown opponents. |
| [Statistics](stats) | Reports wins against external bots, archives result tables, and deletes older champions. |

More precisely, this is evolution of the weights of a fixed neural policy. That is a reasonable experimental choice; evolving program structure or network topology would be a different extension.

Useful existing choices include the shared perspective for Black and White, a separate pass output, legality filtering outside the network, external reference opponents, and saving progress after individual results. Elitism in the local changes is also a useful protection against losing the current tournament winner.

## Evidence from this assessment

Builds and tests ran in a temporary source copy, preserving the repository's code and existing build artifacts.

| Check | Observation | What it establishes |
| --- | --- | --- |
| Fresh `make` | Passed | The C components build locally. |
| `make test` | Passed | Existing library, crossover, and command smoke checks pass. |
| Ruby runtime | Pinned Ruby 3.3.0 is absent locally; syntax checks and focused probes used installed Ruby 3.4.7. | The normal Ruby entry point needs environment attention; this was not a test under the pinned version. |
| Two 9×9 games against Brown | The bundled example completed both games, one in each color, with GNU Go refereeing. Both result rows had `ERR=0`; the example lost both. | Protocol integration works for this fixture. Two games do not estimate the strength of evolved populations. |
| Result parser probe | `B+1.5` selects Black; `W+1.5`, `0`, and `?` all select White. | Draws and unknown results are demonstrably misclassified. |
| GTP without a saved network | Start engine, set board size to 9, then generate a move: engine exits because its initial network has 37 inputs/outputs and needs 82. | The README's example using `./engine/evo` on a 9×9 board is broken. |
| Empty-board scoring | On an empty 9×9 board with komi 6.5, the engine reports `W+87.5`. | The inherited internal scorer is unsuitable for arbitrary positions. |
| Inference cost (24 Sep) | A freshly initialized 9×9 network with 3 hidden layers of 400 neurons (≈387k weights) answered 1,000 `genmove` commands in 0.21 s, about 0.2 ms per move. Engine start and exit took about 10 ms. | Network evaluation is not a meaningful cost at the sizes used so far. |
| Game cost (24 Sep) | Via `gogui-twogtp` on 9×9: a random network against itself ended by passing after 18 moves and took 2.1–2.2 s in three runs. The example network against Brown (180 moves) and Brown against AmiGo (93 moves) took 0.16 s each. Without the referee, the 18-move game took 0.12 s. | GNU Go refereeing a sparsely played board dominated game time in this sample. Early-passing networks, which describes most of an untrained population, are the most expensive games to adjudicate. |
| Determinism (24 Sep) | Repeating the same pairing gave identical results and game lengths: the random network against itself three times, the example against Brown twice, and Brown against AmiGo three times with a second's pause between runs. | Evo is deterministic and Brown and AmiGo behaved deterministically here. The ten Brown and ten AmiGo instances are then likely copies of the same opponent, and replaying a pairing with the same colors gives no new information. |

Most assertions in `engine/test.c` exercise GENANN numerical behavior and persistence; the checks the experiment actually depends on are missing (see [Code cleanup](#code-cleanup)).

## What most affects the experiment

### 1. Fitness and reported progress need a clearer meaning

The tournament has a useful idea: match roughly comparable players while including fixed external bots. However, different networks can face very different schedules, colors are randomized rather than paired, and repeat pairings are allowed. A tournament score measures success in that particular schedule; it is not a stable measure of strength across generations.

The percentages in `stats` divide evolved-player wins by the total number of rounds played by external bot instances. Those rounds include games between external bots. Thus the display is not the evolved population's win rate in its actual games against each bot. Changes in pairings can change the percentage independently of playing strength.

The harness reads the correct referee column, but misclassifies draws, failures, and missing results ([defects table](#defects-that-can-change-results)).

**Proposed response:** explicitly represent wins, losses, draws, and failed/unfinished games; define how move-limit endings are handled; then maintain a fixed benchmark alongside breeding tournaments. Report wins and games played, separated by opponent and color. Keep tournament score and benchmark performance as different quantities.

### 2. Selection may concentrate the population too quickly

Cubing scores makes a score of 10 worth 1,000 times as much reproductive probability as a score of 1. Combined with external-opponent bonuses and uneven schedules, one exceptional result can dominate reproduction. This is a plausible cause of lost diversity, but there is no surviving run data here to demonstrate that it happened.

**Proposed response:** consider rank-based selection or a small parent-selection tournament, with explicit behavior for zero-score populations. Track unique genomes, distinct parents, and how much reproduction each parent receives. Preserve a small number of elites, while measuring whether selection leaves enough variation.

### 3. Mutation and crossover deserve separate experiments

Mutation changes each weight with probability 0.0004, using an additive perturbation between -0.5 and +0.5. There is also a 1% explicit chance of copying the parent unchanged. For a network with `W` weights:

`P(no changed weights on a mutation attempt) ≈ 0.01 + 0.99 × (1 − 0.0004)^W`

The bundled example has 418 weights, making this probability approximately **84.75%**. This calculation describes that architecture, not unknown historical runs. Larger networks receive more mutations per child under the same fixed rate. Changes in weights can also leave the chosen moves unchanged, so genetic and behavioral diversity are different measurements.

Crossover and mutation are mutually exclusive in `evolve/main.c`. Increasing the crossover rate reduces the number of mutation attempts. Crossing identical parents produces an identical child, which becomes relevant if selection concentrates the population.

Crossing raw weight arrays also assumes that hidden units occupy compatible roles in both parents. They need not: equivalent networks can place their internal features in different orders. This is a known issue discussed in the [original NEAT paper](https://nn.cs.utexas.edu/downloads/papers/stanley.ec02.pdf). Whether it is a major problem for Evo should be measured rather than assumed.

**Proposed response:** establish a mutation-only baseline and compare it with the present crossover scheme at equal game budgets. Treat the number of mutated weights and the size of each perturbation as separate controls. Record the actual fraction of unchanged children and optionally their move agreement on a small bank of positions.

### 4. The policy has to learn Go structure from very little guidance

The dense network receives a flat board and komi. It has no explicit liberties, capture features, previous-pass input, move history, or spatial weight sharing. The engine's legality checks handle immediate constraints, but the policy has no lookahead to examine consequences.

That makes a compact policy an interesting learning experiment, with substantial representational demands. In particular, a two-neuron hidden layer such as the bundled fixture compresses the whole board very aggressively; it should not be taken as a recommended training architecture.

Cached sigmoid outputs also create artificial score ties, which favor earlier intersections or passing; a linear output layer removes them ([Neural network library](#neural-network-library)).

**Proposed representation experiment:** use a small shared scorer for the 3×3 neighborhood around each candidate move. The owner's experience of slow runs without improvement makes this an early candidate, alongside a short check of scoring and variation. Additional tactical features and search remain choices to discuss.

### 5. Long runs need recoverable evidence

`clean_up_generation` deletes non-champion networks and every SGF from the previous generation, and `stats` later deletes older `best.ann` files. That saves space but prevents comparisons with early ancestors and inspection of interesting games. Runs also cannot be reproduced or safely resumed: seeds and code revision are not recorded, executables are symlinks to the current build, and the generation transition is not crash-safe. The fixes are listed under [Code cleanup](#code-cleanup).

**Proposed response:** preserve generation zero and a spaced archive of champions, retain selected SGFs, and keep evidence retention independent of viewing statistics.

## Go rules and scoring boundary

Brown's internal final-status algorithm assumes the board has been filled according to Brown's original move policy. Evo can pass earlier, so those assumptions do not generally hold. The GNU Go referee is consequently an important part of the current experimental setup: the internal scoring defect does not by itself establish that tournament winners are wrong.

Before treating results as reliable, specify the board size, komi, suicide policy, ko rule, scoring method, and adjudication of unfinished games. The local engine uses simple ko and accepts suicide through `play`, although its generated moves exclude suicide. Those conventions should agree with the surrounding match system.

## Comparing the owner's two proposed directions

### Shared 3×3 move scoring

The proposed design evaluates each legal candidate with the same small network:

`local board pattern + optional tactical/context features → shared network → move score`

Sharing the network is the key assumption: an evolved preference for a local shape applies wherever that shape occurs. Encoding board boundaries distinctly from empty intersections and treating colors relative to the player makes the inputs meaningful at edges and for either side. Equivalent rotations and reflections can share an encoding as well, provided associated features are transformed consistently.

Appending separate pattern inputs to the existing dense whole-board network would expose local structure, but would not by itself enforce this reuse. A shared scorer keeps the number of learned parameters independent of board area for a fixed feature set, although it must be evaluated at each candidate. Actual move speed relative to the present architecture needs measurement.

Pure 3×3 occupancy cannot describe all tactical situations. A neighboring chain can extend beyond the window and have liberties elsewhere. A small number of optional features—such as whether the move captures, saves a chain in atari, or leaves the played chain with one liberty—would expose this information. Passing also needs an explicit mechanism with enough whole-board context. Which features to supply is still open.

This is my recommended first representation experiment. The hypothesis is that reusable local features make useful behavior easier to evolve. Success must be measured as improvement within this representation from its own initial population, and against random search using the same representation. A stronger starting policy alone would not demonstrate learning through evolution.

### A network inside UCT-style search

Search and local patterns can be combined. There are three distinct roles for a network:

| Network role | What it supplies | Implication for Evo |
| --- | --- | --- |
| Guide exploration | A preference over candidate moves when expanding a search node. | A local move scorer could provide these preferences; incorporating policy priors requires a corresponding tree-selection rule rather than plain UCT alone. |
| Guide rollouts | Move choices during simulated games. | Calls to the policy occur repeatedly inside simulations, making their speed and effect on rollout outcomes important. |
| Evaluate leaves | An estimate of who will win from a position. | Requires a position-value output with consistent player perspective; existing move scores do not supply this value. |

There is direct precedent for combining learned knowledge with Go search. Gelly and Silver's [Combining Online and Offline Knowledge in UCT](https://www.davidsilver.uk/wp-content/uploads/2020/03/combining_uct.pdf) examines simulation policies and prior knowledge in 9×9 Go. One relevant finding is that a stronger standalone policy did not necessarily make a better simulation policy. Their work used reinforcement learning, so it motivates an experiment here without establishing a result for evolution.

For this repository, search also needs a way to copy or restore full board state, correct treatment of simulation endings and ko, and reliable simulation scoring. The current Brown board state is stored in static arrays and exposes neither a snapshot API nor undo. Its inherited scorer cannot simply be used on arbitrary search leaves.

My recommendation is to consider using the local scorer to guide exploration after establishing a useful direct policy. A subsequent experiment must compare search with evolved guidance against the same search with uniform or frozen initial guidance. Use equal simulation budgets to study guidance quality, and equal elapsed-time budgets to measure practical benefit; report both. Search adds work per move, but whether it reduces total compute needed to reach a target strength is an empirical question.

### Slow experiments: identify the cost before choosing the remedy

Each game launches a new GoGui process, two players, and a GNU Go referee. A first timing sample (see the evidence table) points away from the neural network and toward adjudication: inference took about 0.2 ms per move even for a 387k-weight network, while refereeing an 18-move game took about 2 s, more than ten times the cost of a complete 180-move game. The tournament also spends games on pairings that carry no selection signal: bots playing each other, and repeated deterministic pairings.

The remedies are to play network games in a [C arena](#a-c-arena-for-network-games) with cheap explicit scoring, to stop scheduling bot-against-bot games and duplicate deterministic bot instances, and to keep GoGui with GNU Go for benchmark games. The sample covers a few games on one machine; repeat it over a full generation, reporting games per minute at the intended concurrency, before relying on it. The first experiment should have a comfortable elapsed-time cap and checkpoint results within that cap.

## Code cleanup

The owner wrote the code quickly as a side project and does not fully trust it. A code review on 24 September supports that: several defects affect results or long runs, and much of the remaining code is duplicated or unused. The C/Ruby split can stay. The code needs a cleanup pass protected by tests before new representations are added, because each new experiment otherwise inherits these defects.

### Defects that can change results

These should be fixed first, each with a test that fails before the fix.

| Location | Problem | Effect |
| --- | --- | --- |
| [`ruby/run_generation.rb:180`](ruby/run_generation.rb) | Any result not starting with `B`, including `0`, `?`, and errors, counts as a White win; the `ERR` column and the `twogtp` exit status are ignored, and a missing `.dat` file raises. | Draws, failures, and timeouts feed into selection; a failed game can stop the run. |
| [`ruby/run_generation.rb:222`](ruby/run_generation.rb) | Parent pool is an array of `score³` copies of each filename. | One score of 500 already means 125 million entries (about 1 GB). An all-zero population gives an empty pool, and `picks.first` / `picks.sample` return `nil`, which breaks the `cp` and `evolve` calls. |
| [`ruby/run_generation.rb:237`](ruby/run_generation.rb) | `evolve` runs in backticks, its exit status is ignored, and it writes `child.ann` into the working directory. | A failed breed either stops the run (`mv` of a missing `child.ann`) or silently reuses a stale `child.ann` left by an earlier interrupted run. Breeding cannot safely run in parallel. |
| [`ruby/run_generation.rb`](ruby/run_generation.rb) `games_from_ranking` | External bots are paired with each other, and an odd player count gives the last-ranked player a free point (a "bye"). | Compute goes to games that carry no selection signal, and byes add points unrelated to play. |
| [`engine/generate_move.c:114`](engine/generate_move.c) | A network whose size does not match the board calls `exit(1)` inside `genmove`. | The process dies mid-game instead of returning a GTP error. `boardsize` should reject a size the loaded network cannot play. |
| [`engine/interface.c:153`](engine/interface.c) | The engine reports its name as `Brown`. | SGF files and GoGui output cannot tell Evo apart from the real Brown opponent. |
| [`stats:95`](stats) | `'average' => median(...)`. | The reported average is the median. |
| [`stats:145`](stats) | Deletes `best.ann` from all but the last 99 generations while displaying statistics, and archives and deletes `.dat` files as a side effect. | Opening a viewer destroys evidence. |
| [`multi:19`](multi) | References the undefined variable `next_input`. | A mistyped experiment name raises `NameError` instead of the intended message. |
| `engine/main.c`, `initial-population/main.c`, `evolve/evolve.c` | RNG seeded with `time(NULL)` and the address of the global `rng`. | Runs cannot be reproduced, and processes started in the same second rely on address randomization for different seeds. Seeds should be passed in and recorded. |

### Structure and hygiene

- **One copy of each shared file.** `genann.c` and `genann.h` exist in identical copies in `lib/`, `engine/`, `evolve/`, and `initial-population/`, and `minctest.h` in `lib/`, `engine/`, and `evolve/`. Every Makefile compiles its local copy. `lib/` is unused. Build shared code once from `lib/` (as a static library or shared object files) so a fix cannot land in one copy only.
- **Concurrency without Ractors.** The worker pool uses `Ractor.yield` and `Ractor#take`, which Ruby 4.0 removed in favor of `Ractor::Port` (checked against locally installed Ruby 3.4.7 and 4.0.5), so the harness will not run on current Ruby. Each generation also creates new Ractors and re-installs the `SIGINT` trap without stopping the previous ones. The workers only call `system`, which releases the interpreter lock, so a fixed pool of threads fed from a `Queue`, created once per experiment, is simpler and sufficient. Pin the new Ruby version through mise (next item).
- **Typed, validated settings.** `settings.json` stores every value as a string and converts with `.to_i` where used. Parse once into typed values, validate them, and add the fields the experiment needs (seed, code revision, opponent panel, scoring rules).
- **Atomic checkpoints.** `data.json` is rewritten directly after every game and read while being written by `ranking`, which silently skips a refresh when parsing fails. Write to a temporary file and rename it. Save the next generation's setup before deleting the previous generation's files, so a crash in between cannot lose the parents. Stop mixing string and symbol keys in game hashes (`games_from_ranking` creates symbol keys, but after a JSON round trip the code reads string keys).
- **Separate viewing from housekeeping.** `stats` and `ranking` should be read-only. Archiving, pruning, and notifications belong in the runner or a separate command. The `ntfy` notification builds a shell command from data; use `Net::HTTP` instead.
- **Copy executables into the experiment.** Symlinks to the build output mean a rebuild changes a running experiment. Copy the binaries and record the git revision.
- **Remove dead paths.** Remove the default 5-layer network created when `evo` starts without a file (it is sized for the default 6×6 board and fails on 9×9). Remove genann's text format and its backpropagation code, unless they are needed.
- **Test what the experiment depends on.** Add tests for Go rules (capture, ko, suicide, pass), result parsing (every `twogtp` result form), parent selection edge cases, mutation statistics, the file format round trip, and resuming a generation. Run the Ruby tests in CI next to the C tests (done: `mise run test` runs both). Record the fraction of offspring identical to a parent, not only that the code runs.
- **Pin the toolchain with mise.** The pinned Ruby 3.3.0 is not installed. GoGui needs Java, but no version is recorded. GNU Go, GoGui, Brown, and AmiGo are installed by hand from different places. Add a `mise.toml` that pins Ruby (moving to 4.0 together with the thread-pool change) and a Java version for GoGui, and replace `.ruby-version`. Define mise tasks (`build`, `test`, `run`, `stats`) as the documented entry points, and use `jdx/mise-action` in CI so CI builds with the same versions. Where mise has no plugin for a tool (GNU Go, Brown, AmiGo, probably GoGui), use a pinned install task that downloads a fixed release and checks its checksum. Record the tool versions in each experiment's metadata along with the git revision.
- **Update the README.** The "Running brown against itself" example is broken. Document how to benchmark a saved network instead.

### Neural network library

GENANN is used only for a dense forward pass, random initialization, copying, and a binary file format that was added locally. Training is never used. The vendored copy already differs from upstream (PCG random numbers and the binary format), so it cannot simply be updated.

Speed is not a reason to replace it: at 0.2 ms per move for a 387k-weight network, inference is small next to game adjudication. The reasons to replace it are that the experiment needs things GENANN does not provide:

- **Linear outputs for move choice.** Outputs pass through a sigmoid lookup table of 4,096 steps clipped at ±15. Move selection needs only the highest raw score, and sigmoid preserves order, so the table adds nothing but ties: saturated outputs compare equal, and the earliest intersection or pass wins. A linear output layer removes this artificial tie-breaking at no cost.
- **A file format that can evolve.** The binary format writes four native `int`s and native `double`s with no magic number, version, activation choice, or endianness. Its callers (`engine/interface.c`, `evolve/evolve.c`) do not check `fopen`, `genann_binary_read` does not check `genann_init` failures, and its error messages say `fscanf`. The shared 3×3 scorer needs a different network shape and metadata such as feature set and symmetry handling, which this header cannot describe.
- **Shared scorers and batching.** A per-candidate scorer evaluates a small network at up to 81 points per move. That is easiest to write as one small matrix evaluation over all candidates, which GENANN's single-input interface does not support.

**Recommendation:** replace GENANN with a small module owned by this project (on the order of 150 lines of C) containing a list of dense layers with configurable activations (`tanh` or ReLU hidden, linear output), `float` weights in one contiguous genome array (which keeps mutation and crossover simple), batched evaluation, and a versioned little-endian file format with a header. Keep a converter from the current `.ann` format, and check that converted networks choose the same moves on a fixed set of positions before removing GENANN. If much larger networks or search make inference significant later, add BLAS (Apple Accelerate or OpenBLAS `sgemm`) behind the same interface. General-purpose frameworks such as ONNX Runtime or libtorch would bring large dependencies and gradient machinery that evolution does not use, and are not warranted.

### A C arena for network games

The largest structural change suggested by the timing sample is a C program that loads a set of networks once and plays the scheduled network-against-network games in one process. It would reuse Brown's board code, score with an explicit rule set (Tromp–Taylor area scoring is simple and well defined when a game ends by two passes or the move limit), vary openings or seeds deliberately, and write one result line per game with an explicit outcome (win, loss, draw, or error). Ruby would still orchestrate generations, selection, and benchmarks. This removes JVM startup and the GNU Go referee from most games and makes games reproducible from a seed. Before switching, check on a sample of games that arena results agree with the GoGui/GNU Go results.

### Suggested cleanup order

1. Add characterization tests around current behavior: result parsing, parent selection, crossover and mutation, file round trip, and a short scripted GTP game. The evolve test suite now exits nonzero on failed assertions, so failures are visible. The tournament runner's result parsing, parent pool, breeding step, and pairings are now covered by `test/run_generation_test.rb` (minitest, run by `mise run test-ruby` and as part of `mise run test`); tests that pin a listed defect carry `defect` in their name. Crossover and mutation statistics, the file round trip, and a scripted GTP game are still open.
2. Fix the result-changing defects above, one change at a time, each with its test.
3. Consolidate shared C code into `lib/`, then replace GENANN as described above, verified against the converter.
4. Pin the toolchain with mise, replace Ractors with a thread pool, make checkpoints atomic, type the settings, record seeds and revision, copy the binaries, and make `stats` read-only.
5. Build the arena and move network-against-network games into it. Keep the GoGui path for benchmarks.
6. Split CI into separate steps (C tests, Ruby tests, `doctor`, refereed smoke matches) so a failed run shows which part broke. Today one `mise run verify` step runs all of them. The `test-c` and `test-ruby` mise tasks already exist for this.

Steps 1–2 are prerequisites for trusting any new experiment. Steps 3–5 can be interleaved with milestone 1 below. Each step should keep a short reference run able to complete and produce the same results where behavior is meant to be unchanged.

## Proposed sequence

These are candidate milestones for discussion, rather than an implementation commitment. The reported stagnation and long runtime move the shared-pattern experiment earlier in the sequence.

0. **Clean up the code under test.** Carry out steps 1–2 of the [cleanup order](#suggested-cleanup-order) before any new experiment, and the rest alongside milestone 1.
1. **Make a short experiment interpretable and affordable.** Choose 5×5 or 9×9, specify rules and komi, and verify a short run can resume safely. Measure runtime per generation and the fraction of unchanged offspring. Establish a reproducible benchmark containing weak external opponents and frozen initial networks.
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

This design remains provisional. Previous runs showed no visible improvement and took too long; the acceptable feature set and available compute should determine the next experiment's scale.

## Direction choices

The selected direction is understanding evolution through measurable improvement in Go. The other directions remain possible later extensions.

| Direction | What it would emphasize | Main tradeoff |
| --- | --- | --- |
| Understand evolution on Go | Keep the current C/Ruby split; make results reproducible; compare evolutionary operators. | Playing strength may remain modest, but experiments become informative. |
| Build an enjoyable opponent | Add useful Go features and potentially search, with evolution optimizing the policy or evaluator. | More strength may come from authored Go knowledge and search. |
| Explore evolving structures | Investigate topology evolution, indirect encodings, or program evolution after establishing a baseline. | Larger experimental and implementation scope. |

There is precedent for training substantial neural policies with genetic algorithms: [Such et al., Deep Neuroevolution](https://arxiv.org/abs/1712.06567) demonstrated this on Atari and locomotion tasks. That supports taking the idea seriously, but does not establish how well the present Go setup should learn or what compute it needs.

## Questions to settle together

- Which network sizes, populations, and approximate runtimes were used before? Do historical results or champions exist elsewhere?
- For a shared 3×3 scorer, should the first version use occupancy patterns alone or also a few tactical features such as liberties and captures?
- What hardware and unattended runtime are comfortable for a single experiment?
- Is it acceptable for network-against-network games to use the project's own Tromp–Taylor scoring instead of the GNU Go referee, with GNU Go kept for benchmarks?
- Should the harness stay in Ruby (moving to 4.0 with a thread pool), or should orchestration move into the C code along with the arena?
- Which board size and first opponent would make a satisfying initial milestone?

## Decision log

- Agreed scope: assess and discuss the project, culminating in a working document; no implementation changes now.
- Agreed objective: show that evolution produces measurable improvement in Go.
- Owner's observations: play never visibly improved, and experiments took a long time. The owner had considered 3×3 pattern inputs or a neural network inside UCT-style search.
- Current recommendation: address the essential measurement defects and profile a short run, then test evolution of a shared local pattern scorer. Treat search as a possible follow-on that needs its own control experiment.
- Code review (24 Sep): the code needs a test-protected cleanup pass before new experiments. Several defects change results. GENANN should be replaced by a small module owned by the project, for control over outputs, file format, and batching rather than for speed. Timing points to GNU Go adjudication and wasted pairings as the main costs, not inference.
- Toolchain follow-up: the mise setup keeps Ruby at 3.3.0 so the current runner remains usable. Upgrade Ruby to 4.0 in a separate change together with replacing the Ractor worker pool and testing experiment runs under the new version.
- External tool setup follow-up (24 Sep): `mise run setup-experiments` installs checksum-pinned GNU Go 3.8, Brown 1.0, AmiGoGtp 1.8, and GoGui 1.6.0 in the project directory. `mise run verify` includes a complete GoGui match with the GNU Go referee. The macOS setup and match passed; the Linux CI run passed on `main` after merge.
- Test exit status (24 Sep): `evolve/test.c` now returns nonzero when an assertion fails, so `make test` no longer passes over failed crossover checks.
- GNU Go referee (24 Sep): GNU Go 3.8's `gg_sort` forms an out-of-range pointer when sorting zero elements. With Apple clang this aborted GNU Go in `final_score` on every game and during level 10 move generation, so every referee result was `?` and the runner scored it as a White win. GCC builds (Linux CI) are unaffected: with a fixed `--seed`, unpatched and patched builds play identical moves. The smoke match only checked the Black engine's own score, so `mise run verify` passed on macOS anyway. The installer now patches `gg_sort`, and `verify` plays a refereed match with each external opponent and Evo and fails on a program error or a missing referee score. Earlier timing samples and results that depended on a clang-built GNU Go referee should be rechecked. Without `--seed`, GNU Go seeds its random choices from the clock, so unlike Brown it varies between runs started in different seconds.
- Ruby characterization tests (24 Sep): the runner has minitest coverage, run in CI through `mise run test`. Real GoGui result files showed two more cases the runner scores silently: a player that crashes mid-game still gets the referee's score for the position (`ERR` 1, `RES_R` `B+17.5` for the crashed Black), and a game stopped by the move limit is flagged `ERR` 1 but scored normally. A referee that fails to start leaves no `.dat` file, which raises `Errno::ENOENT`. The result-parsing fix should treat all three explicitly. A two-generation smoke run with 4 networks crashed while breeding generation 1: no network won a game, so the parent pool was empty. Because this happens in the smallest runs, the parent-pool fix is more urgent than the notes suggested. The owner wants CI split into one step per check; that is cleanup step 6.
- Benchmark, compute budget, acceptable built-in Go knowledge, and first implementation milestone: open.
