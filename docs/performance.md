# Performance

- For large populations, arena startup was dominated by reading weights one double at a time. The reader now loads little-endian weights directly on little-endian hosts and decodes in 4,096-weight blocks elsewhere, preserving the portable file format. On the `even-bigger` experiment's 9×9 networks (1,000 networks, 10 rounds; the network files total 4.59 GB in generation 0 and 4.89–4.91 GB in generations 100–310, 28 Sep 2026), a 20-game sample with 40 distinct networks took 0.525–0.528 s in the old arena and 0.108–0.109 s with the new reader at `max_moves` 0; at `max_moves` 200, it took 1.106–1.115 s before and 0.691–0.698 s after (three paired runs, 27 Sep 2026).
- With direct reads, a larger 100-game sample using 200 distinct networks took 2.612 s in the old arena and 0.443–0.447 s with minimal play; at `max_moves` 200 it took 5.598 s before and 3.419–3.446 s after. Results and moves matched, excluding the timing fields. One full-sized arena chunk of 250 games and 500 networks took 1.456 s with minimal play and 8.727 s at `max_moves` 200. These measure arena runs, not full-round or generation wall time; the runner still starts fresh arenas each round.
- The tournament's bots are only Brown and AmiGo. GNU Go does not play there (and, since every tournament game went into the arena, no longer referees there either): GNU Go opponents, at level 0 as much as level 10, set most of a generation's wall time while early networks are far too weak for them. It comes back through the opponent ladder in `PROJECT_NOTES.md`. GNU Go level 0 does play in the benchmark.
- A checkpoint's benchmark with the default panel, on 9×9 with concurrency 2 (25 Sep 2026), took 52–69 s, most of it the 20 games against GNU Go level 0. The tournament of 4 networks in the same generations took 2–19 s.
- One generation profiled on macOS (25 Sep 2026, 8 cores, patched GNU Go): 9×9, 20 networks with 1 hidden layer of 100, 10 rounds, `max_moves` 200, seed 1, concurrency 4, `keep_every` 0, generation 0, with the 15 Brown and AmiGo copies: 170 games, two runs each.
  - With the arena: 8.5–8.7 s of wall time, about 1,200 games a minute. The 69 games between two networks took 0.9–1.4 s of summed `duration` (median 0.005 s, 90th percentile 0.010 s). The 101 GoGui games with a bot took 27 s (median 0.27 s, 90th percentile 0.31–0.33 s, slowest 0.5 s), nearly all the game time.
  - With every game through GoGui (`main` before the arena, same settings): 25.7–28.1 s of wall time, 65–73 s of summed `duration`, median 0.30–0.34 s, 90th percentile 0.41–0.50 s. In the slower run the network games took 39 s of the 73, and the slowest (up to 4.4 s) ended early and left the referee an unfinished position.
  - A network answers in under a tenth of a second, so its `time_black`/`time_white` read 0.0, and a GoGui game's whole `duration` is overhead: JVM, referee, and process starts.
  - Each round waits for its slowest job. The per-round lower bound, max(slowest game, summed durations / concurrency), came to 7.1 of the 8.5 s; the rest is setup (the initial population; the profile was generation 0, so no breeding), per-game bookkeeping, and jobs packing unevenly onto the workers.
  - GNU Go against a network took about 7 s a game at level 0 or 10 (up to 13.7 s against AmiGo), measured before the arena with both levels in the tournament's panel: once GNU Go opponents return, each round waits for such a game.
  - Storage: a network's `.ann` is 8 × total weights + 86 bytes (header, genes, feature mask, and `feature_step`) + 8 per feature weight, total weights as `SetupExperiment.total_weights` counts them. On 9×9 without features (`none`), 1×10 is 14 kB (85 kB with `all`: 10,652 weights); the default bounds' largest, 4×200, has 153,682 weights (1.23 MB) without features and 332,082 (2.66 MB) with `all`; 4×200 on 19×19, 2.1 MB without and 8.5 MB with. Until 29 Sep 2026 a kept checkpoint stored every network of its generation, so 20 networks at 4×200 on 9×9 with `all` took about 53 MB per checkpoint (25 MB with `none`); since then it stores only its champion, and a generation's networks are files in `networks/N/` (`docs/experiment-reference.md`).
  - A 20-generation run with the default genes and bounds (26 Sep 2026, same machine), once with `--features all` and once with `--features none`: 9×9, 20 networks of 1×50 (52,932 weights with `all`, 8,332 with `none`), crossover rate 0.5, `max_moves` 200, 5 rounds, `keep_every` 5, `benchmark_games` 10, seed 2026, concurrency 4 (command and results in `docs/features.md`). A generation (85 games, breeding included, timed around `mise run run`) took 4.2–4.8 s with `all` and 4.0–4.6 s with `none`; a checkpoint 17.5–21.2 s and 20.2–21.8 s, most of it the benchmark (30–50 games, most of the time against GNU Go level 0); 2.5 min in all either way, since the GoGui games with bots dominate. The database ended at 52 MB with `all` and 8.8 MB with `none` (as on 25 Sep): 8.5 and 1.33 MB of networks per kept generation (4 checkpoints plus the current generation), 0.28 MB of SGFs from the checkpoints, and little else. The `none` run gave the same genes medians as the same run before features (25 Sep). SQLite does not shrink the file when a generation's networks are dropped, so it grows in steps of a generation's networks and reuses the freed pages afterwards.
  - Features cost about 10× in the arena, still little: 90 games between 10 seeded 9×9 1×50 networks (`initial-population` seed 11, `max_moves` 200, mean length 84–87) took a median of 0.0003 s per game without groups and 0.0033 s with all (974 inputs, 52,932 weights), about 3 and 37 µs per move (26 Sep 2026).
  - Engine inference is negligible: a 9×9 network with 3 hidden layers of 400 neurons (about 387k weights) answered 1,000 `genmove` commands in 0.21 s (24 Sep 2026). Engine start and exit took about 10 ms.
- Two fixed workloads compare complete generations across changes (defined 28 Sep 2026). `mise run profile-workload small|large` (`scripts/profile-workload.sh`) creates the workload's experiment with `mise run new-experiment`, runs generations 0 and 1 as two invocations of `mise run run NAME 8 one-generation`, writes the results to a file outside the repository (`--results FILE`, default `${TMPDIR:-/tmp}/evo-profile-NAME-TIMESTAMP.txt`, each invocation's full output next to it), prints a summary, and deletes the experiment (`--keep` keeps it; a failed or interrupted invocation keeps it too). It refuses to start unless `df` shows at least 2 GiB free for `experiments/` (small) or 15 GiB (large; since networks live in `networks/N/` the large workload peaks at about 9 GiB, estimated from the design: while generation 1 is bred, `networks/0/` and `networks/1.partial/` at 4.3 GiB each, plus a database that holds only the games and the two champions; before, it peaked at about 17 GiB, both generations' networks in the database and in `work/`, and the threshold was 25 GiB). `--tiny` runs 4 networks, 2 rounds, and 2 benchmark games per opponent (`experiments/profile-WORKLOAD-tiny`), only to test the script; its numbers mean nothing. Record numbers only from a quiet machine.
  - Both: 9×9, `features` `shapes,tactics,last_move,liberties`, `game_length` 10, `max_moves` 200, 10 rounds, `tournament_size` 3, `keep_every` 1 (so both generations are checkpoints and run the benchmark, whose time is part of the results: generation 0 plays the three bots, 60 games, and generation 1 also generation 0's champion, 80 games; `previous_checkpoint` is skipped, since it would be generation 0), `benchmark_games` 20, `benchmark_opening_moves` 4, komi 6.5, `meta_rate` 0.2, `initial_copy_chance` 0.01, `initial_weight_step` 0.5, `initial_feature_noise` 0.3, `initial_feature_step` 0.01, and the default opponents (Brown ×5, AmiGo ×10), benchmark panel, and scoring. Concurrency 8, the core count of the 8-core M3 (4 performance and 4 efficiency cores) the workloads were defined on, so every core has a job; keep 8 on other machines so runs compare, and state the machine.
  - Small, bot-heavy (`bigrun`'s settings): `experiments/profile-small`, seed 777 (`bigrun`'s), 50 networks of 1 hidden layer of 100 (`max_hidden_layers` 3, `max_layer_size` 150), crossover rate 0.5, `initial_weight_changes` 42.3128, `initial_activation_rate` 0.05, `initial_structure_rate` 0.1. A network is about 0.85 MB.
  - Large, arena-heavy (`even-bigger`'s settings): `experiments/profile-large`, seed 5318103715471647440 (`even-bigger`'s), 1,000 networks of 10 hidden layers of 200 (`max_hidden_layers` 100, `max_layer_size` 1000), crossover rate 0.4, `initial_weight_changes` 229.3128, `initial_activation_rate` 0.02, `initial_structure_rate` 0.02.
  - Per invocation the results file holds the command lines, the hardware (model, cores, RAM, OS), the `timings` line, the exit status and wall time, `/usr/bin/time -l` (`-v` on Linux) around `mise run run` (its CPU times and maximum RSS cover mise, the runner, and every process they waited for, and the RSS is the largest single process, not a sum), the peak RSS sampled every second (summed over the whole process tree, shared pages counted in every process that maps them so above physical memory, and the runner's own), the runner's own CPU time and Ruby GC totals, the tournament games by scorer with failures and summed durations (not move times: the runner stores an arena game's to a tenth per side, so they read about 0), the benchmark games, the stored networks' count and bytes per generation (every network of a kept generation until 29 Sep 2026, only its champion since), disk use (with `networks/`), and the arena's startup and load cost: after the invocation, one arena over every network of the generation (in `work/` until 29 Sep 2026, in `networks/N/` since), each loaded once, at `max_moves` 0, one untimed run to warm the file cache and then three timed runs, with its wall time, its games' own time, and its maximum RSS. The runner's CPU time and GC totals come from `EVO_PROFILE=FILE`, which makes the runner write one line to FILE when it exits (`ruby/process_profile.rb`): `utime` and `stime` of the runner process, `child_utime` and `child_stime` of the processes it waited for, and `GC.stat`'s runs, time, and allocated and freed objects.
  - Invocation 2's wall time, `/usr/bin/time` figures, and runner CPU and GC totals include re-entering generation 0 first: a `one-generation` run starts at the last generation in the database, empties `work/`, deletes the network directories it no longer needs (until 29 Sep 2026 it exported that generation's 4.6 GB of networks from the database instead, about 2–5 s on the large workload), finds nothing left to play (a finished tournament skips verifying `networks/0/`), and goes on to generation 1. Its `timings` line covers generation 1 only. The results give the re-entry's approximate length, from the two generation headers' clock times (1 s resolution).
  - `setup` widened on 29 Sep 2026: it now also includes emptying `work/` (deleting the previous generation's networks, about 4.6 GB on the large workload), which the runner used to do before starting the timer, so a `setup` from then on is not directly comparable with the figures above, which leave that out; its own part is `setup_clear`, and subtracting it gives the old meaning. From then on the `timings` line also splits `setup` into its parts, and the script's summary lists them after `setup`: first `setup_clear`, `setup_parents`, `setup_breed`, `setup_store` (inside `setup_breed`, not to be added to it), `setup_save`, and `setup_export`; since networks live on disk (later on 29 Sep 2026) `setup_clear`, `setup_breed`, `setup_hash` and `setup_store` (both inside `setup_breed`), `setup_sync`, `setup_save`, `setup_retire`, and on resume `setup_verify`, plus `champion` after the tournament (`docs/experiment-reference.md`).
  - The script builds and runs `mise run doctor` before the first invocation, so the timed invocations' own build and doctor steps find nothing to do. The workloads keep their settings when the code changes; pairings diverge after round 1 once results differ, so between versions only wall time, loading, Ruby time, and memory compare directly.
  - First results (28 Sep 2026, git `bf442ec`, Apple M3 Mac15,3, 8 cores (4 performance, 4 efficiency), 24 GiB, macOS 26.6.2; concurrency 8; the commands above with `--results FILE`; one run each; other work paused, though the load average was 2.6 just before the small run started). Times in seconds; "timings" are the runner's `timings` line, "wall" is `/usr/bin/time`'s real time around `mise run run`; S0 is the small workload's generation 0.

    | | S0 | S1 | L0 | L1 |
    | --- | --- | --- | --- | --- |
    | wall (`/usr/bin/time`) | 41.1 | 40.6 | 146.1 | 173.9 |
    | timings `total` | 40.9 | 40.3 | 145.8 | 169.2 |
    | `setup` (creating or breeding, storing, exporting) | 0.8 | 1.1 | 39.2 | 49.2 |
    | `tournament` (10 rounds) | 9.7 | 9.7 | 82.4 | 86.6 |
    | a round | 0.75–1.71 | 0.76–1.59 | 7.75–9.49 | 8.46–9.24 |
    | `ruby` (runner outside waiting for jobs) | 1.29 | 1.37 | 57.1 | 56.9 |
    | `ruby` per round | 0.10–0.15 | 0.12–0.18 | 5.53–6.08 | 5.52–5.94 |
    | `worker` (summed job wall time) | 67.8 | 67.8 | 318.6 | 348.0 |
    | `benchmark` | 30.3 | 29.5 | 24.2 | 33.1 |
    | tournament games (none failed) | 320 | 320 | 5,070 | 5,070 |
    | GoGui games with a bot: count, summed `duration` | 117, 62.2 | 117, 64.4 | 138, 99.6 | 138, 93.9 |
    | arena games: count, summed `duration` | 203, 5.6 | 203, 3.5 | 4,932, 219.0 | 4,932, 254.1 |
    | benchmark games (none failed): count, summed `duration` | 60, 209.2 | 80, 206.9 | 60, 170.9 | 80, 245.6 |
    | runner CPU, user + sys | 0.72 + 1.14 | 0.79 + 1.40 | 60.0 + 9.7 | 60.4 + 16.6 |
    | runner allocated objects | 1.69 M | 1.75 M | 241.4 M | 243.0 M |
    | runner GC runs (major), GC time | 54 (6), 0.06 | 63 (8), 0.08 | 4,814 (19), 3.14 | 5,787 (23), 3.19 |
    | peak RSS, process tree summed (1 s samples), MiB | 1,018 | 1,054 | 3,945 | 4,296 |
    | peak RSS, runner (1 s samples), MiB | 124 | 124 | 212 | 199 |
    | largest single process (`/usr/bin/time`), MiB | 124 | 124 | 550 | 551 |
    | stored networks of the generation, bytes | 42,319,900 | 42,328,356 | 4,586,398,000 | 4,586,226,288 |
    | experiment on disk after it, GiB (database, `work/`) | 0.08 (0.04, 0.04) | 0.18 (0.09, 0.08) | 8.56 (4.28, 4.28) | 17.12 (8.56, 8.55) |
    | arena load of all networks, three runs: wall; max RSS | 0.02; 43 MiB | 0.02; 43 MiB | 2.26–2.28; 4,408 MiB | 2.24–2.37; 4,408 MiB |

    - Invocation 2 (S1, L1) also re-entered generation 0 first, which its wall time, CPU, and GC figures include and its `timings` line does not: about 0 s on the small workload and about 4 s on the large (generation headers, 1 s resolution).
    - Arena load: one arena over the generation's 1,000 networks (4.59 GB of files), each loaded once at `max_moves` 0, took about 2.3 s, of which its 500 one-move games 0.16 s, and held 4.3 GiB; the 50 small networks took 0.02 s.
    - Limits: one run of each; RSS sampled every second, so short peaks can be missed, and the summed figure counts shared pages in every process; the small run started at a load average of 2.6.
    - So a change to the runner's Ruby side is justified for large populations: on the large workload the runner spent about 57 s of an 82–87 s tournament outside waiting for jobs, about 5.7 s a round or 11 ms a game, and allocated about 240 million objects a generation, while its arena games took 219–254 s of worker time spread over 8 workers. On the small workload Ruby took about 1.3 s of a 9.7 s tournament, and the GoGui games with bots (62–64 s of worker time for 117 games) and the benchmark (about 30 s) dominate.
    - Why, from a micro-benchmark before the change (28 Sep 2026, same machine; not a workload run): after every game the runner rebuilt the ranking, `save_state` deleted and re-inserted every `players`, `rankings`, and `pending_games` row, and the state was reloaded, so a round cost about the population squared: about 10.4 ms and 48.5 thousand objects a game with 1,015 players, 1.3 ms with 65.
  - After saving only what a game changed (#82; 28 Sep 2026, git `cfaa866`, same machine, commands, and concurrency; one run each; other work paused, load average 1.75 just before the small run started). A game now saves, in one transaction with its `games` row, the removal of its pending game and its ranking change; the state stays in memory (`docs/experiment-reference.md`). Same columns and units as above.

    | | S0 | S1 | L0 | L1 |
    | --- | --- | --- | --- | --- |
    | wall (`/usr/bin/time`) | 40.5 | 39.3 | 96.8 | 129.7 |
    | timings `total` | 40.2 | 39.0 | 96.5 | 126.6 |
    | `setup` | 1.3 | 0.9 | 33.4 | 53.9 |
    | `tournament` (10 rounds) | 9.1 | 8.9 | 39.9 | 43.2 |
    | a round | 0.74–1.51 | 0.78–1.08 | 3.62–5.06 | 4.05–5.12 |
    | `ruby` | 0.74 | 0.78 | 14.7 | 13.6 |
    | `ruby` per round | 0.07–0.09 | 0.06–0.10 | 1.31–1.81 | 1.27–1.65 |
    | `worker` | 62.0 | 60.5 | 304.2 | 334.6 |
    | `benchmark` | 29.9 | 29.2 | 23.2 | 29.3 |
    | tournament games (none failed) | 320 | 320 | 5,070 | 5,070 |
    | GoGui games with a bot: count, summed `duration` | 117, 57.2 | 117, 57.2 | 138, 91.1 | 138, 87.0 |
    | arena games: count, summed `duration` | 203, 4.9 | 203, 3.3 | 4,932, 213.1 | 4,932, 247.6 |
    | benchmark games (none failed): count, summed `duration` | 60, 207.0 | 80, 199.2 | 60, 164.6 | 80, 213.5 |
    | runner CPU, user + sys | 0.46 + 0.76 | 0.51 + 0.95 | 20.5 + 7.4 | 20.6 + 14.4 |
    | runner allocated objects | 0.93 M | 0.99 M | 88.5 M | 90.2 M |
    | runner GC runs (major), GC time | 37 (6), 0.04 | 44 (8), 0.06 | 2,311 (17), 1.59 | 2,738 (18), 1.64 |
    | peak RSS, process tree summed (1 s samples), MiB | 1,062 | 1,050 | 4,250 | 4,113 |
    | peak RSS, runner (1 s samples), MiB | 125 | 118 | 218 | 224 |
    | largest single process (`/usr/bin/time`), MiB | 125 | 118 | 550 | 551 |
    | arena load of all networks, three runs: wall; max RSS | 0.02; 43 MiB | 0.02; 43 MiB | 2.26–2.29; 4,408 MiB | 2.24; 4,407–4,408 MiB |

    - Large workload: the tournament went from 82–87 s to 40–43 s, its Ruby time from about 57 s to 14–15 s (about 2.7–2.9 ms a game, pairing included), the runner's allocations from about 241 million objects to about 89 million, and a generation's `total` from 146 and 169 s to 97 and 127 s. The stored networks, disk use, and memory are unchanged. L1's re-entry into generation 0 took about 2 s.
    - Small workload: Ruby went from about 1.3 s to about 0.75 s; the rest is unchanged within run-to-run noise, since the GoGui games with bots and the benchmark dominate.
    - What remains per game is O(population) work in Ruby and SQLite, not O(population²): `RunGeneration#update_data` still re-sorts the whole ranking, `in_order?` checks the old ranking's order, `ranking_moves` copies and searches it, and the rank shift in `ExperimentDatabase#raise_in_ranking` scans the generation's `rankings` rows, which have no index on `rank`. The first game of each round also rewrites all of the generation's `rankings` rows, and each round's pairing still saves the whole state.
    - On the large workload, `setup` (breeding or creating the population, storing it, and exporting its 4.6 GB of networks to `work/`) is now the largest single step of a generation: 33 s in generation 0 and 54 s in generation 1 (breeding), against 4–5 s for a round and 40–43 s for all 10 rounds.
    - Limits as above: one run of each; the small run started at a load average of 1.75.
  - After playing every tournament game in the arena (#83 and commit `2568fff`; 28 Sep 2026, git `3241a0f`, same machine, commands, and concurrency; one run each; machine idle, load average 1.6 just before the small run and 4.4 just before the large). Like the two profiles above, it predates `83654ed`, which moved `WorkerPool` and the `timings` line from `CLOCK_MONOTONIC` to `AwakeClock` (`docs/experiment-reference.md`); on macOS `CLOCK_MONOTONIC` also counts time the machine sleeps, so these runs' job and round times include any sleep, as `/usr/bin/time` does. Games with a bot no longer go through `gogui-twogtp` and a GNU Go referee: the arena starts the bot itself and scores by Tromp–Taylor (`docs/code-reference.md`). The large run used a temporary copy of `scripts/profile-workload.sh` with a 20 GiB free-space threshold instead of 25, since `df` showed 22.1 GiB while Time Machine local snapshots held deleted workloads; the run peaked at 17.1 GiB, and nothing else differed. Same columns and units as above.

    | | S0 | S1 | L0 | L1 |
    | --- | --- | --- | --- | --- |
    | wall (`/usr/bin/time`) | 30.5 | 29.6 | 99.3 | 134.7 |
    | timings `total` | 30.2 | 29.4 | 99.0 | 129.1 |
    | `setup` | 0.7 | 0.9 | 40.7 | 59.9 |
    | `tournament` (10 rounds) | 1.3 | 1.0 | 35.5 | 40.1 |
    | a round | 0.09–0.37 | 0.09–0.11 | 3.21–4.85 | 3.81–4.68 |
    | `ruby` | 0.24 | 0.26 | 10.4 | 10.4 |
    | `ruby` per round | 0.02–0.03 | 0.02–0.03 | 0.93–1.26 | 0.96–1.23 |
    | `worker` | 7.8 | 5.7 | 215.2 | 250.3 |
    | `benchmark` | 28.3 | 27.5 | 22.8 | 28.8 |
    | tournament games (none failed) | 320 | 320 | 5,070 | 5,070 |
    | GoGui games with a bot: count, summed `duration` | 0 | 0 | 0 | 0 |
    | arena games: count, summed `duration` | 320, 7.8 | 320, 5.7 | 5,070, 215.2 | 5,070, 250.3 |
    | benchmark games (none failed): count, summed `duration` | 60, 196.3 | 80, 188.8 | 60, 161.3 | 80, 202.0 |
    | runner CPU, user + sys | 0.36 + 0.49 | 0.42 + 0.68 | 18.1 + 8.1 | 19.1 + 14.5 |
    | runner allocated objects | 1.12 M | 1.18 M | 89.4 M | 91.1 M |
    | runner GC runs (major), GC time | 41 (6), 0.04 | 47 (8), 0.05 | 2,247 (17), 1.11 | 2,663 (19), 1.27 |
    | peak RSS, process tree summed (1 s samples), MiB | 1,054 | 1,053 | 4,318 | 4,088 |
    | peak RSS, runner (1 s samples), MiB | 125 | 123 | 213 | 226 |
    | largest single process (`/usr/bin/time`), MiB | 125 | 123 | 559 | 560 |
    | arena load of all networks, three runs: wall; max RSS | 0.02; 43 MiB | 0.02; 43 MiB | 2.21; 4,408 MiB | 2.19–2.25; 4,407–4,408 MiB |

    - Small workload, against the #82 profile: the tournament went from about 9 s to 1.0–1.3 s and its worker time from about 61 s to 5.7–7.8 s, because the 117 games with a bot no longer start GoGui, a JVM, and a GNU Go referee. A generation went from about 40 s to about 30 s, and is now almost all the benchmark (27.5–28.3 s), which still plays every game through `gogui-twogtp` with the GNU Go referee, most of its time in the games against GNU Go level 0.
    - Large workload: the tournament went from 40 and 43 s to 35 and 40 s, its worker time from 304 and 335 s to 215 and 250 s, and Ruby from 14–15 s to about 10.4 s (about 2 ms a game). A generation's `total` is about unchanged (97 and 127 s before, 99 and 129 s now), because `setup` (breeding or creating the population, storing it, and exporting its 4.6 GB of networks to `work/`) varies between runs, 33–60 s across the two profiles, and is now the largest part of a generation. L1's re-entry into generation 0 took about 5 s.
    - Keeping arenas alive across a generation's rounds would save at most the network loading: about 2.3 s of CPU per round for the 1,000 networks, spread over 8 workers, so roughly 3 s of a 35–40 s tournament and under 3% of a generation. That does not pay for the memory (an arena holding the whole population takes 4.3 GiB, and each of 8 could approach that) or the complexity of keeping sessions alive through interruption and resume, so the runner keeps starting fresh arenas each round. The next bottlenecks are `setup` on large populations and the `gogui-twogtp` benchmark on small ones.
    - Limits: one run of each; RSS sampled every second; the large run started at a load average of 4.4.
  - Summary of #81–#84 (28–29 Sep 2026, git `69a157c`, after #84 and `83654ed`, so timed on `AwakeClock`; same machine, commands, and concurrency; machine idle; small workload run twice, load average 1.9 before each; large twice, load average 6.6 before the first, which started right after the small run, and 2.1 before the second). Against the first profile (#81, before any change) and the one after #82 (Ruby saves only what a game changed). Seconds; each cell is generation 0 / generation 1, and "now" gives the range over both runs where they differ.

    | | small #81 | small #82 | small now | large #81 | large #82 | large now |
    | --- | --- | --- | --- | --- | --- | --- |
    | timings `total` | 40.9 / 40.3 | 40.2 / 39.0 | 29.9 / 28.7–29.0 | 145.8 / 169.2 | 96.5 / 126.6 | 90.0–96.6 / 120.6–120.7 |
    | `setup` | 0.8 / 1.1 | 1.3 / 0.9 | 0.7 / 0.9 | 39.2 / 49.2 | 33.4 / 53.9 | 32.0–38.5 / 52.6–53.0 |
    | `tournament` | 9.7 / 9.7 | 9.1 / 8.9 | 1.2 / 1.0 | 82.4 / 86.6 | 39.9 / 43.2 | 35.1–35.2 / 39.5–39.9 |
    | a round | 0.75–1.71 / 0.76–1.59 | 0.74–1.51 / 0.78–1.08 | 0.09–0.37 / 0.09–0.12 | 7.75–9.49 / 8.46–9.24 | 3.62–5.06 / 4.05–5.12 | 3.22–4.59 / 3.74–4.61 |
    | `ruby` | 1.29 / 1.37 | 0.74 / 0.78 | 0.25 / 0.26 | 57.1 / 56.9 | 14.7 / 13.6 | 10.3–10.7 / 10.4 |
    | `worker` | 67.8 / 67.8 | 62.0 / 60.5 | 7.7 / 5.6 | 318.6 / 348.0 | 304.2 / 334.6 | 209.1–213.1 / 245.5–248.6 |
    | `benchmark` | 30.3 / 29.5 | 29.9 / 29.2 | 28.0 / 26.8–27.1 | 24.2 / 33.1 | 23.2 / 29.3 | 22.8 / 27.9–28.0 |
    | games with a bot: count, summed `duration` | 117, 62.2 / 64.4 (GoGui) | 117, 57.2 / 57.2 (GoGui) | 117, 3.6 / 2.6 (arena, second run) | 138, 99.6 / 93.9 (GoGui) | 138, 91.1 / 87.0 (GoGui) | 138 / 139, in the arena (not split out) |
    | runner CPU, user + sys | 1.86 / 2.19 | 1.22 / 1.46 | 0.84–0.87 / 1.07–1.10 | 69.7 / 77.0 | 27.9 / 35.0 | 24.2–24.8 / 32.2–32.5 |
    | runner allocated objects | 1.69 M / 1.75 M | 0.93 M / 0.99 M | 1.12 M / 1.18 M | 241.4 M / 243.0 M | 88.5 M / 90.2 M | 89.4 M / 91.1 M |
    | peak RSS, process tree summed, MiB | 1,018 / 1,054 | 1,062 / 1,050 | 1,053–1,055 / 1,042–1,049 | 3,945 / 4,296 | 4,250 / 4,113 | 3,893–4,148 / 4,290–4,499 |
    | peak RSS, runner, MiB | 124 / 124 | 125 / 118 | 125 / 121–123 | 212 / 199 | 218 / 224 | 213–220 / 215–229 |
    | largest single process, MiB | 124 / 124 | 125 / 118 | 125 / 121–123 | 550 / 551 | 550 / 551 | 559 / 560 |
    | arena load of all networks: wall | 0.02 | 0.02 | 0.02 | 2.24–2.37 | 2.24–2.29 | 2.14–2.22 |

    - Small workload, bot-heavy: a generation went from 40–41 s to 29–30 s (1.37–1.40× faster, 27–29% less), 11.0–11.6 s in all. About 8.5–8.7 s of that is the tournament: 9.7 s to 1.0–1.2 s (8–10×), its worker time from 68 s to 5.6–7.7 s (9–12×), and Ruby from 1.3 s to 0.25 s (5×; 3× against #82). A game with a bot costs 0.02–0.03 s of worker time in the arena, against 0.49–0.55 s through GoGui, a JVM, and the GNU Go referee; a network game costs 0.015–0.020 s, as before. The bots' own move time was never the cost: every stored `time_black`/`time_white` of a game with a bot reads 0.0 (under 0.05 s a side a game) through GoGui and in the arena alike, so what went is process overhead. The other 2.3–2.7 s is the benchmark (30.3 and 29.5 s to 28.0 and 26.8–27.1 s; its summed game durations 209.2 and 206.9 s in #81, 196.3 and 188.8 s in the 3241a0f profile, 193.0–194.1 and 186.5 s now). None of #81–#84 changed the benchmark and no cause was found, so treat that drop as run-to-run variation. The benchmark is now 93–94% of a generation.
    - Large workload, arena-heavy: the tournament went from 82–87 s to 35–40 s (2.2–2.3×) and its Ruby time from 57 s to 10.3–10.7 s (5.4×; about 11 ms to 2 ms a game), the runner's CPU from 70–77 s to 24–33 s, and a generation's `total` from 146 and 169 s to 90–97 and 121 s (1.5–1.6× and 1.4×). Against #82 alone (the arena change and `AwakeClock`) the tournament fell only 8–12% and Ruby 24–30%, though worker time fell 26–31% (304–335 s to 209–249 s): a round waits for its slowest chunk and for about 1 s of Ruby, so saved worker time spread over 8 workers shows only in part.
    - Negative results: on the large workload a generation gained only about 0–7% over #82 (one run of each then). Generation 1 took 120.6–120.7 s against 126.6 s, about 5% less in both runs, with `setup` about equal (52.6–53.0 s against 53.9 s); the saving is the tournament (43.2 s to 39.5–39.9 s) and the benchmark (29.3 s to 27.9–28.0 s). Generation 0 went from 96.5 s to between 96.6 s (run 1, `setup` 38.5 s) and 90.0 s (run 2, `setup` 32.0 s), equal to 7% faster. `setup` (breeding or creating 1,000 networks, storing them, and exporting 4.6 GB to `work/`) is the largest step, 36–44% of a generation, and varies between runs by as much as 6.5 s. Memory did not change: the arenas hold the networks they load (the largest process 559–560 MiB, 9 MiB above the GoGui runs), and summed peak RSS stays at 3.8–4.4 GiB, within the run-to-run spread. The small workload's benchmark still plays through `gogui-twogtp` with its JVM and referee, which none of #81–#84 touched.
    - The two large runs agree to within 7 s on `total` (the difference is `setup`, 32 against 38.5 s in generation 0) and within 0.5 s on the tournament; the two small runs to within 0.3 s. These numbers match the 3241a0f profile above (git `3241a0f`, before `AwakeClock`), so moving the clocks to `AwakeClock` changed nothing on an awake machine.
    - Limits: two runs of each; RSS sampled every second; the first large run began at a load average of 6.6, left by the small run that had just finished.
  - Before networks moved to disk (29 Sep 2026, git `7c07772`, which only splits `setup` into its parts; same machine; one run each). Two measurements:
    - Generation 7 of `even-bigger2` (1,000 networks of about 4.6 MB, the large workload's shape), one `one-generation` invocation at concurrency 3 on its 13.8 GB database (about 4.6 GB of it free pages, which SQLite reuses), machine quiet: `setup` 103.4 s = `setup_clear` 0.2, `setup_parents` 7.5, `setup_breed` 81.4 (of it `setup_store` 51.7), `setup_save` 0.8, `setup_export` 13.4; tournament 72.6 s. The experiment was deleted afterwards.
    - The large workload, right after that run (load average 4.8 at the start, so not fully quiet). Same columns and units as above; `setup` parts in seconds.

      | | L0 | L1 |
      | --- | --- | --- |
      | wall (`/usr/bin/time`) | 100.8 | 128.3 |
      | timings `total` | 100.5 | 122.7 |
      | `setup` | 40.2 | 52.6 |
      | parts: clear, parents, breed (store within it), save, export | 0.0, –, 31.1 (14.3), 0.0, 9.1 | 0.2, 1.8, 41.1 (16.0), 0.0, 9.5 |
      | `tournament` (10 rounds) | 36.4 | 40.8 |
      | `ruby` | 10.7 | 10.5 |
      | `worker` | 219.1 | 255.8 |
      | `benchmark` | 24.0 | 29.4 |
      | peak RSS, process tree summed (1 s samples), MiB | 4,066 | 4,005 |
      | peak RSS, runner (1 s samples), MiB | 200 | 225 |
      | largest single process (`/usr/bin/time`), MiB | 559 | 560 |
      | experiment on disk after it, GiB (database, `work/`) | 8.56 (4.28, 4.28) | 17.12 (8.56, 8.55) |
      | arena load of all networks, three runs: wall | 2.25–2.29 | 2.27–2.29 |

    - L1's re-entry into generation 0 (emptying `work/` and exporting generation 0's 4.6 GB) took about 5 s.
    - So storing the networks was the largest part of `setup`, and it grows with the database: 14–16 s into a fresh one, 52 s into `even-bigger2`'s. The two exports (`setup_parents` and `setup_export`) took another 11 s fresh and 21 s in `even-bigger2`. `evolve` itself, breeding minus storing, took about 25–30 s one child after another (generation 0's `initial-population`, one process, about 17 s).
    - Limits: one run of each; RSS sampled every second; the large run started at a load average of 4.8, left by the `even-bigger2` run that had just finished.
  - Networks on disk, parallel breeding, births in one transaction (`46462db`, `bb13ed6`, `3e4794a`, 29 Sep 2026): a generation's networks are files in `networks/N/`, the database stores only each checkpoint's champion, breeding runs `concurrency` `evolve`s at a time, and the births go in one transaction (`docs/experiment-reference.md`). Nothing is exported any more and the database no longer grows by a generation's networks. Seeded runs give the same births, games, rankings, and benchmark rows as before (`docs/experiment-reference.md`).
    - The large workload after it (29 Sep 2026, git `48c52f5`, same machine and command; one run each; other work paused, load average 3.03 just before the start and 10.4 at the end, from the run itself). Same rows as the before table; "before" is that table's L0 / L1.

      | | L0 | L1 | before (L0 / L1) |
      | --- | --- | --- | --- |
      | wall (`/usr/bin/time`) | 89.5 | 83.1 | 100.8 / 128.3 |
      | timings `total` | 89.2 | 82.7 | 100.5 / 122.7 |
      | `setup` | 20.8 | 8.4 | 40.2 / 52.6 |
      | parts: clear, breed (hash, store within it), sync, save, retire | 0.0, 20.8 (4.0, 0.04), 0.01, 0.01, 0.0 | 0.0, 8.2 (6.4, 0.04), 0.01, 0.01, 0.17 | see the before table |
      | `champion` | 0.02 | 0.02 | – |
      | `tournament` (10 rounds) | 43.5 | 44.6 | 36.4 / 40.8 |
      | a round | 3.91–4.84 | 4.19–5.02 | – |
      | `ruby` | 11.6 | 10.8 | 10.7 / 10.5 |
      | `worker` | 273.4 | 285.2 | 219.1 / 255.8 |
      | `benchmark` | 25.0 | 29.7 | 24.0 / 29.4 |
      | benchmark games (none failed): count, summed `duration` | 60, 179.3 | 80, 213.6 | – |
      | runner CPU, user + sys | 10.7 + 2.8 | 11.3 + 3.8 | – |
      | peak RSS, process tree summed (1 s samples), MiB | 2,952 | 3,407 | 4,066 / 4,005 |
      | peak RSS, runner (1 s samples), MiB | 93 | 99 | 200 / 225 |
      | largest single process (`/usr/bin/time`), MiB | 507 | 486 | 559 / 560 |
      | stored networks (champions): count, bytes | 1, 4,586,398 | 2, 9,172,796 | every network: 4.59 GB a generation |
      | experiment on disk after it, GiB (database, `networks/`, `work/`) | 4.28 (0.01, 4.27, 0.00) | 4.30 (0.02, 4.27, 0.01) | 8.56 / 17.12 (database and `work/`) |
      | arena load of all networks, three runs: wall; max RSS | 3.03–3.73; 2,447–3,474 MiB | 2.91–3.54; 2,773–3,544 MiB | 2.25–2.29 / 2.27–2.29; 4,351–4,408 MiB |

    - `setup` fell from 52.6 to 8.4 s in generation 1 (6.3×) and a generation's `total` from 122.7 to 82.7 s (33% less): no network is stored or exported, `evolve` runs 8 at a time (`setup_breed` 8.2 s, of it 6.4 s hashing on the main thread), and syncing the 1,000 files took 0.01 s. Generation 0's `setup` fell from 40.2 to 20.8 s, less, since `initial-population` is still one process. L1's re-entry into generation 0 took about 0 s (5 s before). The database holds about 0.02 GiB instead of 8.56 GiB, and the experiment took 4.3 GiB on disk after each invocation (8.56 and 17.12 GiB before).
    - Hashing is now most of generation 1's `setup` (6.4 of 8.4 s, one read and SHA-256 a network on the main thread while the pool breeds), so it is the next thing to move off the main thread if setup matters again.
    - Not improved: the tournament took 43.5 and 44.6 s against 36.4 and 40.8 s, its worker time 273 and 285 s against 219 and 256 s, and the arena load of all networks 2.9–3.7 s against about 2.25 s. Nothing in this change touches the arena or the bytes it loads: the files are the same, read from `networks/N/` instead of `work/`, both written just before and read once untimed before the timed runs. The run shows a busier machine instead: involuntary context switches under `/usr/bin/time` rose from 0.55 M to 1.24 M in generation 1, the arena's games alone, which load nothing, took 0.175–0.178 s against 0.162–0.164 s, and the load runs' maximum RSS varied between 2.4 and 3.5 GiB, where every earlier run over the same 4.59 GB read 4.3 GiB. One run each cannot tell load from a cause in the change; repeat the profile before drawing a conclusion about the tournament or loading.
    - Limits: one run of each; RSS sampled every second; load average 3.03 at the start.
  - Streamed records and four chunks per worker (`925e51a`, `d825366`, 29 Sep 2026): the runner reads each arena chunk's stdout as it arrives and scores each game at once, while the arenas play, and deals a round into `min(4 × concurrency, games)` chunks instead of one per worker (`docs/experiment-reference.md`). Seeded runs give the same births, games, rankings, and benchmark rows as before (`docs/experiment-reference.md`).
    - **Placeholder, not yet measured:** the large workload after it (`mise run profile-workload large`, on a quiet machine), with the rows of the table above, to compare with its L0 / L1: the tournament and each round, `worker` against the round times times 8, and `ruby`, now overlapping play.
