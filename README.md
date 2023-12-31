# evo
Artificial intelligence for the game of Go using neural networks and genetic algorithms

_This is an experiment to see if genetic algorithms can be used to evolve a neural network for playing the game of Go. I don't expect this to be a good program anytime soon (or ever), I just want to play around._

## Requirements

* [GnuGo](https://www.gnu.org/software/gnugo/)
* [GoGui](https://github.com/Remi-Coulom/gogui)
* [brown](http://www.lysator.liu.se/%7Egunnar/gtp/brown-1.0.tar.gz)
* gcc (or compatible, like clang)
* make

## Installation

1. Clone the repository
2. Set up the submodules using `git submodule init && git submodule update`
3. Build everything using `make`
4. Run the tests using `make test`

## Running the evolution of the neural net

1. Ensure that you have the Ruby version installed as specified in `.ruby-version` (or use rvm or similar to do it automatically).
2. Execute `./runner EXPERIMENT_NAME` and answer the setup questions
3. If you quit you can just restart the experiment with the same command

## Running brown against itself

```
BLACK="./engine/evo"
WHITE="./engine/evo"
REFEREE="gnugo --mode gtp"
TWOGTP="gogui-twogtp -black \"$BLACK\" -white \"$WHITE\" -referee \"$REFEREE\" -games 10 -size 9 -alternate -sgffile evo"
gogui -size 9 -program "$TWOGTP" -computer-both -auto
```
