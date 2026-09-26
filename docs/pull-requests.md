# Opening a pull request

Follow these steps in order for every PR. The PR title and body follow the conventions in `CLAUDE.md`. BASE below is the branch the PR targets: `main`, or for a PR stacked on another PR's branch, that branch (see `docs/orchestration.md`).

1. Bring the branch up to date with its base, because the repository only merges a PR that is. Run `git fetch origin`. Before the first push, and only while no other branch is built on this one, rebase onto `origin/BASE`. Otherwise merge `origin/BASE` into it instead: that needs no force push and leaves the base of a branch stacked on this one where it is. Review and CI then cover what will actually merge.
2. Run `mise run test`, plus any smoke run the change calls for. Fix failures first. Once a code file changes, earlier results are stale, so run them again.
3. List what the change makes newly true. Search the whole repository, including files the diff does not touch, for text that still says the old thing, and correct it.
4. Review the whole branch (`git diff origin/BASE...HEAD`) under the [review rules](#review-rules) below, and loop until a round is clean.
5. Check that the commits hold what you meant (`git show --stat`; an amend without `-a` leaves unstaged edits out), then push and open the PR against BASE.
6. Run `mise run pr-checks <pr>`. It waits for CI and fails unless every check passed on the local `HEAD` and GitHub reports the PR neither conflicting with its base nor behind it. GitHub reports a PR as behind only where branch protection requires branches to be up to date, which is `main` alone, so a stacked PR can be behind its base branch and still pass; step 1 keeps it up to date. If a check fails, fix the cause. Do not skip or disable it. If the PR is behind or conflicts, follow the command the script prints, then go on as step 7 says. Run it on a commit that is pushed: it waits for GitHub to show the local `HEAD`, so on an unpushed commit it takes about five minutes to fail.
7. For any later change, repeat steps 1–4 for the whole branch, push, then repeat step 6. One exception: when a merge of `origin/BASE` brought in only commits that were already reviewed (a stacked PR whose base has merged) and had no conflicts, run step 2, push, and repeat step 6, without another review.

No external reviewer runs on this repository, so do not wait for review comments. The CI result is the only thing to check after pushing.

## Review rules

The review is done by a reviewer with fresh context, such as a subagent that has not seen the work. These rules keep it to findings worth another round. They apply to every review: of a PR, of one commit, and of a plan.

### What counts as a finding

A finding names a `file:line`, the defect, and a concrete failure: inputs the real system produces (real `gh`, GoGui, or GNU Go output, real settings), and the wrong result they lead to. It also cites its evidence: the line, a command and its output, or a test. A finding without a realistic failure is dropped, not reported as a nit.

These are not findings:

- Inputs the real tools do not produce, such as `gh` printing only whitespace.
- Lines the change did not touch, unless the change makes an existing bug reachable where it was not before.
- A request to write down a value the code already holds. That copy goes stale.
- A style or wording preference that breaks no rule in `CLAUDE.md`.
- Anything an earlier round already fixed or declined (see [the loop](#the-loop)), or an owner decision.

### Severity

- **Blocker:** wrong results in normal use. Examples: corrupted game results or parent selection, lost experiment evidence, a broken build or CI, or reporting a failing PR as green on real tool output.
- **Important:** a real defect that someone hits in normal use, without corrupting results.
- **Nit:** anything else that is still true and worth saying.

Tests follow the risk. In experiment code (the engine, `evolve`, `initial-population`, the runner, scoring), a behavior change with no test that would fail when it breaks is important. In developer tooling (the `pr-*` scripts, mise tasks), ask for a test only where a break would produce a false pass. A test counts only if it fails when the behavior breaks: before relying on a new test, the author undoes or breaks the fix and checks that the test fails. The reviewer checks this too, in its own worktree: it breaks the behavior the change adds or fixes with a few mutants (flip a condition, drop a call, change a constant) and runs the tests; a mutant no test catches is a missing test, rated as above. A few well-aimed mutants are enough; do not mutate every line.

### The loop

1. Fix every blocker and important finding.
2. Review again, from scratch: a fresh reviewer reviews the whole change as the first round did, not only the fixes, so a fix that breaks something elsewhere or leaves the design lopsided is found. Give it the list of earlier findings and what happened to each (fixed, or declined with the reason), only so it does not raise them again.
3. The loop ends when a round has no blocker and no important finding. Nits do not start another round. Fix a nit only if it is a small change to lines the change already touches and no later step rewrites; otherwise mention it when reporting (in a planned run, a nit about lines a later step touches goes into that step).
4. If the third round still has a blocker or important finding, stop and report to the owner. The change is probably too large, or its approach needs a decision.

Don't stop for sign-off on findings within these rounds. Ask the owner only when a finding needs a decision only the owner can make, such as changing scope or approach.

### Where the reviewer works

The reviewer never modifies, checks out, or stashes in the tree under review: an agent may be working there, and a half-finished edit shows up as failures that are not real. To build, run tests, or try mutants, it makes its own worktree at the commit under review (`git worktree add DIR COMMIT` in a scratch directory; setup and removal in `docs/orchestration.md`). No clean-checkout build is needed: CI tests a fresh clone on every push, so a file the commits do not hold fails there before merge.

### Reviewer prompt

Give the reviewer:

- the branch or commit, the base, and the command for the diff
- why the change was made, and what it is meant to do
- the path to this file, and the instruction to apply its rules
- in a planned run, the plan's owner decisions and declined findings, and for a whole-branch review the per-commit findings and what happened to each
- for later rounds, the earlier findings and what happened to each
- the checks it should run (see "Checks and their cost" in `docs/orchestration.md`)
