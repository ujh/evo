# evo
Artificial intelligence for the game of Go using neural networks and genetic algorithms

_This is an experiment to see if genetic algorithms can be used to evolve a neural network for playing the game of Go. I don't expect this to be a good program anytime soon (or ever), I just want to play around._

## Requirements

* [GnuGo](https://www.gnu.org/software/gnugo/)
* [GoGui](https://github.com/Remi-Coulom/gogui)
* gcc
* make

## TODO

- [ ] Combine the [Brown](http://www.lysator.liu.se/%7Egunnar/gtp/brown-1.0.tar.gz) random Go engine with the [genann](https://github.com/codeplea/genann) neural network library so that it can read a network definiton from file and play a game.
- [ ] Write some scripts to generate NN, run tournaments, do the evolution, etc.
- [ ] Try evolving a engine for 9x9

## Running brown against itself

```
BLACK="./engine/evo"
WHITE="./engine/evo"
REFEREE="gnugo --mode gtp"
TWOGTP="gogui-twogtp -black \"$BLACK\" -white \"$WHITE\" -referee \"$REFEREE\" -games 10 -size 9 -alternate -sgffile evo"
gogui -size 9 -program "$TWOGTP" -computer-both -auto
```