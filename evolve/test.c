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

#include "evolve.h"
#include "minctest.h"

double returns_point_three() { return 0.3; }
double returns_point_one() { return 0.1; }
double returns_point_nine_nine() { return 0.99; }
double returns_point_seven() { return 0.7; }

void test_cross_over() {
  genann *nn1 = genann_init(1, 1, 1, 1);
  genann *nn2 = genann_init(1, 1, 1, 1);
  genann *child = cross_over(nn1, nn2, 2);

  lfequal(nn1->weight[0], child->weight[0]);
  lfequal(nn1->weight[1], child->weight[1]);
  lfequal(nn2->weight[2], child->weight[2]);
  lfequal(nn2->weight[3], child->weight[3]);
}

// The mutation tests pin down what mutate() does today, so that a change to
// it shows up as a failing test. Their tolerances are about four standard
// errors wide (3.8 to 5). The generator is seeded, so each run draws the same
// numbers.

// Like lfequal, with a tolerance chosen by the test.
static void check_close(const char *what, double actual, double expected, double tolerance) {
  ++ltests;
  if (fabs(actual - expected) > tolerance) {
    ++lfails;
    printf("%s: %f is not within %f of %f\n", what, actual, tolerance, expected);
  }
}

typedef struct {
  int children;
  int unchanged_children;
  long changed_weights;
  // Over the changed weights: the largest change in size, the sum of the
  // changes, and how many changed by less than 0.25.
  double largest_change;
  double sum_of_changes;
  long small_changes;
} mutation_counts;

// Mutates the same parent many times and counts what changed.
static mutation_counts mutate_many(genann *parent, int children) {
  mutation_counts counts = {0};
  counts.children = children;
  for (int c = 0; c < children; c++) {
    genann *child = mutate(parent);
    bool unchanged = true;
    for (int i = 0; i < parent->total_weights; i++) {
      double change = child->weight[i] - parent->weight[i];
      if (change == 0) continue;
      unchanged = false;
      counts.changed_weights++;
      counts.sum_of_changes += change;
      if (fabs(change) > counts.largest_change) counts.largest_change = fabs(change);
      if (fabs(change) < 0.25) counts.small_changes++;
    }
    if (unchanged) counts.unchanged_children++;
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
  genann *child = mutate(parent);

  lok(child != parent);
  lok(child->weight != parent->weight);
  lequal(child->inputs, parent->inputs);
  lequal(child->hidden_layers, parent->hidden_layers);
  lequal(child->hidden, parent->hidden);
  lequal(child->outputs, parent->outputs);
  lequal(child->total_weights, parent->total_weights);
  // The child changed, and the parent itself is left alone.
  bool child_changed = false;
  bool parent_unchanged = true;
  for (int i = 0; i < parent->total_weights; i++) {
    if (child->weight[i] != before->weight[i]) child_changed = true;
    if (parent->weight[i] != before->weight[i]) parent_unchanged = false;
  }
  lok(child_changed);
  lok(parent_unchanged);

  genann_free(child);
  genann_free(before);
  genann_free(parent);
}

void test_mutate_is_deterministic_for_a_seed() {
  pcg32_srandom(2, 54u);
  genann *parent = genann_init(82, 1, 100, 82);

  pcg32_srandom(3, 54u);
  genann *first = mutate(parent);
  pcg32_srandom(3, 54u);
  genann *second = mutate(parent);
  pcg32_srandom(4, 54u);
  genann *other = mutate(parent);

  bool same = true;
  bool differs = false;
  for (int i = 0; i < parent->total_weights; i++) {
    if (first->weight[i] != second->weight[i]) same = false;
    if (first->weight[i] != other->weight[i]) differs = true;
  }
  lok(same);
  lok(differs);

  genann_free(other);
  genann_free(second);
  genann_free(first);
  genann_free(parent);
}

// A network of 41,332 weights. The chance that a mutation attempt changes no
// weight is 0.9996^41332, about 1e-7, so the unchanged children are the 1%
// that mutate() returns as plain copies.
void test_mutate_statistics_on_a_large_network() {
  pcg32_srandom(5, 54u);
  genann *parent = genann_init(82, 1, 250, 82);
  lequal(parent->total_weights, 41332);
  mutation_counts counts = mutate_many(parent, 4000);

  // 1% of children are plain copies.
  check_close("share of unchanged children",
              (double)counts.unchanged_children / counts.children, 0.01, 0.006);
  // The other 99% change each weight with probability 0.0004.
  double trials = (double)counts.children * parent->total_weights;
  check_close("changed weights per weight",
              counts.changed_weights / trials, 0.99 * 0.0004, 0.99 * 0.0004 * 0.02);
  // Each change is uniform between -0.5 and +0.5.
  lok(counts.largest_change <= 0.5 + 1e-9);
  check_close("mean change",
              counts.sum_of_changes / counts.changed_weights, 0.0, 0.005);
  check_close("share of changes smaller than 0.25",
              (double)counts.small_changes / counts.changed_weights, 0.5, 0.01);

  genann_free(parent);
}

// A network the size of engine/example.ann (418 weights): a child is
// unchanged with probability 0.01 + 0.99 * 0.9996^418, about 84.75%.
void test_mutate_leaves_most_small_children_unchanged() {
  pcg32_srandom(6, 54u);
  genann *parent = genann_init(82, 2, 2, 82);
  lequal(parent->total_weights, 418);
  mutation_counts counts = mutate_many(parent, 20000);

  double expected = 0.01 + 0.99 * pow(1 - 0.0004, 418);
  check_close("share of unchanged children",
              (double)counts.unchanged_children / counts.children, expected, 0.011);

  genann_free(parent);
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
  lrun("mutate_large", test_mutate_statistics_on_a_large_network);
  lrun("mutate_small", test_mutate_leaves_most_small_children_unchanged);

  lresults();

  return lfails != 0;
}
