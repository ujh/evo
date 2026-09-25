#!/bin/sh
set -eu

# Wait for a pull request's CI and fail unless every check passed on the
# commit checked out here. `gh pr checks --watch` alone is not enough: it
# errors before any check has registered, and its exit status can miss a
# check that is absent from its table.

pr=${1:?usage: mise run pr-checks PR}
head=$(git rev-parse HEAD)
filter="$(dirname "$0")/pr-rollup.jq"

# sh has no pipefail, so fetch before piping: a failed or empty gh call must
# stop the script instead of feeding jq nothing, which would read as green.
not_passed() {
  json=$(gh pr view "$pr" --json headRefOid,mergeStateStatus,statusCheckRollup) || return 1
  [ -n "$json" ] || { printf 'gh pr view returned nothing for PR %s.\n' "$pr" >&2; return 1; }
  printf '%s\n' "$json" | jq -rn --arg head "$head" -f "$filter"
}

# Problems that no amount of waiting for CI will fix.
stop_early() {
  case "$1" in
    'HEAD MOVED'*)
      printf 'PR %s is at %s, but HEAD is %s. Push, or check out the PR head.\n' \
        "$pr" "$(printf '%s' "$1" | cut -f 2)" "$head" >&2
      exit 1
      ;;
    BEHIND)
      printf 'PR %s is behind main. Update it with: gh pr update-branch %s && git pull\n' "$pr" "$pr" >&2
      printf 'Then repeat the tests and review, and run pr-checks again.\n' >&2
      exit 1
      ;;
    CONFLICTS)
      printf 'PR %s has merge conflicts with main. Merge origin/main locally, resolve them, and push.\n' "$pr" >&2
      exit 1
      ;;
  esac
}

# Checks register a few seconds after a push. The tests shorten the wait.
max_tries=${PR_CHECKS_TRIES:-30}
pause=${PR_CHECKS_SLEEP:-10}
tries=0
while :; do
  result=$(not_passed)
  stop_early "$result"
  [ "$result" = "NO CHECKS" ] || break
  tries=$((tries + 1))
  if [ "$tries" -gt "$max_tries" ]; then
    printf 'No checks registered for PR %s after %s seconds.\n' "$pr" "$((max_tries * pause))" >&2
    exit 1
  fi
  sleep "$pause"
done

gh pr checks "$pr" --watch --interval 20 >/dev/null 2>&1 || true

result=$(not_passed)
stop_early "$result"
if [ -n "$result" ]; then
  printf 'Checks that did not pass on %s:\n%s\n' "$head" "$result" >&2
  exit 1
fi
printf 'All checks passed on %s.\n' "$head"
