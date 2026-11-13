# Code reference

What the code does not say plainly about the engine, the arena, the breeding programs, the network files, the build, and CI.
Read the relevant section when changing those parts; the header comments it names hold the rest.
For the genome, mutation, and features as the owner reads them, see [The evolving genome](genes.md) and [Go features](features.md); keep both in step with changes to genes, features, `evolve`, or `stats`.

- [Layout](#layout)
- [Engine](#engine)
- [Arena and bot controller](#arena-and-bot-controller)
- [Breeding programs](#breeding-programs)
- [Engine and network files](#engine-and-network-files)
- [Build and test notes](#build-and-test-notes)
- [CI and external tools](#ci-and-external-tools)

## Layout

- `engine/`: `evo`, a GTP engine on Brown's board code (`brown.c`, `gtp.c`, `interface.c`), with the move choice (`generate_move.c`), the features (`features.c`), the Tromp–Taylor count (`score.c`), the arena (`arena.c`), and the bot controller (`bot.c`).
- `initial-population/` and `evolve/`: the breeding programs, and `evolve/perturb`, a tool for `scripts/brittleness.rb`.
- `lib/`: the network code every program links, built once as `lib/libann.a`.
  `genann.c` and `genann.h` are upstream GENANN v1.1.1, unchanged (license in `lib/GENANN-LICENSE`); to update GENANN, copy the new upstream files over them.
  Evo's additions live in `ann.h` and `ann.c`; programs include `ann.h`, never `genann.h`.
  GENANN stays: it is small, tested upstream, and does what the experiments need; inference is negligible next to adjudication, so batching is not needed.
  Its hidden layers all have one width; revisit that only if an experiment needs different widths.
  `args.c` holds the strict number parsing that `evolve`, `perturb`, and `initial-population` share.
  `lib/minctest.h` is the test framework for `lib/` and `evolve/`.
- `ruby/` and `runner`: the runner, the tournament, the benchmark (`ruby/checkpoint_benchmark.rb`), and `stats` (`ruby/experiment_stats.rb`, `ruby/stats_report.rb`); [Experiment reference](experiment-reference.md) describes them.
- `pcg-c/` is an upstream submodule (`imneme/pcg-c`); do not edit it.
- [`docs/gtp/`](gtp/README.md) holds the GTP version 2 specification that `evo` and the bot controller speak (`gtp2-spec.txt` for grep), under the GNU Free Documentation License, not the repository's MIT licence.

## Engine

Brown's rules, which `engine/rules_test.c` pins:

- Captures remove every neighbouring opponent string left without a liberty.
- Ko is simple ko: only an immediate single-stone recapture is refused, and any other move or a pass ends it; there is no superko.
- `legal_move` and GTP `play` accept suicide; the suicided string is removed at once.
- Brown's own `final_score` is unreliable on arbitrary positions: an empty 9×9 board scores `W+87.5`.
  Use the arena's `tromp_taylor_score` or the referee's result.

The move choice (`generate_move`):

- Each point scores the network's output plus B: the feature weight of each of the network's move features that is 1 at the point.
  The pass output gets no B.
- It plays the highest-scoring point that `move_allowed` (`features.c`) allows: legal, not suicide, and not the opponent's suicide point (in effect an own eye) unless it touches an opponent stone.
- It passes when nothing is allowed or the pass scores at least as high, so a tie passes.
  Saturated `sigmoid_cached`, threshold, and relu outputs tie often, so a pass-heavy run is selection at work, not a bug.
- It is deterministic for a given network and position.
- `generate_move.o` links without the GTP code (`gtp.o`, `interface.o`); `rules_test` links that way, which keeps it so.
- Start a game with `new_game()`, not `clear_board()`, which keeps the ko point (`engine/brown.h`).
- Handicap stones are not moves: code that places them with `play_move` calls `clear_last_move()` after.

The features (`features.c`, `features.h`; include `brown.h` first):

- Every move feature is 0 where `move_allowed` is false, so the features and the moves agree on which points count.
- The group bits and the layout's counts (`ANN_GROUP_*`, `ann_feature_count`, `ann_layout_inputs`) live in `lib/ann.h`, since the `.ann` reader needs them.
  `ruby/feature_groups.rb` mirrors those tables for the runner, so change both.
- `move_features_at` computes the whole board for one point, so use it only in tests.
- The shapes are michi's `pat3src` (MIT, Petr Baudiš, notice in the source), expanded as michi's `pat3_expand` does into a table of the 65,536 3×3 codes.
  `engine/features_test.c` pins the tables by their counts and a hash per family computed with michi's own `pat3_expand` (the Python is in the test's comment).

GTP, `evo NETWORK.ann`:

- It starts at board size 6, so send `boardsize` before `genmove`.
- Without exactly one file argument it prints a usage message and exits 1; a file that is missing or holds no network makes it exit 1 at startup with a message naming it.
- `boardsize` answers `? unacceptable size` for a size the network does not fit, and `genmove` answers `? network does not fit the board` if no fitting `boardsize` came first; the process keeps running.
- It answers `name` with `Evo`.

## Arena and bot controller

`engine/arena.c`'s header comment defines both invocations, the manifest, every output record, and the exit statuses; `engine/bot.h` defines the controller.
What crosses programs or is easy to miss:

- The runner plays every tournament game with `arena --mixed`.
  The legacy invocation (`arena SIZE KOMI MAX_MOVES SCHEDULE`, networks only) is used only by `scripts/arena-agreement.sh` and `engine/arenatest.sh`.
- `arena --protocol` prints `3`; a change to the `--mixed` input or output raises it, and `ruby/arena_result.rb` (`ArenaResult::HEADER`) must follow.
- It exits 2 right after a failure record, with no later game and no trailer, and never exits 130 or 143, which the runner reads as an interrupt.
- Failure records (`timeout`, `illegal`, `crash`, `launch`, and `network_error` with `error=both`) are output only.
  Stored end reasons are `passes`, `limit`, `resign`, `time`, and one-sided `network_error`.
- `ArenaResult::MixedStream` (`ruby/arena_result.rb`) reads the output a line at a time as it arrives.
  A record before the header, for an unscheduled ID, or a second record for one ID raises `ArenaResult::Broken`, since the arena writes none of them.
  `test/fixtures/arena/` pairs arena lines with the move nodes of twogtp SGFs of the same games.
- The controller starts a bot from the stored command as twogtp does (split as `StringUtil.splitArguments`, `execvp`, never a shell) and repeats twogtp's setup sequence, since Brown reseeds its random moves on `boardsize` (`engine/bot.h`).
- After a SIGKILL the arena cannot clean up: a bot that exits at stdin EOF (Brown, AmiGo, GNU Go, and michi do) ends by itself, but one that ignores EOF keeps running in its own process group.
  `engine/arenatest.sh` pins this.
- `engine/botdriver` (built by plain `make`) drives bots through the controller from a script or relays a whole game.

Its tests and smoke checks:

- `engine/bottest.sh` checks the controller against `engine/fakebot`, a scripted fake GTP program, and `engine/arenatest.sh` plays its bot games against `fakebot` only, so CI's `c-tests` and the `gcc:14` check need no bots.
  Both stop, failing, if a run hangs for 60 s.
- `arenatest.sh` pins moves with hand-made networks without hidden layers, whose moves follow from the rules alone.
  It compares seeded random networks with evo's GTP moves instead of pinning theirs, since `-march=native` floating point may differ between machines.
- `sh scripts/bot-response-times.sh [GAMES [LANES [DEADLINE]]]` checks that the tournament's bots answer setup, `play`, and `quit` well within the deadline.
- The smoke checks are the `smoke-*` tasks in `mise.toml`, whose descriptions say what each checks; CI runs each as `smoke (NAME)`.
- `scripts/arena-agreement.sh` (`smoke-agreement`) plays seeded random networks in the arena and through `gogui-twogtp` and compares moves, ends, and scores; its header says how.
  It needs at least 5 two-pass games without dead stones for the referee comparison (the sample gives 24); the count depends on the networks' moves, which `-march=native` can change, so if a machine falls below the minimum, enlarge the sample rather than lower it.
  The file is not executable, so run it with `sh`.

## Breeding programs

`initial-population`:

- `initial-population POP SIZE LAYERS NEURONS COPY_CHANCE WEIGHT_CHANGES WEIGHT_STEP ACTIVATION_RATE STRUCTURE_RATE GROUPS NOISE FEATURE_STEP [SEED]` writes `0001.ann`, `0002.ann`, and so on, and prints one genes line per network in file order (`ann_print_genes_line` in `lib/ann.h`).
- Each network's feature-weight noise is drawn after its weights from the same stream, even when NOISE is 0, so the number of draws does not depend on NOISE.
- The runner's arguments come from `RunGeneration.initial_population_arguments`; it stores each line in the network's `births` row, and `parse_genes` refuses lines that are missing, malformed, or of another shape or feature set than the experiment's.

`evolve`:

- `evolve RATE META_RATE MAX_LAYERS MAX_WIDTH ADD_WIDTH A.ann B.ann OUT.ann [SEED]` writes one child to `OUT.ann`; the runner's arguments come from `RunGeneration#evolve_arguments`, with min(`layer_size`, `max_layer_size`) as ADD_WIDTH.
- Its last two stdout lines, the `summary` line and the child's genes line (`evolve/main.c`), go into the child's `births` row; a missing or malformed line, a genes line of another feature set, a failed exit, or a missing `OUT.ann` stops breeding before the parents are deleted.
- A differs count covers the network weights, not the feature weights, so 0 can be a mutation that changed only genes and feature weights; it is -1, stored as NULL, for a parent of another shape.
- It exits 1 without writing when the parents differ in inputs, outputs, or feature groups (compared as masks, since `shapes` and `liberties` add as many inputs).
- [The evolving genome](genes.md) explains how a child is made, the shape changes, and crossover; the code is `breed()` and `mutate()` in `evolve/evolve.c` and the structural operators in `evolve/evolve.h`.
- The draws come in a fixed order (the comment above `mutate()`), so a seed gives one child; changing the order changes every seeded run.
- Widen keeps the outputs `==` equal with clang; GCC vectorizes GENANN's sums, so a longer row can round differently in the last bit.
- `evolve/test.c` checks mutation statistically, at about four standard errors, so most checks do not depend on the exact draws; the copy, seed, and pinned-weights tests do.
  `test_mutate_weights_are_pinned` pins the changed weights of two seeds within 1e-12, not by a hash, since clang and GCC may differ in the last bits of `exp()`.
  `make evolvetest` relies on particular seeds (seed 28 draws a copy, 8 switches both activations, 3 adds a layer).
  Changing how mutation works means updating those tests.

`evolve/perturb NET OUT WEIGHT_CHANGES WEIGHT_STEP SEED` (usage in `evolve/perturb.c`):

- It writes a child that differs from NET only in its network weights, for `scripts/brittleness.rb` (`docs/analysis-scripts.md`, "How brittle a champion is").
- It replaces OUT through a temporary file, so OUT is either as it was or the whole child, and prints `differs=N`.
- It is a tool, not an experiment program: `mise run build` builds it, but the runner neither needs nor copies it (`SetupExperiment::EXECUTABLES`).

## Engine and network files

The `.ann` format, version 2 (`lib/ann.h`), in this order:

- the magic `EVOANN` and the format version, 2, as a uint32;
- the sizes inputs, hidden_layers, hidden, and outputs as int32s (hidden is 0 without hidden layers: normalized on write, required on read);
- a uint32 code for the hidden and one for the output activation (`ANN_ACTIVATIONS`' positions plus one);
- the five genes as doubles, in `ann_genes`' order;
- the features: a uint32 mask of feature groups (`ANN_GROUP_*`, 0 for none), `feature_step` as a double, and one double weight per move feature of the groups (F = `ann_feature_count`, in `ANN_FEATURES`' order);
- the weights as doubles.

That is 86 + 8F bytes before the weights.
All numbers are little-endian and fixed-size, so files are portable; `lib/test.c` checks the bytes.

- Reading refuses any version but 2, genes or features outside their ranges (`ANN_*_MIN` and `_MAX` in `lib/ann.h`; `copy_chance` may also be exactly 0), a shape that fits no square board of 2 to 23 points a side with the file's groups, and a file too short or too long.
- Writing refuses invalid genes or features but does not check the shape against a board, since `evolve/test.c` writes small networks of other shapes.
- A network for board size N has N²+1 outputs (pass last) and `ann_layout_inputs(groups, N²)` inputs: N²+1 without groups (komi first), and 974 on 9×9 with every group.
- There are two loads, which accept the same files and give the same network.
  `ann_binary_read` builds it with `genann_init`, which draws every weight from the global PCG stream before the file's weights replace them.
  `ann_binary_read_for_play` lays it out with `ann_allocate`, without drawing.
  `evolve` keeps the drawing load, since it seeds PCG before loading its parents and a seed's child depends on those draws; `evo` and the arena use the play load; `initial-population` loads nothing.
  `genann.c` stays upstream, so `ann_allocate` lives in `ann.c`.
- `engine/example.ann` is a 9×9 test fixture (2×2 hidden neurons, cached sigmoid, the default genes, no feature groups, 418 weights), not a trained player.

Seeds and reproducibility:

- `initial-population` and `evolve` take an optional seed as their last argument, and `perturb` a required one; the same seed gives byte-identical output.
- `evolve` prints its output file's name as given (`Saving output to %s ...`), so a seeded comparison of what two builds print needs the same OUT name in both.
- A run is reproducible from the experiment's `seed` setting (`SetupExperiment` generates and saves one if it is missing); `ruby/seeds.rb` derives every other seed from it and a label.
  Two runs with the same seed, even with parallel games, produce the same networks, pairings, moves, rankings, and benchmark results; only the date in the SGF headers differs.
  A game lost on time would differ, and so do games of a GNU Go whose level is not pinned, since given `time_settings` it changes its level by its own clock (`docs/experiment-reference.md`, "The default panels and the michi ladder").

The experiment database records, besides `games`:

- `births`: each network's parents, operator, differing weights, seed, the SHA-256 of its `.ann` (against which a resumed generation verifies `networks/N/`), and its genes line's columns ([The evolving genome](genes.md) lists them; a feature weight is NULL when the network's groups lack that feature).
  Generation 0 has operator `initial`, genes, and no parent, structure, or activation_changed.
  An elite (`elite_share`), which no `evolve` makes, has operator `elite`, its one parent as `first_parent` (no `second_parent`), `parent` `first`, `differs_from_first` 0, `structure` `none`, `activation_changed` false, the genes and feature columns of its parent's birth, and its place's birth seed, unused.
  A differs count is NULL for a parent of another shape, so readers such as `ExperimentStats` handle NULL.
- `rankings`: each generation's standings, kept current after every game and final once the generation is done.

## Build and test notes

- Build from the repository root.
  The subdirectory Makefiles link `../pcg-c/src/libpcg_random.a` and `../lib/libann.a`, and fail if `make pcg` and `make lib` have not run.
  The top-level `Makefile` runs each subdirectory's with `$(MAKE) -C DIR`, so a missing directory, such as `pcg-c/src` before `git submodule update --init`, stops it with an error instead of recursing without end (`test/makefile_test.rb`).
- The build uses `-march=native`, so binaries are for the local machine only.
- macOS ships GNU make 3.81, which compares timestamps to the second.
  A C file edited and rebuilt within the same second can leave the old object in place, and an object rebuilt in the same second as the program is not linked again, so a quick edit-rebuild-test loop (such as checking that a test catches a mutant) may run a stale binary and report a mutant as surviving.
  Deleting the `.o` is not enough: delete the changed `.o` files and the programs that link them before rebuilding.
  A build tree copied with `cp -R` (to patch an external tool, for example) has the same trap: its objects carry the copy's time, so an edit soon after may not rebuild them and a broken build looks correct.
  Build a mutant from a tree without objects (`make clean` first).
- macOS `cmp -n N A B SKIP1 SKIP2` misreports EOF when the bytes left after the two skips differ in length, even though `-n` limits the range.
  To compare byte ranges at different offsets, dump them with `od` and compare the dumps.
- zsh, the default shell here, expands a word that starts with `=` as a command's path, so an argument such as Pachi's `-t =500` fails with "500 not found".
  Quote it (`'=500'`) or run the command through `sh -c`.
- zsh does not split an unquoted variable into words, so settings held in one string (`ARGS='--board-size 9 --seed 1'; mise run new-experiment NAME $ARGS`) arrive as a single argument and fail with "invalid option: --board-size 9 --seed 1".
  Hold them in an array (`args=(--board-size 9 --seed 1)`, then `"${args[@]}"`).
- In Claude Code's shell, `grep` is a function that runs ugrep, which refuses a pattern with two or more long bounded repeats (`a.{0,200}b.{0,200}c`: "exceeds complexity limits", exit 2).
  Use `grep -P`, `command grep` (macOS's BSD grep), or a short script.
- `mise run test-ruby` takes 70–180 s on the owner's machine, so give `mise run test` a Bash time limit of at least 400000 ms; without one, Claude Code moves it to the background after 2 minutes.
- `gogui-twogtp` runs without a display.
  GoGui's docs do not give every option's format; its jars do: `mise exec -- javap -c -classpath .local/evo-tools/current/gogui/lib/gogui.jar net.sf.gogui.game.TimeSettings` shows what `-time` accepts.
  Confirm what you find with a few games.
- Ruby tests (`test/`, minitest) build `RunGeneration` with `allocate` and set its instance variables directly (settings, a seeded `rng`, a fake pool).
  They stub the C programs: `evolve` with `evolve_pool` (`test/test_helper.rb`), and `initial-population` by overriding `run_initial_population`.
- The PR script tests run `scripts/pr-checks.sh` against a fake `gh` on `PATH` (`test/fake_gh.rb`); `PR_CHECKS_TRIES` and `PR_CHECKS_SLEEP` shorten the wait for checks to register.
- There is no Ruby linter yet.
- In fixtures, Sequel's `multi_insert` takes its columns from the first row's keys: a key missing there is dropped from every row, without an error (`[{a: 1}, {a: 2, b: 3}]` stores `b` as NULL).
  Give every row every key, or insert the rows one at a time.
- `ExperimentDatabase#save_state` and `RunGeneration#save_data` take a keyword argument besides the state hash, so Ruby 3 takes a brace-less hash such as `save_state(1, 'round' => 0)` as keywords and fails with a wrong-number-of-arguments error.
  Pass the state in braces: `save_state(1, { 'round' => 0 })`.

## CI and external tools

- CI (`.github/workflows/ci.yml`) runs on every pull request, whatever its base (so stacked PRs get checks), and on pushes to `main`, on Ubuntu.
- It has one job per kind of check: `c-tests` (`test-c`), `ruby-tests` (`test-ruby`), and one `smoke (CHECK)` job per smoke check (`setup-experiments`, `doctor`, `smoke-CHECK`; a matrix over `matches`, `controller`, `arena`, `patches`, and `agreement`); `mise run smoke` runs them all one after the other.
- Each job has `timeout-minutes`, a few times its usual length, so a hang fails instead of running for GitHub's default of 6 hours.
- Branch protection on `main` requires these jobs by name, so renaming or adding a job (or a matrix entry) also needs the protection rule updated.
- CI caches the gems (keyed on `Gemfile.lock` and `mise.toml`) and the built external tools in `.local/evo-tools` (keyed on the installer, the manifest, and `scripts/patches/`); both keys include the runner image, because the caches hold compiled code.
  A change to how the tools build has to change one of those files, or CI keeps using the old build; bumping `release_id` does that.
- Local setup is usually macOS with Apple clang, so code that builds GNU Go or other external tools has to work with both clang and GCC.
  A green local `verify` says nothing about Linux; wait for CI.
- Docker reproduces CI's toolchain locally: `gcc:14` for the C build, `ubuntu:24.04` for its `mawk` and `dash`.
  Docker runs in OrbStack on the owner's machine; when `docker` cannot reach its daemon, OrbStack is stopped, and `orb start` starts it.
  A `gcc:14` build that fails with `brown.dep: Directory nonexistent` is a flake; run it once more.
  Copy `pcg-c` into the image as plain files: its `.git` points back to the checkout it came from, so a `git clean` inside the copy deletes that checkout's build output.

michi-c2 (github.com/db3108/michi-c2, MIT, commit `d2a4cb8`) is installed as `michi`, an opponent whose strength is its playouts per move, not a clock:

- `scripts/patches/michi-c2-d2a4cb8.patch` (its header lists each change) fixes an out-of-bounds write that crashed it after an opponent's pass and a `delta[8]` over-read, makes GTP `play` accept a move that repeats an earlier position (the arena forbids only a simple ko retake; michi's own `genmove` still avoids repeats), builds with plain `cc` flags (no `-march=native`), ignores `time_settings` and `time_left` (it would otherwise spend playouts by the clock), writes no `michi.log` and nothing on stderr, loads no pattern files from its working directory, and holds 10,000 moves, answering `?` to `play` and `genmove` once full.
  `scripts/smoke-bot-patches.sh` checks each patched behaviour.
- Command line: `michi gtp [--sims N] [--seed N] [--play-until-end]`.
  `--sims` sets the playouts per move (default 2000, at least 1), `--seed` the random seed (0 to 2³²−1; 0 means a fixed seed, not the clock; default 1), and `--play-until-end` stops it from passing early.
  The same command and seed play the same game.
  An invalid value (`--sims 0`, `--seed x`) exits 2; an unknown option, or one without its value, prints the usage and exits 255.
- The default panels play it at 80, 300, and 1200 playouts with `--play-until-end`, calibrated on 9×9 only (`docs/experiment-reference.md`, "The default panels and the michi ladder").
- michi exits 0 at stdin EOF, like the other bots.
- Its `clear_board` keeps its superko history (`zhistory`) and its random state, so a seeded michi game repeats only in a new process.
  The arena starts every bot anew for each game and the benchmark runs `gogui-twogtp -games 1`; keep that for any bot kept running across games.
- Its own `genmove` checks superko only from move 30 (`sgf.c:93`).
- Its board code shifts `1` left by 31 in a signed int (`board.c`, `board_util.c`): undefined behaviour that works in practice and the one known UBSan report, so a sanitizer run need not chase it.
- Command-line options apply before an optional config file, so a `random_seed` in such a file would override `--seed`; no evo command uses one.
