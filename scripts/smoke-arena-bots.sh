#!/bin/sh
set -eu

# Checks the arena's games with the real bots: it plays a --mixed chunk
# with networks and Brown, AmiGoGtp, GNU Go level 0, and michi-c2, and the
# same chunk repeats in a new arena; and its games with Brown, AmiGo, GNU
# Go and michi-c2 repeat twogtp's moves. engine/arenatest.sh covers the
# rest with a fake bot; this is where real bots play, locally and in CI's
# smoke (arena) job.

root=$(cd "$(dirname "$0")/.." && pwd)
evo="$root/engine/evo"
for program in "$evo" "$root/engine/arena"; do
  if [ ! -x "$program" ]; then
    printf 'build %s first (mise run build)\n' "$program" >&2
    exit 1
  fi
done

scratch=$(mktemp -d "${TMPDIR:-/tmp}/evo-arena-bots.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
trap 'exit 1' HUP INT TERM
T=$(printf '\t')
failed=0
fail() {
  printf '%s\n' "$*" >&2
  failed=1
}

gnugo='gnugo --level 0 --mode gtp --seed 11'
michi='michi gtp --sims 100 --seed 11'

# The arena plays a --mixed chunk with the real bots on its own board:
# example.ann against Brown, AmiGo, GNU Go level 0 and michi-c2 with
# either color, and the bots against each other (GNU Go and michi-c2
# against Brown and AmiGo: both refuse a suicide play, so this also checks
# that Brown and AmiGo never send one), each game with fresh bot processes
# and GNU Go and michi-c2 seeded per game. The chunk completes with its
# trailer, every game played; the same chunk in a new arena gives the same
# games.
games=18
{
  printf 'network\tnet\t%s\nbot\tbrown\nbot\tamigo\nbot\tgnugo\nbot\tmichi\n' "$root/engine/example.ann"
  seed=100
  for pair in net:brown brown:net net:amigo amigo:net net:gnugo gnugo:net brown:amigo gnugo:brown amigo:gnugo \
    gnugo:gnugo net:michi michi:net michi:brown brown:michi michi:amigo amigo:michi gnugo:michi michi:michi; do
    black=${pair%%:*} white=${pair#*:}
    printf 'game\t%s-%s\t%s\t%s\n' "$black" "$white" "$black" "$white"
    for color in black white; do
      if [ "$color" = black ]; then player=$black; else player=$white; fi
      seed=$((seed + 1))
      case $player in
        brown) printf 'command\t%s-%s\t%s\tbrown\n' "$black" "$white" "$color" ;;
        amigo) printf 'command\t%s-%s\t%s\tamigogtp\n' "$black" "$white" "$color" ;;
        gnugo) printf 'command\t%s-%s\t%s\tgnugo --level 0 --mode gtp --seed %s\n' "$black" "$white" "$color" "$seed" ;;
        michi) printf 'command\t%s-%s\t%s\tmichi gtp --sims 100 --seed %s\n' "$black" "$white" "$color" "$seed" ;;
      esac
    done
  done
} >"$scratch/mixed.manifest"
# run_chunk NAME: the manifest in a new arena, in the background (its pid
# in $! and added to $pids). The two runs play at once. The arena itself is the
# background job, so that the traps below can reach it: an async list of
# a non-interactive shell starts with SIGINT ignored, which the arena then
# keeps, but it stops its bots on SIGTERM.
pids=''
run_chunk() {
  "$root/engine/arena" --mixed 9 6.5 200 600 10 10 "$scratch/mixed.manifest" >"$scratch/$1" 2>"$scratch/$1.err" &
  pids="$pids $!"
}
# check_chunk NAME PID: the run completed with its trailer, every game played.
check_chunk() {
  status=0
  wait "$2" || status=$?
  if [ "$status" -ne 0 ] || [ "$(tail -1 "$scratch/$1")" != "done $games" ]; then
    fail "mixed chunk $1: expected exit status 0 and 'done $games', got $status:
$(cat "$scratch/$1" "$scratch/$1.err")"
    return 1
  fi
  if ! sed '1d;$d' "$scratch/$1" | awk -F'\t' '
    NF != 9 || $2 !~ /^result=([BW]\+([0-9]+(\.[0-9]+)?|R)|0)$/ || $3 !~ /^end=(passes|limit|resign)$/ ||
      $8 !~ /^moves=((pass|[A-HJ-T][1-9])(,(pass|[A-HJ-T][1-9]))*)?$/ { bad = 1 }
    { n++ }
    END { exit bad || n != '"$games"' }'; then
    fail "mixed chunk $1: a game was not played out as expected:
$(cat "$scratch/$1")"
    return 1
  fi
}
trap 'kill $pids 2>/dev/null; exit 1' HUP INT TERM
run_chunk mixed
mixed=$!
run_chunk mixed-again
mixed_again=$!
if check_chunk mixed "$mixed" && check_chunk mixed-again "$mixed_again"; then
  for run in mixed mixed-again; do
    sed -E 's/(time_black|time_white|duration)=[0-9.]+/\1=T/g' "$scratch/$run" >"$scratch/$run.stripped"
  done
  if ! cmp -s "$scratch/mixed.stripped" "$scratch/mixed-again.stripped"; then
    fail "mixed chunk: the same chunk gave other games in a new arena:
$(diff "$scratch/mixed.stripped" "$scratch/mixed-again.stripped" || true)"
  fi
  sed '1d;$d' "$scratch/mixed" | while IFS="$T" read -r id result end length rest; do
    printf 'arena %s: %s, %s, %s\n' "$id" "${result#result=}" "${end#end=}" "${length#length=} moves"
  done
fi

# The arena's bot games repeat twogtp's: the same pairings with the same
# commands, through gogui-twogtp (evo playing the network), give the same
# moves. Brown reseeds its moves on boardsize, so this checks that the
# arena sends twogtp's setup sequence.
# sgf_moves FILE: the moves of an SGF game as the arena writes them.
sgf_moves() {
  grep -o ';[BW]\[[a-z]*\]' "$1" | awk -F'[][]' '
    {
      c = $2
      if (c == "" || c == "tt") v = "pass"
      else v = substr("ABCDEFGHJKLMNOPQRST", index("abcdefghijklmnopqrs", substr(c, 1, 1)), 1) \
        (9 - index("abcdefghijklmnopqrs", substr(c, 2, 1)) + 1)
      printf "%s%s", n++ ? "," : "", v
    }'
}
net="$evo $root/engine/example.ann"
{
  printf 'network\tnet\t%s\nbot\tbot\n' "$root/engine/example.ann"
  printf 'game\tnet-brown\tnet\tbot\ncommand\tnet-brown\twhite\tbrown\n'
  printf 'game\tbrown-net\tbot\tnet\ncommand\tbrown-net\tblack\tbrown\n'
  printf 'game\tgnugo-brown\tbot\tbot\ncommand\tgnugo-brown\tblack\t%s\n' "$gnugo"
  printf 'command\tgnugo-brown\twhite\tbrown\n'
  printf 'game\tbrown-amigo\tbot\tbot\ncommand\tbrown-amigo\tblack\tbrown\n'
  printf 'command\tbrown-amigo\twhite\tamigogtp\n'
  printf 'game\tmichi-brown\tbot\tbot\ncommand\tmichi-brown\tblack\t%s\n' "$michi"
  printf 'command\tmichi-brown\twhite\tbrown\n'
  printf 'game\tnet-michi\tnet\tbot\ncommand\tnet-michi\twhite\t%s\n' "$michi"
} >"$scratch/twogtp.manifest"
if "$root/engine/arena" --mixed 9 6.5 200 600 10 10 "$scratch/twogtp.manifest" >"$scratch/twogtp-arena" \
  2>"$scratch/twogtp-arena.err"; then
  for pair in "net-brown|$net|brown" "brown-net|brown|$net" "gnugo-brown|$gnugo|brown" "brown-amigo|brown|amigogtp" \
    "michi-brown|$michi|brown" "net-michi|$net|$michi"; do
    id=${pair%%|*} rest=${pair#*|}
    black=${rest%%|*} white=${rest#*|}
    gogui-twogtp -black "$black" -white "$white" -size 9 -komi 6.5 -auto -games 1 -time 10 -maxmoves 200 \
      -sgffile "$scratch/$id" >/dev/null 2>"$scratch/$id.twogtp.err" || true
    arena_moves=$(sed -n "s/^$id${T}.*${T}moves=\([^${T}]*\)${T}ok\$/\1/p" "$scratch/twogtp-arena")
    twogtp_moves=$(sgf_moves "$scratch/$id-0.sgf" 2>/dev/null || true)
    if [ -z "$arena_moves" ] || [ "$arena_moves" != "$twogtp_moves" ]; then
      fail "$id: the arena and twogtp played different moves:
  arena  $arena_moves
  twogtp $twogtp_moves
$(cat "$scratch/$id.twogtp.err")"
    else
      printf '%s: the arena and twogtp played the same %s moves\n' "$id" "$(printf '%s\n' "$arena_moves" | tr ',' '\n' | wc -l | tr -d ' ')"
    fi
  done
else
  fail "twogtp comparison: the arena failed: $(cat "$scratch/twogtp-arena" "$scratch/twogtp-arena.err")"
fi

if [ "$failed" -ne 0 ]; then
  printf 'Arena smoke check with real bots failed\n' >&2
  exit 1
fi
printf 'The arena played Brown, AmiGoGtp, GNU Go, michi-c2, and Evo, repeated its games, and matched twogtp\n'
