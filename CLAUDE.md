# CLAUDE.md

Evo evolves the weights of a fixed dense neural network that plays Go. The C programs build, breed, and play networks. The Ruby scripts run tournaments through GoGui, with GNU Go as referee. The goal is to show measurable improvement from evolution, not a strong engine.

`PROJECT_NOTES.md` holds only work still to do: known defects, the planned cleanup order, proposed experiments, and open questions. Read it before changing behavior. When a change fixes a listed item or settles a question, delete it from `PROJECT_NOTES.md` in the same change. Do not record finished work or history there. If a future agent must know something about the change, put it in this file instead.

## Commands

Always go through mise. It pins Ruby 3.3.0 and Java 21, and it puts `.local/evo-tools/current/bin` (GNU Go, Brown, AmiGoGtp, GoGui) on `PATH`. A bare shell has none of these. For one-off commands, use `mise exec -- <cmd>`.

| Task | Command |
| --- | --- |
| First setup (submodule, gems, build) | `mise run setup` |
| Install external Go programs | `mise run setup-experiments` (downloads with pinned checksums and builds under `.local/evo-tools/`) |
| Build | `mise run build` (root `make`; builds `pcg-c` first) |
| Tests (C and Ruby) | `mise run test` (or `test-c`, `test-ruby` alone) |
| Full check, same as CI | `mise run verify` (tests, `doctor`, and refereed GoGui matches with every bot and Evo) |
| Run/resume experiment | `mise run run NAME [CONCURRENCY [one-generation]]` |

- Build from the repository root. The subdirectory Makefiles link `../pcg-c/src/libpcg_random.a` and fail if `make pcg` has not run.
- `mise run example` opens the GoGui window. Do not use it headless. `gogui-twogtp` runs without a display.
- Ruby tests live in `test/` (minitest). They build `RunGeneration` with `allocate` because `new` starts Ractors, and they stub `../evolve` by overriding the backtick method. There is no Ruby linter yet.

## Layout

- `engine/`: `evo`, a GTP engine built on Brown's board code (`brown.c`, `gtp.c`) plus the network move policy (`generate_move.c`). `engine/test.c` tests GENANN only, not Go rules.
- `initial-population/`: `initial-population POP SIZE LAYERS NEURONS` writes random networks named `0001.ann`, `0002.ann`, and so on.
- `evolve/`: `evolve RATE A.ann B.ann` writes `child.ann` to the current directory. It either crosses over or mutates; it never does both.
- `ruby/`, `runner`: tournament orchestration. `stats`, `ranking`: viewers. `multi`: rotates between several experiments.
- `lib/` is **unused**. `genann.c/h` has four identical copies (`lib/`, `engine/`, `evolve/`, `initial-population/`), and every Makefile compiles its own local copy. A GENANN change must go into all four until the cleanup consolidates them.
- `pcg-c/` is an upstream submodule (`imneme/pcg-c`). Do not edit it.

## Things that trip agents up

### Engine and network files

- `evo` starts at board size 6. Without a file argument it builds a random 5-layer network sized for 6×6. Always pass an `.ann` file and send `boardsize` before `genmove`.
- When the network size does not match the board, `genmove` calls `exit(1)` and the process dies. The engine does not return a GTP error.
- The engine answers `name` with `Brown`, so in SGF and GoGui output it looks like the real Brown bot.
- The startup message reads "total neurons", but the number it prints is `total_weights`.
- The `.ann` format is native binary with no header: four C `int`s (inputs, hidden_layers, hidden, outputs), then native `double` weights. It is not portable across ABIs.
  - A network for board size N has N²+1 inputs (komi first) and N²+1 outputs (pass last).
  - `engine/example.ann` is a 9×9 test fixture with 2×2 hidden neurons and 418 weights. It is not a trained player.
- Move choice takes the highest output. It is deterministic for a given network and position. The RNG seed matters only in `initial-population` and `evolve`.
  - Seeds come from `time(NULL)` plus an address. Runs cannot be reproduced.
- Brown's own `final_score` is unreliable on arbitrary positions: an empty 9×9 board scores `W+87.5`. Use the referee's result.
- The build uses `-march=native`. Binaries are for the local machine only.

### Game results

- A GoGui `.dat` file is tab-separated: `GAME RES_B RES_W RES_R ALT DUP LEN TIME_B TIME_W CPU_B CPU_W ERR ERR_MSG`.
  - Columns can be empty, so split on tabs. The runner does this in `ruby/game_result.rb`. `stats` and `ranking` still split on whitespace, so an empty column shifts `RES_R` and `LEN`, and anything not starting with `B` counts as a White win there.
  - The runner saves twogtp's stderr to `PREFIX.err` next to the `.dat` file. Only stderr says which program crashed ("Black program died" or "White program died"). Breeding deletes the empty `.err` files and keeps the rest.
- Points for beating an opponent: 1 for a network or Brown, 10 for AmiGo, 50 for GNU Go level 0, 100 for level 10 (`EXTERNAL_PLAYERS` in `ruby/run_generation.rb`). Parents are sampled in proportion to the cube of the score (`parent_pool` in `ruby/run_generation.rb`).
- Scoring rules (agreed with the owner, in `score_game` and `ruby/game_result.rb`):
  - A referee win (`B+` or `W+`) counts, including games stopped by the move limit. The winner gets the loser's `points`.
  - A draw gives no points.
  - A network that crashes loses, whatever the referee said.
  - These give no points and are logged and listed under `unscored` in `GEN/data.json`: a crashed external bot, a missing referee score (`?`), any other GoGui error (an illegal move is blamed on the program that rejected it, not the one that played it), and a missing or empty `.dat` file.
  - Failed games are never retried, so a broken setup stays visible.
- Check `RES_R` and `ERR`, not only whether a game finished. A crashed player shows only in `ERR`, and a crashed referee only as `?` in `RES_R`. `scripts/smoke-external-tools.sh` checks both. Keep it that way when changing it.
- Brown and AmiGo play deterministically. The 5 Brown and 10 AmiGo "instances" are copies of the same opponent, so replaying a pairing with the same colors adds no information.
- GNU Go seeds its random choices from the clock unless it gets `--seed N`. Runs started in different seconds differ, so compare GNU Go behavior with a fixed seed.

### Running experiments

- On a first run, `mise run run NAME` prompts on STDIN for settings. When running non-interactively, write `experiments/NAME/settings.json` first. Every value is a **string**:
  ```json
  {"board_size": "9", "population_size": "4", "hidden_layers": "1", "layer_size": "10",
   "cross_over_rate": "0.5", "game_length": "10", "max_moves": "200", "tournament_rounds": "1"}
  ```
  With `4 one-generation`, that runs one generation of 12 pairings (11 games plus a bye for the odd player out) in a few seconds, which makes it a good smoke run. Delete `experiments/NAME` afterwards. Running it a second time breeds generation 1, which usually crashes: random networks rarely win a game, so every score is 0, the parent pool is empty, and `evolve` gets a directory instead of a file (`fread: Is a directory`, then `Errno::ENOENT` on `child.ann`). This is a listed defect, not a setup problem. `experiments/` is gitignored.
- The runner works inside `experiments/NAME/GEN/` and calls `../evo`, `../evolve`, and `../initial-population`. Those are **symlinks** to the build output, so rebuilding changes a running experiment.
- State lives in `GEN/data.json`. It is rewritten after every game and not atomically. On resume, `setup_complete` skips creating or breeding the population. The generation's games are skipped only once `round` reaches `tournament_rounds`. Game hashes are built with symbol keys and read back with string keys after the JSON round trip.
- The runner passes `-force` to twogtp, which deletes an existing `PREFIX.dat`. A game that was queued but not yet scored when the runner stopped is replayed from scratch on resume, and its `.err` is rewritten.
- Generation 0 names networks `0001.ann`, `0002.ann`, and so on. Later generations use `0.ann`, `1.ann`, and so on.
- **Evidence gets destroyed:**
  - Breeding a new generation deletes every `.ann` and `.sgf`, and every empty `.err`, in the previous generation.
  - `stats` is not read-only. It moves each generation's `.dat` files into `data.tar.bz2` and caches results in `stats.json`.
  - Copy anything you need to inspect before running either of them.
- `stats` (without `--csv`), `ranking`, and `multi` loop forever. Run them with a timeout or in the background.
- The worker pool uses Ractors (`Ractor.yield`/`take`), which Ruby 4.0 removed. Stay on the pinned Ruby 3.3.0 until the planned thread-pool rewrite. The "Ractor is experimental" warning is expected.
- GNU Go 3.8 needs `scripts/patches/gnugo-3.8-gg-sort-empty.patch`. Without it, clang builds abort in `final_score` and during level 10 move generation. GCC builds happen to work either way. When changing how external tools are built, bump `release_id` in `scripts/install-external-tools.sh` so existing installs rebuild, then run `mise run verify`.

### Performance

- One timing sample on macOS (24 Sep 2026) put the cost in adjudication, not inference. Its referee was a clang-built GNU Go from before the `gg_sort` patch, so recheck it before relying on it.
  - A 9×9 network with 3 hidden layers of 400 neurons (about 387k weights) answered 1,000 `genmove` commands in 0.21 s, about 0.2 ms per move. Engine start and exit took about 10 ms.
  - Through `gogui-twogtp`, a random network playing itself passed after 18 moves and took 2.1–2.2 s with the GNU Go referee, but 0.12 s without it. Complete games of 93–180 moves between Brown, AmiGo, and the example network took 0.16 s each.
  - Early-passing networks, which is most of an untrained population, are the most expensive games to referee.

## Working conventions

- Fix defects test-first: write a test that fails, then fix. The cleanup order in `PROJECT_NOTES.md` puts characterization tests and the result-changing defects before any new experiment.
- Commits: imperative, sentence-case subject (for example "Build GNU Go with common symbols on Linux"), with a body that explains why.
- Branches: `fix/…`, `chore/…`, `docs/…`.
- PRs: this is a personal repo with no Jira, so titles and bodies carry no ticket key. The body is one short paragraph that starts with the why, plus a line on how the change was verified.
- CI (`.github/workflows/ci.yml`) runs on Ubuntu: `mise run setup-experiments`, then `mise run verify`. Local setup is usually macOS with Apple clang, so code that builds GNU Go or other external tools has to work with both clang and GCC. A green local `verify` says nothing about Linux; wait for CI.
