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
   [Brown](https://www.lysator.liu.se/~gunnar/gtp/), and
   [AmiGoGtp](https://amigogtp.sourceforge.net/), and installs
   [GoGui](https://github.com/Remi-Coulom/gogui) 1.6.0. The archives come from
   this repository's `external-tools-r1` GitHub release, a copy of the
   upstream files, so setup does not depend on the upstream hosts. They are
   checked against SHA-256 hashes before extraction, and GNU Go is patched for an
   upstream sorting bug (`scripts/patches/`). The programs stay under
   `.local/evo-tools/` and mise places them on `PATH` for project tasks.
3. Run `mise run verify` to run the C and Ruby tests and refereed 9×9 matches in which
   Brown, AmiGoGtp, GNU Go levels 0 and 10, and Evo each play. It fails if a
   program crashes or the GNU Go referee returns no score. It also plays a
   sample of games between random networks both in the arena (the C program
   that plays network-against-network games) and through GoGui, and fails if
   the moves differ or the arena's score differs from a Tromp–Taylor count of
   GoGui's game.

CI runs the same tasks as separate jobs (C tests, Ruby tests, and the
refereed matches), so a failure shows which kind of check broke. For
development without the
external programs, use `mise run setup` and `mise run test` (or `test-c` and
`test-ruby` on their own). Other useful tasks are `mise run build`,
`mise run clean`, `mise run doctor`, and `mise run smoke`.

## Running the evolution of the neural net

1. Run `mise run run EXPERIMENT_NAME` and answer the setup questions.
2. Restart an interrupted experiment with the same command.
3. View results with `mise run stats EXPERIMENT_NAME` (see [Statistics](#statistics)).

Each network carries its own settings as genes, and they evolve with its
weights: its hidden and output activations, its shape (hidden layers and
their width), and its mutation settings (the chance that a child is a plain
copy, how many weights a mutation changes and by how much, and how often it
switches an activation or changes the shape). The experiment's settings give
generation 0's shape and genes, the bounds on the shape
(`max_hidden_layers`, `max_layer_size`), and the pace at which the mutation
settings themselves change (`meta_rate`). `mise run new-experiment` without
arguments lists every setting and its default.

You can pass the existing runner arguments after the name, for example
`mise run run EXPERIMENT_NAME 2 one-generation`. `mise run` supplies the pinned
Ruby and Java versions even without shell activation.

## Benchmark

Tournament scores only compare the networks of one generation, so they cannot
show whether evolution makes progress. At every checkpoint (every
`keep_every`-th generation, including generation 0; none when `keep_every` is
0), after the tournament, the generation's top network plays a fixed panel:
Brown, AmiGo, GNU Go level 0, the top network of generation 0, and the top
network of the previous checkpoint. Generation 0 plays only the bots.

Two settings control it:

- `benchmark_games` (default 20): games per opponent, an even number, half
  with each color.
- `benchmark_opening_moves` (default 4): stones in each seeded opening. Every
  checkpoint plays the same openings, each once with each color, so
  checkpoints can be compared. With 0, the games against Brown, AmiGo, and
  networks repeat, because those players are deterministic.

The results are in the `benchmark_games` table of
`experiments/EXPERIMENT_NAME/experiment.sqlite3`, one row per game, and
`stats` shows them per checkpoint and opponent.

The panel is stored in each experiment's database (table
`benchmark_opponents`) when the experiment is created. To use another panel,
create the experiment with `mise run new-experiment EXPERIMENT_NAME ...`, change
the table before the first `mise run run`, for example
`sqlite3 experiments/EXPERIMENT_NAME/experiment.sqlite3 "DELETE FROM benchmark_opponents WHERE name = 'GnuGoLevel0'"`,
and leave it alone afterwards: a panel changed during a run makes its
checkpoints incomparable. A bot row has `kind` `bot` and the `command` that
starts it; `initial_champion` and `previous_checkpoint` rows have no command.

## Statistics

`stats` reads the experiment database read-only, so it can run while the
experiment does:

- `mise run stats EXPERIMENT_NAME` prints the tables once.
- `mise run stats EXPERIMENT_NAME --watch` redraws them every 5 seconds until
  Ctrl-C.
- `mise run stats EXPERIMENT_NAME --csv` prints one row per generation with
  every figure, for a spreadsheet. The columns depend only on the tournament's
  opponents and the benchmark panel, so experiments with the same ones line up.

The first table shows whether evolution is healthy: the games, draws, and
failed games of each generation's tournament and their total time, the share
of bred children identical to a parent, the distinct networks that passed on
weights (a mutation or a copy comes from one parent only), the distinct genomes, and the
lowest, median, and highest network score. A generation is done once its
rounds and, at a checkpoint, its benchmark are played. The last table shows
progress: each checkpoint's benchmark, with the network's wins and losses as
Black and as White against each opponent. For example, after two generations
of `mise run new-experiment NAME --board-size 9 --population-size 4 --hidden-layers 1 --layer-size 10 --cross-over-rate 0.5 --game-length 10 --max-moves 200 --tournament-rounds 1 --keep-every 1 --benchmark-games 2 --seed 3` (trimmed to the first and last table; the times vary):

```text
Generations
+-----+------+-------+-------+--------+------+--------+---------+---------+-----+-----+-----+
| Gen | Done | Games | Draws | Failed | Time | Copies | Parents | Genomes | Min | Med | Max |
+-----+------+-------+-------+--------+------+--------+---------+---------+-----+-----+-----+
|   0 |  yes |     9 |     0 |      0 | 2.2s |      - |       0 |       4 |   0 | 0.5 |   1 |
|   1 |  yes |     9 |     0 |      0 | 1.7s |    50% |       2 |       3 |   0 |   0 |   1 |
+-----+------+-------+-------+--------+------+--------+---------+---------+-----+-----+-----+

Benchmark
+-----+----------+--------------+-------+-------+-------+-------+--------+
| Gen | Network  | Opponent     | Games | Black | White | Draws | Failed |
+-----+----------+--------------+-------+-------+-------+-------+--------+
|   0 | 0002.ann | Brown        |   2/2 |   1-0 |   0-1 |     0 |      0 |
|   1 | 3.ann    | Brown        |   2/2 |   1-0 |   0-1 |     0 |      0 |
|   1 | 3.ann    | Gen0Champion |   2/2 |   0-1 |   1-0 |     0 |      0 |
+-----+----------+--------------+-------+-------+-------+-------+--------+
```

Between the two, for the latest 10 generations, three tables show how the
genomes evolve: Genes (the median of each gene, layers, width, and weights,
with the range in the latest generation), Shapes and activations (the most
common of each), and Breeding and bots (the most children of one parent,
parents without children, the structural changes, and where the best copy of
each bot ranks among the networks).

The tournament score only ranks one generation's networks against each other,
so compare generations by the benchmark, not by the scores.

## Running the bundled example against itself

Run `mise run example` to open a GoGui match with the bundled network playing
both colors.
