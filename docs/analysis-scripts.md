# Analysis scripts

What each analysis script in `scripts/` prints, how to run it, and how to read its output; how runs, their storage and `stats` work is in [Experiment reference](experiment-reference.md).

- [How noisy the tournament's ranking is](#how-noisy-the-tournaments-ranking-is)
- [How often tournament games repeat](#how-often-tournament-games-repeat)
- [Gene trajectories and clones](#gene-trajectories-and-clones)
- [Population strength and elites](#population-strength-and-elites)
- [How brittle a champion is](#how-brittle-a-champion-is)
- [Comparing runs' champions](#comparing-runs-champions)

## How noisy the tournament's ranking is

`scripts/ranking-noise.rb` measures, from an experiment's recorded games alone (read-only), how much of a generation's ranking is skill and how much luck.

    mise exec -- scripts/ranking-noise.rb experiments/NAME/experiment.sqlite3 GEN...

It prints one row per generation (its header comment has the details):

- **Games**, **Networks**: the generation's tournament games and networks.
- **White wins**: White's share of the wins.
- **Colour r²**: how much of the spread in the networks' win counts their number of games as White explains.
- **Odd/even Spearman**: how alike the benchmark's rating fit (`BenchmarkRatings`) on the odd rounds and one on the even rounds rank the networks.
  Odd against even, not first half against second, so each half holds early and late rounds alike.
- **Reliability, R, 2R and 4R rounds** (R the rounds played): the reliability of a rating from the whole tournament, and from twice and four times as many rounds, from the odd/even agreement by Spearman–Brown.
  The projection assumes added rounds are like the ones played; under the Swiss pairing, later rounds pair closer scores.
- **Wins vs rating**: how well the win count, which parent selection uses, agrees with a rating fit on all the games (Spearman).
- **Top 50 in common**: how many of the stored ranking's top 50, its ties shuffled as selection sees them, the fit also puts in its top 50.

The reliabilities are the rating fit's.
The win count's own cannot be measured by splitting: under the Swiss pairing a network that won in one half meets harder opponents in the other, so the halves' win counts correlate slightly negatively whatever the skill.

## How often tournament games repeat

A network always plays its best move, so two networks that move alike play the same game.
`scripts/game-repeats.rb` counts, from an experiment's recorded games alone (read-only), how many of a generation's tournament games repeat another game of that generation move for move.
Only the generations that keep their SGFs (every `keep_every`-th) can be counted; it refuses any other.

    mise exec -- scripts/game-repeats.rb [--without-elites] experiments/NAME/experiment.sqlite3 GEN...

It prints one Markdown table per generation, one row per kind of game: network against network, against each bot (in the order of the `opponents` table), and bot against bot.
How to read it:

- A game's move sequence is its SGF from Black's first move on (`substr(sgf, instr(sgf, ';B['))`), and its pairing is (Black, White), a bot's copies counted as the bot itself through `players.opponent` (AmiGo2 is AmiGo).
- The games with one move sequence form a group.
  The first in (round, black, white) order, the `games` key, is the original; of a group of n games with p distinct pairings, the other n − 1 add no new game: p − 1 are **clone repeats** (another pairing played the same game, so those networks move alike) and n − p are **rematches** (a pairing met again and replayed its game).
- Each game counts in its own kind's row, also in a group of several kinds (a network's game against another network identical to one against AmiGo).
- **No moves** counts games without a move (a bot that resigned at once); they are no one's repeat.
- The shares are of the row's games.
  Clone repeats measure how alike the population plays at a given number of rounds; the share can grow with the rounds counted, since two clones repeat a game only when they meet the same opponent with the same colour, and more rounds give them more chances.
  Rematches depend on the rounds and the pairing; among the network rows their share is mostly highest against AmiGo and Brown, where a network meets another copy of the bot with the same colour.
  michi and GNU Go vary through their per-game seeds, so their rows stay near 0.

`--without-elites` leaves out every game in which an elite of the generation plays (its `births` with `operator` `elite`), against a network, a bot or another elite, so the bred networks' repeats can be set beside those of a run without elitism.
The games left out count as if they had not been played: the groups are formed from the other games alone, so a group whose first game an elite played gets its first remaining game as original (a bred network's game that repeats only elites' games counts as an original), and a kind of game none of whose games remains gets no row.
Each table's first line gives the games counted, the generation's games, those left out, and its number of elites, or says that it has none (a run without elitism, or generation 0, whose births are all `initial`).
Elites are told from `births`, never from `elite_share`, so a database without that setting works too; a generation without `births` is refused, since its elites cannot be told.

## Gene trajectories and clones

`scripts/gene-trajectories.rb` describes, from every generation's births alone (read-only, so a run may still be running), how each run's mutation genes, shapes and clones moved.
It describes; it prints no test or p-value.
A run is named after its database's directory; it reads schema 17 databases as well as later ones and tells elites by their birth's operator `elite`, never by `elite_share`.

    mise exec -- scripts/gene-trajectories.rb [--window W] experiments/NAME/experiment.sqlite3...

It leaves out every generation whose tournament did not finish (`generations.round` below `tournament_rounds`) and names them at the top, with each run's elite count.
Generation 0 is a row of its own, then windows of W generations (default 50: 1–50, 51–100, …); a run's last window can hold fewer, and every row says how many generations it holds.
It prints, as Markdown tables, per run and window:

- **Genes.** For each of `copy_chance`, `weight_changes`, `weight_step`, `activation_rate`, `structure_rate` and `feature_step`: the median of the per-generation medians, the 10th and 90th percentiles over the window's networks (nearest rank), and the share within 1 % of a clamp of `lib/ann.h` (at most 1.01 times `ANN_*_MIN`, at least 0.99 times `ANN_*_MAX`; `weight_changes` has no fixed maximum, its limit being the network's own weight count, so only its minimum is counted).
  A `copy_chance` of exactly 0 (`initial_copy_chance` 0) lies below the clamp range and has a column of its own.
  Three populations: all networks (as `stats` counts genes), the bred children (elites left out), and the elites alone.
  In runs made before `evolve` kept the chances exact at `meta_rate` 0 (every run to 12 Nov 2026), the fixed genes differ in their last bits (generation 0 stores `copy_chance` 0.01, bred births 0.010000000000000002); nothing in the script relies on them being equal.
  Values print to 3 significant figures, from 100 on as whole numbers.
- **Structural changes and shapes**: the bred children, those whose `structure` is set and not `none`, and the distinct shapes (hidden layers by width) among all networks.
- **Clones**: copies (`operator` `copy`), self-crossovers (`first_parent` = `second_parent`), crossovers whose differs count against the picked parent (the column `parent` names) is 0, crossovers whose `genome` equals either parent's, and the exact clones, copies plus the last.
  The three crossover columns nest (a crossover can also have the genome of the parent not picked), so they are never added; the report counts the crossovers outside that nesting.
- **No network weight changed**, apart from the clones: mutation children whose differs count against their picked parent is 0, with no structural or activation change, and the median and maximum of each one's largest feature-weight change against that parent (`fw_*`).
  The report labels them "no network weight changed; feature weights and genes may differ from the parent's; whether they play like the parent is not measured", and keeps them out of any clone or not-clone count.
  `stats`' Copies column counts them.

## Population strength and elites

`scripts/population-strength.rb` describes, from every generation's births and final ranking (read-only), how strong each run's population was against the bots, what became of its elites, and how far the scores of networks that play two tournaments unchanged move.
It describes; it prints no test or p-value.
Run names, schema 17 databases, elites (births with `operator` `elite`), unfinished generations and windows are as for `scripts/gene-trajectories.rb` above.

    mise exec -- scripts/population-strength.rb [--window W] experiments/NAME/experiment.sqlite3...

It prints, as Markdown tables, per run and window:

- **Population against the bots.** The share of networks whose tournament score is strictly above the mean score of the AmiGo copies (the bot players whose `players.opponent` is `AmiGo`), and likewise for MichiWeak and MichiMid, for all networks, the bred networks (the initial population and the elites left out), and the elites alone.
  A generation without a copy of one of the three is refused.
- **Elites** (runs with elites).
  In the tournament they are carried into: their rank percentile among the generation's networks by stored rank (0 the first, 1 the last; bots left out), mean and median; and the longest chain of generations one network was carried in a row, up to the window (it can begin in an earlier window).
  Of the elites whose next generation is kept: the share carried again (Stay elite), and their mean number of bred children in the next generation, against the same mean for the generation's networks among its first 10 % by stored rank (`Elitism`'s rounding of 0.1 times the networks) that are not elites.
  Children are counted as `ExperimentStats#parents` counts them: a crossover for each of its two distinct parents, a mutation or copy only for the parent it used.
- **Score retest.** The elites, and the exact clones (copies, and crossovers whose `genome` equals a parent's), against the score in the generation before of the parent whose genome they equal (the parent they used when both have it): how many, the mean scores before and after, the mean change, and for the exact clones the Pearson correlation.
  Both compare two tournaments against different fields, so neither is a reliability coefficient of one tournament; the report says so.

## How brittle a champion is

`scripts/brittleness.rb` asks whether larger weight steps can still improve a late champion, and how much a champion's play changes when only its dense weights change.
It makes children of a stored checkpoint champion that differ from it only in their network weights and plays them on the champion's own benchmark games, so a child's result minus the champion's is the mutation's effect alone.
It reads the experiment (read-only, open while the experiment runs if need be) and writes only into its output directory.

    mise exec -- scripts/brittleness.rb seed2-rounds20 300 500 --out experiments/brittleness --concurrency 3
    mise exec -- scripts/brittleness.rb --report-only --out experiments/brittleness [EXPERIMENT [GEN...]]

`experiments/` is gitignored, so the output directory does not show up as untracked files.

Options and their defaults: `--steps 0.005,0.02,0.1,0.5` (fixed weight steps, each with `--changes 229` weight changes), `--children 32` (a step), `--opponents AmiGo,MichiWeak,MichiMid` (bots of the benchmark panel), `--retest-games 600` (divisible by 2 × the opponents), `--concurrency 2` (games at once; it may change between resumes), and `--accept-failures` (below).
EXPERIMENT is a name under `experiments/` or a directory.

- **Players.** The champion is the checkpoint's benchmarked network (the first network of the generation's final ranking, from the `networks` table).
  Its children come from `evolve/perturb` (see `docs/code-reference.md`), one seed each, `Seeds.derive(seed, 'brittleness', NAME, GEN, STEP, k)`, at every fixed step and at `own`, the champion's own `weight_changes` and `weight_step` read from its `.ann`.
  `own` is left out when it equals a fixed step (the step within 1e-6 relative and the changes within 1 % of `--changes`), as for `seed2-meta0`'s fixed genes.
  A replay of the unchanged champion plays too.
  Every network runs the experiment's own `evo`, copied to `DIR/NAME/evo`.
- **Screen.** Every player plays every opponent on the checkpoint's benchmark openings with both colours, through the benchmark's command (`CheckpointBenchmark.game_command`) and with the benchmark game's seed, so each game pairs with a stored champion game.
  The replay must reproduce the stored games (winner, length, referee result); the report says when it does not, and that champion's results are then unreliable.
- **Re-test.** Once no child's screen game has a failure left (a failure counts as a loss, which would bias the choice; the replay's do not count, since the choice compares with the champion's stored games), per step the best ceil(children / 10) children by screen difference (ties: lower index) and as many controls drawn at random from the rest (seed `Seeds.derive(seed, 'brittleness-controls', NAME, GEN, STEP)`), with the champion, play `--retest-games` fresh games.
  Their openings come from `Seeds.derive(seed, 'brittleness-retest')` and their game seeds are `Seeds.gnugo(seed, 'brittleness-retest', GEN, OPPONENT, OPENING, COLOUR)`, the same for every player, so these games pair too; they are ordered by opening, then colour, then opponent.
  A child selected on the screen's luck would carry that luck into a re-test on the same games; fresh games do not.
  While a child's screen games have failed, that generation's re-test waits, and says so, while later generations of the run still play; a run of the same command replays them.
  If the same games keep failing (the programs are deterministic, so a crash can repeat), `--accept-failures` chooses the children with those games counted as losses; the report then says how many had failed.
  Once chosen, the children stay, and the option is not one of the options a directory keeps.
- **Results** go to `DIR/results.sqlite3`: `games` (one row per game, keyed by experiment, generation, phase, step, `weight_changes`, `weight_step`, child, opponent, opening and colour; `child` is `replay` under step `champion` for the champion; winner, failure, length, referee result, a hash of the moves, duration), `runs` (each generation's options and champion), `champion_games` (the stored benchmark games the replay is checked against), `children` (seed and changed weights), `selections` (the re-tested children), `selection_failures` (how many screen games had failed when they were chosen, 0 unless `--accept-failures`) and `version` (the layout; a directory an older script wrote is refused: use a new `--out`).
- **Resume.** The same command skips stored games and replays failure rows.
  A directory refuses other options for a generation it holds, and a second run on it while one runs.
  Ctrl-C stores nothing after it (exit 130); each start empties `DIR/NAME/work`, where the games run, so no game file or half-written child is left.
  A child's file is deleted once its games of the phase are stored and rebuilt from its seed for the re-test.

How to read the report.
Screen differences are wins of the screen's games (300 at the defaults), re-test differences wins of `--retest-games`, and every SE comes with its n children (a t interval on n − 1 degrees of freedom applies to a few).

- **Every child shares the champion's luck** on the same games, so neither SD/√n nor an independent-games formula is right.
  Each SE comes from the crossed formula of a two-way children × games table: for steps A and B on the same N games, Var(mean_A − mean_B) = s_TA²/n_A + s_TB²/n_B + N·max(0, var_g(ȳA_g − ȳB_g) − MSE_A/n_A − MSE_B/n_B), with s_T² the variance of the children's totals, ȳ_g a game's mean over the children and MSE the table's residual mean square; against the champion (one player) its two terms drop.
  Below two children it prints `n/a`, and a correlation below three (two points always give ±1).
- While a run plays, `--report-only` leaves a child out of the screen figures until its screen is complete, and out of the re-test summary until its re-test is, and names them; the replay is compared as far as it has played.
  A pair of games of which neither left an SGF counts as not identical.
- **Screen table**, per step: the mean difference (the step's champion-relative level), its SE, the observed SD of the children's differences, the share of a child's games identical move for move to the replay's, and the discordance (the share of games whose result differs from the champion's) per opponent.
  Beside it, the **independence approximation** of a null band: where a child as strong as the champion would land if its games were independent of the champion's.
  Children agree with the champion more than that, so the band is too wide; compare the observed SD.
- **Between steps**: each pair of steps' difference with its crossed SE, the main comparison.
- **Re-test**: a re-test game the champion's replay failed is left out of every child's comparison (counted as the champion's loss, it would give each child that won it a discordant win), and the report says how many; the same command replays it.
  A child's own failed re-test game counts as its loss until the same command replays it, which can only make it look worse, never call it better.
  Per re-tested child its screen and re-test difference and an exact one-sided sign test (McNemar) on the games where its result and the champion's differ, n_d of them, k won by the child: it is better when P(Bin(n_d, ½) ≥ k) ≤ 0.05 / m, m the champion's re-tested best children (Bonferroni; 20 with `own`, 16 without, at the defaults).
  Then per step the controls against the champion (a level that is unbiased only as far as the screen does not predict the re-test), the re-tested best minus the controls, and the correlation of screen and re-test differences.
- **Smallest detectable improvement** per step at 50 % and 80 % power, an estimate in percentage points of the re-test games: an effect δ makes the child win a discordant game with probability (1 + δ/d) / 2, d the step's screen discordance averaged over the opponents.
  A null result means that a re-tested best child better by at least the 80 %-power size would have been found with about 80 % probability; children not re-tested are judged only by the screen.

Cost at the defaults: a champion with `own` screens 161 players × 300 games and re-tests 41 players × 600 (48,300 and 24,600 games); one without, 129 and 33 (38,700 and 19,800).
At about 0.111 s of wall time per game at concurrency 3 on a machine doing other work, four such champions take an estimated 5.4 hours for the screen and 2.7 hours for the re-test.
A small pilot checks the setup first: `mise exec -- scripts/brittleness.rb seed2-rounds20 500 --children 2 --retest-games 60 --concurrency 2 --out DIR`.

## Comparing runs' champions

`scripts/compare-runs.rb` describes several runs side by side from their stored benchmark games, births and rankings alone (read-only, so a run may still be running).
It describes; it prints no test, p-value or interval for a difference.
A run is named after its database's directory.

    mise exec -- scripts/compare-runs.rb [--bots A,B,...] experiments/NAME/experiment.sqlite3...

It leaves out every generation whose tournament did not finish (`generations.round` below `tournament_rounds`) and names them at the top.
Then it prints, as Markdown tables:

- **Ratings from the games against the bots.** One `BenchmarkRatings` fit over every run's champion-against-bot games and the first run's bot-against-bot games, AmiGo rated 0.
  A bot is one player shared by name across the runs (refused unless every run stores the same command for it); each run's champions are players of their own (`RUN:GenN`).
  Games against `Gen0Champion` and `GenNChampion` are left out, since through them a champion's rating would depend on its run's later champions directly.
  Champions stay linked through the bots, which are rated from all given runs' champions, so a rating still moves with the other champions given, and ratings compare only within one invocation.
  Within one invocation, identical champions with identical games get identical ratings.
  A checkpoint missing some of its games against the bots is marked incomplete.
  It also says how many of the other runs' bot-against-bot games had another result than the first run's.
- **Wins against the `--bots`** (default AmiGo, MichiWeak, MichiMid), per checkpoint and run, with the 95 % half-width of the binomial spread of one champion's wins over another sample of openings and bot seeds (summed over the bots at the champion's own win rate against each).
  A checkpoint missing games is marked incomplete.
  For the default bots it adds that replaying the same games would not move the wins (the openings repeat, AmiGo plays deterministically, the michi levels repeat for their seed); a bot outside them, such as an unpinned GNU Go, need not replay alike.
  Per run, over the checkpoints of 500..1000 and of 200..1000: the mean wins, the least-squares slope in wins per 100 generations, and the residual standard deviation around the line, only for a run whose complete checkpoints cover the whole window.
- **Differences**, given exactly two runs: their wins and the difference per checkpoint both have complete.
- **Where the runs diverge**, per pair of runs over the finished generations both have: the first generation whose births differ (a child with another `genome`, or a child in one run only) and how many births the two still share there, the last generation with any shared birth, and the first generation whose rankings differ.
  `genome` hashes the network file, genes included, so runs with different stored genes share no birth even where their networks play alike.
- **Champions benchmarked against themselves**: per run, each checkpoint champion's operator, and the checkpoints whose champion has the same `genome` as a network it was benchmarked against.
