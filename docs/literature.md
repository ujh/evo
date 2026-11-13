# Literature: self-adaptation, noisy selection, elitism, and evolving game players

What the literature says about evo's breeding and selection: the mechanisms that explain its runs, the experiments it suggests in ranked order, and what it leaves open.
A review of 9 Oct 2026 and a follow-up on elitism of 15 Oct 2026 read the sources, and a second reader checked every claim against its source; claims that could not be checked carry "(not verified)".
The review's own arithmetic and simulation are labelled as such and are not published results.

The review studied runs with self-adaptive genes nudged by `meta_rate` 0.2 (`genes.md`), no elitism, tournament selection of size 3, 1,000 networks, and one-point crossover at rate 0.4.
In them the genes shrank: `weight_step`'s median fell from 0.5 to 0.018, 0.006 and 0.0004 by generation 500 in `seed2-rounds10`, `seed2-rounds20` and `seed2-rounds40` (`findings.md`, "10, 20 and 40 rounds", which cannot tell whether the round count caused the differences).
In `seed2-rounds20-b`, the same run as `seed2-rounds20` to generation 500, the median rose in some later windows and fell in others up to generation 1000 (same finding, every window).
"The owner's hypothesis": without elitism, lineages that make near-copies keep their fitness, so self-adaptation evolves a de-facto elitism and switches exploration off.

- [Short answer](#short-answer)
- [Why self-adaptation collapses](#why-self-adaptation-collapses)
- [Fixes for self-adaptation](#fixes-for-self-adaptation)
- [Noise: rounds and reliability](#noise-rounds-and-reliability)
- [Elitism](#elitism)
- [Large-scale neuroevolution compared with evo](#large-scale-neuroevolution-compared-with-evo)
- [Evolving Go and board-game players](#evolving-go-and-board-game-players)
- [Recommendations for evo](#recommendations-for-evo)
- [Open questions](#open-questions)
- [Reading list](#reading-list)

## Short answer

- **The collapse of self-adaptive rates is a known failure**: "loss of step-size control" (Liang, Yao & Newton 2001), "premature convergence of self-adapting mutation rates" (Glickman & Sycara 2000), "implicit elitism" (Kruisselbrink et al. 2011).
  In the two published setups closest to evo, a fixed rate clearly beat self-adaptation: Glickman & Sycara (2000: network weights, tournament selection, noisy fitness, no crossover) and Rand & Riolo (2005: population 1000, tournament size 3, generational, no elitism).
- **The owner's hypothesis is in the literature almost word for word**: with self-adaptation, robustness "can be trivially maximized when a genotype encodes that it should be subjected only to trivial perturbations" (Lehman et al. 2018b).
- **Evo lacks every condition that makes self-adaptation safe** (Beyer & Schwefel 2002; Hansen, Arnold & Auger 2015): recombination of the strategy genes (evo never averages genes), a surplus of children with extinctive selection (evo makes 1,000 children from 1,000 parents), a learning rate of about 1/√n (evo's 0.2 against about 0.001–0.05), and μ ≥ 1.25n parents (evo has 1,000 for about 500k weights).
- **A fixed step will probably plateau too**, at a "final localization error" that grows with the step (Beyer & Schwefel 2002), so judge fixed genes on plateau height, not only on when the plateau starts.
  Other causes of a plateau: opponents already beaten or out of reach (Lubberts & Miikkulainen 2001; Perez-Bergquist 2001), picking the move directly (Lucas & Kendall 2006), and weight mutation in very large networks (Szubert, Jaśkowski & Krawiec 2013).
- **Large-scale neuroevolution keeps the step fixed, keeps a small re-tested elite, selects strongly and uses no crossover** (Such et al. 2017; Salimans et al. 2017).
- **Every successful game evolver the review read kept good parents alive**, and under noise an elite must earn a fresh score every generation (Arnold & Beyer 2000a; Real et al. 2019).
  Rosin & Belew (1997): "Elitism is important… If it is not used, an optimal individual may be found and then lost."
- **One Swiss tournament is weak at finding the best networks**, and evo's split-half reliabilities may be artefacts of the pairing ([Noise: rounds and reliability](#noise-rounds-and-reliability)).

## Why self-adaptation collapses

Each network carries its own mutation size σ, nudged as σ′ = σ·exp(τ·N(0,1)) with τ = `meta_rate`, and selection should carry good σ along with good weights (Beyer & Schwefel 2002).
But a σ is judged only by its child's fitness in one generation, a selection Hansen & Ostermeier (2001) call "highly disturbed".

1. **Selection rewards safe children, not productive ones.**
   A size-3 tournament on noisy scores mostly asks who kept a good rank, which a near-copy almost always does, not who made a rare big gain.
   Beyer & Schwefel (2002): self-adaptation needs λ/μ ≥ 1/P_success, "otherwise, smaller mean step-sizes with higher success probabilities are preferred"; evo's λ/μ is 1.
   Most mutations of a good network make it worse, so credit by the average child pushes rates down (Clune et al. 2008; Kumar et al. 2022).
2. **Noise without gene recombination makes a random walk that drifts down** (Hansen, Arnold & Auger 2015; Meyer-Nieberg 2007).
   Classic ES counter it by averaging σ over parents; evo's children take one parent's genes, the (1,λ) case that "loses step-size control" under noise (Meyer-Nieberg 2007).
3. **The learning rate is large.**
   Recommended τ is about 1/√(2N), or 1/√(2√N) per weight (Beyer & Schwefel 2002): by the review's arithmetic about 0.001 or 0.027 for ~500k weights, 0.047 for the ~229 changed per child, so evo's 0.2 is 4 to 200 times above.
   Under noise a larger τ makes σ fall faster (Meyer-Nieberg 2007).
4. **Near-copies act as elitism** ("implicit elitism", Kruisselbrink et al. 2011), and `copy_chance` is an evolvable version of it.
   Given the choice of rate 0.2 or 0, Glickman & Sycara's (2000) population chose 0.
5. **Brittle networks and low rates reinforce each other.**
   Networks from self-adaptive runs were "mutation-brittle": they made equal-or-better children much less often than equally fit networks from fixed-rate runs (Glickman & Sycara 2000).

In Clune et al. (2008) a non-mutating lineage drove the best-rate lineage extinct in 50 of 50 runs.
Theory proves self-adaptation can beat any fixed rate only with λ/μ ≥ 4, a hard floor, ties broken toward the higher rate, an upward bias, and noise-free fitness (Case & Lehre 2020).

## Fixes for self-adaptation

| Fix | Source | Caveat |
|---|---|---|
| Drop self-adaptation (fixed step) | Glickman & Sycara 2000; Rand & Riolo 2005; Such et al. 2017 | A fixed step stalls at a step-dependent floor |
| Recombine the strategy genes | Beyer & Schwefel 2002; Meyer-Nieberg 2007 | Only the **arithmetic** mean biases σ upward |
| Small upward bias in the nudge | Meyer-Nieberg 2007 (β = 0.005–0.02 for τ = 0.1–0.5) | β must match τ, or σ diverges |
| Smaller τ | Beyer & Schwefel 2002 | Changes only the speed (Clune et al. 2008; Glickman & Sycara 2000) |
| Dynamic or offset floor (step = floor + evolved step) | Liang, Yao & Newton 2001; Kruisselbrink et al. 2011 | Hard clamps make the rate "hover" just above the bound |
| Some children with fixed default genes | Rudolph 2001 | Shown for a (1+1) algorithm only |
| One shared step by the 1/5 success rule | Hansen, Arnold & Auger 2015; Kumar et al. 2022 | Not with evo's tournament scores as the measure: copies beat their parent about as often as mutation children (`findings.md`, "Fixed mutation genes") |
| Raise σ when re-played rankings are noisy (UH-CMA-ES) | Hansen et al. 2009 | The opposite of what evo's genes do |
| Elitism | Kruisselbrink et al. 2011; Lehman et al. 2018b | A fit parent with a bad rate can block progress (Doerr, Witt & Yang 2018) |

Example: parents with `weight_step` 0.02 and 0.5 give a child 0.02 or 0.5 today; their geometric mean is about 0.1, with no upward bias under random selection; their arithmetic mean is 0.26, the upward-biased choice the ES theory relies on.

## Noise: rounds and reliability

- **Noise scales the selection response by √r**, r the share of fitness variance that is real (Miller & Goldberg 1995).
  Our arithmetic, taking evo's reliability estimates at face value: tournament 3 gives about 0.60 per generation at 10 rounds and 0.69 at 20, tournament 4 about 0.73 at 10, so a larger tournament would buy more than doubling the rounds.
- **Convergence makes noise worse**: as the population becomes near-copies, real variance shrinks and selection becomes nearly random (Miller & Goldberg 1995).
- **Less accurate evaluation can be better**: "one should not reduce noise further than necessary" (Branke & Schmidt 2003); for games, resampling helped small populations but not large ones (Darwen & Pollack 1999, via Jin & Branke 2005).
- **If less noise gives a deeper collapse** (one run per round count cannot tell: `findings.md`, "10, 20 and 40 rounds"), the drift barrier would explain it: rates fall until a further cut is worth less than drift, and noisy ranking acts like a smaller population (Lynch 2011; LaBar & Adami 2017).
  The step-size theories predict the opposite (Meyer-Nieberg 2007; Qin 2024).
  Any round comparison under self-adaptation is confounded with the gene collapse.
- **Rounds as a schedule.** Pollack & Blair (1998) found that comparing two close players needs "dozens or even hundreds of games"; raising the games required on a fixed schedule failed in 9 of 10 runs, raising it when the challengers' success rate passed 15 % worked in 10 of 10.
  This fits the owner's preference for more rounds: let a measured statistic decide when to add them.
- **Swiss tournaments rank the whole field well but pick the single winner no better than knockout** (Sziklai, Biró & Csató 2022); "even with as many as 16 games per player, the inferred ranks are still substantially different from the true ranks" (Glickman & Jensen 2005).

A simulation made for the review (not published; the script was not kept) had 1,000 players with Bradley-Terry strengths, Swiss pairing by score, White advantage and an evo-style rating fit, but no bots or draws:

| Rounds | Split-half reliability, all players equally strong | True top 10 recovered | True top 50 recovered |
|---|---|---|---|
| 10 | 0.56 | 2 | 13 |
| 20 | 0.71 | 2 | 20 |
| 40 | 0.79 | 4 | 23 |

Swiss pairs on total score, so each half's opponents depend on the other half's results, which the split-half method assumes away (Christenfeld 1996).
The reliabilities in `findings.md`, "How noisy the tournament's ranking is", may therefore be artefacts of the pairing; the test-retest replay (step 0a) is the check.

## Elitism

- **Why.** "Without parameter control… elitist strategies always converge to the essential global optimum, however at a much slower rate"; non-elitist ones only "with mutation variances bounded away from zero" (Hansen, Arnold & Auger 2015).
  With the best network surviving on its own, its lineage no longer needs near-copies, so the collapse should weaken (Kruisselbrink et al. 2011), though the pull toward less variation may remain (Altenberg, Liberman & Feldman 2017), so pair elitism with a floor or a fixed step.
- **Risks under noise.**
  A survivor that keeps its old noisy score causes "systematic overvaluation" and stagnation (Arnold & Beyer 2000a); "lucky models" can dominate reproduction (Real et al. 2019).
  Elitism "can cause premature convergence if not kept in check: perhaps by increasing the mutation and crossover noise, or weakening the selection pressure, or reducing how many elites are being stored" (Luke 2013).
  A fit parent with a bad self-adapted rate can block progress for a long time (Doerr, Witt & Yang 2018).
  Re-evaluation is not automatically better: Antipov & Doerr (2025) found re-evaluations "can be highly detrimental" in a (1+1) EA on LeadingOnes under constant noise rates.
- **Stale scores.** Evo at `elite_share` 0 lives one generation per network, the extreme of aging evolution (Real et al. 2019; our inference); `elite_share` (#126) elites play the next Swiss tournament and are scored on it alone, so they never keep a stale score.
  Ranking an elite on its mean over every tournament since the one that selected it would keep earlier evidence (Fieldsend 2015, abstract only), but also that likely lucky tournament at weight 1/k after k tournaments, and games against older populations; no source tested a setting like evo's.
- **Local optima.** On some multimodal problems the elitist (μ+λ) EA "gets trapped on a local optimum" while a non-elitist EA with 3-tournament selection escapes, given a mutation rate below the error threshold (Dang, Eremeev & Lehre 2021).
  Whether evo's mutation is below it is open (`findings.md`, "Fixed mutation genes": step 0.5 "may be too big without elitism"); a few elites with every parent still drawn by size-3 tournament is not (μ+λ) truncation (our inference).
- **Diversity.** The Field Guide's first remedy for premature convergence is "Not using the reproduction operator", and it suggests watching behaviour: "Measuring phenotypic variation (i.e., diversity of behaviour) may also be useful" (Poli, Langdon & McPhee 2008).
  For evo, `copy_chance` is a reproduction operator and the clone-repeat share (`analysis-scripts.md`, "How often tournament games repeat") a behavioural measure (our inference).
- **How many.** Counts in practice run from 0.1 % to about 4 % (Deep GA 1 in 1001; Rosin & Belew 1997, 20 in 1000; Hornby 2006, 3 per 100), so 1–2 % sits in the middle (our inference).
- **Choosing under noise.**
  The Deep GA's top 10 each play 30 extra episodes, and the best mean becomes the elite (Such et al. 2017).
  AlphaGo Zero's new player had to win "by a margin of > 55% (to avoid selecting on noise alone)" over 400 games (Silver et al. 2017a); AlphaZero dropped the gate (Silver et al. 2017b).
  Networks, Brown and AmiGo play deterministically, so an extra game tells something only with an opponent or opening the candidate has not met (our inference).
- **Against bots or within the tournament.** In Othello, random opponents drawn anew every generation (86.46 %) and two-population coevolution plus random opponents (86.44 %, "equally good") gave the best expected utility against random players (Jaśkowski et al. 2013); evo's mix of networks and a fixed set of strong bots is nearest to their one population plus random opponents (83.63 %).

## Large-scale neuroevolution compared with evo

- The Deep GA mutated **all** 4M+ weights with a fixed σ = 0.002 picked from 36 settings, in a population of 1000+1 with the top 20 as parents (Such et al. 2017).
  OpenAI's ES "did not see benefit from adapting σ" (Salimans et al. 2017).
- **No crossover**: none of the large-scale successes crossed weights (Such et al. 2017; Salimans et al. 2017; Lehman et al. 2018a).
  Averaging unrelated trained networks drops accuracy to chance (Uriot & Izzo 2020), while NEAT's aligned crossover helps (Stanley & Miikkulainen 2002); evo's one-point crossover may be harmless late in a run, when parents are close relatives, and harmful early.
- **Weight growth**: without decay evolved weights grew to mean absolute values of 3–105 (Pagliuca, Milano & Nolfi 2020), shrinking an absolute step relative to the weights; evo's initial ±0.5 is about four times Glorot & Bengio's (2010) bound of about 0.12 for its 200-wide layers (the review's arithmetic).

**Total mutation size.**
By the review's arithmetic, a child whose k weights each change by uniform ±s has the perturbation norm √(k·s²/3), against √(n·σ²) for dense Gaussian noise σ on n weights.
Evo's rows use the medians of a generation's `weight_changes` (k) and `weight_step` (s) from `births`, computed by the review on 9 Oct 2026, before the rule that such figures come from a reviewed script; each row is one run.

| Setting | Perturbation norm |
|---|---|
| Evo generation 0 (k = 229, s = 0.5) | ≈ 4.4, as dense σ ≈ 0.0059 on 550k weights |
| Deep GA, Atari (σ 0.002 on 4M) | ≈ 4 |
| `seed2-rounds10`, generation 500 | ≈ 0.049 |
| `rounds20` (seed 1), generation 303 (tiny step, 30k–250k weights) | ≈ 0.040 |
| `seed2-rounds20`, generation 500 | ≈ 0.011 |
| `seed2-rounds40`, generation 500 | ≈ 0.0028 |

Evo starts in the range that works at scale; these runs' medians ended about 90 to 1,500 times below it.
`rounds20` traded a tiny step for many changed weights, so a floor should apply to the **total norm**, not to `weight_step` alone (Salimans et al. 2017: what matters is the size of the whole perturbation).

## Evolving Go and board-game players

- SANE, with the same "highest legal output plays" design as evo, beat the weak 9×9 program Wally 75 % of the time after about 260 generations (Richards, Moriarty & Miikkulainen 1998).
- ESP never won more than 1.2 % against GnuGo at 9×9 and larger, which gave no gradient (Perez-Bergquist 2001); coevolution with a hall of fame beat gnugo on small boards in about 5–7 generations, while evolution *against* gnugo stopped improving once it won (Lubberts & Miikkulainen 2001).
- A TD-trained linear value function over local shapes reached a 9×9 CGOS rating of about +1070 to +1140 without deep search (Silver, Sutton & Müller 2007).
- **Architecture.** Networks that pick the move directly, as evo's do, are "typically harder to learn" than position evaluators (Lucas & Kendall 2006) and "generally not competitive" with them (Risi & Togelius 2015).

### What helped

- **Parent survival or averaging**: Blondie24's (15+15) selection, SANE's elite, NEAT's species champions.
- **Opponents near 50 %**: learning was fastest near even odds (Pollack & Blair 1998), so add random moves to a strong fixed opponent until the population has an even chance (Lucas & Kendall 2006).
- **Randomness against overfitting**: against fully deterministic Wally, SANE learned "tricks" and then lost even to random players; adding 10 % random moves to Wally fixed this (Richards, Moriarty & Miikkulainen 1998).
- **Archives**: a hall of fame of past champions as opponents sped coevolution (Lubberts & Miikkulainen 2001; Rosin & Belew 1997).
- **Paired games**: colours reversed with the same dice (Pollack & Blair 1998).

Watch for mediocre stable states and cycling (Pollack & Blair 1998), and for fitness against fixed opponents that overfits them (Szubert, Jaśkowski & Krawiec 2013).

## Recommendations for evo

Compare at **equal games played**, against the 20-round runs (`rounds20`, seed 1, and `seed2-rounds20`) unless stated, and add seeds where the budget allows, since two is thin (Poli, Langdon & McPhee 2008).

### Step 0: cheap measurements

- **0a. Test-retest reliability.** Replay one stored generation in an independent Swiss tournament at 10 and 20 rounds and correlate wins and fits, since the split-half estimates may be pairing artefacts.
- **0b. Neutral-drift control.** A few dozen generations with shuffled fitness, tracking the median log `weight_step`, to separate selection from drift.
  Our estimate: a lineage's log-step random walk has SD ≈ 0.2·√(0.6·500) ≈ 3.5 after 500 generations, the order of the observed falls (3.3 to 7 log units).
- **0c. Brittleness test.** Mutate late top networks 32–64 times at fixed steps up to 0.5, plus exact copies for the noise, against a fixed bot panel (Glickman & Sycara 2000); done: `findings.md`, "How brittle a champion is".
- **0d. Per-generation logging**: the perturbation norm √(k·s²/3); the share of mutation children scoring at least their parent; scores by operator (crossover, mutation, copy); per-bot win rates; weight RMS per layer and the share of saturated units; how often a child picks its parent's move on reference positions.

### Ranked experiments

**1. `meta_rate` 0 control (the owner's plan).**
- **Hypothesis:** fixed genes keep exploring, so benchmark strength keeps rising past generation 100–300, or plateaus higher.
- **Single change:** `meta_rate` 0.2 → 0; the genes stay at step 0.5, ~229 changes and the initial `copy_chance`.
- **Ran:** `seed2-meta0` and `seed2-meta0-step015` against `seed2-rounds20`, one run per setting; whether the shrinking limits progress: cannot tell, and the share of mutation children scoring at least as well as their parent cannot tell whether a step is too big (`findings.md`, "Fixed mutation genes").
- **Refinements:** judge on plateau height at 300–500 generations (Elena & Sanjuán 2008).
  Without elitism a large fixed step can exceed what the population can keep (Qin 2024; Case & Lehre 2020); a warning sign is the best networks' strength against fixed bots rising and then falling.
  Treat 0.5 as one point on a grid: an arm at step 0.15 separates "self-adaptation is harmful" from "0.5 is the wrong step".
  Expect robustness to evolve in the weights instead, with higher move margins and more neutral mutants (van Nimwegen et al. 1999; Wilke et al. 2001).

**2. Elitism, crossed with `meta_rate` (2×2).**
- **Hypothesis:** explicit elitism removes the advantage of near-copy lineages, so with `meta_rate` 0.2 the step and `copy_chance` collapse less, and with `meta_rate` 0 the plateau is higher.
- **Single change:** carry over E unchanged elites.
- **Ran:** four arms and two baselines, one run each, to generation 1000 (`findings.md`, "Elitism (`elite_share`)"); with one run per setting they cannot tell the hypothesis.
- **Refinements** (Such et al. 2017; Rosin & Belew 1997; Arnold & Beyer 2000a; Luke 2013):
  - 1–2 % elites (10–20 of 1,000), kept small;
  - elites play the next Swiss tournament like everyone else, so no score goes stale;
  - choose elites by extra colour-paired games for the top ~10–50 plus the current elites against the same fixed panel, by mean or paired difference (Chong et al. 2012), since one Swiss tournament mostly keeps lucky networks;
  - optionally, replace an elite only by a clearly better challenger, as AlphaGo Zero's 55 % of 400 games;
  - as a separate change, `copy_chance` 0 in elitist runs, since an exact copy then only duplicates an elite;
  - with `meta_rate` 0.2, add a floor or fixed-gene children, since an elite with collapsed genes can block exploration;
  - keep drawing every parent by size-3 tournament from the whole population (Dang, Eremeev & Lehre 2021);
  - decide whether an elite is ranked on its latest tournament or on its mean since the one that selected it.

**3. Fixed-gene share (if self-adaptation stays).**
10 % of mutation children use the default genes (0.5, ~229) whatever their parent's, so exploration cannot switch off (Rudolph 2001).

**4. Recombine the strategy genes.**
Every child's step-size genes are the **arithmetic mean** of two tournament winners' genes, then nudged (Beyer & Schwefel 2002).

**5. Population-level 1/5 success rule (replaces `weight_step` self-adaptation).**
A shared `weight_step`, raised when more than ~20 % of mutation children out-rank their parent's previous percentile and lowered otherwise, cannot be gamed by single lineages, but needs a success measure other than the tournament score (`findings.md`, "Fixed mutation genes").

**6. Upward-biased nudge, offset floor or smaller `meta_rate` (if self-adaptation stays), one at a time.**
A log-step nudge + β with β ≈ 0.01 (Meyer-Nieberg 2007), an offset floor on the total perturbation norm (Kruisselbrink et al. 2011), or `meta_rate` 0.05, expected only to slow the collapse (Clune et al. 2008; Glickman & Sycara 2000).

**7. Tournament size 5.**
Stronger selection may let riskier steps win (Beyer & Schwefel 2002; Qin 2024).
Low priority for stopping the collapse: Glickman & Sycara (2000) found stronger selection "negligible at best" at stopping their rates' convergence, though for the search itself tournament size mattered, effective only in a narrow band (about 10, in a population of 100).

**8. Crossover off.**
`cross_over_rate` 0.4 → 0 under `meta_rate` 0, against run 1, since one-point crossover of unaligned arrays may be destructive early and a second near-copy channel late (Such et al. 2017; Uriot & Izzo 2020).

**9. Heavy-tailed `weight_changes`, without genes.**
Under `meta_rate` 0, draw each child's number of changed weights α from Pr ∝ α^−1.5 on [1, N/2] (our arithmetic: mean about 400, median 2), for many near-copies and rare large jumps with no gene to collapse (Doerr et al. 2017).
This theory is proven only for elitist algorithms on bit strings.

**10. Fitness-side changes (later), each a single change.**
- Tuning bot randomness toward 20–80 % wins (Lucas & Kendall 2006; Pollack & Blair 1998).
- A hall of fame of past champions as Swiss opponents (Lubberts & Miikkulainen 2001).
- Move noise in training games (Richards, Moriarty & Miikkulainen 1998).
- An even number of rounds with balanced colours (Csató & Krumer 2024).
- A benchmark bot never used for fitness (Szubert, Jaśkowski & Krawiec 2013).
- A round schedule triggered by a measured statistic rather than by generation (Pollack & Blair 1998).

**Head starts for later**, each compared with a run without it (`CLAUDE.md`):
- sparse against dense mutation at equal norm (no source answers it);
- scoring the position after each candidate move instead of picking the move (Risi & Togelius 2015);
- a TD-trained seed refined by evolution (Kim, Choi & Cho 2007);
- local, weight-shared shape features (Silver, Sutton & Müller 2007).

## Open questions

1. **Which N sets τ for sparse mutation**, all ~500k weights or the ~229 changed?
2. **Does less noise give a deeper collapse, and why?** The direct test measures the share of non-worse children against step size at 10, 20 and 40 rounds.
3. **Cause or consequence?** In the E. coli long-term experiment, mutation rates fell *after* adaptive potential declined (Wielgoss et al. 2013), so the collapse may follow the plateau rather than cause it.
4. **Does elitism remove the drive toward near-copies or only weaken it?**
5. **How noisy and intransitive are Swiss win counts for 1,000 networks with bots, draws and colours?** The literature covers at most 256 players.
6. **Should elites be judged against fixed bots or within the network tournament, and on their latest tournament or their mean since selection?** No source tests either for a setting like evo's.

## Reading list

All twelve have free full texts.

1. Glickman & Sycara (2000), [*Reasons for Premature Convergence of Self-Adapting Mutation Rates*](https://publications.ri.cmu.edu/storage/publications/pub_files/pub2/glickman_matthew_2000_1/glickman_matthew_2000_1.pdf): the closest analogue to evo, with the brittleness test.
2. Hansen, Arnold & Auger (2015), [*Evolution Strategies*](http://www.cmap.polytechnique.fr/~nikolaus.hansen/es-overview-2015.pdf): self-adaptation, the 1/5 rule, noise, elitism.
3. Beyer & Schwefel (2002), [*Evolution strategies: A comprehensive introduction*](https://gwern.net/doc/reinforcement-learning/model-free/2002-beyer.pdf): learning rates, "opportunism", the λ/μ ≥ 1/P_s condition.
4. Such et al. (2017), [*Deep Neuroevolution*](https://arxiv.org/pdf/1712.06567): fixed σ, one re-evaluated elite, population 1000.
5. Rand & Riolo (2005), [*The Problem with a Self-Adaptive Mutation Rate in Some Environments*](https://gpbib.cs.ucl.ac.uk/gecco2005/docs/p1493.pdf): population 1000, tournament 3.
6. Meyer-Nieberg (2007), [*Self-Adaptation in Evolution Strategies*](https://eldorado.tu-dortmund.de/bitstream/2003/25073/1/phd.pdf): loss of step-size control under noise, recombination and bias remedies.
7. Clune et al. (2008), [*Natural Selection Fails to Optimize Mutation Rates for Long-Term Adaptation on Rugged Fitness Landscapes*](https://pmc.ncbi.nlm.nih.gov/articles/PMC2527516/).
8. Pollack & Blair (1998), [*Co-Evolution in the Successful Learning of Backgammon Strategy*](https://cgi.cse.unsw.edu.au/~blair/pubs/1998PollackBlairML.pdf): rise then plateau with near-identical players, adaptive evaluation.
9. Lehman, Chen, Clune & Stanley (2018b), [*ES Is More Than Just a Traditional Finite-Difference Approximator*](https://arxiv.org/pdf/1712.06568): states the owner's hypothesis.
10. Kruisselbrink et al. (2011), [*On the Log-Normal Self-Adaptation of the Mutation Rate in Binary Search Spaces*](https://groups.csail.mit.edu/EVO-DesignOpt/gecco2011Proceedings/proceedings/p893.pdf): clamps and implicit elitism.
11. Hansen et al. (2009), [*A Method for Handling Uncertainty in Evolutionary Optimization*](http://www.cmap.polytechnique.fr/~nikolaus.hansen/TEC2009.pdf): raise σ when rankings are noisy.
12. Luke (2013), [*Essentials of Metaheuristics*](https://cs.gmu.edu/~sean/book/metaheuristics/): elitism, coevolution, a practitioner's view of self-adaptation.
