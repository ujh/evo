#!/bin/sh
set -eu

# Wait for a pull request's CI and fail unless every check passed on the
# commit checked out here. `gh pr checks --watch` alone is not enough: it
# errors before any check has registered, and its exit status can miss a
# check that is absent from its table.

pr=${1:?usage: mise run pr-checks PR}
head=$(git rev-parse HEAD)
filter="$(dirname "$0")/pr-rollup.jq"

not_passed() {
  gh pr view "$pr" --json headRefOid,statusCheckRollup | jq -r --arg head "$head" -f "$filter"
}

head_moved() {
  case "$1" in
    'HEAD MOVED'*)
      printf 'PR %s is at %s, but HEAD is %s. Push, or check out the PR head.\n' \
        "$pr" "$(printf '%s' "$1" | cut -f 2)" "$head" >&2
      exit 1
      ;;
  esac
}

# Checks register a few seconds after a push.
tries=0
while :; do
  result=$(not_passed)
  head_moved "$result"
  [ "$result" = "NO CHECKS" ] || break
  tries=$((tries + 1))
  if [ "$tries" -gt 30 ]; then
    printf 'No checks registered for PR %s after 5 minutes.\n' "$pr" >&2
    exit 1
  fi
  sleep 10
done

gh pr checks "$pr" --watch --interval 20 >/dev/null 2>&1 || true

result=$(not_passed)
head_moved "$result"
if [ -n "$result" ]; then
  printf 'Checks that did not pass on %s:\n%s\n' "$head" "$result" >&2
  exit 1
fi
printf 'All checks passed on %s.\n' "$head"
