# The evolving genome

This page explains what a network passes on to its children, how `evolve` makes a child, and how to read the genome tables in `stats`.
`mise run new-experiment` without arguments lists every setting named here with its range and default.

- [What a network's genome is](#what-a-networks-genome-is)
- [How `evolve` makes a child](#how-evolve-makes-a-child)
- [Shape changes](#shape-changes)
- [Crossover and shapes](#crossover-and-shapes)
- [Reading a run](#reading-a-run)
- [The settings, and a run to try](#the-settings-and-a-run-to-try)

## What a network's genome is

A network's `.ann` file holds all of it, and all of it can evolve except the feature groups:

- **Weights.** One per connection, plus one bias per neuron; mutation changes them, crossover mixes them.
- **Activations.** One for all hidden layers and one for the output layer, each one of GENANN's six: `sigmoid`, `sigmoid_cached` (generation 0's), `threshold`, `linear`, `tanh`, `relu`.
- **Shape.** The number of hidden layers and their width, written `LAYERSxWIDTH` (for example `1x10`).
  The board and the feature groups fix the inputs and outputs: on 9×9, 82 outputs (81 points plus pass) and 974 inputs with every feature group, 82 with `features none`.
- **Features.** The experiment's feature groups (one experiment has one set, and `evolve` refuses parents with different groups), the gene `feature_step`, and one weight per move feature; [Go features](features.md) explains them.
- **Five mutation genes**, which decide how its children are mutated:

| Gene | What it does | Starts at (setting, default) | Limits |
| --- | --- | --- | --- |
| `copy_chance` | Chance that a mutated child is an exact copy | `initial_copy_chance`, 0.01 | 0.0001 to 0.1, or exactly 0 |
| `weight_changes` | Average number of weights a mutated child changes | `initial_weight_changes`, 0.0004 × generation 0's weights (feature inputs included), at least 1 | 1 to the network's total weights |
| `weight_step` | Largest change of one weight (uniform in ±step) | `initial_weight_step`, 0.5 | 0.0001 to 10 |
| `activation_rate` | Chance that each activation switches | `initial_activation_rate`, 0.02 | 0.0001 to 0.5 |
| `structure_rate` | Chance of one change of shape | `initial_structure_rate`, 0.02 | 0.0001 to 0.5 |

The limits are the clamps in `lib/ann.h`: a gene that evolves past one is set back to it, and the settings accept the same ranges.
Example: a 9×9 `1x50` network with every feature group has 52,932 weights, so its default `weight_changes` is 0.0004 × 52,932 ≈ 21.2.

The file is a header (the format version, the sizes, and the two activations), the five genes, the features, then the weights: 86 bytes plus 8 per feature weight plus 8 per weight (`docs/code-reference.md` has the byte layout).

`copy_chance` 0 means "never copy": every child keeps 0 under any `meta_rate`, and nothing between 0 and 0.0001 is accepted.
Such a run can still breed an exact clone: the two parents are drawn independently, with replacement, and a crossover child of one network with itself is that network.
With a size-3 tournament over N networks whose scores all differ, that happens to 1.8/N of the children drawn for crossover (0.18 % of 1,000; ties make it rarer).

## How `evolve` makes a child

For each child it breeds, the runner picks two parents by tournament selection (draw `tournament_size` networks of the previous generation, elites included, and keep the best) and calls `evolve`.
Each bred child comes about by exactly one of three operators:

```
                    draw: crossover? (cross_over_rate)
                     /                          \
                   yes                           no
                   /                              \
      same shape? ─── no ──────────────▶  mutate one parent
          |                                        |
         yes                           copy? (parent's copy_chance)
          |                               /              \
      CROSSOVER                         yes               no
  (not mutated at all)                  COPY           MUTATION
```

A **crossover** child mixes the parents' weights and nothing else ([Crossover and shapes](#crossover-and-shapes)).
A **copy** is the parent byte for byte: weights, shape, activations, genes, and features.
A **mutation** is everything below.

With `elite_share` above 0, the last E places of a generation are not bred: they are **elites**, the first E networks of the previous generation's final ranking (bots skipped, the champion first), copied byte for byte by the runner without `evolve` (operator `elite` in `births`).
E is `elite_share` × `population_size`, rounded, at least 1 when the share is above 0 and at most `population_size` − 1 (`Elitism.count`).
An elite is no copy: rank chose it, not tournament selection and `copy_chance`.
The places before the elites are bred with the same seeds and parent draws as without elitism.

### A mutated child, step by step

The parent's genes decide the copy check and are where the nudge starts; from then on the child's own, freshly nudged genes drive the rest:

1. **Copy check.** With the parent's `copy_chance` the child is a copy, and `evolve` stops.
2. **Nudge the genes.** Each of the five genes moves a little at random ([What `meta_rate` does](#what-meta_rate-does)) and is clamped to its limits.
3. **Nudge the feature weights** (only with move features).
   `feature_step` moves like `weight_step`, then **every** feature weight moves by a random amount within ±the new `feature_step`, clamped to −10 to 10.
4. **Switch activations.** With the child's `activation_rate`, the hidden activation switches to one of the other five; the output activation gets its own chance.
5. **Maybe change shape.** With the child's `structure_rate`, one [shape change](#shape-changes) happens.
6. **Change weights.** Each weight changes with probability `weight_changes / total_weights`, by a random amount within ±`weight_step`.

### Why good gene values spread

Steps 2 and 3 come before steps 4–6, so a child is made *with the genes it carries*.
If the new genes happened to produce a good child (say a smaller `weight_step` that did not wreck a good network), that child wins games, gets picked as a parent, and passes those genes on; genes that produced a bad child die out with it.
Nobody sets the mutation settings: they ride along with the networks they helped make (self-adaptation).
The catch: selection on genes is indirect and noisy, so a gene can also just drift.

### What `meta_rate` does

`meta_rate` (default 0.2) sets how far a gene moves per nudge.
The nudge multiplies `weight_changes`, `weight_step` and `feature_step` by e^(`meta_rate` × a standard normal number), at 0.2 a typical nudge of about ±22 %: a parent that changes 7 weights per child might have a child that changes 8 or 6, and rarely 5 or 10.
The three chances move the same way on the log-odds scale, which for small values like 0.02 is nearly the same.
`meta_rate` 0 freezes the genes, bit for bit (`docs/findings.md`, "Fixed mutation genes", has the runs).

### Why `weight_changes` is a count, not a rate

The gene says "change about this many weights per child", not "change this share", so a network that grows from 52,932 to 100,000 weights keeps its number of changes per child instead of doubling it without selection asking.
The count never falls below 1, so a mutated child expects at least one weight change.
It is an average: with `weight_changes` 3.3 a child may change 1, 3, or 6 weights, and with 1, about 37 % of mutated children change no network weight at all.
Such a child is no copy: with move features (any group but `liberties` alone) its feature weights all moved, and at a `meta_rate` above 0 its genes did too, unless a clamp held them.
At `meta_rate` 0 without move features, such a child with no activation or shape change equals its parent.

## Shape changes

GENANN networks have one width for all hidden layers, so a shape change acts on every hidden layer at once.
A mutated child gets at most one of four changes, chosen uniformly among those the limits allow (`max_hidden_layers` defaults to 4, `max_layer_size` to 200):

- **Widen** (while width < `max_layer_size`) adds a neuron to every hidden layer, with random incoming weights but weights of 0 into the next layer: it computes something, but nothing listens yet, so the outputs stay the same until later weight mutations connect it.
- **Narrow** (while width > 1) removes one neuron per hidden layer, picked at random, with its weights, and changes play by as much as those neurons mattered.
- **Add a layer** (while layers < `max_hidden_layers`) puts a pass-through layer of the same width after the last one: neuron *i* copies neuron *i* of the layer before (weight 1 from it, 0 from the others, bias 0), so the bigger child starts out playing like its parent.
  That is exact for linear, relu and threshold, close for tanh (about 180 of 200 test moves stay the same), and close for the sigmoids, whose squeeze the output layer compensates (sigmoid(x) ≈ 0.5 + x/4 near 0, so its weights from the new layer are multiplied by 4 and its biases adjusted).
  From no hidden layers there is nothing to pass through: the new layer of min(`layer_size`, `max_layer_size`) neurons and the output rows get random weights, so the child plays like a fresh random network.
- **Remove a layer** (while there are any) drops the last hidden layer and folds it into the outputs, treating its activation as a straight line f(x) ≈ c + s·x, so out = V·f(W·x − b) ≈ (s·V·W)·x + V·(c − s·b).
  That is exact up to rounding for linear and rough for the others, so a drop in play after a removal is expected.
  Removing the only hidden layer connects the outputs straight to the inputs (shape `0x0`).

## Crossover and shapes

Crossover cuts both parents' weight lists at one random point:

```
 parent A   a a a a a a|a a a a
 parent B   b b b b b b|b b b b
 child      a a a a a a|b b b b     (activations and genes from A)
```

That only makes sense when each position means the same connection in both parents, which needs the same shape.
So with the same shape the child takes the first part from the parent picked at random (A here), with its activations, genes, feature weights and `feature_step`, and is not mutated.
With different shapes, a drawn crossover becomes a mutation of the picked parent, so as shapes spread fewer pairs can cross.

## Reading a run

`mise run stats NAME` prints, between the Generations and Benchmark tables, the genome tables for the latest 10 generations (four, or three without move features).
Each row describes the networks *of* that generation, from the `births` table.

### Genes

```
| Gen | Copy    | Changes | Step  | Act   | Struct | Layers | Width | Weights |
|   5 |  0.0089 |    4.12 | 0.618 | 0.206 |  0.259 |      1 |    10 |   10652 |
| min | 0.00666 |    2.56 | 0.472 |  0.13 |  0.191 |      0 |     0 |    9595 |
| max |  0.0119 |    8.61 |  1.02 | 0.265 |  0.368 |      1 |    11 |   79950 |
```

One row of **medians** per generation: the five genes, then Layers, Width, and Weights (feature inputs included).
The `min` and `max` rows give each column's range in the latest generation, so a row need not be one network: the most weights, 79,950, belong to `0x0` networks, whose 974 inputs connect straight to the 82 outputs.
Watch for a gene that walks to a limit and stays there, such as Copy at 0.1 (a tenth of mutated children plain copies) or Step at 10; a median that wanders and comes back is normal.

### Feature weights

The same rows for `feature_step` and each move feature's weight, with move features only; [Go features](features.md#reading-them-in-stats) shows the table and what to look for.

### Shapes and activations

```
| Gen | Shapes                   | Hidden                   | Output                  |
|   3 | 1x10 8, 0x0 2, 1x11 1 +1 | sigc 9, lin 1, relu 1 +1 | thr 6, sigc 5, lin 1    |
|   4 | 1x10 6, 0x0 5, 3x10 1    | sigc 8, relu 1, sig 1 +2 | thr 7, sigc 3, lin 1 +1 |
```

The three most common shapes and activations with their counts; `+1` means one more kind exists.
One that grows from 1–2 networks to many is selection preferring it (here `0x0` from 2 to 5, threshold outputs from 3 to 7); one that appears and vanishes was tried and lost.
Networks with `threshold` or `relu` outputs often tie, and the engine passes on a tie, so they pass a lot: selection's problem, not a bug.

### Breeding and bots

```
| Gen | Kids | Childless | Widen | Narrow | Add | Remove | Bots  | Brown  | AmiGo |
|   3 |    5 |         5 |     1 |      0 |   0 |      2 | 1 (0) | 14 (4) | 1 (0) |
```

- **Kids** is the most bred children of one previous-generation network (a crossover counts for both parents, an elite for none), **Childless** the networks with no bred child.
  High Kids and many Childless mean strong selection pressure, a few networks taking over; `tournament_size` is the knob.
- **Widen, Narrow, Add, Remove** count the shape changes among the bred children.
- **Bots** and each bot's column give the rank of the best bot copy, with the number of networks above it in brackets; progress is the brackets growing.
  The best of many bot copies often tops the ranking anyway, so read the next table too.

### Networks against bots

```
| Gen | Brown       | AmiGo       | MichiWeak  | MichiMid  | MichiStrong | GnuGo    |
|  85 |   44/46 96% |   20/90 22% |  15/48 31% |   2/42 5% |     0/40 0% |  0/18 0% |
```

Per bot, the tournament games between a network and a copy of that bot, and the share the network won.
A generation has some dozens of games per bot, so read the trend over several rows.
The tournament pairs players of similar scores, so these are the networks near the bot's score: a share is no strength estimate, the benchmark is.

### Copies

The Generations table's Copies column is the share of bred children identical to a parent by network weights and activations (`ExperimentStats#identical?`): every copy, and any mutation or crossover child with a parent's activations and a differs count of 0 against it.
It compares neither genes nor feature weights, so it counts the mutation children that changed no network weight, whose feature weights and genes may differ from the parent's ([Why `weight_changes` is a count, not a rate](#why-weight_changes-is-a-count-not-a-rate)).
It leaves out the elites, which are not bred.
`docs/analysis-scripts.md`, "Gene trajectories and clones", tells the exact clones apart.

### CSV columns

`stats NAME --csv` has one row per generation, for every generation, with columns named by table and value, such as `genes.weight_step.median`, `activation.hidden.relu`, `structure.add_layer`, `parents.childless` and `against_bots.AmiGo.wins`.
`genes.feature_step.*` and the seven `genes.fw_NAME.*` columns exist in every experiment, empty where it lacks the feature, so experiments with different feature sets line up.

### Digging deeper: the births table

Each network has a row in `births` in `experiments/NAME/experiment.sqlite3`: `first_parent`, `second_parent` (the same name when selection drew one network twice), `operator` (`initial`, `crossover`, `mutation`, `copy`, `elite`; an elite has its one parent as `first_parent`), `parent` (`first` or `second`: the one mutated or copied, or whose weights come first in a crossover), `structure`, `activation_changed`, and the genome: `layers`, `width`, `act_hidden`, `act_output`, the five genes, `features` (the groups, or `none`), `feature_step`, and one column per feature weight (`fw_hane`, `fw_cut`, `fw_edge`, `fw_capture`, `fw_self_atari`, `fw_saves_atari`, `fw_near_last`), empty when the network's groups lack that feature.
`differs_from_first` and `differs_from_second` count the network weights that differ from each parent (0 for an identical copy, empty for a parent of another shape); they leave the feature weights out.

Every child whose shape or activations changed:

```sh
sqlite3 -header -column experiments/NAME/experiment.sqlite3 "
  SELECT generation AS gen, child, first_parent, second_parent, parent,
         structure, layers || 'x' || width AS shape, act_hidden, act_output
  FROM births WHERE structure != 'none' OR activation_changed
  ORDER BY generation, child"
```

## The settings, and a run to try

`mise run new-experiment` without arguments lists every setting with its range and default.
With the defaults, shape changes are rare: in a population of 20 with `cross_over_rate` 0.5, about 10 children per generation are mutations, and at a `structure_rate` of 0.02 that is one shape change every five generations or so.
To see shapes move, start with a much higher rate and tight limits:

```sh
mise run new-experiment demo --board-size 9 --population-size 12 --hidden-layers 1 --layer-size 10 \
  --cross-over-rate 0.5 --game-seconds 600 --max-moves 200 --tournament-rounds 3 --keep-every 2 \
  --benchmark-games 2 --benchmark-bot-games 0 --initial-structure-rate 0.3 --initial-activation-rate 0.2 \
  --max-hidden-layers 3 --max-layer-size 20 --seed 4242
for i in 1 2 3 4 5 6; do mise run run demo --concurrency 4 --one-generation; done
mise run stats demo
```

The Genes, Shapes and activations, and Breeding examples above come from a run of it on 26 Sep 2026, which showed all four kinds of shape change, shapes from `0x0` to `3x10`, and networks without a hidden layer spreading to 5 of 12 by generation 4.
The same seed gives the same run again on the same machine and code; another machine can differ, because the build is tuned to the local CPU.
Delete `experiments/demo` afterwards.

What a 20-generation run with the default genes showed is in [Findings](findings.md#what-a-20-generation-default-run-showed).
