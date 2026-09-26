# The evolving genome

This page explains what a network passes on to its children, how `evolve`
makes a child, and how to read the genome tables in `stats`. The settings
named here are the ones `mise run new-experiment` takes (without arguments
it lists them all).

## Before and after

Before, evolution only touched the weights. Every network kept the
experiment's shape and activations for life, and one fixed set of mutation
numbers applied to every network.

Now each network carries its own genome, and all of it evolves:

| Part | Before | Now |
| --- | --- | --- |
| Weights | evolved | evolved |
| Hidden and output activation | fixed by the experiment | genes, can switch |
| Shape (hidden layers × width) | fixed by the experiment | genes, can grow and shrink |
| Mutation settings | hard-coded, the same for all | five genes per network |

The experiment's settings now give generation 0, the limits, and the rates that drive breeding.

## 1. What a network's genome is

A network's `.ann` file holds everything about it:

- **Weights.** One per connection, plus one bias per neuron.
- **Activations.** One for all hidden layers and one for the output layer.
  Each is one of GENANN's six: `sigmoid`, `sigmoid_cached`, `threshold`,
  `linear`, `tanh`, `relu`. Generation 0 uses `sigmoid_cached` for both.
- **Shape.** The number of hidden layers and their width, written
  `LAYERSxWIDTH` (for example `1x10`). The inputs and outputs are fixed by
  the board: on 9×9, 82 of each (komi plus 81 points in, 81 points plus pass
  out).
- **Five mutation genes**, which decide how its children are mutated:

| Gene | What it does | Starts at (setting, default) | Limits |
| --- | --- | --- | --- |
| `copy_chance` | Chance that a mutated child is an exact copy | `initial_copy_chance`, 0.01 | 0.0001 to 0.1 |
| `weight_changes` | Average number of weights a mutated child changes | `initial_weight_changes`, 0.0004 × generation 0's weights, at least 1 | 1 to the network's total weights |
| `weight_step` | Largest change of one weight (the change is uniform in ±step) | `initial_weight_step`, 0.5 | 0.0001 to 10 |
| `activation_rate` | Chance that each activation switches | `initial_activation_rate`, 0.02 | 0.0001 to 0.5 |
| `structure_rate` | Chance of one change of shape | `initial_structure_rate`, 0.02 | 0.0001 to 0.5 |

The limits are the clamps in `lib/ann.h`: a gene that evolves past one is
set back to it. The settings accept the same ranges.

Example: a 9×9 network of `1x50` has 8,332 weights, so its default
`weight_changes` is 0.0004 × 8,332 ≈ 3.3. A `1x10` network has 1,732
weights; 0.0004 × 1,732 is 0.69, so it starts at the lower limit of 1.

## 2. How `evolve` makes a child

The runner picks two parents by tournament selection (draw
`tournament_size` networks, keep the best; see `CLAUDE.md`) and calls
`evolve`. Each child comes about by exactly one of three operators:

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

A **crossover** child takes the first part of one parent's weights and the
rest from the other, and nothing else changes (section 4). A **copy** is the
parent byte for byte: weights, shape, activations, and genes. A
**mutation** is everything below.

### A mutated child, step by step

The parent's genes decide the copy check and are where the nudge starts.
From then on the child's own, freshly nudged genes drive the rest:

1. **Copy check.** With the parent's `copy_chance` the child is a copy and
   evolve stops here.
2. **Nudge the genes.** Each of the five genes moves a little at random
   (see "meta_rate" below), then is clamped to its limits.
3. **Switch activations.** With the child's `activation_rate`, the hidden
   activation switches to one of the other five, chosen uniformly. The
   output activation gets its own independent chance.
4. **Maybe change shape.** With the child's `structure_rate`, one shape
   change happens (section 3).
5. **Change weights.** Each weight changes with probability
   `weight_changes / total_weights`, by a random amount between
   −`weight_step` and +`weight_step`.

### Why good gene values spread

Step 2 comes before steps 3–5, so a child is made *with the genes it
carries*. If the new genes happened to produce a good child (say a smaller
`weight_step` that did not wreck a good network), that child wins games,
gets picked as a parent, and passes those genes on. Genes that produced a
bad child die out with it. Nobody sets the mutation settings: they ride
along with the networks they helped make. This is called self-adaptation.

The catch: selection on genes is indirect and noisy, so a gene can also
just drift (section 5 shows how to spot it).

### What `meta_rate` does

`meta_rate` (default 0.2, range 0 to 10) sets how far a gene moves per
nudge. The nudge multiplies `weight_changes` and `weight_step` by
e^(0.2 × a standard normal number), so a typical nudge is about ±22%
(e^0.2 ≈ 1.22, e^−0.2 ≈ 0.82):

> A parent that changes 7 weights per child might have a child that changes
> 8 or 6, and rarely 5 or 10.

The three chances move the same way on the log-odds scale, which for small
values like 0.02 is nearly the same ±22%. `meta_rate` 0 freezes the genes.

### Why `weight_changes` is a count, not a rate

The gene says "change about this many weights per child", not "change this
share of the weights". That matters once shapes change:

- With a rate, a network that grows from 8,332 to 20,000 weights would get
  more than twice as many changes per child, without selection asking for
  it. With a count, it keeps the same number.
- A count cannot sink below 1, so a mutated child always expects at least
  one weight change and never quietly turns into a copy.

It is an average, not an exact number. With `weight_changes` 3.3 a child may
change 1, 3, or 6 weights. With 1, about 37% of mutated children change no
weight at all, and unless an activation or the shape changed, they equal
their parent. The Copies column in `stats` counts those too.

## 3. Shape changes

GENANN networks have one width for all hidden layers:

```
 inputs (82)       hidden 1         hidden 2          outputs (82)
 komi, A1 … J9 ──▶ ○ ○ ○ ○ ○ ○ ──▶ ○ ○ ○ ○ ○ ○ ──▶ A1 … J9, pass
                   6 wide            6 wide
                         shape: 2x6
```

So a shape change acts on every hidden layer at once. A mutated child gets
at most one of four changes, chosen uniformly among those the limits allow
(`max_hidden_layers`, default 4; `max_layer_size`, default 200; width at
least 1):

| Change | Allowed when | Play afterwards |
| --- | --- | --- |
| widen | there are hidden layers and width < `max_layer_size` | the same as the parent |
| narrow | there are hidden layers and width > 1 | changed |
| add a layer | layers < `max_hidden_layers` | the same or close (random from 0 layers) |
| remove a layer | layers > 0 | exact for linear, rough otherwise |

### Widen: one more neuron in every hidden layer

```
 before 1x3                 after 1x4
 in ──▶ h1 h2 h3 ──▶ out    in ──▶ h1 h2 h3 h4 ──▶ out
                                            │
                        random weights in,  weight 0 out
```

The new neuron gets random incoming weights (GENANN's starting range, −0.5
to 0.5), but its weights into the next layer are 0. It computes something,
but nothing listens yet, so the outputs stay the same (exactly with clang;
GCC may round the last bit differently). Later weight mutations can
connect it.

### Narrow: one neuron fewer in every hidden layer

Each hidden layer loses one neuron, picked at random per layer, together
with all its weights in and out. This changes the network's play; how much
depends on how much the lost neurons mattered.

### Add a layer: a pass-through layer

A new hidden layer of the same width goes in after the last one. Neuron *i*
of the new layer copies neuron *i* of the layer before (weight 1 from it, 0
from the others, bias 0). The idea is that the child starts out playing
like its parent, so a bigger network gets a fair chance instead of starting
from scratch.

How exact that is depends on the hidden activation, which the new layer
uses too:

- **linear, relu, threshold:** exact. Passing a value through them again
  gives the same value (relu and threshold values are already ≥ 0, and
  threshold's are already 0 or 1).
- **tanh:** close; about 180 of 200 test moves stay the same.
- **sigmoid, sigmoid_cached:** a plain pass-through would squeeze every
  value into 0.5–0.73 and change most moves. Near 0, sigmoid(x) ≈ 0.5 + x/4,
  so the output layer is compensated: its weights from the new layer are
  multiplied by 4 and its biases adjusted to cancel the 0.5. The result is
  close, not exact.

**From no hidden layers**, there is nothing to pass through. The new layer
gets min(`layer_size`, `max_layer_size`) neurons and random weights, and so
do the output rows, so the child plays like a fresh random network.

### Remove a layer: fold it into the outputs

The last hidden layer disappears, and the output layer is rewired to take
its place, treating the removed layer's activation as a straight line
f(x) ≈ c + s·x:

    out = V·f(W·x − b)  ≈  V·(c + s·(W·x − b))  =  (s·V·W)·x + V·(c − s·b)

(GENANN subtracts biases.) So the output layer's new weights are s·V·W, and
the constant part goes into its biases. For linear (c = 0, s = 1) this is
exact up to rounding. relu and tanh use c = 0, s = 1 too, and the sigmoids
and threshold use c = 0.5, s = 1/4; for all but linear the fold is rough,
so a drop in play after a removal is expected. Removing the only hidden
layer connects the outputs straight to the inputs (shape `0x0`).

Adding and then removing a layer gives the parent back exactly for linear,
relu, and tanh, and up to rounding for the sigmoids.

## 4. Crossover and shapes

Crossover cuts both parents' weight lists at one random point:

```
 parent A   a a a a a a|a a a a
 parent B   b b b b b b|b b b b
 child      a a a a a a|b b b b     (activations and genes from A)
```

This only makes sense when each position means the same connection in both
parents, which needs the same shape (same layers and width). So:

- **Same shape:** crossover as above. The child takes the activations and
  genes of the parent whose weights come first (A here, chosen at random),
  and is not mutated. The parents' activations may differ.
- **Different shapes:** if crossover was drawn, the child becomes a
  mutation of the picked parent instead.

As shapes spread in a population, fewer pairs can cross, and more children
are mutations.

## 5. Reading a run

`mise run stats NAME` prints, between the Generations and Benchmark tables,
three genome tables for the latest 10 generations. Each row describes the
networks *of* that generation, from the `births` table.

### Genes

```
| Gen |   Copy | Changes |  Step |   Act | Struct | Layers | Width | Weights |
|   5 | 0.0106 |    1.14 | 0.533 | 0.206 |  0.303 |      1 |    11 |    1897 |
| min |  0.008 |       1 |  0.37 | 0.126 |  0.234 |      1 |    10 |    1732 |
| max | 0.0179 |    1.84 | 0.733 | 0.231 |  0.369 |      2 |    11 |    2029 |
```

One row of **medians** per generation: Copy (`copy_chance`), Changes
(`weight_changes`), Step (`weight_step`), Act (`activation_rate`), Struct
(`structure_rate`), then Layers, Width, and Weights per network. The `min`
and `max` rows give the range in the latest generation.

Watch for a gene that walks to a limit and stays there, for example Copy at
0.1 (a tenth of mutated children would be plain copies) or Step at 10. A
median that wanders and comes back is normal.

### Shapes and activations

```
| Gen | Shapes                    | Hidden                | Output                   |
|   4 | 1x10 10, 1x11 2           | sigc 10, sig 2        | sigc 9, lin 1, relu 1 +1 |
|   5 | 1x11 6, 1x10 4, 2x10 1 +1 | sig 6, sigc 5, tanh 1 | lin 4, sigc 4, sig 2 +2  |
```

The three most common shapes and activations with their counts; `+1` means
one more kind exists. Short names: `sig`, `sigc` (sigmoid_cached), `thr`,
`lin`, `tanh`, `relu`. A new shape or activation that grows from 1–2
networks to many is selection preferring it (here `1x11` went from 2 to 6).
One that appears and vanishes the next generation was tried and lost.

Networks with `threshold` or `relu` outputs often tie, and the engine
passes on a tie, so they pass a lot: selection's problem, not a bug.

### Breeding and bots

```
| Gen | Kids | Childless | Widen | Narrow | Add | Remove | Bots  | Brown  | AmiGo |
|   2 |    7 |         5 |     0 |      0 |   1 |      0 | 1 (0) | 13 (2) | 1 (0) |
```

- **Kids:** most children of one parent of the previous generation. A
  crossover counts for both parents, a mutation or copy for the picked one.
- **Childless:** previous-generation networks with no child. High Kids and
  many Childless mean strong selection pressure: a few networks take over.
  Low Kids and few Childless mean weak pressure. `tournament_size` is the
  knob.
- **Widen, Narrow, Add, Remove:** shape changes that made this generation's
  children.
- **Bots, Brown, AmiGo:** the rank of the best bot (and of each bot's best
  copy) by score, with the number of networks above it in brackets. `1 (0)`
  means the bot tops the ranking. Progress looks like the bracket numbers
  growing: more networks score above the bots.

### CSV columns

`stats NAME --csv` has one row per generation, with every generation (not
just the latest 10). The genome columns: `genes.GENE.min|median|max`,
`shape.layers|width|weights.min|median|max`, `activation.hidden|output.NAME`
(counts for all six), `structure.none|widen|narrow|add_layer|remove_layer`,
`population.operators.initial|crossover|mutation|copy`,
`parents.max_children|childless|used` (`used`: parents with a child), and
`bots.best_rank`, `bots.networks_above`, and the same per bot
(`bots.Brown.best_rank`).

### Digging deeper: the births table

Each network has a row in `births` in `experiments/NAME/experiment.sqlite3`:
`first_parent`, `second_parent` (the same name when selection drew one
network twice), `operator` (`initial`, `crossover`, `mutation`, `copy`),
`parent` (`first` or `second`: the one mutated or copied, or whose weights
come first in a crossover), `structure`, `activation_changed`, and the
genome: `layers`, `width`, `act_hidden`, `act_output`, and the five genes.
`differs_from_first` and `differs_from_second` count weights that differ
from each parent (0 for an identical copy, empty for a parent of another
shape).

Every child whose shape or activations changed:

```sh
sqlite3 -header -column experiments/NAME/experiment.sqlite3 "
  SELECT generation AS gen, child, first_parent, second_parent, parent,
         structure, layers || 'x' || width AS shape, act_hidden, act_output,
         round(weight_changes, 2) AS changes, round(weight_step, 2) AS step
  FROM births
  WHERE structure != 'none' OR activation_changed
  ORDER BY generation, child"
```

```
gen  child   first_parent  second_parent  parent  structure  shape  act_hidden      act_output ...
1    1.ann   0005.ann      0005.ann       second  narrow     1x9    sigmoid_cached  sigmoid_cached
2    0.ann   10.ann        11.ann         second  add_layer  2x10   sigmoid_cached  sigmoid_cached
4    4.ann   0.ann         5.ann          first   widen      1x11   sigmoid         linear
```

## 6. The settings, and a run to try

| Setting | Default | What it controls |
| --- | --- | --- |
| `hidden_layers`, `layer_size` | required | generation 0's shape |
| `max_hidden_layers` | 4 | most hidden layers a network may reach |
| `max_layer_size` | 200 | widest a hidden layer may get |
| `cross_over_rate` | required | chance of trying crossover (0 to 1) |
| `meta_rate` | 0.2 | how fast the genes move |
| `initial_copy_chance` | 0.01 | generation 0's `copy_chance` |
| `initial_weight_changes` | 0.0004 × generation 0's weights, at least 1 | generation 0's `weight_changes` (at most its total weights) |
| `initial_weight_step` | 0.5 | generation 0's `weight_step` |
| `initial_activation_rate` | 0.02 | generation 0's `activation_rate` |
| `initial_structure_rate` | 0.02 | generation 0's `structure_rate` |
| `tournament_size` | 3 | selection pressure when picking parents |

With the defaults, shape changes are rare. In a population of 20 with
`cross_over_rate` 0.5, about 10 children per generation are mutations, and
at a `structure_rate` of 0.02 that makes one shape change every five
generations or so. To see shapes move, start with a much higher rate and
tight limits:

```sh
mise run new-experiment demo --board-size 9 --population-size 12 --hidden-layers 1 --layer-size 10 \
  --cross-over-rate 0.5 --game-length 10 --max-moves 200 --tournament-rounds 3 --keep-every 2 \
  --benchmark-games 2 --initial-structure-rate 0.3 --initial-activation-rate 0.2 \
  --max-hidden-layers 3 --max-layer-size 20 --seed 4242
for i in 1 2 3 4 5 6; do mise run run demo 4 one-generation; done
mise run stats demo
```

That plays generations 0 to 5 in about a minute; the tables in section 5
come from it. It showed widen, narrow, and add-layer changes (no removal),
shapes from `1x9` to `2x11`, and `1x11` spreading to half the population by
generation 5. `weight_changes` starts at its lower limit of 1 here, because
a `1x10` network is small. The same seed gives the same run again on the
same machine; another machine can differ, because the build is tuned to the
local CPU. Delete `experiments/demo` afterwards.

### What a 20-generation default run showed

A seeded run with the default genes and limits (25 Sep 2026: 9×9, 20
networks of `1x50`, 5 rounds, seed 2026) hit no limit, but the medians
moved: `copy_chance` fell from 0.01 to about 0.005 and `activation_rate`
from 0.02 to about 0.01; `structure_rate` rose to 0.04 and fell back to
0.016; `weight_changes` rose from 3.3 to 4.2; and `weight_step` rose to
about 0.74 around generations 14–17 and fell back to 0.48 (all networks:
0.23 to 1.21).

Only three shape changes and seven activation switches happened, and none
spread. Twenty generations cannot tell drift from selection, so this stays
an open question in `PROJECT_NOTES.md`: watch the Genes table in longer
runs, and start with a higher `initial_structure_rate` to explore shapes.
