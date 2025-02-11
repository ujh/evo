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
#include <math.h>
#include <stdbool.h>
#include <stdlib.h>
#include <time.h>

#include "evolve.h"
#include "genann.h"

pcg32_random_t rng;

void seed() {
  pcg32_srandom(time(NULL), (intptr_t)&rng);
}

genann **load_nns(char *ann1_name, char *ann2_name) {
  genann **anns = malloc(2 * sizeof(genann *));

  printf("Loading %s ...", ann1_name);
  FILE *fd = fopen(ann1_name, "r");
  anns[0] = genann_read(fd);
  fclose(fd);
  printf("\nLoading %s ...", ann2_name);
  fd = fopen(ann2_name, "r");
  anns[1] = genann_read(fd);
  fclose(fd);
  printf("\n");

  return anns;
}

void check_nns(genann **nns) {
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

  if (failed) {
    printf("Sanity check failed!\n");
    exit(1);
  }
  printf("Sanity check passed\n");
}

genann *child_from_cross_over(genann **nns) {
  printf("Cross over\n");
  // Pick order in which to use the NNs
  int i = pcg32_boundedrand(2);
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

genann *child_from_mutation(genann **nns) {
  printf("Mutation\n");
  // Pick a NN to use
  genann *parent = nns[pcg32_boundedrand(2)];
  // Do the mutations
  return mutate(parent);
}

genann *mutate(genann *parent) {
  genann *child = genann_copy(parent);
  // Hacky way to also have a slight chance of no mutation at all.
  if (GENANN_RANDOM() < 0.01) return child;

  float mutation_rate = 0.0004; // 1/2500
  for (int i = 0; i < child->total_weights; i++)
  {
    if (GENANN_RANDOM() < mutation_rate) {
      child->weight[i] += (GENANN_RANDOM() - 0.5);
    }
  }

  return child;
}
