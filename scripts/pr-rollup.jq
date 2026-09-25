# Reads `gh pr view --json headRefOid,statusCheckRollup` and prints one line
# for each reason the PR is not green on $head. No output means every check
# passed on that commit. Run it with `jq -n`: `input` then fails on blank
# input instead of printing nothing, which would read as green.
#
# Check runs report their result in `conclusion`, status contexts in `state`.
# `status` only says whether a check has finished. An empty result means the
# check is still running. A re-run check keeps its older runs in the rollup,
# so only the latest run of each check counts. gh reports a run that has not
# started yet with the zero time (0001-01-01...), so that run ranks newest.
input
| if .headRefOid != $head then
  "HEAD MOVED\t\(.headRefOid)"
elif ((.statusCheckRollup // []) | length) == 0 then
  "NO CHECKS"
else
  .statusCheckRollup
  | group_by([.workflowName // "", .name // .context])
  | map(max_by((.startedAt // "") | if . == "" or startswith("0001-") then "9999" else . end))
  | .[]
  | ((.conclusion // "") + (.state // "")) as $s
  | select($s != "SUCCESS" and $s != "SKIPPED" and $s != "NEUTRAL")
  | [(if $s == "" then "PENDING" else $s end), (.name // .context)]
  | @tsv
end
