#!/bin/sh
set -eu

# Plays a short GTP session against evo with the 9x9 example network and
# checks each answer. A network that does not fit the board must be refused
# with a GTP error, not end the process.

cd "$(dirname "$0")"

output=$(./evo example.ann 2>/dev/null <<'EOF'
name
boardsize 5
genmove b
boardsize 9
komi 6.5
clear_board
genmove b
genmove w
quit
EOF
) || true

# GTP answers are separated by blank lines; keep one answer per line.
answers=$(printf '%s\n' "$output" | grep -v '^$')
expected_prefixes='= Evo
? unacceptable size
? network does not fit the board
=
=
=
=
=
='

failed=0
i=1
printf '%s\n' "$expected_prefixes" | while IFS= read -r want; do
  got=$(printf '%s\n' "$answers" | sed -n "${i}p")
  case "$got" in
    "$want"*) ;;
    *) printf 'answer %d: expected "%s...", got "%s"\n' "$i" "$want" "$got" >&2; exit 1 ;;
  esac
  i=$((i + 1))
done || failed=1

count=$(printf '%s\n' "$answers" | wc -l | tr -d ' ')
if [ "$count" -ne 9 ]; then
  printf 'expected 9 answers, got %s:\n%s\n' "$count" "$answers" >&2
  failed=1
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi
printf 'GTP session answered as expected\n'
