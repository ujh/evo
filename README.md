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
   program crashes or the GNU Go referee returns no score.

CI runs the same tasks as separate jobs (C tests, Ruby tests, and the
refereed matches), so a failure shows which kind of check broke. For
development without the
external programs, use `mise run setup` and `mise run test` (or `test-c` and
`test-ruby` on their own). Other useful tasks are `mise run build`,
`mise run clean`, `mise run doctor`, and `mise run smoke`.

## Running the evolution of the neural net

1. Run `mise run run EXPERIMENT_NAME` and answer the setup questions.
2. Restart an interrupted experiment with the same command.
3. View results with `mise run stats EXPERIMENT_NAME`.

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
`experiments/EXPERIMENT_NAME/experiment.sqlite3`, one row per game. `stats`
does not show them yet; until it does, query the table, for example:

```sh
sqlite3 experiments/EXPERIMENT_NAME/experiment.sqlite3 \
  'SELECT generation, opponent, winner, count(*) FROM benchmark_games GROUP BY 1, 2, 3'
```

The panel is stored in each experiment's database (table
`benchmark_opponents`) when the experiment is created. To use another panel,
create the experiment with `mise run new-experiment EXPERIMENT_NAME ...`, change
the table before the first `mise run run`, for example
`sqlite3 experiments/EXPERIMENT_NAME/experiment.sqlite3 "DELETE FROM benchmark_opponents WHERE name = 'GnuGoLevel0'"`,
and leave it alone afterwards: a panel changed during a run makes its
checkpoints incomparable. A bot row has `kind` `bot` and the `command` that
starts it; `initial_champion` and `previous_checkpoint` rows have no command.

## Running the bundled example against itself

Run `mise run example` to open a GoGui match with the bundled network playing
both colors.
