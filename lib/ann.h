/*
 * Evo's layer over GENANN. genann.c and genann.h are upstream GENANN v1.1.1
 * (https://github.com/codeplea/genann, tag v1.1.1), unchanged, so an update
 * is a plain copy; everything Evo adds lives here and in ann.c. Include this
 * header, not genann.h.
 */

#ifndef ANN_H
#define ANN_H

#include <math.h>
#include <stdio.h>
#include <pcg_variants.h>

// GENANN draws its random weights through this macro. PCG makes them
// reproducible from a seed (pcg32_srandom), as the pcg-random library
// suggests for doubles in [0, 1).
#define GENANN_RANDOM() (ldexp(pcg32_random(), -32))

#include "genann.h"

// The .ann format (version 2) holds everything a GENANN network is, plus
// its genes and its features: the magic "EVOANN", a uint32 format version
// (2), the int32 sizes inputs, hidden_layers, hidden, and outputs (hidden is
// 0 when hidden_layers is 0), a uint32 code for the hidden and then the
// output activation, the genes as five IEEE 754 doubles in ann_genes' order,
// a uint32 mask of feature groups (ANN_GROUP_* bits, 0 for none),
// feature_step as a double, the groups' F feature weights as doubles (F =
// ann_feature_count), and the weights as IEEE 754 doubles: 86 + 8 F + 8 x
// total_weights bytes. Every number is little-endian, so a file reads the
// same on any machine. The codes are ANN_ACTIVATIONS' positions plus one.
// Every network plays one square board of ANN_MIN_SIDE to ANN_MAX_SIDE
// points a side: its outputs are the points plus pass, and its inputs the
// feature set's layout (ann_layout_inputs) on that board.

// The settings a network passes on to its children, which evolve with it.
typedef struct {
    double copy_chance;     // probability that a child is an unchanged copy
    double weight_changes;  // expected number of weights a mutation changes
    double weight_step;     // half-width of a weight's uniform perturbation
    double activation_rate; // probability of switching each activation
    double structure_rate;  // probability of one structural change
} ann_genes;

// The range each gene is clamped to. weight_changes runs from
// ANN_WEIGHT_CHANGES_MIN to the network's total_weights.
#define ANN_COPY_CHANCE_MIN 1e-4
#define ANN_COPY_CHANCE_MAX 0.1
#define ANN_WEIGHT_CHANGES_MIN 1.0
#define ANN_WEIGHT_STEP_MIN 1e-4
#define ANN_WEIGHT_STEP_MAX 10.0
#define ANN_ACTIVATION_RATE_MIN 1e-4
#define ANN_ACTIVATION_RATE_MAX 0.5
#define ANN_STRUCTURE_RATE_MIN 1e-4
#define ANN_STRUCTURE_RATE_MAX 0.5

// The genes of a network before any evolution, for one with total_weights
// weights: weight_changes is 0.0004 per weight, at least 1.
ann_genes ann_default_genes(int total_weights);

// The name of the first gene that is not finite or lies outside its range
// for a network of total_weights weights, or NULL when all are valid.
const char *ann_genes_invalid(ann_genes const *genes, int total_weights);

typedef struct {
    const char *name;
    genann_actfun function;
} ann_activation;

// Every activation GENANN offers, in code order.
extern const ann_activation ANN_ACTIVATIONS[];
extern const int ANN_ACTIVATION_COUNT;

// The activation's name, or NULL for a function GENANN does not offer.
const char *ann_activation_name(genann_actfun function);

// Prints the network's machine-readable genes line: "genes layers=L width=W
// act_hidden=NAME act_output=NAME" and each gene as NAME=%.17g in ann_genes'
// order. The width is 0 without hidden layers, as in the file.
void ann_print_genes_line(FILE *out, genann const *ann, ann_genes const *genes);

// The feature groups a network can see besides the stones and komi, as
// bits of a mask. Each group adds inputs, in this layout on a board of N
// points: [komi][N stones][F x N move features][3 x N liberties]
// [N last_move][opponent_passed], only the groups present, where the F move
// features are, in order, shapes' hane, cut, and edge, tactics' capture,
// self_atari, and saves_atari, and last_move's near_last. liberties adds its
// 3 planes and no move feature; last_move adds near_last, its plane, and
// the one opponent_passed input. The engine's features.c computes them.
#define ANN_GROUP_SHAPES 1u
#define ANN_GROUP_TACTICS 2u
#define ANN_GROUP_LAST_MOVE 4u
#define ANN_GROUP_LIBERTIES 8u
#define ANN_GROUPS_ALL 15u

// The number of move features F of the groups, or -1 when the mask has a
// bit that is no group.
int ann_feature_count(unsigned groups);
// The number of inputs of a network with the groups on a board of `points`
// points, or -1 when the mask has a bit that is no group.
int ann_layout_inputs(unsigned groups, int points);

// The smallest and largest board side a network can be for. They equal
// Brown's MIN_BOARD and MAX_BOARD, which the engine checks at compile time.
#define ANN_MIN_SIDE 2
#define ANN_MAX_SIDE 23

// The most move features any feature set has: F for ANN_GROUPS_ALL.
#define ANN_MAX_FEATURES 7

typedef struct {
    const char *name;
    unsigned group;      // the ANN_GROUP_* bit it belongs to
    double start_weight; // its weight in a network before any evolution
} ann_feature;

// Every move feature, in the layout's order (see the groups above). A
// feature set's features are those of its groups, in this order. The
// starting weights: capture, saves_atari, and self_atari about a random
// network's whole spread of scores, the others a few near-ties' worth.
extern const ann_feature ANN_FEATURES[ANN_MAX_FEATURES];

// A network's features, which evolve with it: its groups, the gene
// feature_step, and one weight per move feature of the groups, in
// ANN_FEATURES' order (weights[0 .. F-1]; the rest are 0 and unused).
typedef struct {
    unsigned groups;
    double feature_step; // half-width of a feature weight's perturbation
    double weights[ANN_MAX_FEATURES];
} ann_features;

// The range each feature weight and feature_step is clamped to.
#define ANN_FEATURE_WEIGHT_MIN -10.0
#define ANN_FEATURE_WEIGHT_MAX 10.0
#define ANN_FEATURE_STEP_MIN 1e-4
#define ANN_FEATURE_STEP_MAX 1.0

// The features of a network with the groups before any evolution:
// feature_step 0.01 and each feature's start_weight.
ann_features ann_default_features(unsigned groups);

// What is wrong with the features ("groups" for a bit that is no group,
// "feature_step", or the name of a feature whose weight is not finite or
// out of range), or NULL when they are valid.
const char *ann_features_invalid(ann_features const *features);

// Returns NULL, after printing why, when the file does not hold a network
// with valid genes and features that fits a board. Stores the genes in
// *genes and the features in *features unless either is NULL.
genann *ann_binary_read(FILE *in, ann_genes *genes, ann_features *features);
// Returns 0, or -1 after printing why: an activation the format has no code
// for, genes or features that are missing or invalid, or a failed write.
int ann_binary_write(genann const *ann, ann_genes const *genes, ann_features const *features, FILE *out);

#endif
