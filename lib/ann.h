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

// The .ann format holds everything a GENANN network is, plus its genes: the
// magic "EVOANN", a uint32 format version (1), the int32 sizes inputs,
// hidden_layers, hidden, and outputs (hidden is 0 when hidden_layers is 0),
// a uint32 code for the hidden and then the output activation, the genes as
// five IEEE 754 doubles in ann_genes' order, and the weights as IEEE 754
// doubles. Every number is little-endian, so a file reads the same on any
// machine. The codes are ANN_ACTIVATIONS' positions plus one.

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

// Returns NULL, after printing why, when the file does not hold a network
// with valid genes. Stores the genes in *genes unless genes is NULL.
genann *ann_binary_read(FILE *in, ann_genes *genes);
// Returns 0, or -1 after printing why: an activation the format has no code
// for, genes that are missing or invalid, or a failed write.
int ann_binary_write(genann const *ann, ann_genes const *genes, FILE *out);

#endif
