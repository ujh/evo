# CLAUDE.md

Evo evolves the weights of a fixed dense neural network that plays Go. The C programs build, breed, and play networks. The Ruby scripts run tournaments through GoGui, with GNU Go as referee. The goal is to show measurable improvement from evolution, not a strong engine.

`PROJECT_NOTES.md` holds only work still to do: known defects, the planned cleanup order, proposed experiments, and open questions. Read it before changing behavior. When a change fixes a listed item or settles a question, delete it from `PROJECT_NOTES.md` in the same change. Do not record finished work or history there. If a future agent must know something about the change, put it in this file instead.

## Commands

Always go through mise. It pins Ruby 4.0, Java 21, and jq, and it puts `.local/evo-tools/current/bin` (GNU Go, Brown, AmiGoGtp, GoGui) on `PATH`. A bare shell has none of these. For one-off commands, use `mise exec -- <cmd>`.

| Task | Command |
| --- | --- |
| First setup (submodule, gems, build) | `mise run setup` |
| Install external Go programs | `mise run setup-experiments` (downloads from the project's own GitHub release with pinned checksums, and builds under `.local/evo-tools/`) |
| Build | `mise run build` (root `make`; builds `pcg-c` first) |
| Tests (C and Ruby) | `mise run test` (or `test-c`, `test-ruby` alone) |
| Full check, same as CI | `mise run verify` (tests, `doctor`, and `smoke`: refereed GoGui matches with every bot and Evo) |
| Create an experiment without prompts | `mise run new-experiment NAME --board-size 9 ...` (without arguments it lists the options) |
| Run/resume experiment | `mise run run NAME [CONCURRENCY [one-generation]]` |

- Build from the repository root. The subdirectory Makefiles link `../pcg-c/src/libpcg_random.a` and `../lib/libann.a`, and fail if `make pcg` and `make lib` have not run.
- `mise run example` opens the GoGui window. Do not use it headless. `gogui-twogtp` runs without a display.
- Ruby tests live in `test/` (minitest). They build `RunGeneration` with `allocate` and set its instance variables directly (settings, a seeded `rng`, a fake pool), and they stub `../evolve` by overriding `run_evolve` on that object (and `initial-population` by overriding `system`). The PR script tests run `scripts/pr-checks.sh` against a fake `gh` on `PATH` (`test/fake_gh.rb`). `PR_CHECKS_TRIES` and `PR_CHECKS_SLEEP` shorten the wait for checks to register. There is no Ruby linter yet.
- `ExperimentDatabase#save_state` and `RunGeneration#save_data` take a keyword argument besides the state hash (the test helper `write_data` accepts either form). In Ruby 3 a brace-less hash argument such as `save_state(1, 'round' => 0)` is then taken as keywords and fails with a wrong-number-of-arguments error, so pass the state in braces: `save_state(1, { 'round' => 0 })`.

## Layout

- `engine/`: `evo`, a GTP engine built on Brown's board code (`brown.c`, `gtp.c`) plus the network move policy (`generate_move.c`). `engine/rules_test.c` (`make test` in `engine/`) pins Brown's rules and the move filter, and `enginetest.sh` checks them through GTP `play`:
  - Captures remove every neighboring opponent string left without a liberty. Ko is simple ko: only an immediate single-stone recapture is refused, and any other move or a pass ends it.
  - `legal_move` and GTP `play` accept suicide; the suicided string is removed at once.
  - `genmove` plays the highest-scoring point that is legal, not suicide, and not the opponent's suicide point (in effect an own eye) unless it touches an opponent stone. It passes when nothing is allowed or the pass output scores at least as high, so a tie (common with saturated cached sigmoid outputs) passes.
- `initial-population/`: `initial-population POP SIZE LAYERS NEURONS [SEED]` writes random networks named `0001.ann`, `0002.ann`, and so on.
- `evolve/`: `evolve RATE A.ann B.ann OUT.ann [SEED]` writes the child to `OUT.ann`. Its last stdout line is `summary operator=crossover|mutation differs_from_first=N differs_from_second=N` (weights differing from each parent; 0 means an identical copy). It either crosses over or mutates; it never does both. It exits 1 without writing anything when an input cannot be read, when the parents differ in sizes or activations, or when the child cannot be written. The runner checks the exit status and that the file exists, and stops breeding before deleting the parents if either fails.
  - `evolve/test.c` (`make test` in `evolve/`) pins `mutate()`'s hard-coded values statistically: it mutates seeded networks thousands of times and checks the shares against tolerances of about four standard errors. Changing a mutation value means updating those tests. The statistical checks do not depend on the exact random draws; only the copy and seed tests rely on a particular seed.
- `ruby/`, `runner`: tournament orchestration, and the benchmark (`ruby/checkpoint_benchmark.rb`, openings in `ruby/openings.rb`). `stats` (figures in `ruby/experiment_stats.rb`, output in `ruby/stats_report.rb`), `ranking`: viewers. `multi`: rotates between several experiments.
- `lib/`: the network code every program links, built once as `lib/libann.a`. `genann.c` and `genann.h` are upstream GENANN v1.1.1, unchanged (license in `lib/GENANN-LICENSE`); to update GENANN, copy the new upstream files over them. Evo's additions live in `ann.h` and `ann.c`: the PCG `GENANN_RANDOM`, and `ann_binary_read`/`ann_binary_write` for the `.ann` format with the activation table. Programs include `ann.h`, never `genann.h`. `lib/test.c` (`make test` in `lib/`) tests GENANN and the `.ann` round trip. `lib/minctest.h` is the test framework for `lib/` and `evolve/`.
- `pcg-c/` is an upstream submodule (`imneme/pcg-c`). Do not edit it.

## Things that trip agents up

### Engine and network files

- `evo NETWORK.ann` starts at board size 6, so send `boardsize` before `genmove`. Without exactly one file argument it prints a usage message and exits 1; a file that is missing or holds no network makes it exit 1 at startup with a message naming it.
- `boardsize` answers `? unacceptable size` for a size the loaded network does not fit, and `genmove` answers `? network does not fit the board` if no fitting `boardsize` came first. The process keeps running. `engine/enginetest.sh` (`make test`) checks a whole GTP session.
- The engine answers `name` with `Evo`.
- The `.ann` format (`lib/ann.h`) holds everything a GENANN network is: the magic `EVOANN`, a format version (1), the sizes inputs, hidden_layers, hidden, and outputs, a code for the hidden and the output activation (every activation GENANN offers has one, in `ANN_ACTIVATIONS`), then the weights as doubles. All numbers are little-endian and fixed-size, so files are portable. Reading rejects a wrong magic or version, an unknown activation, and a file that is too short or too long. There is no reader for the earlier headerless format.
  - A network for board size N has N²+1 inputs (komi first) and N²+1 outputs (pass last).
  - `engine/example.ann` is a 9×9 test fixture with 2×2 hidden neurons, cached sigmoid activations, and 418 weights. It is not a trained player.
- Move choice takes the highest output. It is deterministic for a given network and position.
  - `initial-population` and `evolve` take an optional seed as their last argument; the same seed gives byte-identical output. Without one they seed from `time(NULL)` plus an address.
- Runs are reproducible from the experiment seed (the `seed` setting; `SetupExperiment` generates and saves one if it is missing). `ruby/seeds.rb` derives every other seed from it and a label: the initial population, each child (`birth`, generation, index), parent selection, tie order and colors per round, a per-game GNU Go `--seed` for the referee and GNU Go players (`Seeds.gnugo`, added to a command by `Seeds.with_gnugo_seed`), in the tournament and in the benchmark, and the benchmark openings. Two runs with the same seed, even with parallel games, produce the same networks, pairings, moves, rankings, and benchmark results; only the date in the SGF headers differs. Losing a game on time would still differ.
- Besides `games`, the experiment database records `births` (each network's parents, operator, differing weights, seed, and SHA-256 of its `.ann`; generation 0 has operator `initial`) and `rankings` (each generation's standings, kept current after every game; final once the generation is done).
- Brown's own `final_score` is unreliable on arbitrary positions: an empty 9×9 board scores `W+87.5`. Use the referee's result.
- The build uses `-march=native`. Binaries are for the local machine only.
- macOS ships GNU make 3.81, which compares timestamps to the second. A C file edited and rebuilt within the same second can leave the old object in place, so a quick edit-rebuild-test loop (such as checking that a test catches a mutant) may run a stale binary. Delete the `.o` files before rebuilding in that case.

### Game results

- A GoGui `.dat` file is tab-separated: `GAME RES_B RES_W RES_R ALT DUP LEN TIME_B TIME_W CPU_B CPU_W ERR ERR_MSG`.
  - Columns can be empty, so split on tabs. The runner and the benchmark do this in `ruby/game_result.rb`.
  - The runner saves twogtp's stderr to `PREFIX.err` next to the `.dat` file while the game runs. Only stderr says which program crashed ("Black program died" or "White program died").
- Each experiment stores its opponents, its benchmark panel, and its scoring when it is created (tables `opponents`, `benchmark_opponents`, and `scoring`, from `SetupExperiment::DEFAULT_OPPONENTS`, `DEFAULT_BENCHMARK`, and `DEFAULT_SCORING`), and the runner reads them from there, so changing the defaults only affects new experiments. By default every win is worth 1 point, whether the loser is a network or a bot, a draw 0, and the odd player out in a round sits out with 0. `scoring['rules']` is the version of the scoring logic (`RunGeneration::SCORING_RULES`); bump it when `score_game` or `GameResult` change what counts, and an experiment begun under other rules refuses to run. The bots play in the ranking like networks, and against each other, on purpose: their place in the ranking shows how the networks compare to them. Parents are chosen by tournament selection (`select_parent` in `ruby/run_generation.rb`): draw `tournament_size` networks (setting, default 3) with replacement and keep the highest score. Only the order of scores matters, and equal scores pick uniformly.
- Scoring rules (agreed with the owner, in `score_game` and `ruby/game_result.rb`):
  - A referee win (`B+` or `W+`) counts, including games stopped by the move limit.
  - A draw gives no points.
  - A network that crashes loses, whatever the referee said.
  - These give no points and are logged, with the reason in their row's `failure` column: a crashed external bot, a missing referee score (`?`), any other GoGui error (an illegal move is blamed on the program that rejected it, not the one that played it), and a missing or empty `.dat` file.
  - Failed games are never retried, so a broken setup stays visible.
- Check `RES_R` and `ERR`, not only whether a game finished. A crashed player shows only in `ERR`, and a crashed referee only as `?` in `RES_R`. `scripts/smoke-external-tools.sh` checks both. Keep it that way when changing it.
- Brown and AmiGo play deterministically. The 5 Brown and 10 AmiGo "instances" are copies of the same opponent, so replaying a pairing with the same colors adds no information.
- GNU Go seeds its random choices from the clock unless it gets `--seed N`. The runner always passes one; outside the runner, compare GNU Go behavior with a fixed seed.

### Running experiments

- On a first run, `mise run run NAME` prompts on STDIN for settings. To start without prompts, create the experiment first; `SetupExperiment::SETTINGS` lists every setting with its default and its type (a whole number, an even whole number, or a number, and its range; `mise run new-experiment` without arguments shows them). A value that does not parse strictly is refused when the experiment is created, and a prompt asks again. The database stores settings as strings; `SetupExperiment.parse` turns them into Integers and Floats on every load, so the runner never converts them itself, and test settings must be typed too:
  ```sh
  mise run new-experiment NAME --board-size 9 --population-size 4 --hidden-layers 1 --layer-size 10 \
    --cross-over-rate 0.5 --game-length 10 --max-moves 200 --tournament-rounds 1 --keep-every 0
  ```
  With `4 one-generation`, that runs one generation of 10 pairings (9 games plus a bye for the odd player out) in a few seconds, which makes it a good smoke run; `--keep-every 0` skips the benchmark, which would otherwise add 60 games at generation 0. Delete `experiments/NAME` afterwards. Running it again breeds and plays the next generation. `experiments/` is gitignored.
- An experiment directory holds only `experiment.sqlite3`, the scratch directory `work/`, and the executables. The runner works inside `work/`, which it empties at the start of every generation, and calls `../evo`, `../evolve`, and `../initial-population`. They are **copies** of the build output, made on the experiment's first run once its settings are known, so a rebuild does not change an experiment that has started; to run new code, start a new experiment. Once the provenance is recorded, a missing executable stops the run instead of being copied again. The `provenance` table records what they were built from: the git revision, whether the checkout had uncommitted changes, and the external tools release.
- Everything but a game's files in progress lives in `experiments/NAME/experiment.sqlite3`: the settings, and each generation's round, players, standings (`rankings`), and pending games. `RunGeneration#data` loads a generation's state in the shape `data.json` used to have, and `save_data` replaces it in one transaction after every game. On resume, `setup_complete` skips creating or breeding the population, the runner starts from the last generation in the database, and a generation's games are skipped only once `round` reaches `tournament_rounds`. A checkpoint's benchmark runs after that check too, so a resumed checkpoint finishes its benchmark. `RunGeneration#call` returns `:already_done`, which makes a `one-generation` run go on to the next generation, only when the generation played no tournament game and no benchmark game.
- The runner passes `-force` to twogtp, which deletes an existing `PREFIX.dat`. A game that was queued but not yet scored when the runner stopped is replayed from scratch on resume, and its `.err` is rewritten.
- Generation 0 names networks `0001.ann`, `0002.ann`, and so on. Later generations use `0.ann`, `1.ann`, and so on.
- Game results live in `experiments/NAME/experiment.sqlite3`, through `ExperimentDatabase` (`ruby/experiment_database.rb`, Sequel on SQLite). After scoring a game, the runner writes its row (players, winner or failure, length, referee result, GoGui's error message, stderr, and timings: `duration` is the wall-clock seconds of the whole `gogui-twogtp` run, measured by `WorkerPool`, and `time_black`/`time_white` are the seconds each player spent answering `genmove`, from twogtp's `TIME_B`/`TIME_W`, to a tenth; the rest of `duration` is the referee, the JVM, process starts, and the other GTP commands, plus a 3 s wait twogtp adds when a player crashed. Rows from before migration 005 have no timings) and deletes the game's `.dat`, `.sgf`, and `.err` files. The SGF is kept in the row only for every `keep_every`-th generation (setting, default 10; 0 keeps none). Rows are keyed by generation, round, and players, so a replayed game replaces its row.
- The schema changes only through Sequel migrations in `db/migrations/`. The runner applies pending ones when it opens the store. Add a new numbered migration for a schema change; never edit one that has run.
- `stats` and `ranking` only read: they open the experiment database read-only, so they can run beside the runner.
- Networks live in the `networks` table (the `.ann` bytes). The runner writes the current generation's networks into `work/` to play them, and the parents into `work/parents/` to breed, because both generations name their networks `0.ann`, `1.ann`, and so on. A generation's networks are dropped, in the same transaction that saves the next generation's setup, unless it is a `keep_every`-th generation. To inspect a network, export it: `ExperimentDatabase#export_networks(generation, directory)`.
- `stats NAME` prints the tables once and exits; `--watch` redraws them every 5 s until Ctrl-C; `--csv` prints one row per generation. The CSV header is fixed: the tournament and population columns, then per opponent of the stored panel, color, and outcome (`benchmark.Brown.black.win`), so experiments with the same panel compare column by column; cells a generation lacks are empty.
- `ExperimentStats` computes the figures (a Hash per generation) and `ExperimentStats::Report` formats them; neither prints on its own. A checkpoint counts as finished only once its benchmark is complete: stored rows equal `benchmark_games` times the opponents from `CheckpointBenchmark.opponents_for`, the same rule the runner plays by, so change it there only.
- `ranking` and `multi` loop forever. Run them with a timeout or in the background.
- Games run on a `WorkerPool` (`ruby/worker_pool.rb`): `concurrency` threads, created once per experiment, each running `gogui-twogtp` through `system`. On Ctrl-C the running games stop, the pool starts no queued game (`WorkerPool#halt`, called from the trap in `RunExperiment`), and the runner exits without scoring, leaving the unfinished games pending in the database, so resuming replays them.
- GNU Go 3.8 needs `scripts/patches/gnugo-3.8-gg-sort-empty.patch`. Without it, clang builds abort in `final_score` and during level 10 move generation. GCC builds happen to work either way. When changing how external tools are built, bump `release_id` in `scripts/install-external-tools.sh` so existing installs rebuild, then run `mise run verify`.
- The installer downloads only from the GitHub release named in `mirror_url` in `scripts/install-external-tools.sh`, never from upstream. `scripts/external-tools.txt` lists each archive's SHA-256 and upstream URL. To change an archive, edit the manifest, give `mirror_url` a new release tag (a published release's files should not change under the same tag), bump `release_id`, and run `mise run mirror-external-tools`. That task fetches from upstream and uploads to the release.

### Benchmark

- `CheckpointBenchmark` (`ruby/checkpoint_benchmark.rb`) measures progress apart from the tournament. `RunGeneration#call` runs it after the tournament of every `keep_every`-th generation (the checkpoints, whose networks are kept); with `keep_every` 0 it never runs.
- It plays the top network of the generation's final ranking (the first entry that is not a bot) against the stored panel `benchmark_opponents`, in order. `kind` is `bot` (run by `command`), `initial_champion` (generation 0's top network), or `previous_checkpoint` (the top network of generation minus `keep_every`). Generation 0 plays the bots only, and `previous_checkpoint` is skipped when it would be generation 0, which `initial_champion` already covers.
- Each opponent gets `benchmark_games` games (setting, even, default 20), half with each color: opening `k` is played once with each. The openings (`Openings.moves`) have `benchmark_opening_moves` stones (setting, default 4), drawn from the experiment seed and `k`, never orthogonally adjacent, so they are the same at every checkpoint and checkpoints compare. They go to twogtp as `-openings work/benchmark/openings/k/`.
- twogtp counts opening stones as moves, so the runner passes `-maxmoves` as `max_moves` plus the opening's stones, and the stored `length` includes them.
- With `benchmark_opening_moves` 0 there is no `-openings`, and the games against deterministic opponents (Brown, AmiGo, networks) repeat: only the GNU Go games differ, through their per-game seed.
- Scoring follows the tournament's rules from the benchmarked network's side: the referee decides, a crashed network (benchmarked or opponent) loses, a draw has no winner, and a crashed bot, a missing referee score, another GoGui error, or a missing `.dat` is a failure with no winner.
- Results go to `benchmark_games`, one row per game keyed by generation, opponent, opening, and `network_color` (the benchmarked network's). `winner` is `network`, `opponent`, or nil; `network` is the benchmarked network's name and `opponent_network` the opposing one as `generation:name`. The other columns are those of `games`; no SGF is kept.
- On resume it plays only the games with no row. A row is stored before the game's files are deleted, so a crash between the two does not replay the game. Ctrl-C exits before scoring, as in the tournament.
- Its files live in `work/benchmark/`: the exported networks as `GENERATION-NAME`, each game as `OPPONENT-OPENING-COLOR` (`.dat`, `-0.sgf`, `.err`), and the openings.

### Performance

- The tournament's bots are only Brown and AmiGo. GNU Go referees there but does not play: GNU Go opponents, at level 0 as much as level 10, set most of a generation's wall time while early networks are far too weak for them. It comes back through the opponent ladder in `PROJECT_NOTES.md`. GNU Go level 0 does play in the benchmark.
- A checkpoint's benchmark with the default panel, on 9×9 with concurrency 2 (25 Sep 2026), took 52–69 s, most of it the 20 games against GNU Go level 0. The tournament of 4 networks in the same generations took 2–19 s.
- One generation profiled on macOS (25 Sep 2026, 8 cores, patched GNU Go): 9×9, 20 networks with 1 hidden layer of 100, 10 rounds, `max_moves` 200, seed 1, concurrency 4.
  - With the 15 Brown and AmiGo copies: 170 games in 25 s of wall time, about 400 games a minute. Median `duration` 0.29 s, 90th percentile 0.41 s. The slowest games (up to 4 s) were network games that ended early, after 29–67 moves, where the referee scores an unfinished position.
  - With GNU Go levels 0 and 10 in the panel as well: 190 games in 58 s. GNU Go against a network took about 7 s at either level (up to 13.7 s against AmiGo), and each round waited for such a game.
  - A network answers in under a tenth of a second, so its `time_black`/`time_white` read 0.0, and a network game's whole `duration` is overhead: JVM, referee, and process starts.
  - Each round waits for its slowest game. The per-round lower bound, max(slowest game, summed durations / concurrency), came to 19.8 of the 25 s; the rest is setup (the initial population; the profile was generation 0, so no breeding), per-game bookkeeping, and games packing unevenly onto the workers.
  - Engine inference is negligible: a 9×9 network with 3 hidden layers of 400 neurons (about 387k weights) answered 1,000 `genmove` commands in 0.21 s (24 Sep 2026). Engine start and exit took about 10 ms.

## Working conventions

- Fix defects test-first: write a test that fails, then fix.
- Commits: imperative, sentence-case subject (for example "Build GNU Go with common symbols on Linux"), with a body that explains why.
- Branches: `fix/…`, `chore/…`, `docs/…`.
- PRs: this is a personal repo with no Jira, so titles and bodies carry no ticket key. The body is one short paragraph that starts with the why, plus a line on how the change was verified.
- Open and update every PR by following `docs/pull-requests.md`: tests, the sweep for stale text, the review loop and its rules, and the CI check.
- Run any change bigger than one PR by `docs/orchestration.md`: agree it with the owner, write the plan in `plans/` (gitignored), have it reviewed, then approved by the owner, give each step to a fresh subagent with a review of each commit, open the PRs, and report once at the end.
- CI (`.github/workflows/ci.yml`) runs on every pull request, whatever its base (so stacked PRs get checks), and on pushes to `main`, on Ubuntu, with one job per kind of check: `c-tests` (`test-c`), `ruby-tests` (`test-ruby`), and `smoke-matches` (`setup-experiments`, `doctor`, `smoke`). Branch protection on `main` requires these jobs by name, so renaming or adding a job also needs the protection rule updated. CI caches the gems (keyed on `Gemfile.lock` and `mise.toml`) and the built external tools in `.local/evo-tools` (keyed on the installer, the manifest, and `scripts/patches/`). Both keys also include the runner image, because the caches hold compiled code. A change to how the tools build has to change one of those files, or CI keeps using the old build. Bumping `release_id` does that. Local setup is usually macOS with Apple clang, so code that builds GNU Go or other external tools has to work with both clang and GCC. A green local `verify` says nothing about Linux; wait for CI.
