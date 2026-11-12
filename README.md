# evo

Artificial intelligence for the game of Go using neural networks and genetic algorithms

_This is an experiment to see if genetic algorithms can be used to evolve a neural network for playing the game of Go. I don't expect this to be a good program anytime soon (or ever), I just want to play around._

- [Requirements](#requirements)
- [Installation](#installation)
- [Running the evolution of the neural net](#running-the-evolution-of-the-neural-net)
- [Benchmark](#benchmark)
- [Statistics](#statistics)
- [Running the bundled example against itself](#running-the-bundled-example-against-itself)

## Requirements

Install [mise](https://mise.jdx.dev/) first.
The project configuration pins Ruby 4.0.7, Temurin JDK 21 for GoGui, and jq.
On macOS or Linux, you also need C and C++ compilers, `make`, `curl`, `tar`, `unzip`, `patch`, and either `shasum` or `sha256sum`.

## Installation

1. Clone the repository: `git clone git@github.com:ujh/evo.git`
2. Run `mise run setup-experiments`.
   This runs the base `setup` task, then downloads and builds pinned versions of [GNU Go](https://www.gnu.org/software/gnugo/), [Brown](https://www.lysator.liu.se/~gunnar/gtp/), [AmiGoGtp](https://amigogtp.sourceforge.net/), and [michi-c2](https://github.com/db3108/michi-c2), and installs [GoGui](https://github.com/Remi-Coulom/gogui) 1.6.0.
   The archives come from this repository's own GitHub release, a copy of the upstream files, and are checked against SHA-256 hashes; GNU Go and michi-c2 are patched (`scripts/patches/`).
   The programs stay under `.local/evo-tools/`, and mise puts them on `PATH` for project tasks.
3. Run `mise run verify` to run the C and Ruby tests and the smoke checks: refereed 9×9 matches with every external program and Evo, games through the arena (the C program that plays and scores tournament games), and a comparison of the arena's games with GoGui's.

For development without the external programs, use `mise run setup` and `mise run test` (or `test-c` and `test-ruby` on their own).
Other useful tasks are `mise run build`, `mise run clean`, `mise run doctor`, `mise run smoke`, `mise run profile-workload` (the fixed workloads in `docs/performance.md`), and `mise run archive-experiment NAME`, which shrinks a finished experiment to its kept generations' champions, irreversibly.
[Code reference](docs/code-reference.md) has the build and CI details.

## Running the evolution of the neural net

1. Run `mise run run EXPERIMENT_NAME` and answer the setup questions.
2. Restart an interrupted experiment with the same command.
3. View results with `mise run stats EXPERIMENT_NAME` (see [Statistics](#statistics)).

You can pass the runner's options after the name, for example `mise run run EXPERIMENT_NAME --concurrency 2 --one-generation`, or `--until-generation 100` to stop once generation 100 is finished.
`mise run new-experiment` without arguments lists every setting and its default.

The networks play each other and a ladder of bots: Brown, AmiGo, three levels of michi-c2 between AmiGo and GNU Go, and GNU Go at levels 0 and 10.
The michi levels were calibrated on 9×9 only, so an experiment with them refuses every other board size.
[Experiment reference](docs/experiment-reference.md) has the commands, the calibration, and how the runner works.

Each network carries its own settings as genes, which evolve with its weights: its activations, its shape, and its mutation settings.
[The evolving genome](docs/genes.md) explains the genes, how a child is made, and how to read the genome tables in `stats`.

Networks also get hand-coded Go knowledge (good 3×3 shapes, captures, self-atari, saving a chain from atari, the opponent's last move, and chain liberties), as extra inputs and as feature weights that evolve too.
The `features` setting picks the groups: `all` (the default), `none` (stones and komi only), or a list such as `tactics,liberties`.
[Go features](docs/features.md) explains each feature; [Findings](docs/findings.md) has what a comparison with a stones-only run showed, and what the other experiments found.

## Benchmark

Tournament scores only compare the networks of one generation, so they cannot show whether evolution makes progress.
At every checkpoint (every `keep_every`-th generation, including generation 0), the generation's top network plays a fixed panel: the seven bots, generation 0's champion, and the champions of the last `benchmark_champions` checkpoints.
The bots also play each other once per experiment.
`benchmark_games`, `benchmark_champions`, `benchmark_bot_games`, and `benchmark_opening_moves` control it; [Experiment reference](docs/experiment-reference.md), Benchmark, explains them.

The panel is stored in each experiment's database (table `benchmark_opponents`) when the experiment is created.
To use another panel, create the experiment with `mise run new-experiment EXPERIMENT_NAME ...`, change the table before the first `mise run run`, for example `sqlite3 experiments/EXPERIMENT_NAME/experiment.sqlite3 "DELETE FROM benchmark_opponents WHERE name = 'GnuGoLevel0'"`, and leave it alone afterwards: a panel changed during a run makes its checkpoints incomparable.
A bot row has `kind` `bot` and the `command` that starts it; `initial_champion` and `past_champions` rows have no command.

## Statistics

`stats` reads the experiment database read-only, so it can run while the experiment does:

- `mise run stats EXPERIMENT_NAME` prints the tables once.
- `mise run stats EXPERIMENT_NAME --watch` redraws a few tables every 5 seconds until Ctrl-C; add `--extended` to redraw every table, every 30 seconds.
- `mise run stats EXPERIMENT_NAME --csv` prints one row per generation with every figure, for a spreadsheet.

The first table shows whether evolution is healthy: each generation's games, draws, and time, the share of bred children identical to a parent, the distinct parents and genomes, and the lowest, median, and highest network score.
The last table shows progress: a Bradley–Terry rating in Elo of every benchmark player, AmiGo at 0, fitted over every checkpoint's benchmark games and the bots' games against each other, with its ± of about 95 %, the games, and the points per game.
For example, after two generations of `mise run new-experiment NAME --board-size 9 --population-size 4 --hidden-layers 1 --layer-size 10 --cross-over-rate 0.5 --game-seconds 600 --max-moves 200 --tournament-rounds 1 --keep-every 1 --benchmark-games 2 --benchmark-bot-games 2 --seed 3` (trimmed to the first and last table; the times vary, and the example predates GNU Go level 10, so its panel lacks `GnuGoLevel10`):

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

Between the two, for the latest 10 generations, five tables show how the genomes evolve; [The evolving genome](docs/genes.md) explains them, and [Experiment reference](docs/experiment-reference.md) every figure.
Compare generations by the benchmark, not by the tournament scores.

## Running the bundled example against itself

Run `mise run example` to open a GoGui match with the bundled network playing both colors.
