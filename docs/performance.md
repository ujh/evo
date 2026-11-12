# Performance

How to measure a change's cost, the two fixed workloads that compare complete generations, and the measured costs that set a default or a design or that `PROJECT_NOTES.md` relies on.
Read before optimizing.

## How to measure

- Record numbers only from a quiet machine: pause other work first.
- Run at concurrency 3 (owner, 29 Sep 2026: "Using 8 cores is not a good idea anyway, as this CPU essentially only has 4 cores that are truly parallel. Considering other work (even the OS itself), running with more than 3 in parallel isn't a great idea anyway.").
  The M3 (Mac15,3, 24 GiB) the workloads were defined on has 8 cores, 4 of them performance cores, so 8 jobs oversubscribe them: the same games took 1.7–2.0 times the worker time at 8 as at 3.
  Keep 3 on other machines so runs compare, and state the machine.
- Between code versions only wall time, loading, Ruby time, and memory compare directly: pairings diverge once results differ, and they can differ from round 1 on, where two copies of one bot are ranked next to each other and the later pairs shift.
- A benchmark's time depends on the champion it plays, so compare it only within one panel; it also varies between runs with GNU Go's games (46.6–53.4 s for the same 80 games of the large workload's generation 1).
- Peak RSS is sampled every second, so short peaks can be missed, and the summed figure counts shared pages in every process that maps them.

## Fixed workloads

`mise run profile-workload small|large` (`scripts/profile-workload.sh`) creates the workload's experiment with `mise run new-experiment`, runs generations 0 and 1 as two invocations of `mise run run NAME --concurrency 3 --one-generation`, writes the results to a file outside the repository, prints a summary, and deletes the experiment.

- `--results FILE`, `--keep`, and `--tiny` (4 networks, 2 rounds, only to test the script; its numbers mean nothing) are described in the script's header; a failed or interrupted invocation keeps the experiment.
- The large workload needs 15 GiB free for `experiments/` (it peaks at about 9 GiB), the small one 2 GiB.
- The workloads keep the panel they were defined with, so a change of `SetupExperiment`'s defaults does not redefine them: after `new-experiment` and before any run the script replaces, with `sqlite3`, the experiment's `opponents` with Brown `brown` ×5 and AmiGo `amigogtp` ×10, and its `benchmark_opponents` with Brown `brown`, AmiGo `amigogtp`, GnuGoLevel0 `gnugo --level 0 --mode gtp`, Gen0Champion, and PastChampions.
- `--default-panel` keeps the defaults `new-experiment` stored instead, to measure the current panel against the pinned one at the same seed.
  `--tiny --default-panel` also uses `experiments/profile-WORKLOAD-tiny`, so delete one before running the other.
- Right after creating (and pinning) the experiment, the script checks that its `opponents` and `benchmark_opponents` rows are the requested panel and exits, keeping the experiment, if not.
  The results file names the requested panel in its header and lists both panel tables and the check under `## Create`; the summary names the panel read back from the database.

Settings of both workloads: 9×9, `features` `shapes,tactics,last_move,liberties`, `game_seconds` 600, `max_moves` 200, 10 rounds, `tournament_size` 3, `keep_every` 1, `benchmark_games` 20, `benchmark_bot_games` 0, `benchmark_opening_moves` 4, komi 6.5, `meta_rate` 0.2, `initial_copy_chance` 0.01, `initial_weight_step` 0.5, `initial_feature_noise` 0.3, `initial_feature_step` 0.01, the default scoring, and the pinned panel (or the defaults with `--default-panel`).

- `keep_every` 1 makes both generations checkpoints, so the benchmark's time is part of the results: with the pinned panel generation 0 plays the three bots (60 games) and generation 1 also generation 0's champion (80 games); with `--default-panel` the seven bots (140 games) and 160; `past_champions` plays none, since the only earlier checkpoint is generation 0.
- `benchmark_bot_games` 0: the bot-vs-bot games an experiment plays once, at its first checkpoint, are no per-generation cost.
- Small, bot-heavy (`bigrun`'s settings): `experiments/profile-small`, seed 777, 50 networks of 1 hidden layer of 100 (`max_hidden_layers` 3, `max_layer_size` 150), crossover rate 0.5, `initial_weight_changes` 42.3128, `initial_activation_rate` 0.05, `initial_structure_rate` 0.1; a network is about 0.85 MB.
- Large, arena-heavy (`even-bigger`'s settings): `experiments/profile-large`, seed 5318103715471647440, 1,000 networks of 10 hidden layers of 200 (`max_hidden_layers` 100, `max_layer_size` 1000), crossover rate 0.4, `initial_weight_changes` 229.3128, `initial_activation_rate` 0.02, `initial_structure_rate` 0.02; a network is about 4.6 MB.

The results file holds, per invocation, the hardware, the runner's `timings` line (`docs/experiment-reference.md`, Running experiments), `/usr/bin/time`, the sampled peak RSS, the runner's CPU and GC totals (`EVO_PROFILE=FILE`, `ruby/process_profile.rb`), game counts and durations, disk use, and the arena's load time over the generation's networks; each block says what it covers, including that invocation 2 first re-enters generation 0.

## Measured costs

Each figure names the revision and concurrency it was measured at where the measurement recorded them; one run each unless stated.

### The default panel on the large workload

At `36ef628`, concurrency 3, quiet machine, pinned panel then `--default-panel` at the same seed; seconds, generation 0 / generation 1.
The default panel then had six bots in the benchmark (120 / 140 games); GNU Go level 10, added to the default panels since, is not measured.

| | pinned panel (Brown, AmiGo) | default panel (the whole ladder) |
| --- | --- | --- |
| timings `total` | 117.3 / 118.5 | 164.5 / 182.1 |
| `setup` | 21.0 / 11.5 | 19.2 / 10.7 |
| `tournament` (10 rounds) | 45.6 / 53.3 | 110.3 / 127.5 |
| a round | 4.19–5.40 / 5.14–5.67 | 8.11–17.97 / 8.79–16.83 |
| `worker` | 133.7 / 157.2 | 300.4 / 327.1 |
| `ruby` | 14.3 / 13.4 | 13.8 / 14.1 |
| `benchmark` | 50.6 / 53.7 | 35.0 / 43.9 |

- The default panel makes a generation 40–54 % slower (+47.2 s in generation 0, +63.6 s in generation 1), nearly all of it in the tournament: a round lasts as long as its slowest chunk with a GNU Go game, 8–18 s instead of 4–6 s.
- The worker time roughly doubles for 90 more games a generation: the 18 new bot copies each play one game a round, and those games are long, since the bots play until no dead stones are left (about 120 moves, `docs/experiment-reference.md`).
- Ruby's time and memory do not change.

### The benchmark on the small workload

- A small generation takes about 30 s, about 28 s of it the benchmark (`69a157c`, concurrency 8, pinned panel, two runs: `total` 28.7–29.9 s, `benchmark` 26.8–28.0 s).
- The benchmark plays every game through `gogui-twogtp` with the GNU Go referee, most of its time in the games against GNU Go level 0.
- On the small workload (`69a157c`, concurrency 8) a tournament game with a bot costs 0.02–0.03 s of worker time in the arena against 0.49–0.55 s through GoGui, a JVM, and the GNU Go referee; the bots' own move time is under 0.05 s a side a game, so the rest is process overhead.

### The runner's main thread

- The runner scores each arena record on the main thread as it arrives, while the arenas play.
- On the large workload at concurrency 3 (`40a5043`) the main thread was busy 14.1 / 14.9 s of a 50.2 / 59.6 s tournament, which ended within 1 s of the summed worker time divided by 3 (49.3 / 58.8 s).
- At concurrency 8 (`40a5043`) it was busy 23.3 / 26.6 s of a 32.2 / 46.2 s tournament.

### Chunks per worker

`RunGeneration::CHUNKS_PER_WORKER` is 4 from this measurement (large workload, concurrency 3, quiet machine):

- Against one chunk per worker without streaming (`339eaa1`), four chunks per worker with streaming (`40a5043`, about 42 games a chunk) cut the tournament from 58.1 / 67.5 s to 50.2 / 59.6 s with the same worker time, since the arenas no longer idle between chunks.
- One chunk per worker with streaming gained less (54.4 / 61.6 s), since a worker whose chunk ends early idles until the round ends; that run began at a load average of 9.5.
- An arena loads only its chunk's networks, so the largest process fell from 1,478 to 377 MiB and the summed peak RSS from about 4.1–4.4 GiB to about 1.2 GiB.
- At about 42 games a chunk no minimum number of games per chunk is needed.

### Loading networks: why arenas stay fresh

The runner starts a fresh arena for every chunk; arenas kept alive across rounds and read-only mapped `.ann` files were not built.

- Loading a large network for play (`ann_binary_read_for_play`, without `genann_init`'s random fill) takes about 0.7 ms, against about 2.3 ms with the fill (a rough timing taken while building `9bc3ab5`, one arena, machine not quiet).
- Persistent arenas, measured on a throwaway branch never merged (`measure/persistent-arena`) at 2.3 ms loads (large workload's generation 1, concurrency 3, two runs each), saved 4.7 s a generation (8.2 % of the tournament) for about 4 GiB an arena instead of about 373 MiB a chunk, so about 12 GiB for 3.
- With 0.7 ms loads they would save roughly 1.5–2 s a generation (an estimate, not measured) for about 11 GiB more memory and the complexity of arenas that outlive a round (interruption, resume, the pool's contract), so they were not built.
- Mapping the `.ann` files read-only (considered, not measured) would need a padded format v3 and GENANN's single allocation split so the weights are a separate pointer; not worth it unless loading matters again.

### Setup on the large workload

- With breeding on the pool at concurrency 8 (`48c52f5`), generation 1's `setup` took 8.4 s, 6.4 s of it hashing each network on the main thread (`setup_hash`), so hashing is the next thing to move off the main thread if setup matters again.
