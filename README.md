# evo
Artificial intelligence for the game of Go using neural networks and genetic algorithms

_This is an experiment to see if genetic algorithms can be used to evolve a neural network for playing the game of Go. I don't expect this to be a good program anytime soon (or ever), I just want to play around._

## Requirements

Install [mise](https://mise.jdx.dev/) first. The project configuration pins Ruby
4.0.7, Temurin JDK 21 for GoGui, and jq. On macOS or Linux, you also need C and C++
compilers, `make`, `curl`, `tar`, `unzip`, `patch`, and either `shasum` or
`sha256sum`.

## Installation

1. Clone the repository: `git clone git@github.com:ujh/evo.git`
2. Run `mise run setup-experiments`. This runs the base `setup` task, then
   downloads and builds pinned versions of [GNU Go](https://www.gnu.org/software/gnugo/),
   [Brown](https://www.lysator.liu.se/~gunnar/gtp/),
   [AmiGoGtp](https://amigogtp.sourceforge.net/), and
   [michi-c2](https://github.com/db3108/michi-c2), and installs
   [GoGui](https://github.com/Remi-Coulom/gogui) 1.6.0. The archives come from
   this repository's `external-tools-r1` GitHub release, a copy of the
   upstream files, so setup does not depend on the upstream hosts. They are
   checked against SHA-256 hashes before extraction; GNU Go is patched for two
   upstream bugs (a sort of an empty array and a liberty overflow) and
   michi-c2 for crashes and for play as an opponent (`scripts/patches/`).
   The programs stay under `.local/evo-tools/` and mise places them on
   `PATH` for project tasks.
3. Run `mise run verify` to run the C and Ruby tests and refereed 9×9 matches in which
   Brown, AmiGoGtp, GNU Go levels 0 and 10, michi-c2, and Evo each play. It fails if a
   program crashes or the GNU Go referee returns no score. It drives Brown,
   AmiGoGtp, GNU Go level 0, michi-c2, and Evo through the arena's own GTP controller
   too, and fails if one of them does not answer or a game between them,
   or between one of them and a network in the arena, does not finish. It
   also plays a sample of games between random networks both in the arena
   (the C program that plays and scores games on its own board) and
   through GoGui, and fails if
   the moves differ or the arena's score differs from a Tromp–Taylor count of
   GoGui's game.

CI runs the same tasks as separate jobs (C tests, Ruby tests, and one job
per smoke check), so a failure shows which kind of check broke. For
development without the
external programs, use `mise run setup` and `mise run test` (or `test-c` and
`test-ruby` on their own). Other useful tasks are `mise run build`,
`mise run clean`, `mise run doctor`, `mise run smoke`, `mise run profile-workload`
(the fixed workloads in `docs/performance.md`), and `mise run archive-experiment NAME`,
which shrinks a finished experiment to its kept generations' champions
(irreversibly; see `docs/experiment-reference.md`).

## Running the evolution of the neural net

1. Run `mise run run EXPERIMENT_NAME` and answer the setup questions.
2. Restart an interrupted experiment with the same command.
3. View results with `mise run stats EXPERIMENT_NAME` (see [Statistics](#statistics)).

The networks play each other and a ladder of bots, weakest first: Brown,
AmiGo, three levels of michi-c2 calibrated between AmiGo and GNU Go level 0,
and GNU Go level 0 (`docs/experiment-reference.md` has the commands and the
calibration). The michi levels were calibrated on 9×9 only, so an experiment
with them refuses every other board size.

Each network carries its own settings as genes, and they evolve with its
weights: its hidden and output activations, its shape (hidden layers and
their width), and its mutation settings (the chance that a child is a plain
copy, how many weights a mutation changes and by how much, and how often it
switches an activation or changes the shape). The experiment's settings give
generation 0's shape and genes, the bounds on the shape
(`max_hidden_layers`, `max_layer_size`), and the pace at which the mutation
settings themselves change (`meta_rate`). `mise run new-experiment` without
arguments lists every setting and its default.
[The evolving genome](docs/genes.md) explains the genes, how a child is
made, how shapes change, and how to read the genome tables in `stats`.

Networks also get hand-coded Go knowledge: good 3×3 shapes, captures,
self-atari, saving a chain from atari, the opponent's last move, and chain
liberties, as extra inputs and as feature weights added to each point's
score, which evolve as genes too. The `features` setting picks the groups:
`all` (the default), `none` (stones and komi only), or a list such as
`tactics,liberties`; `initial_feature_noise` and `initial_feature_step`
set how generation 0's feature weights start. [Go features](docs/features.md)
explains each feature, how the network uses it, and what a comparison with
a stones-only run showed.

You can pass the existing runner arguments after the name, for example
`mise run run EXPERIMENT_NAME 2 one-generation`. `mise run` supplies the pinned
Ruby and Java versions even without shell activation.

## Benchmark

Tournament scores only compare the networks of one generation, so they cannot
show whether evolution makes progress. At every checkpoint (every
`keep_every`-th generation, including generation 0; none when `keep_every` is
0), after the tournament, the generation's top network plays a fixed panel:
Brown, AmiGo, the three michi levels, GNU Go level 0, the top network of
generation 0, and the top networks of the last `benchmark_champions`
checkpoints before it (a rolling set: older ones drop out, generation 0's
stays). Each past champion is a separate opponent, `GenNChampion` for the
checkpoint N. Generation 0 plays only the bots. The six bots also play each
other, once per experiment: the first checkpoint plays those games along with
its own (a resume re-enters that checkpoint and finishes them). On every start,
before it resumes, the runner has each earlier checkpoint play the benchmark
games it lacks, so raising a benchmark setting fills in the checkpoints already
played too.

Four settings control it:

- `benchmark_games` (default 100): games per opponent, an even number, half
  with each color.
- `benchmark_champions` (default 10): how many past checkpoints' champions
  each checkpoint plays, besides generation 0's.
- `benchmark_bot_games` (default 100): games per pair of bots, an even number,
  half with each bot as Black; 0 for none. The 15 pairs of the six bots play
  1,500 games in all.
- `benchmark_opening_moves` (default 4): stones in each seeded opening. Every
  checkpoint plays the same openings, each once with each color, so
  checkpoints can be compared. With 0, the games against Brown, AmiGo, and
  networks repeat, because those players are deterministic (michi and GNU Go
  get a seed per game).

The results are in the `benchmark_games` table of
`experiments/EXPERIMENT_NAME/experiment.sqlite3`, one row per game (the bots'
games against each other in `benchmark_bot_games`), and
`stats` rates every player on one scale from all of these games: each
checkpoint's champion, generation 0's, and the bots, with AmiGo at 0.

The panel is stored in each experiment's database (table
`benchmark_opponents`) when the experiment is created. To use another panel,
create the experiment with `mise run new-experiment EXPERIMENT_NAME ...`, change
the table before the first `mise run run`, for example
`sqlite3 experiments/EXPERIMENT_NAME/experiment.sqlite3 "DELETE FROM benchmark_opponents WHERE name = 'GnuGoLevel0'"`,
and leave it alone afterwards: a panel changed during a run makes its
checkpoints incomparable. A bot row has `kind` `bot` and the `command` that
starts it; `initial_champion` and `past_champions` rows have no command.

## Statistics

`stats` reads the experiment database read-only, so it can run while the
experiment does:

- `mise run stats EXPERIMENT_NAME` prints the tables once.
- `mise run stats EXPERIMENT_NAME --watch` redraws, every 5 seconds until
  Ctrl-C, only Breeding and bots and Networks against bots for the latest 10
  generations, and the Benchmark ratings: all the figures of a long experiment
  take seconds to compute. Add `--extended` to redraw every table instead,
  every 30 seconds.
- `mise run stats EXPERIMENT_NAME --csv` prints one row per generation with
  every figure, for a spreadsheet. The columns depend only on the tournament's
  opponents and the benchmark panel, so experiments with the same ones line up.

The first table shows whether evolution is healthy: the games and draws of
each generation's tournament (a game the arena cannot finish stops the run, so
none is stored as failed) and their total time, the share
of bred children identical to a parent, the distinct networks that passed on
weights (a mutation or a copy comes from one parent only), the distinct genomes, and the
lowest, median, and highest network score. A generation is done once its
rounds and, at a checkpoint, its benchmark are played (the champion's games;
the bots' games against each other do not count). The last table shows
progress: a Bradley–Terry rating in Elo of every benchmark player, AmiGo at 0,
fitted over every checkpoint's benchmark games and the bots' games against each
other, so champions of different checkpoints, and bots the latest champion
always beats or always loses to, are compared through the players they met.
If the fit does not converge, a line says so in place of the table.
Each row has the ± of about 95 % (with the other ratings held fixed, so
narrower than the uncertainty against AmiGo), the player's scored games, and
its points per game. The latest champion's row is bold on a terminal. For
example, after two generations
of `mise run new-experiment NAME --board-size 9 --population-size 4 --hidden-layers 1 --layer-size 10 --cross-over-rate 0.5 --game-seconds 600 --max-moves 200 --tournament-rounds 1 --keep-every 1 --benchmark-games 2 --benchmark-bot-games 2 --seed 3` (every feature group, the default; trimmed to the first and last table, without their notes; 30 Sep 2026, the times vary):

```text
Generations
+-----+------+-------+-------+-------+--------+---------+---------+-----+-----+-----+
| Gen | Done | Games | Draws | Time  | Copies | Parents | Genomes | Min | Med | Max |
+-----+------+-------+-------+-------+--------+---------+---------+-----+-----+-----+
|   0 |  yes |    18 |     0 | 14.5s |      - |       0 |       4 |   0 |   0 |   1 |
|   1 |  yes |    18 |     0 | 10.7s |    25% |       2 |       4 |   0 |   0 |   0 |
+-----+------+-------+-------+-------+--------+---------+---------+-----+-----+-----+

Benchmark ratings (all checkpoints, AmiGo = 0)
+------+--------------+--------+-----+-------+-------+
| Rank | Player       | Rating | ±   | Games | Score |
+------+--------------+--------+-----+-------+-------+
|    1 | MichiStrong  |    401 | 280 |    14 |   93% |
|    2 | GnuGoLevel0  |    320 | 253 |    14 |   86% |
|    3 | MichiMid     |    249 | 238 |    14 |   79% |
|    4 | AmiGo        |      0 |   - |    14 |   50% |
|    5 | MichiWeak    |      0 | 220 |    14 |   50% |
|    6 | Gen0Champion |   -255 | 247 |    14 |   21% |
|    7 | Gen1Champion |   -255 | 247 |    14 |   21% |
|    8 | Brown        |   -530 | 365 |    14 |    0% |
+------+--------------+--------+-----+-------+-------+
```

Between the two, for the latest 10 generations, five tables show how the
genomes evolve: Genes (the median of each gene, layers, width, and weights,
with the range in the latest generation), Feature weights (the same for
`feature_step` and each move feature's weight; not shown without move
features), Shapes and activations (the most
common of each), and Breeding and bots (the most children of one parent,
parents without children, the structural changes, and where the best copy of
each bot ranks among the networks), and Networks against bots (per bot, the
networks' wins of their tournament games against it).

The tournament score only ranks one generation's networks against each other,
so compare generations by the benchmark, not by the scores.

## Running the bundled example against itself

Run `mise run example` to open a GoGui match with the bundled network playing
both colors.
