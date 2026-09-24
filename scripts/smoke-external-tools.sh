#!/bin/sh
set -eu

scratch=$(mktemp -d "${TMPDIR:-/tmp}/evo-runtime-smoke.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM

gogui-twogtp -black brown -white amigogtp \
  -referee 'gnugo --mode gtp' -games 1 -size 9 -auto \
  -sgffile "$scratch/match"

awk -F '\t' '
  !/^#/ {
    games++
    if ($12 != 0 || $2 == "?" || $2 == "") exit 1
  }
  END { if (games != 1) exit 1 }
' "$scratch/match.dat"
printf 'GoGui match completed with Brown, AmiGoGtp, and GNU Go\n'
