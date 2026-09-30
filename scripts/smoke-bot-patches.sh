#!/bin/sh
set -eu

# Checks that GNU Go and michi-c2 keep the behaviour evo's patches give
# them (scripts/patches/): the position that overflowed GNU Go's
# superstring liberties replays; and for michi-c2, another seed gives other
# moves, time commands do not change its moves, and the positions that
# crashed it or that it refused replay. Runs locally and in CI's smoke
# (patches) job.

root=$(cd "$(dirname "$0")/.." && pwd)
if [ ! -x "$root/engine/arena" ]; then
  printf 'build %s first (mise run build)\n' "$root/engine/arena" >&2
  exit 1
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/evo-bot-patches.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
trap 'exit 1' HUP INT TERM
T=$(printf '\t')
failed=0
fail() {
  printf '%s\n' "$*" >&2
  failed=1
}

michi='michi gtp --sims 100 --seed 11'

# answers FILE: the GTP answers (lines starting = or ?) in FILE.
answers() {
  grep '^[=?]' "$1" || true
}

# GNU Go with evo's patch (scripts/patches/gnugo-3.8-superstring-libs.patch):
# the position of a tournament game (even-bigger2, generation 64) in which
# its superstring liberties ran past their array. GNU Go at level 10
# aborted in genmove there (at level 0 it got there through the time
# settings, which raise its level); now it answers with a move.
moves='D9 E5 D6 C4 B5 F4 B4 C3 B3 F7 C5 E8 D8 C2 D2 D3 E2 F2 E3 D5 E4 D4 C6 F3 G4 G5 H5 H6 G6 F6 G7'
{
  printf 'boardsize 9\nclear_board\nkomi 6.5\n'
  color=b
  for move in $moves; do
    printf 'play %s %s\n' "$color" "$move"
    if [ "$color" = b ]; then color=w; else color=b; fi
  done
  printf 'genmove w\nquit\n'
} >"$scratch/gnugo-superstring.in"
status=0
(cd "$scratch" && gnugo --mode gtp --level 10 <gnugo-superstring.in >gnugo-superstring 2>gnugo-superstring.err) ||
  status=$?
answer=$(answers "$scratch/gnugo-superstring" | tail -2 | head -1)
if [ "$status" -ne 0 ] || answers "$scratch/gnugo-superstring" | grep -q '^?'; then
  fail "gnugo superstring replay: exit status $status: $(tail -3 "$scratch/gnugo-superstring") $(tail -3 "$scratch/gnugo-superstring.err")"
else
  printf 'gnugo superstring replay: genmove answered %s\n' "$answer"
fi

# michi-c2 with evo's patch (scripts/patches/michi-c2-d2a4cb8.patch).
# Another seed gives other moves: example.ann against michi-c2 at two
# seeds, in one arena chunk (scripts/smoke-arena-bots.sh checks that the
# same seed repeats).
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
(cd "$scratch" && selfplay untimed | $michi >untimed 2>&1) || true
(cd "$scratch" && selfplay timed | $michi >timed 2>&1) || true
untimed=$(answers "$scratch/untimed" | grep -v '^= *$' | tr '\n' ' ')
timed=$(answers "$scratch/timed" | grep -v '^= *$' | tr '\n' ' ')
if [ -z "$untimed" ] || [ "$untimed" != "$timed" ] || grep -q '^?' "$scratch/timed"; then
  fail "michi time commands: the moves changed:
  without $untimed
  with    $timed"
else
  printf 'michi time commands: the same %s moves with and without them\n' "$(answers "$scratch/untimed" | grep -vc '^= *$')"
fi

# played NAME OPTIONS: the moves michi-c2 (with OPTIONS after gtp) plays
# in the 20-move self-play of $scratch/selfplay20.in, run in $scratch.
awk 'BEGIN {
  print "boardsize 9"; print "clear_board"; print "komi 6.5"
  for (i = 0; i < 10; i++) { print "genmove b"; print "genmove w" }
  print "quit"
}' >"$scratch/selfplay20.in"
played() {
  # shellcheck disable=SC2086
  (cd "$scratch" && michi gtp $2 <selfplay20.in >"$1" 2>"$1.err") || true
  answers "$scratch/$1" | grep -v '^= *$' | tr '\n' ' '
}

# --sims sets the playouts: the same seed at 5 and 500 plays other moves.
few=$(played sims-5 '--sims 5 --seed 3')
many=$(played sims-500 '--sims 500 --seed 3')
if [ -z "$few" ] || [ "$few" = "$many" ]; then
  fail "michi --sims: 5 and 500 playouts gave the same moves (or none): $few"
else
  printf 'michi --sims: 5 and 500 playouts played different games\n'
fi

# --seed 0 is a fixed seed, not the clock: two runs play the same moves.
zero=$(played seed-0 '--sims 100 --seed 0')
sleep 1
zero_again=$(played seed-0-again '--sims 100 --seed 0')
if [ -z "$zero" ] || [ "$zero" != "$zero_again" ]; then
  fail "michi --seed 0: two runs played different moves:
  $zero
  $zero_again"
else
  printf 'michi --seed 0: two runs played the same game\n'
fi

# --play-until-end changes play after an opponent's pass (michi-c2 decides
# then whether to pass early): black's moves after white's passes differ.
printf 'boardsize 9\nclear_board\nkomi 6.5\nplay b E5\nplay w pass\nplay b C3\nplay w pass\ngenmove b\nplay w pass\ngenmove b\nquit\n' \
  >"$scratch/until-end.in"
until_end() {
  # shellcheck disable=SC2086
  (cd "$scratch" && michi gtp --sims 200 --seed 1 $2 <until-end.in >"$1" 2>"$1.err") || true
  answers "$scratch/$1" | grep -v '^= *$' | tr '\n' ' '
}
early=$(until_end until-end-off '')
late=$(until_end until-end-on '--play-until-end')
if [ -z "$early" ] || [ "$early" = "$late" ]; then
  fail "michi --play-until-end: the same moves with and without it (or none): $early"
else
  printf 'michi --play-until-end: %swithout it, %swith it\n' "$early" "$late"
fi

# replay NAME OPTIONS: feeds $scratch/NAME.in to michi-c2 (with OPTIONS
# after gtp), in $scratch so that nothing it might write lands in the
# checkout, and requires exit status 0.
replay() {
  status=0
  # shellcheck disable=SC2086
  (cd "$scratch" && michi gtp $2 <"$1.in" >"$1" 2>"$1.err") || status=$?
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

if [ "$failed" -ne 0 ]; then
  printf 'Patched bot smoke check failed\n' >&2
  exit 1
fi
printf 'GNU Go and michi-c2 kept the behaviour of their patches\n'
