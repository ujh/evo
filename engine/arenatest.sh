#!/bin/sh
set -eu

# Checks the arena: its arguments, its schedule, the end of a game (two
# passes in a row, or max_moves + 1 moves, as twogtp ends one), its output
# lines, and that a network plays the same moves as through evo's GTP.
#
# Most games use hand-made 5x5 networks without hidden layers whose moves
# follow from the rules alone, so they are the same on every machine:
# pass.ann always passes, play.ann plays the first allowed point (row 5
# left to right, then row 4, and so on), and komi.ann passes exactly when
# its komi input is positive (komi for white, -komi for black). Networks
# from initial-population are compared with evo instead of pinned moves.

cd "$(dirname "$0")"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0

fail() {
  printf '%s\n' "$*" >&2
  failed=1
}

# A 5x5 network with no hidden layer and linear outputs: every weight is 0
# except the pass output's bias weight ($2) and its komi weight ($3), each
# given as the octal escapes of a little-endian double.
network() {
  {
    printf 'EVOANN'
    printf '\001\000\000\000'   # format version 1
    printf '\032\000\000\000'   # 26 inputs
    printf '\000\000\000\000'   # no hidden layers
    printf '\000\000\000\000'   # no hidden neurons
    printf '\032\000\000\000'   # 26 outputs
    printf '\001\000\000\000'   # hidden activation: sigmoid (unused)
    printf '\004\000\000\000'   # output activation: linear
    # 25 point outputs of 27 weights each (bias, komi, 25 points), all 0.
    head -c $((25 * 27 * 8)) /dev/zero
    printf "$2$3"
    head -c $((25 * 8)) /dev/zero
  } >"$tmp/$1"
}
zero='\000\000\000\000\000\000\000\000'
one='\000\000\000\000\000\000\360\077'
minus_one='\000\000\000\000\000\000\360\277'
# GENANN multiplies the bias weight by -1.
network pass.ann "$minus_one" "$zero"
network play.ann "$one" "$zero"
network komi.ann "$zero" "$one"
printf 'not a network' >"$tmp/garbage.ann"

# Replaces the times, which differ from run to run.
strip_times() {
  sed -E 's/(time_black|time_white|duration)=[0-9]+\.[0-9]{6}/\1=T/g'
}

# arena_ok NAME ARGS...: runs the arena, which must exit 0, into $tmp/NAME.
arena_ok() {
  name=$1
  shift
  status=0
  ./arena "$@" >"$tmp/$name" 2>"$tmp/$name.err" || status=$?
  if [ "$status" -ne 0 ]; then
    fail "$name: expected exit status 0, got $status: $(cat "$tmp/$name.err")"
  fi
}

# expect_line NAME ID WANT: the line for game ID, times stripped, is WANT.
expect_line() {
  got=$(strip_times <"$tmp/$1" | grep "^$2	" || true)
  if [ "$got" != "$3" ]; then
    fail "$1, game $2:
  expected $3
  got      $got"
  fi
}

T='	'
schedule="$tmp/schedule"
cat >"$schedule" <<EOF
pp $tmp/pass.ann $tmp/pass.ann
lp $tmp/play.ann $tmp/pass.ann
pl $tmp/pass.ann $tmp/play.ann
kk $tmp/komi.ann $tmp/komi.ann
missing $tmp/missing.ann $tmp/pass.ann
size $tmp/pass.ann example.ann
both $tmp/garbage.ann example.ann
EOF
arena_ok main 5 6.5 10 "$schedule"

# Two passes in a row end the game; both count as moves. The empty board
# is white's by komi.
expect_line main pp "pp${T}result=W+6.5${T}end=passes${T}length=2${T}time_black=T${T}time_white=T${T}duration=T${T}moves=pass,pass${T}ok"
# With max_moves 10 twogtp still asks for move 11, so a game that does not
# end by passes has 11 moves. Passes between moves count and end nothing.
# Black's six stones own the whole board: 25 - 6.5.
expect_line main lp "lp${T}result=B+18.5${T}end=limit${T}length=11${T}time_black=T${T}time_white=T${T}duration=T${T}moves=A5,pass,B5,pass,C5,pass,D5,pass,E5,pass,A4${T}ok"
expect_line main pl "pl${T}result=W+31.5${T}end=limit${T}length=11${T}time_black=T${T}time_white=T${T}duration=T${T}moves=pass,A5,pass,B5,pass,C5,pass,D5,pass,E5,pass${T}ok"
# Komi reaches the network: with komi 6.5 black's komi input is -6.5, so
# black plays and white passes.
expect_line main kk "kk${T}result=B+18.5${T}end=limit${T}length=11${T}time_black=T${T}time_white=T${T}duration=T${T}moves=A5,pass,B5,pass,C5,pass,D5,pass,E5,pass,A4${T}ok"
# A network that cannot play is named, and no game is played.
expect_line main missing "missing${T}error=black${T}message=cannot open $tmp/missing.ann${T}ok"
expect_line main size "size${T}error=white${T}message=example.ann does not fit a 5x5 board${T}ok"
expect_line main both "both${T}error=both${T}message=$tmp/garbage.ann holds no network; example.ann does not fit a 5x5 board${T}ok"

# One line per game, in schedule order, then the trailer.
got=$(cut -f1 "$tmp/main" | tr '\n' ' ')
if [ "$got" != "pp lp pl kk missing size both done 7 " ]; then
  fail "main: expected the games in order and 'done 7', got: $got"
fi

# With komi -6.5 the komi network plays the other way round.
printf 'kk %s %s\n' "$tmp/komi.ann" "$tmp/komi.ann" >"$tmp/komi-schedule"
arena_ok negative 5 -6.5 10 "$tmp/komi-schedule"
expect_line negative kk "kk${T}result=W+18.5${T}end=limit${T}length=11${T}time_black=T${T}time_white=T${T}duration=T${T}moves=pass,A5,pass,B5,pass,C5,pass,D5,pass,E5,pass${T}ok"

# Two passes end the game even as its last allowed move; max_moves 0
# allows one move.
printf 'pp %s %s\nlp %s %s\n' "$tmp/pass.ann" "$tmp/pass.ann" "$tmp/play.ann" "$tmp/pass.ann" >"$tmp/short-schedule"
arena_ok one 5 6.5 1 "$tmp/short-schedule"
expect_line one pp "pp${T}result=W+6.5${T}end=passes${T}length=2${T}time_black=T${T}time_white=T${T}duration=T${T}moves=pass,pass${T}ok"
arena_ok zero 5 6.5 0 "$tmp/short-schedule"
expect_line zero lp "lp${T}result=B+18.5${T}end=limit${T}length=1${T}time_black=T${T}time_white=T${T}duration=T${T}moves=A5${T}ok"

# Times are seconds with six decimals.
if ! grep -Eq "^pp${T}.*time_black=[0-9]+\.[0-9]{6}${T}time_white=[0-9]+\.[0-9]{6}${T}duration=[0-9]+\.[0-9]{6}${T}" "$tmp/main"; then
  fail "main: times are not seconds with six decimals: $(head -1 "$tmp/main")"
fi

# The same schedule gives the same output apart from the times.
arena_ok again 5 6.5 10 "$schedule"
strip_times <"$tmp/main" >"$tmp/main.stripped"
strip_times <"$tmp/again" >"$tmp/again.stripped"
if ! cmp -s "$tmp/main.stripped" "$tmp/again.stripped"; then
  fail "two runs of the same schedule differ"
fi

# A network plays the same moves as through evo's GTP. With the same
# network on both colors, one evo process can play the whole game.
# same_as_evo SIZE KOMI MAX NETWORK
same_as_evo() {
  printf 'g %s %s\n' "$4" "$4" >"$tmp/evo-schedule"
  arena_ok evo-game "$1" "$2" "$3" "$tmp/evo-schedule"
  moves=$(sed -n 's/.*	moves=\([^	]*\)	ok$/\1/p' "$tmp/evo-game")
  length=$(sed -n 's/.*	length=\([0-9]*\)	.*/\1/p' "$tmp/evo-game")
  {
    printf 'boardsize %s\nkomi %s\nclear_board\n' "$1" "$2"
    k=0
    while [ "$k" -lt "$length" ]; do
      if [ $((k % 2)) -eq 0 ]; then printf 'genmove b\n'; else printf 'genmove w\n'; fi
      k=$((k + 1))
    done
    printf 'quit\n'
  } >"$tmp/evo-commands"
  evo_moves=$(./evo "$4" <"$tmp/evo-commands" 2>/dev/null | grep '^= .' | sed 's/^= //' |
    sed 's/ *$//' | tr '[:upper:]' '[:lower:]' | tr '\n' ',' | sed 's/,$//')
  arena_moves=$(printf '%s' "$moves" | tr '[:upper:]' '[:lower:]')
  if [ -z "$moves" ] || [ "$arena_moves" != "$evo_moves" ]; then
    fail "$4 on ${1}x$1, komi $2: arena and evo differ:
  arena $arena_moves
  evo   $evo_moves"
  fi
}

population="$tmp/population"
mkdir "$population"
generator="$PWD/../initial-population/initial-population"
if [ ! -x "$generator" ]; then
  printf 'build %s first (make from the repository root)\n' "$generator" >&2
  exit 1
fi
(cd "$population" && "$generator" 3 5 1 10 42 >/dev/null)
same_as_evo 9 6.5 60 example.ann
same_as_evo 9 -6.5 60 example.ann
same_as_evo 5 6.5 40 "$tmp/komi.ann"
same_as_evo 5 -6.5 40 "$tmp/komi.ann"
for n in 0001 0002 0003; do
  same_as_evo 5 6.5 40 "$population/$n.ann"
  same_as_evo 5 0 40 "$population/$n.ann"
done

# Many networks in one schedule: each is loaded once, and every game's
# line is the one the game gets when played alone.
: >"$tmp/many-schedule"
for a in 0001 0002 0003; do
  for b in 0001 0002 0003; do
    if [ "$a" != "$b" ]; then
      printf '%s-%s %s %s\n' "$a" "$b" "$population/$a.ann" "$population/$b.ann" >>"$tmp/many-schedule"
    fi
  done
  printf 'play-%s %s %s\n' "$a" "$tmp/play.ann" "$population/$a.ann" >>"$tmp/many-schedule"
done
arena_ok many 5 6.5 40 "$tmp/many-schedule"
strip_times <"$tmp/many" >"$tmp/many.stripped"
while read -r id black white; do
  printf '%s %s %s\n' "$id" "$black" "$white" >"$tmp/alone-schedule"
  arena_ok alone 5 6.5 40 "$tmp/alone-schedule"
  want=$(strip_times <"$tmp/alone" | head -1)
  expect_line many.stripped "$id" "$want"
done <"$tmp/many-schedule"
if [ "$(tail -1 "$tmp/many")" != "done 9" ]; then
  fail "many: expected 'done 9', got: $(tail -1 "$tmp/many")"
fi

# Bad arguments, an unreadable schedule, or a malformed schedule line stop
# the arena with exit status 1 and a message, before any game.
refuses() {
  what=$1
  shift
  status=0
  ./arena "$@" >"$tmp/refused" 2>"$tmp/refused.err" </dev/null || status=$?
  if [ "$status" -ne 1 ]; then
    fail "$what: expected exit status 1, got $status"
  elif [ ! -s "$tmp/refused.err" ]; then
    fail "$what: no message on stderr"
  elif [ -s "$tmp/refused" ]; then
    fail "$what: wrote to stdout: $(cat "$tmp/refused")"
  fi
}
refuses 'no arguments'
refuses 'three arguments' 5 6.5 10
refuses 'five arguments' 5 6.5 10 "$schedule" extra
refuses 'size 1' 1 6.5 10 "$schedule"
refuses 'size 24' 24 6.5 10 "$schedule"
refuses 'size 5x' 5x 6.5 10 "$schedule"
refuses 'komi abc' 5 abc 10 "$schedule"
refuses 'komi 6.5x' 5 6.5x 10 "$schedule"
refuses 'komi nan' 5 nan 10 "$schedule"
refuses 'komi inf' 5 inf 10 "$schedule"
refuses 'empty komi' 5 '' 10 "$schedule"
refuses 'max_moves -1' 5 6.5 -1 "$schedule"
refuses 'max_moves 1.5' 5 6.5 1.5 "$schedule"
refuses 'missing schedule' 5 6.5 10 "$tmp/no-schedule"
bad_schedule() {
  printf "$2" >"$tmp/bad-schedule"
  refuses "$1" 5 6.5 10 "$tmp/bad-schedule"
}
bad_schedule 'two fields' "a $tmp/pass.ann\n"
bad_schedule 'four fields' "a $tmp/pass.ann $tmp/pass.ann x\n"
bad_schedule 'blank line' "a $tmp/pass.ann $tmp/pass.ann\n\nb $tmp/pass.ann $tmp/pass.ann\n"
bad_schedule 'duplicate id' "a $tmp/pass.ann $tmp/pass.ann\na $tmp/play.ann $tmp/pass.ann\n"
bad_schedule 'malformed later line' "a $tmp/pass.ann $tmp/pass.ann\nb $tmp/pass.ann\n"

# An empty schedule plays nothing.
: >"$tmp/empty-schedule"
arena_ok empty 5 6.5 10 "$tmp/empty-schedule"
if [ "$(cat "$tmp/empty")" != "done 0" ]; then
  fail "empty schedule: expected 'done 0', got: $(cat "$tmp/empty")"
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi
printf 'The arena played, ended, and reported its games as expected, and refused bad input\n'
