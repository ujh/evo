# Larger changes: plan, delegate, review, notify

Use this for any change bigger than one PR, or one that needs several design decisions. The agent in the conversation orchestrates: it agrees the plan with the owner, hands each step to a fresh subagent, keeps the plan current, and reports once at the end. Small changes follow `docs/pull-requests.md` alone.

## 1. Agree the work with the owner

Discuss the goal and ask every question whose answer is the owner's to give (scope, trade-offs, defaults) before writing any code. Record the answers. After that, decide the rest yourself and explain those decisions in the PR descriptions; do not come back for approval on choices the owner left to you.

## 2. Write the plan

Write the plan to `plans/NAME.md` in the repository root. The directory is gitignored, so the plan survives a lost session without entering the history. It holds:

- the goal, and what must not change (for example "a seeded run gives the same births, games, and rankings as main");
- the owner's decisions and every finding declined so far, with the reason (give this list to every reviewer, so they do not raise it again);
- the design decisions you made;
- the steps as a checklist, grouped by PR, each small enough for one agent and one or two commits; tick each with its commit ids.

Have a fresh subagent review the plan itself before any code is written: missing cases, rules of the external tools (GoGui, GNU Go, GTP) that the design depends on, and docs that the change will make stale. Design gaps are cheapest here.

Check how CI treats the PRs you plan. `ci.yml` runs only for pull requests into `main`, so a PR stacked on another branch gets no checks until its base merges; prefer PRs based on `main`, merged in order.

## 3. Run each step through a subagent

Give each step to a fresh subagent with the plan's path, the step, the rules it must follow, and a short report format (commits, files, test count, every decision the plan did not settle). Each step:

- writes tests first and checks that they fail before the code exists;
- runs `mise run test` before each commit, and checks `git status` so no stray file is left or committed;
- commits with the conventions in `CLAUDE.md` and does not push.

After each code commit, a different fresh subagent reviews that commit under the review rules in `docs/pull-requests.md`, with the owner's decisions and the declined findings. Fix blockers and important findings before the next step that depends on them.

Independent work can run in parallel: a review of step N while step N+1 is built, or a second PR in its own `git worktree` (with `pcg-c` initialized and `.local` linked to the main checkout's). Never let two agents write to the same working tree at once.

Finish with checks on real runs, not only unit tests: a seeded run compared against `main` where behavior must not change, reproducibility, and resume after an interrupt where the change touches the runner. Examples in the docs come from seeded runs, with the full command, so a reader can repeat them.

## 4. Open the PRs

Follow `docs/pull-requests.md` for each PR: the whole-branch review loop, then push, the PR, and `mise run pr-checks`. A PR stacked on another has to be rebased onto `main` after its base merges, which needs a force push; that is the one exception to merging `main` into a pushed branch.

## 5. Notify the owner

Report once, when the PRs are open and green: what each PR does, what the reviews found and how it was settled, the decisions you made, and anything left open. Do not stop for approval between steps, and do not merge unless the owner says so.
