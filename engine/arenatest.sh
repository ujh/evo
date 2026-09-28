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
# its komi input is positive (komi for white, -komi for black). The
# feature networks capture.ann and careful.ann play like play.ann except
# where their tactics feature weights decide (see tactics_network). Networks
# from initial-population, with and without feature groups, are compared
# with evo instead of pinned moves.

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
    printf '\002\000\000\000'   # format version 2
    printf '\032\000\000\000'   # 26 inputs
    printf '\000\000\000\000'   # no hidden layers
    printf '\000\000\000\000'   # no hidden neurons
    printf '\032\000\000\000'   # 26 outputs
    printf '\001\000\000\000'   # hidden activation: sigmoid (unused)
    printf '\004\000\000\000'   # output activation: linear
    # The genes (unused by the arena): copy_chance 0.01, weight_changes 1,
    # weight_step 0.5, activation_rate 0.02, structure_rate 0.02.
    printf '\173\024\256\107\341\172\204\077'
    printf '\000\000\000\000\000\000\360\077'
    printf '\000\000\000\000\000\000\340\077'
    printf '\173\024\256\107\341\172\224\077'
    printf '\173\024\256\107\341\172\224\077'
    printf '\000\000\000\000'   # no feature groups, so no feature weights
    printf '\173\024\256\107\341\172\204\077'   # feature_step 0.01 (unused)
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

# A 5x5 network with the tactics group and no hidden layer, linear
# outputs, and every network weight 0 except the pass output's bias weight
# 1: every point scores 0 and pass -1, so it plays the first allowed point,
# as play.ann does, unless its feature weights (capture $2, self_atari $3,
# and saves_atari $4) make another point score higher or lower.
tactics_network() {
  {
    printf 'EVOANN'
    printf '\002\000\000\000'   # format version 2
    printf '\145\000\000\000'   # 101 inputs: komi, 25 points, 3 x 25 tactics
    printf '\000\000\000\000'   # no hidden layers
    printf '\000\000\000\000'   # no hidden neurons
    printf '\032\000\000\000'   # 26 outputs
    printf '\001\000\000\000'   # hidden activation: sigmoid (unused)
    printf '\004\000\000\000'   # output activation: linear
    # The genes, as in network().
    printf '\173\024\256\107\341\172\204\077'
    printf '\000\000\000\000\000\000\360\077'
    printf '\000\000\000\000\000\000\340\077'
    printf '\173\024\256\107\341\172\224\077'
    printf '\173\024\256\107\341\172\224\077'
    printf '\002\000\000\000'   # feature groups: tactics
    printf '\173\024\256\107\341\172\204\077'   # feature_step 0.01 (unused)
    printf "$2$3$4"
    # 25 point outputs of 102 weights each (bias, 101 inputs), all 0.
    head -c $((25 * 102 * 8)) /dev/zero
    printf "$one"
    head -c $((101 * 8)) /dev/zero
  } >"$tmp/$1"
}
minus_ten='\000\000\000\000\000\000\044\300'
tactics_network capture.ann "$one" "$zero" "$zero"
tactics_network careful.ann "$zero" "$minus_ten" "$zero"
tactics_network flat.ann "$zero" "$zero" "$zero"
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

# The feature weights decide the moves. The plain game: play.ann against
# itself, and flat.ann, whose feature weights are all 0, plays the same.
cat >"$tmp/feature-schedule" <<EOF
pp $tmp/play.ann $tmp/play.ann
pf $tmp/play.ann $tmp/flat.ann
pc $tmp/play.ann $tmp/capture.ann
pk $tmp/play.ann $tmp/careful.ann
EOF
arena_ok features 5 6.5 30 "$tmp/feature-schedule"
plain="moves=A5,B5,C5,D5,E5,A4,B4,A5,C4,D4,E4,A3,B3,C3,D3,D5,D4,E3,A2,A5,B5,A4,A3,A5,A4,B2,C2,D2,E2,A1,B1"
expect_line features pp "pp${T}result=B+13.5${T}end=limit${T}length=31${T}time_black=T${T}time_white=T${T}duration=T${T}${plain}${T}ok"
expect_line features pf "pf${T}result=B+13.5${T}end=limit${T}length=31${T}time_black=T${T}time_white=T${T}duration=T${T}${plain}${T}ok"
# White's capture weight 1: its second move is A4, which captures A5
# (black A5 has only A4 left), where the plain game plays D5.
expect_line features pc "pc${T}result=B+18.5${T}end=limit${T}length=31${T}time_black=T${T}time_white=T${T}duration=T${T}moves=A5,B5,C5,A4,D5,E5,B4,A5,C4,D4,E4,A3,B3,C3,D3,E3,A2,A5,B5,A4,A3,A5,A4,B2,C2,D2,E2,A1,B1,C1,D1${T}ok"
# White's self_atari weight -10: after black's B4, white's A5 would join
# A4 and B5 with the one liberty A3, which the plain game plays; white
# plays the next allowed point, C4, instead.
expect_line features pk "pk${T}result=W+24.5${T}end=limit${T}length=31${T}time_black=T${T}time_white=T${T}duration=T${T}moves=A5,B5,C5,D5,E5,A4,B4,C4,D4,C5,E4,A3,B3,C3,D3,A2,E3,B2,B4,B3,C2,D2,E2,A1,B1,C1,D1,C2,pass,E1,E5${T}ok"

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
# The default genes (weight_changes is 1 for 556 weights); play ignores them.
(cd "$population" && "$generator" 3 5 1 10 0.01 1 0.5 0.02 0.02 none 0.3 0.01 42 >/dev/null)
# The same with every feature group, so that evo and the arena are seen to
# read and use the features alike.
featured="$tmp/featured"
mkdir "$featured"
(cd "$featured" && "$generator" 3 5 1 10 0.01 1 0.5 0.02 0.02 all 0.3 0.01 42 >/dev/null)
same_as_evo 9 6.5 60 example.ann
same_as_evo 9 -6.5 60 example.ann
same_as_evo 5 6.5 40 "$tmp/komi.ann"
same_as_evo 5 -6.5 40 "$tmp/komi.ann"
same_as_evo 5 6.5 40 "$tmp/capture.ann"
same_as_evo 5 6.5 40 "$tmp/careful.ann"
for n in 0001 0002 0003; do
  same_as_evo 5 6.5 40 "$population/$n.ann"
  same_as_evo 5 0 40 "$population/$n.ann"
  same_as_evo 5 6.5 40 "$featured/$n.ann"
  same_as_evo 5 0 40 "$featured/$n.ann"
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

# --protocol prints the protocol version of the --mixed invocation.
status=0
./arena --protocol >"$tmp/protocol" 2>"$tmp/protocol.err" || status=$?
if [ "$status" -ne 0 ] || [ "$(cat "$tmp/protocol")" != "3" ] || [ -s "$tmp/protocol.err" ]; then
  fail "--protocol: expected '3' and exit status 0, got status $status: $(cat "$tmp/protocol" "$tmp/protocol.err")"
fi
refuses '--protocol with an argument' --protocol 3

# The --mixed invocation: SIZE KOMI MAX_MOVES MAIN_TIME RESPONSE_DEADLINE
# GRACE MANIFEST. Its manifest declares the players and then the games,
# one tab-separated line each.
mixed() {
  ./arena --mixed 5 6.5 10 600 10 10 "$@"
}
manifest="$tmp/manifest"
{
  printf 'network\tpass\t%s\n' "$tmp/pass.ann"
  printf 'network\tplay\t%s\n' "$tmp/play.ann"
  printf 'network\tkomi\t%s\n' "$tmp/komi.ann"
  printf 'network\tmissing\t%s\n' "$tmp/missing.ann"
  printf 'network\texample\texample.ann\n'
  printf 'bot\tgnugo-1\n'
  printf 'game\tpp\tpass\tpass\n'
  printf 'game\tlp\tplay\tpass\n'
  printf 'game\tpl\tpass\tplay\n'
  printf 'game\tkk\tkomi\tkomi\n'
  printf 'game\tmissing\tmissing\tpass\n'
  printf 'game\tsize\tpass\texample\n'
} >"$manifest"
status=0
mixed "$manifest" >"$tmp/mixed" 2>"$tmp/mixed.err" || status=$?
if [ "$status" -ne 0 ]; then
  fail "mixed: expected exit status 0, got $status: $(cat "$tmp/mixed.err")"
fi
# The header comes first, then one record per game in manifest order, then
# the trailer.
got=$(cut -f1 "$tmp/mixed" | tr '\n' '|')
if [ "$got" != "arena protocol 3 ready|pp|lp|pl|kk|missing|size|done 6|" ]; then
  fail "mixed: expected the header, the games in order and 'done 6', got: $got"
fi
# A played game's record is the legacy line.
for id in pp lp pl kk; do
  want=$(strip_times <"$tmp/main" | grep "^$id	")
  expect_line mixed "$id" "$want"
done
# A network that cannot be played loses its game, with the reason.
expect_line mixed missing "missing${T}end=network_error${T}error=black${T}message=cannot open $tmp/missing.ann${T}ok"
expect_line mixed size "size${T}end=network_error${T}error=white${T}message=example.ann does not fit a 5x5 board${T}ok"

# The same network may play both colors, and a player need not play.
printf 'network\tp\t%s\nnetwork\tunused\t%s\ngame\tpp\tp\tp\n' "$tmp/pass.ann" "$tmp/play.ann" >"$tmp/self-manifest"
status=0
mixed "$tmp/self-manifest" >"$tmp/self" 2>"$tmp/self.err" || status=$?
expect_line self pp "pp${T}result=W+6.5${T}end=passes${T}length=2${T}time_black=T${T}time_white=T${T}duration=T${T}moves=pass,pass${T}ok"
if [ "$status" -ne 0 ] || [ "$(tail -1 "$tmp/self")" != "done 1" ]; then
  fail "self: expected exit status 0 and 'done 1', got $status: $(cat "$tmp/self" "$tmp/self.err")"
fi

# An empty manifest plays nothing, after the header.
: >"$tmp/empty-manifest"
status=0
mixed "$tmp/empty-manifest" >"$tmp/mixed-empty" 2>&1 || status=$?
if [ "$status" -ne 0 ] || [ "$(cat "$tmp/mixed-empty")" != "arena protocol 3 ready
done 0" ]; then
  fail "empty manifest: expected the header and 'done 0', got status $status: $(cat "$tmp/mixed-empty")"
fi

# When neither network can be played, the game is a failure: its record
# is written, no later game is played, there is no trailer, and the exit
# status is 2.
{
  printf 'network\tgarbage\t%s\nnetwork\texample\texample.ann\nnetwork\tpass\t%s\n' "$tmp/garbage.ann" "$tmp/pass.ann"
  printf 'game\tpp\tpass\tpass\ngame\tboth\tgarbage\texample\ngame\tlater\tpass\tpass\n'
} >"$tmp/both-manifest"
status=0
mixed "$tmp/both-manifest" >"$tmp/both" 2>"$tmp/both.err" || status=$?
if [ "$status" -ne 2 ]; then
  fail "both: expected exit status 2, got $status"
fi
got=$(cut -f1 "$tmp/both" | tr '\n' '|')
if [ "$got" != "arena protocol 3 ready|pp|both|" ]; then
  fail "both: expected the header, pp and both only, got: $got"
fi
expect_line both both "both${T}end=network_error${T}error=both${T}message=$tmp/garbage.ann holds no network; example.ann does not fit a 5x5 board${T}ok"

# With a generous main time, every network game of --mixed is the legacy
# game: the seeded networks' games from the many schedule, same moves and
# results.
: >"$tmp/many-manifest"
for n in 0001 0002 0003; do
  printf 'network\t%s\t%s\n' "$n" "$population/$n.ann" >>"$tmp/many-manifest"
done
printf 'network\tplay\t%s\n' "$tmp/play.ann" >>"$tmp/many-manifest"
while read -r id black white; do
  printf 'game\t%s\t%s\t%s\n' "$id" "$(basename "$black" .ann)" "$(basename "$white" .ann)" >>"$tmp/many-manifest"
done <"$tmp/many-schedule"
status=0
./arena --mixed 5 6.5 40 600 10 10 "$tmp/many-manifest" >"$tmp/many-mixed" 2>"$tmp/many-mixed.err" || status=$?
if [ "$status" -ne 0 ]; then
  fail "many, --mixed: expected exit status 0, got $status: $(cat "$tmp/many-mixed.err")"
fi
if [ "$(sed 1d "$tmp/many-mixed" | strip_times)" != "$(cat "$tmp/many.stripped")" ]; then
  fail "many, --mixed: the records differ from the legacy lines:
$(sed 1d "$tmp/many-mixed" | strip_times | diff "$tmp/many.stripped" - || true)"
fi

# Main time. heavy.ann, a 5x5 network with two hidden layers of 2000
# neurons, takes about 2 ms a move; pass.ann about a microsecond. With a
# main time of 0.0004 s, heavy.ann overruns it on its first move and
# pass.ann never does, with a wide margin both ways.
(cd "$tmp" && "$generator" 1 5 2 2000 0.01 1 0.5 0.02 0.02 none 0.3 0.01 42 >/dev/null && mv 0001.ann heavy.ann)
printf 'hp %s %s\nph %s %s\n' "$tmp/heavy.ann" "$tmp/pass.ann" "$tmp/pass.ann" "$tmp/heavy.ann" >"$tmp/heavy-schedule"
# The legacy invocation has no time limit: the heavy games are played out.
arena_ok heavy 5 6.5 10 "$tmp/heavy-schedule"
for id in hp ph; do
  if ! grep -Eq "^$id${T}result=[^${T}]*${T}end=(passes|limit)${T}" "$tmp/heavy"; then
    fail "heavy, legacy: game $id was not played out: $(cat "$tmp/heavy")"
  fi
done
heavy_moves=$(sed -n 's/^hp	.*	moves=\([^	]*\)	ok$/\1/p' "$tmp/heavy")
heavy_first=${heavy_moves%%,*}
heavy_reply=$(sed -n 's/^ph	.*	moves=pass,\([^,	]*\).*	ok$/\1/p' "$tmp/heavy")
{
  printf 'network\theavy\t%s\nnetwork\tpass\t%s\n' "$tmp/heavy.ann" "$tmp/pass.ann"
  printf 'game\thp\theavy\tpass\ngame\tph\tpass\theavy\ngame\tpp\tpass\tpass\n'
} >"$tmp/time-manifest"
status=0
./arena --mixed 5 6.5 10 0.0004 10 10 "$tmp/time-manifest" >"$tmp/time" 2>"$tmp/time.err" || status=$?
# A time loss is a played game: the arena goes on to the later games.
if [ "$status" -ne 0 ] || [ "$(cut -f1 "$tmp/time" | tr '\n' '|')" != "arena protocol 3 ready|hp|ph|pp|done 3|" ]; then
  fail "time: expected exit status 0, hp, ph, pp and 'done 3', got $status: $(cat "$tmp/time" "$tmp/time.err")"
fi
# Black overruns on its first move: white wins on time, and the move that
# overran is in the moves and the length.
expect_line time hp "hp${T}result=W+T${T}end=time${T}length=1${T}time_black=T${T}time_white=T${T}duration=T${T}moves=$heavy_first${T}ok"
# White overruns on its first move, after black's pass.
expect_line time ph "ph${T}result=B+T${T}end=time${T}length=2${T}time_black=T${T}time_white=T${T}duration=T${T}moves=pass,$heavy_reply${T}ok"
expect_line time pp "pp${T}result=W+6.5${T}end=passes${T}length=2${T}time_black=T${T}time_white=T${T}duration=T${T}moves=pass,pass${T}ok"
# The overrunning move is charged: the loser's time is past main time, the
# winner's is not.
if ! awk -F'\t' '
  $1 == "hp" { split($5, b, "="); split($6, w, "="); if (!(b[2] > 0.0004 && w[2] <= 0.0004)) bad = 1; n++ }
  $1 == "ph" { split($5, b, "="); split($6, w, "="); if (!(w[2] > 0.0004 && b[2] <= 0.0004)) bad = 1; n++ }
  END { exit bad || n != 2 }' "$tmp/time"; then
  fail "time: expected the loser's time past 0.0004 and the winner's within it: $(cat "$tmp/time")"
fi
# A time loss beats the other endings of the same move. With max_moves 0
# black's overrunning move is also the last allowed one; with max_moves 1,
# white's.
status=0
./arena --mixed 5 6.5 0 0.0004 10 10 "$tmp/time-manifest" >"$tmp/time-limit0" 2>&1 || status=$?
expect_line time-limit0 hp "hp${T}result=W+T${T}end=time${T}length=1${T}time_black=T${T}time_white=T${T}duration=T${T}moves=$heavy_first${T}ok"
status=0
./arena --mixed 5 6.5 1 0.0004 10 10 "$tmp/time-manifest" >"$tmp/time-limit1" 2>&1 || status=$?
expect_line time-limit1 ph "ph${T}result=B+T${T}end=time${T}length=2${T}time_black=T${T}time_white=T${T}duration=T${T}moves=pass,$heavy_reply${T}ok"
# heavy-pass.ann has heavy.ann's shape and speed, but every weight 0 except
# the pass output's bias weight, so it always passes. As white against
# pass.ann, its overrunning move is also the second pass in a row.
{
  printf 'EVOANN'
  printf '\002\000\000\000'   # format version 2
  printf '\032\000\000\000'   # 26 inputs
  printf '\002\000\000\000'   # 2 hidden layers
  printf '\320\007\000\000'   # of 2000 neurons
  printf '\032\000\000\000'   # 26 outputs
  printf '\001\000\000\000'   # hidden activation: sigmoid
  printf '\004\000\000\000'   # output activation: linear
  # The genes and features, as in network().
  printf '\173\024\256\107\341\172\204\077'
  printf '\000\000\000\000\000\000\360\077'
  printf '\000\000\000\000\000\000\340\077'
  printf '\173\024\256\107\341\172\224\077'
  printf '\173\024\256\107\341\172\224\077'
  printf '\000\000\000\000'
  printf '\173\024\256\107\341\172\204\077'
  # The hidden layers (2000 x 27, 2000 x 2001 weights) and 25 point
  # outputs of 2001 weights each, all 0; then the pass output.
  head -c $(((2000 * 27 + 2000 * 2001 + 25 * 2001) * 8)) /dev/zero
  printf "$minus_one"
  head -c $((2000 * 8)) /dev/zero
} >"$tmp/heavy-pass.ann"
printf 'network\theavy\t%s\nnetwork\tpass\t%s\ngame\tpp\tpass\theavy\n' "$tmp/heavy-pass.ann" "$tmp/pass.ann" >"$tmp/pass-manifest"
status=0
./arena --mixed 5 6.5 10 0.0004 10 10 "$tmp/pass-manifest" >"$tmp/time-passes" 2>&1 || status=$?
expect_line time-passes pp "pp${T}result=B+T${T}end=time${T}length=2${T}time_black=T${T}time_white=T${T}duration=T${T}moves=pass,pass${T}ok"

# Bad arguments or a bad manifest stop the arena with exit status 1 and a
# message, before the header and any game.
refuses '--mixed without arguments' --mixed
refuses '--mixed, six arguments' --mixed 5 6.5 10 600 10 "$manifest"
refuses '--mixed, eight arguments' --mixed 5 6.5 10 600 10 10 "$manifest" extra
refuses '--mixed, size 1' --mixed 1 6.5 10 600 10 10 "$manifest"
refuses '--mixed, komi nan' --mixed 5 nan 10 600 10 10 "$manifest"
refuses '--mixed, max_moves -1' --mixed 5 6.5 -1 600 10 10 "$manifest"
for bad in 0 -1 '' abc 1x 1e3 0x10 inf nan ' 1' 1. .5 1000001; do
  refuses "--mixed, main time '$bad'" --mixed 5 6.5 10 "$bad" 10 10 "$manifest"
  refuses "--mixed, response deadline '$bad'" --mixed 5 6.5 10 600 "$bad" 10 "$manifest"
done
for bad in -1 '' abc 1x inf ' 1' 1000001; do
  refuses "--mixed, grace '$bad'" --mixed 5 6.5 10 600 10 "$bad" "$manifest"
done
refuses '--mixed, missing manifest' --mixed 5 6.5 10 600 10 10 "$tmp/no-manifest"
# Tiny times and a grace of 0 are allowed.
status=0
./arena --mixed 5 6.5 10 0.000001 0.001 0 "$tmp/self-manifest" >"$tmp/tiny" 2>"$tmp/tiny.err" || status=$?
if [ "$status" -ne 0 ]; then
  fail "tiny times: expected exit status 0, got $status: $(cat "$tmp/tiny.err")"
fi
bad_manifest() {
  printf "$2" >"$tmp/bad-manifest"
  refuses "manifest: $1" --mixed 5 6.5 10 600 10 10 "$tmp/bad-manifest"
  if ! grep -q "$3" "$tmp/refused.err"; then
    fail "manifest: $1: expected a message with '$3', got: $(cat "$tmp/refused.err")"
  fi
}
n="network${T}n${T}$tmp/pass.ann\n"
bad_manifest 'blank line' "$n\ngame${T}g${T}n${T}n\n" 'line 2'
bad_manifest 'unknown kind' "$n""player${T}p${T}x\n" 'line 2'
bad_manifest 'spaces for tabs' "network n $tmp/pass.ann\n" 'line 1'
bad_manifest 'network, two fields' "network${T}n\n" 'line 1'
bad_manifest 'network, four fields' "network${T}n${T}a${T}b\n" 'line 1'
bad_manifest 'network, empty path' "network${T}n${T}\n" 'line 1'
bad_manifest 'bot, three fields' "bot${T}b${T}brown\n" 'line 1'
bad_manifest 'game, three fields' "$n""game${T}g${T}n\n" 'line 2'
bad_manifest 'game, five fields' "$n""game${T}g${T}n${T}n${T}n\n" 'line 2'
bad_manifest 'empty game ID' "$n""game${T}${T}n${T}n\n" 'line 2'
bad_manifest 'space in a player ID' "network${T}a b${T}$tmp/pass.ann\n" 'line 1'
bad_manifest 'space in a game ID' "$n""game${T}g 1${T}n${T}n\n" 'line 2'
bad_manifest 'carriage return' "$n""network${T}m${T}$tmp/play.ann\r\n" 'line 2'
bad_manifest 'control character' "network${T}m${T}$tmp/play\001.ann\n" 'line 1'
bad_manifest 'tab at the end' "$n""game${T}g${T}n${T}n${T}\n" 'line 2'
bad_manifest 'duplicate player' "$n""bot${T}n\n" 'line 2'
bad_manifest 'duplicate game' "$n""game${T}g${T}n${T}n\ngame${T}g${T}n${T}n\n" 'line 3'
bad_manifest 'undeclared player' "$n""game${T}g${T}n${T}m\n" 'line 2'
bad_manifest 'player after its game' "game${T}g${T}n${T}n\n$n" 'line 1'
bad_manifest 'player after a game' "$n""game${T}g${T}n${T}n\nnetwork${T}m${T}$tmp/play.ann\n" 'line 3'
b="bot${T}b\n"
bad_manifest 'command, three fields' "$n$b""game${T}g${T}n${T}b\ncommand${T}g${T}white\n" 'line 4'
bad_manifest 'command, undeclared game' "$n$b""command${T}g${T}white${T}brown\n" 'line 3'
bad_manifest 'command, bad color' "$n$b""game${T}g${T}n${T}b\ncommand${T}g${T}w${T}brown\n" 'line 4'
bad_manifest 'command for a network' "$n$b""game${T}g${T}n${T}b\ncommand${T}g${T}black${T}brown\n" 'line 4'
bad_manifest 'command twice' "$n$b""game${T}g${T}n${T}b\ncommand${T}g${T}white${T}brown\ncommand${T}g${T}white${T}brown\n" 'line 5'
bad_manifest 'blank command' "$n$b""game${T}g${T}n${T}b\ncommand${T}g${T}white${T}  \n" 'line 4'
bad_manifest 'command, empty' "$n$b""game${T}g${T}n${T}b\ncommand${T}g${T}white${T}\n" 'line 4'
bad_manifest 'bot without a command' "$n$b""game${T}g${T}n${T}b\n" 'game g'
bad_manifest 'bot without a command, later game' "$n$b""game${T}g${T}b${T}n\ncommand${T}g${T}black${T}brown\ngame${T}h${T}n${T}b\n" 'game h'
# Bots are parsed but cannot play yet.
bad_manifest 'bot game' "$n$b""game${T}g${T}n${T}b\ncommand${T}g${T}white${T}gnugo --mode gtp --seed 7\n" 'not supported yet'
# A NUL byte is refused too.
printf "$n""game${T}g${T}n${T}n\000\n" >"$tmp/bad-manifest"
refuses 'manifest: NUL byte' --mixed 5 6.5 10 600 10 10 "$tmp/bad-manifest"

if [ "$failed" -ne 0 ]; then
  exit 1
fi
printf 'The arena played, ended, and reported its games as expected, and refused bad input\n'
