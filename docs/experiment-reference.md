# Experiment reference

How tournament and benchmark games are played and scored, how the runner, its storage, `stats` and the benchmark work.
What each analysis script prints and how to read it is in [Analysis scripts](analysis-scripts.md).
Read the relevant section when changing experiments or reading their results; what past experiments and analyses found is in [Findings](findings.md).
For the genome and feature settings, see [The evolving genome](genes.md) and [Go features](features.md).

- [Game results](#game-results)
  - [Tromp–Taylor against the GNU Go referee on the same games](#tromptaylor-against-the-gnu-go-referee-on-the-same-games)
  - [The default panels and the michi ladder](#the-default-panels-and-the-michi-ladder)
- [Running experiments](#running-experiments)
  - [Creating and running](#creating-and-running)
  - [Settings](#settings)
  - [The experiment directory](#the-experiment-directory)
  - [Networks on disk](#networks-on-disk)
  - [The tournament round](#the-tournament-round)
  - [Storage](#storage)
  - [Breeding](#breeding)
  - [Interrupts and resume](#interrupts-and-resume)
  - [Timings](#timings)
  - [Progress line](#progress-line)
  - [Worker pool](#worker-pool)
  - [Archiving](#archiving)
  - [stats](#stats)
  - [External tools](#external-tools)
- [Benchmark](#benchmark)

## Game results

- Every tournament game is played by the arena (`arena --mixed`, [The tournament round](#the-tournament-round)); the checkpoint benchmark plays through `gogui-twogtp`.
- A GoGui `.dat` file is tab-separated (`GAME RES_B RES_W RES_R ALT DUP LEN TIME_B TIME_W CPU_B CPU_W ERR ERR_MSG`) with columns that can be empty, so split on tabs (`ruby/game_result.rb`).
  Check `RES_R` and `ERR`, not only whether the game finished: a crashed player shows only in `ERR`, and a crashed referee only as `?` in `RES_R`; `scripts/smoke-external-tools.sh` checks both.
  Only twogtp's stderr, which the benchmark saves to `PREFIX.err`, says which program crashed ("Black program died" or "White program died").
- Each experiment stores its opponents, its benchmark panel, and its scoring when it is created (tables `opponents`, `benchmark_opponents`, and `scoring`, from `SetupExperiment::DEFAULT_OPPONENTS`, `DEFAULT_BENCHMARK`, and `DEFAULT_SCORING`), and the runner reads them from there, so changing the defaults only affects new experiments.
- By default every win is worth 1 point, whether the loser is a network or a bot, a draw 0, and the odd player out in a round sits out with 0.
- `scoring['rules']` is the version of the tournament rules (`RunGeneration::SCORING_RULES`, `4`: every tournament game in the arena, and copies of one bot kept apart).
  Bump it when `games_from_ranking` changes who plays whom, or `score_game`, `points_for`, or `ArenaResult` change what counts or what stops a run; an experiment created under other rules refuses to run.
- The bots play in the ranking like networks, and different bots against each other, on purpose: their place in the ranking shows how the networks compare to them.
- Two copies of one bot do not play each other while anyone else is left.
  `games_from_ranking` pairs the ranking from the top; when the next player is a copy of the same opponent (the same `opponent`; networks have none), the first plays the nearest later player that is not, and the copies it passed keep their places for the next pairs.
  Only a tail of nothing but copies of one bot is paired among itself.
  Where no pair of neighbours is two copies, the pairs and their colours are those of plain neighbour pairing.
  Why: a game between two copies would only hand a point to one copy of the same bot (Brown and AmiGo play deterministically; michi and GNU Go copies differ only in their per-game seed).
- Parents are chosen by tournament selection (`select_parent` in `ruby/run_generation.rb`): draw `tournament_size` networks (setting, default 3) with replacement and keep the highest score.
  Only the order of scores matters, and equal scores pick uniformly.
- Every game is area-scored with the experiment's komi (the `komi` setting, a multiple of 0.5 from −50 to 50, default 6.5, so a margin is never 0 without a draw), which the arena and `gogui-twogtp` send to every player and the referee.
  The benchmark's referee, `GameResult::REFEREE`, is GNU Go with `--chinese-rules` (the benchmark appends its `--seed`); GNU Go players keep their own rules.
  An experiment without a `komi` setting refuses to load.
- Scoring rules (agreed with the owner; `score_game` and `points_for` in `ruby/run_generation.rb`, and `ruby/arena_result.rb`):
  - The arena's Tromp–Taylor count decides every tournament game, with a bot or not (`scorer` `tromp_taylor`); in the benchmark, the GNU Go referee (Chinese rules) decides.
    A win (`B+` or `W+`) counts, including games stopped by the move limit, which the arena counts as the board stands, dead stones included.
    How often the two scorers pick different winners on the same games is [below](#tromptaylor-against-the-gnu-go-referee-on-the-same-games).
  - A draw gives no points.
  - A bot that resigns loses (`B+R`/`W+R`, `end_reason` `resign`), whoever its opponent.
  - A network that takes more than its main time, `game_seconds` seconds for all its moves of the game, loses (`B+T`/`W+T`, `end_reason` `time`), and so does a network the arena cannot load (missing, unreadable, or not fitting the board; `end_reason` `network_error`).
  - A game the arena could not finish is never scored or stored, and stops the run (next item), so a broken bot cannot fill the ranking with games nobody won.
- A game the arena could not finish is one where a bot missed a deadline, took its side past main time, played an illegal move, crashed or answered with a GTP error, or could not be started (failure records `timeout`, `illegal`, `crash`, `launch`); one neither network can load; or one without a valid record (the arena died, or its output is cut off or malformed).
  The runner has stored the chunk's other games as their records arrived.
  It sends SIGTERM to the round's other chunks still running instead of waiting out their bots' deadlines (`WorkerPool#terminate`; their further output and statuses are never read), and exits 1 (`RunGeneration::ArenaStopped`, printed without a backtrace).
  The report (`ArenaStopped`) names the chunk, the generation and round, what went wrong, each withheld game with its end reason, failing side and message (or `no record`), the chunk's stderr (the resume empties `work/`), and how many other chunks it terminated and how many had not started, and ends with "resume after fixing the cause".
  A record before the header, a record for a game not in the chunk, or a second record for one game stops the run as that line arrives, with no exit status, since the chunk may still run; the SIGTERM goes to it too.
  Every game not yet stored stays pending, and a resume replays it with the same seeds, so which chunk stops the run does not matter.
  A chunk killed by SIGINT or SIGTERM, or exiting 130 or 143, is an interrupt instead ([Interrupts and resume](#interrupts-and-resume)), which the arena's own exits never are.
- A generation copies each opponent's command and name (`opponent`) into its `players` rows when it starts, so a stopped generation resumes with the command it started with: fix the bot program, or edit that generation's `players` rows; changing `opponents` only affects later generations.
- GNU Go seeds its random choices from the clock unless it gets `--seed N`, and michi uses its own default seed, the same in every game.
  The runner passes every GNU Go and michi command the game's seed (`Seeds.with_bot_seed`; in the tournament `Seeds.gnugo(seed, 'game', generation, round, black, white)`, in the benchmark the game's seed, which the referee shares); Brown and AmiGo play deterministically and get none.
  Outside the runner, compare GNU Go or michi behaviour with a fixed seed.

### Tromp–Taylor against the GNU Go referee on the same games

`scripts/compare-arena-scoring.rb` (at `6156e4a`; removed once `bigrun` and `even-bigger` were gone, `git show fedc5ef:scripts/compare-arena-scoring.rb`) played one seeded set of tournament-style 9×9 games (komi 6.5, 200 moves) twice: through `arena --mixed`, and through `gogui-twogtp` with the seeded referee `GameResult::REFEREE`.
Champions and random generation-0 networks of `bigrun` and `even-bigger` played Brown, AmiGo, GNU Go level 0 and each other, and the bots each other; every game had identical moves in both and ended by two passes, so the differences are all scoring.

| Pairing | Games | Same result | Same winner, other margin | Winner changes | Mean \|margin difference\| |
| --- | ---: | ---: | ---: | ---: | ---: |
| network–Brown | 50 | 47 | 3 | 0 | 1.8 |
| network–AmiGo | 50 | 32 | 11 | 7 | 7.1 |
| network–GNU Go level 0 | 50 | 0 | 33 | 17 | 68.5 |
| bot–bot | 19 | 9 | 7 | 3 | 28.9 |
| network–network | 80 | 27 | 48 | 5 | 15.4 |
| all | 249 | 115 | 102 | 32 | 22.7 |

Why the referee differs, in the 134 games where it does (winner changes in brackets):

- **Dead stones left on the board** (99 [23]): Tromp–Taylor counts a dead stone for its owner and makes the region around it neutral; the referee removes it and gives the area to the other side.
  A network or GNU Go often passes with the opponent's dead stones still inside its area.
- **Dame** (11 [0]) and **dead stones and dame** (10 [4]): GNU Go's `final_score` counts the neutral points as if filled in turn starting with the side to move; Tromp–Taylor gives them to neither side.
- **Judgement** (14 [5]): neither rule reproduces the referee, mostly by 1–3 points.

Against AmiGo, all 7 winner changes go from the network (by the referee) to AmiGo (by Tromp–Taylor), since the network passed without capturing AmiGo's dead stones; against GNU Go level 0, all 17 go the other way, since GNU Go passes with the network's dead stones on the board; against Brown, which fills the board before passing, none.
So a Tromp–Taylor tournament rewards a network for capturing dead stones before it passes, and the tournament's GNU Go and michi play on until the dead stones are captured (`--capture-all-dead`, `--play-until-end`; the endings run below).

### The default panels and the michi ladder

New experiments get the whole ladder from the start (`SetupExperiment::DEFAULT_OPPONENTS`, `DEFAULT_BENCHMARK`), weakest first as far as calibrated (the pinned GNU Go levels are not, below):

| Name | Command | Tournament copies | Benchmark |
| --- | --- | ---: | --- |
| Brown | `brown` | 5 | `Brown`, same command |
| AmiGo | `amigogtp` | 10 | `AmiGo`, same command |
| MichiWeak | `michi gtp --sims 80 --play-until-end` | 5 | same name and command |
| MichiMid | `michi gtp --sims 300 --play-until-end` | 5 | same name and command |
| MichiStrong | `michi gtp --sims 1200 --play-until-end` | 5 | same name and command |
| GnuGoZero | `gnugo --level 0 --min-level 0 --max-level 0 --mode gtp --capture-all-dead` | 3 | `GnuGoLevel0`, `gnugo --level 0 --min-level 0 --max-level 0 --mode gtp` |
| GnuGoTen | `gnugo --level 10 --min-level 10 --max-level 10 --mode gtp --capture-all-dead` | 3 | `GnuGoLevel10`, `gnugo --level 10 --min-level 10 --max-level 10 --mode gtp` |

- The benchmark also plays `Gen0Champion` and `PastChampions` ([Benchmark](#benchmark)).
  Its GNU Go has no ending flag: its referee removes dead stones anyway, so the flag would only change its play, and the benchmark keeps the definition earlier checkpoints were measured with.
- GNU Go's level is pinned (`--min-level` and `--max-level` equal to `--level`).
  Given `time_settings`, GNU Go 3.8's GTP `genmove` adjusts its level before every move by its own clock (`adjust_level_offset`, even without `--autolevel`) between its minimum (default 0) and maximum (default 10): unpinned, `--level 0` plays at level 10 within a few moves whenever its moves are fast and lower under load, so its strength depends on the machine's load and its games do not always repeat for a seed.
  Experiments created before the pinning keep their stored, unpinned commands (`GnuGo`, `GnuGoLevel0`).
  `scripts/smoke-bot-patches.sh` checks that each pinned command plays the same moves without time commands, with plenty of its clock left, and with little.
- A pinned GNU Go cannot play faster when its clock runs low, so `game_seconds` must leave it room: one that runs past its main time is a `timeout` failure, which stops the run.
  How much room level 10 needs is not measured.
- The michi levels are michi-c2 (`docs/code-reference.md`) at fixed playouts per move, so their strength does not depend on the machine's load, and their games repeat for a seed.
- Names end in a letter, since copies are named by a number after the name.
- The levels were calibrated on 9×9 only, so `SetupExperiment` refuses any other board size for an experiment whose `opponents` or `benchmark_opponents` hold a michi command (a command whose first word is `michi`): `new-experiment` and the prompts refuse before anything is saved, and a stored experiment refuses to load.
  Tests and smoke checks on other sizes do not go through it.

The calibration plays in the tournament's own conditions: `mise exec -- scripts/calibrate-bots.rb` (at `5ca3e92`) plays every game through `arena --mixed` at 9×9, komi 6.5, `max_moves` 200, 60 s main time a side (`game_seconds` 60), 10 s response deadline and grace, per-game seeds, both colours, 3 games at a time.
It ran on a busy laptop (load averages 2.0–2.5), which matters only for GNU Go: the calibration's GnuGo is the unpinned `--level 0`, which played at up to level 10 by its clock.
The pinned levels 0 and 10 have not been placed on the ladder: neither has played the michi levels or the other.

**Endings first**, since the ending flags change play: `scripts/calibrate-bots.rb endings` plays 10 random generation-0 networks (one hidden layer of 20, every feature group) and `engine/example.ann` against each command, 5 seeds × both colours (110 games), and loads each game ended by two passes into the seeded GNU Go referee (`GameResult::REFEREE`, `final_score`).
A winner change is a game whose Tromp–Taylor winner differs from the referee's:

| Bot command | Games | Ended by passes | Winner changes | Same winner, other margin | Resigned |
| --- | ---: | ---: | ---: | ---: | ---: |
| `gnugo --level 0 --mode gtp` | 110 | 110 | 45 | 65 | 0 |
| `gnugo --level 0 --mode gtp --capture-all-dead` | 110 | 110 | 0 | 0 | 0 |
| `michi gtp --sims 150` | 110 | 109 | 13 | 93 | 1 |
| `michi gtp --sims 150 --play-until-end` | 110 | 110 | 0 | 8 | 0 |
| `michi gtp --sims 1000` | 110 | 110 | 6 | 104 | 0 |
| `michi gtp --sims 1000 --play-until-end` | 110 | 110 | 0 | 19 | 0 |

Every change gave the network a game the referee gives the bot: the bot passed with the network's dead stones still in its area.
No game reached the move limit.
With the flags the games are longer (mean about 62–66 moves without, 117–122 with, at most 147).
Both flags ship.
GNU Go's 0 is partly by construction, since the referee is GNU Go too; the rows with and without a flag use different seeds, so they are not paired game for game.

**The ladder**, with those commands, 100 games a pairing (half with each colour), michi's wins and a 95 % Wilson interval.
First the candidate playouts against the two anchors (`scripts/calibrate-bots.rb ladder --games 100 --bot NAME=COMMAND ... --pairing A,B ...`):

| michi `--sims` | vs AmiGo | vs GnuGo |
| ---: | --- | --- |
| 20 | 44 % (35–54) | |
| 40 | 60 % (50–69) | |
| 80 | 75 % (66–82) | |
| 150 | 91 % (84–95) | |
| 600 | | 21 % (14–30) |
| 1200 | | 31 % (23–41) |
| 2500 | | 38 % (29–48) |
| 5000 | | 55 % (45–64) |

The weak level is the lowest that wins about 70 % against AmiGo (80), the strong the highest that wins about 30 % against GNU Go level 0 (1200), and the middle near the geometric mean of the two (300).
Then the chosen levels against their neighbours (first-named bot's wins):

| Pairing | Wins |
| --- | --- |
| MichiWeak–MichiMid | 11 % (6–19) |
| MichiMid–MichiStrong | 10 % (6–17) |
| MichiMid–AmiGo | 93 % (86–97) |
| MichiMid–GnuGo | 6 % (3–12) |
| AmiGo–GnuGo | 0 % (0–4) |

So the order is Brown < AmiGo < MichiWeak < MichiMid < MichiStrong < GnuGo, each michi level beating the one below about 90 % of the time; MichiMid stays at 300 for these even steps, though against the outside anchors it sits nearer AmiGo.
Nearly every michi loss is a resignation (michi resigns below a 0.2 win rate), and michi–michi games last about 31 moves.
michi used 0.05 s (80 playouts) to 1.05 s (1200) of CPU a game; GNU Go games took about 2 s of wall time at 3 at a time.

## Running experiments

### Creating and running

- On a first run, `mise run run NAME` prompts on STDIN for settings; to start without prompts, create the experiment first with `mise run new-experiment NAME ...`.
  `SetupExperiment::SETTINGS` lists every setting with its default, type and range; `mise run new-experiment` without arguments shows them.
  A value that does not parse strictly is refused, and a prompt asks again.
- The database stores settings as strings; `SetupExperiment.parse` turns them into Integers and Floats on every load, so the runner never converts them itself, and test settings must be typed too.
  Loading a database that lacks a setting fails with "… is missing".
  `SetupExperiment.parse(strings, only: KEYS)` parses only the given ones, for a reader that does not migrate: `scripts/brittleness.rb` reads archived experiments, which lack every setting added since (`Brittleness::Run::SETTINGS`).
- `mise run run NAME [--concurrency N] [--one-generation | --until-generation G]` (`ruby/runner_options.rb`; options before or after the name).
  `--concurrency` (default 2) is the worker pool's size.
  `--one-generation` stops after the first generation that does work.
  `--until-generation G` stops once generation G is finished, its benchmark included; when the database is already past G it runs nothing, not even a checkpoint catch-up (so several experiments can take turns: 100, then 200, and so on).
- The runner works only with the repository root as its working directory: on an experiment's first run `BuildDependencies` runs `make` there, and the executables and `experiments/NAME` are found by relative path.
  An experiment outside the checkout, such as a throwaway run or a comparison against another commit, runs in a worktree (`docs/orchestration.md`, Worktrees).
- A smoke run:
  ```sh
  mise run new-experiment NAME --board-size 9 --population-size 4 --hidden-layers 1 --layer-size 10 \
    --cross-over-rate 0.5 --game-seconds 600 --max-moves 200 --tournament-rounds 1 --keep-every 0 --seed 3
  mise run run NAME --concurrency 4 --one-generation
  ```
  It plays one generation of 20 games (the 4 networks and the 36 bots of the default panel), all in the arena, in about 5 s at concurrency 4.
  With seed 3, 4 games are between a network and a bot and 16 between bots; with most seeds the 4 networks meet only bots.
  `--keep-every 0` skips the benchmark, which would otherwise add 2,800 games at generation 0 at the default `benchmark_games` and `benchmark_bot_games` (100 each): 700 of the network against the seven bots, and 2,100 of the bots against each other.
  Running it again breeds and plays the next generation.
  Delete `experiments/NAME` afterwards; `experiments/` is gitignored.
- A seeded run that exercises the genes quickly:
  ```sh
  mise run new-experiment NAME --board-size 9 --population-size 12 --hidden-layers 1 --layer-size 10 \
    --cross-over-rate 0.5 --game-seconds 600 --max-moves 200 --tournament-rounds 3 --keep-every 2 \
    --benchmark-games 2 --benchmark-bot-games 0 --initial-structure-rate 0.3 --initial-activation-rate 0.2 \
    --max-hidden-layers 3 --max-layer-size 20 --seed 4242
  ```
  Its high starting rates make structural changes common, so shapes vary within a few generations; a 0×0 network is the largest here (79,950 weights, since all 974 inputs connect to the outputs).
  With the defaults (`initial_structure_rate` 0.02, crossover rate 0.5) a generation of 20 sees a structural change only every few generations, so a run meant to explore shapes needs a higher starting rate.

### Settings

- `hidden_layers` and `layer_size` are generation 0's shape.
- `features` (default `all`) is the feature groups every network of the experiment sees: `none` (the stones alone, the control), `all`, or a comma-separated list of `shapes`, `tactics`, `last_move`, `liberties` in any order, each once.
  It is a `SetupExperiment::FeatureSet`, parsed strictly (by `FeatureGroups.normalize` in `ruby/feature_groups.rb`) to the genes line's form, `none` or the groups in their fixed order (`all` becomes `shapes,tactics,last_move,liberties`), which is what the database stores and what the genes lines are checked against.
- `meta_rate` is the τ of self-adaptive mutation.
- The `initial_*` settings are the genes every generation-0 network starts with (ranges = the clamps in `lib/ann.h`).
  `initial_copy_chance` also takes exactly 0, never copy, which every child keeps, and refuses anything between 0 and 0.0001.
  `initial_feature_step` (default 0.01, 1e-4–1) is generation 0's `feature_step`, and `initial_feature_noise` (default 0.3, 0–1), no gene, is the relative noise on generation 0's feature weights.
- `initial_weight_changes`, when not given, is computed at creation from the generation-0 shape and feature set as max(1, 0.0004 × total weights), the feature inputs counted (`FeatureGroups.total_weights`, which `SetupExperiment.total_weights` uses).
  For example, 9×9 1×10 has 1,732 weights with `none` and 10,652 with `all`, so 4.26 changes.
  It is a `SetupExperiment::Derived` default, computed from the settings before it on both the prompt and the `new-experiment` path (so `features` comes before it in `SETTINGS`), and stored, so a later formula change never alters an existing experiment.
  A value above the network's total weights is refused.
- `max_hidden_layers` (default 4) and `max_layer_size` (default 200) bound the shapes structural mutation can reach.
  The generation-0 shape must lie within them (`max_layer_size` is checked against `layer_size` only when `hidden_layers` is above 0), and a shape above them is refused on every path: the prompts ask again, `new-experiment` fails, and loading fails.
- Networks of one experiment differ in shape (structural mutation, `docs/genes.md`); nothing in the runner, the arena, or the benchmark assumes the generation-0 shape except `initial_weight_changes`' check and the check that `initial-population`'s genes lines have that shape.
- `elite_share` (default 0, no elitism; 0–1) is the share of the population carried over unchanged into the next generation ([Breeding](#breeding)).
  The count E is `Elitism.count(elite_share, population_size)` (`ruby/elitism.rb`, the only place it is computed): the share times the population, rounded to the nearest whole number (a half up; rounded, since 0.07 × 100 is 7.000000000000001 in floating point), and at least 1 for any share above 0.
  At least one child must be bred, so E is at most `population_size` − 1, checked on every path as the shape bounds are.
  Experiments created before the setting run on without elitism (migration 018 gives them `elite_share` 0).

### The experiment directory

- An experiment directory holds only `experiment.sqlite3`, the networks directory `networks/`, the scratch directory `work/`, the lock file `experiment.lock`, and the executables (and, while `archive-experiment` runs, its copy `experiment.sqlite3.archive`).
  The database and `networks/` are the experiment's durable state; `work/` is emptied at the start of every generation.
- The runner holds an exclusive `flock` on `experiment.lock` for its whole life (`ExperimentLock`, `ruby/experiment_lock.rb`), taken in `SetupExperiment.call` after creating the directory and before opening the database.
  So a second runner on the same experiment, or one started while an archive runs, exits 1 with a message naming the lock and never opens the database (SQLite's locks cannot tell: the runner holds none between transactions).
  The file stays; the kernel releases the lock when its holder exits, even after `kill -9`, and the programs the runner starts never hold it (close-on-exec).
- Still before migrating, the runner reads the `archived` setting (`ExperimentDatabase.archived_on`, only when the database exists) and refuses an archived experiment.
  That read is read-only; after a runner was killed mid-transaction, a read-only connection cannot roll back its hot journal and refuses to read, so the check then reads read-write, which rolls the journal back, still without migrating.
- The runner works inside `work/` and calls `../evo`, `../arena`, `../evolve`, and `../initial-population`.
  They are **copies** of the build output, made on the experiment's first run once its settings are known, just after that run builds them with `make` (a failed build refuses the run and prints `make`'s output; `mise run run` itself does not build).
  So a resumed run compiles nothing and a rebuild does not change an experiment that has started; to run new code, start a new experiment.
  Once the provenance is recorded, a missing executable stops the run instead of being copied again.
  The `provenance` table records what they were built from: the git revision, whether the checkout had uncommitted changes, and the external tools release.
- The Ruby runner is not copied: it runs from the checkout, so an experiment whose executables take other arguments than the runner passes cannot resume.
- Generation 0 names networks `0001.ann`, `0002.ann`, and so on; later generations use `0.ann`, `1.ann`, and so on.

### Networks on disk

- Networks live in `networks/N/` of the experiment directory (`RunGeneration::NETWORKS`), named as their players: the current generation's and, while the next one is set up, its parents'.
  Players' commands (`../evo ../networks/N/NAME`) and the arena manifest name the files there.
- Setup of generation N writes into `networks/N.partial/` (emptied first): `initial-population` runs inside it as `../../initial-population`, and `evolve` reads `../networks/N−1/P` and writes `../networks/N.partial/I.ann` from `work/` (an elite's file the runner copies there itself).
- Once every child is written and hashed, the runner syncs each file and the directory, renames it to `networks/N/`, syncs `networks/` and the experiment directory, and then saves the setup; only after that commit does it delete `networks/N−1/`.
  The syncs are Ruby's `IO#fsync`, on macOS a plain `fsync(2)`, not `F_FULLFSYNC` (SQLite's default is the same), so the protocol survives a killed or crashed runner but not necessarily a power loss.
- At the start of every setup the runner deletes every `networks/K/` and `networks/K.partial/` but the one that setup needs (`networks/N−1/` while N's setup is unsaved, `networks/N/` once it is saved).
  So a crash at any point leaves either no setup saved and the parents intact (breeding starts over with the same seeds) or the setup saved and `networks/N/` complete.
- A generation whose saved setup a later session resumes checks `networks/N/` against its births (each name present, each file's SHA-256 equal to `births.genome`) before it plays.
  A missing directory or a missing or changed file stops the run with exit 1 and a message naming them (`RunGeneration::NetworksDamaged`): the parents are gone, so it cannot be bred again.
  A generation whose tournament is over plays nothing and skips the check.
- The `networks` table holds only each `keep_every`-th generation's champion (the first network of its final ranking that is not a bot), stored with the last round's state, so a finished checkpoint always has it; export one with `ExperimentDatabase#export_network(generation, name, path)`.

### The tournament round

- `RunGeneration#play_round` scores the bye at once and plays every other game in the arena (`../arena --mixed`), in `min(4 × concurrency, games)` chunks (`RunGeneration::CHUNKS_PER_WORKER`), so a worker whose chunk finishes early takes the next one instead of idling.
  Each network still plays once a round, so the population is still loaded once.
- Each chunk is one streaming `WorkerPool` job (`submit_streaming`) with the files `arena-K.txt` (the manifest: the chunk's networks by their file, its bots by player name, then each game with its ID and the command of each of its bots, a GNU Go or michi command with the game's `--seed`) and `arena-K.err`; the arena's stdout is a pipe the runner reads.
- Games with a bot are dealt out in turn first, then the others, so chunks differ by at most one game and by at most one game with a bot, and the games with a bot land in the first chunks queued, which start first.
  Game IDs do not depend on the chunks, so the chunk count changes no result.
- Every manifest is written before the first chunk starts, and a field the manifest cannot hold (empty, or with a tab or another control character, such as an opponent's command) raises `ArgumentError` before any game.
- Each side gets `game_seconds` seconds of main time (1 to 10⁶, the arena's limit).
  The bot response deadline and `genmove` grace are `RunGeneration::RESPONSE_DEADLINE` and `GENMOVE_GRACE`, 10 s each (why in `engine/arena.c`'s header comment).
  They are constants, not settings: they do not limit thinking, since a `genmove` may use the side's whole remaining main time, but a bot that needs longer than 10 s to answer a setup command, such as one that loads a large model at startup, stops the run as `launch`.
- Each line of a chunk's stdout (UTF-8 whatever the locale; invalid bytes replaced) goes to the chunk's `ArenaResult::MixedStream` as it arrives, and a valid record that is not a failure is scored, stored, and ranked at once, so scoring runs while the arenas play.
  The order records arrive in changes no result: during a round the ranking stays in `ranking_key` order, and the next round's ties are shuffled from a name-sorted list with a seeded generator.
- When a chunk ends, its stored games get their share of its overhead ([Storage](#storage)).
  If the chunk wrote a failure record, is incomplete (no header, a missing, cut-off, or malformed record, or no matching trailer), exited non-zero, or was killed by a signal other than SIGINT or SIGTERM (SIGKILL, SIGSEGV), the runner stops as [Game results](#game-results) says, leaving the chunk's files in `work/`; otherwise the chunk's files are deleted.
- The arena dies of the runner's SIGTERM after killing its bots.
  A SIGKILL of the arena (by hand, or the system out of memory) leaves no time for that: a bot that exits at stdin EOF, as Brown, AmiGo, and GNU Go do, ends by itself, but one that ignores it keeps running and must be killed by hand.

### Storage

- Everything but the networks (`networks/`) and a game's files in progress lives in `experiments/NAME/experiment.sqlite3`, through `ExperimentDatabase` (`ruby/experiment_database.rb`, Sequel on SQLite): the settings, and each generation's round, players (`name`, `command`, `external`, and a bot copy's `opponent`, NULL for a network), standings (`rankings`), and pending games.
- `RunGeneration#data` keeps a generation's state in memory, which must always equal what `ExperimentDatabase#state` would load (string keys, pending games in order; a network's player has no `external` or `opponent` key, not a nil one).
  `save_data` replaces the whole state in one transaction at setup and at each round's pairing.
- A scored game saves only what it changed (`RunGeneration#save_game`, `ExperimentDatabase#raise_in_ranking`), in one transaction with its `games` row (a bye has none): its `pending_games` row goes, and `rankings` stays exact, rank for rank.
- Game rows are keyed by generation, round, and players, so a replayed game replaces its row.
  A row holds:
  - the players, whether each is a bot (`black_external`, `white_external`), the winner, the length, the result (`referee_result`: the Tromp–Taylor count, `B+R`/`W+R` for a resignation, `B+T`/`W+T` for a time loss), and the error message (`move limit exceeded` for a game stopped by the limit, the arena's message for a network it could not load, which names its file);
  - `stderr` and `failure`, always empty (a chunk's stderr is shared by all its games and a stop prints it; a game that failed is never stored);
  - `scorer`, `tromp_taylor` for every game, and `end_reason`, how the game ended: `passes`, `limit`, `resign` (a bot resigned), `time` (a network ran out of main time), or `network_error` (one network could not be loaded and lost); `ExperimentDatabase#record` refuses a row without them or with other values;
  - `duration`, the game's own time in the arena plus an equal share of its chunk's overhead (the chunk's wall time beyond the durations of all its records: starting the arena, loading the networks, and any game left without a record), shared among the chunk's stored games.
    A failed game's own time is subtracted and not shared, since the game is replayed.
    A row gets its own time when its record arrives and its share when the chunk ends (`ExperimentDatabase#add_duration`), so a generation's durations add up to its worker seconds, unless the runner stopped in the middle of a chunk: that chunk's stored rows then lack their share.
    The chunk's time is `WorkerPool`'s, on `AwakeClock`, and the arena's own times also leave out sleep, so a laptop that sleeps during a round adds nothing to any row;
  - `time_black`/`time_white`, each side's summed move times (a bot's `genmove` answers) to a tenth, the time charged against main time;
  - the SGF, only for every `keep_every`-th generation (setting, default 10; 0 keeps none), built from the moves (`ArenaResult#sgf`).
- A benchmark game's `duration` is the seconds of the whole `gogui-twogtp` run on `AwakeClock`, and `time_black`/`time_white` the seconds each player spent answering `genmove` (twogtp's `TIME_B`/`TIME_W`); the rest is the referee, the JVM, process starts, and the other GTP commands, plus a 3 s wait twogtp adds when a player crashed.
- The schema changes only through Sequel migrations in `db/migrations/`; the runner applies pending ones when it opens the store.
  Add a new numbered migration for a schema change; never edit one that has run.
  Sequel keeps the version reached in the one-row table `schema_info` (column `version`), not in `schema_migrations`.

### Breeding

- Breeding runs on the worker pool, `concurrency` children at a time; the runner first draws every child's two parents, in child order, from the generation's own selection generator, so the draws are those of breeding one child after another.
- With `elite_share` above 0, the last E places (I from P−E to P−1 for a population of P) are elites: the first E networks of the previous generation's stored final ranking, bots skipped, in the order `champion` takes (so the champion is one, at place P−E).
  Before the evolves are queued, the runner copies each one's file byte for byte from `networks/N−1/` into `networks/N.partial/I.ann` and makes its birth itself (operator `elite`; `docs/code-reference.md`, births), with no `evolve` run and no pool job.
  An elite whose file is missing from `networks/N−1/` or that has no birth in generation N−1 (only damage by hand leaves either) stops the run with a `BreedingFailed` report before any `evolve` runs, with nothing stored.
- The bred children keep places 0 to P−E−1, with the same seeds and parent draws as without elitism, so they are the children a run without elites breeds at those places.
  Parents are drawn from the whole previous population, elites included, and an elite plays the new generation's tournament as an ordinary network, scored on it alone.
- Each bred child is one pool job, `exec ../evolve ... ../networks/N.partial/I.ann SEED > I.out 2> I.err` in `work/` (`exec`, so `WorkerPool#terminate` reaches `evolve`); the main thread parses, hashes and records each child as it finishes.
- Once the last child is back, the runner stores all the births in one transaction (`ExperimentDatabase#record_births`), as it does for generation 0's; their rows are keyed by generation and child, and the setup is saved only after them, so the order the children finish in does not show: a seeded run gives the same births and networks at any concurrency.
- When an `evolve` fails (a non-zero exit, no child written, or output without a summary, without exactly one genes line, with a malformed one, or with a feature set other than the experiment's), the runner sends SIGTERM to the others still running and exits 1 with a report naming the command, its exit status, and its stderr (`RunGeneration::BreedingFailed`, printed without a backtrace, as is a failed or unusable `initial-population` run).
  No birth is stored and the setup is not saved, so a resume copies the elites and breeds every child again.

### Interrupts and resume

- On resume, `setup_complete` skips creating or breeding the population, the runner starts from the last generation in the database, and a generation's games are skipped only once `round` reaches `tournament_rounds`.
  A checkpoint's benchmark runs after that check too, so a resumed checkpoint finishes its benchmark.
  `RunGeneration#call` returns `:already_done`, which makes a `--one-generation` run go on to the next generation, only when the generation played no tournament game and no benchmark game.
- Ctrl-C stops the runner after the transaction of a scored game commits, so a finished game is kept.
- On Ctrl-C the running games stop (the jobs stay in the runner's process group, so a Ctrl-C in the terminal reaches every one), the pool starts no queued game (`WorkerPool#halt`, called from the trap in `RunExperiment`), and the runner exits without scoring, leaving the unfinished games (those of an arena chunk whose records had not arrived) pending in the database.
  A queued job the halted pool never starts comes back from `next_finished` with the status `WorkerPool::NOT_STARTED`, which `interrupted?` counts as interrupted, so a caller waiting for every job it queued never blocks, also when Ctrl-C came just before it queued them.
- A killed job can come back before the trap has set `$stop_now`, so the runner (tournament and benchmark) also exits without scoring a job whose status `WorkerPool.interrupted?` calls interrupted: killed by SIGINT or SIGTERM, or exiting 130 or 143 (128 plus the signal), as `gogui-twogtp`'s JVM does on Ctrl-C.
  Without the flag set it says on stderr which game or chunk was interrupted and exits 130, so killing one hung game stops the run and leaves the game pending.
  After Ctrl-C with the flag set the runner exits 0, though `mise run run` itself reports 130 because mise gets the SIGINT too.
  A shell running a command that SIGINT killed kills itself with SIGINT, and the arena dies of it, so both show as signaled.
  Any other end of an arena chunk, such as SIGKILL or SIGSEGV, stops the run as [Game results](#game-results) says, after storing its valid records.
- A game that was queued but not yet scored when the runner stopped (after Ctrl-C, or when a chunk stopped the run) is replayed from scratch on resume, in a fresh `work/`.
  After Ctrl-C the games of a running chunk that finished before the signal stay stored (a record read after the trap has set `$stop_now` is dropped, and its game replays), and when one chunk stops the run, the games the other chunks' records gave until then stay stored too.
- Ctrl-C during "Breeding population" kills the running `evolve`s too, the pool starts no queued one, and the runner exits quietly as it does in the tournament (with exit 130 and a message when an evolve's status shows the interrupt before the trap ran).
  The children bred so far are in `networks/N.partial/`, none of their births is stored yet, and the generation's setup is saved only after the last child, so a resume deletes `networks/N.partial/`, copies the elites again, and breeds every child again, with the same seeds and the same parent draws.
- Ctrl-C during generation 0's `initial-population` stops the same way, with nothing stored, so a resume runs it again.
- The benchmark passes `-force` to twogtp, which deletes an existing `PREFIX.dat`, so a replayed benchmark game's `.err` is rewritten too; how the benchmark resumes is under [Benchmark](#benchmark).
- A seeded run gives the same settings, players, births (every column), networks (by SHA-256), rankings, games (every column but `duration`, `time_black`, and `time_white`; SGFs included) and benchmark rows (every column but those three and `stderr`) at any concurrency, and an interrupted and resumed run gives the same as an uninterrupted one.
  Compare those when checking a change that must not alter results.

### Timings

- At the end of every generation the runner prints its timings: a summary of two or three lines, then one machine-readable `timings` line of `key=value` fields to compare runs by.
  Nothing is stored.
- `GenerationTimings`' header comment (`ruby/generation_timings.rb`) lists the fields in order and what each covers.
  Times are on `AwakeClock`, so time the machine spends asleep is not counted, as in the arena.
- The setup parts add up to a little less than `setup`; `setup_hash` and `setup_store` run inside `setup_breed` and must not be added to it.
  A resumed setup has `setup_clear`, `setup_retire`, and, unless its tournament is over, `setup_verify`.
- Per round, `worker` is the summed wall time of its arena chunks (more than the round's time when they run in parallel) and `ruby` the round's time the runner spent not waiting for the pool.
  `failures` is always 0, since a failed game stops the run and the generation prints no timings.
- `partial=1` marks a generation an earlier session began: its times cover only this session, and the summary says so.
- A generation stopped by Ctrl-C or an error prints nothing, and so does one this session had nothing left to do in (as when a `--one-generation` run re-enters the last finished generation), so every timing line is a generation that ran.

### Progress line

- The runner shows each step that can take a while on one progress line (`ProgressLine#show`, `ruby/progress_line.rb`), each status overwriting the one before and padded to the width of the one it replaces, so the terminal never sits on a step that is over.
- Setup, the tournament (`Round R/T: starting K arena chunks ...` until the round's first record arrives, then a line per game), and a checkpoint's benchmark (`Benchmark: starting N games ...`, then a line per game) each end their line with `... done`.
- Each status is printed once, so a log such as `scripts/profile-workload.sh`'s gets one update a step or game, separated by carriage returns.

### Worker pool

- Games run on a `WorkerPool` (`ruby/worker_pool.rb`; its header comment describes plain and streaming jobs): `concurrency` threads, created once per experiment, each running an arena chunk (the tournament) or a `gogui-twogtp` game (the benchmark) in `sh -c`, in the runner's process group, so a Ctrl-C in the terminal reaches every job.
- Jobs are timed on `AwakeClock` (`ruby/awake_clock.rb`): `CLOCK_UPTIME_RAW` where Ruby defines it (macOS, whose `CLOCK_MONOTONIC` counts system sleep), else `CLOCK_MONOTONIC`, so a job's seconds are awake time, as the arena's clock is.
- `WorkerPool#terminate` keeps queued jobs from starting, as `halt` does, and sends SIGTERM to the running ones; a job already reaped is never signalled.
  It is only for jobs that `exec` their program: `RunGeneration#prepare_chunk` prefixes the arena command with `exec`, so the job's pid is the arena, whose own SIGTERM handling stops its bots, while a SIGTERM to the shell running `gogui-twogtp` would leave the JVM running (macOS `sh` does not exec a last command with redirections by itself).

### Archiving

`mise run archive-experiment NAME [--yes]` (`ArchiveExperiment`, `ruby/archive_experiment.rb`) shrinks a finished experiment that will not run again, irreversibly, so it asks first (type `yes`) unless given `--yes`.

- It keeps every table whole except `networks`, and of the networks only the champion of each kept generation that finished its tournament (as `CheckpointBenchmark#top_network` picks it), which is all that table holds anyway ([Networks on disk](#networks-on-disk)); it mainly frees `networks/` and `work/`, which it deletes.
- The copy gets the setting `archived`, after which the runner refuses the experiment.
  `stats` prints what it printed before (it never reads `networks`), but only while the stored schema is one `stats` accepts: the runner never migrates an archived experiment, so one archived before a table `stats` needs is refused by `stats` for good.
- It takes the experiment's lock for its whole run and refuses while a runner or another archive holds it.
- It never opens the original read-write or through `ExperimentDatabase.new`, which migrates.
  It builds the copy in `experiment.sqlite3.archive` from the original attached read-only, table by table with `networks` filtered (`VACUUM INTO` cannot filter), checks it (`PRAGMA integrity_check`, the schema, the row counts, the settings, each kept network byte for byte, and each kept network playing itself in the experiment's own `arena`), syncs it, renames it over the original, and syncs the directory.
- A failed check, a refusal, a declined prompt, or an archive stopped at any point before the rename leaves the original as it was; the next archive deletes a copy an interrupted one left.
  Archiving an archived experiment only deletes a `work/` or `networks/` left by an archive stopped after its rename.
- A hot journal next to the original (left by a writer killed mid-transaction) makes the read-only attach fail; the archive then refuses and says to open the database read-write once while no runner is active, for example `sqlite3 experiments/NAME/experiment.sqlite3 'pragma schema_version'`, which rolls it back.
  A cold journal (a zeroed header, which SQLite ignores) it deletes.
- A `stats` still reading the old file holds its space until it exits.

### stats

- `stats` only reads: it opens the experiment database read-only, so it can run beside the runner.
- `stats NAME` prints the tables once and exits; `--csv` prints one row per generation.
  `--watch` redraws until Ctrl-C, every 5 s, only the Breeding and bots and Networks against bots tables of the latest 10 generations (`Report::GENOME_ROWS`) and the Benchmark ratings, and computes only what they need (`ExperimentStats#brief_generation`); `--watch --extended` redraws every table, every 30 s.
  Both cache a finished generation's figures (`Report.figures`), but the first draw, like the once mode, computes every generation it shows, which takes seconds for a few hundred generations.
  `--extended` without `--watch`, and `--csv` with `--watch`, print the usage and exit 1.
- It needs the `board_size` and `features` settings for the total weights (`FeatureGroups.total_weights`); without either it prints `features is missing` (or `board_size is missing`) and exits 1, rather than show wrong weights.
- It never migrates, so it refuses, in every mode and with exit 1, a database without the `benchmark_bot_games` table (migration 016), saying to run the experiment once to migrate it (`ExperimentStats::Unmigrated`).
  It looks for the table through `sqlite_master`, as `ExperimentDatabase.archived_on` looks for `settings`, since `table_exists?` takes a hot journal for a missing table.
- Tables: Generations (the latest 50); for the latest 10 generations Genes, Feature weights (none for a feature set without move features, `none` or `liberties` alone), Shapes and activations, Breeding and bots, and Networks against bots (per bot group, by `players.opponent`, the networks' wins against a copy); then Benchmark ratings, over all checkpoints whatever generations are shown.
  `ruby/stats_report.rb` has their columns; [The evolving genome](genes.md) explains the genome tables.
- Children per parent count selection: a crossover counts for both parents, a mutation or copy for the picked parent, out of the previous generation's ranked networks.
  The Parents column (`population.distinct_parents`) instead counts whose weights survive.
- Bot ranks go by score (1 + players with more points), so tied players share a rank whatever order the ranking broke the tie in.
  A bot group is a stored opponent (`opponents` table); its copies are named with a copy number (`Brown1`).
- Elites are told by their births' operator `elite` alone; `stats` never reads `elite_share`, so it works the same on experiments created before it.
  Figures about breeding and selection leave elites out, so they stay comparable with runs without elitism: Copies (`population.identical`, over the bred children), the structural changes (`structure.*`, so `structure.none` does not grow by E), and children per parent (`parents.*`: selection did not pick an elite).
  Figures about the generation's networks count them: Parents (an elite's weights are its parent's), Genomes, the scores, and the genes, shapes, and activations tables.
  `population.operators.elite` counts them (0 without elitism).
- Benchmark ratings (`BenchmarkRatings`, `ruby/benchmark_ratings.rb`, fitted in `ExperimentStats#benchmark_ratings`; its header comment has the model): one row per player, strongest first, with Rank, Player, Rating, ±, Games, and Score.
  - Its games are every `benchmark_games` row without a failure, the benchmarked network named by `CheckpointBenchmark.champion_name(generation)` (the name later checkpoints play it under as `GenGChampion`, so the name pools them), and every `benchmark_bot_games` row without a failure.
  - The anchor, rated 0, is the panel bot AmiGo, else the panel's first bot, else Gen0Champion (`BenchmarkRatings.anchor`).
  - The model is Bradley–Terry with a prior of one win and one loss per player against a virtual player at 0, so a player nobody has beaten, or who never won, is held finite only by that prior.
  - Rating is Elo above the anchor.
    ± is 1.96 / sqrt of the player's Hessian diagonal, about 95 % with the other ratings held fixed, so narrower than the uncertainty against the anchor (on a synthetic set of 500 champions the full interval against the anchor was 1.1–1.8 times wider, median about 1.3).
  - The latest champion with a scored game is bold on a terminal.
  - The fit is kept until `ExperimentDatabase#benchmark_game_counts` changes, so `--watch` refits only after a game is stored.
    A fit that raises `BenchmarkRatings::NotConverged` is kept the same way and shown as `Benchmark ratings: the fit did not converge (MESSAGE)` in place of the table, so `--watch` keeps redrawing.
- On a terminal, the rows of a generation that is not done (`finished`) are grey and italic in Generations, Breeding and bots, and Networks against bots, whose figures change while it plays; piped output has no escape codes.
- The CSV header is fixed per experiment (`Report::CSV_COLUMNS`, then per stored bot group, then per panel opponent, colour, and outcome), except that past champions add columns as checkpoints play them, every `GenNChampion` a stored checkpoint plays, oldest first (`ExperimentStats#benchmark_opponents`).
  Experiments with the same opponents and panel compare column by column up to their shared checkpoints; cells a generation lacks (structure and parents in generation 0, a group with no ranked copy) are empty.
- `ExperimentStats` computes the figures (a Hash per generation) and `ExperimentStats::Report` formats them; neither prints on its own.
- A checkpoint counts as finished only once its benchmark is complete: stored rows equal `benchmark_games` times the opponents from `CheckpointBenchmark.opponents_for`, the same rule the runner plays by, so change it there only.
  The bot-vs-bot games ([Benchmark](#benchmark)) do not count, so a checkpoint whose bot games are still pending counts as finished.

### External tools

- GNU Go 3.8 needs two patches.
  Without `scripts/patches/gnugo-3.8-gg-sort-empty.patch`, clang builds abort in `final_score` and during level 10 move generation; GCC builds happen to work either way.
  `scripts/patches/gnugo-3.8-superstring-libs.patch` stops `superstring_add_string` from writing liberties past its caller's array: without it, a macOS build aborted in `genmove` (`__stack_chk_fail` in `superstring_moves`) in a position from a tournament game of `even-bigger2`, generation 64, which `scripts/smoke-bot-patches.sh` replays at level 10, the level an unpinned `--level 0` reaches under `time_settings`.
- When changing how external tools are built, bump `release_id` in `scripts/install-external-tools.sh` so existing installs rebuild, then run `mise run verify`.
- The installer downloads only from the GitHub release named in `mirror_url` in `scripts/install-external-tools.sh`, never from upstream.
  `scripts/external-tools.txt` lists each archive's SHA-256 and upstream URL.
- To change an archive, edit the manifest, give `mirror_url` a new release tag (a published release's files should not change under the same tag), bump `release_id`, and run `mise run mirror-external-tools`.
  Adding an archive may keep the release tag, since no published file changes; only changing an archive needs a new tag.
- michi-c2's upstream URL is a GitHub `archive/COMMIT.tar.gz`, which GitHub builds on request and whose bytes have changed before, so a re-mirror without the local cache (`.local/evo-tools/cache`) can fail the SHA-256 check; the file on the release is the reference copy.
- `mise run mirror-external-tools` fetches from upstream and uploads to the release; since the upload is seen outside the repository, it needs the owner's approval first (`docs/orchestration.md`, When to ask the owner).

## Benchmark

- `CheckpointBenchmark` (`ruby/checkpoint_benchmark.rb`) measures progress apart from the tournament.
  Its games use `gogui-twogtp`, one game per run (the command from `CheckpointBenchmark.game_command`, which `scripts/brittleness.rb` uses too), with the GNU Go referee (`GameResult::REFEREE`), and are read from its `.dat` file by `GameResult`.
  `RunGeneration#call` runs it after the tournament of every `keep_every`-th generation (the checkpoints, whose champions are kept); with `keep_every` 0 it never runs.
- It plays the top network of the generation's final ranking (the first entry that is not a bot) against the stored panel `benchmark_opponents`, in order.
  `kind` is `bot` (run by `command`), `initial_champion` (generation 0's top network), or `past_champions`: the top networks of the last `benchmark_champions` checkpoints before this one (setting, default 10), oldest first, each a separate opponent named `GenNChampion` for the checkpoint N, so older ones drop out as the run goes on.
  Generation 0 plays the bots only, and `past_champions` never holds generation 0, which `initial_champion` always covers.
  `CheckpointBenchmark.opponents_for` expands the panel.
- With elitism (`elite_share` above 0) an elite can stay first across checkpoints, so a checkpoint's champion can be byte for byte a stored `GenNChampion` or `Gen0Champion`, and the benchmark then plays that network against itself.
  `scripts/compare-runs.rb` flags such pairs by `births.genome` ([Comparing runs' champions](analysis-scripts.md#comparing-runs-champions)).
- Each opponent gets `benchmark_games` games (setting, even, default 100), half with each colour: opening `k` is played once with each.
  The openings (`Openings.moves`) have `benchmark_opening_moves` stones (setting, default 4), drawn from the experiment seed and `k`, never orthogonally adjacent, so they are the same at every checkpoint and checkpoints compare.
  They go to twogtp as `-openings work/benchmark/openings/k/`, all written before the first game is queued.
  With `benchmark_opening_moves` 0 there is no `-openings`, and the games against deterministic opponents (Brown, AmiGo, networks) repeat.
- twogtp counts opening stones as moves, so the runner passes `-maxmoves` as `max_moves` plus the opening's stones, and the stored `length` includes them.
- Each player gets `game_seconds` of main time as `-time Ns` (GoGui 1.6.0 reads a bare `-time N` as minutes and takes only whole numbers); without `-time`, GNU Go plays a different, faster game.
- Scoring, from the benchmarked network's side (`CheckpointBenchmark.score`, on `GameResult`): the referee decides, a crashed network (benchmarked or opponent) loses, and a draw has no winner.
  A crashed bot, a missing referee score, another GoGui error, or a missing `.dat` is a failure with no winner, stored with its reason; a failure does not stop the run.
- Results go to `benchmark_games`, one row per game keyed by generation, opponent, opening, and `network_color` (the benchmarked network's).
  `winner` is `network`, `opponent`, or nil; `network` is the benchmarked network's name and `opponent_network` the opposing one as `generation:name`.
  The other columns are those of `games` without `scorer` and `end_reason`; no SGF is kept.
- The panel's bots also play each other, once per experiment rather than at every checkpoint, since their games do not change as the networks evolve.
  Every pair of `bot` rows in panel order (a before b) plays `benchmark_bot_games` games (setting, even, default 100, 0 for none): for each opening `k` in `0...benchmark_bot_games/2`, one game with a as Black and one with b as Black.
  With the seven default bots that is 21 pairs, 2,100 games.
  - Each checkpoint, generation 0 included, plays the bot games not yet stored in the same pool as its own games, so they are all played at the first checkpoint (a resume re-enters it and finishes them).
    Any still missing later (the setting was raised, or the experiment predates the bot games) are played on the next start by the first checkpoint the runner enters: the earliest one through the catch-up below, or the generation it resumes with when there is no earlier checkpoint.
  - A bot game's seed is `Seeds.gnugo(seed, 'benchmark-bots', BLACK, WHITE, k)`, without the generation, so the game is the same whichever checkpoint plays it; both bots and the referee get it.
  - The referee decides; a crash of either bot, like any other game without a usable result, is a failure with no winner, and a draw has no winner.
  - Results go to `benchmark_bot_games`, one row per game keyed by `black`, `white` (panel names), and `opening`: `winner` is `black`, `white`, or nil, and `generation` is only the checkpoint that played it.
    They do not count toward a checkpoint's being done ([stats](#stats)).
- On every start, before it resumes, `RunExperiment#catch_up_benchmarks` has each checkpoint before the generation it resumes with play the benchmark games it lacks, oldest first, in an emptied `work/`, each under a heading `*** BENCHMARK OF GENERATION N ***` printed only when it has a game to play.
  That is what fills in earlier checkpoints after `benchmark_games` or `benchmark_bot_games` was raised: the champions are in the database (`networks`), and the new openings are those with the next indexes, from the seed as always, so a topped-up checkpoint plays exactly the games a new one would.
  A checkpoint with nothing missing costs three small reads (`CheckpointBenchmark#complete?`).
  The generation it resumes with finishes its own benchmark in `RunGeneration`.
- On resume the benchmark plays only the games with no row.
  A row is stored before the game's files are deleted, so a crash between the two does not replay the game.
  Ctrl-C exits before scoring, as in the tournament, also when the interrupted game is back before the trap has run.
- Its files live in `work/benchmark/`: the exported networks as `GENERATION-NAME`, each game as `OPPONENT-OPENING-COLOR` (`.dat`, `-0.sgf`, `.err`), each bot game as `BLACK-WHITE-OPENING` (ending in a number, so never a network game's name), and the openings.
