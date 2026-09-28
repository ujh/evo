#!/bin/sh
set -eu

# Checks the bot controller (bot.c) through botdriver against fakebot, a
# scripted fake GTP program, so it needs no real bot (CI's c-tests job and
# the gcc:14 check have none; scripts/smoke-bot-controller.sh runs the
# real ones): argument splitting as twogtp's, launching, command IDs, the
# answer parser, deadlines, a bot that dies, hangs, or floods, cleanup on
# exit and on signals, and the exit status a signal leaves through sh -c.

cd "$(dirname "$0")"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0
T=$(printf '\t')

fail() {
  printf '%s\n' "$*" >&2
  failed=1
}

# watch NAME PID: stops PID if it still runs after 60 s (no test takes
# 10), so a hang fails the test instead of stopping it: first with
# SIGTERM, which the driver answers by killing its bots (a SIGKILL would
# leave a bot that ignores stdin EOF running), then with SIGKILL. The
# watcher ends by itself soon after PID does.
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

# hung NAME: when the watcher had to kill NAME's job, fails and stops
# the tests at once, since what hung one would hang the rest.
hung() {
  if [ -e "$tmp/$1.hung" ]; then
    printf '%s: hung, killed after 60 s\n' "$1" >&2
    exit 1
  fi
}

# run NAME: runs botdriver script on stdin, output in $tmp/NAME, killed
# by a watcher if it hangs. A background job's stdin is /dev/null, so
# the script goes through a file.
run() {
  cat >"$tmp/$1.in"
  ./botdriver script <"$tmp/$1.in" >"$tmp/$1" 2>"$tmp/$1.err" &
  job=$!
  watch "$1" "$job"
  status=0
  # The braces keep the shell's report of a crash out of the output.
  { wait "$job" || status=$?; } 2>/dev/null
  hung "$1"
}

# expect NAME LINE...: the output's lines without the seconds column,
# and a start without its pid.
expect() {
  name=$1
  shift
  got=$(cut -f1,2,4 "$tmp/$name" | sed "s/^start${T}ok${T}pid=[0-9]*\$/start${T}ok/")
  want=$(printf '%s\n' "$@")
  if [ "$got" != "$want" ]; then
    fail "$name: expected
$want
got
$got
stderr: $(cat "$tmp/$name.err")"
  fi
}

# seconds NAME LINE MIN MAX: line LINE's seconds column is within [MIN, MAX].
seconds() {
  s=$(sed -n "$2p" "$tmp/$1" | cut -f3)
  if ! awk -v s="$s" -v lo="$3" -v hi="$4" 'BEGIN { exit !(s >= lo && s <= hi) }'; then
    fail "$1: line $2 took $s s, expected $3 to $4"
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

# Splitting, as twogtp's StringUtil.splitArguments: each case checked
# against GoGui 1.6.0's own function.
split_case() {
  printf 'split %s\n' "$1" | run split
  got=$(cut -f2,4 "$tmp/split")
  if [ "$got" != "$2" ]; then
    fail "split '$1': expected '$2', got '$got'"
  fi
}
split_case 'brown' "1${T}[brown]"
split_case 'gnugo --level 0 --mode gtp --seed 12' "7${T}[gnugo][--level][0][--mode][gtp][--seed][12]"
split_case '  a   b  ' "2${T}[a][b]"
split_case "a${T}b" "2${T}[a][b]"
split_case 'a "b c" d' "3${T}[a][b c][d]"
split_case 'ab"c d"e' "2${T}[abc d][e]"
split_case '"a"b' "2${T}[a][b]"
split_case '""' "1${T}[]"
split_case 'a "" b' "3${T}[a][][b]"
split_case 'a\"b c' "2${T}[a\\\"b][c]"
split_case 'a\\"b c"' "1${T}[a\\\\b c]"
split_case '"a\" b"' "1${T}[a\\\" b]"
split_case '"unclosed a  b' "1${T}[unclosed a  b]"
split_case '"' "0${T}"
split_case ' ' "0${T}"
# U+2003 (em space) separates, as Java's isWhitespace says; U+00A0
# (no-break space) does not.
split_case "$(printf 'a\342\200\203b')" "2${T}[a][b]"
split_case "$(printf 'a\302\240b')" "1${T}[$(printf 'a\302\240b')]"
split_case "$(printf 'a\037b')" "2${T}[a][b]"

# Launching: what cannot start is refused with a reason; a program name
# without a slash that is a file in the working directory is that file,
# as twogtp makes it absolute.
printf 'not a program\n' >"$tmp/plain"
run launch <<EOF
start a ./no-such-program --mode gtp
start a "
start a $tmp/plain
start a "" x
start a fakebot
send a 5 name
quit a 5
EOF
expect launch "start${T}launch${T}cannot start ./no-such-program: No such file or directory" \
  "start${T}launch${T}the command names no program" \
  "start${T}launch${T}cannot start $tmp/plain: Permission denied" \
  "start${T}launch${T}cannot start : No such file or directory" \
  "start${T}ok" "send${T}ok${T}fake" "quit${T}answered${T}"
if ! grep -q "^start${T}ok${T}[0-9.]*${T}pid=[0-9][0-9]*$" "$tmp/launch"; then
  fail "launch: no pid: $(cat "$tmp/launch")"
fi

# Commands get increasing IDs; answers are "=" or "?", with empty,
# multi-line, trailing-space, and CRLF replies, and junk lines before an
# answer are skipped. known_command ignores case.
run replies <<EOF
start a ./fakebot --log $tmp/replies.log --banner "GNU Go banner\n\n" "unknown=err:unknown command" "list=ok:a\nb  \n c" "crlf=raw:=%i \t G7  \r\n\r\n" junk=raw:junk\n=%i\tx\n\n "known_command#1=ok:TRUE" "known_command#2=ok:False" "known_command#3=ok:yes" "known_command#4=err:no"
send a 5 name
send a 5 boardsize 9
send a 5 unknown
send a 5 list
send a 5 crlf
send a 5 junk
known a 5 time_settings
known a 5 time_settings
known a 5 time_settings
known a 5 time_settings
quit a 5
EOF
expect replies "start${T}ok" "send${T}ok${T}fake" "send${T}ok${T}" "send${T}error${T}unknown command" \
  "send${T}ok${T}a\\nb  \\n c" "send${T}ok${T}G7" "send${T}ok${T}x" "known${T}ok${T}1" "known${T}ok${T}0" \
  "known${T}ok${T}0" "known${T}error${T}no" "quit${T}answered${T}"
want=$(printf '%s\n' '1 name' '2 boardsize 9' '3 unknown' '4 list' '5 crlf' '6 junk' '7 known_command time_settings' \
  '8 known_command time_settings' '9 known_command time_settings' '10 known_command time_settings' '11 quit')
if [ "$(cat "$tmp/replies.log")" != "$want" ]; then
  fail "replies: the bot read $(cat "$tmp/replies.log")"
fi

# An answer with another ID, without one, or too long, and a bot that
# floods, are not GTP: the bot is killed, and later calls find it gone.
run protocol <<EOF
start a ./fakebot --pid $tmp/protocol-a.pid "name=raw:=99 fake\n\n"
send a 5 name
send a 5 name
start b ./fakebot "name=raw:= fake\n\n"
send b 5 name
start c ./fakebot name=flood
send c 5 name
start d ./fakebot "name=raw:=%ix\n\n"
send d 5 name
start e ./fakebot --pid $tmp/protocol-e.pid "name=raw:=%i$(awk 'BEGIN { while (n++ < 70) { printf "\\n"; for (k = 0; k < 1000; k++) printf "x" } }')\n\n"
send e 5 name
send e 5 name
EOF
expect protocol "start${T}ok" "send${T}protocol${T}answered with ID 99 to command 1" "send${T}died${T}the bot is gone" \
  "start${T}ok" "send${T}protocol${T}answered without ID to command 1" \
  "start${T}ok" "send${T}protocol${T}a line longer than 65536 bytes" \
  "start${T}ok" "send${T}protocol${T}answered with ID 1x to command 1" \
  "start${T}ok" "send${T}protocol${T}an answer longer than 65536 bytes" "send${T}died${T}the bot is gone"
gone protocol "$tmp/protocol-a.pid"
gone protocol "$tmp/protocol-e.pid"

# Deadlines: a slow answer within its deadline is fine; a missing one, or
# half an answer, times out at the deadline (1 s: the bounds allow a busy
# machine but not twice the deadline), and the bot is killed even when it
# ignores SIGTERM and stdin EOF: it is gone while the controller still
# runs, before any exit cleanup.
cat >"$tmp/deadline.in" <<EOF
start a ./fakebot --pid $tmp/deadline-a.pid --ignore-signals --stay genmove#1=sleep:0.4 genmove#2=hang
send a 5 genmove b
send a 1 genmove b
start b ./fakebot --pid $tmp/deadline-b.pid --ignore-signals --stay "genmove=raw:=%i C3\n"
send b 1 genmove b
wait 5
EOF
: >"$tmp/deadline"
./botdriver script <"$tmp/deadline.in" >"$tmp/deadline" 2>"$tmp/deadline.err" &
job=$!
watch deadline "$job"
n=0
until [ "$(wc -l <"$tmp/deadline")" -ge 5 ] || [ "$n" -gt 100 ]; do
  n=$((n + 1))
  sleep 0.1
done
gone deadline "$tmp/deadline-a.pid"
gone deadline "$tmp/deadline-b.pid"
if ! kill -0 "$job" 2>/dev/null; then
  fail "deadline: the driver ended before the bots were checked"
fi
{ wait "$job" || :; } 2>/dev/null
hung deadline
expect deadline "start${T}ok" "send${T}ok${T}pass" "send${T}timeout${T}no answer to genmove within 1.000 s" \
  "start${T}ok" "send${T}timeout${T}no answer to genmove within 1.000 s" "wait${T}ok${T}"
seconds deadline 2 0.35 3
seconds deadline 3 0.99 1.6
seconds deadline 5 0.99 1.6

# A bot that exits, crashes, or closes its output dies; its exit status
# or signal is the message. Writing to a bot that has exited is an error,
# not a SIGPIPE that kills the controller.
run died <<EOF
start a ./fakebot genmove=exit:3
send a 5 genmove b
start b ./fakebot genmove=crash
send b 5 genmove b
start c ./fakebot --pid $tmp/died-c.pid genmove=close
send c 5 genmove b
start d ./fakebot
send d 5 quit
wait 0.3
send d 5 name
send d 5 name
split still here
EOF
expect died "start${T}ok" "send${T}died${T}exited with status 3" "start${T}ok" "send${T}died${T}killed by signal 11" \
  "start${T}ok" "send${T}died${T}closed its output" "start${T}ok" "send${T}ok${T}" "wait${T}ok${T}" \
  "send${T}died${T}exited with status 0" "send${T}died${T}the bot is gone" "split${T}2${T}[still][here]"
gone died "$tmp/died-c.pid"

# A bot that stops reading its input times out on writing, too.
run stuck <<EOF
start a ./fakebot --pid $tmp/stuck.pid --no-read
send a 1 play b $(awk 'BEGIN { while (n++ < 200000) printf "x" }')
EOF
expect stuck "start${T}ok" "send${T}timeout${T}no answer to play within 1.000 s"
seconds stuck 2 0.99 1.6
gone stuck "$tmp/stuck.pid"

# setup: known_command time_settings, then twogtp's sequence for a game:
# boardsize, clear_board, komi as twogtp writes it, boardsize and
# clear_board again, and time_settings only when known, with whole
# seconds. A failure on the second boardsize or clear_board is named.
run setup <<EOF
start a ./fakebot --log $tmp/setup-a.log
setup a 5 9 6.5 600
setup a 5 19 7 0.5
setup a 5 9 -0.125 1
setup a 5 9 6.0001 1
quit a 5
start b ./fakebot --log $tmp/setup-b.log known_command=ok:true
setup b 5 9 6.5 0.5
quit b 5
start c ./fakebot known_command=ok:true "time_settings=err:no time"
setup c 5 9 6.5 600
start d ./fakebot "boardsize=err:unacceptable size"
setup d 5 9 6.5 600
start e ./fakebot komi=hang
setup e 0.2 9 6.5 600
start f ./fakebot known_command=exit:1
setup f 5 9 6.5 600
start g ./fakebot "boardsize#2=err:not twice"
setup g 5 9 6.5 600
start h ./fakebot clear_board#2=hang
setup h 0.2 9 6.5 600
EOF
expect setup "start${T}ok" "setup${T}ok${T}" "setup${T}ok${T}" "setup${T}ok${T}" "setup${T}ok${T}" "quit${T}answered${T}" \
  "start${T}ok" "setup${T}ok${T}" "quit${T}answered${T}" \
  "start${T}ok" "setup${T}error${T}time_settings: no time" \
  "start${T}ok" "setup${T}error${T}boardsize: unacceptable size" \
  "start${T}ok" "setup${T}timeout${T}komi: no answer to komi within 0.200 s" \
  "start${T}ok" "setup${T}died${T}known_command: exited with status 1" \
  "start${T}ok" "setup${T}error${T}boardsize: not twice" \
  "start${T}ok" "setup${T}timeout${T}clear_board: no answer to clear_board within 0.200 s"
want=$(printf '%s\n' '1 known_command time_settings' '2 boardsize 9' '3 clear_board' '4 komi 6.5' '5 boardsize 9' \
  '6 clear_board' '7 known_command time_settings' '8 boardsize 19' '9 clear_board' '10 komi 7' '11 boardsize 19' \
  '12 clear_board' '13 known_command time_settings' '14 boardsize 9' '15 clear_board' '16 komi -0.125' \
  '17 boardsize 9' '18 clear_board' '19 known_command time_settings' '20 boardsize 9' '21 clear_board' '22 komi 6' \
  '23 boardsize 9' '24 clear_board' '25 quit')
if [ "$(cat "$tmp/setup-a.log")" != "$want" ]; then
  fail "setup: a bot without time_settings read $(cat "$tmp/setup-a.log")"
fi
want=$(printf '%s\n' '1 known_command time_settings' '2 boardsize 9' '3 clear_board' '4 komi 6.5' '5 boardsize 9' \
  '6 clear_board' '7 time_settings 1 0 0' '8 quit')
if [ "$(cat "$tmp/setup-b.log")" != "$want" ]; then
  fail "setup: a bot with time_settings read $(cat "$tmp/setup-b.log")"
fi

# genmove replies, ignoring case.
run moves <<EOF
start a ./fakebot genmove#1=ok:c3 genmove#2=ok:PASS genmove#3=ok:Resign genmove#4=ok:J9 genmove#5=ok:I5 genmove#6=ok:K1 genmove#7=ok:A0 genmove#8=ok:A10 genmove#9=ok:a01 genmove#10=ok:t19 "genmove#11=ok:A1 B2" genmove#12=ok:
genmove a 5 b 9
genmove a 5 b 9
genmove a 5 b 9
genmove a 5 b 9
genmove a 5 b 9
genmove a 5 b 9
genmove a 5 b 9
genmove a 5 b 9
genmove a 5 b 9
genmove a 5 b 19
genmove a 5 b 9
genmove a 5 b 9
EOF
expect moves "start${T}ok" "genmove${T}ok${T}point 2 2" "genmove${T}ok${T}pass" "genmove${T}ok${T}resign" \
  "genmove${T}ok${T}point 8 8" "genmove${T}ok${T}invalid I5" "genmove${T}ok${T}invalid K1" "genmove${T}ok${T}invalid A0" \
  "genmove${T}ok${T}invalid A10" "genmove${T}ok${T}invalid a01" "genmove${T}ok${T}point 18 18" \
  "genmove${T}ok${T}invalid A1 B2" "genmove${T}ok${T}invalid "

# quit: the exit status after quit is ignored; a bot that answers but
# stays is killed at the deadline; one that does not answer is killed.
# A later bot does not hold an earlier one's pipes (close-on-exec), so
# closing its stdin reaches it as EOF.
run quit <<EOF
start a ./fakebot --quit-status 7
quit a 5
start b ./fakebot --pid $tmp/quit-b.pid --stay quit=ok:bye
quit b 0.3
start c ./fakebot --pid $tmp/quit-c.pid quit=hang --stay
quit c 0.3
start d ./fakebot --fds $tmp/quit-d.fds --log $tmp/quit-d.log quit=ok:bye
start e ./fakebot --fds $tmp/quit-e.fds
quit d 5
quit e 5
EOF
expect quit "start${T}ok" "quit${T}answered${T}" "start${T}ok" "quit${T}answered${T}" "start${T}ok" "quit${T}unanswered${T}" \
  "start${T}ok" "start${T}ok" "quit${T}answered${T}" "quit${T}answered${T}"
seconds quit 4 0.29 1.5
seconds quit 6 0.29 1.5
seconds quit 9 0 1
gone quit "$tmp/quit-b.pid"
gone quit "$tmp/quit-c.pid"
if [ "$(tail -1 "$tmp/quit-d.log")" != EOF ]; then
  fail "quit: bot d saw no EOF: $(cat "$tmp/quit-d.log")"
fi
if [ "$(cat "$tmp/quit-d.fds")" != "$(cat "$tmp/quit-e.fds")" ]; then
  fail "quit: the second bot has $(cat "$tmp/quit-e.fds") descriptors above 2, the first $(cat "$tmp/quit-d.fds")"
fi

# A bot's stderr goes to the controller's.
run stderr <<EOF
start a ./fakebot --stderr "a note from the bot"
quit a 5
EOF
if ! grep -q '^a note from the bot$' "$tmp/stderr.err"; then
  fail "stderr: the bot's note is missing: $(cat "$tmp/stderr.err")"
fi

# A bot runs in its own process group, so a terminal's Ctrl-C does not
# reach it.
run group <<EOF
start a ./fakebot --pid $tmp/group.pid
quit a 5
EOF
read -r pid pgid <"$tmp/group.pid"
if [ "$pid" != "$pgid" ]; then
  fail "group: the bot $pid is in process group $pgid"
fi

# An exit with bots running kills them; so does a crash, which then
# kills the controller by its signal. The bots here ignore SIGTERM and
# stdin EOF, so only SIGKILL ends them.
run exit <<EOF
start a ./fakebot --pid $tmp/exit.pid --ignore-signals --stay
send a 5 name
exit 5
EOF
[ "$status" -eq 5 ] || fail "exit: expected status 5, got $status"
gone exit "$tmp/exit.pid"
run crash <<EOF
start a ./fakebot --pid $tmp/crash.pid --ignore-signals --stay
send a 5 name
crash
EOF
[ "$status" -eq 139 ] || fail "crash: expected status 139 (SIGSEGV), got $status"
gone crash "$tmp/crash.pid"

# SIGINT and SIGTERM while a bot is running kill the bot, then the
# controller by the same signal, whether it runs under sh -c or
# sh -c 'exec ...': the status a parent sees is 128 + the signal. A
# background job starts with SIGINT ignored, so fakebot --exec restores
# its default action first, as a foreground job has it.
signal_case() {
  name=$1 signal=$2 want=$3 exec=$4
  rm -f "$tmp/$name.log" "$tmp/$name.driver"
  printf '%s\n' "start a ./fakebot --pid $tmp/$name.pid --log $tmp/$name.log --ignore-signals --stay genmove=hang" \
    "pid $tmp/$name.driver" "send a 100 genmove b" >"$tmp/$name.in"
  ./fakebot --exec sh -c "$exec./botdriver script <'$tmp/$name.in' >'$tmp/$name' 2>'$tmp/$name.err'" 2>/dev/null &
  job=$!
  watch "$name" "$job"
  wait_for "$tmp/$name.log" genmove || { kill -9 "$job"; return; }
  driver=$(cat "$tmp/$name.driver")
  if [ -n "$exec" ] && [ "$driver" != "$job" ]; then
    fail "$name: the driver's pid $driver is not the job's $job"
  fi
  kill -"$signal" "$driver"
  status=0
  { wait "$job" || status=$?; } 2>/dev/null
  hung "$name"
  [ "$status" -eq "$want" ] || fail "$name: expected status $want, got $status"
  gone "$name" "$tmp/$name.pid"
}
signal_case sigint INT 130 ''
signal_case sigint-exec INT 130 'exec '
signal_case sigterm TERM 143 ''
signal_case sigterm-exec TERM 143 'exec '

# A signal ignored when the controller started stays ignored (here SIGINT,
# as a background job gets it); SIGTERM still works.
printf '%s\n' "start a ./fakebot --pid $tmp/ignored.pid --log $tmp/ignored.log --stay genmove=hang" \
  "pid $tmp/ignored.driver" "send a 100 genmove b" >"$tmp/ignored.in"
./botdriver script <"$tmp/ignored.in" >"$tmp/ignored" 2>"$tmp/ignored.err" &
job=$!
watch ignored "$job"
if wait_for "$tmp/ignored.log" genmove; then
  kill -INT "$job"
  sleep 0.3
  if ! kill -0 "$job" 2>/dev/null; then
    fail "ignored: an ignored SIGINT stopped the controller"
  fi
  kill -TERM "$job"
  status=0
  { wait "$job" || status=$?; } 2>/dev/null
  hung ignored
  [ "$status" -eq 143 ] || fail "ignored: expected status 143, got $status"
  gone ignored "$tmp/ignored.pid"
else
  kill -9 "$job"
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi
printf 'The bot controller started, drove, timed, and cleaned up its fake bots as expected\n'
