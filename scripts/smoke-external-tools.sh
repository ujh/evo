#!/bin/sh
set -eu

scratch=$(mktemp -d "${TMPDIR:-/tmp}/evo-runtime-smoke.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM

referee='gnugo --mode gtp'
failed=0

# Play one refereed game and require that neither player failed and that the
# referee scored it. A crashed program only shows up in ERR, and a crashed
# referee only as a missing RES_R, so a finished game alone proves nothing.
# Any further arguments go to twogtp.
match() {
  name=$1
  black=$2
  white=$3
  shift 3
  gogui-twogtp -black "$black" -white "$white" -referee "$referee" \
    -games 1 -size 9 -auto -sgffile "$scratch/$name" "$@" >/dev/null 2>&1 || true

  if [ ! -f "$scratch/$name.dat" ]; then
    printf '%s: no result file\n' "$name" >&2
    failed=1
    return
  fi

  if awk -F '\t' '
    !/^#/ {
      games++
      if ($12 != 0) { printf "error: %s\n", $13; bad = 1 }
      if ($4 !~ /^([BW]\+|0$)/) { printf "referee result: %s\n", $4; bad = 1 }
      printf "%s moves, referee %s\n", $7, $4
    }
    END {
      if (games != 1) { printf "%d games recorded\n", games; bad = 1 }
      exit bad
    }
  ' "$scratch/$name.dat" >"$scratch/$name.out"; then
    printf '%s: %s\n' "$name" "$(cat "$scratch/$name.out")"
  else
    printf '%s failed:\n' "$name" >&2
    sed 's/^/  /' "$scratch/$name.out" >&2
    failed=1
  fi
}

# Each opponent in DEFAULT_OPPONENTS (ruby/setup_experiment.rb) plays at
# least once, and so does the engine itself. GNU Go is not in the tournament,
# only its referee, but it plays here too: it comes back as an opponent later,
# and level 10 move generation checks the gg_sort patch.
match brown-amigo brown amigogtp
match gnugo0-brown 'gnugo --level 0 --mode gtp' brown
match amigo-gnugo10 amigogtp 'gnugo --level 10 --mode gtp'
match evo-brown './engine/evo engine/example.ann' brown

# The benchmark starts its games from a seeded opening through -openings
# (ruby/openings.rb); this one is Openings.moves(1, 0, 9, 4). The game must
# start with exactly these moves and go on past them.
opening=';B[ge];W[de];B[gh];W[fd]'
mkdir "$scratch/openings"
printf '(;GM[1]FF[4]SZ[9]%s)\n' "$opening" >"$scratch/openings/opening.sgf"
match evo-brown-opening './engine/evo engine/example.ann' brown -openings "$scratch/openings"
played=$(awk '
  { s = s $0 }
  END {
    while (match(s, /;[BW]\[[a-s]*\]/)) {
      printf "%s", substr(s, RSTART, RLENGTH)
      s = substr(s, RSTART + RLENGTH)
    }
  }
' "$scratch/evo-brown-opening-0.sgf" 2>/dev/null || true)
case $played in
  "$opening"?*) ;;
  *)
    printf 'evo-brown-opening: game does not start with the opening %s: %.60s\n' "$opening" "$played" >&2
    failed=1
    ;;
esac

if [ "$failed" -ne 0 ]; then
  printf 'GoGui smoke matches failed\n' >&2
  exit 1
fi
printf 'GoGui matches completed with Brown, AmiGoGtp, GNU Go, and Evo\n'
