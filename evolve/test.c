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

#include <stdbool.h>
#include <string.h>

#include "evolve.h"
#include "minctest.h"

// The meta rate τ the runner passes by default.
#define META_RATE 0.2

void test_cross_over() {
  genann *nn1 = genann_init(1, 1, 1, 1);
  genann *nn2 = genann_init(1, 1, 1, 1);
  genann *child = cross_over(nn1, nn2, 2);

  lfequal(nn1->weight[0], child->weight[0]);
  lfequal(nn1->weight[1], child->weight[1]);
  lfequal(nn2->weight[2], child->weight[2]);
  lfequal(nn2->weight[3], child->weight[3]);
}

// The mutation tests pin down how the genes drive mutate(), so that a change
// to it shows up as a failing test. Their tolerances are about four standard
// errors wide. The generator is seeded, so each run draws the same numbers.

// Like lfequal, with a tolerance chosen by the test.
static void check_close(const char *what, double actual, double expected, double tolerance) {
  ++ltests;
  if (fabs(actual - expected) > tolerance) {
    ++lfails;
    printf("%s: %f is not within %f of %f\n", what, actual, tolerance, expected);
  }
}

static double logit(double p) {
  return log(p / (1 - p));
}

// Genes well inside their ranges, for a network of at least 50 weights.
static ann_genes middle_genes() {
  ann_genes genes = {
    .copy_chance = 0.05,
    .weight_changes = 50,
    .weight_step = 0.3,
    .activation_rate = 0.02,
    .structure_rate = 0.03,
  };
  return genes;
}

static bool same_genes(ann_genes const *a, ann_genes const *b) {
  return a->copy_chance == b->copy_chance
    && a->weight_changes == b->weight_changes
    && a->weight_step == b->weight_step
    && a->activation_rate == b->activation_rate
    && a->structure_rate == b->structure_rate;
}

typedef struct {
  int children;
  int copies;
  long changed_weights;
  // Over the mutated children: the sum of (changed weights - the child's
  // weight_changes gene).
  double sum_of_excess_changes;
  // Over the changed weights: the largest change in size, the sum of the
  // changes, and how many changed by less than half the parent's step.
  double largest_change;
  double sum_of_changes;
  long small_changes;
} mutation_counts;

// Mutates the same parent many times and counts what changed. A child whose
// weights and genes all equal the parent's counts as a copy.
static mutation_counts mutate_many(genann *parent, ann_genes genes, double meta_rate, int children) {
  mutation_counts counts = {0};
  counts.children = children;
  for (int c = 0; c < children; c++) {
    ann_genes child_genes;
    genann *child = mutate(parent, &genes, meta_rate, NULL, &child_genes, NULL);
    long changed = 0;
    for (int i = 0; i < parent->total_weights; i++) {
      double change = child->weight[i] - parent->weight[i];
      if (change == 0) continue;
      changed++;
      counts.sum_of_changes += change;
      if (fabs(change) > counts.largest_change) counts.largest_change = fabs(change);
      if (fabs(change) < genes.weight_step / 2) counts.small_changes++;
    }
    if (changed == 0 && same_genes(&child_genes, &genes)) {
      counts.copies++;
    } else {
      counts.changed_weights += changed;
      counts.sum_of_excess_changes += changed - child_genes.weight_changes;
    }
    genann_free(child);
  }
  return counts;
}

void test_mutate_copies_the_parent() {
  // Large enough that the child has changed weights, so writing them into
  // the parent would show.
  pcg32_srandom(1, 54u);
  genann *parent = genann_init(82, 1, 250, 82);
  genann *before = genann_copy(parent);
  ann_genes genes = middle_genes();
  genes.copy_chance = ANN_COPY_CHANCE_MIN;
  ann_genes child_genes;
  genann *child = mutate(parent, &genes, META_RATE, NULL, &child_genes, NULL);

  lok(child != parent);
  lok(child->weight != parent->weight);
  lequal(child->inputs, parent->inputs);
  lequal(child->hidden_layers, parent->hidden_layers);
  lequal(child->hidden, parent->hidden);
  lequal(child->outputs, parent->outputs);
  lequal(child->total_weights, parent->total_weights);
  lok(child->activation_hidden == parent->activation_hidden);
  lok(child->activation_output == parent->activation_output);
  // The child changed, and the parent itself is left alone.
  bool child_changed = false;
  bool parent_unchanged = true;
  for (int i = 0; i < parent->total_weights; i++) {
    if (child->weight[i] != before->weight[i]) child_changed = true;
    if (parent->weight[i] != before->weight[i]) parent_unchanged = false;
  }
  lok(child_changed);
  lok(parent_unchanged);
  lok(!same_genes(&child_genes, &genes));

  genann_free(child);
  genann_free(before);
  genann_free(parent);
}

// Writes the child and its genes to a temporary file and returns its bytes.
static size_t child_bytes(genann const *child, ann_genes const *genes, unsigned char *buffer, size_t size) {
  FILE *file = tmpfile();
  lok(file != NULL);
  ann_features features = ann_default_features(0);
  lequal(ann_binary_write(child, genes, &features, file), 0);
  rewind(file);
  size_t length = fread(buffer, 1, size, file);
  fclose(file);
  return length;
}

void test_mutate_is_deterministic_for_a_seed() {
  pcg32_srandom(2, 54u);
  genann *parent = genann_init(82, 1, 100, 82);
  ann_genes genes = middle_genes();
  ann_genes first_genes, second_genes, other_genes;

  pcg32_srandom(3, 54u);
  genann *first = mutate(parent, &genes, META_RATE, NULL, &first_genes, NULL);
  pcg32_srandom(3, 54u);
  genann *second = mutate(parent, &genes, META_RATE, NULL, &second_genes, NULL);
  pcg32_srandom(4, 54u);
  genann *other = mutate(parent, &genes, META_RATE, NULL, &other_genes, NULL);

  static unsigned char a[200000], b[200000], c[200000];
  size_t a_length = child_bytes(first, &first_genes, a, sizeof a);
  size_t b_length = child_bytes(second, &second_genes, b, sizeof b);
  size_t c_length = child_bytes(other, &other_genes, c, sizeof c);
  lok(a_length > 0 && a_length < sizeof a);
  lok(a_length == b_length && memcmp(a, b, a_length) == 0);
  lok(a_length == c_length && memcmp(a, c, a_length) != 0);

  genann_free(other);
  genann_free(second);
  genann_free(first);
  genann_free(parent);
}

// A child is an exact copy, genes included, with the parent's copy_chance.
// Every other child differs in its genes, as meta_rate is not 0.
void test_mutate_copies_with_copy_chance() {
  pcg32_srandom(5, 54u);
  genann *parent = genann_init(82, 2, 2, 82);
  lequal(parent->total_weights, 418);
  ann_genes genes = middle_genes();
  mutation_counts counts = mutate_many(parent, genes, META_RATE, 20000);

  // SE = sqrt(0.05 * 0.95 / 20000) = 0.0015.
  check_close("share of copies", (double)counts.copies / counts.children, 0.05, 0.006);

  genann_free(parent);
}

// With meta_rate 0 the genes stay as they are, so the weights follow the
// parent's genes: each weight changes with probability weight_changes /
// total_weights, by a uniform amount in [-weight_step, +weight_step].
void test_mutate_changes_weights_by_the_genes() {
  pcg32_srandom(6, 54u);
  genann *parent = genann_init(82, 1, 100, 82);
  lequal(parent->total_weights, 16582);
  ann_genes genes = middle_genes();
  genes.copy_chance = ANN_COPY_CHANCE_MIN;
  mutation_counts counts = mutate_many(parent, genes, 0, 4000);
  int mutated = counts.children - counts.copies;

  // Binomial(16582, 50/16582) per child: SE = sqrt(50 / 4000) = 0.11.
  check_close("changed weights per mutated child",
              (double)counts.changed_weights / mutated, genes.weight_changes, 0.45);
  // Uniform in [-0.3, 0.3]: sd 0.173, so over ~200,000 changes the mean has
  // SE 0.0004, and the share below 0.15 in size SE 0.0011.
  lok(counts.largest_change <= genes.weight_step);
  lok(counts.largest_change > 0.99 * genes.weight_step);
  check_close("mean change", counts.sum_of_changes / counts.changed_weights, 0.0, 0.0016);
  check_close("share of changes smaller than half the step",
              (double)counts.small_changes / counts.changed_weights, 0.5, 0.0045);

  genann_free(parent);
}

// weight_changes as large as total_weights changes every weight.
void test_mutate_changes_every_weight_at_most() {
  pcg32_srandom(7, 54u);
  genann *parent = genann_init(3, 1, 4, 2);
  ann_genes genes = middle_genes();
  genes.copy_chance = ANN_COPY_CHANCE_MIN;
  genes.weight_changes = parent->total_weights;
  mutation_counts counts = mutate_many(parent, genes, 0, 100);

  lequal((int)counts.changed_weights, (counts.children - counts.copies) * parent->total_weights);

  genann_free(parent);
}

// The mutated genes, not the parent's, drive the child's weights: the changed
// weights follow the child's weight_changes gene. With meta_rate 0.5 the
// parent's gene (50) is on average 6.6 below the child's.
void test_mutate_uses_the_mutated_genes() {
  pcg32_srandom(8, 54u);
  genann *parent = genann_init(82, 1, 100, 82);
  ann_genes genes = middle_genes();
  genes.copy_chance = ANN_COPY_CHANCE_MIN;
  mutation_counts counts = mutate_many(parent, genes, 0.5, 2000);
  int mutated = counts.children - counts.copies;

  // Per child sd about sqrt(57): SE = 0.17.
  check_close("changed weights minus the child's weight_changes",
              counts.sum_of_excess_changes / mutated, 0.0, 0.7);

  genann_free(parent);
}

// Self-adaptation: log(g'/g) for weight_changes and weight_step and
// logit(p') - logit(p) for the probabilities are N(0, meta_rate), each gene
// with its own draw.
void test_mutate_genes_distributions() {
  pcg32_srandom(9, 54u);
  const int n = 20000;
  const double tau = META_RATE;
  ann_genes genes = middle_genes();
  double sum[5] = {0}, sum_of_squares[5] = {0};
  long within_tau[5] = {0};
  double sum_of_products[5][5] = {{0}};
  for (int k = 0; k < n; k++) {
    ann_genes child = mutate_genes(genes, tau, 1000);
    double step[5] = {
      logit(child.copy_chance) - logit(genes.copy_chance),
      log(child.weight_changes / genes.weight_changes),
      log(child.weight_step / genes.weight_step),
      logit(child.activation_rate) - logit(genes.activation_rate),
      logit(child.structure_rate) - logit(genes.structure_rate),
    };
    for (int g = 0; g < 5; g++) {
      sum[g] += step[g];
      sum_of_squares[g] += step[g] * step[g];
      if (fabs(step[g]) < tau) within_tau[g]++;
    }
    for (int g = 0; g < 5; g++) {
      for (int h = g + 1; h < 5; h++) sum_of_products[g][h] += step[g] * step[h];
    }
  }
  for (int g = 0; g < 5; g++) {
    double mean = sum[g] / n;
    double sd = sqrt(sum_of_squares[g] / n - mean * mean);
    // SE of the mean tau/sqrt(n) = 0.0014; of the sd tau/sqrt(2n) = 0.001;
    // of the share within one sd sqrt(0.683 * 0.317 / n) = 0.0033.
    check_close("mean of the gene step", mean, 0.0, 0.0057);
    check_close("sd of the gene step", sd, tau, 0.004);
    check_close("share of gene steps within one sd", (double)within_tau[g] / n, 0.6827, 0.013);
  }
  // Independent draws: the correlation of every pair has SE 1/sqrt(n) = 0.007.
  for (int g = 0; g < 5; g++) {
    for (int h = g + 1; h < 5; h++) {
      check_close("correlation of two gene steps", sum_of_products[g][h] / n / (tau * tau), 0.0, 0.028);
    }
  }
}

// However far the genes step, they stay in their ranges, and weight_changes
// stays at most the network's total_weights.
void test_mutate_genes_clamps() {
  pcg32_srandom(10, 54u);
  ann_genes low = {
    ANN_COPY_CHANCE_MIN, ANN_WEIGHT_CHANGES_MIN, ANN_WEIGHT_STEP_MIN,
    ANN_ACTIVATION_RATE_MIN, ANN_STRUCTURE_RATE_MIN,
  };
  ann_genes high = {
    ANN_COPY_CHANCE_MAX, 26, ANN_WEIGHT_STEP_MAX,
    ANN_ACTIVATION_RATE_MAX, ANN_STRUCTURE_RATE_MAX,
  };
  int invalid = 0, at_low = 0, at_high = 0;
  for (int k = 0; k < 1000; k++) {
    ann_genes a = mutate_genes(low, 5, 26);
    ann_genes b = mutate_genes(high, 5, 26);
    if (ann_genes_invalid(&a, 26) || ann_genes_invalid(&b, 26)) invalid++;
    if (a.weight_step == ANN_WEIGHT_STEP_MIN) at_low++;
    if (b.weight_changes == 26) at_high++;
  }
  lequal(invalid, 0);
  // Half of the steps go past the bound and stop at it.
  lok(at_low > 400 && at_low < 600);
  lok(at_high > 400 && at_high < 600);
  // With meta_rate 0 the genes at the bounds stay valid despite rounding.
  ann_genes same = mutate_genes(high, 0, 26);
  lok(ann_genes_invalid(&same, 26) == NULL);
}

// Parents can breed when they have the same inputs and outputs; their
// shapes and activations may differ. Only the same shape can cross over.
void test_parents_must_match() {
  genann *a = genann_init(3, 1, 4, 2);
  genann *b = genann_init(3, 1, 4, 2);
  genann *nns[2] = {a, b};
  lok(nns_compatible(nns));
  lok(same_shape(a, b));

  b->activation_output = genann_act_linear;
  b->activation_hidden = genann_act_tanh;
  lok(nns_compatible(nns));
  lok(same_shape(a, b));

  genann *wider = genann_init(3, 1, 5, 2);
  genann *deeper = genann_init(3, 2, 4, 2);
  genann *others[] = {wider, deeper};
  for (int i = 0; i < 2; i++) {
    nns[1] = others[i];
    lok(nns_compatible(nns));
    lok(!same_shape(a, others[i]));
    genann_free(others[i]);
  }
  genann *more_inputs = genann_init(4, 1, 4, 2);
  genann *more_outputs = genann_init(3, 1, 4, 3);
  genann *incompatible[] = {more_inputs, more_outputs};
  for (int i = 0; i < 2; i++) {
    nns[1] = incompatible[i];
    lok(!nns_compatible(nns));
    lok(!same_shape(a, incompatible[i]));
    genann_free(incompatible[i]);
  }
  // Without hidden layers the width does not count.
  genann *flat = genann_init(3, 0, 0, 2);
  genann *flat_wide = genann_init(3, 0, 7, 2);
  lok(same_shape(flat, flat_wide));
  genann_free(flat_wide);
  genann_free(flat);

  genann_free(b);
  genann_free(a);
}

// The position of a network's activation in ANN_ACTIVATIONS.
static int activation_index(genann_actfun function) {
  for (int i = 0; i < ANN_ACTIVATION_COUNT; i++) {
    if (ANN_ACTIVATIONS[i].function == function) return i;
  }
  return -1;
}

// With the given rate each activation switches on its own, always to a
// different one, chosen uniformly among the other five, from whichever it
// starts with.
void test_mutate_activations_switches_uniformly() {
  pcg32_srandom(11, 54u);
  lequal(ANN_ACTIVATION_COUNT, 6);
  const int trials = 3000;
  const double rate = 0.3;
  genann *net = genann_init(3, 1, 4, 2);
  long hidden_switches = 0, output_switches = 0, both = 0, invalid = 0, changed_reported = 0;
  long targets[6][6] = {{0}};
  long switches_from[6] = {0};
  for (int start = 0; start < 6; start++) {
    for (int k = 0; k < trials; k++) {
      net->activation_hidden = ANN_ACTIVATIONS[start].function;
      net->activation_output = ANN_ACTIVATIONS[(start + 3) % 6].function;
      bool changed = mutate_activations(net, rate);
      int hidden = activation_index(net->activation_hidden);
      int output = activation_index(net->activation_output);
      bool hidden_switched = hidden != start;
      bool output_switched = output != (start + 3) % 6;
      if (hidden < 0 || output < 0) invalid++;
      if (changed != (hidden_switched || output_switched)) invalid++;
      if (changed) changed_reported++;
      if (hidden_switched) {
        hidden_switches++;
        switches_from[start]++;
        targets[start][hidden]++;
      }
      if (output_switched) output_switches++;
      if (hidden_switched && output_switched) both++;
    }
  }
  const double n = 6.0 * trials;
  // SE = sqrt(0.3 * 0.7 / 18000) = 0.0034; of both 0.0024.
  check_close("share of hidden switches", hidden_switches / n, rate, 0.014);
  check_close("share of output switches", output_switches / n, rate, 0.014);
  check_close("share of both switching", both / n, rate * rate, 0.01);
  check_close("share reported changed", changed_reported / n, 1 - (1 - rate) * (1 - rate), 0.016);
  lequal((int)invalid, 0);
  for (int start = 0; start < 6; start++) {
    lequal((int)targets[start][start], 0);
    for (int target = 0; target < 6; target++) {
      if (target == start) continue;
      // About 900 switches from each start: SE sqrt(0.2 * 0.8 / 900) = 0.013.
      check_close("share of switches to one activation",
                  (double)targets[start][target] / switches_from[start], 0.2, 0.053);
    }
  }
  genann_free(net);
}

// A mutated child switches each activation with its activation_rate gene
// (meta_rate 0 keeps the gene as it is), and says so. A copy never switches.
void test_mutate_switches_activations_by_the_gene() {
  pcg32_srandom(12, 54u);
  genann *parent = genann_init(3, 1, 4, 2);
  ann_genes genes = middle_genes();
  genes.copy_chance = ANN_COPY_CHANCE_MAX;
  genes.activation_rate = 0.4;
  const int children = 20000;
  long copies = 0, hidden_switches = 0, output_switches = 0, mismatched = 0;
  for (int c = 0; c < children; c++) {
    ann_genes child_genes;
    mutation_outcome outcome;
    genann *child = mutate(parent, &genes, 0, NULL, &child_genes, &outcome);
    bool hidden_switched = child->activation_hidden != parent->activation_hidden;
    bool output_switched = child->activation_output != parent->activation_output;
    if (outcome.activation_changed != (hidden_switched || output_switched)) mismatched++;
    if (outcome.copy) {
      copies++;
      if (hidden_switched || output_switched || !same_genes(&child_genes, &genes)) mismatched++;
      for (int i = 0; i < parent->total_weights; i++) {
        if (child->weight[i] != parent->weight[i]) mismatched++;
      }
    } else {
      if (hidden_switched) hidden_switches++;
      if (output_switched) output_switches++;
    }
    genann_free(child);
  }
  lequal((int)mismatched, 0);
  // SE = sqrt(0.1 * 0.9 / 20000) = 0.0021.
  check_close("share of copies", (double)copies / children, 0.1, 0.0085);
  // About 18,000 mutated children: SE sqrt(0.4 * 0.6 / 18000) = 0.0037.
  check_close("share of hidden switches", (double)hidden_switches / (children - copies), 0.4, 0.015);
  check_close("share of output switches", (double)output_switches / (children - copies), 0.4, 0.015);
  genann_free(parent);
}

// A crossover child takes the activations of the parent whose weights come
// first, and none switches.
void test_cross_over_keeps_the_picked_parents_activations() {
  pcg32_srandom(13, 54u);
  genann *a = genann_init(3, 1, 4, 2);
  genann *b = genann_init(3, 1, 4, 2);
  b->activation_hidden = genann_act_tanh;
  b->activation_output = genann_act_linear;
  genann *nns[2] = {a, b};
  int picked_first = 0, wrong = 0;
  for (int k = 0; k < 1000; k++) {
    int picked;
    genann *child = child_from_cross_over(nns, &picked);
    if (picked == 0) picked_first++;
    if (child->activation_hidden != nns[picked]->activation_hidden) wrong++;
    if (child->activation_output != nns[picked]->activation_output) wrong++;
    genann_free(child);
  }
  lequal(wrong, 0);
  lok(picked_first > 400 && picked_first < 600);
  genann_free(b);
  genann_free(a);
}

// The structural operators. The networks are small, and their weights and
// inputs are drawn from a seeded generator.

#define INPUTS 6
#define OUTPUTS 5
#define SAMPLES 30

// A random network of the given shape and activations.
static genann *random_network(int layers, int width, genann_actfun hidden, genann_actfun output) {
  genann *ann = genann_init(INPUTS, layers, layers ? width : 0, OUTPUTS);
  ann->activation_hidden = hidden;
  ann->activation_output = output;
  return ann;
}

// SAMPLES random inputs in [-1, 1).
static void random_inputs(double inputs[SAMPLES][INPUTS]) {
  for (int s = 0; s < SAMPLES; s++) {
    for (int i = 0; i < INPUTS; i++) inputs[s][i] = 2.0 * GENANN_RANDOM() - 1.0;
  }
}

// The outputs of a network for each sample.
static void run_all(genann const *ann, double inputs[SAMPLES][INPUTS], double outputs[SAMPLES][OUTPUTS]) {
  for (int s = 0; s < SAMPLES; s++) {
    memcpy(outputs[s], genann_run(ann, inputs[s]), sizeof(double) * OUTPUTS);
  }
}

// The largest difference between two networks' outputs, and whether all are
// == equal.
static double largest_difference(genann const *a, genann const *b, bool *equal) {
  double inputs[SAMPLES][INPUTS], a_out[SAMPLES][OUTPUTS], b_out[SAMPLES][OUTPUTS];
  random_inputs(inputs);
  run_all(a, inputs, a_out);
  run_all(b, inputs, b_out);
  double largest = 0;
  *equal = true;
  for (int s = 0; s < SAMPLES; s++) {
    for (int o = 0; o < OUTPUTS; o++) {
      if (a_out[s][o] != b_out[s][o]) *equal = false;
      double difference = fabs(a_out[s][o] - b_out[s][o]);
      if (!(difference <= largest)) largest = difference;
    }
  }
  return largest;
}

static bool same_outputs(genann const *a, genann const *b) {
  bool equal;
  largest_difference(a, b, &equal);
  return equal;
}

// The total_weights of a GENANN network of that shape.
static int weights_of(int layers, int width) {
  genann *ann = genann_init(INPUTS, layers, layers ? width : 0, OUTPUTS);
  int total = ann->total_weights;
  genann_free(ann);
  return total;
}

// Whether the network has the shape and the activations, with every weight
// finite.
static bool valid_network(genann const *ann, int layers, int width, genann const *parent) {
  bool valid = ann->inputs == INPUTS && ann->outputs == OUTPUTS && ann->hidden_layers == layers
    && (layers == 0 || ann->hidden == width) && ann->total_weights == weights_of(layers, width)
    && ann->activation_hidden == parent->activation_hidden
    && ann->activation_output == parent->activation_output;
  for (int i = 0; valid && i < ann->total_weights; i++) valid = isfinite(ann->weight[i]);
  return valid;
}

// Whether two networks' outputs agree to a relative tolerance (against each
// sample's largest output) and pick the same move.
static bool close_outputs(genann const *a, genann const *b, double tolerance) {
  double inputs[SAMPLES][INPUTS], a_out[SAMPLES][OUTPUTS], b_out[SAMPLES][OUTPUTS];
  random_inputs(inputs);
  run_all(a, inputs, a_out);
  run_all(b, inputs, b_out);
  bool close = true;
  for (int s = 0; s < SAMPLES; s++) {
    double scale = 0;
    int a_best = 0, b_best = 0;
    for (int o = 0; o < OUTPUTS; o++) {
      scale = fmax(scale, fabs(a_out[s][o]));
      if (a_out[s][o] > a_out[s][a_best]) a_best = o;
      if (b_out[s][o] > b_out[s][b_best]) b_best = o;
    }
    for (int o = 0; o < OUTPUTS; o++) {
      if (!(fabs(a_out[s][o] - b_out[s][o]) <= tolerance * scale)) close = false;
    }
    if (a_best != b_best) close = false;
  }
  return close;
}

// Widening changes no output, whatever the activations and the depth, and
// the new neurons get random incoming weights. The new weights add exact
// zeros, but a compiler may sum a longer row in another order (GCC
// vectorizes GENANN's loops), so the outputs agree up to rounding.
void test_widen_keeps_the_outputs() {
  pcg32_srandom(20, 54u);
  int different = 0, invalid = 0, nonzero_new = 0, out_of_range = 0;
  for (int layers = 1; layers <= 3; layers++) {
    for (int h = 0; h < ANN_ACTIVATION_COUNT; h++) {
      for (int o = 0; o < ANN_ACTIVATION_COUNT; o++) {
        genann *parent = random_network(layers, 3, ANN_ACTIVATIONS[h].function, ANN_ACTIVATIONS[o].function);
        genann *child = widen(parent);
        if (!valid_network(child, layers, 4, parent)) invalid++;
        if (!close_outputs(parent, child, 1e-12)) different++;
        // The first layer's new row: bias and one weight per input.
        double const *row = child->weight + 3 * (INPUTS + 1);
        for (int k = 0; k <= INPUTS; k++) {
          if (row[k] != 0) nonzero_new++;
          if (row[k] < -0.5 || row[k] >= 0.5) out_of_range++;
        }
        genann_free(child);
        genann_free(parent);
      }
    }
  }
  lequal(invalid, 0);
  lequal(different, 0);
  lequal(out_of_range, 0);
  lequal(nonzero_new, 3 * 36 * (INPUTS + 1));
}

// Narrowing removes one neuron per layer, a different one in each layer
// independently, each equally likely, with its row and its column in the
// next layer. Each neuron's bias here names it: 100·layer + index.
void test_narrow_removes_a_neuron_per_layer() {
  pcg32_srandom(21, 54u);
  const int width = 3, trials = 9000;
  long joint[3][3] = {{0}};
  int invalid = 0, wrong_weights = 0;
  genann *parent = random_network(2, width, genann_act_tanh, genann_act_linear);
  int row_length[3] = {INPUTS + 1, width + 1, width + 1};
  for (int h = 0; h < 2; h++) {
    for (int j = 0; j < width; j++) parent->weight[h * width * (INPUTS + 1) + j * row_length[h]] = 100 * h + j;
  }
  for (int t = 0; t < trials; t++) {
    genann *child = narrow(parent);
    if (!valid_network(child, 2, width - 1, parent)) invalid++;
    // Find the removed neuron of each layer from the biases left.
    int removed[2];
    int child_row[3] = {INPUTS + 1, width, width};
    for (int h = 0; h < 2; h++) {
      double const *first = child->weight + h * (width - 1) * (INPUTS + 1);
      int index0 = (int)first[0] - 100 * h, index1 = (int)first[child_row[h]] - 100 * h;
      removed[h] = index0 != 0 ? 0 : index1 != 1 ? 1 : 2;
    }
    joint[removed[0]][removed[1]]++;
    // Every row left equals its parent row without the removed column.
    double const *to = child->weight;
    for (int h = 0; h < 3; h++) {
      int neurons = h == 2 ? OUTPUTS : width;
      double const *from = parent->weight + (h == 0 ? 0 : width * (INPUTS + 1) + (h - 1) * width * (width + 1));
      for (int j = 0; j < neurons; j++, from += row_length[h]) {
        if (h < 2 && j == removed[h]) continue;
        for (int k = 0; k < row_length[h]; k++) {
          if (h > 0 && k == 1 + removed[h - 1]) continue;
          if (*to++ != from[k]) wrong_weights++;
        }
      }
    }
    if (to != child->weight + child->total_weights) wrong_weights++;
    genann_free(child);
  }
  lequal(invalid, 0);
  lequal(wrong_weights, 0);
  // Each of the 9 pairs about 1,000 times: SE sqrt(1/9 · 8/9 / 9000) = 0.0033.
  for (int a = 0; a < 3; a++) {
    for (int b = 0; b < 3; b++) check_close("share of one pair of removed neurons", joint[a][b] / (double)trials, 1.0 / 9, 0.014);
  }
  genann_free(parent);
}

// An added layer passes the last hidden layer through unchanged for the
// activations that leave their own outputs as they are: linear, relu, and
// threshold, with any output activation.
void test_add_layer_passes_through() {
  pcg32_srandom(22, 54u);
  genann_actfun exact[] = {genann_act_linear, genann_act_relu, genann_act_threshold};
  int different = 0, invalid = 0;
  for (int layers = 1; layers <= 3; layers++) {
    for (int h = 0; h < 3; h++) {
      for (int o = 0; o < ANN_ACTIVATION_COUNT; o++) {
        genann *parent = random_network(layers, 4, exact[h], ANN_ACTIVATIONS[o].function);
        genann *child = add_layer(parent, 9);
        if (!valid_network(child, layers + 1, 4, parent)) invalid++;
        if (!same_outputs(parent, child)) different++;
        genann_free(child);
        genann_free(parent);
      }
    }
  }
  lequal(invalid, 0);
  lequal(different, 0);
}

// Without hidden layers, the added layer has add_layer_size neurons and it
// and the outputs get random weights.
void test_add_layer_to_no_hidden_layers() {
  pcg32_srandom(23, 54u);
  genann *parent = random_network(0, 0, genann_act_relu, genann_act_tanh);
  genann *child = add_layer(parent, 7);
  lok(valid_network(child, 1, 7, parent));
  int out_of_range = 0, zeros = 0;
  for (int i = 0; i < child->total_weights; i++) {
    if (child->weight[i] < -0.5 || child->weight[i] >= 0.5) out_of_range++;
    if (child->weight[i] == 0) zeros++;
  }
  lequal(out_of_range, 0);
  lequal(zeros, 0);
  genann_free(child);
  genann_free(parent);
}

// A linear layer folds into the output layer up to rounding: the outputs
// agree to a relative 1e-9 and pick the same move. From one hidden layer the
// output rows fold onto every input.
void test_remove_layer_folds_a_linear_layer() {
  pcg32_srandom(24, 54u);
  int invalid = 0, too_far = 0, other_move = 0;
  for (int layers = 1; layers <= 3; layers++) {
    for (int n = 0; n < 20; n++) {
      genann *parent = random_network(layers, 5, genann_act_linear, genann_act_linear);
      genann *child = remove_layer(parent);
      if (!valid_network(child, layers - 1, 5, parent)) invalid++;
      double inputs[SAMPLES][INPUTS], a[SAMPLES][OUTPUTS], b[SAMPLES][OUTPUTS];
      random_inputs(inputs);
      run_all(parent, inputs, a);
      run_all(child, inputs, b);
      for (int s = 0; s < SAMPLES; s++) {
        double scale = 0;
        int a_best = 0, b_best = 0;
        for (int o = 0; o < OUTPUTS; o++) {
          scale = fmax(scale, fabs(a[s][o]));
          if (a[s][o] > a[s][a_best]) a_best = o;
          if (b[s][o] > b[s][b_best]) b_best = o;
        }
        for (int o = 0; o < OUTPUTS; o++) {
          if (!(fabs(a[s][o] - b[s][o]) <= 1e-9 * scale)) too_far++;
        }
        if (a_best != b_best) other_move++;
      }
      genann_free(child);
      genann_free(parent);
    }
  }
  lequal(invalid, 0);
  lequal(too_far, 0);
  lequal(other_move, 0);
}

// Adding a layer and removing it again gives the parent back: byte for byte
// and with == outputs for linear, relu, and tanh, and to 1e-9 for the
// sigmoids, whose compensation the fold undoes. Threshold's does not undo, so
// it only has to keep the shape.
void test_add_then_remove_round_trips() {
  pcg32_srandom(25, 54u);
  int invalid = 0, other_bytes = 0, different = 0, too_far = 0;
  for (int layers = 1; layers <= 3; layers++) {
    for (int h = 0; h < ANN_ACTIVATION_COUNT; h++) {
      for (int o = 0; o < ANN_ACTIVATION_COUNT; o++) {
        genann_actfun f = ANN_ACTIVATIONS[h].function;
        genann *parent = random_network(layers, 4, f, ANN_ACTIVATIONS[o].function);
        genann *added = add_layer(parent, 9);
        genann *child = remove_layer(added);
        if (!valid_network(child, layers, 4, parent)) invalid++;
        bool equal;
        double difference = largest_difference(parent, child, &equal);
        if (f == genann_act_linear || f == genann_act_relu || f == genann_act_tanh) {
          if (memcmp(parent->weight, child->weight, sizeof(double) * parent->total_weights) != 0) other_bytes++;
          if (!equal) different++;
        } else if (f == genann_act_sigmoid || f == genann_act_sigmoid_cached) {
          for (int i = 0; i < parent->total_weights; i++) {
            if (!(fabs(parent->weight[i] - child->weight[i]) <= 1e-9)) too_far++;
          }
          if (!(difference <= 1e-9)) too_far++;
        }
        genann_free(child);
        genann_free(added);
        genann_free(parent);
      }
    }
  }
  lequal(invalid, 0);
  lequal(other_bytes, 0);
  lequal(different, 0);
  lequal(too_far, 0);
  // From no hidden layers and back, the shape is the parent's.
  genann *flat = random_network(0, 0, genann_act_sigmoid_cached, genann_act_sigmoid_cached);
  genann *added = add_layer(flat, 3);
  genann *back = remove_layer(added);
  lok(valid_network(back, 0, 0, flat));
  genann_free(back);
  genann_free(added);
  genann_free(flat);
}

// The operators draw only their own numbers: building the reshaped network
// draws nothing. After each, the generator is where replaying just those
// draws leaves it.
void test_structure_operators_draw_only_their_own_numbers() {
  pcg32_srandom(30, 54u);
  int wrong = 0;
  for (int layers = 1; layers <= 3; layers++) {
    genann *parent = random_network(layers, 3, genann_act_tanh, genann_act_linear);
    for (int op = 0; op < 4; op++) {
      pcg32_srandom(31 + op, 54u);
      genann *child = NULL;
      switch (op) {
        case 0: child = remove_layer(parent); break;
        case 1: child = add_layer(parent, 5); break;
        case 2: child = widen(parent); break;
        default: child = narrow(parent); break;
      }
      uint32_t after = pcg32_random();
      pcg32_srandom(31 + op, 54u);
      if (op == 2) {
        // The new first-layer row, then a row of width + 2 per later layer.
        int draws = (INPUTS + 1) + (layers - 1) * (3 + 2);
        for (int d = 0; d < draws; d++) pcg32_random();
      } else if (op == 3) {
        for (int h = 0; h < layers; h++) pcg32_boundedrand(3);
      }
      if (pcg32_random() != after) wrong++;
      genann_free(child);
    }
    genann_free(parent);
  }
  lequal(wrong, 0);
}

// The bounds allow widen below max_layer_size, narrow above width 1 (both
// only with hidden layers), add_layer below max_hidden_layers, and
// remove_layer with hidden layers.
void test_allowed_structure_changes() {
  shape_bounds bounds = {.max_hidden_layers = 2, .max_layer_size = 4, .add_layer_size = 3};
  struct { int layers, width, count; structure_change changes[4]; } cases[] = {
    {0, 0, 1, {STRUCTURE_ADD_LAYER}},
    {1, 1, 3, {STRUCTURE_WIDEN, STRUCTURE_ADD_LAYER, STRUCTURE_REMOVE_LAYER}},
    {1, 2, 4, {STRUCTURE_WIDEN, STRUCTURE_NARROW, STRUCTURE_ADD_LAYER, STRUCTURE_REMOVE_LAYER}},
    {2, 4, 2, {STRUCTURE_NARROW, STRUCTURE_REMOVE_LAYER}},
    {2, 1, 2, {STRUCTURE_WIDEN, STRUCTURE_REMOVE_LAYER}},
  };
  for (unsigned c = 0; c < sizeof cases / sizeof cases[0]; c++) {
    genann *ann = random_network(cases[c].layers, cases[c].width, genann_act_linear, genann_act_linear);
    structure_change changes[4];
    int count = allowed_structure_changes(ann, &bounds, changes);
    lequal(count, cases[c].count);
    for (int i = 0; i < count && i < cases[c].count; i++) lok(changes[i] == cases[c].changes[i]);
    genann_free(ann);
  }
  shape_bounds flat = {.max_hidden_layers = 0, .max_layer_size = 4, .add_layer_size = 3};
  genann *ann = random_network(0, 0, genann_act_linear, genann_act_linear);
  structure_change changes[4];
  lequal(allowed_structure_changes(ann, &flat, changes), 0);
  genann_free(ann);
}

// A mutated child changes its structure with its structure_rate gene, by one
// of the allowed changes chosen uniformly, and its shape shows the change.
void test_mutate_changes_the_structure_by_the_gene() {
  pcg32_srandom(26, 54u);
  shape_bounds bounds = {.max_hidden_layers = 3, .max_layer_size = 4, .add_layer_size = 2};
  genann *four = random_network(2, 3, genann_act_relu, genann_act_linear);
  genann *two = random_network(3, 4, genann_act_relu, genann_act_linear);
  genann *parents[] = {four, two};
  int allowed[] = {4, 2};
  ann_genes genes = middle_genes();
  genes.copy_chance = ANN_COPY_CHANCE_MIN;
  genes.structure_rate = 0.4;
  const int children = 12000;
  for (int p = 0; p < 2; p++) {
    genann *parent = parents[p];
    long counts[5] = {0};
    int wrong_shape = 0;
    for (int c = 0; c < children; c++) {
      ann_genes child_genes;
      mutation_outcome outcome;
      genann *child = mutate(parent, &genes, 0, &bounds, &child_genes, &outcome);
      counts[outcome.structure]++;
      int layers = parent->hidden_layers, width = parent->hidden;
      switch (outcome.structure) {
        case STRUCTURE_WIDEN: width++; break;
        case STRUCTURE_NARROW: width--; break;
        case STRUCTURE_ADD_LAYER: layers++; break;
        case STRUCTURE_REMOVE_LAYER: layers--; break;
        default: break;
      }
      if (child->hidden_layers != layers || (layers > 0 && child->hidden != width)) wrong_shape++;
      genann_free(child);
    }
    lequal(wrong_shape, 0);
    long changed = children - counts[STRUCTURE_NONE];
    // SE = sqrt(0.4 · 0.6 / 12000) = 0.0045.
    check_close("share of structural changes", (double)changed / children, 0.4, 0.018);
    if (p == 1) {
      lequal((int)counts[STRUCTURE_WIDEN], 0);
      lequal((int)counts[STRUCTURE_ADD_LAYER], 0);
    }
    for (int s = 1; s < 5; s++) {
      if (p == 1 && (s == STRUCTURE_WIDEN || s == STRUCTURE_ADD_LAYER)) continue;
      // Among about 4,800 changes: SE at most sqrt(0.25 · 0.75 / 4800) = 0.0063.
      check_close("share of one structural change", (double)counts[s] / changed, 1.0 / allowed[p], 0.028);
    }
  }
  genann_free(two);
  genann_free(four);
}

// However often the structure changes, the child stays within the bounds
// (for a parent within them), is a valid network, and its weight_changes
// gene is clamped against its own total_weights, not the parent's: after a
// widening it may exceed the parent's.
void test_mutate_keeps_the_structure_in_bounds() {
  pcg32_srandom(27, 54u);
  shape_bounds bounds = {.max_hidden_layers = 2, .max_layer_size = 3, .add_layer_size = 2};
  ann_genes genes = middle_genes();
  genes.copy_chance = ANN_COPY_CHANCE_MIN;
  genes.structure_rate = ANN_STRUCTURE_RATE_MAX;
  int out_of_bounds = 0, invalid = 0, above_parent = 0;
  for (int layers = 0; layers <= 2; layers++) {
    for (int width = 1; width <= 3; width++) {
      genann *parent = random_network(layers, width, genann_act_tanh, genann_act_sigmoid_cached);
      genes.weight_changes = parent->total_weights;
      for (int c = 0; c < 500; c++) {
        ann_genes child_genes;
        mutation_outcome outcome;
        genann *child = mutate(parent, &genes, 0.5, &bounds, &child_genes, &outcome);
        if (child->hidden_layers < 0 || child->hidden_layers > bounds.max_hidden_layers) out_of_bounds++;
        if (child->hidden_layers > 0 && (child->hidden < 1 || child->hidden > bounds.max_layer_size)) out_of_bounds++;
        if (ann_genes_invalid(&child_genes, child->total_weights)) invalid++;
        if (child_genes.weight_changes > parent->total_weights) above_parent++;
        for (int i = 0; i < child->total_weights; i++) {
          if (!isfinite(child->weight[i])) invalid++;
        }
        genann_free(child);
      }
      genann_free(parent);
    }
  }
  lequal(out_of_bounds, 0);
  lequal(invalid, 0);
  lok(above_parent > 0);
}

// When the bounds allow no change, the structure is not even drawn: the
// child is the one mutate() gives without bounds.
void test_mutate_draws_no_structure_when_none_is_allowed() {
  genann *parent = random_network(0, 0, genann_act_linear, genann_act_linear);
  shape_bounds bounds = {.max_hidden_layers = 0, .max_layer_size = 4, .add_layer_size = 2};
  ann_genes genes = middle_genes();
  genes.copy_chance = ANN_COPY_CHANCE_MIN;
  genes.structure_rate = ANN_STRUCTURE_RATE_MAX;
  int different = 0;
  for (uint64_t seed = 0; seed < 50; seed++) {
    ann_genes a_genes, b_genes;
    mutation_outcome outcome;
    pcg32_srandom(seed, 54u);
    genann *a = mutate(parent, &genes, META_RATE, &bounds, &a_genes, &outcome);
    pcg32_srandom(seed, 54u);
    genann *b = mutate(parent, &genes, META_RATE, NULL, &b_genes, NULL);
    if (outcome.structure != STRUCTURE_NONE || !same_genes(&a_genes, &b_genes)
        || memcmp(a->weight, b->weight, sizeof(double) * a->total_weights) != 0) different++;
    genann_free(b);
    genann_free(a);
  }
  lequal(different, 0);
  genann_free(parent);
}

// A seed gives one child, structure included.
void test_mutate_structure_is_deterministic_for_a_seed() {
  pcg32_srandom(28, 54u);
  genann *parent = random_network(2, 3, genann_act_sigmoid_cached, genann_act_sigmoid_cached);
  shape_bounds bounds = {.max_hidden_layers = 3, .max_layer_size = 4, .add_layer_size = 2};
  ann_genes genes = middle_genes();
  genes.structure_rate = ANN_STRUCTURE_RATE_MAX;
  int different = 0, seen = 0;
  for (uint64_t seed = 0; seed < 60; seed++) {
    static unsigned char a[8192], b[8192];
    ann_genes a_genes, b_genes;
    mutation_outcome outcome;
    pcg32_srandom(seed, 54u);
    genann *first = mutate(parent, &genes, META_RATE, &bounds, &a_genes, &outcome);
    pcg32_srandom(seed, 54u);
    genann *second = mutate(parent, &genes, META_RATE, &bounds, &b_genes, NULL);
    seen |= 1 << outcome.structure;
    size_t a_length = child_bytes(first, &a_genes, a, sizeof a);
    size_t b_length = child_bytes(second, &b_genes, b, sizeof b);
    if (a_length == 0 || a_length != b_length || memcmp(a, b, a_length) != 0) different++;
    genann_free(second);
    genann_free(first);
  }
  lequal(different, 0);
  // Every change came up.
  lequal(seen, 31);
  genann_free(parent);
}

// With crossover rate 1 parents of the same shape always cross over, and
// parents of different shapes never: their child is a mutation of the picked
// parent.
void test_breed_crosses_over_only_the_same_shape() {
  pcg32_srandom(29, 54u);
  shape_bounds bounds = {.max_hidden_layers = 3, .max_layer_size = 5, .add_layer_size = 2};
  ann_genes genes[2] = {middle_genes(), middle_genes()};
  genann *a = random_network(1, 3, genann_act_tanh, genann_act_linear);
  genann *same = random_network(1, 3, genann_act_relu, genann_act_linear);
  genann *wider = random_network(1, 4, genann_act_tanh, genann_act_linear);
  genann *deeper = random_network(2, 3, genann_act_tanh, genann_act_linear);
  genann *flat = random_network(0, 0, genann_act_tanh, genann_act_linear);
  genann *flat_too = random_network(0, 0, genann_act_relu, genann_act_linear);
  flat_too->hidden = 5;
  int wrong = 0, picked_first = 0;
  for (int k = 0; k < 400; k++) {
    breeding result;
    genann *pair[2] = {a, same};
    genann *child = breed(pair, genes, 1, META_RATE, &bounds, &result);
    if (strcmp(result.operator_name, "crossover") != 0) wrong++;
    genann_free(child);
    genann *flats[2] = {flat, flat_too};
    child = breed(flats, genes, 1, META_RATE, &bounds, &result);
    if (strcmp(result.operator_name, "crossover") != 0) wrong++;
    genann_free(child);
    genann *others[] = {wider, deeper};
    for (int i = 0; i < 2; i++) {
      genann *mixed[2] = {a, others[i]};
      child = breed(mixed, genes, 1, META_RATE, &bounds, &result);
      if (strcmp(result.operator_name, "crossover") == 0) wrong++;
      if (result.picked == 0) picked_first++;
      // Unless its structure changed, it has its picked parent's shape.
      if (result.outcome.structure == STRUCTURE_NONE && !same_shape(child, mixed[result.picked])) wrong++;
      genann_free(child);
    }
  }
  lequal(wrong, 0);
  lok(picked_first > 320 && picked_first < 480);
  genann_free(flat_too);
  genann_free(flat);
  genann_free(deeper);
  genann_free(wider);
  genann_free(same);
  genann_free(a);
}

int main(int argc, char **argv) {
  printf("Evolve test suite\n");

  lrun("cross_over", test_cross_over);
  lrun("parents_match", test_parents_must_match);
  lrun("mutate_copy", test_mutate_copies_the_parent);
  lrun("mutate_seed", test_mutate_is_deterministic_for_a_seed);
  lrun("mutate_copy_chance", test_mutate_copies_with_copy_chance);
  lrun("mutate_weights", test_mutate_changes_weights_by_the_genes);
  lrun("mutate_every_weight", test_mutate_changes_every_weight_at_most);
  lrun("mutate_new_genes", test_mutate_uses_the_mutated_genes);
  lrun("mutate_gene_distributions", test_mutate_genes_distributions);
  lrun("mutate_gene_clamps", test_mutate_genes_clamps);
  lrun("mutate_activations", test_mutate_activations_switches_uniformly);
  lrun("mutate_activation_gene", test_mutate_switches_activations_by_the_gene);
  lrun("cross_over_activations", test_cross_over_keeps_the_picked_parents_activations);
  lrun("widen", test_widen_keeps_the_outputs);
  lrun("narrow", test_narrow_removes_a_neuron_per_layer);
  lrun("add_layer", test_add_layer_passes_through);
  lrun("add_first_layer", test_add_layer_to_no_hidden_layers);
  lrun("remove_layer_linear", test_remove_layer_folds_a_linear_layer);
  lrun("add_remove_round_trip", test_add_then_remove_round_trips);
  lrun("structure_draws", test_structure_operators_draw_only_their_own_numbers);
  lrun("allowed_structure", test_allowed_structure_changes);
  lrun("mutate_structure_gene", test_mutate_changes_the_structure_by_the_gene);
  lrun("mutate_structure_bounds", test_mutate_keeps_the_structure_in_bounds);
  lrun("mutate_no_structure_draw", test_mutate_draws_no_structure_when_none_is_allowed);
  lrun("mutate_structure_seed", test_mutate_structure_is_deterministic_for_a_seed);
  lrun("breed_shapes", test_breed_crosses_over_only_the_same_shape);

  lresults();

  return lfails != 0;
}
