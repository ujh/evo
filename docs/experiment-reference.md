# Experiment reference

How tournament and benchmark games are played and scored, how the runner, its storage, `stats` and the benchmark work.
What each analysis script prints and how to read it is in [Analysis scripts](analysis-scripts.md).
Read the relevant section when changing experiments or reading their results.
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
- [How noisy the tournament's ranking is](#how-noisy-the-tournaments-ranking-is)
  - [10, 20 and 40 rounds](#10-20-and-40-rounds)
- [How often tournament games repeat](#how-often-tournament-games-repeat)
  - [Self-adaptive and fixed genes](#self-adaptive-and-fixed-genes)
- [Fixed mutation genes (`meta_rate` 0)](#fixed-mutation-genes-meta_rate-0)
- [How brittle a champion is](#how-brittle-a-champion-is)
  - [Results: `seed2-rounds20` and `seed2-meta0` at generations 300 and 500](#results-seed2-rounds20-and-seed2-meta0-at-generations-300-and-500)
- [Elitism (`elite_share`)](#elitism-elite_share)
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

## How noisy the tournament's ranking is

On `even-bigger2` (1,000 networks, 33 bot copies, 10 Swiss rounds, 5,160 games a generation; 30 Sep 2026):

    mise exec -- scripts/ranking-noise.rb experiments/even-bigger2/experiment.sqlite3 1 5 20 50 100 150 200 235

| Generation | Games | Networks | White wins | Colour r² | Odd/even Spearman | Reliability, 10 rounds | Reliability, 20 rounds | Reliability, 40 rounds | Wins vs rating | Top 50 in common |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 5160 | 1000 | 61 % | 0.01 | 0.40 | 0.57 | 0.73 | 0.84 | 0.95 | 29 |
| 5 | 5160 | 1000 | 58 % | 0.02 | 0.35 | 0.52 | 0.69 | 0.81 | 0.94 | 31 |
| 20 | 5160 | 1000 | 63 % | 0.06 | 0.35 | 0.52 | 0.68 | 0.81 | 0.94 | 35 |
| 50 | 5160 | 1000 | 62 % | 0.07 | 0.38 | 0.55 | 0.71 | 0.83 | 0.94 | 33 |
| 100 | 5160 | 1000 | 62 % | 0.06 | 0.37 | 0.54 | 0.70 | 0.83 | 0.94 | 34 |
| 150 | 5160 | 1000 | 62 % | 0.05 | 0.35 | 0.51 | 0.68 | 0.81 | 0.94 | 31 |
| 200 | 5160 | 1000 | 59 % | 0.01 | 0.34 | 0.51 | 0.67 | 0.80 | 0.94 | 32 |
| 235 | 5160 | 1000 | 56 % | 0.01 | 0.32 | 0.49 | 0.65 | 0.79 | 0.94 | 31 |

- **Odd/even Spearman:** the benchmark's rating fit (`BenchmarkRatings`) on rounds 1, 3, …, 9 and on rounds 2, 4, …, 10 ranks the networks alike only weakly. By Spearman–Brown, a rating from all 10 rounds is about half skill (reliability 0.49–0.57); 20 rounds would make it about two thirds, 40 about four fifths. The projection assumes added rounds are like the ones played; under the Swiss pairing, later rounds pair closer scores.
- These are the rating fit's reliabilities. The win count's, which parent selection uses, cannot be measured by splitting: a network that won in one half meets harder opponents in the other, so the halves' win counts correlate slightly negatively (Pearson −0.10 to 0.01 here, first against second half or odd against even rounds) whatever the skill. If the fit is the better estimate of skill, the win count's reliability is about 0.94² of the fit's, so about 0.46 at 10 rounds (0.94² × 0.52).
- **Wins vs rating:** the win count orders the networks much as the rating fit of the same games does (Spearman 0.94–0.95), but ties are many (at generation 235, 116 networks share 7 wins, the score at which the top 50 is cut), and selection breaks them at random. Of the stored ranking's top 50, only 29–35 are in the fit's top 50.
- **Colour:** White wins 56–63 % of tournament games, but each network's colours even out enough over 10 games that its number of games as White explains 1–7 % of the spread in win counts.
- The spread of win counts (standard deviation 1.49 at generation 235) is close to that of 10 coin flips (1.58): the Swiss pairing keeps every network near 50 %, so the spread itself says little about skill.
- What this means for selection is a prediction, not a measurement. Under the breeder's equation the gain per generation grows with the square root of the reliability of what selection ranks by. With the win count's reliability taken as 0.94² of the fit's at any length, 20 rounds would select about 14–15 % better per generation than 10 (√0.65 against √0.49 at generation 235, √0.68 against √0.52 at generation 20) at twice the tournament's cost, so less per unit of compute. The rating fit instead of the win count would select about 6 % better (1/0.94, from the same assumption) at no cost in games. The runs of 10, 20 and 40 rounds follow.

### 10, 20 and 40 rounds

`tournament_rounds` defaults to 20 since 9 Oct 2026, from the two seeds below: 20 rounds beat 10 at equal compute with both, and 40 beat neither 10 nor 20.

#### First seed: 10 against 20

`rounds20` repeats `even-bigger2` with `tournament_rounds` 20 and every other setting the same, the seed included, so both start from the same generation 0. Its tournament games add up to about 19 h per 100 generations, against about 10.4 h for `even-bigger2` (summed `games.duration`, so worker time, not wall time; breeding and the benchmark cost the same per generation in both, so the wall-time ratio is a little under 2). Equal compute therefore pairs `rounds20`'s generation N with `even-bigger2`'s 2N. The checkpoint champions' benchmark wins out of 100 (2 Oct 2026, `rounds20` at generation 303, `even-bigger2` at 518):

| Summed tournament hours | Champion | AmiGo | MichiWeak | MichiMid |
| --- | --- | ---: | ---: | ---: |
| 0 | `even-bigger2` generation 0 | 0 | 2 | 1 |
| 0 | `rounds20` generation 0 | 1 | 5 | 0 |
| 20 | `even-bigger2` generation 200 | 39 | 30 | 6 |
| 20 | `rounds20` generation 100 | 57 | 46 | 18 |
| 41 | `even-bigger2` generation 400 | 34 | 30 | 5 |
| 39 | `rounds20` generation 200 | 57 | 45 | 18 |
| 52 | `even-bigger2` generation 500 | 39 | 27 | 7 |
| 58 | `rounds20` generation 300 | 56 | 53 | 19 |

- Brown (81–100 wins), MichiStrong and GNU Go level 0 (0–3 wins) separate neither run.
- At equal compute the 20-round champions win more against all three bots at every checkpoint; 57 against 39 wins of 100 against AmiGo is about z = 2.5 on its own. `stats` puts `rounds20`'s champions at 55–92 Elo above AmiGo and `even-bigger2`'s at 52–89 below.
- Already generation 0's champion, picked from the same population, is better with 20 rounds (Brown 95 against 81), as the reliabilities above predict.
- Both runs stop improving after generation 100: `even-bigger2`'s champions win 34–39 against AmiGo from then on, `rounds20`'s 56–57. The whole gap opened in the first 100 generations, which one lucky early lineage could also explain, so a second seed (`seed2-rounds10`, `seed2-rounds20`, and `seed2-rounds40` with 40 rounds, seed 2246017379882995802) has to repeat it before 20 rounds becomes the default.

#### Second seed: 10, 20 and 40

`seed2-rounds10`, `seed2-rounds20` and `seed2-rounds40` (seed 2246017379882995802, `even-bigger2`'s settings otherwise, so all three start from the same generation 0) ran to generation 500. Their tournament games add up to about 10.5, 18 and 38 h per 100 generations. The checkpoint champions' benchmark wins out of 100, and their rating in Elo above AmiGo from each experiment's own `stats` fit (9 Oct 2026):

| Summed tournament hours | Champion | AmiGo | MichiWeak | MichiMid | All three, of 300 | Rating |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 0 | generation 0 (10, 20, 40 rounds) | 2, 5, 3 | 4, 1, 4 | 0, 0, 0 | 6, 6, 7 | −616, −506, −607 |
| 10 | 10 rounds, generation 100 | 33 | 22 | 2 | 57 | −94 |
| 18 | 20 rounds, generation 100 | 18 | 28 | 5 | 51 | −227 |
| 21 | 10 rounds, generation 200 | 36 | 29 | 3 | 68 | −88 |
| 31 | 10 rounds, generation 300 | 21 | 20 | 1 | 42 | −102 |
| 36 | 20 rounds, generation 200 | 43 | 45 | 13 | 101 | 14 |
| 38 | 40 rounds, generation 100 | 31 | 35 | 9 | 75 | −107 |
| 42 | 10 rounds, generation 400 | 39 | 20 | 8 | 67 | −68 |
| 52 | 10 rounds, generation 500 | 48 | 32 | 3 | 83 | −50 |
| 55 | 20 rounds, generation 300 | 54 | 39 | 9 | 102 | 16 |
| 72 | 20 rounds, generation 400 | 52 | 45 | 12 | 109 | 45 |
| 76 | 40 rounds, generation 200 | 34 | 36 | 8 | 78 | −36 |
| 90 | 20 rounds, generation 500 | 48 | 50 | 16 | 114 | 69 |
| 114 | 40 rounds, generation 300 | 37 | 40 | 9 | 86 | −54 |
| 152 | 40 rounds, generation 400 | 37 | 37 | 8 | 82 | −32 |
| 189 | 40 rounds, generation 500 | 38 | 47 | 9 | 94 | −48 |

- Brown (91–100 wins after generation 0), MichiStrong and GNU Go level 0 (0–4 wins) separate none of the runs.
- From about 36 summed hours on, the 20-round run leads at every equal-compute point: 101 against 67 of 300 for 10 rounds at 36–42 h (about z = 3), 102 against 83 at 52–55 h. Unlike the first seed, 10 rounds led at about 20 h and the gap opened in the 20-round run's generations 100–300, so the effect does not hang on one early lineage.
- 40 rounds is beaten at equal compute and, from generation 200 on, even at equal generations (78 against 101 of 300 at generation 200, 94 against 114 at 500). It leads only at generation 100 (75 against 51), at twice the cost.
- The round count also decides how reliably the champion is picked, and the benchmark plays only the champion: the 10-round run's dip at generation 300 (42 of 300) fits a poor pick better than a worse population.
- Only the 40-round run is clearly flat after generation 200 (ratings −36 to −54). The 20-round champions' rating still rises at generation 500 (14, 16, 45, 69 at generations 200–500), and the 10-round run's from generation 300 (−102 to −50). Meanwhile the mutation genes shrink: `weight_step`'s median fell from 0.5 to 0.018 with 10 rounds, 0.006 with 20, and 0.0004 with 40 (at generation 500), the less noisy the tournament the further. `PROJECT_NOTES.md` has the open question.

## How often tournament games repeat

### Self-adaptive and fixed genes

The script at generations 100–500 of the five second-seed runs (14 Oct 2026, at f2e6717): `seed2-rounds10`, `seed2-rounds20` and `seed2-rounds40` with self-adaptive genes and 10, 20 and 40 rounds, and `seed2-meta0` and `seed2-meta0-step015` with fixed genes ("Fixed mutation genes" below) and 20 rounds. Clone repeats + rematches, as shares of the row's games:

    mise exec -- scripts/game-repeats.rb experiments/NAME/experiment.sqlite3 100 200 300 400 500

Network against network (4,853–4,858 games a checkpoint with 10 rounds, 9,720–9,767 with 20, 19,523–19,577 with 40):

| Generation | `seed2-rounds10` | `seed2-rounds20` | `seed2-rounds40` | `seed2-meta0` | `seed2-meta0-step015` |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | 0.7 % + 0.1 % | 0.3 % + 0.8 % | 1.9 % + 1.5 % | 0.0 % + 0.7 % | 0.0 % + 0.5 % |
| 200 | 0.3 % + 0.1 % | 0.0 % + 0.7 % | 7.0 % + 1.5 % | 0.0 % + 0.6 % | 0.0 % + 0.7 % |
| 300 | 0.6 % + 0.1 % | 2.7 % + 0.7 % | 19.8 % + 1.8 % | 0.0 % + 0.7 % | 0.0 % + 0.6 % |
| 400 | 2.5 % + 0.1 % | 11.6 % + 0.6 % | 22.4 % + 1.5 % | 1.8 % + 0.6 % | 0.0 % + 0.6 % |
| 500 | 0.9 % + 0.2 % | 16.7 % + 0.6 % | 35.8 % + 1.5 % | 0.3 % + 0.6 % | 0.0 % + 0.6 % |

Against AmiGo (93–98 games a checkpoint with 10 rounds, 177–198 with 20, 354–391 with 40):

| Generation | `seed2-rounds10` | `seed2-rounds20` | `seed2-rounds40` | `seed2-meta0` | `seed2-meta0-step015` |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | 0.0 % + 1.1 % | 0.0 % + 10.7 % | 4.9 % + 10.8 % | 0.0 % + 11.2 % | 0.0 % + 6.4 % |
| 200 | 0.0 % + 4.1 % | 0.5 % + 5.2 % | 10.5 % + 9.7 % | 0.0 % + 7.5 % | 0.0 % + 9.7 % |
| 300 | 1.1 % + 2.1 % | 6.6 % + 5.6 % | 20.3 % + 11.2 % | 0.0 % + 3.6 % | 0.0 % + 4.7 % |
| 400 | 5.3 % + 2.1 % | 11.6 % + 5.6 % | 25.0 % + 13.8 % | 8.2 % + 4.6 % | 0.0 % + 10.4 % |
| 500 | 3.1 % + 0.0 % | 19.7 % + 5.1 % | 35.0 % + 21.2 % | 1.6 % + 6.2 % | 0.0 % + 3.6 % |

- **At 20 rounds, the fixed-gene runs' play stayed more varied from generation 300 on (one seed).** `seed2-meta0-step015` has at most 3 clone repeats among its network games at any checkpoint and none against AmiGo; `seed2-meta0` 0 or 1 up to generation 300, then 174 (1.8 %) at 400 and 32 (0.3 %) at 500, and against AmiGo 16 (8.2 %) at 400 and 3 (1.6 %) at 500. `seed2-rounds20`, the same 20 rounds with self-adaptive genes, has 258 (2.7 %), 1,126 (11.6 %) and 1,630 (16.7 %) at generations 300–500.
- **At 20 and 40 rounds, the self-adaptive runs bred behavioural clones (one seed; only at 20 rounds is there a fixed-gene run to compare).** With 10, 20 and 40 rounds, 0.9 %, 16.7 % and 35.8 % of the network games at generation 500 are clone repeats. These runs are not directly comparable: the share can grow with the number of rounds counted, since two clones repeat a game only when they meet the same opponent with the same colour, so part of the gradient may be the measure itself. Different networks also repeat each other's games against AmiGo (19.7 % and 35.0 % at generation 500 with 20 and 40 rounds).
- Interpretation, at most: the rest of the gradient may come from the mutation genes shrinking further the more rounds there are ("10, 20 and 40 rounds" above). The repeats against AmiGo suggest that a lineage keeps winning or losing with one line per colour, which the benchmark's openings do not reward.
- **Rematches follow the rounds, not the genes (one seed):** 0.1–0.2 % of the network games with 10 rounds, 0.5–0.8 % in all three 20-round runs, 1.5–1.8 % with 40.
- The other rows: michi's are 0 everywhere, GNU Go's at most 1 game a checkpoint. Against Brown, clone repeats are at most 8 games a checkpoint (none with fixed genes), and rematches are most of its repeats summed over the checkpoints (up to 52.9 %, `seed2-rounds40` at generation 200). Bot against bot has no clone repeats; its rematches reach 19.7 % (`seed2-rounds40` at generation 300) and 19.4 % (`seed2-rounds20` at generation 400).
- Interpretation: of the three 20-round runs, the most clone-heavy, `seed2-rounds20`, is also the strongest from generation 300 on ("Fixed mutation genes" below), so its clones did not stop it leading, and the more varied fixed-gene runs were not stronger. Whether more variety would help a self-adaptive run is untested for random openings in the tournament, and the first elitism runs cannot tell ("Elitism (`elite_share`)" below); `PROJECT_NOTES.md` (item 7) has the proposals.

## Fixed mutation genes (`meta_rate` 0)

`seed2-meta0` and `seed2-meta0-step015` repeat `seed2-rounds20` with `meta_rate` 0, so every network keeps generation 0's mutation genes, and every other setting the same, the seed included, so all three start from the same generation 0 (the same champion, 6 of 300). `seed2-meta0` keeps the default genes (`weight_step` 0.5, 229 weight changes, `copy_chance` 0.01, `activation_rate` and `structure_rate` 0.02); `seed2-meta0-step015` the same with `initial_weight_step` 0.15. They test whether the self-adaptive genes' shrinking limits progress (`docs/literature.md` sections 1 and 7). Both ran to about generation 570, at nearly the same cost per generation as `seed2-rounds20` (summed tournament hours to generation 500: 94 and 106 against 90), so equal generations are close to equal compute. The checkpoint champions' benchmark wins out of 300 against AmiGo, MichiWeak and MichiMid, and their rating in Elo above AmiGo from each experiment's own `stats` fit (14 Oct 2026):

| Generation | `seed2-rounds20` | `seed2-meta0` | `seed2-meta0-step015` | Ratings, same order |
| ---: | ---: | ---: | ---: | --- |
| 100 | 51 | 73 | 56 | −227, −106, −117 |
| 200 | 101 | 102 | 61 | 14, −24, −80 |
| 300 | 102 | 93 | 58 | 16, −27, −127 |
| 400 | 109 | 81 | 83 | 45, −14, −52 |
| 500 | 114 | 77 | 80 | 69, −59, −60 |

This section's figures, except the brittleness test's, predate the rule that analysis figures come from a reviewed script (`CLAUDE.md`): they came from one-off queries, re-checked by four review rounds in #119, which the owner shipped as is (14 Oct 2026). A later change to them goes through a script.

- The fixed step 0.5 learns faster at first, then falls behind and declines. `seed2-meta0` leads at generation 100 (73 against 51 wins, about z = 2), is level at generation 200 (102 against 101), and then falls behind while the self-adaptive run keeps rising: 93 against 102 wins at generation 300 and 77 against 114 at 500 (about z = 3.2). `seed2-meta0-step015` is never clearly ahead (56 against 51 at generation 100) and is behind from generation 200 on.
- The populations agree, so this is not only the champion pick. Averaged over 50 generations, the share of networks scoring above the AmiGo copies' mean tournament score is, for `seed2-rounds20`, `seed2-meta0` and `seed2-meta0-step015`: 11, 6 and 5 % at generations 151–200, 32, 15 and 5 % at 251–300, 41, 22 and 6 % at 351–400, and 40, 23 and 9 % at 451–500. `seed2-meta0`'s share peaks at 27 % (generations 401–450) and then falls: per 25 generations 29.8 % at 401–425, 15.4 % at 526–550 and 8.4 % at 551–575.
- Up to generation 500 the smaller fixed step is worse: the step-0.15 population trails the step-0.5 one at every window above, although their champions match at generations 400–500. After that the step-0.15 population keeps rising slowly (per 25 generations 7.0 % at 401–425, 11.0 % at 526–550, 9.5 % at 551–570) while the step-0.5 one declines, and from generation 526 on they are level. A rise and fall like step 0.5's is what `docs/literature.md` (section 7, the `meta_rate` 0 control) expects when a step is too big for selection without elitism. So "self-adaptation hurts" does not hold for this seed, and "0.5 is too big a step" is open: it may be too big without elitism. The brittleness test ("How brittle a champion is", below) narrows it: children of `seed2-meta0`'s champions of generations 300 and 500 at step 0.5 showed no detectable average loss (losses of a few points are not excluded), and the generation-500 champion is far less sensitive to mutation than the generation-300 one (32 % against 2 % of its children's games at step 0.5 identical to its own, 72 % against 8 % at step 0.1).
- Interpretation: step-0.5 mutations do not wreck these champions; whether per-mutation losses too small for this test drive the decline is not measured.
- The share of mutation children that score at least as well as their parent cannot tell whether a step is too big. It is 30.5–31.6 % per 100 generations in all three runs, about the same as for exact copies (30–38 % in every 100 generations with a few hundred copies), whose play is unchanged: it measures how far a parent's lucky score regresses, not the mutation. Measured against its parent's score in the generation before, a mutation child scores on average 0.18, 0.28 and 0.09 wins (of 20 games) less than a copy over generations 1–500 in `seed2-rounds20`, `seed2-meta0` and `seed2-meta0-step015`, and in some 100 generations no less. Strictly better than their parent are 18–21 % of copies and 18–19 % of mutation children in each run.
- The self-adaptive run did not stop exploring; it moved from weights to shapes. In `seed2-rounds20`, over generations 401–500, the per-generation mean `weight_step` was 0.0035–0.019 and `weight_changes` 14–55, while `structure_rate`, which had fallen from 0.02 to about 0.01 or less by generations 200–250, rose from about generation 255 to about 0.06 at 300 and then ran at per-generation means of 0.04–0.13 (10-generation means 0.05–0.12, highest at 441–500): 2,096 shape changes in generations 201–300, then 6,483 and 8,717 in generations 301–400 and 401–500, against 1,340–1,750 per 100 generations in the fixed runs, and 123–141 distinct shapes among the children per 100 generations against 20–50. At generation 500 its networks have 5–18 hidden layers, 437 of 1,000 at 7–9 and 467 at 12–16, about 198 wide; the fixed runs' networks mostly have 10 (`seed2-meta0`, 966) or 9 (`seed2-meta0-step015`, 868) layers of about 200–204. Whether the shapes are what kept it improving is not measured.
- One seed only. `PROJECT_NOTES.md` (item 3) has what remains open.

## How brittle a champion is

### Results: `seed2-rounds20` and `seed2-meta0` at generations 300 and 500

The owner ran `seed2-rounds20 300 500` and `seed2-meta0 300 500` at the default options (finished 15 Oct 2026, at ec7a7a0, `--out experiments/brittleness`); the figures are from its `--report-only` report. No game failed, and every replay reproduced all 300 of its champion's stored benchmark games. Each `seed2-rounds20` champion played 48,300 screen and 24,600 re-test games, each `seed2-meta0` one 38,700 and 19,800, since its own genes (229.3 changes of 0.5) are the 0.5 step. `seed2-rounds20`'s own genes are 77.61 changes of 0.04142 at generation 300 and 26.25 of 0.0004811 at generation 500. The champions won 102, 114, 93 and 77 of their 300 benchmark games (`seed2-rounds20` at 300 and 500, `seed2-meta0` at 300 and 500), and 215, 224, 195 and 144 of the 600 re-test games.

| Champion | Step | Screen: mean difference ± SE (wins of 300) | Identical games | Re-test: controls − champion ± SE (wins of 600) | Screen–re-test correlation (n 8) | Smallest detectable improvement, 80 % power (points) |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `seed2-rounds20` 300 | 0.005 | −0.94 ± 4.29 | 21 % | −7.50 ± 5.34 | +0.53 | 5.9 |
| | 0.02 | −1.59 ± 4.44 | 18 % | −1.00 ± 7.29 | −0.50 | 5.9 |
| | 0.1 | −3.47 ± 4.82 | 12 % | −1.75 ± 7.29 | −0.06 | 6.5 |
| | 0.5 | −2.47 ± 5.78 | 7 % | +0.00 ± 8.04 | +0.28 | 7.2 |
| | own | +0.16 ± 2.94 | 39 % | +4.25 ± 5.48 | −0.18 | 4.6 |
| `seed2-rounds20` 500 | 0.005 | +4.28 ± 5.55 | 16 % | −8.25 ± 7.70 | +0.48 | 7.2 |
| | 0.02 | +2.38 ± 5.61 | 14 % | −6.75 ± 8.59 | −0.16 | 7.4 |
| | 0.1 | +5.31 ± 5.90 | 12 % | −14.50 ± 8.40 | +0.57 | 7.4 |
| | 0.5 | +3.12 ± 6.46 | 9 % | −11.00 ± 9.75 | −0.01 | 7.7 |
| | own | −1.16 ± 1.69 | 72 % | +1.00 ± 1.47 | −0.59 | 3.4 |
| `seed2-meta0` 300 | 0.005 | +0.66 ± 0.96 | 78 % | −2.00 ± 1.91 | −0.35 | 2.2 |
| | 0.02 | +0.34 ± 2.42 | 42 % | −3.00 ± 3.81 | +0.29 | 4.2 |
| | 0.1 | −0.22 ± 5.33 | 8 % | −6.25 ± 8.70 | −0.23 | 6.8 |
| | 0.5 | +0.50 ± 6.67 | 2 % | −7.00 ± 11.22 | −0.53 | 8.1 |
| `seed2-meta0` 500 | 0.005 | +0.22 ± 0.25 | 98 % | +0.50 ± 0.50 | −0.18 | n/a |
| | 0.02 | +0.28 ± 0.59 | 93 % | +0.50 ± 0.87 | −0.47 | n/a |
| | 0.1 | −0.72 ± 1.57 | 72 % | +0.00 ± 1.83 | +0.47 | 2.1 |
| | 0.5 | −1.16 ± 3.06 | 32 % | −1.25 ± 3.77 | +0.20 | 4.3 |

Screen differences are over 32 children a step, re-test levels over the step's 4 controls. The smallest detectable improvement is the report's estimate in percentage points of the 600 re-test games; `n/a` where the children's results almost never differed from the champion's on the screen.

- **No re-tested best child was called better, at any step of any champion.** The sign test called none of them better (m = 20 for each `seed2-rounds20` champion, 16 for each `seed2-meta0` one); the smallest P of a best child was 0.1051 (`seed2-rounds20` generation 500, `own`). Some of the screen's best fell far back: `seed2-rounds20` generation 500's step-0.5 child 27, for one, was +18 on the screen and −29 on the re-test. The screen did not detectably predict the re-test: the correlation over every re-tested child is +0.09 and −0.12 (n 40) for `seed2-rounds20` at generations 300 and 500, −0.34 and +0.11 (n 32) for `seed2-meta0`.
- **No detectable average loss at any step**, up to ±0.5 on 229 weight changes (186–273 weights changed per child at the fixed steps), on any of the four champions: every step's mean screen difference (−3.47 to +5.31 wins of 300) is within one SE of 0. With SEs of up to 6.67 wins of 300, losses of a few points are not excluded.
- **No step can be told from another.** No pair of steps in the report's between-steps table differs by two SEs; the nearest is 0.02 against 0.1 for `seed2-rounds20` generation 500 (−2.94 ± 1.51).
- **None of the re-tested best children was detectably better.** The report estimates the size found with 80 % power at 5.9–7.7 points for the fixed steps of `seed2-rounds20`, 4.6 and 3.4 at `own`, and 2.1–8.1 for `seed2-meta0` (no estimate at steps 0.005 and 0.02 for its generation-500 champion, whose children almost never play differently): a re-tested best child better by at least that much would have been found with about 80 % probability. Only a step's 4 best children on the screen, of 32, were tested for improvement, picked by a screen that did not detectably predict the re-test; the other 28 were not tested for improvement (4 of them, the controls, were re-tested only to set the step's re-test level).
- **The `seed2-meta0` generation-500 champion is far less sensitive to mutation than the generation-300 champion:** 98 %, 93 %, 72 % and 32 % of its children's games are identical to its own at steps 0.005, 0.02, 0.1 and 0.5 (78 %, 42 %, 8 % and 2 % at generation 300). The self-adaptive champions react even to small steps: at step 0.005 only 21 % (generation 300) and 16 % (generation 500) of the games stay identical, and at `own` 39 % and 72 %, although the generation-500 champion's own step is tiny (0.0004811).
- Interpretation: the step-0.5 lineage evolved robustness to the mutation it gets (`docs/literature.md` section 7 expects this under fixed genes), while the self-adaptive champions' move scores are close enough that a small change flips moves; neither shows a detectable average loss of strength, so they are sensitive rather than, as far as this test can tell, brittle.
- **A faint hint, not significant on its own:** on the fresh re-test games, `seed2-rounds20` generation 500's controls trail the champion at every fixed step (−8.25 ± 7.70, −6.75 ± 8.59, −14.50 ± 8.40, −11.00 ± 9.75 wins of 600), each within two SEs of 0, while on the benchmark openings the same steps' children are ahead (+2.38 to +5.31 of 300). The four steps share the champion's 600 re-test games, so they are not four independent signs; `seed2-meta0` generation 300's controls are also all below 0 (−2.00 to −7.00). A small loss of children on fresh games cannot be ruled out.
- One seed, two checkpoints of each run, 32 children a step, and 4 controls a step for the re-test levels.

## Elitism (`elite_share`)

Six runs to generation 1000 (finished between 24 Oct and 12 Nov 2026) describe elitism (`elite_share`, #126: the first E networks of a generation's final ranking carried unchanged into the next, `docs/genes.md`), with `meta_rate` 0.2 and 0, and with `initial_copy_chance` 0.01 and 0 (never copy, #124). All six have `seed2-rounds20`'s seed and other settings (9×9, 1,000 networks starting at 10 hidden layers of 200, 20 rounds). The two without elitism repeat `seed2-rounds20` (which ends at generation 500) and `seed2-meta0` (finished generations to 576) up to generation 1000. At `elite_share` 0.01, every generation from 1 on holds 10 elites, 10,000 a run (B, C).

| Run | `elite_share` | `meta_rate` | `initial_copy_chance` |
| --- | ---: | ---: | ---: |
| `seed2-elite` | 0.01 | 0.2 | 0.01 |
| `seed2-elite-meta0` | 0.01 | 0 | 0.01 |
| `seed2-elite-nocopy` | 0.01 | 0.2 | 0 |
| `seed2-elite-meta0-nocopy` | 0.01 | 0 | 0 |
| `seed2-rounds20-b` | 0 | 0.2 | 0.01 |
| `seed2-meta0-b` | 0 | 0 | 0.01 |

The runs predate #132, so their GNU Go, in the tournament and the benchmark, is the unpinned one ("The default panels and the michi ladder" above). The wins below are against AmiGo, MichiWeak and MichiMid only. All six runs' 1,500 bot-against-bot benchmark games had the same results (A).

The figures come from four scripts at their defaults: A `scripts/compare-runs.rb`, B `scripts/gene-trajectories.rb` and C `scripts/population-strength.rb`, all at 7e4b5a6, and D `scripts/game-repeats.rb` at 5be3d2b. These are the invocations, from the repository root; each table names the outputs it comes from ("A six" is A on the six runs, "A pairs" A on the two one-setting pairs, and so on). Every other window, the bred children and the elites alone, the other genes and the shapes are in the same outputs.

    for script in compare-runs gene-trajectories population-strength; do
      mise exec -- scripts/$script.rb experiments/{seed2-elite,seed2-elite-meta0,seed2-elite-nocopy,seed2-elite-meta0-nocopy,seed2-rounds20-b,seed2-meta0-b}/experiment.sqlite3
      mise exec -- scripts/$script.rb experiments/{seed2-meta0,seed2-meta0-b}/experiment.sqlite3
      mise exec -- scripts/$script.rb experiments/{rounds20,seed2-rounds20}/experiment.sqlite3
    done
    mise exec -- scripts/compare-runs.rb experiments/{seed2-rounds20,seed2-rounds20-b}/experiment.sqlite3
    for run in seed2-elite seed2-elite-meta0 seed2-elite-nocopy seed2-elite-meta0-nocopy seed2-rounds20-b seed2-meta0-b; do
      mise exec -- scripts/game-repeats.rb experiments/$run/experiment.sqlite3 100 300 500 700 1000
      mise exec -- scripts/game-repeats.rb --without-elites experiments/$run/experiment.sqlite3 100 300 500 700 1000
    done
    mise exec -- scripts/game-repeats.rb experiments/seed2-meta0/experiment.sqlite3 100 300 500
    mise exec -- scripts/game-repeats.rb experiments/rounds20/experiment.sqlite3 100 200 300
    mise exec -- scripts/game-repeats.rb experiments/seed2-rounds20/experiment.sqlite3 100 200 300

**Each setting has one run, so nothing here is attributed to a setting.** Whether a difference between these runs comes from their settings cannot be told. Each table also gives the figures of two runs of one setting, or says there are none. One pair is `seed2-meta0` and `seed2-meta0-b`: no elitism, `meta_rate` 0, the same seed, diverging at generation 33 (below). The other is `rounds20` and `seed2-rounds20`: no elitism, `meta_rate` 0.2, other seeds. With another seed they also played other benchmark openings and bot seeds, so their win differences also include another draw of openings and bot seeds, which the six runs share. Neither pair has elites, and the generations both runs of a pair have end at 576 and 302, their shared checkpoints at 500 and 300.

**How the runs relate** (A six, A pairs, "Where the runs diverge"). In every pair of the six, the rankings first differ at generation 1, so all six share generation 0's ranking and champion (6 of 300 wins, rating −513). Runs with the same `initial_copy_chance` share generation 0's births and some of generation 1's, and none later. `seed2-elite` and `seed2-rounds20-b` share 990 births at generation 1, as do `seed2-elite-meta0` and `seed2-meta0-b`; runs with different `meta_rate` share 385–395. Runs with different `initial_copy_chance` share no birth, since `genome` hashes the stored genes too. Even the pairs that share 990 births rank differently from generation 1, whose tournament in an elite run already holds its elites (`RunGeneration#evolve_from_previous_population`). From generation 1 on, the six are separate runs. `seed2-meta0` and `seed2-meta0-b` rank alike through generation 32 and have identical births through 33; at 34 they still share 20 births, later none. Their figures below therefore start at checkpoint 100 and window 51–100. `rounds20` and `seed2-rounds20` differ from generation 0, and 164 of their 1,500 bot-against-bot games had another result. `seed2-rounds20` and `seed2-rounds20-b` never differ over generations 0–500: A gives their champions identical wins and ratings there, and B, C and D print the same figures for both at every window and checkpoint both outputs hold, so `rounds20`'s partner has `seed2-rounds20-b`'s figures in the tables below up to 500.

**Windows.** Where a table below shows 50-generation windows, it shows every window that ends at a multiple of 100 (51–100, 151–200, …, 951–1000) and no other. Where it gives a range, the range is over every window the row names.

**Champions** (A six; the pair columns from A pairs, "Differences"). Each checkpoint champion's wins of 300 against AmiGo, MichiWeak and MichiMid, and in brackets its rating in Elo above AmiGo from the six-run fit. These ratings compare only within that fit, and each is ±42–55 at checkpoints 100–1000 with the other ratings held fixed. Over another sample of openings and bot seeds, one champion's wins would move by ±12–16 (95 %, A's binomial half-width at checkpoints 100–1000). The last two columns are the one-setting pairs' differences in wins. Checkpoint 0 is the same in every run: 6 wins, rating −513.

| Checkpoint | `seed2-elite` | `seed2-elite-meta0` | `seed2-elite-nocopy` | `seed2-elite-meta0-nocopy` | `seed2-rounds20-b` | `seed2-meta0-b` | `seed2-meta0` − `seed2-meta0-b` | `rounds20` − `seed2-rounds20` |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | 116 (48) | 85 (−46) | 67 (−113) | 66 (−117) | 51 (−204) | 78 (−74) | −5 | +70 |
| 200 | 121 (48) | 88 (−55) | 64 (−124) | 73 (−93) | 101 (−2) | 79 (−55) | +23 | +19 |
| 300 | 123 (62) | 78 (−74) | 74 (−86) | 69 (−103) | 102 (1) | 92 (−28) | +1 | +26 |
| 400 | 117 (51) | 106 (10) | 85 (−55) | 73 (−93) | 109 (21) | 76 (−107) | +5 | none |
| 500 | 119 (48) | 129 (78) | 74 (−93) | 76 (−80) | 114 (29) | 80 (−61) | −3 | none |
| 600 | 99 (−4) | 126 (67) | 71 (−96) | 86 (−49) | 120 (56) | 113 (29) | none | none |
| 700 | 111 (35) | 116 (37) | 72 (−93) | 86 (−46) | 109 (29) | 118 (51) | none | none |
| 800 | 120 (45) | 113 (32) | 82 (−64) | 94 (−25) | 111 (35) | 125 (64) | none | none |
| 900 | 97 (−4) | 118 (51) | 77 (−83) | 95 (−16) | 107 (18) | 135 (91) | none | none |
| 1000 | 125 (59) | 134 (91) | 78 (−67) | 107 (15) | 118 (51) | 118 (51) | none | none |

In the pairs' own fits, `seed2-meta0` and `seed2-meta0-b` are rated −101 and −92, −19 and −74, −50 and −47, −80 and −124, −89 and −80 at checkpoints 100–500. `rounds20` and `seed2-rounds20` are rated 48 and −202, 48 and −6, 61 and −3 at checkpoints 100–300.

**Champions over a window** (A six). Two windows, fixed before the scripts ran: per run, the mean wins, the least-squares slope in wins per 100 generations, and the residual SD around the line over the window's checkpoints. A slope describes a straight line over the window, not its shape; set the residual SD beside one champion's game noise, whose SD is the ± above divided by 1.96 (about 6–8 wins). One-setting figures: none (A pairs prints "does not cover" for `seed2-meta0`, `rounds20` and `seed2-rounds20` in both windows).

| Run | 500..1000: mean, slope, SD | 200..1000: mean, slope, SD |
| --- | ---: | ---: |
| `seed2-elite` | 111.8, +0.9, 12.9 | 114.7, −1.1, 10.5 |
| `seed2-elite-meta0` | 122.7, −0.1, 9.2 | 112.0, +5.1, 13.3 |
| `seed2-elite-nocopy` | 75.7, +1.4, 3.6 | 75.2, +1.0, 6.0 |
| `seed2-elite-meta0-nocopy` | 90.7, +5.4, 3.1 | 84.3, +4.4, 3.9 |
| `seed2-rounds20-b` | 113.2, −0.5, 5.6 | 110.1, +1.4, 5.7 |
| `seed2-meta0-b` | 114.8, +7.5, 13.8 | 104.0, +7.0, 12.2 |

**Population against the bots** (C six, C pairs, all networks). Per window, the share of networks (%) that scored strictly above the mean of the AmiGo / MichiWeak / MichiMid copies in their tournament. The last two columns are the pairs: `seed2-meta0`'s partner is `seed2-meta0-b`, `rounds20`'s is `seed2-rounds20` (equal to `seed2-rounds20-b` to 500). `seed2-meta0`'s 551–600 holds 26 generations.

| Window | `seed2-elite` | `seed2-elite-meta0` | `seed2-elite-nocopy` | `seed2-elite-meta0-nocopy` | `seed2-rounds20-b` | `seed2-meta0-b` | `seed2-meta0` | `rounds20` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 51–100 | 56.9 / 49.0 / 0.4 | 5.3 / 3.3 / 0.1 | 3.0 / 2.3 / 0.1 | 3.3 / 2.0 / 0.1 | 2.9 / 3.9 / 0.2 | 6.2 / 8.2 / 0.2 | 4.7 / 6.7 / 0.1 | 10.3 / 19.7 / 0.2 |
| 151–200 | 70.3 / 53.4 / 0.4 | 8.4 / 7.7 / 0.2 | 3.9 / 4.7 / 0.1 | 3.4 / 3.9 / 0.1 | 10.7 / 10.7 / 0.2 | 19.1 / 25.1 / 0.3 | 5.9 / 15.4 / 0.1 | 30.2 / 53.3 / 0.4 |
| 251–300 | 64.2 / 55.2 / 0.4 | 13.0 / 15.0 / 0.2 | 6.7 / 5.2 / 0.1 | 4.9 / 4.6 / 0.1 | 32.4 / 37.2 / 0.3 | 21.0 / 32.6 / 0.3 | 15.2 / 25.7 / 0.3 | 26.2 / 64.6 / 0.5 |
| 351–400 | 63.7 / 50.7 / 0.5 | 23.3 / 23.0 / 0.3 | 9.5 / 6.5 / 0.1 | 6.7 / 4.7 / 0.1 | 41.0 / 46.8 / 0.5 | 29.9 / 33.8 / 0.3 | 21.6 / 30.2 / 0.3 | none |
| 451–500 | 80.4 / 45.8 / 0.5 | 55.8 / 46.8 / 0.4 | 12.2 / 7.4 / 0.2 | 9.5 / 4.4 / 0.2 | 40.3 / 49.4 / 0.4 | 45.0 / 38.7 / 0.3 | 22.9 / 32.2 / 0.3 | none |
| 551–600 | 72.4 / 45.0 / 0.5 | 75.1 / 43.8 / 0.5 | 10.6 / 7.0 / 0.2 | 10.9 / 6.9 / 0.2 | 51.7 / 56.0 / 0.5 | 13.8 / 43.4 / 0.3 | 8.5 / 36.8 / 0.4 | none |
| 651–700 | 79.7 / 53.8 / 0.5 | 76.8 / 51.3 / 0.4 | 9.7 / 7.4 / 0.1 | 8.0 / 9.2 / 0.2 | 60.0 / 62.2 / 0.5 | 43.7 / 42.7 / 0.4 | none | none |
| 751–800 | 88.8 / 47.7 / 0.5 | 54.3 / 60.7 / 0.6 | 13.1 / 8.3 / 0.1 | 11.4 / 9.3 / 0.1 | 52.7 / 49.4 / 0.5 | 52.4 / 52.0 / 0.6 | none | none |
| 851–900 | 85.8 / 56.6 / 0.4 | 52.0 / 60.1 / 0.6 | 17.1 / 8.8 / 0.2 | 21.3 / 12.0 / 0.2 | 71.0 / 50.7 / 0.5 | 64.2 / 57.8 / 0.7 | none | none |
| 951–1000 | 80.6 / 54.0 / 0.5 | 41.4 / 63.1 / 0.6 | 14.0 / 8.1 / 0.1 | 27.7 / 27.7 / 0.3 | 66.3 / 49.5 / 0.5 | 62.2 / 53.8 / 0.5 | none | none |

**Genes** (B six, B pairs, all networks). The median of the per-generation medians per window. At `meta_rate` 0 every window of all four runs (`seed2-elite-meta0`, `seed2-elite-meta0-nocopy`, `seed2-meta0-b`, `seed2-meta0`) prints generation 0's values, `weight_step` 0.5 and `copy_chance` 0.01 (0 in the no-copy run), so the `seed2-meta0` pair has no gene spread to show. The no-copy runs' `copy_chance` is exactly 0 in every window. The `meta_rate` 0.2 runs, with `rounds20` for the pair (its partner `seed2-rounds20` equals `seed2-rounds20-b` to 500):

| Window | `weight_step`: `seed2-elite` | `seed2-elite-nocopy` | `seed2-rounds20-b` | `rounds20` | `copy_chance`: `seed2-elite` | `seed2-rounds20-b` | `rounds20` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 51–100 | 1.21 | 1.2 | 0.154 | 0.00712 | 0.00317 | 0.0123 | 0.00693 |
| 151–200 | 0.872 | 0.398 | 0.143 | 0.00178 | 0.00435 | 0.00019 | 0.00195 |
| 251–300 | 1.02 | 0.0458 | 0.0647 | 0.000297 | 0.0126 | 0.00033 | 0.000618 |
| 351–400 | 0.571 | 0.00318 | 0.00678 | none | 0.017 | 0.000465 | none |
| 451–500 | 0.612 | 0.00497 | 0.0056 | none | 0.00465 | 0.00132 | none |
| 551–600 | 0.601 | 0.00182 | 0.0155 | none | 0.00114 | 0.000902 | none |
| 651–700 | 1.81 | 0.00194 | 0.181 | none | 0.000393 | 0.00197 | none |
| 751–800 | 1.27 | 0.00391 | 2.65 | none | 0.00141 | 0.00434 | none |
| 851–900 | 1.17 | 0.00482 | 0.118 | none | 0.000566 | 0.0079 | none |
| 951–1000 | 0.978 | 0.000591 | 0.034 | none | 0.000598 | 0.00204 | none |

**Clones** (B six, B pairs; the owner asked for these counts on 19 Oct 2026). Per run, the range of each count over the 50-generation windows the row names: copies; self-crossovers (a network crossed with itself); crossovers whose differs count against the picked parent is 0; crossovers whose `genome` equals a parent's; exact clones (copies plus the last). The three crossover columns nest, so they are never added. The last column is apart from the clones: mutation children with no network weight changed, whose feature weights and genes may differ from the parent's and whose play is not measured, so they count neither as clones nor as not clones. The pairs' rows cover only the full windows both runs of the pair have, from the first after their divergence.

| Run | Windows | Copies | Self-crossovers | Differs 0 | A parent's genome | Exact clones | No network weight changed |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `seed2-elite` | 1–50 to 951–1000 | 35–1,308 | 19–49 | 34–93 | 34–93 | 128–1,357 | 0–5,777 |
| `seed2-elite-meta0` | 1–50 to 951–1000 | 325–452 | 21–44 | 22–49 | 23–49 | 361–496 | 0 |
| `seed2-elite-nocopy` | 1–50 to 951–1000 | 0 | 20–50 | 32–65 | 32–66 | 32–66 | 0–3,121 |
| `seed2-elite-meta0-nocopy` | 1–50 to 951–1000 | 0 | 24–41 | 25–41 | 25–42 | 25–42 | 0 |
| `seed2-rounds20-b` | 1–50 to 951–1000 | 3–858 | 22–50 | 36–197 | 36–199 | 56–934 | 0–6,345 |
| `seed2-meta0-b` | 1–50 to 951–1000 | 340–442 | 24–54 | 28–54 | 29–55 | 385–481 | 0 |
| Pair: `seed2-meta0` | 51–100 to 501–550 | 320–404 | 22–43 | 23–44 | 24–47 | 367–449 | 0 |
| Pair: `seed2-meta0-b` | 51–100 to 501–550 | 340–442 | 24–51 | 28–51 | 29–51 | 385–481 | 0 |
| Pair: `rounds20` | 1–50 to 251–300 | 68–582 | 28–40 | 28–40 | 28–41 | 109–612 | 0 |
| Pair: `seed2-rounds20` | 1–50 to 251–300 | 3–858 | 28–43 | 36–58 | 36–58 | 56–895 | 0–556 |

**Repeats** (D). Network-against-network clone repeats per checkpoint, of 9,712–9,767 games. After the slash, with `--without-elites`, of the 9,531–9,556 games left; in the runs without elites the option leaves out nothing, and D prints the same figures. Read them across checkpoints, not from one. The last three columns are the pairs (`seed2-meta0`'s partner is `seed2-meta0-b`). — means D did not run at that checkpoint; none means the run has no such generation.

| Generation | `seed2-elite` | `seed2-elite-meta0` | `seed2-elite-nocopy` | `seed2-elite-meta0-nocopy` | `seed2-rounds20-b` | `seed2-meta0-b` | `seed2-meta0` | `rounds20` | `seed2-rounds20` |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | 34 / 34 | 0 / 0 | 5 / 5 | 6 / 6 | 29 | 2 | 0 | 20 | 29 |
| 200 | — | — | — | — | — | — | — | 66 | 3 |
| 300 | 145 / 140 | 1 / 1 | 63 / 59 | 3 / 3 | 258 | 0 | 1 | 11 | 258 |
| 500 | 362 / 342 | 1 / 1 | 191 / 184 | 0 / 0 | 1,630 | 406 | 32 | none | — |
| 700 | 390 / 380 | 12 / 12 | 176 / 165 | 0 / 0 | 855 | 11 | none | none | none |
| 1000 | 627 / 589 | 11 / 11 | 465 / 450 | 0 / 0 | 813 | 4 | none | none | none |

**Elites** (C six). Facts within each elite run, as ranges over its windows 1–50 to 951–1000; no one-setting pair has elites, so there is no one-setting figure. Rank percentile: among the networks of the tournament an elite is carried into, 0 the first and 1 the last, the window's mean and median. Stay elite: the share carried again into the next generation. Children: bred children in the next generation per elite, and per non-elite network among its generation's first 10 %. Score: in the tournament that chose them (their parents' score, the same networks) and in the next one, the window's mean and the mean change. The longest chain is the most generations in a row one network was carried as an elite. No checkpoint champion of any run was an elite (A).

| Run | Mean percentile | Median percentile | Longest chain | Stay elite | Children per elite | Children per top-10 % non-elite | Score before | Score after | Change |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `seed2-elite` | 0.343–0.457 | 0.265–0.431 | 2–3 | 0.8–3.4 % | 1.23–1.85 | 2.83–3.35 | 14.4–14.9 | 10.3–11.1 | −4.53 to −3.35 |
| `seed2-elite-meta0` | 0.403–0.464 | 0.356–0.446 | 2–3 | 1.0–3.0 % | 1.29–1.64 | 2.92–3.48 | 14.4–14.9 | 10.2–10.7 | −4.45 to −3.77 |
| `seed2-elite-nocopy` | 0.407–0.503 | 0.37–0.505 | 2–3 | 0.2–2.0 % | 1.15–1.62 | 2.9–3.74 | 14.3–14.7 | 9.86–10.5 | −4.76 to −3.71 |
| `seed2-elite-meta0-nocopy` | 0.382–0.497 | 0.334–0.521 | 2–3 | 0.6–2.4 % | 0.98–1.72 | 2.8–3.46 | 14.3–14.8 | 9.97–10.8 | −4.71 to −3.52 |

**Score retest of the exact clones** (C six, C pairs). Copies, and crossovers with a parent's genome, against that parent's score in the generation before, as ranges over the windows the row names: the clones a window, the mean score before and after, the mean change, and the correlation of the scores before and after. Like the elites' score above, both tournaments have different fields (the next generation's), so neither the change nor the correlation is a reliability coefficient of one tournament.

| Run | Windows | Exact clones | Score before | Score after | Change | Correlation |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `seed2-elite` | 1–50 to 951–1000 | 128–1,357 | 11.7–12 | 9.94–10.3 | −1.93 to −1.56 | 0.0129 to 0.308 |
| `seed2-elite-meta0` | 1–50 to 951–1000 | 361–496 | 11.6–11.9 | 10–10.3 | −1.81 to −1.32 | 0.0163 to 0.184 |
| `seed2-elite-nocopy` | 1–50 to 951–1000 | 32–66 | 11.7–12.4 | 9.18–10.4 | −2.76 to −1.37 | −0.078 to 0.29 |
| `seed2-elite-meta0-nocopy` | 1–50 to 951–1000 | 25–42 | 11.8–12.5 | 9.48–10.9 | −2.69 to −1.22 | −0.397 to 0.343 |
| `seed2-rounds20-b` | 1–50 to 951–1000 | 56–934 | 11.5–12.2 | 9.87–10.5 | −2.16 to −1.39 | −0.0656 to 0.227 |
| `seed2-meta0-b` | 1–50 to 951–1000 | 385–481 | 11.6–11.9 | 9.98–10.3 | −1.8 to −1.36 | −0.00972 to 0.203 |
| Pair: `seed2-meta0` | 51–100 to 501–550 | 367–449 | 11.7–11.9 | 9.86–10.3 | −1.9 to −1.41 | −0.0316 to 0.198 |
| Pair: `seed2-meta0-b` | 51–100 to 501–550 | 385–481 | 11.6–11.9 | 9.98–10.3 | −1.8 to −1.36 | −0.00972 to 0.173 |
| Pair: `rounds20` | 1–50 to 251–300 | 109–612 | 11.6–11.8 | 9.92–10.2 | −1.85 to −1.58 | 0.0526 to 0.161 |
| Pair: `seed2-rounds20` | 1–50 to 251–300 | 56–895 | 11.5–12.2 | 9.95–10.5 | −1.76 to −1.54 | −0.0656 to 0.181 |

**The 16 Oct hypothesis** (`docs/literature.md` section 7, experiment 2): with elitism, `weight_step` and `copy_chance` shrink less at `meta_rate` 0.2, and the plateau is higher at `meta_rate` 0. With one run per setting, the runs **cannot tell**. The Genes table gives each run's medians, the two Champions tables each run's champions; telling it needs more seeds of each setting.

**Step 0.5's rise and fall** (`PROJECT_NOTES.md` item 3): does elitism change it? The runs **cannot tell** that either, with one run of each elitist setting at `meta_rate` 0. The Population and Champions tables give each run, and the `seed2-meta0` pair's figures as far as both runs reach.

**Self-benchmark check** (A six and pairs, owner 19 Oct 2026). In none of the runs above did a checkpoint champion have the genome of a network it was benchmarked against.

**Interpretation** (what the outputs cannot separate). In every window, the elites of the four elite runs and the exact clones of every run scored less on average in the next tournament than they or their parent had in the one that chose them (the Elites and exact-clone retest tables). The outputs cannot tell how much of either fall is a stronger next field and how much a lucky score that selection picked, since the two tournaments have different fields. Nor can they separate a setting's effect on the `meta_rate` 0.2 gene trajectories from the spread between runs of one setting: the only pair at 0.2, `rounds20` and `seed2-rounds20`, is in the Genes table, up to generation 300 (its outputs to 302).

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
