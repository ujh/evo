# Evo project guidance

Evo evolves dense neural networks that play Go. The C programs build, breed, and play networks; Ruby runs tournaments and benchmarks. The goal is measurable improvement in Go play. A head start such as Go features or search is welcome; compare it with a run without that head start.

`PROJECT_NOTES.md` contains only unfinished work and open questions. Read the relevant part before changing behavior. Remove an item when the change resolves it. Put lasting implementation facts in the relevant topic document below.

## Commands

Use mise: it pins Ruby, Java, and jq and adds the local Go tools to `PATH`. For one-off commands, use `mise exec -- <cmd>`. Build from the repository root.

| Task | Command |
| --- | --- |
| First setup | `mise run setup` |
| Install external Go programs | `mise run setup-experiments` |
| Build | `mise run build` |
| C and Ruby tests | `mise run test` (or `test-c`, `test-ruby`) |
| Full CI-equivalent check | `mise run verify` |
| Create an experiment without prompts | `mise run new-experiment NAME --board-size 9 ...` |
| Run or resume an experiment | `mise run run NAME [CONCURRENCY [one-generation]]` |

`mise run example` opens a GoGui window; do not use it headless.

## Read when relevant

- [Code reference](docs/code-reference.md): engine rules, network format, breeding programs, build and test details, CI, and external tools.
- [Experiment reference](docs/experiment-reference.md): tournament and benchmark rules, game results, the runner, SQLite storage, stats, and recovery.
- [Performance measurements](docs/performance.md): measured costs and historical experiments. Read before optimizing.
- [Go features](docs/features.md): feature design, groups, weights, and comparison results.
- [The evolving genome](docs/genes.md): genes, mutation, crossover, structure, and run interpretation.
- [GTP version 2 specification](docs/gtp/README.md): the protocol evo and the bot controller speak; grep `gtp2-spec.txt`.
- [PR workflow](docs/pull-requests.md) and [larger change workflow](docs/orchestration.md): follow when preparing the corresponding work.

## Working conventions

- Fix defects test-first: write a test that fails, then fix.
- Commit with an imperative, sentence-case subject and a body explaining why. Use `fix/…`, `chore/…`, or `docs/…` branches.
- For pull requests, follow `docs/pull-requests.md`. For changes larger than one PR, follow `docs/orchestration.md`.
- Add numbered Sequel migrations for schema changes; never edit a migration that has run.
- `pcg-c/` is an upstream submodule; do not edit it.
