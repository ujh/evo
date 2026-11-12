# Larger changes: plan, delegate, review, report

- [Roles](#roles)
- [The run](#the-run)
  - [1. Agree the work](#1-agree-the-work)
  - [2. Write the plan](#2-write-the-plan)
  - [3. Review the plan](#3-review-the-plan)
  - [4. Get the owner's approval](#4-get-the-owners-approval)
  - [5. Build the PRs, one at a time up the stack](#5-build-the-prs-one-at-a-time-up-the-stack)
  - [6. Report](#6-report)
  - [7. Clean up](#7-clean-up)
- [When to ask the owner](#when-to-ask-the-owner)
  - [While the owner is away](#while-the-owner-is-away)
- [Watching running agents](#watching-running-agents)
- [Step brief](#step-brief)
- [Checks and their cost](#checks-and-their-cost)
- [Measurements](#measurements)
- [Analyses and results docs](#analyses-and-results-docs)
- [Worktrees and stacked PRs](#worktrees-and-stacked-prs)

Use this for any change bigger than one PR, or one that needs several design decisions; small changes follow `docs/pull-requests.md` alone.
That file holds the rules every review and PR follows; this one adds who does what, in which order, when a run has several steps.

## Roles

- **Owner:** decides scope, trade-offs, and defaults, approves the plan, and says when to merge.
- **Orchestrator** (the agent in the conversation): agrees the work with the owner, writes the plan as its only editor (so the plan says what the orchestrator knows), briefs every other agent and [watches it while it runs](#watching-running-agents), decides what the owner left open, makes review fixes of a few lines ([per-commit review](#5-build-the-prs-one-at-a-time-up-the-stack)), keeps the learnings log and the out-of-scope list, and reports.
- **Step agent:** a fresh subagent that does one step, commits without pushing, and reports; it does not edit the plan.
- **Reviewer:** a fresh subagent that has not seen the work; it reports findings under `docs/pull-requests.md` and never writes to a tree an agent is working in.

Run one agent at a time, since on this side project token use matters more than speed.
Parallel work ([Worktrees and stacked PRs](#worktrees-and-stacked-prs)) is an option to agree with the owner at the start and record as an owner decision.

## The run

### 1. Agree the work

Before any code, ask every question whose answer is the owner's (scope, trade-offs, defaults), and record each answer as an owner decision in the owner's words, with the date, so reviews and the report work from what the owner said.
Search `PROJECT_NOTES.md` and the docs for every item the owner addressed to this work (attributed to the owner, with a date) and record each as an owner decision with its date, or the run's own cleanup may delete it unanswered; an unattributed item is an agent's proposal, not a decision.
A request the owner makes along the way outside the plan's work (an open item for `PROJECT_NOTES.md`, a change to these docs) is an owner decision too; give it a home in one PR's docs, so it is not lost.
Decide the rest yourself and explain it in the PR descriptions.

### 2. Write the plan

Write the plan to `plans/NAME.md` in the repository root.
`plans/` is gitignored, so the plan survives a lost session without entering the history, and git cannot restore it: edit it with the Edit tool, or write a new file and move it over the old one, never with a script that opens the plan for writing before it writes (one left a plan empty).
It holds:

- the goal, and what must not change (for example "a seeded run gives the same births, games, and rankings as `main`");
- the owner's decisions, each request outside the plan's work with the PR whose docs carry it;
- the declined findings with their reasons, which every reviewer gets so it does not raise them again;
- the facts the design rests on, each cited by its method or symbol, with the `file:line` only as a hint, since lines drift as the plan's steps land (owner, 19 Oct 2026), and each read in the code that acts on it, since config and docs can miss what the code does;
- the design decisions; one that moves code or a check names its exact new place, checked against what must come before and after it, since the obvious place can come before a lock or database open it needs;
- the steps as a checklist, grouped by PR, in an order where the PRs can merge one after the other (below);
- each measurement whose numbers the plan or docs will rely on, marked **[quiet]** in its step ([Measurements](#measurements)), and each analysis whose numbers results docs or the choice of the next experiment will rely on, as a script reviewed and merged before it runs (scripts that belong together may share a PR), with the rules its results doc follows ([Analyses and results docs](#analyses-and-results-docs));
- a learnings log (what worked, what went wrong, tool quirks, what the owner asked to change about the process), written as things happen, not from memory, since the whole-process review (step 5) works from it;
- out-of-scope items, each with who raised it, in which step, and where (a file and line, or a command), of two kinds: code that is not ideal (a confusing name, a duplicated rule, a slow or flaky test, a missing check), and the tools agents work with (mise tasks, the `pr-*` scripts, test and smoke-run commands, the reference docs), such as many commands that could be one script, output too long or vague to read, a check with no command, or a doc that sent an agent the wrong way.
  The learnings log ends up in these docs; this list is about the repository and may end up in `PROJECT_NOTES.md` (step 6).

Each step fits one agent and one or two commits (a step of real runs and owner docs may be larger) and names the checks it needs beyond `mise run test` ([Checks and their cost](#checks-and-their-cost)), among them the cheapest check that shows each property the design claims (such as a smoke run comparing generation 1's children at two settings).
The last code PR ends with a step of real runs.
In a plan for an analysis, the script PRs are followed by the analysis phase (step 5): the merge (the owner's, or the orchestrator's when granted), the runs, and the results PR.
Then come the whole-process review (step 5), with its final docs PR if it yields changes (for an analysis, possibly the results PR), and last, deleting the plan and its results once its PRs merge (step 7), which is easy to forget.

Each PR updates the docs it makes stale (`docs/pull-requests.md` step 3), since a final docs step would let the PRs before it merge with stale text.

No repository file names the plan's labels (such as "PR 1b" or a step number), since they mean nothing once the plan is deleted: commits, comments and docs cite GitHub PR numbers.
Cite a commit id only for a commit on `main` (such as the revision an analysis ran from), since a rebase gives an unmerged commit a new id while a PR number never changes (owner, 19 Oct 2026: cite PR numbers for work that has not merged).

### 3. Review the plan

Have a fresh subagent review the whole plan before any code, since design gaps are cheapest here (`docs/pull-requests.md`, Review rules).
Ask it to run things as well as read, since measured numbers, not estimates, set a design's constants, and premises read in the source have been wrong:

- **External tools** (GoGui, GNU Go, GTP, a bot) the design depends on: run them, since no stubbed test shows what the real tool does.
  When the work brings in a new external tool, try it yourself while writing the plan (build it, play a few games through the arena) and record what you find, since that has found blockers reading the source missed.
- **Maths, statistics and counts:** check them numerically, with a pilot on real data or a simulation for a statistical design (a standard error, a test, a power estimate) and for each measure of an analysis, since pilots have found errors reading missed (such as a standard error about 6 times too small).
- **Cost at full size:** where cost or convergence depends on the data's size, check it on synthetic data as large as real use will reach, since the real data may still be small.
- **Measurement methods:** how each measurement or calibration will be taken, not only the code it feeds, since gaps hide there: a check that cannot hold, workloads that new defaults would silently redefine, two settings calibrated from one table although one changes the other, a run meant to count network games that plays none.

The reviewer runs the repository's commands and writes pilots and simulations as scratch scripts.
Claude Code's permission check may refuse it an edit of the repository's code, even in its own worktree; brief such a check as a smoke run in the step that builds the code, and tell the reviewer so.

Fold the findings into the plan.
When a finding or the owner changes the design, a fresh subagent reviews the whole plan again before any code, since a change can leave other parts that no longer fit; a reviewer still running can get the change by message and review the plan as changed.
The loop is that of `docs/pull-requests.md`: until a round has no blocker and no important finding.
Quote that file's severity rule for a plan review (Severity) in every plan-review brief from the first round, since without it reviews raise as important the edge cases a step's tests settle anyway.

### 4. Get the owner's approval

Show the plan to the owner and wait for approval before any code.
Explain each mechanism plainly, with an example or a small diagram, since the owner can only approve what they understand.
Where the design's statistics bound what it can find, show the smallest effect it can detect at the planned budget and what more games would buy, so the owner can choose between designs.
Put the answers to the owner's questions into the plan.
An approval in advance (for example "start once the review is folded in") is recorded as an owner decision, and work starts once the findings are in the plan.
A design change after approval, the owner's or a finding's, goes through step 3 again, and the owner approves it before code builds on it.

### 5. Build the PRs, one at a time up the stack

Finish each PR, in the plan's order, before the next begins: its steps, its whole-branch review loop, push, open, and `mise run pr-checks`.
Only then branch the next PR from it, so a stacked PR builds on reviewed commits and a fix to the base never moves a branch built on it.

**Steps.** Give each step to a fresh step agent with the [step brief](#step-brief).
Check its report against every clause of the plan that names the step, the design decisions included, since a clause the brief left out is work no step does.
Then tick the step with its commit ids and what later steps need to know (an interface, a name, a number), record its decisions, add to the learnings log, and copy its out-of-scope items into the plan's list, as for every reviewer's report, the plan review's included.
A step that needs the orchestrator's choice halfway (run a calibration, pick levels from its table, build on them) stays with one agent: its brief says where to stop, it reports there, and the orchestrator records the choice in the plan, sends it to the same agent, which goes on with its context, and starts a new heartbeat ([Watching running agents](#watching-running-agents)); if the agent is gone, a fresh one gets the choice and the first part's commits.

**Per-commit review.** After each code commit, a fresh reviewer reviews it under `docs/pull-requests.md`, with the owner's decisions and the declined findings, so a defect is fixed before later steps build on it.
A docs-only commit gets none, nor does one no later commit of the PR depends on (a single-step PR's, the last step's, a fix later steps do not use): the whole-branch review covers it, mutants included, as the next round of the loop, from scratch.
Fix blockers and important findings before the next step that depends on them:

- Send the fix to the agent that wrote the step, which keeps its context, once no other agent writes to that tree, or to a fresh agent if it is gone.
  The orchestrator may make a fix of a few lines itself, test first, while no agent writes to the tree, since resuming an agent re-reads its whole context (about 200k tokens) and the next review covers the fix either way.
- A fix is a new commit on top, since amending or rebasing a commit another branch is built on moves that branch's base; an unpushed stacked branch may instead be rebased onto its fixed base ([Worktrees and stacked PRs](#worktrees-and-stacked-prs)).
- A nit about lines a later step touches goes into that step's item in the plan, since that step rewrites them anyway.

**Whole-branch review and the PR.** After the last step, follow `docs/pull-requests.md`: stale-text sweep, whole-branch review loop, push, `mise run pr-checks`.
The reviewer also gets the per-commit findings and what happened to each, so it does not raise them again; as the first to read all the commits together, it sees how they fit and what text they left stale.
Its findings are fixed as per-commit ones.
`mise run pr-checks` compares against the local `HEAD`, so run it in the checkout that has the PR's branch.

**Real runs.** The last code PR ends with checks on real runs, since they find design consequences no review predicts: a seeded run compared against `main` where behavior must not change, the same seed twice, and resume after an interrupt where the runner changes.
For a runner change, the seeded comparison is cheap enough for every step: `mise run profile-workload small --tiny --keep` in a worktree at the base and one at the step's commit, then compare the kept databases with `sqlite3 -readonly` and delete them (`--tiny`'s timings mean nothing, but its seeded results compare).
Compare births (every column, the SHA-256 `genome` included), games and benchmark results without their time columns, and rankings; timings and `provenance` always differ.
Examples in the docs come from seeded runs, with the full command, so a reader can repeat them.
Report a result that argues against the design; stop only if it means the goal cannot be met.
Claude Code's permission check blocks a run in place on an existing experiment, or deleting an experiment that existed before the run, even with the owner's go-ahead; give the owner the exact commands to run with `!`.

**Analysis phase.** A plan for an analysis ([Analyses and results docs](#analyses-and-results-docs)) runs its scripts only once they have merged.
When the script PRs are open and green, tell the owner in a short note (not the report) and wait for the merge, unless the owner granted merging ([While the owner is away](#while-the-owner-is-away)); merge as [merging a stack](#worktrees-and-stacked-prs) says.
Run each script from the merged revision.
The orchestrator runs a short one itself in a worktree at that revision, passing the main checkout's paths for the experiments and for any results directory a later run or `--report-only` must find, since a worktree has no `experiments/` and is removed afterwards.
A long run goes to the owner as a command, to start at the concurrency they choose, since the machine is theirs, and the plan goes on when it has finished ([While the owner is away](#while-the-owner-is-away) says when the orchestrator may start it).
Keep the raw outputs, then build the results PR like any other.

**Whole-process review.** The plan's last step before cleanup gives a fresh step agent the learnings log; it reviews the process as one system and edits this file, `docs/pull-requests.md`, and `CLAUDE.md`'s working conventions.
It folds in what generalizes as a rule with its reason, drops one-offs, and restructures where parts no longer fit rather than patching lines, since rules added one at a time drift apart; repository quirks go into the relevant reference doc.
Useful changes go into a final docs PR (for an analysis, possibly the results PR), reviewed and checked like the others, so it is in the report (owner, 29 Sep 2026: plans now always have a learnings log, so go over the process as a whole at the end of each plan and open a final PR if there are useful changes; this replaced a review every third run).

### 6. Report

Report once, when every PR, the final docs PR included, is open and green (for an analysis, the results and final docs PRs, since its script PRs merged already).
Say what each PR does, what the reviews found and how it was settled, your decisions, what the real runs showed (results that argue against the design included), what the owner must know (for example that old experiments no longer load), and what is left open.
Do not merge unless the owner says so ([Worktrees and stacked PRs](#worktrees-and-stacked-prs) says how to merge a stack).

Before reporting, a fresh subagent triages the out-of-scope list.
It checks each item against `main`, against merged and open PRs (these included), and against `PROJECT_NOTES.md`, drops what is settled or already there and one-offs that will not trip anyone again, and merges duplicates.
For each item kept it says plainly what and where the problem is and why fixing it would help (for a tool, what agents would no longer do by hand or work out again).
Put that list in the report and ask the owner which items go into `PROJECT_NOTES.md`; add those in a commit on the final docs PR (or the last PR), follow `docs/pull-requests.md` step 7, and tell the owner when its checks pass again.

### 7. Clean up

Once all the plan's PRs have merged, delete the plan and its results directory from `plans/`, since the history and docs hold the rest; it is the plan's last checklist item (step 2).

## When to ask the owner

Stop and ask only:

- before the plan, for every decision that is the owner's (step 1);
- for approval of the plan, unless given in advance, and of a design change after approval (step 4);
- when a review finding (plan, commit, or branch) needs a decision only the owner can make, such as scope, approach, or something the plan says must not change; the number of rounds alone is no reason, but a finding whose kind comes back after its whole kind was swept is, the first time it comes back (`docs/pull-requests.md`, The loop);
- before each [quiet] measurement, to pause other work ([Measurements](#measurements));
- before an action seen outside the repository's branches and PRs, such as `mise run mirror-external-tools` (an upload to the external-tools release), unless the owner approved it in advance (an owner decision); a step agent never runs one;
- which triaged out-of-scope items go into `PROJECT_NOTES.md` (step 6);
- for parallel work, and before any merge, an analysis's script PRs included (step 5);
- to start a long run (longer than the Bash tool's 10-minute limit), with its command (step 5).

What the owner granted for their absence ([While the owner is away](#while-the-owner-is-away)) replaces the asks it covers.
Everything else the orchestrator decides and explains in the report and PR descriptions, without stopping for sign-off between steps.

### While the owner is away

The owner may let the orchestrator go on alone, for example overnight; that is never the default, and the grant, with its scope, is recorded as an owner decision.
Within it, the orchestrator may:

- decide a finding that needs an owner decision where the plan and earlier owner decisions point one way; one they do not settle waits, and work that does not depend on it goes on;
- decide a PR or step the plan made conditional on measurements, from those measurements;
- carry out an irreversible step the plan describes (such as archiving data) once it is built and its reviews are clean;
- merge PRs whose review loop is clean and whose `mise run pr-checks` is green ([merging a stack](#worktrees-and-stacked-prs));
- start a long run itself, an analysis or a real run in a worktree (a run in place on an existing experiment stays blocked, see [real runs](#5-build-the-prs-one-at-a-time-up-the-stack)), one at a time at concurrency 3 at most, so no more than 3 games run at once in all (no agent's smoke or profile run beside it), as its own background job (`run_in_background`, which notifies it at the end), not a step agent's (owner, 15 Oct 2026: "Yes, while away you can start long running stuff (max concurrency of 3).
  Not during normal operations though.").
  A run still going when the owner returns is stopped so it can resume (SIGINT to its process group, as the reviewer prompt in `docs/pull-requests.md` shows), unless the owner wants it to finish;
- run [quiet] measurements unattended when the owner said nothing else runs on the machine, only while neither it nor its agents build, test, or play a long run, recording the load average before each.

It records each such decision in the plan as it makes it and lists them in the report.

## Watching running agents

A subagent can finish its work and never report, for example while waiting on its own background job, even when briefed to work in the foreground; nothing tells the orchestrator, and the run stalls until the owner asks.
So the orchestrator checks each running agent on a background timer: `git log` and `git status` in its tree, `git worktree list`, and the process list (its builds, tests, runs), against what the step should produce.
An agent with no progress over two checks gets a message asking for its status and report; one that still does not answer is stopped, and a fresh agent takes over from what is committed.
A message to an idle agent may show as queued; the agent picks it up, so wait rather than send again.
When an agent reports, cancel its timer at once (TaskStop); a timer that fires afterwards is stale, so ignore it without telling the owner.
After an agent is stopped from outside, such as by the usage limit, check its tree (`git status`, `git log`) after the reset and resume it by message, saying what survived, so it neither redoes committed work nor builds on lost edits.
No tool does these checks automatically yet (`PROJECT_NOTES.md`).

## Step brief

Give the step agent the plan's path, the step, every clause of the plan that names the step (the design decisions included; quote or point, since a summary drops clauses), the owner's decisions it touches, the step's checks, and this file's path with the instruction to follow this section.
Write into the brief itself the two instructions agents skipped when only pointed here: tests first, and a long enough time limit on every command (`mise run test` needs at least 400000 ms, `docs/code-reference.md`, Build and test notes).
Ask for a short report: commits, files, test count, whether each test failed before its code existed, every decision the plan did not settle, what later steps need to know, and out-of-scope items.
Give every reviewer the same request for out-of-scope items, beside its findings, and the foreground rule below.
The step agent:

- writes tests first and checks they fail before the code exists, on data shaped like real data and, for a report script, on the whole output (`docs/pull-requests.md`, Tests);
- runs a command that writes files outside the repository's own outputs (a micro-test or micro-benchmark) from a new scratch directory, since from the repository it leaves them in the root (`mise exec -C REPO -- sh -c 'cd SCRATCH && cmd'`, since `-C` changes into REPO);
- runs `mise run test` before each commit, `git status` so no stray file is left or committed, and `git status --ignored` after adding files, since a rule such as `*.out` can hide a fixture;
- where the tests stub the programs a change spans (the Ruby tests stub the C programs), runs a short seeded experiment through the real runner in a worktree ([Worktrees and stacked PRs](#worktrees-and-stacked-prs)), such as the smoke run in `docs/experiment-reference.md` or, for a runner change, the seeded comparison under [real runs](#5-build-the-prs-one-at-a-time-up-the-stack), since a mismatch between C output and Ruby parser passes every test;
- runs the other checks its step names;
- runs every command in the foreground with an explicit `timeout` long enough for it (without one, Claude Code backgrounds a command after 2 minutes), starts no background job, never ends a turn waiting on background work, and reports as soon as the step is done ([Watching running agents](#watching-running-agents));
- does not run a command longer than the tool's 10-minute maximum but reports it as a stop halfway (step 5, Steps), and finishes the step with its output once the owner, or the orchestrator while the owner is away, has run it;
- for a [quiet] measurement, writes the command, uses a provisional value where the code needs the number, and does not run it ([Measurements](#measurements));
- runs no action seen outside the repository's branches and PRs, such as `mise run mirror-external-tools`, and leaves it to the orchestrator, which asks the owner first ([When to ask the owner](#when-to-ask-the-owner));
- cites GitHub PR numbers, and commit ids only of commits on `main`, never the plan's labels ([the plan](#2-write-the-plan));
- commits with the conventions in `CLAUDE.md` and does not push;
- reports, without acting on it, anything outside its step that tripped it up or could be better, in the code or the tools ([the plan](#2-write-the-plan)), as an out-of-scope item;
- does not edit the plan; its report carries what the plan needs.

## Checks and their cost

Each check earns its cost only where it can find something the others do not.

| Check | When | Why there |
| --- | --- | --- |
| Plan review | Before code; again, of the whole plan, after a finding or the owner changed it | Design gaps are cheapest before code; a pilot or simulation finds errors of a statistical design or an analysis's measures that reading does not. |
| Per-commit review | Each code commit a later commit of the PR depends on | Finds a defect before later steps build on it. |
| Whole-branch review | Each PR, before its first push and after every later change, except a merge that `docs/pull-requests.md` step 7 exempts (commits already reviewed or merged through their own PR) | Sees how commits fit and what they left stale. |
| Mutants | In each review of code, a few on the behavior the change adds or fixes | The only proof that a test catches a break; on macOS a quick rebuild can run a stale binary and fake a survivor (`docs/code-reference.md`, make 3.81). |
| GCC in Docker (`make test` in `gcc:14`) | The whole-branch review of a PR that changes C; a step, only when later steps rely on its floating-point results before CI sees them | The local build is clang and CI's is GCC, whose floating-point results and warnings differ; CI runs GCC on every push, so once per PR is enough. |
| Seeded smoke run | Each step whose tests stub a program it changes; for a runner change, the seeded comparison against the base (step 5, real runs) | Stubs hide a mismatch between the programs. |
| Real runs | Once, at the end of the last code PR | They find design consequences no review predicts. |

## Measurements

The machine runs other work that can take much CPU and memory, so a timing taken meanwhile is unreliable.
A measurement whose numbers the plan or docs rely on is marked **[quiet]** in the plan and split:

- The step agent writes its command or script and, where the code needs the number, uses a provisional value.
- The orchestrator asks the owner to pause the other work and whether that work needs the disk, and waits, unless the owner said the machine stays quiet ([While the owner is away](#while-the-owner-is-away)).
  It checks free disk with `df` before a large workload, records the load average, runs only the measurement, and tells the owner they can resume.
  It quotes every figure, the load average included, from what it recorded for that run, never from an earlier command or memory.
- The step, or a follow-up commit, records the numbers or sets the value.

Measure at the concurrency the owner runs experiments at (3, `docs/performance.md`), not at the core count, since on the M3 the workloads were defined on, 8 jobs oversubscribe its 4 performance cores, and a slowdown seen at 8 vanished at 3.
Report the breakdown, not only the headline, since it can show a cheaper fix that makes the measured PR not worth building; for the same reason, re-decide a PR the plan made conditional on a measurement whenever an earlier step changes its payoff.

Builds, test suites, smoke runs, and real runs for correctness need no quiet machine.
A hang guard (a deadline of which one miss stops a run) is the opposite: set it from the worst case under normal load with a wide margin, since a quiet measurement gives only a floor.

## Analyses and results docs

An analysis turns experiment data into numbers that go into results docs or decide the next experiment: a count of repeated games, a comparison of two runs' genes, a statistical test of mutated champions.
Three kinds of numbers follow their own rules instead: [quiet] measurements ([Measurements](#measurements): the orchestrator runs a reviewed command and quotes what it recorded), examples from seeded runs, which give their full command (step 5, real runs), and the pilots and simulations of a plan review, which shape a plan whose code is then reviewed; a number the docs keep from such a design comes from that code's run.
Analysis figures from one-off queries went wrong, hence (owner, 14 Oct 2026: "I've noticed that just doing it as one offs results in issues in the calculations and might lead to wrong results.
So plan, write scripts, proper PRs with reviews etc, and only then let's run them."):

- **Script first.** Write the analysis as a script in `scripts/` with tests, and merge it through a reviewed PR before running it for the docs.
  Its tests meet the standard of experiment code (`docs/pull-requests.md`, Tests), since a wrong figure misleads the next run as much as a wrong result does.
- **"Cannot tell" is a result.** Owner, 12 Nov 2026: "It is also fine to have the outcome that you actually cannot tell from 1000 generations if it's a stall or not.
  Let's not make the mistake (here and [in] any other analysis) of trying to find things in the data that are not actually there.
  If we cannot tell one thing from another at that point that's also a valid outcome."
  What the outputs cannot tell apart, the results doc reports plainly as "cannot tell".
  Three practices keep an analysis from finding what is not there (applied in `docs/findings.md`, "Elitism (`elite_share`)"):
  - **Design for the runs there are.** Before designing a comparison of settings, count the runs of each.
    With one run per setting, a difference between runs cannot be told from the spread between two runs of one setting, so a test between the settings tests the runs.
    Such an analysis describes each run from the start, attributes nothing to a setting, and names more seeds as the way to tell settings apart; if telling them apart is the point, ask the owner whether to run more seeds first (owner, 12 Nov 2026: "Descriptive only").
    Beside a difference between runs, the doc sets the differences between two runs of one setting that the outputs hold for the same measure and generations, or says there are none.
  - **Rules fixed before the outputs.** Before the scripts run, the plan fixes the windows and defaults, which windows and checkpoints the results doc covers, and for each question the output it is answered from.
    It names the output, never the statement, since a fact the plan tells the doc to state can turn out contradicted by the data.
    Only an owner decision, recorded as one, changes these rules after the outputs are seen.
  - **Answers and the command to rerun.** Per analysis, the results doc (an entry in `docs/findings.md`) gives the questions, a plain answer to each ("cannot tell" allowed), the runs, and the command and revision that reproduce the numbers (owner, 12 Nov 2026: "Answers + command", replacing the earlier layout of tables by stated rules).
    A table appears only where a question's answer is a table; for more detail, readers rerun the script.
    No sentence sums up over some of the runs, windows or measures, or from a starting point, since the pick leans one way; a statement or range over every run, window or measure the outputs hold, or every one a stated rule names, picks nothing and may stay ("in every window …").
- **Raw outputs kept.** Run the script from a merged revision and keep its raw output, with that revision, beside the plan (`plans/NAME-results/`), so the results PR's reviewers check each figure against the output, not the writer's notes.
  The plan and its results are deleted at the end (step 7); the docs keep the command and the revision, so anyone can run it again.
- **Figures from the outputs only.** The docs quote numbers from those outputs and, beyond them, hold only what the exceptions below allow.
  A reviewer may refute a claim with a query of its own; a new figure from such a query reaches the docs only through a script, and until then it is an out-of-scope item.
- **Claims no stronger than the outputs.** Check every sentence, the interpretation's included, against these before the first review, since otherwise each review round finds another sentence that claims more than the output shows:
  - Not detected is not absent: a test that finds no effect rules out only effects above the size it can detect, so say "no detectable average loss" with that size, not "no loss".
  - Power is not certainty, and covers only what was tested: at 80 % power a null result still misses an effect of that size one time in five, and a test of each step's four best children says nothing about the others.
  - A correlation is not a cause: say what was measured, and label a causal reading as interpretation.
  - A qualifier must match the number beside it: a champion is not "nearly insensitive to mutation" while 68 % of its step-0.5 children's games differ from its own.
  - An expected value is not a measured one: 229 weight changes per child was the expected count, and the program's output showed 186 to 273.
  - An interpretation may suggest, not settle: every fact in it comes from the outputs, and where they cannot separate two explanations (such as luck and a stronger next field) it names both and says so.
- **The exceptions.** This is the one list of what results docs may hold, for analyses, besides the outputs' figures and what follows from them; `CLAUDE.md` and the severity rule in `docs/pull-requests.md` point here rather than repeat it, so the copies cannot drift apart:
  - An estimate made before the run (its cost, its expected power), labelled as an estimate.
    The run's figures replace it where its outputs give them; a cost stays a labelled estimate unless a [quiet] measurement replaces it, since a timing the docs rely on is one.
  - A caveat a reviewer's own query raised, as its mechanism without the query's figure: the clone-repeat share can grow with the rounds counted, since two clones repeat a game only when they meet the same opponent with the same colour.
  - Figures a section marks as predating this rule, from one-off queries the owner shipped after review (the figures of `docs/findings.md`, "Fixed mutation genes", #119, 14 Oct 2026); later text may cite them, and a change to them goes through a script.
  - Interpretation, in its own labelled bullet or paragraph, apart from the results, so a reader can tell what was measured from what is read into it; it is checked as strictly as the figures (above).

## Worktrees and stacked PRs

- **Stacking.** A PR may be stacked on another PR's branch, since CI runs on every pull request, whatever its base.
  Stack a PR on another that changes the same code, so it is built and reviewed on top of that change; PRs that share only neighbouring text (each deleting its own `PROJECT_NOTES.md` item) need not stack, since `docs/pull-requests.md` step 7 exempts that conflict from a new review.
  Branch a stacked PR from its base once the base PR is open, its review loop done, and `mise run pr-checks` green (step 5).
  A base with a branch built on it is merged, not rebased (`docs/pull-requests.md` step 1); if it was rebased anyway, move the stacked branch with `git rebase --onto NEW_BASE OLD_BASE`, OLD_BASE being the base's commit id from before its rebase.
  A stack's PRs may be linked into a GitHub stack with `gh stack link BOTTOM … TOP` (the `github/gh-stack` extension), which changes no branch; bring them up to date by merging as step 1 says, not with `gh stack sync` or `gh stack rebase`, which rebase and force-push every branch.
- **When the base merges.** Merge the base PR without `--delete-branch`, retarget the stacked PR to `main` (`gh pr edit PR --base main`, checked with `gh pr view PR --json baseRefName`), and only then delete the base branch (`git push origin --delete BRANCH`), since deleting it while a PR still targets it closes that PR instead of retargeting it.
  Then merge `origin/main` into the stacked branch and follow `docs/pull-requests.md` step 7.
- **Merging a stack,** once the owner says so: merge the bottom PR, retarget the next as above, bring it up to date, wait for `mise run pr-checks`, merge it, and repeat.
  A linked GitHub stack can instead be merged at once, all or nothing, with `gh stack merge TOP_PR --merge`; the repository merges with merge commits, so merging `origin/main` in is clean.
- **Worktrees.** Every agent that builds or runs tests outside the tree it writes to (a reviewer, a second PR in parallel) uses its own `git worktree`, since two agents must never write to the same tree at once.
  To set one up, link the main checkout's installed tools into it (`ln -s /path/to/checkout/.local .local`; `/.local` is gitignored), then run `mise trust` and `mise run setup` there (submodule, gems, build); until setup (or `git submodule update --init`) has run, `pcg-c` is empty and every `mise run` task that runs `make` (`build`, `test`, `verify`, `clean`, …) fails.
  The runner needs a repository root as its working directory (`docs/experiment-reference.md`), so a throwaway or comparison run goes in such a worktree, with `mise run run` or `mise run profile-workload` run from there.
  Remove it with `git worktree remove --force`, since git refuses without the flag while the worktree holds the `pcg-c` submodule; for the same reason `gh pr merge --delete-branch` on a branch checked out in a worktree skips the local cleanup, so remove the worktree, then delete the local branch.
- **Parallel work,** when the owner agreed to it: a review of step N in its own worktree while step N+1 is built, or a PR not stacked on an unfinished one in its own worktree.
