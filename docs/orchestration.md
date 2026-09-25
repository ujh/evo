# Larger changes: plan, delegate, review, notify

Use this for any change bigger than one PR, or one that needs several design decisions. The agent in the conversation orchestrates: it agrees the plan with the owner, hands each step to a fresh subagent, keeps the plan current, and reports once at the end. Small changes follow `docs/pull-requests.md` alone.

## 1. Agree the work with the owner

Discuss the goal and ask every question whose answer is the owner's to give (scope, trade-offs, defaults) before writing any code. Record the answers. After that, decide the rest yourself and explain those decisions in the PR descriptions; do not come back for approval on choices the owner left to you.

## 2. Write the plan

Write the plan to `plans/NAME.md` in the repository root. The directory is gitignored, so the plan survives a lost session without entering the history. It holds:

- the goal, and what must not change (for example "a seeded run gives the same births, games, and rankings as main");
- the owner's decisions and every finding declined so far, with the reason (give this list to every reviewer, so they do not raise it again);
- the design decisions you made;
- the steps as a checklist, grouped by PR, each small enough for one agent and one or two commits; tick each with its commit ids. A nit about lines a later step will rewrite goes into that step's item instead of being fixed now.

Have a fresh subagent review the plan itself before any code is written: missing cases, rules of the external tools (GoGui, GNU Go, GTP) that the design depends on, and docs that the change will make stale. Design gaps are cheapest here.

Plan PRs that can merge in order. A PR may be stacked on another branch: CI runs on every pull request, whatever its base. The repository deletes a merged PR's branch, so once the base merges, GitHub retargets the stacked PR to `main` (check with `gh pr view PR --json baseRefName`); merge `origin/main` into it and push, and `mise run pr-checks` then checks it against `main`.

Fold the review's findings into the plan, then show the plan to the owner and wait for their approval before any code is written. After that, stop only where section 5 says to.

## 3. Run each step through a subagent

Give each step to a fresh subagent with the plan's path, the step, the rules it must follow, and a short report format (commits, files, test count, every decision the plan did not settle). Each step:

- writes tests first and checks that they fail before the code exists;
- runs `mise run test` before each commit, and checks `git status` so no stray file is left or committed, and `git status --ignored` after adding files, since a rule such as `*.out` can hide a fixture the tests need;
- commits with the conventions in `CLAUDE.md` and does not push.

After each code commit, a different fresh subagent reviews that commit under the review rules in `docs/pull-requests.md`, with the owner's decisions and the declined findings. Fix blockers and important findings before the next step that depends on them. Send a fix back to the agent that wrote the step (it keeps its context), once no other agent is writing to that tree.

A reviewer builds and runs tests only in its own scratch worktree at the commit under review (`git worktree add /tmp/... COMMIT`), never in a tree a step agent is writing to: a half-finished edit there shows up as failures that are not real. The whole-branch review also builds and tests a clean checkout (`git archive HEAD` plus `pcg-c`), which is the only place an untracked or ignored file the tests need goes missing.

Independent work can run in parallel: a review of step N while step N+1 is built, or a second PR in its own `git worktree`. To set one up, link the main checkout's installed tools into it (`ln -s /path/to/checkout/.local .local`; `/.local` is gitignored), then run `mise trust` and `mise run setup` there (submodule, gems, build). Never let two agents write to the same working tree at once.

Finish with checks on real runs, not only unit tests: a seeded run compared against `main` where behavior must not change, reproducibility, and resume after an interrupt where the change touches the runner. Examples in the docs come from seeded runs, with the full command, so a reader can repeat them.

## 4. Open the PRs

Follow `docs/pull-requests.md` for each PR: the whole-branch review loop, then push, the PR, and `mise run pr-checks`. When a stacked PR's base merges, merge `origin/main` into it as for any pushed branch; the repository merges with merge commits, so that is clean. Remove a finished worktree with `git worktree remove --force`: without it git refuses, because the worktree holds the `pcg-c` submodule. For the same reason `gh pr merge --delete-branch` on a branch checked out in a worktree merges but skips the local cleanup; remove the worktree, then delete the local branch.

## 5. Notify the owner

Report once, when the PRs are open and green: what each PR does, what the reviews found and how it was settled, the decisions you made, and anything left open. Once the owner has approved the plan, do not stop for approval between steps, except where `docs/pull-requests.md` says to stop and ask (a third review round that is still not clean, or a finding only the owner can decide), and do not merge unless the owner says so.
