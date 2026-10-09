# Literature: self-adaptation, noisy selection, elitism, and evolving game players

A literature review made on 9 Oct 2026, after the 500-generation runs of 10, 20 and 40 tournament rounds (`experiment-reference.md`, "10, 20 and 40 rounds") showed the self-adaptive mutation genes shrinking: `weight_step` from 0.5 to 0.018, 0.006 and 0.0004, further the less noisy the tournament. It describes evo as it was then: six self-adaptive genes nudged by `meta_rate` 0.2 (`genes.md`), no elitism, tournament selection of size 3, 1,000 networks, one-point crossover at rate 0.4. Only the 40-round run had clearly stopped improving; the 20-round run's champions still gained at generation 500.

Every claim was checked against its source by a second reader; claims that could not be checked carry "(not verified)". The review's own arithmetic and simulation are labelled as such and are not published results. "The owner's hypothesis" is the one in `PROJECT_NOTES.md`: without elitism, lineages that make near-copies keep their fitness, so self-adaptation evolves a de-facto elitism and switches exploration off.

---

## 1. Short answer

- **The collapse is a known failure, and it has names.** The literature calls it "loss of step-size control" (Liang, Yao & Newton 2001), "premature convergence of self-adapting mutation rates" (Glickman & Sycara 2000) and "implicit elitism" or "hidden plus strategy" (Kruisselbrink et al. 2011). Two published setups are close to evo, and in both a fixed mutation rate clearly beat self-adaptation:
  - Glickman & Sycara (2000): neural-network weights, tournament selection, noisy fitness, no crossover.
  - Rand & Riolo (2005): population 1000, tournament size 3, generational, no elitism.
- **The owner's hypothesis is stated almost word for word in the literature.** Lehman et al. (2018b): with self-adaptation, robustness "can be trivially maximized when a genotype encodes that it should be subjected only to trivial perturbations". Hansen & Ostermeier (2001) explain why. Self-adaptation maximises a child's chance of being selected, and that is not the same as maximising progress. This is "one reason for the often observed phenomenon that the global step size is adapted to be too small". PushGP explicitly forbids programs from simply copying themselves, to avoid catastrophic loss of diversity (Poli, Langdon & McPhee 2008).
- **Evo lacks every condition that makes self-adaptation safe.** The textbooks list four (Beyer & Schwefel 2002; Eiben & Smith slides; Hansen, Arnold & Auger 2015):
  1. Intermediate recombination of the strategy genes. Evo never averages genes.
  2. A surplus of children and extinctive selection. Evo makes 1000 children from 1000 parents with a size-3 tournament.
  3. A learning rate of about 1/√n. Evo uses 0.2; the recommendations are about 0.001–0.05.
  4. Enough parents relative to the number of parameters (μ ≥ 1.25n). Evo has 1000 parents for about 500k weights.
- **More rounds giving a deeper collapse fits "more efficient selection".** Noise theory predicts the opposite direction. Population genetics says mutation rates fall until a further cut is worth less than drift, and more accurate selection pushes that floor lower (Lynch 2011; LaBar & Adami 2017). The step-size theories predict a deeper collapse with *more* noise (Meyer-Nieberg 2007; Qin 2024), so they do not explain this part of evo's data. This is an interpretation, not a tested result.
- **A fixed step will probably also plateau.** With a fixed step, an evolution strategy stalls at a "final localization error" whose size grows with the step (Beyer & Schwefel 2002). Other causes of a plateau may also be present:
  - opponents that are already beaten, or too strong to beat (Lubberts & Miikkulainen 2001; Perez-Bergquist 2001);
  - evo's direct "pick the highest-scoring move" design, which is harder to learn than evaluating positions (Lucas & Kendall 2006; Risi & Togelius 2015);
  - weight mutation in very large networks, which scaled badly in the studies that varied network size (Szubert, Jaśkowski & Krawiec 2013).

  So compare the meta_rate 0 control on **plateau height**, not only on when the plateau starts.
- **Large-scale neuroevolution keeps the step fixed, keeps a small re-tested elite, selects strongly and uses no crossover.** The Deep GA used population 1000+1, σ = 0.002 on 4M+ weights, the top 20 as parents, and one elite chosen by re-playing the top 10 on 30 extra episodes (Such et al. 2017). OpenAI's ES "did not see benefit from adapting σ" (Salimans et al. 2017). Evo's *starting* mutation has about the same total size as the Deep GA's; the collapsed one is about 90–1500 times smaller (the review's arithmetic, section 5).
- **Every successful game evolver the review read kept good parents alive.** Examples: Blondie24's (15+15) selection, Pollack & Blair's champion, SANE's elite, NEAT's species champions. Rosin & Belew (1997): "Elitism is important… If it is not used, an optimal individual may be found and then lost." Under noisy fitness, elites must earn a fresh score every generation (Arnold & Beyer 2000a; Real et al. 2019). One Swiss tournament is also weak at telling which networks are really the best (Sziklai, Biró & Csató 2022; Glickman & Jensen 2005).
- **Check the reliability numbers before relying on them.** A simulation run during this research (not a published result) found that evo's odd/even split-half reliability under Swiss pairing comes out at about 0.56 at 10 rounds **even when all networks are equally strong**. The documented 0.5 and 0.65–0.7 may therefore be artefacts of the pairing. A test-retest replay settles this (Section 3).

---

## 2. Self-adaptation of step sizes and rates

### 2.1 How it is supposed to work

The scheme comes from Schwefel and is standard in evolution strategies. Each individual carries its own mutation size σ:

1. Nudge σ: σ′ = σ·exp(τ·N(0,1)).
2. Mutate the weights with σ′.
3. A good σ′ tends to produce a good child, so selection carries good σ values along with good weights (Beyer & Schwefel 2002; Eiben & Smith slides, ch. 4).

Evo does exactly this with six genes, nudged by `meta_rate` = τ = 0.2.

The catch is that a σ is judged **only by its child's fitness in one generation**. Hansen & Ostermeier (2001) describe this selection as "highly disturbed": the difference in selection chance between two σ settings "can be quite small".

### 2.2 Why it collapses: the mechanisms, applied to evo

**Mechanism 1: selection rewards safe children, not productive ones.**

*Illustration (the numbers are made up to show the logic):* one strong parent has two mutation children.

| | Child A | Child B |
|---|---|---|
| Genes | weight_step 0.5, ~229 weights | weight_step 0.0004 |
| Effect | changes many move choices | plays the same moves as the parent |
| Chance of beating the parent | maybe 5% | almost 0% |
| Chance of keeping the parent's rank | maybe 30% | almost 100% |

A size-3 tournament on noisy scores mostly asks "who kept a good rank?", not "who made a rare big gain?". B's lineage spreads.

The literature backs each step of this:
- Beyer & Schwefel (2002) call it "opportunism": "Evolution rewards short term success."
- Their formal condition: self-adaptation needs selection pressure λ/μ ≥ 1/P_success, "otherwise, smaller mean step-sizes with higher success probabilities are preferred". Evo's λ/μ is 1.
- Even without noise, "the step-size of the μ-th best offspring is typically even smaller than the step-size of the best offspring" (Hansen, Arnold & Auger 2015, describing a derandomised self-adaptive ES).
- Most random mutations of a good network make it worse. Credit based on the *average* child therefore always pushes rates down (Clune et al. 2008; Kumar et al. 2022). Ni & Spector (2024) found that the expected immediate effect of mutation was negative at every rate they tested.

**Mechanism 2: noise plus no gene recombination makes a random walk that drifts down.**

When selection on σ is mostly noise, σ does a random walk. Small values are rarely punished; large values are removed faster. The walk is therefore biased toward zero (Hansen, Arnold & Auger 2015; Meyer-Nieberg 2007). The one built-in counterweight in classic ES is **averaging σ over several parents** (intermediate recombination), which biases σ upward. In evo:
- crossover and copy children inherit one parent's genes unchanged;
- mutation children nudge one parent's genes.

That is the "(1,λ)" case, which Meyer-Nieberg (2007) shows "loses step-size control" under noise. Liang et al. (cited in Meyer-Nieberg 2007) observed this case stalling even on the simplest test function (the sphere). One high-fitness individual with a far-too-small σ "bequests its ill-adapted mutation strength to all descendants".

**Mechanism 3: the learning rate is large.** Recommended values:
- τ ≈ 1/√N, or 1/√(2N) on multimodal problems (Beyer & Schwefel 2002);
- per-weight τ ≈ 1/√(2√N) (Beyer & Schwefel 2002; used by Blondie24).

The review's arithmetic:

| Basis for N | 1/√(2N) | 1/√(2√N) |
|---|---|---|
| All ~500k weights | ≈ 0.001 | ≈ 0.027 |
| ~229 weights changed per child | ≈ 0.047 | — |

Evo's 0.2 is 4 to 200 times above these. Under noise, a larger τ makes σ fall faster: in Meyer-Nieberg's (1,100)-ES runs, τ = 0.9 drove σ down to about 1e-25. Note that no source says which N applies to sparse mutation (Section 8).

**Mechanism 4: near-copies act as elitism.** In a comma strategy, children that are not changed at all behave like surviving parents. Kruisselbrink et al. (2011) call this "implicit elitism"; Breukelaar & Bäck, as cited there, call it a "hidden plus strategy". Evo's copy_chance gene is an **evolvable** version of this. Its rise to 2–7% at 40 rounds is the predicted pattern. It matches Glickman & Sycara's (2000) experiment where each network could only choose rate 0.2 or rate 0, and the population chose 0.

**Mechanism 5: brittle networks and low rates reinforce each other.** Glickman & Sycara (2000) found that networks from self-adaptive runs were "mutation-brittle". Mutated at the standard rate, they produced equal-or-better children much less often than equally fit networks from fixed-rate runs (9 of 10 pairs). Their explanation is a feedback loop: low rates allow brittle solutions, and brittle solutions favour low rates. Lehman et al. (2018b) observed the same in large networks: GA-trained humanoid policies lost far more performance under perturbation than ES-trained ones.

**Is evo's pattern known? Yes.** The closest matches:

| Study | Setup | Result |
|---|---|---|
| Glickman & Sycara 2000 | 277-weight recurrent net, population 100, tournament 10, fitness from 10 random maze starts, no crossover | Self-adapted rate fell from 0.2 to near 0 by generation ~200; much worse than fixed 0.2. Changing τ "yielded no significant results" (they call this "limited experimentation"). |
| Rand & Riolo 2005 | Population 1000, tournament 3, generational, crossover 0.7, Bäck-style rate bits, a changing test function | Best fitness 83.6 vs 161.0 for fixed rate 0.001 (76 vs 191 in another setting). Rates sank to the floor. |
| Clune et al. 2008 | Avida digital organisms, rugged landscape | Evolved rates orders of magnitude below the best fixed rate; log fitness 4.6 or 1.2 vs 14.5. A non-mutating lineage drove the optimal-rate lineage extinct in 50 of 50 runs. |
| Lehman & Stanley 2011 (abstract only) | Neuroevolution | "Adding self-adaptation to fitness-based search decreases evolvability." |

Kumar et al. (2022), Ni & Spector (2024) and the GA review in Meyer-Nieberg (2007) report the same decay to zero in other domains. Sean Luke (2013): self-adaptive operators are "finicky. I wouldn't bother."

**When self-adaptation does work.** Recent theory proves self-adaptation can beat any fixed rate (Dang & Lehre 2016; Case & Lehre 2020; Doerr, Witt & Yang 2018), but only under conditions evo lacks: selection with λ/μ ≥ 4, a hard floor on the rate, ties broken toward the *higher* rate, an upward bias in the rate update, and noise-free fitness (Case & Lehre 2020).

### 2.3 Fixes the literature offers

| Fix | What it does | Source | Caveat |
|---|---|---|---|
| Drop self-adaptation (fixed step) | Selection can no longer switch exploration off | Glickman & Sycara 2000; Rand & Riolo 2005; Salimans et al. 2017; Such et al. 2017 | A fixed step stalls at a step-dependent floor (Beyer & Schwefel 2002) |
| Recombine the strategy genes | Averaging σ over parents biases σ upward and damps the swings | Beyer & Schwefel 2002 ("highly recommended"); Meyer-Nieberg 2007 | Only the **arithmetic** mean of σ carries the upward bias |
| Small upward bias in the nudge | Counteracts the downward walk when selection on σ is mostly noise | Meyer-Nieberg 2007 (β = 0.005–0.02 for τ = 0.1–0.5); Hansen 2016: "On noisy problems, a properly controlled bias towards increase can be appropriate." | β must match τ, otherwise σ diverges |
| Smaller τ | Slows the drift | Beyer & Schwefel 2002; Schaul et al. 2011 | Only changes the *speed*: the final rate in Clune et al. 2008 did not depend on how often the rate mutated, and Glickman & Sycara found τ insensitive |
| Dynamic lower bound | A floor that follows the search, e.g. the median σ of successful children, or a success rate | Liang, Yao & Newton 2001; Meyer-Nieberg 2007 | A fixed floor is "highly problem dependent"; evo's 1e-4 clamp was hit |
| Offset floor instead of clamp | Effective step = floor + evolved step | Kruisselbrink et al. 2011: hard clamps make the rate "hover" just above the bound, as evo's 0.0002–0.0004 does | The clamp did better in their larger populations, through implicit elitism |
| Always make some children with fixed default genes | Exploration can never fully stop | Rudolph 2001 (a fixed wide distribution next to the self-adapted children) | Shown for a (1+1) algorithm; benefit in practice unknown |
| Population-level 1/5 success rule | One shared step: raise it if more than ~20% of children beat their parent, lower it otherwise | Hansen, Arnold & Auger 2015; Luke 2013 | Near-copies give success near ½ or ties, so the rule pushes the step *up*, which is what evo needs. The 1/5 rule beat GESMR on an MNIST neuroevolution task (Kumar et al. 2022) |
| Cumulative step-size adaptation (CSA, as in CMA-ES) | Step change is unbiased on the log scale when selection is random | Hansen 2016 | Needs a population mean; evo has none, so it does not apply directly |
| Re-evaluate and raise σ when rankings are noisy (UH-CMA-ES) | Re-play a fraction of the population and count rank changes. If rankings are mostly noise, first lengthen evaluation, then **raise** σ | Hansen et al. 2009 | The opposite of what evo's genes do |
| Best-child credit | Judge a rate by the best child in its group, not the average | Kumar et al. 2022 (GESMR); Ni & Spector 2024 | GESMR also keeps one elite |
| Elitism | Removes the lineage's need to keep its rank through near-copies | Kruisselbrink et al. 2011; Lehman et al. 2018b | With elitism, a fit parent with a bad rate can block progress (Doerr, Witt & Yang 2018; Rudolph 2001) |

**Example: recombining genes.** Two parents have weight_step 0.02 and 0.5.

| | Child's weight_step |
|---|---|
| Today | 0.02 or 0.5, unchanged |
| Geometric mean (log-mean) | ≈ 0.1; no upward bias under random selection |
| Arithmetic mean | 0.26; the upward-biased choice the ES theory relies on |

---

## 3. Noise: rounds, population size and re-evaluation

### 3.1 What noise does to selection

In Miller & Goldberg's (1995) model of tournament selection, noise multiplies the selection response by √r, where r is the share of fitness variance that is real. *Our arithmetic*, taking evo's estimated reliabilities at face value:

| Setting | μ(s:s) × √r | Response per generation |
|---|---|---|
| Tournament 3, 10 rounds | 0.85 × √0.5 | ≈ 0.60 |
| Tournament 3, 20 rounds | 0.85 × √0.67 | ≈ 0.69 |
| Tournament 4, 10 rounds | 1.03 × √0.5 | ≈ 0.73 |

By this sum, a larger tournament buys more than doubling rounds, at no extra games. These numbers stand or fall with the reliability estimates (Section 3.4).

Two related points:
- **Convergence makes noise worse.** As the population becomes near-copies, real fitness variance shrinks, so selection becomes nearly random even at fixed noise (Miller & Goldberg 1995).
- **Takeover is fast.** A size-3 tournament on 1000 networks takes about log₃1000 ≈ 6 generations for one ancestor's descendants to fill the population (Poli, Langdon & McPhee 2008). A gene setting that preserves fitness can spread many times over a 500-generation run.

### 3.2 More games per network or more networks?

The findings conflict (Jin & Branke 2005):
- Fitzpatrick & Grefenstette (1988), for GAs: grow the population rather than the sample size. "In some cases, more efficient search results from less accurate evaluations."
- Beyer, and Hammel & Bäck, for (1,λ)-ES: more samples beat a larger population.
- Arnold & Beyer, with recombination: more parents beat resampling.
- Darwen & Pollack (1999), the setting closest to evo (games): resampling helps small populations but not large ones (via Jin & Branke 2005).

Branke & Schmidt (2003) add that noise partly replaces the deliberate randomness of tournament selection, so "one should not reduce noise further than necessary". Luke & Talukder found that for meta-EAs a single noisy test did best (via Luke 2013).

### 3.3 What this means for the 10 / 20 / 40-round result

Three readings, which do not exclude each other:

1. **Precise evaluation is wasteful.** 20 beating 40 at equal compute matches Fitzpatrick & Grefenstette (1988) and Luke & Talukder. Rosin & Belew (1997) even call drift under weak selection "potentially beneficial" in coevolution.
2. **The 40-round run lost partly because exploration switched off.** It collapsed deepest (step about 0.0004 against the 1e-4 clamp). The round comparison is confounded with the gene collapse, so it should be **repeated after the collapse is fixed**. Under plus-selection, more games per network helped (Al-Khateeb & Kendall 2011).
3. **Why less noise gives a deeper collapse.** Three accounts point the same way:
   - **Drift barrier** (Lynch 2011; Sung et al. 2012): mutation rates fall until the gain from a further cut drops below drift, about 1/N_eff. Noisy ranking acts like a smaller effective population, so 10 rounds stop higher (0.018) than 40 rounds (0.0004). Large, efficiently selected populations also end up on fragile peaks with many small-effect harmful mutations (LaBar & Adami 2017; Krakauer & Plotkin 2002; Elena et al. 2007).
   - **Short-term advantage** (Clune et al. 2008): with accurate fitness, the advantage of faithful copies is detected reliably.
   - **Error threshold** (Case & Lehre 2020): with tournament 3 and no elitism, a lineage keeps its level only if more than about 1/3 of its children are no worse. At 40 rounds small losses are detected, so the step must shrink further to meet that bar (our inference).

   The error-threshold theory of Qin (2024) predicts the **opposite** (lower rates with more noise), and so do the ES noise results. The literature does not settle this; see the test in Section 8, question 2.

**Rounds as a schedule, not a constant.** Pollack & Blair (1998) found that comparing two close backgammon players needs "dozens or even hundreds of games". Their fixed schedule for raising the number of games required failed in 9 of 10 runs. Raising it **when the challenger success rate passed 15%** (averaged over 1000 generations) worked in 10 of 10. This fits the owner's preference for more rounds: let a measured statistic decide when to add them.

### 3.4 Can the reliability estimates be trusted?

The Swiss literature, all on small fields:
- At equal games, Swiss ranks the *whole field* best, but is no better than knockout at picking the *single* winner (Sziklai, Biró & Csató 2022; 32 players).
- Accuracy rises with rounds, with diminishing returns: Kendall τ about 0.63–0.67 after 7 rounds for 32 players (Sauer, Cseh & Lenzner 2022).
- "Even with as many as 16 games per player, the inferred ranks are still substantially different from the true ranks" (Glickman & Jensen 2005; 50 players).

**Simulation from this research (not published).** Setup: 1000 players, Bradley-Terry strengths, Swiss pairing by score, White advantage, evo-style rating fit. The script was not kept; the test-retest replay in section 7 (0a) is the real check.

| Rounds | Split-half reliability, all players equally strong | True top-10 recovered | True top-50 recovered |
|---|---|---|---|
| 10 | 0.56 | 2 of 10 | 13 of 50 |
| 20 | 0.71 | 2 of 10 | 20 of 50 |
| 40 | 0.79 | 4 of 10 | 23 of 50 |

(Top-10/top-50 columns are for a spread giving true test-retest reliability of about 0.33/0.50/0.68.)

- **The cause:** Swiss pairs on total score, so each half's opponents depend on the other half's results.
- **Check:** replay one stored generation in a second, independent Swiss tournament and correlate the two.
- **Model limits:** no bots, no draws, not evo's exact pairing.

Christenfeld (1996) is the source of the split-half method. It assumes the two halves are independent tests, which Swiss pairing violates.

---

## 4. Elitism

### 4.1 Benefits

- **Theory.** "Without parameter control… elitist strategies always converge to the essential global optimum, however at a much slower rate." Non-elitist strategies get a similar guarantee only "with mutation variances bounded away from zero" (Hansen, Arnold & Auger 2015). Evo has neither elitism nor a meaningful floor.
- **Practice.** Every successful game evolver read kept parents (Section 6). Rosin & Belew (1997) used 1 elite in 500 and 20 elites in 1000.
- **Fits the owner's hypothesis.** Once the best network survives on its own, its lineage no longer needs near-copies to keep its place:

  | | How the best lineage keeps its place | Its children |
  |---|---|---|
  | Before (today) | Must produce near-copies; small steps win | Mostly near-copies |
  | After (elitism) | The network itself is carried over | Free to explore at a useful step |

  The literature predicts that copy_chance and step collapse should *weaken* (Kruisselbrink et al. 2011; Lehman et al. 2018b). The reduction principle (Altenberg, Liberman & Feldman 2017) suggests the pull toward less variation **remains near a plateau whatever the scheme**, so pair elitism with a floor or a fixed step.

### 4.2 Risks under noisy fitness

- **Stale lucky scores.** If a survivor keeps its old noisy score, "systematic overvaluation and in turn… reduced success probabilities and long periods of stagnation" follow. Success-based step rules become useless (Arnold & Beyer 2000a). Real et al. (2019) describe "lucky models" that linger and dominate reproduction under standard (non-aging) tournament selection.
- **Premature convergence.** Elitism "can cause premature convergence if not kept in check: perhaps by increasing the mutation and crossover noise, or weakening the selection pressure, or reducing how many elites are being stored" (Luke 2013).
- **Bad genes survive with a fit host.** "Using the + strategy bad σ values can survive… too long if their host x is very fit" (Eiben & Smith slides). A high-fitness parent with a bad self-adapted rate can block progress for a long time (Doerr, Witt & Yang 2018).
- **Re-evaluation is not automatically better.** For a (1+1) EA under one kind of noise, re-evaluating the parent made noise tolerance *much worse* (Qian, Yu & Zhou 2013). Occasional re-evaluation can beat both never and always (Arnold & Beyer 2000a). This argues for a margin before an elite is replaced.
- **Single-elite search is fragile under noise.** Population-based schemes are robust (Sudholt 2021). Keep the large population and add only a few elites.

### 4.3 How others do it

| System | Elitism | Noise handling |
|---|---|---|
| Deep GA, Atari (Such et al. 2017) | 1 unchanged elite in 1000+1 | Top 10 (later top 9 plus the previous elite) each play 30 extra episodes; the best mean becomes the elite. The Humanoid runs skipped this and still worked |
| Blondie24 (Chellapilla & Fogel 2001) | Top 15 of 30 survive | Survivors replay games every generation |
| Coevolution, Othello and IPD (Jaśkowski et al. 2013; Chong et al. 2012) | (μ+λ) truncation | Parents re-scored against fresh opponents every generation; candidates compared by paired tests on the same opponents |
| Pollack & Blair 1998 | One champion | Champion moves only 5% toward a winning challenger; the win bar rises adaptively |
| DeepMind soccer, population-based training (Liu et al. 2019) | Weak agents overwritten by stronger ones | Replace only if expected win rate < 0.47; slow Elo (K = 0.1); burn-in period |
| NEAT (Stanley & Miikkulainen 2002) | Champion of each species with more than 5 members copied | — |

**For evo.** Elites that play the next Swiss tournament are re-scored for free. The hard part is *choosing* them: one Swiss tournament identifies only a minority of the true top (Section 3.4). Give a candidate pool extra games before naming elites, for example:
- the top 10–50 by score, plus the current elites;
- colour-paired games (both colours against each opponent);
- the same fixed panel for every candidate (bots, optionally past champions), compared by paired differences (Chong et al. 2012; Jaśkowski et al. 2008).

Prefer new opponents over rematches, since repeating a pairing is "an inefficacious policy" (Sziklai, Biró & Csató 2022).

---

## 5. Large-scale neuroevolution compared with evo

| System | Weights | Population and selection | Elitism | Mutation | Step control | Crossover | Noise handling |
|---|---|---|---|---|---|---|---|
| Deep GA, Atari (Such et al. 2017) | 4M+ (authors' figure) | 1000+1; truncation, top 20 (2%) | 1, re-evaluated | Gaussian on **all** weights, σ = 0.002 | Fixed; picked from 36 settings | None ("for simplicity") | Top 10 × 30 extra episodes |
| Deep GA, Humanoid | ~167k | 12,500+1; top 625 | 1 | All weights, σ = 0.00224 | Fixed; lowered to 0.001 after 1000 generations ("small performance boost") | None | Mean of 5 episodes |
| GA vs ES on Humanoid (Lehman et al. 2018b) | ~167k | — | — | GA needed σ = 0.00224; ES used 0.02 | Larger GA σ "destabilized evolution" | — | — |
| OpenAI ES (Salimans et al. 2017) | ~167k (humanoid) | ES gradient estimate, 10,000 episodes per batch | n/a | Gaussian on all weights, σ = 0.02, mirrored | Fixed: "did not see benefit from adapting σ" | n/a | Rank transform, mirrored sampling, weight decay |
| Safe mutations, control (Lehman et al. 2018a) | ~0.5M–1M | 100, steady-state, tournament 5 | Implicit (steady-state) | All weights, best σ = 0.01 | Fixed; grid of 6 values | None | — |
| ES fine-tuning LLMs (Qiu et al. 2025) | 0.5B–8B | ES, N = 30 | n/a | All weights, σ = 0.001 | Fixed | n/a | — |
| SA-MBEANN (2024) | Small | Tournament 20–50, no elitism | No | Gaussian on all weights | Self-adaptive; τ ≈ 1/√n (formula not verified); step clamped to [0.001, 0.1] | — | — |
| Blondie24 (Chellapilla & Fogel 2001) | 5,046 | (15+15) | Yes | Gaussian on all weights | Per-weight self-adaptive, τ = 0.084 | None | Parents replay; 4-ply search |
| Backgammon (Pollack & Blair 1998) | 3,980 | 1+1 | Champion | Gaussian, 0.05 RMS | Fixed | None | Paired games with the same dice; adaptive win bar |
| NEAT (Stanley & Miikkulainen 2002) | Small, growing | 150 (1000 in one task), speciated | Species champions | 80% of genomes; each weight 90% perturbed | Fixed | Aligned by historical markings | — |
| CoSyNE (Gomez et al. 2008) | Small | Top quarter recombine; replace least fit | Yes | Cauchy, α = 0.3, on 30% of weights | Fixed | One-point within each neuron | — |
| **evo** | ~500–600k | 1000, generational, tournament 3 | **None** (copy_chance only) | Uniform ±step on ~229 weights | **Self-adaptive, τ = 0.2**; collapses to 0.0004–0.018 | 40% one-point on flat arrays; children not mutated | Swiss, 10–40 rounds |

**Total mutation size.** The review's arithmetic: the perturbation norm √(k·s²/3) of a child whose k weights each change by uniform ±s (k·s²/3 is the squared norm), against √(n·σ²) for dense Gaussian noise σ on n weights. Evo's rows are the median over a generation's networks of their genes `weight_changes` (k) and `weight_step` (s), from `births`.

| Setting | Perturbation norm |
|---|---|
| Evo generation 0 (k = 229, s = 0.5) | ≈ 4.4; the same as dense Gaussian σ ≈ 0.0059 on 550k weights |
| Deep GA, Atari (σ 0.002 on 4M) | ≈ 4 |
| `seed2-rounds10`, generation 500 | ≈ 0.049 |
| `rounds20` (seed 1), generation 303 (tiny step, 30k–250k weights) | ≈ 0.040 |
| `seed2-rounds20`, generation 500 | ≈ 0.011 |
| `seed2-rounds40`, generation 500 | ≈ 0.0028 |

Evo started in the range that works at scale and collapsed about 90 to 1500 times below it. The seed-1 run shows the genes trading off along the norm: tiny steps on many weights. That is why a floor should apply to the **total norm**, not to weight_step alone (Salimans et al. 2017: what matters is the size of the whole perturbation).

**Crossover.** None of the large-scale successes used it (Such et al. 2017; Salimans et al. 2017; Lehman et al. 2018a). Naive crossover of unaligned networks destroys function: in Uriot & Izzo (2020), averaging two independently trained CIFAR networks dropped accuracy from about 40% to chance. That was arithmetic averaging between unrelated parents, not one-point crossover between relatives. NEAT shows crossover helps when genes are aligned (3,600 vs 5,557 evaluations without mating). Evo's crossover may be harmless late in a run, when parents are close relatives, and harmful early. Recombination also selects for robustness on its own (Azevedo et al. 2006; Lenski, Barrick & Ofria 2006), which confounds the gene story.

**Weight growth.** Without decay, evolved weights grew to mean absolute values of 3–105 under some ES variants (Pagliuca, Milano & Nolfi 2020). Pollack & Blair (1998) list "general growth in weights" as a possible cause of stalling. An absolute step shrinks *relative* to growing weights, and growth also saturates sigmoid units (Glorot & Bengio 2010). Evo's initial ±0.5 is about four times Glorot & Bengio's normalised initialisation bound √6/√(n_in+n_out) ≈ 0.12 for its 200-wide hidden layers (the review's arithmetic).

---

## 6. Evolving Go and board-game players; coevolution

### 6.1 What was reached

| System | Board / game | Result |
|---|---|---|
| SANE (Richards, Moriarty & Miikkulainen 1998) | 9×9 Go, same "highest legal output plays" design as evo | Beat the weak program Wally 75% of the time after about 260 generations (up to 5 CPU-days) |
| ESP against GnuGo (Perez-Bergquist 2001) | 9×9, 11×11, 13×13 Go | Never won more than 1.2% of games: no gradient. Learned fine at 5×5 and 7×7 |
| Roving eye, NEAT (Stanley & Miikkulainen 2004a) | Small-board Go | Graded score-based fitness; species champions kept; learned to exploit GnuGo's habits |
| Lubberts & Miikkulainen 2001 | Small-board Go | Coevolution with a hall of fame beat gnugo in about 5–7 generations. Evolution *against* gnugo stopped improving once it won |
| Silver, Sutton & Müller 2007 | 9×9 Go | Linear value function over local shapes, TD-trained, 1-ply, about 1.5M weights: CGOS rating about +1070 to +1140 without deep search |
| Blondie24 (Chellapilla & Fogel 2001) | Checkers | 5,046-weight evaluator with search, 840 generations: expert rating 2045.85. No stall seen; the paper reports no σ trajectories |
| Pollack & Blair 1998 | Backgammon | About 40% against PUBEVAL after 100k generations |

**Architecture.** Action selectors, where the network picks the move directly as evo's does, are "typically harder to learn" than state evaluators (Lucas & Kendall 2006). They are "generally not competitive" with networks that evaluate positions (Risi & Togelius 2015). Whole-board Go networks "can do well on small-board Go… but fail to scale up" (Risi & Togelius 2015).

### 6.2 What helped

- **Parent survival or averaging.**
  - Blondie24 used (15+15) selection; SANE kept its elite; NEAT copied champions.
  - Runarsson & Lucas found parent/child weighted averaging "essential" (secondary, via Lucas & Kendall 2006 and Lucas 2008). Self-adaptive mutation strength had "unnoticeable" effects for larger populations (secondary, via Krawiec & Szubert 2010).
  - The two secondary sources disagree on whether a population of 10 was enough.
- **Keeping opponents near 50%.**
  - Pollack & Blair (1998): learning was fastest when the win probability was near 50%; coevolution beat every fixed foil.
  - Lucas & Kendall (2006): add random moves to a strong fixed opponent, tuned so the population has an even chance.
  - Opponents that are beaten (Lubberts & Miikkulainen 2001) or too strong (Perez-Bergquist 2001) give no gradient.
- **Randomness against overfitting.** Against fully deterministic Wally, SANE learned "tricks" and then lost even to random players. Adding 10% random moves to Wally fixed this (Richards, Moriarty & Miikkulainen 1998). Exploratory moves during evaluation were part of what made coevolution beat TD in Runarsson & Lucas (abstract).
- **Archives.** A hall of fame of past champions sped coevolution (Lubberts & Miikkulainen 2001) and helped on 5×5 Go (Krawiec, Jaśkowski & Szubert 2011). Random sampling from it was cheaper than performance-based sampling, at little loss (Rosin & Belew 1997).
- **Paired games.** Colours reversed with the same dice (Pollack & Blair 1998); double games (Krawiec, Jaśkowski & Szubert 2011; Jaśkowski et al. 2008).

### 6.3 Pathologies to watch

- **Mediocre stable states** (Pollack & Blair 1998), more likely in deterministic games.
- **Cycling and focus on the wrong things** (Watson & Pollack 2001).
- **Internal and external measures can disagree.** In 5×5 Go the benchmark plateaued while genotypes kept changing (Krawiec, Jaśkowski & Szubert 2011). Evo's collapse suggests the opposite case: the search itself has stopped.
- **Fixed-opponent fitness overfits.** It maximises score against those opponents but generalises worse (Szubert, Jaśkowski & Krawiec 2013). In the same study no mutation σ rescued pure weight mutation in larger networks.

---

## 7. Recommendations for evo

All comparisons are at **equal games played**, against the existing 20-round runs (`rounds20`, seed 1, to generation 303; `seed2-rounds20`, to generation 500) unless stated. The Field Guide warns that two seeds is thin (Poli, Langdon & McPhee 2008), so add seeds where the budget allows.

### Step 0: cheap measurements (no new long runs)

| # | Measurement | Why | Source |
|---|---|---|---|
| 0a | **Test-retest reliability.** Replay one stored generation in an independent Swiss tournament at 10 and 20 rounds; correlate wins and fits | The split-half estimates may be pairing artefacts | Simulation in Section 3.4; Christenfeld 1996 |
| 0b | **Neutral-drift control.** A few dozen generations with shuffled fitness; track median log weight_step | Separates selection from drift. Our estimate: a lineage's log-step random walk has SD ≈ 0.2·√(0.6·500) ≈ 3.5 after 500 generations, the same order as the observed falls (3.3 to 7 log units) | Kruisselbrink et al. 2011; Hansen 2016 |
| 0c | **Offspring distribution / brittleness test.** Take top networks from late self-adaptive generations; mutate each 32–64 times at fixed steps {0.5, 0.1, 0.02, 0.005} with ~229 changes, plus exact copies to measure noise; score against a fixed bot panel. Report P(child ≥ parent), mean change, top-10% and bottom-10% means; fit w(step) = w₀·exp(−a·step − b·step²) | Tells whether larger steps still give rare big gains (premature collapse) or never do (a bowl or brittle networks) | Glickman & Sycara 2000; Smith et al. 2002; Wilke et al. 2001 |
| 0d | **Per-generation logging** | Makes runs comparable and diagnoses the plateau | Below |

Items to log in 0d:
- perturbation norm √(k·s²/3);
- fraction of mutation children scoring ≥ parent;
- separate scores for crossover, mutation and copy children;
- per-bot win rates;
- weight RMS per layer and the share of saturated units;
- fraction of reference positions where a child picks the same move as its parent.

Sources: Beyer & Schwefel 2002; Case & Lehre 2020; Pagliuca, Milano & Nolfi 2020; van Nimwegen et al. 1999.

### Ranked experiments

**1. meta_rate 0 control (the owner's plan).**
- **Hypothesis:** fixed genes keep exploring, so benchmark strength keeps rising past generation 100–300, or plateaus higher.
- **Single change:** meta_rate 0.2 → 0. Genes stay at their initial values: step 0.5, ~229 changes, initial copy_chance.
- **Compare:** the 20-round seed 1 and 2 runs.
- **Literature:** Glickman & Sycara 2000; Rand & Riolo 2005; Clune et al. 2008; Such et al. 2017; Salimans et al. 2017; Runarsson & Lucas (secondary).

How the literature refines it:
- Judge on **plateau height at 300–500 generations**. Robust solutions may look worse early (Elena & Sanjuán 2008). A fixed step also stalls at a step-dependent level (Beyer & Schwefel 2002).
- Watch the opposite failure. Without elitism, a large fixed step can exceed what the population can keep (Qin 2024; Case & Lehre 2020). If fewer than about 1/3 of mutation children score at or above their parent, or the best networks' strength against fixed bots rises and falls, the step is too big for non-elitist selection.
- Treat 0.5/229 as one point on a grid. Such et al. tuned over 36 settings and Lehman et al. over 6. If budget allows, add a second arm with step 0.15 (about 11 times smaller squared norm, the review's arithmetic) to separate "self-adaptation is harmful" from "0.5 is the wrong step".
- Expect robustness to evolve in the weights instead: higher move margins, more neutral mutants (van Nimwegen et al. 1999; Forster et al. 2006; Wilke et al. 2001). Track it with diagnostic 0d.

**2. Elitism, crossed with meta_rate (2×2 design).**
- **Hypothesis:** explicit elitism removes the advantage of near-copy lineages, so with meta_rate 0.2 the step and copy_chance collapse less; with meta_rate 0 the plateau is higher.
- **Single change:** carry over E unchanged elites.
- **Compare:** run 1 (meta_rate 0) and the 20-round meta_rate 0.2 runs.
- **Literature:** Such et al. 2017; Rosin & Belew 1997; Arnold & Beyer 2000a; Kruisselbrink et al. 2011; Luke 2013.

How the literature refines it:
- **How many:** 1–2% (10–20 of 1000). Deep GA used 1; Rosin & Belew 20 in 1000. Keep it small (Luke 2013).
- **No stale scores:** elites play the next Swiss tournament like everyone else (Arnold & Beyer 2000a; Real et al. 2019; Jaśkowski et al. 2013).
- **Choosing elites:** give the top ~10–50 plus the current elites a batch of extra colour-paired games against the same fixed panel, and pick by mean or paired difference (Such et al. 2017; Chong et al. 2012). One Swiss tournament alone mostly keeps lucky networks (Section 3.4).
- **Optional margin:** replace an elite only if a challenger is clearly better (Pollack & Blair 1998; Liu et al. 2019).
- **Follow-up as a separate change:** set copy_chance to 0 in elitist runs. An exact copy then only duplicates an elite (Kruisselbrink et al. 2011; Poli, Langdon & McPhee 2008).
- **With meta_rate 0.2:** add a floor or fixed-gene children, because an elite with collapsed genes can block exploration (Doerr, Witt & Yang 2018; Rudolph 2001).

**3. Fixed-gene share (if self-adaptation is kept).**
- **Hypothesis:** a guaranteed stream of default-gene children stops exploration from switching off.
- **Single change:** 10% of mutation children use the default genes (0.5, ~229) whatever their parent's genes.
- **Compare:** the 20-round self-adaptive runs.
- **Literature:** Rudolph 2001; Yao, Liu & Lin 1999 (two step scales per parent, keep the better).

**4. Recombine the strategy genes.**
- **Hypothesis:** averaging genes provides the upward bias classic ES relies on, so σ stays stable under noise.
- **Single change:** every child's step-size genes are the **arithmetic mean** of two tournament winners' genes, then nudged.
- **Compare:** the 20-round runs.
- **Literature:** Beyer & Schwefel 2002; Meyer-Nieberg 2007; Hansen, Arnold & Auger 2015.

**5. Population-level 1/5 success rule (replaces weight_step self-adaptation).**
- **Hypothesis:** a shared step driven by the measured success rate cannot be gamed by single lineages. Near-copies push it *up*.
- **Single change:** a shared weight_step, multiplied up when more than ~20% of mutation children out-rank their parent's previous percentile, down otherwise.
- **Compare:** runs 1 and 4.
- **Literature:** Hansen, Arnold & Auger 2015; Luke 2013; Kumar et al. 2022; Plappert et al. 2018 (adapt the step to a target behavioural change instead).

**6. Upward-biased nudge, offset floor or smaller meta_rate (if self-adaptation is kept).** One at a time:
- log-step nudge + β with β ≈ 0.01 (Meyer-Nieberg 2007);
- offset floor on the total perturbation norm (Kruisselbrink et al. 2011; Liang, Yao & Newton 2001);
- meta_rate 0.05 (Beyer & Schwefel 2002).

Expect a smaller meta_rate only to slow the collapse (Clune et al. 2008; Glickman & Sycara 2000).

**7. Tournament size 5.**
- **Hypothesis:** stronger selection lets riskier steps win and raises the error threshold.
- **Single change:** tournament size 3 → 5.
- **Compare:** the 20-round runs.
- **Literature:** Beyer & Schwefel 2002; Glickman & Sycara 1998; Qin 2024; Miller & Goldberg 1995.

Low priority for stopping the collapse: Glickman & Sycara (2000) found stronger selection "negligible at best" at stopping their mutation rates' convergence. For the search itself they found tournament size mattered, effective only in a narrow band (about 10, in a population of 100).

**8. Crossover off.**
- **Hypothesis:** one-point crossover of unaligned flat arrays is destructive early and adds a second near-copy channel late.
- **Single change:** cross_over_rate 0.4 → 0, under meta_rate 0.
- **Compare:** run 1.
- **Literature:** Such et al. 2017; Stanley & Miikkulainen 2002; Uriot & Izzo 2020; Azevedo et al. 2006.

**9. Heavy-tailed weight_changes, without genes.**
- **Hypothesis:** drawing the number of changed weights per child from a power law (β = 1.5) gives many near-copies plus occasional large jumps, with no gene to collapse.
- **Single change:** under meta_rate 0, draw α from Pr ∝ α^−1.5 on [1, N/2] and change α weights. Our arithmetic: mean about 400, median 2.
- **Compare:** run 1.
- **Literature:** Doerr et al. 2017; Antipov, Buzdalov & Doerr 2020, 2021; Hansen et al. 2006 (heavy tails help when the large steps are axis-aligned).

This theory is proven only for elitist algorithms on bit strings.

**10. Fitness-side changes (later).** Each is a single change:
- per-bot win-rate audit, and tuning bot randomness toward 20–80% wins (Lucas & Kendall 2006; Pollack & Blair 1998);
- a hall of fame of past champions as Swiss opponents (Lubberts & Miikkulainen 2001; Rosin & Belew 1997);
- move noise in training games (Richards, Moriarty & Miikkulainen 1998);
- an even number of rounds with balanced colours (Csató & Krumer 2024);
- a benchmark bot never used for fitness (Szubert, Jaśkowski & Krawiec 2013);
- a round schedule triggered by a measured statistic rather than by generation (Pollack & Blair 1998).

**Also for later (head-start comparisons, per CLAUDE.md):**
- a norm-matched sparse vs dense mutation comparison (no source answers it);
- a 1-ply state-evaluator interface (Risi & Togelius 2015);
- a TD-trained seed refined by evolution (Kim, Choi & Cho 2007);
- local, weight-shared shape features (Silver, Sutton & Müller 2007).

---

## 8. Open questions the literature does not answer for evo

1. **Which N sets τ for sparse mutation:** all ~500k weights, or the ~229 changed? ES theory assumes every coordinate is mutated (Beyer & Schwefel 2002).
2. **Why does less noise give a deeper collapse?** The drift barrier fits (Lynch 2011; LaBar & Adami 2017). Noise theory predicts the reverse (Qin 2024; Meyer-Nieberg 2007). No paper maps ranking reliability to an effective population size. The direct test is to measure the fraction of non-worse children against step size at 10, 20 and 40 rounds.
3. **Cause or consequence?** In the E. coli long-term experiment, mutation rates fell *after* adaptive potential declined (Wielgoss et al. 2013). The collapse may follow the plateau rather than cause it. Comparing run 1 on both timing and plateau height separates the two.
4. **Is the plateau a real optimum or a premature stop?** Only measurement 0c plus run 1 can tell.
5. **Does elitism remove the drive toward near-copies or only weaken it?** The reduction principle suggests only weaken (Altenberg, Liberman & Feldman 2017).
6. **Sparse large steps or dense small steps at equal norm?** Untested for deep MLPs trained from scratch (Whitaker & Whitley 2023 did not match norms; Montana & Davis 1989 used a 126-weight net).
7. **How noisy and how intransitive are Swiss win counts for 1000 networks with bots, draws and colours?** The literature covers at most 256 players. Rating fits can hurt in intransitive games (Harris & Tauritz 2021).
8. **Should elites be judged against fixed bots or within the network tournament?** Bots are steadier but risk overfitting (Szubert, Jaśkowski & Krawiec 2013).
9. **Not read in full:**
   - Arnold & Beyer 2000b (PPSN): reportedly finds both self-adaptation and CSA "prone to failure in the presence of noise" (not verified).
   - Smith & Fogarty 1996: steady-state replacement policies (not verified).
   - Meyer-Nieberg & Beyer 2007 (book chapter), Kramer 2010, Runarsson & Lucas 2005 full text, Lehman & Stanley 2011 full text.

---

## 9. Reading list (the 12 most useful, all free)

1. Glickman & Sycara (2000), *Reasons for Premature Convergence of Self-Adapting Mutation Rates.* The closest analogue to evo, including the brittleness test. https://publications.ri.cmu.edu/storage/publications/pub_files/pub2/glickman_matthew_2000_1/glickman_matthew_2000_1.pdf
2. Hansen, Arnold & Auger (2015), *Evolution Strategies* (handbook chapter). Self-adaptation, the 1/5 rule, noise, elitism. http://www.cmap.polytechnique.fr/~nikolaus.hansen/es-overview-2015.pdf
3. Beyer & Schwefel (2002), *Evolution strategies: A comprehensive introduction.* Learning rates, "opportunism", the λ/μ ≥ 1/P_s condition. https://gwern.net/doc/reinforcement-learning/model-free/2002-beyer.pdf
4. Such et al. (2017), *Deep Neuroevolution.* Fixed σ, one re-evaluated elite, population 1000. https://arxiv.org/pdf/1712.06567
5. Rand & Riolo (2005), *The Problem with a Self-Adaptive Mutation Rate in Some Environments.* Population 1000, tournament 3. https://gpbib.cs.ucl.ac.uk/gecco2005/docs/p1493.pdf
6. Meyer-Nieberg (2007), *Self-Adaptation in Evolution Strategies* (PhD thesis). Loss of step-size control under noise, recombination and bias remedies. https://eldorado.tu-dortmund.de/bitstream/2003/25073/1/phd.pdf
7. Clune et al. (2008), *Natural Selection Fails to Optimize Mutation Rates for Long-Term Adaptation on Rugged Fitness Landscapes.* https://pmc.ncbi.nlm.nih.gov/articles/PMC2527516/
8. Pollack & Blair (1998), *Co-Evolution in the Successful Learning of Backgammon Strategy.* Rise-then-plateau with near-identical players, adaptive evaluation. https://cgi.cse.unsw.edu.au/~blair/pubs/1998PollackBlairML.pdf
9. Lehman, Chen, Clune & Stanley (2018b), *ES Is More Than Just a Traditional Finite-Difference Approximator.* States the owner's hypothesis. https://arxiv.org/pdf/1712.06568
10. Kruisselbrink et al. (2011), *On the Log-Normal Self-Adaptation of the Mutation Rate in Binary Search Spaces.* Clamps and implicit elitism. https://groups.csail.mit.edu/EVO-DesignOpt/gecco2011Proceedings/proceedings/p893.pdf
11. Hansen et al. (2009), *A Method for Handling Uncertainty in Evolutionary Optimization* (UH-CMA-ES). Raise σ when rankings are noisy. http://www.cmap.polytechnique.fr/~nikolaus.hansen/TEC2009.pdf
12. Luke (2013), *Essentials of Metaheuristics.* Elitism, coevolution, a practitioner's view of self-adaptation. https://cs.gmu.edu/~sean/book/metaheuristics/

---

## References

*"Free" means a free full text exists. "Abstract only" means only the abstract was read.*

- Al-Khateeb, B., Kendall, G. (2011). Introducing a Round Robin Tournament into Evolutionary Individual and Social Learning Checkers. https://www.graham-kendall.com/papers/ak2011b.pdf (free)
- Altenberg, L. (1994). The evolution of evolvability in genetic programming. https://dynamics.org/Altenberg/FILES/LeeEEGP.pdf (free)
- Altenberg, L., Liberman, U., Feldman, M. (2017). Unified reduction principle for the evolution of mutation, migration, and recombination. https://www.ncbi.nlm.nih.gov/pmc/articles/PMC5373362/ (abstract only)
- Antipov, D., Buzdalov, M., Doerr, B. (2020). Fast Mutation in Crossover-based Algorithms. https://arxiv.org/abs/2004.06538 (free)
- Antipov, D., Buzdalov, M., Doerr, B. (2021). Lazy Parameter Tuning and Control: Choosing All Parameters Randomly From a Power-Law Distribution. https://arxiv.org/abs/2104.06714 (abstract only)
- Arnold, D. V., Beyer, H.-G. (2000a). Local Performance of the (1+1)-ES in a Noisy Environment. https://eldorado.tu-dortmund.de/handle/2003/5384 (free)
- Arnold, D. V., Beyer, H.-G. (2000b). Efficiency and Mutation Strength Adaptation of the (μ/μ_I,λ)-ES in a Noisy Environment. https://doi.org/10.1007/3-540-45356-3_4 (not free; not verified)
- Azevedo, R., et al. (2006). Sexual reproduction selects for robustness and negative epistasis in artificial gene networks. https://pubmed.ncbi.nlm.nih.gov/16511495 (abstract only)
- Beyer, H.-G., Schwefel, H.-P. (2002). Evolution strategies: A comprehensive introduction. https://gwern.net/doc/reinforcement-learning/model-free/2002-beyer.pdf (free)
- Branke, J., Schmidt, C. (2003). Selection in the Presence of Noise. https://www.cs.york.ac.uk/rts/docs/GECCO_2003/papers/2723/27230766.pdf (free)
- Case, B., Lehre, P. K. (2020). Self-adaptation in non-Elitist Evolutionary Algorithms on Discrete Problems with Unknown Structure. https://arxiv.org/pdf/2004.00327 (free)
- Chellapilla, K., Fogel, D. B. (2001). Evolving an Expert Checkers Playing Program without Using Human Expertise. http://www.sci.brooklyn.cuny.edu/~sklar/teaching/f05/alife/papers/ali-Evolving-an-expert-checkers-playing-program-without-using-human-expertise.pdf (free)
- Chong, S. Y., Tino, P., Ku, D. C., Yao, X. (2012). Improving Generalization Performance in Co-evolutionary Learning. https://petertino.github.io/web/PAPERS/clmpaperfinal.pdf (free)
- Christenfeld, N. (1996). What makes a good sport? https://nature.com/articles/383662b0.pdf (free)
- Clune, J., et al. (2008). Natural Selection Fails to Optimize Mutation Rates for Long-Term Adaptation on Rugged Fitness Landscapes. https://pmc.ncbi.nlm.nih.gov/articles/PMC2527516/ (free)
- Csató, L., Krumer, A. (2024). Swiss-system chess tournaments and unfairness. https://arxiv.org/abs/2410.19333 (free)
- Dang, D.-C., Lehre, P. K. (2016). Self-adaptation of Mutation Rates in Non-elitist Populations. https://arxiv.org/abs/1606.05551 (free)
- Doerr, B., Le, H. P., Makhmara, R., Nguyen, T. D. (2017). Fast Genetic Algorithms. https://arxiv.org/abs/1703.03334 (free)
- Doerr, B., Witt, C., Yang, J. (2018). Runtime Analysis for Self-adaptive Mutation Rates. https://arxiv.org/pdf/1811.12824 (free)
- Eiben, A. E., Hinterding, R., Michalewicz, Z. (1999). Parameter Control in Evolutionary Algorithms. https://cs.adelaide.edu.au/~zbyszek/Papers/self9.pdf (free)
- Eiben, A. E., Smith, J. E. (2003–2015). Introduction to Evolutionary Computing, official slides (chapters 4–8, 11, 15; 1st-edition ES slides). http://web.archive.org/web/20211130111157/http://www.evolutionarycomputation.org/wp-content/uploads/2015/06/ch04-Representation_Mutation_Recombination-2014.pptx and https://www.cs.vu.nl/~gusz/ecbook/slides/Evolution_strategies.ppt (free)
- Elena, S. F., Sanjuán, R. (2008). The effect of genetic robustness on evolvability in digital organisms. https://www.ncbi.nlm.nih.gov/pmc/articles/PMC2588588/ (free)
- Elena, S. F., Wilke, C. O., Ofria, C., Lenski, R. E. (2007). Effects of population size and mutation rate on the evolution of mutational robustness. https://pubmed.ncbi.nlm.nih.gov/17348929 (abstract only)
- Fitzpatrick, J. M., Grefenstette, J. J. (1988). Genetic Algorithms in Noisy Environments. https://mlanthology.org/mlj/1988/fitzpatrick1988mlj-genetic (abstract only)
- Forster, R., Adami, C., Wilke, C. O. (2006). Selection for mutational robustness in finite populations. https://pubmed.ncbi.nlm.nih.gov/16901510 (abstract only)
- Glickman, M., Sycara, K. (1998). Evolutionary Algorithms: Exploring the Dynamics of Self-Adaptation. https://publications.ri.cmu.edu/storage/publications/pub_files/pub2/glickman_matthew_1998_1/glickman_matthew_1998_1.pdf (free)
- Glickman, M., Sycara, K. (2000). Reasons for Premature Convergence of Self-Adapting Mutation Rates. https://publications.ri.cmu.edu/storage/publications/pub_files/pub2/glickman_matthew_2000_1/glickman_matthew_2000_1.pdf (free)
- Glickman, M. E., Jensen, S. T. (2005). Adaptive paired comparison design. https://glicko.net/research/gj.pdf (free)
- Glorot, X., Bengio, Y. (2010). Understanding the difficulty of training deep feedforward neural networks. https://proceedings.mlr.press/v9/glorot10a/glorot10a.pdf (free)
- Gomez, F., Schmidhuber, J., Miikkulainen, R. (2008). Accelerated Neural Evolution through Cooperatively Coevolved Synapses. https://jmlr.org/papers/volume9/gomez08a/gomez08a.pdf (free)
- Hansen, N. (2016). The CMA Evolution Strategy: A Tutorial. https://arxiv.org/pdf/1604.00772 (free)
- Hansen, N., Arnold, D. V., Auger, A. (2015). Evolution Strategies. http://www.cmap.polytechnique.fr/~nikolaus.hansen/es-overview-2015.pdf (free)
- Hansen, N., Gemperle, F., Auger, A., Koumoutsakos, P. (2006). When Do Heavy-Tail Distributions Help? https://researchportal.ip-paris.fr/en/publications/when-do-heavy-tail-distributions-help/ (abstract only)
- Hansen, N., Niederberger, A., Guzzella, L., Koumoutsakos, P. (2009). A Method for Handling Uncertainty in Evolutionary Optimization with an Application to Feedback Control of Combustion. http://www.cmap.polytechnique.fr/~nikolaus.hansen/TEC2009.pdf (free)
- Hansen, N., Ostermeier, A. (2001). Completely Derandomized Self-Adaptation in Evolution Strategies. http://www.cmap.polytechnique.fr/~nikolaus.hansen/cmaartic.pdf (free)
- Harris, S., Tauritz, D. (2021). Competitive Coevolution for Defense and Security: Elo-Based Similar-Strength Opponent Sampling. http://www.cmap.polytechnique.fr/~nikolaus.hansen/proceedings/2021/GECCO/companion/companion_files/p1898-harris.pdf (free)
- Jaśkowski, W., Krawiec, K., Wieloch, B. (2008). Fitnessless Coevolution. https://web.archive.org/web/2015/http://www.cs.put.poznan.pl/wjaskowski/pub/papers/jaskowski08fitnessless.pdf (free)
- Jaśkowski, W., Liskowski, P., Szubert, M., Krawiec, K. (2013). Improving Coevolution by Random Sampling. https://www.cs.put.poznan.pl/mszubert/pub/jaskowski2013gecco.pdf (free)
- Jin, Y., Branke, J. (2005). Evolutionary Optimization in Uncertain Environments: A Survey. https://web.archive.org/web/2015/http://www.cs.le.ac.uk/people/sy11/ECiDUE/JinBranke-TEVC05.pdf (free)
- Kim, K.-J., Choi, H., Cho, S.-B. (2007). Hybrid of Evolution and Reinforcement Learning for Othello Players. http://vigir.missouri.edu/~gdesouza/Research/Conference_CDs/IEEE_SSCI_2007/CI%20and%20Games%20-%20CIG%202007/data/papers/CIG/S001P028.pdf (free)
- Krakauer, D. C., Plotkin, J. B. (2002). Redundancy, antiredundancy, and the robustness of genomes. https://www.ncbi.nlm.nih.gov/pmc/articles/PMC122203/ (abstract only)
- Krawiec, K., Jaśkowski, W., Szubert, M. (2011). Evolving Small-Board Go Players Using Coevolutionary Temporal Difference Learning with Archives. https://zbc.uz.zgora.pl/repozytorium/Content/46954/download (free)
- Krawiec, K., Szubert, M. (2010). Coevolutionary Temporal Difference Learning for Small-Board Go. https://www.cs.put.poznan.pl/kkrawiec/pubs/2010CECGo.pdf (free)
- Kruisselbrink, J., Li, R., Reehuis, E., Eggermont, J., Bäck, T. (2011). On the Log-Normal Self-Adaptation of the Mutation Rate in Binary Search Spaces. https://groups.csail.mit.edu/EVO-DesignOpt/gecco2011Proceedings/proceedings/p893.pdf (free)
- Kumar, A., Liu, B., Miikkulainen, R., Stone, P. (2022). Effective Mutation Rate Adaptation through Group Elite Selection. https://arxiv.org/html/2204.04817 (free)
- LaBar, T., Adami, C. (2017). Evolution of drift robustness in small populations. https://www.ncbi.nlm.nih.gov/pmc/articles/PMC5647343/ (free)
- Lehman, J., Chen, J., Clune, J., Stanley, K. O. (2018a). Safe Mutations for Deep and Recurrent Neural Networks through Output Gradients. https://arxiv.org/pdf/1712.06563 (free)
- Lehman, J., Chen, J., Clune, J., Stanley, K. O. (2018b). ES Is More Than Just a Traditional Finite-Difference Approximator. https://arxiv.org/pdf/1712.06568 (free)
- Lehman, J., Stanley, K. O. (2011). Improving Evolvability Through Novelty Search and Self-Adaptation. https://stars.library.ucf.edu/scopus2010/2709 (abstract only)
- Lenski, R. E., Barrick, J. E., Ofria, C. (2006). Balancing robustness and evolvability. https://www.ncbi.nlm.nih.gov/pmc/articles/PMC1750925/ (free)
- Liang, K.-H., Yao, X., Newton, C. S. (2001). Adapting self-adaptive parameters in evolutionary algorithms. https://scholars.ln.edu.hk/en/publications/adapting-self-adaptive-parameters-in-evolutionary-algorithms/ (abstract only)
- Liu, S., et al. (2019). Emergent Coordination Through Competition. https://arxiv.org/pdf/1902.07151 (free)
- Lubberts, A., Miikkulainen, R. (2001). Co-Evolving a Go-Playing Neural Network. https://www.cs.utexas.edu/users/nn/downloads/papers/lubberts.coevolution-gecco01.pdf (free)
- Lucas, S. M. (2008). Investigating Learning Rates for Evolution and Temporal Difference Learning. https://repository.essex.ac.uk/4049/1/ciginfo.pdf (free)
- Lucas, S. M., Kendall, G. (2006). Evolutionary Computation and Games. https://www.cs.montana.edu/courses/spring2007/536/materials/ec_and_games_lucas.pdf (free)
- Luke, S. (2013). Essentials of Metaheuristics, 2nd ed. https://cs.gmu.edu/~sean/book/metaheuristics/ (free)
- Lynch, M. (2011). The lower bound to the evolution of mutation rates. https://www.ncbi.nlm.nih.gov/pmc/articles/PMC3194889/ (free)
- Meyer-Nieberg, S. (2007). Self-Adaptation in Evolution Strategies (PhD thesis). https://eldorado.tu-dortmund.de/bitstream/2003/25073/1/phd.pdf (free)
- Miller, B. L., Goldberg, D. E. (1995). Genetic Algorithms, Tournament Selection, and the Effects of Noise. https://content.wolfram.com/sites/13/2018/02/09-3-2.pdf (free)
- Montana, D. J., Davis, L. (1989). Training Feedforward Neural Networks Using Genetic Algorithms. https://www.ijcai.org/Proceedings/89-1/Papers/122.pdf (free)
- Ni, A., Spector, L. (2024). Effective Adaptive Mutation Rates for Program Synthesis. https://arxiv.org/html/2406.15976v1 (free)
- Pagliuca, P., Milano, N., Nolfi, S. (2020). Efficacy of Modern Neuro-Evolutionary Strategies for Continuous Control Optimization. https://arxiv.org/pdf/1912.05239 (free)
- Perez-Bergquist, A. S. (2001). Applying ESP and Region Specialists to Neuro-Evolution for Go. https://www.cs.utexas.edu/ftp/techreports/tr01-24.pdf (free)
- Plappert, M., et al. (2018). Parameter Space Noise for Exploration. https://arxiv.org/pdf/1706.01905 (free)
- Poli, R., Langdon, W. B., McPhee, N. F. (2008). A Field Guide to Genetic Programming. http://www0.cs.ucl.ac.uk/staff/W.Langdon/ftp/papers/poli08_fieldguide.pdf (free)
- Pollack, J. B., Blair, A. D. (1998). Co-Evolution in the Successful Learning of Backgammon Strategy. https://cgi.cse.unsw.edu.au/~blair/pubs/1998PollackBlairML.pdf (free)
- Qian, C., Yu, Y., Zhou, Z.-H. (2013). Analyzing Evolutionary Optimization in Noisy Environments. https://arxiv.org/pdf/1311.4987 (free)
- Qin, X. (2024). Self-adaptive parameter control mechanisms in evolutionary computation (PhD thesis). http://etheses.bham.ac.uk//id/eprint/14436/7/Qin2024PhD.pdf (free)
- Qiu, X., et al. (2025). Evolution Strategies at Scale: LLM Fine-Tuning Beyond Reinforcement Learning. https://arxiv.org/html/2509.24372 (free)
- Rand, W., Riolo, R. (2005). The Problem with a Self-Adaptive Mutation Rate in Some Environments. https://gpbib.cs.ucl.ac.uk/gecco2005/docs/p1493.pdf (free)
- Real, E., Aggarwal, A., Huang, Y., Le, Q. V. (2019). Regularized Evolution for Image Classifier Architecture Search. https://arxiv.org/pdf/1802.01548 (free)
- Richards, N., Moriarty, D. E., Miikkulainen, R. (1998). Evolving Neural Networks to Play Go. https://nn.cs.utexas.edu/downloads/papers/richards.apin97.pdf (free)
- Risi, S., Togelius, J. (2015). Neuroevolution in Games: State of the Art and Open Challenges. https://arxiv.org/pdf/1410.7326 (free)
- Rosin, C. D., Belew, R. K. (1997). New Methods for Competitive Coevolution. https://cseweb.ucsd.edu/~crosin/newmethods.ps (free)
- Rudolph, G. (2001). Self-Adaptive Mutations May Lead to Premature Convergence. https://ls11-www.cs.tu-dortmund.de/people/rudolph/publications/papers/tec335.pdf (free)
- Runarsson, T. P., Lucas, S. M. (2005). Coevolution versus self-play temporal difference learning for acquiring position evaluation in small-board Go. https://ieeexplore.ieee.org/iel5/4235/32990/01545939.pdf (not free; abstract and secondary sources only)
- Salimans, T., Ho, J., Chen, X., Sidor, S., Sutskever, I. (2017). Evolution Strategies as a Scalable Alternative to Reinforcement Learning. https://arxiv.org/pdf/1703.03864 (free)
- Sauer, P., Cseh, Á., Lenzner, P. (2022). Improving Ranking Quality and Fairness in Swiss-System Chess Tournaments. https://arxiv.org/pdf/2112.10522 (free)
- Schaul, T., Glasmachers, T., Schmidhuber, J. (2011). High Dimensions and Heavy Tails for Natural Evolution Strategies. https://groups.csail.mit.edu/EVO-DesignOpt/gecco2011Proceedings/proceedings/p845.pdf (free)
- Silver, D., Sutton, R., Müller, M. (2007). Reinforcement Learning of Local Shape in the Game of Go. https://webdocs.cs.ualberta.ca/~mmueller/ps/silver-ijcai2007.pdf (free)
- Smith, J. E., Fogarty, T. C. (1996). Self adaptation of mutation rates in a steady state genetic algorithm. https://uwe-repository.worktribe.com/OutputFile/1106226 (not verified)
- Smith, T., Husbands, P., Layzell, P., O'Shea, M. (2002). Fitness landscapes and evolvability. https://neuro.bstu.by/ai/To-dom/My_research/Papers-0/For-research/Needle/1-Fitness-landscape/smith-ec2002.pdf (free)
- Stanley, K. O., Miikkulainen, R. (2002). Evolving Neural Networks through Augmenting Topologies. https://nn.cs.utexas.edu/downloads/papers/stanley.ec02.pdf (free)
- Stanley, K. O., Miikkulainen, R. (2004a). Evolving a Roving Eye for Go. https://nn.cs.utexas.edu/downloads/papers/stanley.gecco04.pdf (free)
- Such, F. P., et al. (2017). Deep Neuroevolution: Genetic Algorithms are a Competitive Alternative for Training Deep Neural Networks for Reinforcement Learning. https://arxiv.org/pdf/1712.06567 (free)
- Sudholt, D. (2021). Analysing the Robustness of Evolutionary Algorithms to Noise. https://eprints.whiterose.ac.uk/156911/1/Sudholt2020_Article_AnalysingTheRobustnessOfEvolut.pdf (free)
- Sung, W., et al. (2012). Drift-barrier hypothesis and mutation-rate evolution. https://www.ncbi.nlm.nih.gov/pmc/articles/PMC3494944/ (abstract only)
- Szubert, M., Jaśkowski, W., Krawiec, K. (2013). On Scalability, Generalization, and Hybridization of Coevolutionary Learning: A Case Study for Othello. https://www.cs.put.poznan.pl/kkrawiec/wiki/uploads/Research/2012TCIAIG.pdf (free)
- Sziklai, B., Biró, P., Csató, L. (2022). The efficacy of tournament designs. https://arxiv.org/pdf/2103.06023 (free)
- Uriot, T., Izzo, D. (2020). Safe Crossover of Neural Networks Through Neuron Alignment. https://arxiv.org/pdf/2003.10306 (free)
- van Nimwegen, E., Crutchfield, J. P., Huynen, M. (1999). Neutral evolution of mutational robustness. https://arxiv.org/pdf/adap-org/9903006 (free)
- Watson, R. A., Pollack, J. B. (2001). Coevolutionary Dynamics in a Minimal Substrate. https://eprints.soton.ac.uk/id/eprint/262011/1/watson_cdms_gecco_2001.pdf (free)
- Whitaker, T., Whitley, D. (2023). Sparse Mutation Decompositions: Fine Tuning Deep Neural Networks with Subspace Evolution. https://arxiv.org/abs/2302.05832 (free)
- Wielgoss, S., et al. (2013). Mutation rate dynamics in a bacterial population reflect tension between adaptation and genetic load. https://www.ncbi.nlm.nih.gov/pmc/articles/PMC3538217/ (abstract only)
- Wilke, C. O., Wang, J. L., Ofria, C., Lenski, R. E., Adami, C. (2001). Evolution of digital organisms at high mutation rates leads to survival of the flattest. http://wexler.free.fr/library/files/wilke%20(2001)%20evolution%20of%20digital%20organisms%20at%20high%20mutation%20rate%20leads%20to%20survival%20of%20the%20flattest.pdf (third-party copy)
- Yao, X., Liu, Y., Lin, G. (1999). Evolutionary Programming Made Faster. https://www.cse.unr.edu/%7Esushil/class/gas/papers/EPMadeFaster.pdf (free)
- SA-MBEANN authors (2024). Improving the performance of mutation-based evolving artificial neural networks with self-adaptive mutations. https://pmc.ncbi.nlm.nih.gov/articles/PMC11249216/ (free; τ formula not verified)