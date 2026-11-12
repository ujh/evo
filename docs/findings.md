# Findings

What each experiment or analysis asked, what it answered, and the command that reproduces its numbers.
Results follow `docs/orchestration.md`, "Analyses and results docs": with one run per setting, a finding describes each run and attributes nothing to the setting.
How runs, `stats` and the benchmark work is in [Experiment reference](experiment-reference.md); what each analysis script prints is in [Analysis scripts](analysis-scripts.md).

- [What a comparison showed](#what-a-comparison-showed)
- [What a 20-generation default run showed](#what-a-20-generation-default-run-showed)
- [How noisy the tournament's ranking is](#how-noisy-the-tournaments-ranking-is)
- [10, 20 and 40 rounds](#10-20-and-40-rounds)
- [How often tournament games repeat](#how-often-tournament-games-repeat)
- [Fixed mutation genes (`meta_rate` 0)](#fixed-mutation-genes-meta_rate-0)
- [How brittle a champion is](#how-brittle-a-champion-is)
- [Elitism (`elite_share`)](#elitism-elite_share)

## What a comparison showed

Questions: does a run with every feature group ([Go features](features.md)) play better than one with the stones alone, and how do its feature weights move?
Runs: one with `features all`, one with `features none`, the same settings and seed otherwise (9×9, 20 networks of `1x50`, 5 rounds, 20 generations); one run per setting.

- Against Brown, which plays at random, the checkpoint champions won 6, 6, 9 and 9 of 10 games at checkpoints 0, 5, 10 and 15 with `all`, and 0, 4, 3 and 5 with `none`.
  Against AmiGo and GNU Go level 0, every checkpoint of both runs lost all 10 games, except one win against AmiGo by `none`'s generation 5.
  Against their own generation 0's champion, `all`'s checkpoints won 8–9 of 10 and `none`'s all 10; against the previous checkpoint, `all`'s won 5 of 10 at both checkpoints, `none`'s 1 and then 5.
  In the arena, `all`'s champion beat `none`'s in both colours at generation 15 and in one of two at generation 19.
- Whether the features make the difference: suggestive, not proof, with 10 games per opponent and one run per setting; more seeds and more games would tell.
- The `all` run's feature-weight medians moved most in the first five generations, faster than mutation could move them (at a `feature_step` of 0.01, five generations move a weight by at most about 0.05; saves_atari rose from 0.73 to 0.91); after that they barely moved (saves_atari 0.92 at generation 19), and `feature_step`'s median fell from 0.01 to 0.0050.
- Interpretation: selection picked among generation 0's noise; whether it picked for those weights or for the networks that carried them cannot be told apart from one run.

Source: these commands (26 Sep 2026, seed 2026), then `stats` and the arena; no script.

```sh
mise run new-experiment NAME --board-size 9 --population-size 20 --hidden-layers 1 --layer-size 50 \
  --cross-over-rate 0.5 --game-seconds 600 --max-moves 200 --tournament-rounds 5 --keep-every 5 \
  --benchmark-games 10 --features all --seed 2026      # and --features none
for i in $(seq 20); do mise run run NAME --concurrency 4 --one-generation; done
```

## What a 20-generation default run showed

Question: do the mutation genes reach a bound in a short run with the default genes and limits?
Runs: the two runs of [What a comparison showed](#what-a-comparison-showed), one with `features all` and one with `features none`.

- Neither run hit a limit, but the medians moved:

  | Gene | Start | `all` at generation 19 | `none` at generation 19 |
  | --- | --- | --- | --- |
  | `copy_chance` | 0.01 | 0.008 | 0.005 |
  | `weight_changes` | 21.2 (`all`), 3.3 (`none`) | 12.5 | 4.2 |
  | `weight_step` | 0.5 | 0.34 | 0.48 (about 0.74 around generations 14–17) |
  | `activation_rate` | 0.02 | 0.016 | 0.01 |
  | `structure_rate` | 0.02 | 0.008 | 0.016 (0.04 in between) |
  | `feature_step` | 0.01 | 0.005 | 0.01 (never moves) |

- Only two or three shape changes happened in each run, and none spread.
- Twenty generations cannot tell drift from selection.

Source: the commands under [What a comparison showed](#what-a-comparison-showed), then `stats` (26 Sep 2026); no script.

## How noisy the tournament's ranking is

Question: how much of a generation's tournament ranking is skill, and how much luck?
Run: `even-bigger2` (1,000 networks, 33 bot copies, 10 Swiss rounds, 5,160 games a generation), generations 1, 5, 20, 50, 100, 150, 200 and 235.

- The rating fit (`BenchmarkRatings`) on all 10 rounds is about half skill: by Spearman–Brown from the odd/even split, its reliability is 0.49–0.57; 20 rounds would make it about two thirds, 40 about four fifths, assuming added rounds are like the ones played (under the Swiss pairing, later rounds pair closer scores).
- The win count, which parent selection uses, cannot be measured by splitting; if the fit is the better estimate of skill, its reliability is about 0.94² of the fit's, about 0.46 at 10 rounds.
- The win count orders the networks much as the fit does (Spearman 0.94–0.95), but only 29–35 of the stored ranking's top 50 are in the fit's top 50.
- White wins 56–63 % of the tournament games; a network's number of games as White explains 1–7 % of the spread in win counts.
- Prediction, not a measurement (the breeder's equation, with the win count's reliability taken as 0.94² of the fit's): 20 rounds would select about 14–15 % better per generation than 10, at twice the tournament's cost, so less per unit of compute; ranking by the rating fit instead of the win count would select about 6 % better at no cost in games.

Source: `mise exec -- scripts/ranking-noise.rb experiments/even-bigger2/experiment.sqlite3 1 5 20 50 100 150 200 235` (30 Sep 2026; no revision named).

## 10, 20 and 40 rounds

Question: do champions get stronger with 20 or 40 tournament rounds than with 10, at equal compute (summed tournament hours)?
Runs: first seed, `even-bigger2` (10 rounds) and `rounds20` (20), every other setting and the seed the same; second seed (2246017379882995802), `seed2-rounds10`, `seed2-rounds20` and `seed2-rounds40`, `even-bigger2`'s settings otherwise, to generation 500.
Each seed has one run per round count; `tournament_rounds` defaults to 20 since 9 Oct 2026, chosen from these runs.

- First seed: at equal compute, `rounds20`'s checkpoint champions won more benchmark games against AmiGo, MichiWeak and MichiMid than `even-bigger2`'s at every checkpoint after generation 0; against AmiGo, 56–57 of 100 from `rounds20`'s generation 100 on against 34–39 from `even-bigger2`'s generation 200 on.
  The whole gap opened in the first 100 generations, which one lucky early lineage could also explain.
- Second seed, wins of 300 against the same three bots: the 10-round run led at about 20 summed hours; from about 36 h on the 20-round run led at every equal-compute point (101 against 67 at 36–42 h, 102 against 83 at 52–55 h).
  The 40-round run trailed the 20-round run at equal compute and, from generation 200 on, at equal generations (78 against 101 at generation 200, 94 against 114 at 500); it led only at generation 100 (75 against 51), at twice the cost.
- `weight_step`'s median fell from 0.5 to 0.018 in `seed2-rounds10`, 0.006 in `seed2-rounds20` and 0.0004 in `seed2-rounds40` by generation 500.
- Whether the round count caused these differences: cannot tell, with one run per round count and seed.
  Two runs of 20 rounds with different seeds, `rounds20` and `seed2-rounds20`, differ by +70, +19 and +26 wins of 300 at checkpoints 100, 200 and 300 (which also include another draw of benchmark openings and bot seeds; [Elitism](#elitism-elite_share)).

Source: each experiment's own `stats` (first seed 2 Oct 2026, second seed 9 Oct 2026) and the summed `games.duration`; no script.

## How often tournament games repeat

Question: how many of a generation's tournament games repeat another game of that generation move for move ([Analysis scripts](analysis-scripts.md#how-often-tournament-games-repeat) defines clone repeats and rematches)?
Runs: `seed2-rounds10`, `seed2-rounds20` and `seed2-rounds40` (self-adaptive genes; 10, 20 and 40 rounds) and `seed2-meta0` and `seed2-meta0-step015` (fixed genes, 20 rounds; [Fixed mutation genes](#fixed-mutation-genes-meta_rate-0)), at generations 100–500; one run per setting.

- Clone repeats among the network games at generations 100, 200, 300, 400 and 500: `seed2-rounds10` 0.7, 0.3, 0.6, 2.5 and 0.9 %; `seed2-rounds20` 0.3, 0.0, 2.7, 11.6 and 16.7 %; `seed2-rounds40` 1.9, 7.0, 19.8, 22.4 and 35.8 %; `seed2-meta0` 0.0 % up to generation 300, then 1.8 and 0.3 %; `seed2-meta0-step015` at most 3 clone repeats at any checkpoint.
- Against AmiGo at generation 500, clone repeats are 3.1, 19.7, 35.0, 1.6 and 0.0 % of the games, in the same order of runs.
- Rematches: 0.1–0.2 % of the network games with 10 rounds, 0.5–0.8 % in all three 20-round runs, 1.5–1.8 % with 40.
- Whether the genes or the rounds cause these differences: cannot tell, with one run per setting.
  Runs with different rounds are not directly comparable either: the clone-repeat share can grow with the rounds counted, since two clones repeat a game only when they meet the same opponent with the same colour.

Source: `mise exec -- scripts/game-repeats.rb experiments/NAME/experiment.sqlite3 100 200 300 400 500` for each run, at f2e6717 (14 Oct 2026).

## Fixed mutation genes (`meta_rate` 0)

Questions: does the self-adaptive genes' shrinking limit progress (`docs/literature.md`, "Short answer" and "Ranked experiments")?
Does the share of mutation children that score at least as well as their parent tell whether a step is too big?
Runs: `seed2-rounds20` (self-adaptive, `meta_rate` 0.2), `seed2-meta0` (`meta_rate` 0 with the default genes: `weight_step` 0.5, 229 weight changes, `copy_chance` 0.01, `activation_rate` and `structure_rate` 0.02) and `seed2-meta0-step015` (the same with `initial_weight_step` 0.15), with every other setting and the seed the same, so all three share generation 0; one run per setting, the fixed ones to about generation 570.
`seed2-meta0-b`, a second run of `seed2-meta0`'s setting, is under [Elitism](#elitism-elite_share).

These figures predate the rule that analysis figures come from a reviewed script (`CLAUDE.md`): they came from one-off queries, re-checked by four review rounds in #119, which the owner shipped as is (14 Oct 2026).
A later change to them goes through a script.

- Whether the shrinking limits progress: cannot tell, with one run per setting.
  The checkpoint champions' benchmark wins of 300 against AmiGo, MichiWeak and MichiMid at generations 100–500: `seed2-rounds20` 51, 101, 102, 109 and 114; `seed2-meta0` 73, 102, 93, 81 and 77; `seed2-meta0-step015` 56, 61, 58, 83 and 80.
- The share of networks scoring above the AmiGo copies' mean tournament score, averaged over generations 151–200, 251–300, 351–400 and 451–500: `seed2-rounds20` 11, 32, 41 and 40 %; `seed2-meta0` 6, 15, 22 and 23 %; `seed2-meta0-step015` 5, 5, 6 and 9 %.
  Per 25 generations, `seed2-meta0`'s was 29.8 % at 401–425, 15.4 % at 526–550 and 8.4 % at 551–575, and `seed2-meta0-step015`'s 7.0, 11.0 and 9.5 % (to 570).
- `seed2-rounds20` made 2,096, 6,483 and 8,717 shape changes in generations 201–300, 301–400 and 401–500, against 1,340–1,750 per 100 generations in the fixed runs, while its per-generation mean `weight_step` was 0.0035–0.019 over generations 401–500; whether the shapes kept it improving is not measured.
- The share of mutation children that score at least as well as their parent cannot tell whether a step is too big: it is 30.5–31.6 % per 100 generations in all three runs, about the same as for exact copies (30–38 %), whose play is unchanged, so it measures how far a parent's lucky score regresses.
  Strictly better than their parent's score of the generation before are 18–21 % of copies and 18–19 % of mutation children in each run.
- Interpretation: whether step 0.5 is too big is open; it may be too big without elitism.

Source: each experiment's own `stats` fit for the champions (14 Oct 2026) and the one-off queries of #119; no script.

## How brittle a champion is

Questions: do mutations at steps up to 0.5 cost a late champion strength on average, does any step still give a detectably better child, can the steps be told apart, and how much of a champion's play do they change?
Runs: the checkpoint champions of `seed2-rounds20` and `seed2-meta0` at generations 300 and 500 (one seed), each with 32 children a step at 229 weight changes of 0.005, 0.02, 0.1 and 0.5 and at its own genes (`own`, which for `seed2-meta0` is the 0.5 step), and 4 controls a step for the re-test levels.

- No detectable average loss at any step, on any of the four champions: every step's mean screen difference (−3.47 to +5.31 wins of 300) is within one SE of 0; with SEs of up to 6.67 wins of 300, losses of a few points are not excluded.
- No re-tested best child was called better at any step of any champion (the smallest P 0.1051).
  The size found with 80 % power is 5.9–7.7 points for `seed2-rounds20`'s fixed steps, 4.6 and 3.4 at `own`, and 2.1–8.1 for `seed2-meta0` (none at steps 0.005 and 0.02 of its generation-500 champion, whose children almost never play differently); only each step's 4 best children of 32 on the screen were tested for improvement, and the screen did not detectably predict the re-test.
- No step can be told from another: no pair of steps differs by two SEs.
- At steps 0.005, 0.02, 0.1 and 0.5, 98, 93, 72 and 32 % of the games of `seed2-meta0`'s generation-500 champion's children are identical to its own (78, 42, 8 and 2 % at generation 300); for the self-adaptive champions, 21 % (generation 300) and 16 % (500) at step 0.005, and 39 % and 72 % at `own`.
- A faint hint, not significant on its own: on the fresh re-test games, `seed2-rounds20` generation 500's controls trail the champion at every fixed step (−8.25 ± 7.70, −6.75 ± 8.59, −14.50 ± 8.40, −11.00 ± 9.75 wins of 600), each within two SEs of 0, while on the benchmark openings the same steps' children are ahead (+2.38 to +5.31 of 300); the four steps share the champion's re-test games, so they are not four independent signs, and `seed2-meta0` generation 300's controls are also all below 0 (−2.00 to −7.00).
  A small loss of children on fresh games cannot be ruled out.
- Interpretation: the step-0.5 lineage may have evolved robustness to the mutation it gets (`docs/literature.md`, "Ranked experiments", experiment 1, expects this under fixed genes), while the self-adaptive champions' move scores may be close enough that a small change flips moves; neither shows a detectable average loss, so they are sensitive rather than, as far as this test can tell, brittle.

Source: `scripts/brittleness.rb` at ec7a7a0, run by the owner on `seed2-rounds20 300 500` and `seed2-meta0 300 500` at the default options with `--out experiments/brittleness` (finished 15 Oct 2026), and its `--report-only` report; no game failed, and every replay reproduced all 300 of its champion's stored benchmark games.

## Elitism (`elite_share`)

Questions:

1. The 16 Oct hypothesis (`docs/literature.md`, "Ranked experiments", experiment 2): with elitism, do `weight_step` and `copy_chance` shrink less at `meta_rate` 0.2, and is the plateau higher at `meta_rate` 0?
2. Step 0.5's rise and fall ([Fixed mutation genes](#fixed-mutation-genes-meta_rate-0)): does elitism change it?
3. Do elites and exact clones keep their score in the next tournament?
4. Did a checkpoint champion play the benchmark against its own genome (owner, 19 Oct 2026)?

Runs: six, to generation 1000 (finished between 24 Oct and 12 Nov 2026), all with `seed2-rounds20`'s seed and other settings (9×9, 1,000 networks starting at 10 hidden layers of 200, 20 rounds), one run per setting (`elite_share`, `meta_rate`, `initial_copy_chance`): `seed2-elite` (0.01, 0.2, 0.01), `seed2-elite-meta0` (0.01, 0, 0.01), `seed2-elite-nocopy` (0.01, 0.2, 0), `seed2-elite-meta0-nocopy` (0.01, 0, 0), `seed2-rounds20-b` (0, 0.2, 0.01) and `seed2-meta0-b` (0, 0, 0.01).
They share generation 0's ranking and champion and are separate runs from generation 1 on; `seed2-rounds20-b` and `seed2-rounds20` never differ over generations 0–500.
Two runs of one setting, both without elitism: `seed2-meta0` and `seed2-meta0-b` (`meta_rate` 0, the same seed, diverging at generation 33; both reach generation 576) and `rounds20` and `seed2-rounds20` (`meta_rate` 0.2, other seeds; both reach generation 302).
The runs predate #132, so their GNU Go is the unpinned one.

1. **Cannot tell**, with one run per setting; telling it needs more seeds of each setting.
   Nor can the outputs separate a setting's effect on the `meta_rate` 0.2 gene trajectories from the spread between runs of one setting: the only pair at 0.2, `rounds20` and `seed2-rounds20`, reaches generation 302.
2. **Cannot tell**, with one run of each elitist setting at `meta_rate` 0.
3. In every window, the elites of the four elite runs and the exact clones of every run scored less on average in the next tournament than they or their parent had in the one that chose them.
   The outputs cannot tell how much of either fall is a stronger next field and how much a lucky score that selection picked, since the two tournaments have different fields.
4. No: in none of the runs did a checkpoint champion have the genome of a network it was benchmarked against, and no checkpoint champion of any run was an elite.

Source: these commands from the repository root, all scripts at their defaults: `scripts/compare-runs.rb`, `scripts/gene-trajectories.rb` and `scripts/population-strength.rb` at 7e4b5a6, `scripts/game-repeats.rb` at 5be3d2b.
Each run's champions, gene medians, population against the bots, clones, repeats and elites, with the one-setting pairs' figures to set beside them, are in their outputs.

    for script in compare-runs gene-trajectories population-strength; do
      mise exec -- scripts/$script.rb experiments/{seed2-elite,seed2-elite-meta0,seed2-elite-nocopy,seed2-elite-meta0-nocopy,seed2-rounds20-b,seed2-meta0-b}/experiment.sqlite3
      mise exec -- scripts/$script.rb experiments/{seed2-meta0,seed2-meta0-b}/experiment.sqlite3
      mise exec -- scripts/$script.rb experiments/{rounds20,seed2-rounds20}/experiment.sqlite3
    done
    mise exec -- scripts/compare-runs.rb experiments/{seed2-rounds20,seed2-rounds20-b}/experiment.sqlite3
    for run in seed2-elite seed2-elite-meta0 seed2-elite-nocopy seed2-elite-meta0-nocopy seed2-rounds20-b seed2-meta0-b; do
      mise exec -- scripts/game-repeats.rb experiments/$run/experiment.sqlite3 100 300 500 700 1000
      mise exec -- scripts/game-repeats.rb --without-elites experiments/$run/experiment.sqlite3 100 300 500 700 1000
    done
    mise exec -- scripts/game-repeats.rb experiments/seed2-meta0/experiment.sqlite3 100 300 500
    mise exec -- scripts/game-repeats.rb experiments/rounds20/experiment.sqlite3 100 200 300
    mise exec -- scripts/game-repeats.rb experiments/seed2-rounds20/experiment.sqlite3 100 200 300
