#!/bin/sh
set -eu

# Wait for a pull request's CI and fail unless every check passed on the
# commit checked out here. `gh pr checks --watch` alone is not enough: it
# errors before any check has registered, and its exit status can miss a
# check that is absent from its table.

pr=${1:?usage: mise run pr-checks PR}

local_head=$(git rev-parse HEAD)
pr_head=$(gh pr view "$pr" --json headRefOid --jq .headRefOid)
if [ "$local_head" != "$pr_head" ]; then
  printf 'PR %s is at %s, but HEAD is %s. Push first.\n' "$pr" "$pr_head" "$local_head" >&2
  exit 1
fi

# Check runs report their result in `conclusion`, status contexts in `state`.
# `status` only says whether a check has finished. An empty result means the
# check is still running.
not_passed() {
  gh pr view "$pr" --json statusCheckRollup --jq '
    if (.statusCheckRollup | length) == 0 then "NO CHECKS"
    else .statusCheckRollup[]
      | ((.conclusion // "") + (.state // "")) as $s
      | select($s != "SUCCESS" and $s != "SKIPPED" and $s != "NEUTRAL")
      | [(if $s == "" then "PENDING" else $s end), (.name // .context)]
      | @tsv
    end'
}

# Checks register a few seconds after a push.
tries=0
while [ "$(not_passed)" = "NO CHECKS" ]; do
  tries=$((tries + 1))
  if [ "$tries" -gt 30 ]; then
    printf 'No checks registered for PR %s after 5 minutes.\n' "$pr" >&2
    exit 1
  fi
  sleep 10
done

gh pr checks "$pr" --watch --interval 20 >/dev/null 2>&1 || true

remaining=$(not_passed)
if [ -n "$remaining" ]; then
  printf 'Checks that did not pass on %s:\n%s\n' "$local_head" "$remaining" >&2
  exit 1
fi
printf 'All checks passed on %s.\n' "$local_head"
