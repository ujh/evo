#!/bin/sh
set -eu

black='./engine/evo ./engine/example.ann'
white='./engine/evo ./engine/example.ann'
referee='gnugo --mode gtp'
twogtp="gogui-twogtp -black \"$black\" -white \"$white\" -referee \"$referee\" -games 10 -size 9 -alternate -sgffile evo"

exec gogui -size 9 -program "$twogtp" -computer-both -auto
