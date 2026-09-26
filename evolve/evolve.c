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
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "evolve.h"
#include "ann.h"

pcg32_random_t rng;

void seed() {
  pcg32_srandom(time(NULL), (intptr_t)&rng);
}

// Exits with an error, instead of returning NULL, when the file cannot be
// opened or does not hold a network.
static genann *load_nn(char *name, ann_genes *genes, ann_features *features) {
  printf("Loading %s ...", name);
  FILE *fd = fopen(name, "rb");
  if (fd == NULL) {
    fprintf(stderr, "\nCould not open %s: %s\n", name, strerror(errno));
    exit(1);
  }
  genann *ann = ann_binary_read(fd, genes, features);
  fclose(fd);
  if (ann == NULL) {
    fprintf(stderr, "\nCould not read a network from %s\n", name);
    exit(1);
  }
  printf("\n");
  return ann;
}

genann **load_nns(char *ann1_name, char *ann2_name, ann_genes genes[2], ann_features features[2]) {
  genann **anns = malloc(2 * sizeof(genann *));
  anns[0] = load_nn(ann1_name, &genes[0], &features[0]);
  anns[1] = load_nn(ann2_name, &genes[1], &features[1]);
  return anns;
}

// Prints each difference between the parents that makes them impossible to
// breed, and returns whether there was none. Shapes, activations, and genes
// do not count: parents of different shapes only cannot cross over.
bool nns_compatible(genann **nns) {
  genann *nn1 = nns[0];
  genann *nn2 = nns[1];
  bool failed = false;

  if (nn1->inputs != nn2->inputs) {
    printf("nn1.inputs = %d, nn2.inputs = %d\n", nn1->inputs, nn2->inputs);
    failed = true;
  }
  if (nn1->outputs != nn2->outputs) {
    printf("nn1.outputs = %d, nn2.outputs = %d\n", nn1->outputs, nn2->outputs);
    failed = true;
  }
  return !failed;
}

bool same_shape(genann const *a, genann const *b) {
  return a->inputs == b->inputs
    && a->outputs == b->outputs
    && a->hidden_layers == b->hidden_layers
    && (a->hidden_layers == 0 || a->hidden == b->hidden);
}

void check_nns(genann **nns) {
  if (!nns_compatible(nns)) {
    printf("Sanity check failed!\n");
    exit(1);
  }
  printf("Sanity check passed\n");
}

genann *child_from_cross_over(genann **nns, int *picked) {
  // Pick order in which to use the NNs
  int i = pcg32_boundedrand(2);
  *picked = i;
  genann *first_parent = nns[i];
  genann *second_parent = nns[(i+1) % 2];
  // Find weight at which to cross over
  int cross_over_point = pcg32_boundedrand(first_parent->total_weights);
  // Do the cross over
  return cross_over(first_parent, second_parent, cross_over_point);
}

genann *cross_over(genann *first_parent, genann *second_parent, int cross_over_point) {
  genann *child = genann_copy(first_parent);
  for (int ci = cross_over_point; ci < first_parent->total_weights; ci++) {
    child->weight[ci] = second_parent->weight[ci];
  }
  return child;
}

genann *child_from_mutation(genann **nns, ann_genes const genes[2], double meta_rate,
                            shape_bounds const *bounds, int *picked, ann_genes *child_genes,
                            mutation_outcome *outcome) {
  // Pick a NN to use
  *picked = pcg32_boundedrand(2);
  // Do the mutations
  return mutate(nns[*picked], &genes[*picked], meta_rate, bounds, child_genes, outcome);
}

genann *breed(genann **nns, ann_genes const genes[2], double cross_over_rate, double meta_rate,
              shape_bounds const *bounds, breeding *result) {
  // The operator is drawn whatever the shapes, so the draws that follow do
  // not depend on them.
  bool cross = GENANN_RANDOM() < cross_over_rate;
  result->outcome = (mutation_outcome){.copy = false, .activation_changed = false, .structure = STRUCTURE_NONE};
  if (cross && same_shape(nns[0], nns[1])) {
    genann *child = child_from_cross_over(nns, &result->picked);
    result->operator_name = "crossover";
    // A crossover child is not mutated: it keeps the activations and genes
    // of the parent whose weights come first.
    result->genes = genes[result->picked];
    return child;
  }
  genann *child = child_from_mutation(nns, genes, meta_rate, bounds, &result->picked, &result->genes,
                                      &result->outcome);
  result->operator_name = result->outcome.copy ? "copy" : "mutation";
  return child;
}

double standard_normal(void) {
  // u1 lies in (0, 1], so its logarithm is finite. No second value is kept
  // for the next call, so every draw takes the same two numbers.
  double u1 = (pcg32_random() + 1.0) * 0x1p-32;
  double u2 = ldexp(pcg32_random(), -32);
  return sqrt(-2.0 * log(u1)) * cos(2.0 * M_PI * u2);
}

static double clamp(double value, double min, double max) {
  return fmin(fmax(value, min), max);
}

static double log_normal_step(double gene, double meta_rate) {
  return gene * exp(meta_rate * standard_normal());
}

static double logit_normal_step(double p, double meta_rate) {
  double x = log(p / (1.0 - p)) + meta_rate * standard_normal();
  return 1.0 / (1.0 + exp(-x));
}

ann_genes mutate_genes(ann_genes genes, double meta_rate, int total_weights) {
  ann_genes child;
  child.copy_chance = clamp(logit_normal_step(genes.copy_chance, meta_rate),
                            ANN_COPY_CHANCE_MIN, ANN_COPY_CHANCE_MAX);
  child.weight_changes = clamp(log_normal_step(genes.weight_changes, meta_rate),
                               ANN_WEIGHT_CHANGES_MIN, total_weights);
  child.weight_step = clamp(log_normal_step(genes.weight_step, meta_rate),
                            ANN_WEIGHT_STEP_MIN, ANN_WEIGHT_STEP_MAX);
  child.activation_rate = clamp(logit_normal_step(genes.activation_rate, meta_rate),
                                ANN_ACTIVATION_RATE_MIN, ANN_ACTIVATION_RATE_MAX);
  child.structure_rate = clamp(logit_normal_step(genes.structure_rate, meta_rate),
                               ANN_STRUCTURE_RATE_MIN, ANN_STRUCTURE_RATE_MAX);
  return child;
}

// With probability rate, a different activation than the current one, each
// of the other five equally likely; otherwise the current one.
static genann_actfun switch_activation(genann_actfun current, double rate, bool *switched) {
  if (GENANN_RANDOM() >= rate) return current;
  int index = 0;
  while (index < ANN_ACTIVATION_COUNT && ANN_ACTIVATIONS[index].function != current) index++;
  // Skip the current one; an unknown activation may become any.
  int choices = index < ANN_ACTIVATION_COUNT ? ANN_ACTIVATION_COUNT - 1 : ANN_ACTIVATION_COUNT;
  int choice = pcg32_boundedrand(choices);
  if (choice >= index) choice++;
  *switched = true;
  return ANN_ACTIVATIONS[choice].function;
}

bool mutate_activations(genann *child, double activation_rate) {
  bool switched = false;
  child->activation_hidden = switch_activation(child->activation_hidden, activation_rate, &switched);
  child->activation_output = switch_activation(child->activation_output, activation_rate, &switched);
  return switched;
}

const char *structure_name(structure_change change) {
  switch (change) {
    case STRUCTURE_WIDEN: return "widen";
    case STRUCTURE_NARROW: return "narrow";
    case STRUCTURE_ADD_LAYER: return "add_layer";
    case STRUCTURE_REMOVE_LAYER: return "remove_layer";
    default: return "none";
  }
}

int allowed_structure_changes(genann const *ann, shape_bounds const *bounds, structure_change changes[4]) {
  int count = 0;
  if (ann->hidden_layers > 0 && ann->hidden < bounds->max_layer_size) changes[count++] = STRUCTURE_WIDEN;
  if (ann->hidden_layers > 0 && ann->hidden > 1) changes[count++] = STRUCTURE_NARROW;
  if (ann->hidden_layers < bounds->max_hidden_layers) changes[count++] = STRUCTURE_ADD_LAYER;
  if (ann->hidden_layers > 0) changes[count++] = STRUCTURE_REMOVE_LAYER;
  return count;
}

// A network of the given shape with the parent's activations and all
// weights 0. genann_init would fill it with random weights, drawing from the
// generator, so it is laid out here as genann_init lays it out (and as
// genann_copy and genann_free expect): building a network draws nothing.
static genann *blank(genann const *parent, int hidden_layers, int hidden) {
  int inputs = parent->inputs, outputs = parent->outputs;
  if (hidden_layers == 0) hidden = 0;
  long long hidden_weights = hidden_layers
    ? (long long)(inputs + 1) * hidden + (long long)(hidden_layers - 1) * (hidden + 1) * hidden : 0;
  long long output_weights = (long long)(hidden_layers ? hidden + 1 : inputs + 1) * outputs;
  long long total_weights = hidden_weights + output_weights;
  long long total_neurons = (long long)inputs + (long long)hidden * hidden_layers + outputs;
  genann *ann = NULL;
  // The same limit as genann_init's, so the sizes fit its int counters.
  if (total_weights <= INT_MAX / 32 && total_neurons <= INT_MAX / 32) {
    ann = calloc(1, sizeof(genann) + sizeof(double) * (total_weights + total_neurons + (total_neurons - inputs)));
  }
  if (ann == NULL) {
    fprintf(stderr, "Could not build a network with %d hidden layers of %d\n", hidden_layers, hidden);
    exit(1);
  }
  ann->inputs = inputs;
  ann->hidden_layers = hidden_layers;
  ann->hidden = hidden;
  ann->outputs = outputs;
  ann->total_weights = (int)total_weights;
  ann->total_neurons = (int)total_neurons;
  ann->weight = (double *)((char *)ann + sizeof(genann));
  ann->output = ann->weight + ann->total_weights;
  ann->delta = ann->output + ann->total_neurons;
  ann->activation_hidden = parent->activation_hidden;
  ann->activation_output = parent->activation_output;
  return ann;
}

// A weight as genann_randomize draws it.
static double random_weight(void) {
  return GENANN_RANDOM() - 0.5;
}

// In GENANN's layout every neuron has a row: its bias (the weight of a
// constant input of -1), then one weight per neuron of the layer before. The
// rows go layer by layer, the outputs last.

// The number of neurons feeding hidden layer h (or the outputs, for h equal
// to hidden_layers).
static int layer_inputs(genann const *ann, int h) {
  return h == 0 ? ann->inputs : ann->hidden;
}

// The number of weights in the hidden layers before layer h.
static int weights_before(genann const *ann, int h) {
  if (h == 0) return 0;
  return (ann->inputs + 1) * ann->hidden + (h - 1) * (ann->hidden + 1) * ann->hidden;
}

genann *widen(genann const *parent) {
  int n = parent->hidden;
  genann *child = blank(parent, parent->hidden_layers, n + 1);
  double const *from = parent->weight;
  double *to = child->weight;
  for (int h = 0; h <= parent->hidden_layers; h++) {
    int inputs = layer_inputs(parent, h);
    int neurons = h == parent->hidden_layers ? parent->outputs : n;
    for (int j = 0; j < neurons; j++) {
      // An existing neuron keeps its row; the new neuron of the layer before
      // (none before the first) feeds it with weight 0.
      for (int k = 0; k <= inputs; k++) *to++ = *from++;
      if (h > 0) *to++ = 0.0;
    }
    if (h < parent->hidden_layers) {
      // The new neuron, fed at random by the whole layer before.
      int row = h == 0 ? inputs + 1 : inputs + 2;
      for (int k = 0; k < row; k++) *to++ = random_weight();
    }
  }
  return child;
}

genann *narrow(genann const *parent) {
  int n = parent->hidden;
  int layers = parent->hidden_layers;
  int removed[layers];
  for (int h = 0; h < layers; h++) removed[h] = pcg32_boundedrand(n);
  genann *child = blank(parent, layers, n - 1);
  double const *from = parent->weight;
  double *to = child->weight;
  for (int h = 0; h <= layers; h++) {
    int inputs = layer_inputs(parent, h);
    int neurons = h == layers ? parent->outputs : n;
    for (int j = 0; j < neurons; j++) {
      if (h < layers && j == removed[h]) {
        from += inputs + 1;
        continue;
      }
      *to++ = *from++;
      for (int k = 0; k < inputs; k++, from++) {
        if (h == 0 || k != removed[h - 1]) *to++ = *from;
      }
    }
  }
  return child;
}

static bool is_sigmoid(genann_actfun activation) {
  return activation == genann_act_sigmoid || activation == genann_act_sigmoid_cached;
}

genann *add_layer(genann const *parent, int add_layer_size) {
  int layers = parent->hidden_layers;
  if (layers == 0) {
    genann *child = blank(parent, 1, add_layer_size);
    for (int i = 0; i < child->total_weights; i++) child->weight[i] = random_weight();
    return child;
  }
  int n = parent->hidden;
  genann *child = blank(parent, layers + 1, n);
  int hidden_weights = weights_before(parent, layers);
  memcpy(child->weight, parent->weight, sizeof(double) * hidden_weights);
  double *to = child->weight + hidden_weights;
  for (int i = 0; i < n; i++) {
    *to++ = 0.0;
    for (int k = 0; k < n; k++) *to++ = k == i ? 1.0 : 0.0;
  }
  // The pass-through of a sigmoid is 0.5 + x/4 or so, so the output rows
  // take four times the weights and a bias that cancels the 0.5.
  bool compensate = is_sigmoid(parent->activation_hidden);
  double const *from = parent->weight + hidden_weights;
  for (int o = 0; o < parent->outputs; o++) {
    double bias = from[0];
    double sum = 0.0;
    for (int k = 0; k < n; k++) sum += from[1 + k];
    *to++ = compensate ? bias + 2.0 * sum : bias;
    for (int k = 0; k < n; k++) *to++ = compensate ? 4.0 * from[1 + k] : from[1 + k];
    from += n + 1;
  }
  return child;
}

genann *remove_layer(genann const *parent) {
  int layers = parent->hidden_layers;
  int n = parent->hidden;
  genann *child = blank(parent, layers - 1, n);
  // The straight line c + s·x standing in for the removed layer's activation.
  genann_actfun f = parent->activation_hidden;
  bool squeezed = is_sigmoid(f) || f == genann_act_threshold;
  double c = squeezed ? 0.5 : 0.0;
  double s = squeezed ? 0.25 : 1.0;
  int kept = weights_before(parent, layers - 1);
  memcpy(child->weight, parent->weight, sizeof(double) * kept);
  // The removed layer's rows (n of them, each bias then m weights) and the
  // output rows (each bias then n weights).
  int m = layer_inputs(parent, layers - 1);
  double const *removed = parent->weight + kept;
  double const *outputs = removed + n * (m + 1);
  double *to = child->weight + kept;
  for (int o = 0; o < parent->outputs; o++) {
    double const *v = outputs + o * (n + 1);
    // A neuron's sum is -bias + Σ w·x, so the output's is
    // -B + Σ_k V_k·(c + s·(-b_k + Σ_j W_kj·x_j)).
    double offset = 0.0;
    for (int k = 0; k < n; k++) offset += v[1 + k] * (c - s * removed[k * (m + 1)]);
    *to++ = v[0] - offset;
    for (int j = 0; j < m; j++) {
      double sum = 0.0;
      for (int k = 0; k < n; k++) sum += v[1 + k] * removed[k * (m + 1) + 1 + j];
      *to++ = s * sum;
    }
  }
  return child;
}

// With the rate, one structural change among those the bounds allow, chosen
// uniformly. Replaces *child when it changes.
static structure_change mutate_structure(genann **child, shape_bounds const *bounds, double rate) {
  structure_change allowed[4];
  int count = allowed_structure_changes(*child, bounds, allowed);
  if (count == 0 || GENANN_RANDOM() >= rate) return STRUCTURE_NONE;
  structure_change change = allowed[pcg32_boundedrand(count)];
  genann *changed = NULL;
  switch (change) {
    case STRUCTURE_WIDEN: changed = widen(*child); break;
    case STRUCTURE_NARROW: changed = narrow(*child); break;
    case STRUCTURE_ADD_LAYER: changed = add_layer(*child, bounds->add_layer_size); break;
    default: changed = remove_layer(*child); break;
  }
  genann_free(*child);
  *child = changed;
  return change;
}

// The draws come in a fixed order, so a seed gives one child: the copy
// check, the genes, the activations, the structure, then the weights.
genann *mutate(genann const *parent, ann_genes const *parent_genes, double meta_rate,
               shape_bounds const *bounds, ann_genes *child_genes, mutation_outcome *outcome) {
  mutation_outcome result = {.copy = false, .activation_changed = false, .structure = STRUCTURE_NONE};
  genann *child = genann_copy(parent);
  *child_genes = *parent_genes;
  if (GENANN_RANDOM() < parent_genes->copy_chance) {
    result.copy = true;
    if (outcome) *outcome = result;
    return child;
  }

  // weight_changes is clamped against the child's final total_weights, known
  // only after the structural change.
  *child_genes = mutate_genes(*parent_genes, meta_rate, INT_MAX);

  result.activation_changed = mutate_activations(child, child_genes->activation_rate);

  if (bounds) result.structure = mutate_structure(&child, bounds, child_genes->structure_rate);
  child_genes->weight_changes = fmin(child_genes->weight_changes, child->total_weights);

  double change_chance = fmin(1.0, child_genes->weight_changes / child->total_weights);
  double step = child_genes->weight_step;
  for (int i = 0; i < child->total_weights; i++) {
    if (GENANN_RANDOM() < change_chance) {
      child->weight[i] += (2.0 * GENANN_RANDOM() - 1.0) * step;
    }
  }

  if (outcome) *outcome = result;
  return child;
}
