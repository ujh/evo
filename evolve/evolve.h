/*

MIT License

Copyright (c) 2023 Urban Hafner

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

*/

#include <pcg_variants.h>
#include <stdbool.h>

#include "ann.h"

extern pcg32_random_t rng;

void seed();
// Reads both parents and their genes; exits 1 if either cannot be read.
genann **load_nns(char *ann1_name, char *ann2_name, ann_genes genes[2]);
// Whether the parents can breed at all: the same inputs and outputs. Their
// shapes, activations, and genes may differ.
bool nns_compatible(genann **nns);
void check_nns(genann **nns);
// Whether two networks have the same shape: the same inputs, outputs, hidden
// layers, and width (the width does not count without hidden layers).
bool same_shape(genann const *a, genann const *b);

// The one structural change a mutated child may undergo.
typedef enum {
  STRUCTURE_NONE,
  STRUCTURE_WIDEN,        // one neuron more in every hidden layer
  STRUCTURE_NARROW,       // one neuron less in every hidden layer
  STRUCTURE_ADD_LAYER,    // a pass-through layer after the last hidden one
  STRUCTURE_REMOVE_LAYER, // the last hidden layer folded into the output
} structure_change;

// The name the summary line uses: none, widen, narrow, add_layer, or
// remove_layer.
const char *structure_name(structure_change change);

// The bounds on a child's shape: at most max_hidden_layers hidden layers of
// 1 to max_layer_size neurons. A layer added to a network without hidden
// layers has add_layer_size neurons.
typedef struct {
  int max_hidden_layers;
  int max_layer_size;
  int add_layer_size;
} shape_bounds;

// Stores in changes, in enum order, the structural changes the bounds allow
// for the network, and returns how many: widen below max_layer_size, narrow
// above width 1 (both only with hidden layers), add_layer below
// max_hidden_layers, remove_layer above 0 layers.
int allowed_structure_changes(genann const *ann, shape_bounds const *bounds, structure_change changes[4]);

// The structural operators. Each returns a new network with the parent's
// activations and leaves the parent alone. They draw only what is said
// below: widen its new neurons' weights in weight order, narrow one neuron
// index per layer in order, add_layer its random weights (only without
// hidden layers), remove_layer nothing.
// Appends a neuron to every hidden layer. Its incoming weights are random in
// GENANN's initial range, [-0.5, 0.5); its weights into the next layer's
// other neurons and into the outputs are 0, so the outputs stay the same up
// to rounding (a compiler may reorder the longer sums).
genann *widen(genann const *parent);
// Removes from every hidden layer a neuron drawn uniformly, independently per
// layer, with its row and its column in the next layer. Needs width 2.
genann *narrow(genann const *parent);
// Inserts a layer after the last hidden one. With hidden layers it passes the
// last one through: same width, bias 0, weight 1 from the neuron at the same
// position and 0 from the others. For the sigmoid activations, whose pass-
// through squeezes values, the output rows are compensated by the straight
// line sigmoid(x) ≈ 0.5 + x/4: V' = 4V, B' = B + 2ΣV. Without hidden layers
// the new layer has add_layer_size neurons, and it and the output rows get
// random weights.
genann *add_layer(genann const *parent, int add_layer_size);
// Removes the last hidden layer by folding it into the output rows, taking
// its activation f as the straight line f(x) ≈ c + s·x: c = 0 and s = 1 for
// linear, relu, and tanh; c = 0.5 and s = 1/4 for the sigmoids and
// threshold. Exact only for linear (up to rounding). Draws nothing.
genann *remove_layer(genann const *parent);

// What happened to a mutated child besides its weights.
typedef struct {
  bool copy;               // an exact copy of the parent, genes included
  bool activation_changed; // an activation switched
  structure_change structure;
} mutation_outcome;

// Both store in *picked which parent (0 or 1) the child is built from: the
// one mutated, or the one whose weights come first in a crossover. A
// crossover child has that parent's activations. Crossover needs parents of
// the same shape.
genann *child_from_cross_over(genann **nns, int *picked);
// Stores the child's genes in *child_genes and, unless outcome is NULL,
// what happened in *outcome.
genann *child_from_mutation(genann **nns, ann_genes const genes[2], double meta_rate,
                            shape_bounds const *bounds, int *picked, ann_genes *child_genes,
                            mutation_outcome *outcome);
genann *cross_over(genann *first_parent, genann *second_parent, int cross_over_point);

// How a child came about.
typedef struct {
  const char *operator_name; // crossover, mutation, or copy
  int picked;                // the parent it is built from, 0 or 1
  mutation_outcome outcome;  // all false and none for a crossover
  ann_genes genes;           // the child's
} breeding;

// A child of two compatible parents: with probability cross_over_rate a
// crossover, if the parents have the same shape; otherwise, or when their
// shapes differ, a mutation of the picked parent. Stores how in *result.
genann *breed(genann **nns, ann_genes const genes[2], double cross_over_rate, double meta_rate,
              shape_bounds const *bounds, breeding *result);

// A standard normal draw from the PCG generator, by Box-Muller.
double standard_normal(void);
// The genes mutated by meta rate τ: weight_changes and weight_step
// log-normally, g·exp(τ·N(0,1)), the probabilities on the logit scale,
// logit⁻¹(logit(p) + τ·N(0,1)), in the struct's order, then clamped to their
// ranges (weight_changes to at most total_weights).
ann_genes mutate_genes(ann_genes genes, double meta_rate, int total_weights);
// With probability activation_rate each, the hidden and then the output
// activation is replaced by one of the other activations in ANN_ACTIVATIONS,
// chosen uniformly. Returns whether either switched.
bool mutate_activations(genann *child, double activation_rate);
// A mutated copy of the parent. With the parent's copy_chance the child is an
// exact copy, genes included. Otherwise its genes mutate first, then its
// activations switch with the new activation_rate, then with the new
// structure_rate it undergoes one structural change, chosen uniformly among
// those the bounds allow (no draw when none is allowed, and none at all when
// bounds is NULL), and then each weight changes with probability
// weight_changes / total_weights by a uniform amount in [-weight_step,
// +weight_step] of the new genes, weight_changes clamped against the child's
// final total_weights. Unless outcome is NULL, stores in *outcome what
// happened.
genann *mutate(genann const *parent, ann_genes const *parent_genes, double meta_rate,
               shape_bounds const *bounds, ann_genes *child_genes, mutation_outcome *outcome);
