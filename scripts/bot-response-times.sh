#!/bin/sh
set -eu

# Reports the worst response times of the real bots to the commands the
# arena's fixed response deadline bounds (setup, play, quit), to check
# that deadline's margin: sh scripts/bot-response-times.sh [GAMES [LANES
# [DEADLINE]]].
#
# The tournament's bots, with the default opponents' commands
# (ruby/setup_experiment.rb): Brown, AmiGoGtp, michi-c2 at MichiStrong's
# playouts (the most of the three levels), and GNU Go level 0 with
# --capture-all-dead play GAMES (default 20) relayed 9x9 games through
# engine/botdriver for each ordered pairing (12 pairings), LANES (default
# 4) games at a time, as a tournament runs several chunks at once, each
# michi and GNU Go game with its own seed. It prints, per bot, the
# worst time of its setup (known_command, boardsize, clear_board, komi,
# and time_settings together, the first of them including the bot's
# start, so an upper bound for any one of them), play, genmove, and quit,
# and exits 1 if any setup, play, or quit time is within a factor of 10
# of DEADLINE (default 10 s, the value the runner passes), or at once if
# any game failed. Run it under
# the machine's normal load: it checks a margin, not a recorded number.

root=$(cd "$(dirname "$0")/.." && pwd)
driver="$root/engine/botdriver"
if [ ! -x "$driver" ]; then
  printf 'build %s first (mise run build)\n' "$driver" >&2
  exit 1
fi
games=${1:-20}
lanes=${2:-4}
deadline=${3:-10}

scratch=$(mktemp -d "${TMPDIR:-/tmp}/evo-bot-times.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
trap 'exit 1' HUP INT TERM

# The bot of a short name, with michi's and GNU Go's seed from the game
# number.
command_of() {
  case $1 in
    brown) printf 'brown' ;;
    amigo) printf 'amigogtp' ;;
    michi) printf 'michi gtp --sims 1200 --play-until-end --seed %s' "$2" ;;
    gnugo0) printf 'gnugo --level 0 --mode gtp --capture-all-dead --seed %s' "$2" ;;
  esac
}
bots='brown amigo michi gnugo0'
pairings=$(for b in $bots; do for w in $bots; do [ "$b" = "$w" ] || printf '%s:%s ' "$b" "$w"; done; done)
pairing_count=$(printf '%s\n' $pairings | wc -l | tr -d ' ')

# lane K: plays every game whose number is K modulo LANES.
lane() {
  k=0
  for pairing in $pairings; do
    black=${pairing%:*}
    white=${pairing#*:}
    n=0
    while [ "$n" -lt "$games" ]; do
      if [ $((k % lanes)) -eq "$1" ]; then
        out="$scratch/game-$k"
        if ! "$driver" game 9 6.5 200 600 "$deadline" "$(command_of "$black" "$k")" "$(command_of "$white" "$k")" \
          >"$out" 2>"$out.err"; then
          printf '%s-%s game %d: %s\n' "$black" "$white" "$k" "$(grep '^fail' "$out" || cat "$out.err")" \
            >"$out.failed"
        fi
        awk -F '\t' -v black="$black" -v white="$white" '
          $1 == "black" || $1 == "white" { print ($1 == "black" ? black : white) "\t" $2 "\t" $3 "\t" $4 }
        ' "$out" >"$out.times"
      fi
      k=$((k + 1))
      n=$((n + 1))
    done
  done
}

start=$(date +%s)
pids=''
lane_k=0
while [ "$lane_k" -lt "$lanes" ]; do
  lane "$lane_k" &
  pids="$pids $!"
  lane_k=$((lane_k + 1))
done
status=0
for pid in $pids; do
  wait "$pid" || status=1
done
# A failed game (a bot that cannot start, a failed call, an invalid move)
# fails the check: its times say nothing about the margin.
failures=$(cat "$scratch"/game-*.failed 2>/dev/null | wc -l | tr -d ' ')
if [ "$failures" -ne 0 ]; then
  printf '%d of %d games failed:\n' "$failures" $((games * pairing_count))
  sed 's/^/  /' "$scratch"/game-*.failed
  exit 1
fi

printf '%d games (%d per pairing, %d at a time) in %d s; load average: %s\n' $((games * pairing_count)) "$games" "$lanes" \
  $(($(date +%s) - start)) "$(uptime | sed 's/.*load average[s]*: //')"
cat "$scratch"/game-*.times | awk -F '\t' -v deadline="$deadline" '
  $3 != "ok" { failures++ }
  {
    key = $1 SUBSEP $2
    if (!(key in worst) || $4 > worst[key]) worst[key] = $4
    count[key]++
    bots[$1] = 1
  }
  END {
    printf "%-7s %9s %9s %9s %9s   (worst seconds; calls)\n", "bot", "setup", "play", "genmove", "quit"
    for (bot in bots) {
      line = sprintf("%-7s", bot)
      for (k = 1; k <= 4; k++) {
        kind = k == 1 ? "setup" : k == 2 ? "play" : k == 3 ? "genmove" : "quit"
        key = bot SUBSEP kind
        line = line sprintf(" %9.4f", worst[key] + 0)
        calls = calls sprintf(" %s=%d", kind, count[key])
        if (kind != "genmove" && worst[key] > overall) { overall = worst[key]; which = bot " " kind }
      }
      print line "  " calls
      calls = ""
    }
    printf "worst setup/play/quit: %.4f s (%s); the deadline %s s is %.0f times that\n", overall, which, deadline,
      (overall > 0 ? deadline / overall : 0)
    if (failures) printf "%d calls failed\n", failures
    if (failures || overall * 10 >= deadline) exit 1
  }
' || status=1
exit "$status"
