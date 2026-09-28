#!/bin/sh
set -eu

# Checks the arena's bot controller (engine/bot.c) against the real bots,
# through engine/botdriver: Brown, AmiGoGtp, GNU Go level 0, and Evo each
# start from their stored command line, answer the setup (time_settings
# only where known_command says so: Brown and AmiGo reject time commands),
# genmove, play, and quit; bot-against-bot games relayed through the
# controller finish; a seeded GNU Go game repeats exactly in new
# processes; and SIGTERM with bots running kills them and gives status
# 143 under sh -c and sh -c 'exec ...'. The C tests (engine/bottest.sh)
# cover the rest with a fake bot; this is where real bots run, locally
# and in CI's smoke-matches job.

root=$(cd "$(dirname "$0")/.." && pwd)
driver="$root/engine/botdriver"
evo="$root/engine/evo"
for program in "$driver" "$evo"; do
  if [ ! -x "$program" ]; then
    printf 'build %s first (mise run build)\n' "$program" >&2
    exit 1
  fi
done

scratch=$(mktemp -d "${TMPDIR:-/tmp}/evo-bot-controller.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
trap 'exit 1' HUP INT TERM
T=$(printf '\t')
failed=0
fail() {
  printf '%s\n' "$*" >&2
  failed=1
}

gnugo='gnugo --level 0 --mode gtp --seed 11'
evo_bot="$evo $root/engine/example.ann"

# check NAME COMMAND KNOWN: one bot through every call the arena makes.
# KNOWN is 1 when the bot supports time_settings.
check() {
  name=$1 command=$2 known=$3
  printf '%s\n' "start a $command" "known a 10 time_settings" "setup a 10 9 6.5 600" "genmove a 10 b 9" \
    "send a 10 play w pass" "genmove a 10 b 9" "send a 10 no_such_command" "setup a 10 9 7 600" "quit a 10" |
    "$driver" script >"$scratch/$name" 2>"$scratch/$name.err" || true
  got=$(cut -f1,2 "$scratch/$name" | tr '\n' ' ')
  want="start${T}ok known${T}ok setup${T}ok genmove${T}ok send${T}ok genmove${T}ok send${T}error setup${T}ok quit${T}answered "
  if [ "$got" != "$want" ]; then
    fail "$name: unexpected results:
$(cat "$scratch/$name" "$scratch/$name.err")"
    return
  fi
  if [ "$(sed -n 2p "$scratch/$name" | cut -f4)" != "$known" ]; then
    fail "$name: known_command time_settings: expected $known, got $(sed -n 2p "$scratch/$name" | cut -f4)"
  fi
  for line in 4 6; do
    case $(sed -n "${line}p" "$scratch/$name" | cut -f4) in
      'point '* | pass) ;;
      *) fail "$name: genmove gave $(sed -n "${line}p" "$scratch/$name")" ;;
    esac
  done
  printf '%s: setup, genmove, play, and quit answered (time_settings known: %s)\n' "$name" "$known"
}
check brown brown 0
check amigo amigogtp 0
check gnugo0 "$gnugo" 1
check evo "$evo_bot" 0

# A bot that rejects time commands answers time_settings with an error,
# which is why setup asks known_command first.
printf '%s\n' 'start a brown' 'send a 10 time_settings 600 0 0' 'quit a 10' | "$driver" script >"$scratch/time" 2>&1 || true
if [ "$(sed -n 2p "$scratch/time" | cut -f2)" != error ]; then
  fail "brown: expected time_settings to be rejected: $(cat "$scratch/time")"
fi

# game NAME BLACK WHITE: a relayed game that finishes.
game() {
  if "$driver" game 9 6.5 200 600 10 "$2" "$3" >"$scratch/$1" 2>"$scratch/$1.err"; then
    printf '%s: %s after %s moves\n' "$1" "$(tail -1 "$scratch/$1" | cut -f2)" "$(tail -1 "$scratch/$1" | cut -f3)"
  else
    fail "$1: the game failed: $(grep '^fail' "$scratch/$1" || true) $(cat "$scratch/$1.err")"
  fi
}
game brown-amigo brown amigogtp
game gnugo0-brown "$gnugo" brown
game amigo-gnugo0 amigogtp "$gnugo"
game evo-brown "$evo_bot" brown
game gnugo0-brown-again "$gnugo" brown
if [ "$(tail -1 "$scratch/gnugo0-brown")" != "$(tail -1 "$scratch/gnugo0-brown-again")" ]; then
  fail "gnugo0-brown: the same seeded game differs in new processes"
fi

# SIGTERM while bots run: they are killed, and the status is 143 whether
# the driver runs under sh -c or sh -c 'exec ...'.
signal_case() {
  name=$1 exec=$2
  printf '%s\n' 'start a brown' "start b $gnugo" 'send a 10 name' 'send b 10 name' "pid $scratch/$name.pid" 'wait 60' \
    >"$scratch/$name.in"
  sh -c "$exec'$driver' script <'$scratch/$name.in' >'$scratch/$name' 2>'$scratch/$name.err'" 2>/dev/null &
  job=$!
  n=0
  until [ -s "$scratch/$name.pid" ]; do
    n=$((n + 1))
    if [ "$n" -gt 100 ]; then
      fail "$name: the driver did not start"
      kill "$job" 2>/dev/null || true
      return
    fi
    sleep 0.1
  done
  bots=$(sed -n 's/^start.*pid=//p' "$scratch/$name")
  kill -TERM "$(cat "$scratch/$name.pid")"
  status=0
  { wait "$job" || status=$?; } 2>/dev/null
  [ "$status" -eq 143 ] || fail "$name: expected status 143, got $status"
  for pid in $bots; do
    if kill -0 "$pid" 2>/dev/null; then
      fail "$name: bot $pid still runs"
      kill -9 "$pid" 2>/dev/null || true
    fi
  done
}
signal_case sigterm ''
signal_case sigterm-exec 'exec '

if [ "$failed" -ne 0 ]; then
  printf 'Bot controller smoke check failed\n' >&2
  exit 1
fi
printf 'The bot controller drove Brown, AmiGoGtp, GNU Go, and Evo, and cleaned up after SIGTERM\n'
