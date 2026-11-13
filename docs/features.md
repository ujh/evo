# Go features

Without help, a network sees only the stones and komi and has to discover everything about Go by itself: that capturing is good, that a stone in atari should run, that some shapes are strong.
Features give it that knowledge from the start.
[The evolving genome](genes.md) explains the rest of a network's genome.
What a comparison with a stones-only run showed is in [Findings](findings.md#what-a-comparison-showed).

- [Two ways the network uses them](#two-ways-the-network-uses-them)
- [The features](#the-features)
- [Feature groups: the `features` setting](#feature-groups-the-features-setting)
- [The starting values](#the-starting-values)
- [How the feature weights evolve](#how-the-feature-weights-evolve)
- [Reading them in `stats`](#reading-them-in-stats)
- [What the features cost](#what-the-features-cost)

## Two ways the network uses them

The engine computes a few facts for every point of the board ("playing here captures", "this is a hane shape", …) and uses them twice:

- **A: as inputs.** Besides komi and the stones, the network gets one input per point per feature, plus a few board facts (chain liberties, the opponent's last stone, whether the opponent just passed); what it makes of them is up to its evolving weights.
- **B: as feature weights.** After the network has scored every point, each move feature adds its own weight, one per feature and network, to the score of every point where that feature is 1.

Example: the network scores D5 at 0.40 and E5 at 0.45, so on its own it would play E5.
But playing D5 captures a stone (capture = 1 at D5), and this network's capture weight is 1.0, so D5 scores 1.40 and the engine plays D5.

B gives generation 0 good habits at once (capture, run from atari, avoid self-atari), while A lets evolution find more subtle uses.
The pass keeps its own output; B never touches it.

## The features

Every feature looks at the board from the side of the player to move, so it means the same for Black and White.
Every move feature is 0 at a point the engine would not play anyway (illegal, suicide, or filling its own eye).

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

Handicap stones do not count as a last move; benchmark opening stones do, since they arrive as ordinary moves.

### The shapes

The three shape families are the 3×3 patterns MoGo used in its playouts, taken from [michi](https://github.com/pasky/michi) (Petr Baudiš, MIT licence; the credit is in `engine/features.c`).
The candidate point is the centre, marked `*`:

```
X, O   stones of the two colours       .   empty
x      not X (empty, O, or off board)  ?   anything
o      not O (empty, X, or off board)  #   off the board (the edge)
```

Each pattern counts in all 4 rotations, their mirror images, and with the colours swapped, so a hane point is urgent for both sides.
One point can match several families, and then each of their features is 1.

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

## Feature groups: the `features` setting

An experiment's `features` setting says which groups every network gets, for the whole run:

| Group | Move features | Board features | Inputs on 9×9 |
| --- | --- | --- | --- |
| `shapes` | hane, cut, edge | | 243 |
| `tactics` | capture, self_atari, saves_atari | | 243 |
| `last_move` | near_last | last move, opponent passed | 163 |
| `liberties` | | liberties (3 planes) | 243 |

The setting is `all` (the default), `none` (stones and komi only), or a comma-separated list such as `--features tactics,liberties`.
The inputs are always in this order, counting only the planes of the network's groups, so 82 inputs on 9×9 with `none` and 974 with `all`:

```
[komi][stones][move features, one plane each][liberties ×3][last move][opponent passed]
   1     81        7 × 81 = 567                  243           81            1
```

## The starting values

Generation 0's feature weights start from hand-set values: capture +1.0, saves_atari +0.8, self_atari −1.0, and hane, cut, edge and near_last +0.05 each.

Why these sizes: a random network's scores over the legal points spread over about 0.6 to 1.0, but its best and second-best points differ by only 0.02–0.04 on average, and often by less than 0.01.
A weight of about 1 is the whole spread, so it decides the move almost always; a weight of 0.05 is worth a few near-ties, so it breaks close calls without deciding every move.
On generation-0 networks of `1x10`, `1x50` and `1x100` with all groups (1,000 positions from random play per shape), the feature weights changed 63–69 % of the moves, the networks captured 90–95 % of the time they could, saved an atari 81–85 % of the time, and avoided the self-atari in every position where their own favourite was one; the three shape weights alone changed 7–12 % of the moves, `near_last` 5–10 %.

Each network then gets its own copy with some noise: every weight is multiplied by 1 + u, with u drawn uniformly within ±`initial_feature_noise` (default 0.3), so capture starts between 0.7 and 1.3.
The noise is relative, so no sign flips: capture stays good and self-atari bad in generation 0.

## How the feature weights evolve

The feature weights and `feature_step` are genes, inherited and mutated as [The evolving genome](genes.md) describes: a mutated child nudges `feature_step` and then moves **every** feature weight by up to ±`feature_step`, clamped to −10…10.
`feature_step` starts at `initial_feature_step`, 0.01, and stays within 0.0001…1.
So with the defaults a shape weight of 0.05 moves by at most 0.01 per mutation, and capture's 1.0 barely moves: the small weights drift over tens of mutations, and selection keeps the drift that wins games.
Networks without move features (`none`, or `liberties` alone) have no feature weights, and their `feature_step` never moves.

## Reading them in `stats`

With move features, `stats` has a Feature weights table between Genes and Shapes and activations:

```
Feature weights (range: generation 2)
| Gen | Step    | Hane   | Cut    | Edge   | Capture | SelfAtari | SavesAtari | NearLast |
|   0 |    0.01 | 0.0594 | 0.0583 | 0.0551 |   0.955 |     -1.09 |      0.728 |   0.0427 |
|   1 |    0.01 | 0.0594 | 0.0603 | 0.0505 |    1.29 |     -1.14 |      0.626 |   0.0427 |
|   2 |  0.0104 | 0.0565 | 0.0607 | 0.0472 |    1.28 |     -1.15 |      0.622 |    0.041 |
| min | 0.00872 | 0.0491 | 0.0532 | 0.0372 |    1.27 |     -1.15 |      0.606 |   0.0301 |
| max |  0.0137 | 0.0654 | 0.0643 | 0.0639 |     1.3 |    -1.14 |      0.626 |   0.0573 |
```

Each row gives the medians of that generation's networks: Step is `feature_step`, the others the weight each feature adds.
The `min` and `max` rows give the range in the latest generation, and only the experiment's features have a column.
What to look for:

- A median that moves steadily in one direction over many generations: selection likes (or dislikes) that feature more than the start assumed.
- A sign that flips (Capture or SavesAtari below 0, SelfAtari above 0), or a weight that runs to ±10: worth a look at the games.
- A median that only wobbles by a few thousandths: drift, `feature_step` at work without selection pushing.

[The evolving genome](genes.md), "CSV columns", has the feature weights' CSV columns.

## What the features cost

On 9×9 with a hidden layer of 50:

| | `none` | `all` |
| --- | --- | --- |
| Inputs | 82 | 974 |
| Network weights | 8,332 | 52,932 |
| `.ann` file | 67 kB | 424 kB |
| Default `weight_changes` (max(1, 0.0004 × weights)) | 3.3 | 21.2 |
| Arena game (median, 90 games of seeded 1×50 networks) | 0.0003 s | 0.0033 s |
| Per move | about 3 µs | about 37 µs |

The features multiply the arena's move time by about ten, but a game still takes a few milliseconds.
On 19×19 a network with all groups has 4,334 inputs, and 1×50 is 235,212 weights (1.9 MB).
With this many inputs, removing a network's only hidden layer makes it bigger, not smaller: a 9×9 `0x0` network connects all 974 inputs to the 82 outputs, 79,950 weights, against 10,652 for `1x10`.
