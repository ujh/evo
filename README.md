# evo
Artificial intelligence for the game of Go using neural networks and genetic algorithms

_This is an experiment to see if genetic algorithms can be used to evolve a neural network for playing the game of Go. I don't expect this to be a good program anytime soon (or ever), I just want to play around._

## Requirements

Install [mise](https://mise.jdx.dev/) first. The project configuration pins Ruby
3.3.0 and Temurin JDK 21 for GoGui. You also need a C compiler and `make`.

To run experiments, install these programs separately and put them on `PATH`:

* [GnuGo](https://www.gnu.org/software/gnugo/)
* [GoGui](https://github.com/Remi-Coulom/gogui)
* [brown](http://www.lysator.liu.se/%7Egunnar/gtp/brown-1.0.tar.gz)
* [AmiGoGtp](https://amigogtp.sourceforge.net/)

## Installation

1. Clone the repository: `git clone git@github.com:ujh/evo.git`
2. Run `mise run setup`. This installs the pinned tools, initializes the
   submodule, installs Ruby gems, and builds the C programs.
3. Run `mise run verify` to run the tests and check the programs needed for
   experiments.

CI runs the same `mise run setup` and `mise run test` tasks. Other useful tasks
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
