#!/bin/sh
set -eu

missing=0
for program in gnugo gogui gogui-twogtp brown amigogtp java; do
  if command -v "$program" >/dev/null 2>&1; then
    printf '%s: %s\n' "$program" "$(command -v "$program")"
  else
    printf '%s: missing\n' "$program" >&2
    missing=1
  fi
done

if [ "$missing" -ne 0 ]; then
  printf 'Install the missing Go programs listed in README.md before running an experiment.\n' >&2
  exit 1
fi
