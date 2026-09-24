# evo
Artificial intelligence for the game of Go using neural networks and genetic algorithms

_This is an experiment to see if genetic algorithms can be used to evolve a neural network for playing the game of Go. I don't expect this to be a good program anytime soon (or ever), I just want to play around._

## Requirements

Install [mise](https://mise.jdx.dev/) first. The project configuration pins Ruby
3.3.0 and Temurin JDK 21 for GoGui. On macOS or Linux, you also need C and C++
compilers, `make`, `curl`, `tar`, `unzip`, and either `shasum` or `sha256sum`.

## Installation

1. Clone the repository: `git clone git@github.com:ujh/evo.git`
2. Run `mise run setup-experiments`. This runs the base `setup` task, then
   downloads and builds pinned versions of [GNU Go](https://www.gnu.org/software/gnugo/),
   [Brown](https://www.lysator.liu.se/~gunnar/gtp/), and
   [AmiGoGtp](https://amigogtp.sourceforge.net/), and installs
   [GoGui](https://github.com/Remi-Coulom/gogui) 1.6.0. Archives are checked
   against SHA-256 hashes before extraction. The programs stay under
   `.local/evo-tools/` and mise places them on `PATH` for project tasks.
3. Run `mise run verify` to run the C tests and a complete 9×9 match with
   Brown, AmiGoGtp, GoGui, and the GNU Go referee.

CI runs the same setup and verification tasks. For C development without the
external programs, use `mise run setup` and `mise run test`. Other useful tasks
are `mise run build`, `mise run clean`, and `mise run doctor`.

## Running the evolution of the neural net

1. Run `mise run run EXPERIMENT_NAME` and answer the setup questions.
2. Restart an interrupted experiment with the same command.
3. View results with `mise run stats EXPERIMENT_NAME`.

You can pass the existing runner arguments after the name, for example
`mise run run EXPERIMENT_NAME 2 one-generation`. `mise run` supplies the pinned
Ruby and Java versions even without shell activation.

## Running the bundled example against itself

Run `mise run example` to open a GoGui match with the bundled network playing
both colors.
