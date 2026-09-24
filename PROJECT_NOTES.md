# Evo: assessment and next experiments

Working draft, 23 September 2026. This records an assessment of the current checkout and proposals for discussion. The owner has chosen measurable improvement from evolution as the objective; the experiment design and milestones remain proposals. No implementation changes were made for this assessment.

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

Most assertions in `engine/test.c` exercise GENANN numerical behavior and persistence. There are no comparable automated checks of Go rules, mutation behavior, Ruby result interpretation, generation recovery, or improvement in playing strength. The crossover unit test also does not propagate its assertion-failure count as the process exit status.

## What most affects the experiment

### 1. Fitness and reported progress need a clearer meaning

The tournament has a useful idea: match roughly comparable players while including fixed external bots. However, different networks can face very different schedules, colors are randomized rather than paired, and repeat pairings are allowed. A tournament score measures success in that particular schedule; it is not a stable measure of strength across generations.

The percentages in `stats` divide evolved-player wins by the total number of rounds played by external bot instances. Those rounds include games between external bots. Thus the display is not the evolved population's win rate in its actual games against each bot. Changes in pairings can change the percentage independently of playing strength.

The harness correctly reads GoGui's referee result column. However, it ignores the error flag and treats every result not starting with `B` as a White win. A failed or truncated game can therefore affect selection, and a missing result file can stop the run. The worker also discards the subprocess exit status.

**Proposed response:** explicitly represent wins, losses, draws, and failed/unfinished games; define how move-limit endings are handled; then maintain a fixed benchmark alongside breeding tournaments. Report wins and games played, separated by opponent and color. Keep tournament score and benchmark performance as different quantities.

### 2. Selection may concentrate the population too quickly

Cubing scores makes a score of 10 worth 1,000 times as much reproductive probability as a score of 1. Combined with external-opponent bonuses and uneven schedules, one exceptional result can dominate reproduction. This is a plausible cause of lost diversity, but there is no surviving run data here to demonstrate that it happened.

The implementation also creates a literal array containing `score³` copies of each parent's filename. A single score of 500 produces 125 million entries, approximately 1 GB of references on a 64-bit Ruby, before other overhead. If every evolved player scores zero, the parent pool is empty.

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

The cached sigmoid outputs also have finite resolution and clipping. Exact score ties favor earlier board intersections, or passing when the best board score ties the pass score. Saturation and tie frequency are worth measuring if larger networks plateau; they have not been measured here.

**Proposed representation experiment:** use a small shared scorer for the 3×3 neighborhood around each candidate move. The owner's experience of slow runs without improvement makes this an early candidate, alongside a short check of scoring and variation. Additional tactical features and search remain choices to discuss.

### 5. Long runs need recoverable evidence

`clean_up_generation` deletes non-champion networks and every SGF from the previous generation. The statistics script then removes older `best.ann` files as it runs. These choices save space but prevent later comparisons with early ancestors and inspection of interesting games.

Experiment settings omit random seeds, code revision, and executable versions. Experiment executables are symlinks to the current build. A rebuild can therefore change the engine used by a resumed experiment. The C seed uses time and a process address, while Ruby randomness is not recorded.

There are also two concrete lifecycle concerns: each `RunGeneration` creates new Ractors with no normal completion shutdown, and previous-generation files are removed before the next generation's setup checkpoint is saved. A crash in that transition can make restarting impossible from the original parents. Checkpoint JSON itself is overwritten directly.

**Proposed response:** preserve generation zero and a spaced archive of champions, retain selected SGFs, record seeds/configuration/code identity, and make checkpoints and generation transitions recoverable. Give workers an explicit lifetime. Keep evidence retention independent of viewing statistics.

## Go rules and scoring boundary

Brown's internal final-status algorithm assumes the board has been filled according to Brown's original move policy. Evo can pass earlier, so those assumptions do not generally hold. The GNU Go referee is consequently an important part of the current experimental setup: the internal scoring defect does not by itself establish that tournament winners are wrong.

Before treating results as reliable, specify the board size, komi, suicide policy, ko rule, scoring method, and adjudication of unfinished games. The local engine uses simple ko and accepts suicide through `play`, although its generated moves exclude suicide. Those conventions should agree with the surrounding match system. Targeted capture, ko, pass, and final-position checks would be more relevant than increasing the number of neural-library assertions.

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

The harness launches a new GoGui process, two players, and a referee for each game. That makes startup a plausible source of overhead, but neither startup nor neural inference has been profiled. External-opponent computation, referee work, game length, checkpoint writes, and breeding can also matter.

A short timing sample should separate startup, game play, adjudication, and generation overhead, and report games per minute at the intended concurrency. If startup dominates, batching games or reusing processes may help. If opponents dominate, use cheaper opponents for breeding and stronger ones for periodic evaluation. If policy execution dominates, then representation and inference changes deserve attention. The first experiment should have a comfortable elapsed-time cap and checkpoint results within that cap.

## Proposed sequence

These are candidate milestones for discussion, rather than an implementation commitment. The reported stagnation and long runtime move the shared-pattern experiment earlier in the sequence.

1. **Make a short experiment interpretable and affordable.** Choose 5×5 or 9×9, specify rules and komi, correct result handling, retain useful evidence, and verify a short run can resume safely. Measure the main runtime costs and the fraction of unchanged offspring. Establish a reproducible benchmark containing weak external opponents and frozen initial networks.
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
- Which board size and first opponent would make a satisfying initial milestone?

## Decision log

- Agreed scope: assess and discuss the project, culminating in a working document; no implementation changes now.
- Agreed objective: show that evolution produces measurable improvement in Go.
- Owner's observations: play never visibly improved, and experiments took a long time. The owner had considered 3×3 pattern inputs or a neural network inside UCT-style search.
- Current recommendation: address the essential measurement defects and profile a short run, then test evolution of a shared local pattern scorer. Treat search as a possible follow-on that needs its own control experiment.
- Benchmark, compute budget, acceptable built-in Go knowledge, and first implementation milestone: open.
