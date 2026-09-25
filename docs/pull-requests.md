# Opening a pull request

Follow these steps in order for every PR. The PR title and body follow the conventions in `CLAUDE.md`.

1. Run `mise run test`, plus any smoke run the change calls for. Fix failures first. Once a code file changes, earlier results are stale, so run them again.
2. List what the change makes newly true. Search the whole repository, including files the diff does not touch, for text that still says the old thing, and correct it.
3. Review the whole branch (`git diff main...HEAD`) under the [review rules](#review-rules) below, and loop until a round is clean.
4. Push and open the PR.
5. Run `mise run pr-checks <pr>`. It waits for CI and fails unless every check passed on the local `HEAD`. If a check fails, fix the cause. Do not skip or disable it.
6. Run `mise run pr-feedback <pr>`. It lists reviews (including summary text and change requests), inline comments, and top-level comments. Fix or answer each one. Reply to an inline comment on its thread, and answer reviews and top-level comments with a new top-level comment (the output shows both commands).
7. For any later fix, repeat steps 1–3 for the whole branch, push, then repeat steps 5–6.

## Review rules

The review is done by a reviewer with fresh context, such as a subagent that has not seen the work. These rules keep it to findings worth another round.

### What counts as a finding

A finding names a `file:line`, the defect, and a concrete failure: inputs the real system produces (real `gh`, GoGui, or GNU Go output, real settings), and the wrong result they lead to. It also cites its evidence: the line, a command and its output, or a test. A finding without a realistic failure is dropped, not reported as a nit.

These are not findings:

- Inputs the real tools do not produce, such as `gh` printing only whitespace.
- Lines the branch did not change, unless the change makes an existing bug reachable where it was not before.
- A request to write down a value the code already holds. That copy goes stale.
- A style or wording preference that breaks no rule in `CLAUDE.md`.
- Anything an earlier round already fixed or declined (see [the loop](#the-loop)).

### Severity

- **Blocker:** wrong results in normal use. Examples: corrupted game results or parent selection, lost experiment evidence, a broken build or CI, or reporting a failing PR as green on real tool output.
- **Important:** a real defect that someone hits in normal use, without corrupting results.
- **Nit:** anything else that is still true and worth saying.

Tests follow the risk. In experiment code (the engine, `evolve`, `initial-population`, the runner, scoring), a behavior change with no test that would fail when it breaks is important. In developer tooling (the `pr-*` scripts, mise tasks), ask for a test only where a break would produce a false pass.

### The loop

1. Fix every blocker and important finding.
2. Review again. Give the new round the list of earlier findings and what happened to each (fixed, or declined with the reason), so it does not raise them again.
3. The loop ends when a round has no blocker and no important finding. Nits do not start another round. Fix a nit only if it is a small change to lines the branch already touches; otherwise mention it when reporting the PR.
4. If the third round still has a blocker or important finding, stop and report to the owner. The change is probably too large, or its approach needs a decision.

Don't stop for sign-off on findings within these rounds. Ask the owner only when a finding needs a decision only the owner can make, such as changing scope or approach.

### Reviewer prompt

Give the reviewer:

- the branch, the base (`main`), and the command for the diff
- why the change was made, and what it is meant to do
- the path to this file, and the instruction to apply its rules
- for later rounds, the earlier findings and what happened to each
- the instruction not to modify files, check out other commits, or use `git stash`
