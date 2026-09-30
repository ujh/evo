# Larger changes: plan, delegate, review, report

Use this for any change bigger than one PR, or one that needs several design decisions. Small changes follow `docs/pull-requests.md` alone. This file says who does what and in which order; `docs/pull-requests.md` holds the rules every review and every PR follows, and this file only adds what a run of several steps needs on top.

## Roles

- **Owner:** decides scope, trade-offs, and defaults, approves the plan, and says when to merge.
- **Orchestrator** (the agent in the conversation): agrees the work with the owner, writes the plan and is its only editor, briefs every other agent, [watches them while they run](#watching-running-agents), decides what the owner left open, keeps the learnings log and the out-of-scope list, and reports. The plan then has one writer and says what the orchestrator knows.
- **Step agent:** a fresh subagent that does one step, commits without pushing, and reports. It does not edit the plan.
- **Reviewer:** a fresh subagent that has not seen the work. It reports findings under `docs/pull-requests.md` and never writes to a tree an agent is working in.

Run one agent at a time: on this side project token use matters more than speed. Parallel work (see [Worktrees and stacked PRs](#worktrees-and-stacked-prs)) is an option to agree with the owner at the start, and to record as an owner decision.

## The run

### 1. Agree the work

Discuss the goal and ask every question whose answer is the owner's to give (scope, trade-offs, defaults) before writing any code, and record the answers as owner decisions, in the owner's words and with the date: reviewers and the report then work from what the owner said, not a summary of it. A request the owner makes along the way that is not part of the plan's work (an open item for `PROJECT_NOTES.md`, a change to these docs) is an owner decision too; give it a home in one PR's docs, so it is not lost. Decide the rest yourself and explain those decisions in the PR descriptions.

### 2. Write the plan

Write the plan to `plans/NAME.md` in the repository root. The directory is gitignored, so the plan survives a lost session without entering the history. It holds:

- the goal, and what must not change (for example "a seeded run gives the same births, games, and rankings as `main`");
- the owner's decisions, each request outside the plan's work with the PR whose docs carry it;
- the declined findings, each with its reason; every reviewer gets this list, so it does not raise them again;
- the facts the design rests on, each with its `file:line`, read in the code that acts on it, not only in the config or docs that describe it: one plan's premise that experiments use their own copies came from `mise.toml`, and missed that the runner itself built on every start, which the first run needed;
- the design decisions you made. One that moves code or a check names its exact new place, checked against what must come before and after it: the obvious place for a moved build, where it ran before, was before the lock and the database open;
- the steps as a checklist, grouped by PR, in an order where the PRs can merge one after the other. Each step is small enough for one agent and one or two commits, and names the checks it needs beyond `mise run test` (a GCC build, a smoke run; see [Checks and their cost](#checks-and-their-cost)). A step of real runs and owner docs may be larger. The last code PR ends with a step of real runs; after it come the whole-process review (step 5, with its final docs PR if it yields changes) and, as the last item, deleting the plan once its PRs merge (step 7), which is easy to forget;
- the measurements whose numbers the plan or docs will rely on, each marked **[quiet]** in its step ([Measurements](#measurements));
- a learnings log: what worked, what went wrong, tool quirks, and what the owner asked to change about the process. Add to it as things happen, not from memory at the end: it is what the [whole-process review](#5-build-the-prs-one-at-a-time-up-the-stack) works from;
- a list of out-of-scope items: improvements that lie outside the plan's work, of two kinds. One is code that is not ideal: a confusing name, a duplicated rule, a slow or flaky test, a missing check. The other is the tools and scripts agents work with (mise tasks, the `pr-*` scripts, the test and smoke-run commands, the reference docs): a step that took many commands and could be one script, output too long or too vague to read, a check with no command to run it, a doc that sent an agent the wrong way. Each item says who raised it, in which step, and where (a file and line, or a command). The learnings log is about how the run works and ends up in these docs; this list is about the repository and may end up in `PROJECT_NOTES.md` (step 6).

Each PR updates the docs it makes stale (`docs/pull-requests.md` step 3). Do not park those edits in a final docs step, or the PRs before it merge with stale text.

The plan's own labels (a PR's place in the plan such as "PR 1b", a step number) mean nothing once the plan is deleted (step 7), so no repository file names them: commits, comments and docs cite commit ids and GitHub PR numbers.

### 3. Review the plan

Have a fresh subagent review the plan before any code is written: missing cases, rules of the external tools (GoGui, GNU Go, GTP) that the design depends on, and docs that the change will make stale. Design gaps are cheapest here. Ask the reviewer to check the maths numerically and the external tools by running them, not by reading alone: measured numbers, not estimates, set a design's constants. Where cost or convergence depends on the data's size, ask for the check on a synthetic data set as large as real use will reach, not only on the real data, which may still be small: the rating fit first planned for #107 was 10–25 times over its time budget on a synthetic chain of 500 champions, the size a long experiment reaches, while the live experiment then had only a few checkpoints. When the work brings in a new external tool, try it yourself while writing the plan (build it, play a few games through the arena) and record what you find in the plan: in one run, doing so and the reviewers' own runs found both of a new bot's blockers (a crash after a pass, a refused move) before any code, where reading its source had not. Ask the reviewer, too, to check how each measurement or calibration will be taken, not only the code it feeds: four of one plan's six review rounds found a gap in a measurement method, such as a check that could not hold, benchmark workloads that the new defaults would silently redefine, two settings calibrated from one table although one changes the other, and a run meant to count network games that played none. Fold the findings into the plan. When a finding or the owner changes the design, have a fresh subagent review the whole plan again before any code, not only the changed parts: a change can leave other parts that no longer fit. The loop is that of `docs/pull-requests.md`: fresh whole-plan reviews until one has no blocker and no important finding. Quote that file's severity rule for a plan review (Severity) in every plan-review brief from the first round: without it, plan reviews kept raising as important edge cases a step agent settles anyway while writing its tests, one per round.

### 4. Get the owner's approval

Show the plan to the owner and wait for their approval before any code is written. Show it in plain language: explain each mechanism with an example or a small diagram, not only as a list of steps, since the owner can only approve what they understand. Expect questions, and put the answers back into the plan. The owner may approve in advance (for example "start once the review is folded in"); then start as soon as the findings are in the plan, and record the approval as an owner decision. A design change after approval, the owner's or a finding's, goes through step 3 again, and the owner approves the change before code builds on it.

### 5. Build the PRs, one at a time up the stack

Take the PRs in the plan's order, and finish each one before the next begins: its steps, its whole-branch review loop, then push, open, and `mise run pr-checks`. Only then branch the next PR from it and start that PR's first step. So a PR stacked on another is built on commits whose review is done, and a fix to the base never has to move a branch already built on it.

**Steps.** Give each step to a fresh step agent with the [step brief](#step-brief). When it reports, check the report against every clause of the plan that names the step, the design decisions included: a clause the brief left out is work no step does, and only the whole-branch review can still catch it (a clock change in the design section was once never briefed, and so never built until that review). Then tick the step in the plan with its commit ids and what later steps need to know (a new interface, a name, a number), record the decisions it made, add to the learnings log, and copy its out-of-scope items into the plan's list. Do the same with the out-of-scope items of every reviewer's report, the plan review's included. A step that needs the orchestrator's choice halfway (run a calibration, pick the levels from its table, then build on them) stays with one agent: its brief says where to stop, the agent reports there as if the step were done, the orchestrator records its choice in the plan and sends it to the same agent, which goes on with its context intact, and the orchestrator starts a new heartbeat for it ([Watching running agents](#watching-running-agents)). If that agent is gone, brief a fresh one with the choice and the first part's commits.

**Per-commit review.** After each code commit, a fresh reviewer reviews that commit under `docs/pull-requests.md`, with the owner's decisions and the declined findings, so a defect is fixed before the PR's later steps build on it. A commit that changes only docs gets no review of its own, and neither does one that no later commit of the PR depends on (the commit of a PR with a single step, the last step's, or a fix for a per-commit finding that later steps do not use): the PR's whole-branch review covers it, mutants included. For such a fix, that review is the next round of the loop in `docs/pull-requests.md`, reviewing the whole change from scratch. Fix blockers and important findings before the next step that depends on them:

- Send the fix back to the agent that wrote the step, since it keeps its context, once no other agent is writing to that tree. If that agent is gone, brief a fresh one with the finding.
- A fix is a new commit on top. Amending or rebasing a commit that another branch is built on moves that branch's base. A stacked branch that is not yet pushed may instead be rebased onto its fixed base ([Worktrees and stacked PRs](#worktrees-and-stacked-prs)).
- A nit about lines a later step touches goes into that step's item in the plan, not into a commit now: that step rewrites those lines anyway.

**Whole-branch review and the PR.** Once the PR's last step is ticked, follow `docs/pull-requests.md` for it: stale-text sweep, whole-branch review loop, push, and `mise run pr-checks`. In a planned run, the whole-branch reviewer gets the per-commit findings and what happened to each, and looks for what a review of one commit cannot see: how the commits fit together and text they left stale. `mise run pr-checks` compares against the local `HEAD`, so run it in the checkout that has the PR's branch.

**Real runs.** Finish the last code PR with a step of checks on real runs, not only unit tests; they find what reviews do not, such as a design consequence no one predicted: a seeded run compared against `main` where behavior must not change, reproducibility (the same seed twice), and resume after an interrupt where the change touches the runner. For a runner change, the seeded comparison is cheap enough for every step as well: `mise run profile-workload small --tiny --keep` in a worktree at the base and in one at the step's commit, then compare the kept databases with `sqlite3 -readonly` and delete them (`--tiny`'s timings mean nothing, but its seeded results compare): births (every column, the SHA-256 `genome` included), games and benchmark results without their time columns, and rankings; timings and `provenance` always differ. Examples in the docs come from seeded runs, with the full command, so a reader can repeat them. Report a result that argues against the design; do not stop for it unless it means the goal cannot be met. A run in place on an existing experiment, or deleting an experiment that existed before the run, is blocked by Claude Code's permission check even with the owner's go-ahead; give the owner the exact commands to run with `!` instead of trying.

**Whole-process review.** The plan's last step before cleanup gives a fresh step agent the plan's learnings log; it reviews the whole process as one system and edits the docs: this file, `docs/pull-requests.md`, and `CLAUDE.md`'s working conventions. It folds in what generalizes as a rule with its reason, drops one-offs, and restructures where the parts no longer fit rather than patching lines, since rules added one at a time drift apart; repository quirks go into the relevant reference linked from `CLAUDE.md`. If that yields useful changes, the plan ends with a final docs PR, which a reviewer then reviews as usual and which goes through the same CI as the others, so it is in the report (owner, 29 Sep 2026: plans now always have a learnings log, so go over the process as a whole at the end of each plan and open a final PR if there are useful changes; this replaced a review every third run).

### 6. Report

Report once, when every PR, the final docs PR included, is open and green: what each PR does, what the reviews found and how it was settled, the decisions you made, what the real runs showed (including results that argue against the design), what the owner must know (for example that old experiments no longer load), and anything left open. Do not merge unless the owner says so; how to merge a stack is under [Worktrees and stacked PRs](#worktrees-and-stacked-prs).

Before reporting, give the plan's out-of-scope list to a fresh subagent to triage. For each item it checks against `main` whether it still holds, whether a merged or open PR (these included) already settled it, and whether `PROJECT_NOTES.md` already has it; it drops those, merges duplicates, and drops one-offs that will not trip anyone again. For each item it keeps, it says in plain language what the problem is, where it is, and why fixing it would help: for a tool or script, what agents would no longer have to do by hand or work out again. Put that list in the report and ask the owner which items go into `PROJECT_NOTES.md`. Add those in a commit on the final docs PR (or the last PR, if there is none), follow `docs/pull-requests.md` step 7 for it, and tell the owner when its checks pass again.

### 7. Clean up

Once all of the plan's PRs have merged, delete the plan from `plans/`: it then holds nothing the repository's history and docs do not. It is the plan's last checklist item (step 2), since a finished plan was once left behind.

## When to ask the owner

Stop and ask only:

- before the plan, for every decision that is the owner's (step 1);
- for approval of the plan, unless given in advance, and of a design change after approval (step 4);
- when a finding of any review (plan, commit, or branch) needs a decision only the owner can make, such as changing scope, approach, or something the plan says must not change; the number of rounds alone is no reason to ask (`docs/pull-requests.md`, the loop), unless the owner granted such decisions ([While the owner is away](#while-the-owner-is-away));
- before each [quiet] measurement, to pause other work ([Measurements](#measurements)), unless the owner said the machine stays quiet ([While the owner is away](#while-the-owner-is-away));
- before an action seen outside the repository's branches and PRs, such as uploading archives to the external-tools release (`mise run mirror-external-tools`), unless the owner approved it in advance (record that as an owner decision); a step agent never runs one;
- which triaged out-of-scope items go into `PROJECT_NOTES.md` (step 6);
- for parallel work, and before merging, unless the owner granted merging ([While the owner is away](#while-the-owner-is-away)).

Everything else the orchestrator decides and explains in the report and the PR descriptions. Do not stop for sign-off between steps.

### While the owner is away

The owner may let the orchestrator go on alone, for example overnight. That is an option the owner grants, with its scope, and it is recorded as an owner decision; it is never the default. Within what the owner granted, the orchestrator may:

- decide a finding that needs an owner decision, where the plan and the earlier owner decisions point one way; a finding they do not settle waits for the owner, and work that does not depend on it goes on;
- decide a PR or step the plan made conditional on measurements, from those measurements;
- carry out an irreversible step the plan describes (such as archiving data) once it is built and its reviews are clean;
- merge PRs whose review loop is clean and whose `mise run pr-checks` is green, as [merging a stack](#worktrees-and-stacked-prs) says;
- run [quiet] measurements unattended, when the owner said nothing else runs on the machine, only while no agent of its own builds or runs tests, and recording the load average before each.

It records each such decision in the plan as it makes it and lists them in the report, so the owner can check them on return.

## Watching running agents

A subagent can finish its work and never report, for example while it waits on a background job of its own; nothing tells the orchestrator, and the run stands still until the owner asks. Briefing it to work in the foreground is not enough: a reviewer so briefed once ended its turn waiting on its own background job, and reported only when that job ended. So while an agent runs, the orchestrator checks it at regular intervals, with a background timer as the heartbeat: `git log` and `git status` in the agent's tree, `git worktree list`, and the process list (its builds, tests, runs), against what the step should be producing. An agent that shows no progress over two checks gets a message asking for its status and its report; one that still does not answer is stopped, and a fresh agent takes over the step from what is committed. A message sent to an idle agent may be reported as queued rather than delivered; the agent picks it up, so wait for its answer rather than sending again. When an agent reports, cancel its timer at once (TaskStop): a timer left to run out fires after its agent is done, and one run collected many such stale notifications. One that fires anyway is stale: ignore it without telling the owner. No tool does these checks automatically yet (`PROJECT_NOTES.md`).

## Step brief

Give the step agent the plan's path, the step, every clause of the plan that names the step (the design decisions included; point to them or quote them, since a summary drops clauses), the owner's decisions it touches, the checks the step names, and this file's path with the instruction to follow this section. Ask for a short report: commits, files, test count, every decision the plan did not settle, what later steps need to know, and its out-of-scope items. Give every reviewer the same request for out-of-scope items, next to its findings, and the rule on foreground work below. The step agent:

- writes tests first and checks that they fail before the code exists;
- changes into a new scratch directory before any command that writes files outside the repository's own outputs (a micro-test or micro-benchmark), since a command run from the repository leaves its files in the root (`mise exec -C REPO -- cmd` changes into REPO before running cmd, so wrap it as `mise exec -C REPO -- sh -c 'cd SCRATCH && cmd'`); an experiment instead goes in a worktree, since the runner works only from a repository root ([Worktrees and stacked PRs](#worktrees-and-stacked-prs));
- runs `mise run test` before each commit, and checks `git status` so no stray file is left or committed, and `git status --ignored` after adding files, since a rule such as `*.out` can hide a fixture the tests need;
- where the tests stub the programs a change spans (the Ruby tests stub the C programs), runs a short seeded experiment through the real runner, such as the smoke run in `docs/experiment-reference.md`, or for a runner change the seeded comparison against the base under [real runs](#5-build-the-prs-one-at-a-time-up-the-stack): a mismatch between the C output and the Ruby parser passes every test. The runner works only from a repository root, so an experiment outside the checkout runs in a worktree ([Worktrees and stacked PRs](#worktrees-and-stacked-prs));
- runs the other checks its step names;
- runs every command in the foreground with an explicit time limit, starts no background job, never ends a turn waiting on background work, and reports as soon as the step is done ([Watching running agents](#watching-running-agents));
- for a [quiet] measurement, writes its command or script and uses a provisional value where the code needs the number, and does not run it ([Measurements](#measurements));
- runs no action seen outside the repository's branches and PRs, such as `mise run mirror-external-tools`, and leaves it to the orchestrator, which asks the owner first ([When to ask the owner](#when-to-ask-the-owner));
- cites commit ids and GitHub PR numbers, never the plan's labels ([the plan](#2-write-the-plan));
- commits with the conventions in `CLAUDE.md` and does not push;
- notes, without acting on it, anything outside its step that tripped it up or could be done better, in the code or in the tools and scripts it worked with (both kinds under [the plan](#2-write-the-plan)), and reports each as an out-of-scope item;
- does not edit the plan: its report carries what the plan needs.

## Checks and their cost

Each check earns its cost only where it can find something the others do not.

| Check | When | Why there |
| --- | --- | --- |
| Plan review | Once before code; again, of the whole plan, after a finding or the owner changed it | Design gaps are cheapest before code. |
| Per-commit review | Each code commit that a later commit of the PR depends on | Finds a defect before the PR's later steps build on it. |
| Whole-branch review | Each PR, before its first push and after every later change, except a merge of commits already reviewed that `docs/pull-requests.md` step 7 exempts | Sees how commits fit and what they left stale. |
| Mutants | In each review of code, a few on the behavior the change adds or fixes | The only proof that a test catches a break. On macOS a quick rebuild can run a stale binary and fake a survivor (`docs/code-reference.md`, make 3.81). |
| GCC in Docker (`make test` in `gcc:14`) | In the whole-branch review of a PR that changes C; in a step, only when later steps rely on its floating-point results before CI sees them | The local build is clang and CI's is GCC: floating-point results and warnings differ. CI runs GCC on every push, so once per PR is enough. |
| Seeded smoke run | Each step whose tests stub a program it changes; for a runner change, the seeded comparison against the base (step 5, real runs) | Stubs hide a mismatch between the programs. |
| Real runs | Once, at the end of the last code PR | They find design consequences no review predicts. |

## Measurements

The machine runs other work that can take much CPU and memory, so a timing taken while it runs is unreliable. A measurement whose numbers the plan or the docs rely on is therefore marked **[quiet]** in the plan and split:

- The step agent writes the measurement's command or script, and where the code needs the number, uses a provisional value.
- The orchestrator asks the owner to pause the other work and whether that work needs the disk, and waits for the answer, unless the owner said the machine stays quiet ([While the owner is away](#while-the-owner-is-away)). It checks free disk with `df` before a large workload, records the load average, runs only the measurement, and tells the owner they can resume. It quotes every figure, the load average included, from what it recorded for that run, not from an earlier command or from memory: a report once gave the load average of an earlier `uptime`, and only the step agent noticed.
- The step, or a follow-up commit, records the numbers or sets the value.

Measure at the concurrency the owner runs experiments at (3, `docs/performance.md`), not at the core count: on the M3 the workloads were defined on, 8 jobs oversubscribe its 4 performance cores, and a result that looked like a slowdown at 8 vanished at 3. Report the breakdown, not only the headline: a measurement meant to decide one PR once showed, in its breakdown, a cheaper fix that made that PR not worth building. For the same reason, re-decide a PR the plan made conditional on a measurement whenever an earlier step changes its payoff.

Builds, test suites, smoke runs, and real runs for correctness need no quiet machine. A hang guard (a deadline of which one miss stops a run) is the opposite case: set it from the worst case under the machine's normal load with a wide margin, since a quiet measurement gives only a floor.

## Worktrees and stacked PRs

- **Stacking.** A PR may be stacked on another PR's branch: CI runs on every pull request, whatever its base. Stack a PR on another that changes the same code, so it is built and reviewed on top of that change (#102 on #100, both changing `stats`). PRs that share only neighbouring text, such as each deleting its own `PROJECT_NOTES.md` item, need not stack: `docs/pull-requests.md` step 7 exempts that conflict from a new review. Branch a stacked PR from its base once the base PR is open, its review loop done, and `mise run pr-checks` green (step 5). If the base is rebased afterwards, move the stacked branch with `git rebase --onto NEW_BASE OLD_BASE`, where OLD_BASE is the base's commit id from before its rebase.
- **When the base merges.** The repository deletes a merged PR's branch, so GitHub retargets the stacked PR to `main` (check with `gh pr view PR --json baseRefName`). Merge `origin/main` into it, then follow `docs/pull-requests.md` step 7.
- **Merging a stack,** once the owner says so: merge the bottom PR, confirm the next one now targets `main`, bring it up to date as above, wait for `mise run pr-checks`, merge it, and repeat. The repository merges with merge commits, so merging `origin/main` in is clean.
- **Worktrees.** Every agent that builds or runs tests outside the tree it writes to (a reviewer, or a second PR in parallel) uses its own `git worktree`. Never let two agents write to the same working tree at once. To set one up, link the main checkout's installed tools into it (`ln -s /path/to/checkout/.local .local`; `/.local` is gitignored), then run `mise trust` and `mise run setup` there (submodule, gems, build). The runner needs a repository root as its working directory (`docs/experiment-reference.md`), so a throwaway or comparison run goes in a worktree set up this way, with `mise run run` or `mise run profile-workload` run from there. Remove it with `git worktree remove --force`: without the flag git refuses, because the worktree holds the `pcg-c` submodule. For the same reason `gh pr merge --delete-branch` on a branch checked out in a worktree merges but skips the local cleanup; remove the worktree, then delete the local branch.
- **Parallel work,** when the owner agreed to it: a review of step N in its own worktree while step N+1 is built, or a PR that is not stacked on an unfinished one in its own worktree.
