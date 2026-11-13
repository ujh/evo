# Opening a pull request

- [Review rules](#review-rules)
  - [What counts as a finding](#what-counts-as-a-finding)
  - [Severity](#severity)
  - [Tests](#tests)
  - [The loop](#the-loop)
  - [Where the reviewer works](#where-the-reviewer-works)
  - [Reviewer prompt](#reviewer-prompt)

Follow these steps in order for every PR.
BASE is the branch the PR targets: `main`, or for a PR stacked on another PR's branch, that branch (`docs/orchestration.md`).
Title: short and descriptive, without a ticket key (this repo has no Jira key).
Body: one short paragraph that starts with why the change is needed, plus a line saying how it was verified.

1. Bring the branch up to date with its base, since the repository merges only a PR that is, and review and CI then cover what will merge.
   Run `git fetch origin`.
   Before the first push, and only while no other branch is built on this one, rebase onto `origin/BASE`.
   Otherwise merge `origin/BASE` into it: that needs no force push and leaves the base of a branch stacked on this one where it is.
2. Run `mise run test`, plus any smoke run the change calls for, and fix failures first.
   Once a code file changes, earlier results are stale; run them again.
3. List what the change makes newly true, search the whole repository (including files the diff does not touch) for text that still says the old thing, and correct it.
   Before a change that deletes data for good (rows, tables or files, archiving an experiment) or adds to what stored data must hold (a setting every experiment needs), find every reader of that data (its table, its columns, the helpers that read it) and check that each still works on the result (a reader that opens archived experiments read-only skips the migrations, so it lacks a new setting).
   Search a renamed name in every spelling (`game_length`, `--game-length`, `GAME_LENGTH`), since a search for one misses the others.
4. Review the whole branch (`git diff origin/BASE...HEAD`) under the [review rules](#review-rules), and loop until a round is clean.
5. Check that the commits hold what you meant (`git show --stat`; an amend without `-a` leaves unstaged edits out), then push and open the PR against BASE.
6. Run `mise run pr-checks <pr>` on a pushed commit (it waits for GitHub to show the local `HEAD`, so on an unpushed one it fails only after about five minutes).
   It waits for CI and fails unless every check passed on the local `HEAD` and GitHub reports the PR neither conflicting with its base nor behind it.
   GitHub reports a PR as behind only where branch protection requires branches to be up to date, which is `main` alone, so a stacked PR can be behind its base and still pass; step 1 keeps it up to date.
   If a check fails, fix the cause; do not skip or disable it.
   If the PR is behind or conflicts, follow the command the script prints, then go on as step 7 says.
7. For any later change, repeat steps 1–4 for the whole branch, push, then repeat step 6.
   One exception: a merge of `origin/BASE` that brought in only commits already reviewed or merged through their own PR (the base of a stacked PR, a merged sibling PR, a Dependabot update) needs no new review if it had no conflicts, or if its only conflicts were where both sides deleted neighbouring text and keeping both deletions resolved them (two PRs each deleting their own `PROJECT_NOTES.md` item).
   Such a resolution adds no line of its own, so what merges is what was reviewed.
   Check that on the merge commit: `git show --remerge-diff --format= HEAD` must show each conflict block removed whole, its markers and both sides as `-` lines, with no `+` line, no line kept between the markers, and no file without a `remerge CONFLICT` line (a dropped mode change, such as a lost `chmod +x`, shows only as `old mode`/`new mode`).
   Comparing `+`/`-` lines alone is not enough: it cannot tell which of two identical lines a resolution deleted.
   Then run step 2, push, and repeat step 6.

No external reviewer runs here, so do not wait for review comments; after pushing, only CI counts.

## Review rules

A reviewer with fresh context, such as a subagent that has not seen the work, does the review.
These rules keep it to findings worth another round, and apply to every review: of a PR, of one commit, and of a plan.

Every review covers the whole change under review (the whole plan, the whole commit, or the whole branch against its base), and every round reviews it from scratch.
No brief tells a reviewer to focus on a part or a kind of problem (the latest fix, the prose, what an earlier review could not see) or to skip one, however small the latest change, since a fix checked on its own stays local and what it breaks elsewhere goes unseen.
Owner, 19 Oct 2026: "I have noticed in the past that when we tell the reviewer to only check small things it leads to a local fix, but overall we might end up with broken things.
This is especially true when talking about prose.
So we should not tell anyone to focus on something for a fresh review, but always review the whole change."
A brief adds context and work, never scope: what the [reviewer prompt](#reviewer-prompt) lists, and checks the reviewer runs on top of reading (mutants, GCC in Docker, a seeded comparison, an interrupt walk, every figure against its raw output).
Such a check never stands in for reading the whole change.

### What counts as a finding

A finding names a `file:line`, the defect, and a concrete failure: inputs the real system produces (real `gh`, GoGui, or GNU Go output, real settings) and the wrong result they lead to.
It cites its evidence: the line, a command and its output, or a test.
A claim about how an external tool behaves names the platform and the exact command, since the same tool has given reviewers on other platforms different results (GNU Go's exit status at stdin EOF).
A finding without a realistic failure is dropped, not reported as a nit.

Not findings:

- Inputs the real tools do not produce, such as `gh` printing only whitespace.
- Lines the change did not touch, unless the change makes an existing bug reachable.
- A request to write down a value the code already holds: that copy goes stale.
- A style or wording preference that breaks no rule in `CLAUDE.md`.
- Anything an earlier round fixed or declined ([the loop](#the-loop)), or an owner decision.

### Severity

- **Blocker:** wrong results in normal use, such as corrupted game results or parent selection, lost experiment evidence, a broken build or CI, or a failing PR reported green on real tool output.
- **Important:** a real defect that someone hits in normal use, without corrupting results.
- **Nit:** anything else that is still true and worth saying.

In a plan review, a finding is important only if it would plausibly make a step build the wrong behavior or break something the plan says must not change, and a step agent would not settle it anyway while writing the step's tests.
Other edge cases are nits: the step's tests settle them.

In docs that record results, a figure or claim the quoted outputs do not support is important, since the next run is chosen from it: an effect called absent where none was detected, a cause where a correlation was measured, an interpretation that picks one of two explanations the outputs cannot separate.
What such docs may hold besides the outputs' figures is listed in one place, `docs/orchestration.md`, Analyses and results docs (The exceptions); what that list allows is not such a claim.

### Tests

- **Tests follow the risk.**
  In experiment code (the engine, `evolve`, `initial-population`, the runner, scoring) and in analysis scripts whose numbers go into the docs or a decision (such as `scripts/ranking-noise.rb`, `scripts/game-repeats.rb`, `scripts/brittleness.rb`), a behavior change with no test that would fail when it breaks is important.
  In developer tooling (the `pr-*` scripts, mise tasks), ask for a test only where a break would produce a false pass.
- **A test counts only if it fails when the behavior breaks.**
  The author undoes or breaks the fix and checks that the test fails before relying on it.
  The reviewer checks this too, in its own worktree, with a few well-aimed mutants (flip a condition, drop a call, change a constant), not one per line; a mutant no test catches is a missing test, rated as above.
- **Test data takes the branches real data takes**, which small, symmetric data skips.
  Shape hand-made data like real data (unequal players and opponents, partial runs, rows a selection leaves out, orders that are not alphabetical) and aim some mutants at those branches.
- **Where the output is the product, test the whole output.**
  For a script that prints a report or a table for the docs, pin the whole output text on such data from the first test, since single-line assertions let untested report lines through round after round.
- **Speed is bounded by work.**
  A test that bounds speed states a work bound (iterations, steps, games), not a wall-clock one, since CI's runners and a busy owner machine make a time limit fail at random.

### The loop

1. Fix every blocker and important finding, and treat each as one instance of its kind: look through the whole change for the others (every report line without a test, every sentence that claims more than its output) and fix them too, since a reviewer reports only the instances it found.
2. Review again, from scratch: a fresh reviewer reviews the whole change as the first round did ([Review rules](#review-rules)), not only the fixes and even after a fix of a few lines or of docs alone, so a fix that breaks something elsewhere or leaves the design lopsided is found.
   Give it the earlier findings and what happened to each (fixed, or declined with the reason), only so it does not raise them again.
3. The loop ends when a round has no blocker and no important finding; nits do not start another round.
   Fix a nit only if it is a small change to lines the change already touches and no later step rewrites; otherwise mention it when reporting (in a planned run, a nit about lines a later step touches goes into that step).

The loop has no round limit (owner, 28 Sep 2026): go on until only nits are left, without asking, since later rounds still find real defects.
Ask the owner only when a finding needs a decision only the owner can make, such as changing scope or approach.
A finding of a kind whose whole class the round before swept (loop step 1) is the sign of such a decision: ask the first time the kind comes back, with the options (sweep once more, or change the approach, and how), not after more sweeps.
One owner answer can end such a kind where sweeps have not (owner, 12 Nov 2026, on claims stronger than one run per setting allows: "Descriptive only", "Slim it down").

### Where the reviewer works

The reviewer never modifies, checks out, or stashes in the tree under review, since an agent may be working there and its half-finished edit shows up as failures that are not real.
To build, run tests, or try mutants, it makes its own worktree at the commit under review (`git worktree add DIR COMMIT` in a scratch directory; setup and removal in `docs/orchestration.md`).
No clean-checkout build is needed: CI tests a fresh clone on every push, so a file the commits miss fails there before merge.

### Reviewer prompt

Give the reviewer:

- the branch or commit, the base, and the diff against the remote base after a fetch (`git fetch origin`, then `git diff origin/BASE...HEAD`), never against a local branch such as `main`, which may be stale
- why the change was made, and what it is meant to do
- the path to this file, and the instruction to apply its rules
- in a planned run, the plan's owner decisions and declined findings; for a whole-branch review, the per-commit findings and what happened to each; and the request to report out-of-scope items (`docs/orchestration.md`, Step brief): problems outside the change, such as on lines it did not touch, that are not findings here
- for later rounds, the earlier findings and what happened to each
- for a change to the worker pool, the processes it runs, a signal path, or what a resumed run plays, the instruction to walk a real interrupt (Ctrl-C) through every stage and check what the docs say about resume against what the walk shows, since such walks have found hangs and wrong resume docs.
  Ctrl-C sends SIGINT to the whole foreground process group, so from a tool start the command in a group of its own and signal the group, in one foreground call: `perl -e '$SIG{INT}="DEFAULT"; setpgrp(0,0); exec @ARGV' CMD ARGS… & pid=$!; sleep N; kill -INT -$pid; wait $pid; echo $?` (exit 130 when the interrupt arrived).
  The default handler must be restored because a job started with `&` from the tool's non-interactive shell inherits SIGINT as ignored, and `setpgrp` and `exec` keep that (macOS, zsh; `mise exec --` happens to reset it).
  zsh refuses `set -m`; `/bin/sh` accepts it, so `sh -c 'set -m; CMD & pid=$!; sleep N; kill -INT -$pid; wait $pid'` works too.
  Slow a stage too short to hit, such as breeding (0.2–0.5 s a generation in a 12-network run), by replacing the experiment's own copy of the program (made on its first run, `docs/experiment-reference.md`, so only after generation 0) with a wrapper that sleeps, then runs the real one
- for docs that record results, the raw outputs they quote and the revision that produced them, and the instruction to check every figure and claim, the interpretation included, against those outputs (`docs/orchestration.md`, Analyses and results docs)
- the checks it should run (`docs/orchestration.md`, Checks and their cost), each in the foreground with a time limit long enough for it (`mise run test` needs at least 400000 ms) and no background job, and the instruction to report as soon as it is done
- that it writes the command for a timing whose number would be recorded or set a constant, and does not run it: those are [quiet] measurements (`docs/orchestration.md`, Measurements)
