# Go features

Without help, a network sees only the stones and komi and has to discover
everything about Go by itself: that capturing is good, that a stone in
atari should run, that some shapes are strong. Features give it that
knowledge from the start. This page explains what the features are, how
the network uses them, how they evolve, how to read them in `stats`, and
what they cost. [The evolving genome](genes.md) explains the rest of a
network's genome.

## Two ways the network uses them

The engine computes a few facts for every point of the board ("playing
here captures", "this is a hane shape", …) and uses them twice:

- **A: as inputs.** Besides komi and the stones, the network gets one
  input per point per feature, plus a few board facts (chain liberties,
  the opponent's last stone, whether the opponent just passed). What the
  network makes of them is up to its weights, which evolve as always.
- **B: as feature weights.** After the network has scored every point,
  each move feature adds its own weight to the score of every point where
  that feature is 1. There is one weight per feature, the same at every
  point, and each network carries its own.

```
score(p) = network(p) + w_hane·hane(p) + w_cut·cut(p) + w_edge·edge(p)
                      + w_capture·capture(p) + w_self_atari·self_atari(p)
                      + w_saves_atari·saves_atari(p) + w_near_last·near_last(p)
```

Example: the network scores D5 at 0.40 and E5 at 0.45, so on its own it
would play E5. But playing D5 captures a stone (capture = 1 at D5), and
this network's `w_capture` is 1.0. D5's score becomes 0.40 + 1.0 = 1.40,
and the engine plays D5.

B gives generation 0 good habits at once (capture, run from atari, avoid
self-atari), while A lets evolution find more subtle uses. The pass keeps
its own output; B never touches it.

## The features

Every feature looks at the board from the side of the player to move, so
it means the same for Black and White. Every move feature is 0 at a point
the engine would not play anyway (illegal, suicide, or filling its own
eye), so no feature ever points at a refused move.

### Move features (inputs and feature weights)

| Feature | Group | 1 when |
| --- | --- | --- |
| `hane` | shapes | the point matches one of the hane shapes below |
| `cut` | shapes | the point matches one of the cut shapes below |
| `edge` | shapes | the point matches one of the edge shapes below |
| `capture` | tactics | playing there captures at least one opponent stone (a ko capture too) |
| `self_atari` | tactics | playing there captures nothing and leaves the new chain with one liberty |
| `saves_atari` | tactics | one of the player's chains in atari has two or more liberties afterwards, by extending or by capturing (the move need not touch the chain) |
| `near_last` | last_move | the point is one of the 8 around the opponent's last stone |

### Board features (inputs only)

| Feature | Group | Inputs | Value |
| --- | --- | --- | --- |
| liberties | liberties | 3 per point | at a stone, +1 (own) or −1 (opponent's) in the first, second, or third plane for a chain with 1, 2, or 3 or more liberties; 0 elsewhere |
| last move | last_move | 1 per point | 1 at the opponent's last stone, else 0 (all 0 after a pass and at the start) |
| opponent passed | last_move | 1 | 1 if the opponent's last move was a pass |

Handicap stones do not count as a last move. Benchmark opening stones do:
they arrive as ordinary moves.

### The shapes

The three shape families are the 3×3 patterns MoGo used in its playouts,
taken from [michi](https://github.com/pasky/michi) (Petr Baudiš, MIT
licence; the credit is in `engine/features.c`). The candidate point is the
centre, marked `*`. Legend:

```
X, O   stones of the two colours       .   empty
x      not X (empty, O, or off board)  ?   anything
o      not O (empty, X, or off board)  #   off the board (the edge)
```

Each pattern counts in all 4 rotations and their mirror images, and with
the colours swapped, so a shape counts whoever is to move: a hane point is
urgent for both sides.

**hane** (4 patterns)

```
enclosing hane   non-cutting hane   magari        katatsuke
  X O X            X O .            X O ?         . O .
  . * .            . * .            X * .         X * .
  ? ? ?            ? . ?            x . ?         . . .
```

**cut** (4 patterns)

```
kiri (unprotected)   kiri (peeped)   de        cut keima
  X O ?                X O ?         ? X ?     O X ?
  O * o                O * X         O * O     o * O
  ? o ?                ? ? ?         o o o     ? ? ?
```

**edge** (5 patterns, the bottom row is off the board)

```
chase     block side cut   block side connection   sagari    side cut
X . ?     O X ?            ? X ?                   ? X O     ? O X
O * ?     X * O            x * O                   x * x     X * O
# # #     # # #            # # #                   # # #     # # #
```

The families overlap: one point can match a hane and a cut at once, and
then both features are 1.

## Feature groups: the `features` setting

The features come in four groups, and an experiment's `features` setting
says which ones every network gets:

| Group | Move features | Board features | Inputs on 9×9 |
| --- | --- | --- | --- |
| `shapes` | hane, cut, edge | | 243 |
| `tactics` | capture, self_atari, saves_atari | | 243 |
| `last_move` | near_last | last move, opponent passed | 163 |
| `liberties` | | liberties (3 planes) | 243 |

The setting is `all` (the default), `none` (stones and komi only, the
networks Evo had before features), or a comma-separated list such as
`--features tactics,liberties`. A network's inputs are always in the same
order:

```
[komi][stones][move features, one plane each][liberties ×3][last move][opponent passed]
   1     81        7 × 81 = 567                  243           81            1
```

counting only the planes of its groups. On 9×9 that is 82 inputs with
`none` and 974 with `all`. The outputs stay the same: one per point plus
pass. One experiment has one feature set; it never changes during a run.

## The starting values

Generation 0's feature weights start from hand-set values:

| Feature | Starting weight |
| --- | --- |
| capture | +1.0 |
| saves_atari | +0.8 |
| self_atari | −1.0 |
| hane, cut, edge, near_last | +0.05 each |

Why these sizes: a random network's scores over the legal points spread
over about 0.6 to 1.0, but its best and second-best points differ by only
0.02–0.04 on average, and often by less than 0.01. A weight of about 1 is the whole spread, so it decides
the move almost always; a weight of 0.05 is worth a few near-ties, so it
breaks close calls without deciding every move.

Measured on generation-0 networks with all groups (step 2.4 of the
features plan; 10 random 9×9 networks per shape, 100 positions from
random play each, 1,000 positions per shape):

| Shape | Captures when it can | Saves an atari when it can | Avoids self-atari* | Plays a shape point (network alone) | Move changed by the feature weights |
| --- | --- | --- | --- | --- | --- |
| 1×10 | 95% | 85% | 100% | 61% (21%) | 63% |
| 1×50 | 91% | 84% | 100% | 62% (23%) | 64% |
| 1×100 | 90% | 81% | 100% | 64% (23%) | 69% |

\* of the positions where the network's own favourite was a self-atari.
The three shape weights alone change 7–12% of the moves, `near_last` 5–10%.

Each network then gets its own copy with some noise: every weight is
multiplied by 1 + u, with u drawn uniformly within
±`initial_feature_noise` (default 0.3), so capture starts between 0.7 and
1.3. The noise is relative, so no sign flips: capture stays good and
self-atari bad in generation 0.

## How the feature weights evolve

The feature weights are genes. A copy keeps them exactly; a crossover
child takes those of the parent whose weights come first. A mutated child
first nudges its gene `feature_step` (as `weight_step` is nudged, by
`meta_rate`), then moves **every** feature weight by a random amount
between −`feature_step` and +`feature_step`, and clamps it to −10…10.
`feature_step` starts at `initial_feature_step`, 0.01, and stays within
0.0001…1.

So with the defaults a shape weight of 0.05 moves by at most 0.01 per
mutation, and capture's 1.0 barely moves at all: the small weights drift
over tens of mutations, and selection keeps the drift that wins games.
Networks without move features (`none`, or `liberties` alone) have no
feature weights, and their `feature_step` never moves.

## Reading them in `stats`

With move features, `stats` has a Feature weights table between Genes and
Shapes and activations:

```
Feature weights (range: generation 2)
+-----+---------+--------+--------+--------+---------+-----------+------------+----------+
| Gen | Step    | Hane   | Cut    | Edge   | Capture | SelfAtari | SavesAtari | NearLast |
+-----+---------+--------+--------+--------+---------+-----------+------------+----------+
|   0 |    0.01 | 0.0594 | 0.0583 | 0.0551 |   0.955 |     -1.09 |      0.728 |   0.0427 |
|   1 |    0.01 | 0.0594 | 0.0603 | 0.0505 |    1.29 |     -1.14 |      0.626 |   0.0427 |
|   2 |  0.0104 | 0.0565 | 0.0607 | 0.0472 |    1.28 |     -1.15 |      0.622 |    0.041 |
+-----+---------+--------+--------+--------+---------+-----------+------------+----------+
| min | 0.00872 | 0.0491 | 0.0532 | 0.0372 |    1.27 |     -1.15 |      0.606 |   0.0301 |
| max |  0.0137 | 0.0654 | 0.0643 | 0.0639 |     1.3 |    -1.14 |      0.626 |   0.0573 |
+-----+---------+--------+--------+--------+---------+-----------+------------+----------+
```

(Generations 0 to 2 of `mise run new-experiment demo --board-size 9
--population-size 4 --hidden-layers 1 --layer-size 10 --cross-over-rate 0.5
--game-length 10 --max-moves 200 --tournament-rounds 1 --keep-every 2
--benchmark-games 2 --seed 3`, then `mise run run demo 4 one-generation`
three times; 26 Sep 2026.)

Each row gives the medians of that generation's networks: Step is
`feature_step`, the others the weight each feature adds. The `min` and
`max` rows give the range in the latest generation. Only the experiment's
features have a column, and without move features there is no table.

What to look for:

- A median that moves steadily in one direction over many generations:
  selection likes (or dislikes) that feature more than the start assumed.
- A sign that flips (Capture or SavesAtari below 0, SelfAtari above 0), or
  a weight that runs to ±10: worth a look at the games.
- A median that only wobbles by a few thousandths: drift, `feature_step`
  at work without selection pushing.

In `stats NAME --csv`, the columns `genes.feature_step.min|median|max` are
filled for every experiment, and `genes.fw_NAME.min|median|max` (for
example `genes.fw_capture.median`) for each of the seven feature weights,
empty where the experiment's groups lack that feature. So experiments with
different feature sets have the same columns and line up in a spreadsheet.
The Weights column of the Genes table counts the feature inputs' weights.

## What the features cost

On 9×9 with a hidden layer of 50:

| | `none` | `all` |
| --- | --- | --- |
| Inputs | 82 | 974 |
| Network weights | 8,332 | 52,932 |
| `.ann` file | 67 kB | 424 kB |
| Default `weight_changes` (0.0004 × weights) | 3.3 | 21.2 |
| Arena game (median, 90 games of seeded 1×50 networks) | 0.0003 s | 0.0033 s |
| Per move | about 3 µs | about 37 µs |

The features multiply the arena's move time by about ten, but a game still
takes a few milliseconds, against about 0.3 s for any game through GoGui
with a bot. The storage grows with the weights: a kept checkpoint of 20
such networks takes about 8.5 MB instead of 1.3 MB. On 19×19 a network
with all groups has 4,334 inputs, and 1×50 is 235,212 weights (1.9 MB).

With this many inputs, removing a network's only hidden layer makes it
bigger, not smaller: a 9×9 `0x0` network connects all 974 inputs to the
82 outputs, 79,950 weights, against 10,652 for `1x10`.

## What a comparison showed

One run with every feature group next to one with `features none`, with
the same settings and seed otherwise (26 Sep 2026, concurrency 4):

```sh
mise run new-experiment NAME --board-size 9 --population-size 20 --hidden-layers 1 --layer-size 50 \
  --cross-over-rate 0.5 --game-length 10 --max-moves 200 --tournament-rounds 5 --keep-every 5 \
  --benchmark-games 10 --features all --seed 2026      # and --features none
for i in $(seq 20); do mise run run NAME 4 one-generation; done
```

Benchmark wins of each checkpoint's top network, out of 10 games per
opponent (5 with each colour):

| Checkpoint | Brown: all | Brown: none | Generation 0's champion: all | none | Previous checkpoint: all | none |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 6 | 0 | | | | |
| 5 | 6 | 4 | 9 | 10 | | |
| 10 | 9 | 3 | 9 | 10 | 5 | 1 |
| 15 | 9 | 5 | 8 | 10 | 5 | 5 |

Against AmiGo and GNU Go level 0, every checkpoint of both runs lost all
10 games, except one win against AmiGo by `none`'s generation 5. Played
against each other in the arena (no openings, so one game per colour),
the `all` run's champion beat the `none` run's in both colours at
generation 15, and in one of two at generation 19.

What that says:

- **The head start is real.** Generation 0 with features already beats
  Brown, which plays at random, 6 times out of 10; without features it
  loses all 10. After 20 generations the feature run still leads (9 to 5).
- **Neither run gets near AmiGo or GNU Go** in 20 generations. The
  features do not change that yet.
- **The feature run improves less on its own start.** Its checkpoints beat
  generation 0's champion 8–9 times out of 10, the stones-only run's all
  10 times: the stones-only generation 0 is so weak that beating it is
  easy. Against the previous checkpoint the feature run wins 5 of 10 at
  both checkpoints, a sign that it stalls between generations 5 and 15;
  the stones-only run wins 1 and then 5.
- **Ten games per opponent are few.** A difference of 9 against 5 wins is
  suggestive, not proof; one seed is one run. More seeds and more games
  would tell (see `PROJECT_NOTES.md`).

How the feature weights moved (medians of the `all` run):

| | Generation 0 | Generation 5 | Generation 19 |
| --- | --- | --- | --- |
| capture | 0.97 | 0.96 | 0.96 |
| self_atari | −0.98 | −1.07 | −1.06 |
| saves_atari | 0.73 | 0.91 | 0.92 |
| hane | 0.048 | 0.051 | 0.054 |
| cut | 0.054 | 0.053 | 0.076 |
| edge | 0.044 | 0.076 | 0.069 |
| near_last | 0.050 | 0.066 | 0.078 |
| `feature_step` | 0.01 | 0.0083 | 0.0050 |

The big moves happen in the first generations, faster than mutation could
make them (at a `feature_step` of 0.01, five generations move a weight by
at most about 0.05): the population descends from a few generation-0
networks whose noise happened to give them a high saves_atari, edge, or
near_last weight. So selection picked among the starting noise, and
whether it picked for those weights or for the networks that carried them
cannot be told apart from one run. After that the weights barely move, and
`feature_step` halves: mutation is not exploring the feature weights much.

Cost in the same runs: a generation took 4.2–4.8 s with features and
4.0–4.6 s without, a checkpoint with its benchmark 17.5–21.2 s and
20.2–21.8 s; the whole run 2.5 min either way, since the games with bots
through GoGui take nearly all the time. The database ended at 52 MB with
features and 8.8 MB without: each kept generation's 20 networks take about
8.5 MB instead of 1.3 MB.
