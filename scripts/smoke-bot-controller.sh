#!/bin/sh
set -eu

# Checks the arena's bot controller (engine/bot.c) against the real bots,
# through engine/botdriver: Brown, AmiGoGtp, GNU Go level 0, michi-c2, and
# Evo each start from their stored command line, answer the setup
# (time_settings only where known_command says so: Brown and AmiGo reject
# time commands), genmove, play, and quit; bot-against-bot games relayed
# through the controller finish; a seeded GNU Go game repeats exactly in
# new processes; SIGTERM with bots running kills them and gives status 143
# under sh -c and sh -c 'exec ...'; the arena plays a --mixed chunk with
# networks and bots, michi-c2 among them, and the same chunk repeats in a
# new arena; its games with Brown, AmiGo, GNU Go and michi-c2 repeat
# twogtp's moves; and michi-c2 keeps the behaviour evo's patch gives it
# (scripts/patches/): another seed gives other moves, time commands do not
# change its moves, and the positions that crashed it or that it refused
# replay. The C tests (engine/bottest.sh)
# cover the rest with a fake bot; this is where real bots run, locally
# and in CI's smoke-matches job.

root=$(cd "$(dirname "$0")/.." && pwd)
driver="$root/engine/botdriver"
evo="$root/engine/evo"
for program in "$driver" "$evo" "$root/engine/arena"; do
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
michi='michi gtp --sims 100 --seed 11'
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
check michi "$michi" 1
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

# The arena plays a --mixed chunk with the real bots on its own board:
# example.ann against Brown, AmiGo, GNU Go level 0 and michi-c2 with
# either color, and the bots against each other (GNU Go and michi-c2
# against Brown and AmiGo: both refuse a suicide play, so this also checks
# that Brown and AmiGo never send one), each game with fresh bot processes
# and GNU Go and michi-c2 seeded per game. The chunk completes with its
# trailer, every game played; the same chunk in a new arena gives the same
# games.
games=18
mixed_chunk() {
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
  status=0
  "$root/engine/arena" --mixed 9 6.5 200 600 10 10 "$scratch/mixed.manifest" >"$scratch/$1" 2>"$scratch/$1.err" ||
    status=$?
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
if mixed_chunk mixed && mixed_chunk mixed-again; then
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

# michi-c2 with evo's patch (scripts/patches/michi-c2-d2a4cb8.patch).
# answers FILE: the GTP answers (lines starting = or ?) in FILE.
answers() {
  grep '^[=?]' "$1" || true
}

# Another seed gives other moves: example.ann against michi-c2 at two
# seeds, in one arena chunk (the same seed repeating is checked above).
{
  printf 'network\tnet\t%s\nbot\tmichi\n' "$root/engine/example.ann"
  for seed in 1 2; do
    printf 'game\tseed-%s\tnet\tmichi\ncommand\tseed-%s\twhite\tmichi gtp --sims 100 --seed %s\n' "$seed" "$seed" "$seed"
  done
} >"$scratch/seeds.manifest"
if "$root/engine/arena" --mixed 9 6.5 200 600 10 10 "$scratch/seeds.manifest" >"$scratch/seeds" 2>"$scratch/seeds.err"; then
  first=$(sed -n "s/^seed-1${T}.*${T}moves=\([^${T}]*\)${T}ok\$/\1/p" "$scratch/seeds")
  second=$(sed -n "s/^seed-2${T}.*${T}moves=\([^${T}]*\)${T}ok\$/\1/p" "$scratch/seeds")
  if [ -z "$first" ] || [ "$first" = "$second" ]; then
    fail "michi seeds: seeds 1 and 2 gave the same moves (or none): $first"
  else
    printf 'michi seeds: seeds 1 and 2 played different games\n'
  fi
else
  fail "michi seeds: the arena failed: $(cat "$scratch/seeds" "$scratch/seeds.err")"
fi

# Time commands do not change michi-c2's moves: unpatched, it spends its
# playouts by the clock once it gets time_settings. It plays 30 moves
# against itself without time commands, then with time_settings and a
# time_left of 1 second before every move.
selfplay() {
  printf 'boardsize 9\nclear_board\nkomi 6.5\n'
  [ "$1" = timed ] && printf 'time_settings 1 0 0\n'
  n=0
  while [ "$n" -lt 30 ]; do
    if [ $((n % 2)) -eq 0 ]; then color=b; else color=w; fi
    [ "$1" = timed ] && printf 'time_left %s 1 0\n' "$color"
    printf 'genmove %s\n' "$color"
    n=$((n + 1))
  done
  printf 'quit\n'
}
selfplay untimed | $michi >"$scratch/untimed" 2>&1 || true
selfplay timed | $michi >"$scratch/timed" 2>&1 || true
untimed=$(answers "$scratch/untimed" | grep -v '^= *$' | tr '\n' ' ')
timed=$(answers "$scratch/timed" | grep -v '^= *$' | tr '\n' ' ')
if [ -z "$untimed" ] || [ "$untimed" != "$timed" ] || grep -q '^?' "$scratch/timed"; then
  fail "michi time commands: the moves changed:
  without $untimed
  with    $timed"
else
  printf 'michi time commands: the same %s moves with and without them\n' "$(answers "$scratch/untimed" | grep -vc '^= *$')"
fi

# replay NAME OPTIONS: feeds $scratch/NAME.in to michi-c2 (with OPTIONS
# after gtp) and requires exit status 0.
replay() {
  status=0
  # shellcheck disable=SC2086
  michi gtp $2 <"$scratch/$1.in" >"$scratch/$1" 2>"$scratch/$1.err" || status=$?
  if [ "$status" -ne 0 ]; then
    fail "michi $1: exit status $status: $(tail -3 "$scratch/$1") $(cat "$scratch/$1.err")"
    return 1
  fi
}

# The position that crashed michi-c2 (a pass child written over the end of
# the tree's children array): after the opponent's pass it had few legal
# moves, and genmove read past the array.
moves='A1 A2 B7 B5 F9 D9 J3 G3 J5 J6 F2 E3 H9 J9 H2 H3 B9 B8 G5 H4 B2 A3 E7 C7 H8 G7 E9 E8 J1 B1 H6 F6 B6 A7 D3 D2
H5 H7 B4 J7 F3 F5 B3 C6 G6 J4 D6 F8 D1 G9 C3 A6 G2 G4 C1 J8 E5 E4 A5 A4 E9 G8 G1 J2 A8 A9 C2 E2 E6 C9 H8 H9 D8 F9
C8 D7 G6 D5 J3 F7 E7 E6 B7 B6 D8 C8 G5 H5 E1 F4 A1 A5 C5 C4 B1 H6 D4 F1 B3 E1 D4 D3 C2 C1 C3 B2 A1 B4 C2 C3 G5 G6
J2 H1 J1 J2 H2 G2 F2 F3'
{
  printf 'boardsize 9\nclear_board\nkomi 6.5\n'
  color=b
  for move in $moves; do
    printf 'play %s %s\n' "$color" "$move"
    if [ "$color" = b ]; then color=w; else color=b; fi
  done
  printf 'play b pass\ngenmove w\nquit\n'
} >"$scratch/crash.in"
if replay crash '--sims 150 --seed 1'; then
  if answers "$scratch/crash" | grep -q '^?'; then
    fail "michi crash replay: an error answer: $(answers "$scratch/crash" | grep '^?')"
  else
    printf 'michi crash replay: genmove after the pass answered %s\n' "$(answers "$scratch/crash" | tail -2 | head -1)"
  fi
fi

# A play that repeats an earlier position (positional superko; the arena
# forbids only a simple ko retake) is accepted, while michi-c2's own
# genmove does not repeat one. On 5x5, after 32 passes (michi checks
# repetitions only from move 30 on), black captures the white stone at
# B3 in a ko by C3; both pass, and white's retake at B3 repeats the
# position after white's first B3. It is white's only move that is not
# its own eye, and with komi -5.5 the ko decides the game, so a genmove
# that did not avoid repeats would play it.
{
  printf 'boardsize 5\nclear_board\nkomi -5.5\n'
  n=0
  while [ "$n" -lt 16 ]; do
    printf 'play b pass\nplay w pass\n'
    n=$((n + 1))
  done
  for move in 'b B5' 'w C5' 'b A4' 'w E5' 'b B4' 'w C4' 'b A3' 'w D4' 'b A2' 'w E4' 'b B2' 'w D3' 'b B1' 'w C2' \
    'b pass' 'w D2' 'b pass' 'w E2' 'b pass' 'w C1' 'b pass' 'w E1' 'b pass' 'w B3' 'b C3' 'w pass' 'b pass'; do
    printf 'play %s\n' "$move"
  done
} >"$scratch/ko.in"
{ cat "$scratch/ko.in"; printf 'play w B3\nquit\n'; } >"$scratch/superko-play.in"
{ cat "$scratch/ko.in"; printf 'genmove w\nquit\n'; } >"$scratch/superko-genmove.in"
if replay superko-play ''; then
  if answers "$scratch/superko-play" | grep -q '^?'; then
    fail "michi superko play: refused: $(answers "$scratch/superko-play" | grep '^?')"
  else
    printf 'michi superko play: the repeating play was accepted\n'
  fi
fi
if replay superko-genmove '--sims 100 --seed 1 --play-until-end'; then
  answer=$(answers "$scratch/superko-genmove" | tail -2 | head -1)
  case $answer in
    '= pass' | '= resign') printf 'michi superko genmove: did not repeat the position (%s)\n' "$answer" ;;
    *) fail "michi superko genmove: expected pass or resign, got $answer" ;;
  esac
fi

# The move history holds 10,000 moves, passes included; after that play
# and genmove answer with an error instead of writing past its end.
awk 'BEGIN {
  print "boardsize 9"; print "clear_board"
  for (i = 0; i < 5000; i++) { print "play b pass"; print "play w pass" }
  print "play b pass"; print "genmove b"; print "quit"
}' >"$scratch/history.in"
if replay history '--sims 10'; then
  ok=$(answers "$scratch/history" | grep -c '^=' || true)
  last=$(answers "$scratch/history" | tail -3 | head -2 | cut -c1 | tr -d '\n')
  if [ "$ok" -ne 10003 ] || [ "$last" != '??' ]; then
    fail "michi history: expected 10,000 moves accepted and the next play and genmove refused, got $ok = answers and $last"
  else
    printf 'michi history: 10000 moves accepted, then play and genmove refused\n'
  fi
fi

# No michi.log, no output on stderr, and pattern files in the working
# directory are not loaded: a game there repeats the untimed one above.
mkdir "$scratch/michi-dir"
printf 'garbage\n' >"$scratch/michi-dir/patterns.prob"
printf 'garbage\n' >"$scratch/michi-dir/patterns.spat"
(cd "$scratch/michi-dir" && selfplay untimed | $michi >out 2>err) || true
if [ -e "$scratch/michi-dir/michi.log" ] || [ -s "$scratch/michi-dir/err" ] ||
  [ "$(answers "$scratch/michi-dir/out" | grep -v '^= *$' | tr '\n' ' ')" != "$untimed" ]; then
  fail "michi files: expected no michi.log, no stderr, and the same moves with pattern files present:
$(ls "$scratch/michi-dir") $(cat "$scratch/michi-dir/err")"
else
  printf 'michi files: no log, no stderr, pattern files ignored\n'
fi

# The response-time script fails when a game fails: here no bot can
# start, since the PATH holds none of them.
status=0
env PATH=/usr/bin:/bin sh "$root/scripts/bot-response-times.sh" 1 1 >"$scratch/times" 2>&1 || status=$?
if [ "$status" -eq 0 ] || ! grep -q '^6 of 6 games failed' "$scratch/times"; then
  fail "bot-response-times.sh: expected it to fail with '6 of 6 games failed', got status $status: $(cat "$scratch/times")"
fi

if [ "$failed" -ne 0 ]; then
  printf 'Bot controller smoke check failed\n' >&2
  exit 1
fi
printf 'The bot controller drove Brown, AmiGoGtp, GNU Go, michi-c2, and Evo, and cleaned up after SIGTERM; the arena played them\n'
