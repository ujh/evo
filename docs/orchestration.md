# Larger changes: plan, delegate, review, report

Use this for any change bigger than one PR, or one that needs several design decisions. Small changes follow `docs/pull-requests.md` alone. This file says who does what and in which order; `docs/pull-requests.md` holds the rules every review and every PR follows, and this file only adds what a run of several steps needs on top.

## Roles

- **Owner:** decides scope, trade-offs, and defaults, approves the plan, and says when to merge.
- **Orchestrator** (the agent in the conversation): agrees the work with the owner, writes the plan and is its only editor, briefs every other agent, decides what the owner left open, keeps the learnings log, and reports. The plan then has one writer and says what the orchestrator knows.
- **Step agent:** a fresh subagent that does one step, commits without pushing, and reports. It does not edit the plan.
- **Reviewer:** a fresh subagent that has not seen the work. It reports findings under `docs/pull-requests.md` and never writes to a tree an agent is working in.

Run one agent at a time: on this side project token use matters more than speed. Parallel work (see [Worktrees and stacked PRs](#worktrees-and-stacked-prs)) is an option to agree with the owner at the start, and to record as an owner decision.

## The run

### 1. Agree the work

Discuss the goal and ask every question whose answer is the owner's to give (scope, trade-offs, defaults) before writing any code, and record the answers as owner decisions. A request the owner makes along the way that is not part of the plan's work (an open item for `PROJECT_NOTES.md`, a change to these docs) is an owner decision too; give it a home in one PR's docs, so it is not lost. Decide the rest yourself and explain those decisions in the PR descriptions.

### 2. Write the plan

Write the plan to `plans/NAME.md` in the repository root. The directory is gitignored, so the plan survives a lost session without entering the history. It holds:

- the goal, and what must not change (for example "a seeded run gives the same births, games, and rankings as `main`");
- the owner's decisions, each request outside the plan's work with the PR whose docs carry it;
- the declined findings, each with its reason; every reviewer gets this list, so it does not raise them again;
- the design decisions you made;
- the steps as a checklist, grouped by PR, in an order where the PRs can merge one after the other. Each step is small enough for one agent and one or two commits, and names the checks it needs beyond `mise run test` (a GCC build, a smoke run; see [Checks and their cost](#checks-and-their-cost)). A step of real runs and owner docs may be larger. The last code PR ends with a step of real runs, and the plan's last step folds the learnings log into the docs (both in step 5);
- a learnings log: what worked, what went wrong, tool quirks, and what the owner asked to change about the process. Add to it as things happen, not from memory at the end.

Each PR updates the docs it makes stale (`docs/pull-requests.md` step 3). Do not park those edits in a final docs step, or the PRs before it merge with stale text.

### 3. Review the plan

Have a fresh subagent review the plan before any code is written: missing cases, rules of the external tools (GoGui, GNU Go, GTP) that the design depends on, and docs that the change will make stale. Design gaps are cheapest here. Ask the reviewer to check the maths numerically and the external tools by running them, not by reading alone: measured numbers, not estimates, set a design's constants. Fold the findings into the plan. When a finding or the owner changes the design, have a fresh subagent review the changed parts before any code: they are the parts no reviewer has seen. The loop and its limit are those of `docs/pull-requests.md`.

### 4. Get the owner's approval

Show the plan to the owner and wait for their approval before any code is written. Show it in plain language: explain each mechanism with an example or a small diagram, not only as a list of steps, since the owner can only approve what they understand. Expect questions, and put the answers back into the plan. The owner may approve in advance (for example "start once the review is folded in"); then start as soon as the findings are in the plan, and record the approval as an owner decision.

### 5. Build the PRs, one at a time up the stack

Take the PRs in the plan's order, and finish each one before the next begins: its steps, its whole-branch review loop, then push, open, and `mise run pr-checks`. Only then branch the next PR from it and start that PR's first step. So a PR stacked on another is built on commits whose review is done, and a fix to the base never has to move a branch already built on it.

**Steps.** Give each step to a fresh step agent with the [step brief](#step-brief). When it reports, tick the step in the plan with its commit ids and what later steps need to know (a new interface, a name, a number), record the decisions it made, and add to the learnings log.

**Per-commit review.** After each code commit, a fresh reviewer reviews that commit under `docs/pull-requests.md`, with the owner's decisions and the declined findings, so a defect is fixed before the PR's later steps build on it. Commits that change only docs get no review of their own, and neither does the commit of a PR with a single step: no later step builds on it before the PR's whole-branch review, which covers both. Fix blockers and important findings before the next step that depends on them:

- Send the fix back to the agent that wrote the step, since it keeps its context, once no other agent is writing to that tree. If that agent is gone, brief a fresh one with the finding.
- A fix is a new commit on top. Amending or rebasing a commit that another branch is built on moves that branch's base. A stacked branch that is not yet pushed may instead be rebased onto its fixed base ([Worktrees and stacked PRs](#worktrees-and-stacked-prs)).
- A nit about lines a later step touches goes into that step's item in the plan, not into a commit now: that step rewrites those lines anyway.

**Whole-branch review and the PR.** Once the PR's last step is ticked, follow `docs/pull-requests.md` for it: stale-text sweep, whole-branch review loop, push, and `mise run pr-checks`. In a planned run, the whole-branch reviewer gets the per-commit findings and what happened to each, and looks for what a review of one commit cannot see: how the commits fit together, text they left stale, and files the commits do not hold. `mise run pr-checks` compares against the local `HEAD`, so run it in the checkout that has the PR's branch.

**Real runs.** Finish the last code PR with a step of checks on real runs, not only unit tests; they find what reviews do not, such as a design consequence no one predicted: a seeded run compared against `main` where behavior must not change, reproducibility (the same seed twice), and resume after an interrupt where the change touches the runner. Examples in the docs come from seeded runs, with the full command, so a reader can repeat them. Report a result that argues against the design; do not stop for it unless it means the goal cannot be met.

**Learnings.** The plan's last step, in its own docs PR or at the end of the last PR, folds the plan's learnings log into this file and `docs/pull-requests.md`, and repository quirks into `CLAUDE.md`, which every agent reads: keep what generalizes as a rule with its reason, drop one-offs. Its PR goes through the same review and CI as the others, so it is in the report.

### 6. Report

Report once, when every PR, the learnings PR included, is open and green: what each PR does, what the reviews found and how it was settled, the decisions you made, what the real runs showed (including results that argue against the design), what the owner must know (for example that old experiments no longer load), and anything left open. Do not merge unless the owner says so; how to merge a stack is under [Worktrees and stacked PRs](#worktrees-and-stacked-prs).

### 7. Clean up

Once all of the plan's PRs have merged, delete the plan from `plans/`: it then holds nothing the repository's history and docs do not.

## When to ask the owner

Stop and ask only:

- before the plan, for every decision that is the owner's (step 1);
- for approval of the plan, unless given in advance (step 4);
- when any review (plan, commit, or branch) is still not clean after its third round, or a finding needs a decision only the owner can make, such as changing scope, approach, or something the plan says must not change (`docs/pull-requests.md`, the loop);
- for parallel work, and before merging.

Everything else the orchestrator decides and explains in the report and the PR descriptions. Do not stop for sign-off between steps.

## Step brief

Give the step agent the plan's path, the step, the owner's decisions and design decisions it touches, the checks the step names, and this file's path with the instruction to follow this section. Ask for a short report: commits, files, test count, every decision the plan did not settle, and what later steps need to know. The step agent:

- writes tests first and checks that they fail before the code exists;
- runs `mise run test` before each commit, and checks `git status` so no stray file is left or committed, and `git status --ignored` after adding files, since a rule such as `*.out` can hide a fixture the tests need;
- where the tests stub the programs a change spans (the Ruby tests stub the C programs), runs a short seeded experiment through the real runner, such as the smoke run in `CLAUDE.md`: a mismatch between the C output and the Ruby parser passes every test;
- runs the other checks its step names;
- commits with the conventions in `CLAUDE.md` and does not push;
- does not edit the plan: its report carries what the plan needs.

## Checks and their cost

Each check earns its cost only where it can find something the others do not.

| Check | When | Why there |
| --- | --- | --- |
| Plan review | Once before code; again for parts a finding or the owner changed | Design gaps are cheapest before code. |
| Per-commit review | Each code commit, unless the PR has only one step | Finds a defect before the PR's later steps build on it. |
| Whole-branch review | Each PR, before its first push and after every later change, except a clean merge of commits already reviewed (`docs/pull-requests.md` step 7) | Sees how commits fit and what they left stale. |
| Mutants | In each review of code, a few on the behavior the change adds or fixes | The only proof that a test catches a break. |
| Clean checkout | In the whole-branch review of a PR that adds or renames files | Only there does a file the commits do not hold go missing. |
| GCC in Docker (`make test` in `gcc:14`) | In the whole-branch review of a PR that changes C; in a step, only when later steps rely on its floating-point results before CI sees them | The local build is clang and CI's is GCC: floating-point results and warnings differ. CI runs GCC on every push, so once per PR is enough. |
| Seeded smoke run | Each step whose tests stub a program it changes | Stubs hide a mismatch between the programs. |
| Real runs | Once, at the end of the last code PR | They find design consequences no review predicts. |

## Worktrees and stacked PRs

- **Stacking.** A PR may be stacked on another PR's branch: CI runs on every pull request, whatever its base. Branch a stacked PR from its base once the base PR is open, its review loop done, and `mise run pr-checks` green (step 5). If the base is rebased afterwards, move the stacked branch with `git rebase --onto NEW_BASE OLD_BASE`, where OLD_BASE is the base's commit id from before its rebase.
- **When the base merges.** The repository deletes a merged PR's branch, so GitHub retargets the stacked PR to `main` (check with `gh pr view PR --json baseRefName`). Merge `origin/main` into it, then follow `docs/pull-requests.md` step 7.
- **Merging a stack,** once the owner says so: merge the bottom PR, confirm the next one now targets `main`, bring it up to date as above, wait for `mise run pr-checks`, merge it, and repeat. The repository merges with merge commits, so merging `origin/main` in is clean.
- **Worktrees.** Every agent that builds or runs tests outside the tree it writes to (a reviewer, or a second PR in parallel) uses its own `git worktree`. Never let two agents write to the same working tree at once. To set one up, link the main checkout's installed tools into it (`ln -s /path/to/checkout/.local .local`; `/.local` is gitignored), then run `mise trust` and `mise run setup` there (submodule, gems, build). Remove it with `git worktree remove --force`: without the flag git refuses, because the worktree holds the `pcg-c` submodule. For the same reason `gh pr merge --delete-branch` on a branch checked out in a worktree merges but skips the local cleanup; remove the worktree, then delete the local branch.
- **Parallel work,** when the owner agreed to it: a review of step N in its own worktree while step N+1 is built, or a PR that is not stacked on an unfinished one in its own worktree.
