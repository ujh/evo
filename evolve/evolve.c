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
static genann *load_nn(char *name, ann_genes *genes) {
  printf("Loading %s ...", name);
  FILE *fd = fopen(name, "rb");
  if (fd == NULL) {
    fprintf(stderr, "\nCould not open %s: %s\n", name, strerror(errno));
    exit(1);
  }
  genann *ann = ann_binary_read(fd, genes);
  fclose(fd);
  if (ann == NULL) {
    fprintf(stderr, "\nCould not read a network from %s\n", name);
    exit(1);
  }
  printf("\n");
  return ann;
}

genann **load_nns(char *ann1_name, char *ann2_name, ann_genes genes[2]) {
  genann **anns = malloc(2 * sizeof(genann *));
  anns[0] = load_nn(ann1_name, &genes[0]);
  anns[1] = load_nn(ann2_name, &genes[1]);
  return anns;
}

// Prints each difference between the parents that makes them impossible to
// breed, and returns whether there was none. Activations and genes do not
// count: the child takes them from the picked parent.
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
  if (nn1->hidden_layers != nn2->hidden_layers) {
    printf("nn1.hidden_layers = %d, nn2.hidden_layers = %d\n", nn1->hidden_layers, nn2->hidden_layers);
    failed = true;
  }
  if (nn1->hidden != nn2->hidden) {
    printf("nn1.hidden = %d, nn2.hidden = %d\n", nn1->hidden, nn2->hidden);
    failed = true;
  }
  return !failed;
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
                            int *picked, ann_genes *child_genes, mutation_outcome *outcome) {
  // Pick a NN to use
  *picked = pcg32_boundedrand(2);
  // Do the mutations
  return mutate(nns[*picked], &genes[*picked], meta_rate, child_genes, outcome);
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

// The draws come in a fixed order, so a seed gives one child: the copy
// check, the genes, the activations, then the weights.
genann *mutate(genann const *parent, ann_genes const *parent_genes, double meta_rate,
               ann_genes *child_genes, mutation_outcome *outcome) {
  mutation_outcome result = {.copy = false, .activation_changed = false};
  genann *child = genann_copy(parent);
  *child_genes = *parent_genes;
  if (GENANN_RANDOM() < parent_genes->copy_chance) {
    result.copy = true;
    if (outcome) *outcome = result;
    return child;
  }

  // weight_changes is clamped against the child's final total_weights. No
  // structural change exists yet, so that is the parent's.
  *child_genes = mutate_genes(*parent_genes, meta_rate, child->total_weights);

  result.activation_changed = mutate_activations(child, child_genes->activation_rate);

  // The structure draw goes here, after the activations.

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
