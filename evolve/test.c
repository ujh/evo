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
    genann *child = mutate(parent, &genes, meta_rate, &child_genes);
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
  genann *child = mutate(parent, &genes, EVOLVE_META_RATE, &child_genes);

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
  lequal(ann_binary_write(child, genes, file), 0);
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
  genann *first = mutate(parent, &genes, EVOLVE_META_RATE, &first_genes);
  pcg32_srandom(3, 54u);
  genann *second = mutate(parent, &genes, EVOLVE_META_RATE, &second_genes);
  pcg32_srandom(4, 54u);
  genann *other = mutate(parent, &genes, EVOLVE_META_RATE, &other_genes);

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
  mutation_counts counts = mutate_many(parent, genes, EVOLVE_META_RATE, 20000);

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
  const double tau = EVOLVE_META_RATE;
  ann_genes genes = middle_genes();
  double sum[5] = {0}, sum_of_squares[5] = {0};
  long within_tau[5] = {0};
  double sum_of_products = 0;
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
    sum_of_products += step[0] * step[2];
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
  // Independent draws: correlation SE 1/sqrt(n) = 0.007.
  check_close("correlation of two gene steps", sum_of_products / n / (tau * tau), 0.0, 0.028);
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

// Crossing over mixes weights, so both parents must be the same kind of
// network: the same sizes and the same activations.
void test_parents_must_match() {
  genann *a = genann_init(3, 1, 4, 2);
  genann *b = genann_init(3, 1, 4, 2);
  genann *nns[2] = {a, b};
  lok(nns_compatible(nns));

  b->activation_output = genann_act_linear;
  lok(!nns_compatible(nns));
  b->activation_output = a->activation_output;
  b->activation_hidden = genann_act_tanh;
  lok(!nns_compatible(nns));

  genann *c = genann_init(3, 1, 5, 2);
  nns[1] = c;
  lok(!nns_compatible(nns));

  genann_free(c);
  genann_free(b);
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

  lresults();

  return lfails != 0;
}
