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

- Build from the repository root. The subdirectory Makefiles link `../pcg-c/src/libpcg_random.a` and fail if `make pcg` has not run.
- `mise run example` opens the GoGui window. Do not use it headless. `gogui-twogtp` runs without a display.
- Ruby tests live in `test/` (minitest). They build `RunGeneration` with `allocate` and set its instance variables directly (settings, a seeded `rng`, a fake pool), and they stub `../evolve` by overriding `run_evolve` on that object (and `initial-population` by overriding `system`). The PR script tests run `scripts/pr-checks.sh` against a fake `gh` on `PATH` (`test/fake_gh.rb`). `PR_CHECKS_TRIES` and `PR_CHECKS_SLEEP` shorten the wait for checks to register. There is no Ruby linter yet.
- `ExperimentDatabase#save_state` and `RunGeneration#save_data` take a keyword argument besides the state hash (the test helper `write_data` accepts either form). In Ruby 3 a brace-less hash argument such as `save_state(1, 'round' => 0)` is then taken as keywords and fails with a wrong-number-of-arguments error, so pass the state in braces: `save_state(1, { 'round' => 0 })`.

## Layout

- `engine/`: `evo`, a GTP engine built on Brown's board code (`brown.c`, `gtp.c`) plus the network move policy (`generate_move.c`). `engine/test.c` tests GENANN only, not Go rules.
- `initial-population/`: `initial-population POP SIZE LAYERS NEURONS [SEED]` writes random networks named `0001.ann`, `0002.ann`, and so on.
- `evolve/`: `evolve RATE A.ann B.ann OUT.ann [SEED]` writes the child to `OUT.ann`. Its last stdout line is `summary operator=crossover|mutation differs_from_first=N differs_from_second=N` (weights differing from each parent; 0 means an identical copy). It either crosses over or mutates; it never does both. It exits 1 without writing anything when an input cannot be read. The runner checks the exit status and that the file exists, and stops breeding before deleting the parents if either fails.
  - `evolve/test.c` (`make test` in `evolve/`) pins `mutate()`'s hard-coded values statistically: it mutates seeded networks thousands of times and checks the shares against tolerances of about four standard errors. Changing a mutation value means updating those tests. The statistical checks do not depend on the exact random draws; only the copy and seed tests rely on a particular seed.
- `ruby/`, `runner`: tournament orchestration. `stats`, `ranking`: viewers. `multi`: rotates between several experiments.
- `lib/` is **unused**. `genann.c/h` has four identical copies (`lib/`, `engine/`, `evolve/`, `initial-population/`), and every Makefile compiles its own local copy. A GENANN change must go into all four until the cleanup consolidates them.
- `pcg-c/` is an upstream submodule (`imneme/pcg-c`). Do not edit it.

## Things that trip agents up

### Engine and network files

- `evo` starts at board size 6. Without a file argument it builds a random 5-layer network sized for 6×6. Always pass an `.ann` file and send `boardsize` before `genmove`.
- `boardsize` answers `? unacceptable size` for a size the loaded network does not fit, and `genmove` answers `? network does not fit the board` if no fitting `boardsize` came first. The process keeps running. `engine/enginetest.sh` (`make test`) checks a whole GTP session.
- The engine answers `name` with `Evo`.
- The startup message reads "total neurons", but the number it prints is `total_weights`.
- The `.ann` format is native binary with no header: four C `int`s (inputs, hidden_layers, hidden, outputs), then native `double` weights. It is not portable across ABIs.
  - A network for board size N has N²+1 inputs (komi first) and N²+1 outputs (pass last).
  - `engine/example.ann` is a 9×9 test fixture with 2×2 hidden neurons and 418 weights. It is not a trained player.
- Move choice takes the highest output. It is deterministic for a given network and position.
  - `initial-population` and `evolve` take an optional seed as their last argument; the same seed gives byte-identical output. Without one they seed from `time(NULL)` plus an address.
- Runs are reproducible from the experiment seed (the `seed` setting; `SetupExperiment` generates and saves one if it is missing). `ruby/seeds.rb` derives every other seed from it and a label: the initial population, each child (`birth`, generation, index), parent selection, tie order and colors per round, and a per-game GNU Go `--seed` for GNU Go players and the referee. Two runs with the same seed, even with parallel games, produce the same networks, pairings, moves, and rankings; only the date in the SGF headers differs. Losing a game on time would still differ.
- Besides `games`, the experiment database records `births` (each network's parents, operator, differing weights, seed, and SHA-256 of its `.ann`; generation 0 has operator `initial`) and `rankings` (each generation's standings, kept current after every game; final once the generation is done).
- Brown's own `final_score` is unreliable on arbitrary positions: an empty 9×9 board scores `W+87.5`. Use the referee's result.
- The build uses `-march=native`. Binaries are for the local machine only.
- macOS ships GNU make 3.81, which compares timestamps to the second. A C file edited and rebuilt within the same second can leave the old object in place, so a quick edit-rebuild-test loop (such as checking that a test catches a mutant) may run a stale binary. Delete the `.o` files before rebuilding in that case.

### Game results

- A GoGui `.dat` file is tab-separated: `GAME RES_B RES_W RES_R ALT DUP LEN TIME_B TIME_W CPU_B CPU_W ERR ERR_MSG`.
  - Columns can be empty, so split on tabs. The runner does this in `ruby/game_result.rb`. `stats` and `ranking` use it too.
  - The runner saves twogtp's stderr to `PREFIX.err` next to the `.dat` file while the game runs. Only stderr says which program crashed ("Black program died" or "White program died").
- Every win is worth 1 point, whether the loser is a network or a bot, and the odd player out in a round sits out with no point. The bots play in the ranking like networks, and against each other, on purpose: their place in the ranking shows how the networks compare to them. Parents are chosen by tournament selection (`select_parent` in `ruby/run_generation.rb`): draw `tournament_size` networks (setting, default 3) with replacement and keep the highest score. Only the order of scores matters, and equal scores pick uniformly.
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

- On a first run, `mise run run NAME` prompts on STDIN for settings. To start without prompts, create the experiment first; `SetupExperiment::SETTINGS` lists every setting and its default (`mise run new-experiment` without arguments shows them), and settings are stored as **strings**:
  ```sh
  mise run new-experiment NAME --board-size 9 --population-size 4 --hidden-layers 1 --layer-size 10 \
    --cross-over-rate 0.5 --game-length 10 --max-moves 200 --tournament-rounds 1
  ```
  With `4 one-generation`, that runs one generation of 12 pairings (11 games plus a bye for the odd player out) in a few seconds, which makes it a good smoke run. Delete `experiments/NAME` afterwards. Running it again breeds and plays the next generation. `experiments/` is gitignored.
- An experiment directory holds only `experiment.sqlite3`, the scratch directory `work/`, and the executables. The runner works inside `work/`, which it empties at the start of every generation, and calls `../evo`, `../evolve`, and `../initial-population`. Those are **symlinks** to the build output, so rebuilding changes a running experiment.
- Everything but a game's files in progress lives in `experiments/NAME/experiment.sqlite3`: the settings, and each generation's round, players, standings (`rankings`), and pending games. `RunGeneration#data` loads a generation's state in the shape `data.json` used to have, and `save_data` replaces it in one transaction after every game. On resume, `setup_complete` skips creating or breeding the population, the runner starts from the last generation in the database, and a generation's games are skipped only once `round` reaches `tournament_rounds`.
- The runner passes `-force` to twogtp, which deletes an existing `PREFIX.dat`. A game that was queued but not yet scored when the runner stopped is replayed from scratch on resume, and its `.err` is rewritten.
- Generation 0 names networks `0001.ann`, `0002.ann`, and so on. Later generations use `0.ann`, `1.ann`, and so on.
- Game results live in `experiments/NAME/experiment.sqlite3`, through `ExperimentDatabase` (`ruby/experiment_database.rb`, Sequel on SQLite). After scoring a game, the runner writes its row (players, winner or failure, length, referee result, GoGui's error message, stderr, and timings: `duration` is the wall-clock seconds of the whole `gogui-twogtp` run, measured by `WorkerPool`, and `time_black`/`time_white` are the seconds each player spent answering `genmove`, from twogtp's `TIME_B`/`TIME_W`, to a tenth; the rest of `duration` is the referee, the JVM, process starts, and the other GTP commands, plus a 3 s wait twogtp adds when a player crashed. Rows from before migration 005 have no timings) and deletes the game's `.dat`, `.sgf`, and `.err` files. The SGF is kept in the row only for every `keep_every`-th generation (setting, default 10; 0 keeps none). Rows are keyed by generation, round, and players, so a replayed game replaces its row.
- The schema changes only through Sequel migrations in `db/migrations/`. The runner applies pending ones when it opens the store. Add a new numbered migration for a schema change; never edit one that has run.
- `stats` and `ranking` only read: they open the experiment database read-only.
- Networks live in the `networks` table (the `.ann` bytes). The runner writes the current generation's networks into `work/` to play them, and the parents into `work/parents/` to breed, because both generations name their networks `0.ann`, `1.ann`, and so on. A generation's networks are dropped, in the same transaction that saves the next generation's setup, unless it is a `keep_every`-th generation. To inspect a network, export it: `ExperimentDatabase#export_networks(generation, directory)`.
- `stats` (without `--csv`), `ranking`, and `multi` loop forever. Run them with a timeout or in the background.
- Games run on a `WorkerPool` (`ruby/worker_pool.rb`): `concurrency` threads, created once per experiment, each running `gogui-twogtp` through `system`. On Ctrl-C the running games stop, the pool starts no queued game (`WorkerPool#halt`, called from the trap in `RunExperiment`), and the runner exits without scoring, leaving the unfinished games pending in the database, so resuming replays them.
- GNU Go 3.8 needs `scripts/patches/gnugo-3.8-gg-sort-empty.patch`. Without it, clang builds abort in `final_score` and during level 10 move generation. GCC builds happen to work either way. When changing how external tools are built, bump `release_id` in `scripts/install-external-tools.sh` so existing installs rebuild, then run `mise run verify`.
- The installer downloads only from the GitHub release named in `mirror_url` in `scripts/install-external-tools.sh`, never from upstream. `scripts/external-tools.txt` lists each archive's SHA-256 and upstream URL. To change an archive, edit the manifest, give `mirror_url` a new release tag (a published release's files should not change under the same tag), bump `release_id`, and run `mise run mirror-external-tools`. That task fetches from upstream and uploads to the release.

### Performance

- One timing sample on macOS (24 Sep 2026) put the cost in adjudication, not inference. Its referee was a clang-built GNU Go from before the `gg_sort` patch, so recheck it before relying on it.
  - A 9×9 network with 3 hidden layers of 400 neurons (about 387k weights) answered 1,000 `genmove` commands in 0.21 s, about 0.2 ms per move. Engine start and exit took about 10 ms.
  - Through `gogui-twogtp`, a random network playing itself passed after 18 moves and took 2.1–2.2 s with the GNU Go referee, but 0.12 s without it. Complete games of 93–180 moves between Brown, AmiGo, and the example network took 0.16 s each.
  - Early-passing networks, which is most of an untrained population, are the most expensive games to referee.

## Working conventions

- Fix defects test-first: write a test that fails, then fix.
- Commits: imperative, sentence-case subject (for example "Build GNU Go with common symbols on Linux"), with a body that explains why.
- Branches: `fix/…`, `chore/…`, `docs/…`.
- PRs: this is a personal repo with no Jira, so titles and bodies carry no ticket key. The body is one short paragraph that starts with the why, plus a line on how the change was verified.
- Open and update every PR by following `docs/pull-requests.md`: tests, the sweep for stale text, the review loop and its rules, and the CI check.
- CI (`.github/workflows/ci.yml`) runs on Ubuntu, with one job per kind of check: `c-tests` (`test-c`), `ruby-tests` (`test-ruby`), and `smoke-matches` (`setup-experiments`, `doctor`, `smoke`). Branch protection on `main` requires these jobs by name, so renaming or adding a job also needs the protection rule updated. CI caches the gems (keyed on `Gemfile.lock` and `mise.toml`) and the built external tools in `.local/evo-tools` (keyed on the installer, the manifest, and `scripts/patches/`). Both keys also include the runner image, because the caches hold compiled code. A change to how the tools build has to change one of those files, or CI keeps using the old build. Bumping `release_id` does that. Local setup is usually macOS with Apple clang, so code that builds GNU Go or other external tools has to work with both clang and GCC. A green local `verify` says nothing about Linux; wait for CI.
