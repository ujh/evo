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
arena_ok time-limit0 --mixed 5 6.5 0 0.0004 10 10 "$tmp/time-manifest"
expect_line time-limit0 hp "hp${T}result=W+T${T}end=time${T}length=1${T}time_black=T${T}time_white=T${T}duration=T${T}moves=$heavy_first${T}ok"
arena_ok time-limit1 --mixed 5 6.5 1 0.0004 10 10 "$tmp/time-manifest"
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
arena_ok time-passes --mixed 5 6.5 10 0.0004 10 10 "$tmp/pass-manifest"
expect_line time-passes pp "pp${T}result=B+T${T}end=time${T}length=2${T}time_black=T${T}time_white=T${T}duration=T${T}moves=pass,pass${T}ok"
# Each side is charged only its own moves: in heavy.ann against itself,
# the loser is past main time and the winner within it. Each side's whole
# game takes about 30 ms here, so main times of 1 to 6 ms end it on time
# even on a much faster machine. The main times step by 0.25 ms, well
# under a move's 2 ms, so that a check against the two sides' sum (even
# against twice the main time) ends some of these games with the wrong
# loser or at the wrong move.
printf 'network\theavy\t%s\ngame\thh\theavy\theavy\n' "$tmp/heavy.ann" >"$tmp/hh-manifest"
for main in 0.001 0.00125 0.0015 0.00175 0.002 0.00225 0.0025 0.00275 0.003 0.00325 0.0035 0.00375 \
  0.004 0.00425 0.0045 0.00475 0.005 0.00525 0.0055 0.00575 0.006; do
  arena_ok time-hh --mixed 5 6.5 40 "$main" 10 10 "$tmp/hh-manifest"
  if ! awk -F'\t' -v main="$main" '
    # The times are printed to the microsecond, so a loser past main time
    # by at most half a microsecond prints as main time itself: >= for the
    # loser; the winner, never past main time, stays <=.
    $1 == "hh" {
      split($2, r, "="); split($3, e, "="); split($5, b, "="); split($6, w, "=")
      if (e[2] != "time") bad = 1
      else if (r[2] == "W+T") { if (!(b[2] >= main && w[2] <= main)) bad = 1 }
      else if (r[2] == "B+T") { if (!(w[2] >= main && b[2] <= main)) bad = 1 }
      else bad = 1
      n++
    }
    END { exit bad || n != 1 }' "$tmp/time-hh"; then
    fail "time-hh, main time $main: expected a time loss past main time to a winner within it: $(cat "$tmp/time-hh")"
  fi
done

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
# A NUL byte is refused too.
printf "$n""game${T}g${T}n${T}n\000\n" >"$tmp/bad-manifest"
refuses 'manifest: NUL byte' --mixed 5 6.5 10 600 10 10 "$tmp/bad-manifest"

# Games with bots, against fakebot, a scripted fake GTP program (see
# fakebot.c), so no real bot is needed (scripts/smoke-arena-bots.sh
# plays the real ones). By default fakebot passes to every genmove.

# watch NAME PID: stops PID if it still runs after 60 s (no game here
# takes 10), first with SIGTERM, which the arena answers by killing its
# bots, then with SIGKILL; a hang then fails the test instead of stopping
# it.
watch() {
  (
    n=0
    while kill -0 "$2" 2>/dev/null; do
      n=$((n + 1))
      if [ "$n" -gt 300 ]; then
        : >"$tmp/$1.hung"
        kill -TERM "$2"
        sleep 2
        kill -9 "$2"
        exit
      fi
      sleep 0.2
    done
  ) >/dev/null 2>&1 &
}

# hung NAME: when the watcher had to stop NAME's arena, fails and stops
# the tests at once, since what hung one would hang the rest.
hung() {
  if [ -e "$tmp/$1.hung" ]; then
    printf '%s: hung, stopped after 60 s\n' "$1" >&2
    exit 1
  fi
}

# bots NAME MAX_MOVES MAIN_TIME RESPONSE_DEADLINE GRACE: runs the arena on
# the manifest $tmp/NAME.manifest, 5x5 with komi 6.5, under a watcher; output in
# $tmp/NAME, stderr in $tmp/NAME.err, exit status in $status, and the
# whole seconds it took in $took.
bots() {
  name=$1
  began=$(date +%s)
  ./arena --mixed 5 6.5 "$2" "$3" "$4" "$5" "$tmp/$name.manifest" >"$tmp/$name" 2>"$tmp/$name.err" &
  job=$!
  watch "$name" "$job"
  status=0
  { wait "$job" || status=$?; } 2>/dev/null
  took=$(($(date +%s) - began))
  hung "$name"
}

# order NAME WANT: the output's first fields, joined by '|', are WANT.
order() {
  got=$(cut -f1 "$tmp/$1" | tr '\n' '|')
  if [ "$got" != "$2" ]; then
    fail "$1: expected $2, got $got: $(cat "$tmp/$1" "$tmp/$1.err")"
  fi
}

# exits NAME STATUS: the arena exited with STATUS.
exits() {
  if [ "$status" -ne "$2" ]; then
    fail "$1: expected exit status $2, got $status: $(cat "$tmp/$1.err")"
  fi
}

# log NAME FILE LINE...: the bot's log (fakebot --log) is the lines; a
# line SETUP stands for the setup commands of a 5x5 game with komi 6.5,
# IDs 1 to 6, for a bot without time_settings: twogtp's boardsize,
# clear_board and komi, then boardsize and clear_board again.
log() {
  name=$1 file=$2
  shift 2
  want=$(for line in "$@"; do
    if [ "$line" = SETUP ]; then
      printf '%s\n' '1 known_command time_settings' '2 boardsize 5' '3 clear_board' '4 komi 6.5' '5 boardsize 5' \
        '6 clear_board'
    else
      printf '%s\n' "$line"
    fi
  done)
  if [ "$(cat "$file" 2>/dev/null)" != "$want" ]; then
    fail "$name: the bot read
$(cat "$file" 2>/dev/null)
expected
$want"
  fi
}

# wait_for FILE PATTERN: waits up to 10 s for a line matching PATTERN.
wait_for() {
  n=0
  until grep -q "$2" "$1" 2>/dev/null; do
    n=$((n + 1))
    if [ "$n" -gt 100 ]; then
      fail "no '$2' in $1"
      return 1
    fi
    sleep 0.1
  done
}

# gone NAME PIDFILE: the process in PIDFILE (fakebot --pid) no longer runs.
gone() {
  if [ ! -s "$2" ]; then
    fail "$1: no pid file $2"
    return
  fi
  pid=$(cut -d' ' -f1 "$2")
  if kill -0 "$pid" 2>/dev/null; then
    fail "$1: bot $pid still runs"
    kill -9 "$pid" 2>/dev/null || true
  fi
}

# field NAME ID KEY: the value of KEY in game ID's record.
field() {
  grep "^$2	" "$tmp/$1" | tr '\t' '\n' | sed -n "s/^$3=//p"
}

# within NAME ID KEY MIN MAX: KEY of game ID's record is within [MIN, MAX].
within() {
  v=$(field "$1" "$2" "$3")
  if ! awk -v v="$v" -v lo="$4" -v hi="$5" 'BEGIN { exit !(v != "" && v >= lo && v <= hi) }'; then
    fail "$1, game $2: $3 is '$v', expected $4 to $5"
  fi
}

# A bot plays either color against a network, and against another bot,
# on the arena's board. Its moves are read ignoring case and written as
# the arena writes a network's; its games are the network games it
# replaces: fakebot passing plays as pass.ann does (see the games lp, pl
# and pp above). A bot is told only the other player's moves, each just
# before its own genmove, never its own; the game's last move is never
# sent, and quit follows the game.
{
  printf 'network\tplay\t%s\nnetwork\tpass\t%s\nbot\tfake\n' "$tmp/play.ann" "$tmp/pass.ann"
  printf 'game\tlp\tplay\tfake\ncommand\tlp\twhite\t./fakebot --log %s genmove=ok:PASS\n' "$tmp/lp.log"
  printf 'game\tpl\tfake\tplay\ncommand\tpl\tblack\t./fakebot --log %s\n' "$tmp/pl.log"
  printf 'game\tpp\tfake\tfake\n'
  printf 'command\tpp\tblack\t./fakebot --log %s\ncommand\tpp\twhite\t./fakebot --log %s genmove=ok:Pass\n' \
    "$tmp/pp-b.log" "$tmp/pp-w.log"
} >"$tmp/with-bots.manifest"
bots with-bots 10 600 10 10
exits with-bots 0
order with-bots "arena protocol 3 ready|lp|pl|pp|done 3|"
for id in lp pl pp; do
  want=$(strip_times <"$tmp/main" | grep "^$id	")
  expect_line with-bots "$id" "$want"
done
log lp "$tmp/lp.log" SETUP '7 play b A5' '8 genmove w' '9 play b B5' '10 genmove w' '11 play b C5' '12 genmove w' \
  '13 play b D5' '14 genmove w' '15 play b E5' '16 genmove w' '17 quit'
log pl "$tmp/pl.log" SETUP '7 genmove b' '8 play w A5' '9 genmove b' '10 play w B5' '11 genmove b' \
  '12 play w C5' '13 genmove b' '14 play w D5' '15 genmove b' '16 play w E5' '17 genmove b' '18 quit'
log pp "$tmp/pp-b.log" SETUP '7 genmove b' '8 quit'
log pp "$tmp/pp-w.log" SETUP '7 play b pass' '8 genmove w' '9 quit'

# max_moves + 1 moves between two bots, with lowercase vertices written in
# uppercase; the same bot player plays both colors, each color its own
# process.
{
  printf 'bot\tfake\ngame\tlimit\tfake\tfake\n'
  printf 'command\tlimit\tblack\t./fakebot --log %s genmove#1=ok:c3 genmove#2=ok:d4\n' "$tmp/limit-b.log"
  printf 'command\tlimit\twhite\t./fakebot --log %s\n' "$tmp/limit-w.log"
} >"$tmp/limit.manifest"
bots limit 2 600 10 10
exits limit 0
expect_line limit limit "limit${T}result=B+18.5${T}end=limit${T}length=3${T}time_black=T${T}time_white=T${T}duration=T${T}moves=C3,pass,D4${T}ok"
log limit "$tmp/limit-b.log" SETUP '7 genmove b' '8 play w pass' '9 genmove b' '10 quit'
log limit "$tmp/limit-w.log" SETUP '7 play b C3' '8 genmove w' '9 quit'

# A bot's resignation is its opponent's win, also before any move; the
# games after it are played. Its genmove time is charged to its side.
{
  printf 'network\tplay\t%s\nnetwork\tpass\t%s\nbot\tfake\n' "$tmp/play.ann" "$tmp/pass.ann"
  printf 'game\tw-resigns\tplay\tfake\ncommand\tw-resigns\twhite\t./fakebot genmove#1=sleep:0.2 genmove#2=ok:Resign\n'
  printf 'game\tb-resigns\tfake\tpass\ncommand\tb-resigns\tblack\t./fakebot genmove=ok:resign\n'
  printf 'game\tpp\tpass\tpass\n'
} >"$tmp/resign.manifest"
bots resign 10 600 10 10
exits resign 0
order resign "arena protocol 3 ready|w-resigns|b-resigns|pp|done 3|"
expect_line resign w-resigns "w-resigns${T}result=B+R${T}end=resign${T}length=3${T}time_black=T${T}time_white=T${T}duration=T${T}moves=A5,pass,B5${T}ok"
expect_line resign b-resigns "b-resigns${T}result=W+R${T}end=resign${T}length=0${T}time_black=T${T}time_white=T${T}duration=T${T}moves=${T}ok"
within resign w-resigns time_white 0.2 5
within resign w-resigns time_black 0 0.1
within resign w-resigns duration 0.2 5

# Failures: each writes its record, with the moves and times before it,
# and stops the arena with exit status 2, with no later game and no
# trailer. $tmp/NAME.bare has the output with each message M.
# failure NAME MAX_MOVES MAIN_TIME RESPONSE_DEADLINE GRACE
# COLOR COMMAND: play.ann against the bot COMMAND, the bot playing COLOR,
# then a game that must not be played.
failure() {
  name=$1 color=$6 command=$7
  {
    printf 'network\tplay\t%s\nnetwork\tpass\t%s\nbot\tfake\n' "$tmp/play.ann" "$tmp/pass.ann"
    if [ "$color" = white ]; then
      printf 'game\tg\tplay\tfake\n'
    else
      printf 'game\tg\tfake\tplay\n'
    fi
    printf 'command\tg\t%s\t%s\ngame\tlater\tpass\tpass\n' "$color" "$command"
  } >"$tmp/$name.manifest"
  bots "$name" "$2" "$3" "$4" "$5"
  exits "$name" 2
  order "$name" "arena protocol 3 ready|g|"
  sed "s/${T}message=[^${T}]*${T}/${T}message=M${T}/" "$tmp/$name" >"$tmp/$name.bare"
}
# message NAME PATTERN: the failure record's message matches PATTERN.
message() {
  m=$(field "$1" g message)
  if ! printf '%s\n' "$m" | grep -Eq "$2"; then
    fail "$1: expected a message matching '$2', got '$m'"
  fi
}

# An occupied point, a point off the board, or no vertex at all is an
# illegal move.
failure occupied 10 600 10 10 white "./fakebot genmove=ok:a5"
expect_line occupied g "g${T}end=illegal${T}error=white${T}length=1${T}time_black=T${T}time_white=T${T}duration=T${T}moves=A5${T}message=genmove answered A5, which is not a legal move on the board${T}ok"
failure off-board 10 600 10 10 black "./fakebot genmove#2=ok:F1"
expect_line off-board g "g${T}end=illegal${T}error=black${T}length=2${T}time_black=T${T}time_white=T${T}duration=T${T}moves=pass,A5${T}message=genmove answered 'F1', which is not a move on a 5x5 board${T}ok"
failure no-vertex 10 600 10 10 white './fakebot "genmove=ok:A1 B2"'
expect_line no-vertex g "g${T}end=illegal${T}error=white${T}length=1${T}time_black=T${T}time_white=T${T}duration=T${T}moves=A5${T}message=genmove answered 'A1 B2', which is not a move on a 5x5 board${T}ok"
# Simple ko: taking back at once is illegal. Black's C3 captures B3;
# white takes back at B3.
{
  printf 'bot\tfake\ngame\tg\tfake\tfake\n'
  printf 'command\tg\tblack\t./fakebot genmove#1=ok:B4 genmove#2=ok:A3 genmove#3=ok:B2 genmove#5=ok:C3\n'
  printf 'command\tg\twhite\t./fakebot genmove#1=ok:C4 genmove#2=ok:D3 genmove#3=ok:C2 genmove#4=ok:B3 genmove#5=ok:B3\n'
} >"$tmp/ko.manifest"
bots ko 20 600 10 10
exits ko 2
expect_line ko g "g${T}end=illegal${T}error=white${T}length=9${T}time_black=T${T}time_white=T${T}duration=T${T}moves=B4,C4,A3,D3,B2,C2,pass,B3,C3${T}message=genmove answered B3, which is not a legal move on the board${T}ok"

# A bot that misses its genmove deadline (its remaining main time plus
# the grace) times out; its side's time includes the wait. Main time 0.3 s
# and grace 0.3 s: the second genmove waits about 0.6 s.
failure timeout 10 0.3 10 0.3 white "./fakebot --pid $tmp/timeout.pid --ignore-signals --stay genmove#2=hang"
expect_line timeout.bare g "g${T}end=timeout${T}error=white${T}length=3${T}time_black=T${T}time_white=T${T}duration=T${T}moves=A5,pass,B5${T}message=M${T}ok"
message timeout '^genmove: no answer to genmove within 0\.(59[0-9]|600) s$'
within timeout g time_white 0.59 1.5
within timeout g time_black 0 0.1
gone timeout "$tmp/timeout.pid"
# An answer within the grace that takes the bot past main time is a
# timeout too, not a time loss.
failure overrun 10 0.3 10 1 black "./fakebot genmove#2=sleep:0.4"
expect_line overrun.bare g "g${T}end=timeout${T}error=black${T}length=2${T}time_black=T${T}time_white=T${T}duration=T${T}moves=pass,A5${T}message=M${T}ok"
message overrun '^genmove: answered after 0\.[4-9][0-9]{2} s of genmove time in all, past the main time of 0\.300 s$'
within overrun g time_black 0.4 1.5

# A bot that dies, answers a GTP error, or answers what is not GTP,
# crashes, whether on genmove or on play.
failure segv 10 600 10 10 white "./fakebot genmove=crash"
expect_line segv g "g${T}end=crash${T}error=white${T}length=1${T}time_black=T${T}time_white=T${T}duration=T${T}moves=A5${T}message=genmove: killed by signal 11${T}ok"
failure play-exit 10 600 10 10 white "./fakebot play#2=exit:4"
expect_line play-exit g "g${T}end=crash${T}error=white${T}length=3${T}time_black=T${T}time_white=T${T}duration=T${T}moves=A5,pass,B5${T}message=play: exited with status 4${T}ok"
failure gtp-error 10 600 10 10 black "./fakebot genmove=err:out\tof\\nstones"
expect_line gtp-error g "g${T}end=crash${T}error=black${T}length=0${T}time_black=T${T}time_white=T${T}duration=T${T}moves=${T}message=genmove answered an error: out of stones${T}ok"
failure wrong-id 10 600 10 10 white './fakebot "genmove=raw:=99 A1\n\n"'
expect_line wrong-id g "g${T}end=crash${T}error=white${T}length=1${T}time_black=T${T}time_white=T${T}duration=T${T}moves=A5${T}message=genmove: answered with ID 99 to command 8${T}ok"
failure play-timeout 10 600 0.2 10 white "./fakebot play=hang"
expect_line play-timeout g "g${T}end=timeout${T}error=white${T}length=1${T}time_black=T${T}time_white=T${T}duration=T${T}moves=A5${T}message=play: no answer to play within 0.200 s${T}ok"
within play-timeout g time_white 0 0.1

# Any failure before the bot's first play or genmove is a launch failure:
# it cannot start, or a setup command fails or misses its deadline.
failure no-program 10 600 10 10 white "./no-such-program --mode gtp"
expect_line no-program g "g${T}end=launch${T}error=white${T}length=0${T}time_black=T${T}time_white=T${T}duration=T${T}moves=${T}message=cannot start ./no-such-program: No such file or directory${T}ok"
failure setup-error 10 600 10 10 black './fakebot "boardsize=err:unacceptable size"'
expect_line setup-error g "g${T}end=launch${T}error=black${T}length=0${T}time_black=T${T}time_white=T${T}duration=T${T}moves=${T}message=boardsize: unacceptable size${T}ok"
failure setup-hang 10 600 0.2 10 white "./fakebot komi=hang"
expect_line setup-hang g "g${T}end=launch${T}error=white${T}length=0${T}time_black=T${T}time_white=T${T}duration=T${T}moves=${T}message=komi: no answer to komi within 0.200 s${T}ok"
within setup-hang g time_white 0 0

# A network that cannot be played loses a game against a bot without the
# bot being started; the later games are played.
{
  printf 'network\tmissing\t%s\nnetwork\tpass\t%s\nbot\tfake\n' "$tmp/missing.ann" "$tmp/pass.ann"
  printf 'game\tmissing\tmissing\tfake\ncommand\tmissing\twhite\t./fakebot --pid %s\n' "$tmp/missing-bot.pid"
  printf 'game\tpp\tpass\tfake\ncommand\tpp\twhite\t./fakebot\n'
} >"$tmp/network-error.manifest"
bots network-error 10 600 10 10
exits network-error 0
order network-error "arena protocol 3 ready|missing|pp|done 2|"
expect_line network-error missing "missing${T}end=network_error${T}error=black${T}message=cannot open $tmp/missing.ann${T}ok"
if [ -e "$tmp/missing-bot.pid" ]; then
  fail "network-error: the bot of a game whose network cannot be played was started"
fi

# Every game starts its bots anew, from its own command line, so a
# per-game seed reaches the bot; their stderr is the arena's.
{
  printf 'network\tpass\t%s\nbot\tfake\n' "$tmp/pass.ann"
  printf 'game\tg1\tpass\tfake\ncommand\tg1\twhite\t./fakebot --stderr seed-11 --pid %s --log %s\n' "$tmp/g1.pid" "$tmp/g1.log"
  printf 'game\tg2\tfake\tpass\ncommand\tg2\tblack\t./fakebot --stderr seed-22 --pid %s --log %s\n' "$tmp/g2.pid" "$tmp/g2.log"
  printf 'game\tg3\tpass\tfake\ncommand\tg3\twhite\tfakebot --stderr seed-33 --pid %s --log %s\n' "$tmp/g3.pid" "$tmp/g3.log"
} >"$tmp/fresh.manifest"
bots fresh 10 600 10 10
exits fresh 0
order fresh "arena protocol 3 ready|g1|g2|g3|done 3|"
if [ "$(grep '^seed-' "$tmp/fresh.err" | tr '\n' ' ')" != "seed-11 seed-22 seed-33 " ]; then
  fail "fresh: expected each game's seed on the arena's stderr in order, got: $(cat "$tmp/fresh.err")"
fi
if [ "$(cut -d' ' -f1 "$tmp/g1.pid")" = "$(cut -d' ' -f1 "$tmp/g3.pid")" ]; then
  fail "fresh: games g1 and g3 had the same bot process"
fi
log fresh "$tmp/g1.log" SETUP '7 play b pass' '8 genmove w' '9 quit'
log fresh "$tmp/g2.log" SETUP '7 genmove b' '8 quit'
log fresh "$tmp/g3.log" SETUP '7 play b pass' '8 genmove w' '9 quit'
gone fresh "$tmp/g1.pid"
gone fresh "$tmp/g2.pid"
gone fresh "$tmp/g3.pid"

# A bot that knows time_settings gets the main time in whole seconds,
# rounded up, after the second clear_board, as twogtp sends it.
for main in 2.5 600; do
  printf 'network\tpass\t%s\nbot\tfake\ngame\tg\tpass\tfake\ncommand\tg\twhite\t./fakebot --log %s known_command=ok:true\n' \
    "$tmp/pass.ann" "$tmp/time-$main.log" >"$tmp/time-$main.manifest"
  bots "time-$main" 10 "$main" 10 10
  exits "time-$main" 0
done
log time-2.5 "$tmp/time-2.5.log" '1 known_command time_settings' '2 boardsize 5' '3 clear_board' '4 komi 6.5' \
  '5 boardsize 5' '6 clear_board' '7 time_settings 3 0 0' '8 play b pass' '9 genmove w' '10 quit'
log time-600 "$tmp/time-600.log" '1 known_command time_settings' '2 boardsize 5' '3 clear_board' '4 komi 6.5' \
  '5 boardsize 5' '6 clear_board' '7 time_settings 600 0 0' '8 play b pass' '9 genmove w' '10 quit'

# A genmove waits only for the side's remaining main time plus the grace:
# after a first genmove of 0.2 s of 0.3 s main time, the second waits
# about 0.1 + 0.3 s, not 0.3 + 0.3 s.
failure remaining 10 0.3 10 0.3 white "./fakebot genmove#1=sleep:0.2 genmove#2=hang"
expect_line remaining.bare g "g${T}end=timeout${T}error=white${T}length=3${T}time_black=T${T}time_white=T${T}duration=T${T}moves=A5,pass,B5${T}message=M${T}ok"
waited=$(field remaining g message | sed -n 's/^genmove: no answer to genmove within \([0-9.]*\) s$/\1/p')
if ! awk -v w="$waited" 'BEGIN { exit !(w != "" && w >= 0.3 && w <= 0.405) }'; then
  fail "remaining: expected a wait of about 0.4 s, got: $(field remaining g message)"
fi
within remaining g time_white 0.59 1.5

# A bot that does not answer quit after a played game is killed, with a
# note on stderr; its record stands, written before quit is asked, and
# the arena goes on with the later games.
{
  printf 'network\tpass\t%s\nbot\tfake\ngame\tg\tpass\tfake\n' "$tmp/pass.ann"
  printf 'command\tg\twhite\t./fakebot --pid %s --ignore-signals --stay quit=hang\ngame\tpp\tpass\tpass\n' \
    "$tmp/quit.pid"
} >"$tmp/quit.manifest"
./arena --mixed 5 6.5 10 600 2 10 "$tmp/quit.manifest" >"$tmp/quit" 2>"$tmp/quit.err" &
job=$!
watch quit "$job"
if wait_for "$tmp/quit" "^g${T}"; then
  if ! kill -0 "$job" 2>/dev/null || grep -q "^pp${T}" "$tmp/quit"; then
    fail "quit: the record was not written before quit was waited for: $(cat "$tmp/quit")"
  fi
fi
status=0
{ wait "$job" || status=$?; } 2>/dev/null
hung quit
exits quit 0
order quit "arena protocol 3 ready|g|pp|done 2|"
expect_line quit g "g${T}result=W+6.5${T}end=passes${T}length=2${T}time_black=T${T}time_white=T${T}duration=T${T}moves=pass,pass${T}ok"
if ! grep -q "^arena: game g: the white bot did not answer quit in time and was killed$" "$tmp/quit.err"; then
  fail "quit: no note on stderr: $(cat "$tmp/quit.err")"
fi
gone quit "$tmp/quit.pid"

# A bot that hangs mid-chunk: its game's failure record is written after
# the records before it, a one-sided network_error among them; the arena
# exits 2 at once, without waiting on the other bot, which does not
# answer quit, and without the later games; and no bot is left.
{
  printf 'network\tpass\t%s\nnetwork\tmissing\t%s\nbot\tfake\n' "$tmp/pass.ann" "$tmp/missing.ann"
  printf 'game\tpp\tpass\tpass\ngame\tmissing\tpass\tmissing\ngame\thang\tfake\tfake\n'
  printf 'command\thang\tblack\t./fakebot --pid %s --ignore-signals --stay genmove=hang\n' "$tmp/hang-b.pid"
  printf 'command\thang\twhite\t./fakebot --pid %s --ignore-signals --stay quit=hang\n' "$tmp/hang-w.pid"
  printf 'game\tlater\tpass\tfake\ncommand\tlater\twhite\t./fakebot --pid %s\n' "$tmp/hang-later.pid"
} >"$tmp/hang.manifest"
bots hang 10 0.5 10 0.5
exits hang 2
order hang "arena protocol 3 ready|pp|missing|hang|"
expect_line hang pp "pp${T}result=W+6.5${T}end=passes${T}length=2${T}time_black=T${T}time_white=T${T}duration=T${T}moves=pass,pass${T}ok"
expect_line hang missing "missing${T}end=network_error${T}error=white${T}message=cannot open $tmp/missing.ann${T}ok"
expect_line hang hang "hang${T}end=timeout${T}error=black${T}length=0${T}time_black=T${T}time_white=T${T}duration=T${T}moves=${T}message=genmove: no answer to genmove within 1.000 s${T}ok"
if [ "$took" -gt 5 ]; then
  fail "hang: the arena took $took s to stop, not about 1 s"
fi
gone hang "$tmp/hang-b.pid"
gone hang "$tmp/hang-w.pid"
if [ -e "$tmp/hang-later.pid" ]; then
  fail "hang: the game after the failure started its bot"
fi

# The header comes before any network is loaded: with a network read from
# a FIFO, the arena writes the header and then waits to load it.
mkfifo "$tmp/network.fifo"
printf 'network\tfifo\t%s\ngame\tpp\tfifo\tfifo\n' "$tmp/network.fifo" >"$tmp/fifo-manifest"
./arena --mixed 5 6.5 10 600 10 10 "$tmp/fifo-manifest" >"$tmp/fifo" 2>"$tmp/fifo.err" &
job=$!
watch fifo "$job"
n=0
until [ -s "$tmp/fifo" ] || [ "$n" -gt 100 ]; do
  n=$((n + 1))
  sleep 0.1
done
if [ "$(cat "$tmp/fifo")" != "arena protocol 3 ready" ]; then
  fail "fifo: expected only the header while the network is unread, got: $(cat "$tmp/fifo")"
fi
cat "$tmp/pass.ann" >"$tmp/network.fifo"
status=0
{ wait "$job" || status=$?; } 2>/dev/null
hung fifo
exits fifo 0
expect_line fifo pp "pp${T}result=W+6.5${T}end=passes${T}length=2${T}time_black=T${T}time_white=T${T}duration=T${T}moves=pass,pass${T}ok"


# SIGINT and SIGTERM while a bot is thinking: the arena kills the bot and
# dies by the signal, with the records before and none for the game it
# played. A background job starts with SIGINT ignored; fakebot --exec
# restores its default action, as a terminal's Ctrl-C finds it.
interrupt() {
  name=$1 signal=$2 want=$3
  {
    printf 'network\tpass\t%s\nbot\tfake\ngame\tpp\tpass\tpass\n' "$tmp/pass.ann"
    printf 'game\tg\tpass\tfake\ncommand\tg\twhite\t./fakebot --pid %s --log %s --ignore-signals --stay genmove=hang\n' \
      "$tmp/$name.pid" "$tmp/$name.log"
  } >"$tmp/$name.manifest"
  ./fakebot --exec ./arena --mixed 5 6.5 10 600 10 10 "$tmp/$name.manifest" >"$tmp/$name" 2>"$tmp/$name.err" &
  job=$!
  watch "$name" "$job"
  wait_for "$tmp/$name.log" genmove || { kill -9 "$job"; return; }
  kill -"$signal" "$job"
  status=0
  { wait "$job" || status=$?; } 2>/dev/null
  hung "$name"
  exits "$name" "$want"
  order "$name" "arena protocol 3 ready|pp|"
  gone "$name" "$tmp/$name.pid"
}
interrupt sigint INT 130
interrupt sigterm TERM 143

# After a SIGKILL the arena cannot clean up: a bot that exits at stdin EOF,
# as Brown, AmiGo, michi-c2 and GNU Go do, ends by itself, but one that
# ignores EOF is left running (in its own process group). This pins what
# the docs say.
{
  printf 'bot\tfake\ngame\tg\tfake\tfake\n'
  printf 'command\tg\tblack\t./fakebot --pid %s --log %s --stay genmove=hang\n' "$tmp/killed-b.pid" "$tmp/killed.log"
  printf 'command\tg\twhite\t./fakebot --pid %s\n' "$tmp/killed-w.pid"
} >"$tmp/killed.manifest"
./arena --mixed 5 6.5 10 600 10 10 "$tmp/killed.manifest" >"$tmp/killed" 2>"$tmp/killed.err" &
job=$!
watch killed "$job"
if wait_for "$tmp/killed.log" genmove; then
  kill -9 "$job"
  { wait "$job" || :; } 2>/dev/null
  n=0
  while kill -0 "$(cut -d' ' -f1 "$tmp/killed-w.pid")" 2>/dev/null && [ "$n" -lt 50 ]; do
    n=$((n + 1))
    sleep 0.1
  done
  gone killed "$tmp/killed-w.pid"
  orphan=$(cut -d' ' -f1 "$tmp/killed-b.pid")
  if kill -0 "$orphan" 2>/dev/null; then
    kill -9 "$orphan"
  else
    fail "killed: the bot that ignores EOF is gone after the arena's SIGKILL; update the docs"
  fi
else
  kill -9 "$job"
fi

# A failed write to stdout is the arena's error (exit 1 with a message),
# not a SIGPIPE, which the arena ignores while bots run; its bot is
# killed. The reader stops after the header, before the first record.
{
  printf 'network\tpass\t%s\nbot\tfake\n' "$tmp/pass.ann"
  printf 'game\tg\tpass\tfake\ncommand\tg\twhite\t./fakebot --pid %s --stay genmove=sleep:0.3\n' "$tmp/closed.pid"
} >"$tmp/closed.manifest"
{
  status=0
  ./arena --mixed 5 6.5 10 600 10 10 "$tmp/closed.manifest" 2>"$tmp/closed.err" || status=$?
  printf '%s\n' "$status" >"$tmp/closed.status"
} | head -1 >/dev/null
if [ "$(cat "$tmp/closed.status")" != 1 ] || ! grep -q 'cannot write' "$tmp/closed.err"; then
  fail "closed: expected exit status 1 and 'cannot write', got $(cat "$tmp/closed.status"): $(cat "$tmp/closed.err")"
fi
gone closed "$tmp/closed.pid"
# The same in a chunk without bots, since SIGPIPE is ignored from the
# start: here the network comes from a FIFO, fed once the reader is gone.
rm -f "$tmp/network.fifo" "$tmp/closed-net.status"
mkfifo "$tmp/network.fifo"
{
  status=0
  ./arena --mixed 5 6.5 10 600 10 10 "$tmp/fifo-manifest" 2>"$tmp/closed-net.err" || status=$?
  printf '%s\n' "$status" >"$tmp/closed-net.status"
} | head -1 >"$tmp/closed-net.head" &
reader=$!
n=0
while kill -0 "$reader" 2>/dev/null && [ "$n" -lt 100 ]; do
  n=$((n + 1))
  sleep 0.1
done
cat "$tmp/pass.ann" >"$tmp/network.fifo"
n=0
until [ -s "$tmp/closed-net.status" ] || [ "$n" -gt 100 ]; do
  n=$((n + 1))
  sleep 0.1
done
if [ "$(cat "$tmp/closed-net.status" 2>/dev/null)" != 1 ] || ! grep -q 'cannot write' "$tmp/closed-net.err"; then
  fail "closed-net: expected exit status 1 and 'cannot write', got $(cat "$tmp/closed-net.status" 2>/dev/null): $(cat "$tmp/closed-net.err")"
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi
printf 'The arena played, ended, and reported its games as expected, and refused bad input\n'
