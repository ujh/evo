#!/bin/sh
set -eu

# List all feedback on a pull request: reviews (summary text and change
# requests), inline comments, and top-level comments. They come from three
# separate GitHub endpoints, and each one is paginated.

# The REST paths need the number; gh pr view also accepts a URL or branch.
pr=$(gh pr view "${1:?usage: mise run pr-feedback PR}" --json number --jq .number)

printf '## Reviews\n'
gh api --paginate "repos/{owner}/{repo}/pulls/$pr/reviews" --jq '
  .[] | select(.body != "" or .state == "CHANGES_REQUESTED")
  | "- [\(.id)] \(.user.login) \(.state): \(.body)"'

printf '\n## Inline comments (reply with: gh api repos/{owner}/{repo}/pulls/%s/comments -F in_reply_to=ID -f body=...)\n' "$pr"
gh api --paginate "repos/{owner}/{repo}/pulls/$pr/comments" --jq '
  .[] | "- [\(.id)]\(if .in_reply_to_id then " reply to \(.in_reply_to_id)" else "" end) \(.user.login) \(.path):\(.line // .original_line): \(.body)"'

printf '\n## Top-level comments (answer with: gh pr comment %s --body ...)\n' "$pr"
gh api --paginate "repos/{owner}/{repo}/issues/$pr/comments" --jq '
  .[] | "- [\(.id)] \(.user.login): \(.body)"'
