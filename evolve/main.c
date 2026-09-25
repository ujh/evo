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

#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "evolve.h"

// A seed is a non-negative decimal integer; anything else is an error, so a
// typo cannot silently fall back to an unseeded run.
static uint64_t parse_seed(const char *text) {
  char *end;
  errno = 0;
  unsigned long long value = strtoull(text, &end, 10);
  if (errno != 0 || end == text || *end != '\0' || text[0] == '-') {
    fprintf(stderr, "seed must be a non-negative integer, got %s\n", text);
    exit(1);
  }
  return value;
}

// How many weights of the child differ from a parent's.
static int count_differences(genann const *child, genann const *parent) {
  int differences = 0;
  for (int i = 0; i < child->total_weights; i++) {
    if (child->weight[i] != parent->weight[i]) differences++;
  }
  return differences;
}

int main(int argc, char **argv) {
  // Do not buffer stdout
  setbuf(stdout, NULL);

  if (argc != 5 && argc != 6) {
    fprintf(stderr, "4 arguments required: cross_over_rate, ann1, ann2, output, and optionally a seed!\n");
    exit(1);
  }

  // Without a seed the child differs on every run.
  if (argc == 6) {
    pcg32_srandom(parse_seed(argv[5]), 54u);
  } else {
    seed();
  }

  double cross_over_rate = atof(argv[1]);
  char *ann1_name = argv[2];
  char *ann2_name = argv[3];
  char *output_name = argv[4];

  printf(
    "cross_over_rate = %f, ann1_name = %s, ann2_name = %s\n",
    cross_over_rate,
    ann1_name,
    ann2_name
  );

  ann_genes genes[2];
  genann **anns = load_nns(ann1_name, ann2_name, genes);
  check_nns(anns);

  genann *child = NULL;
  const char *operator_name;
  int picked;
  ann_genes child_genes;

  if (GENANN_RANDOM() < cross_over_rate) {
    child = child_from_cross_over(anns, &picked);
    operator_name = "crossover";
    // A crossover child is not mutated: it keeps the genes of the parent
    // whose weights come first.
    child_genes = genes[picked];
  } else {
    child = child_from_mutation(anns, genes, EVOLVE_META_RATE, &picked, &child_genes);
    operator_name = "mutation";
  }

  printf("Saving output to %s ...", output_name);
  FILE *fd = fopen(output_name, "wb");
  if (fd == NULL) {
    fprintf(stderr, "\nCould not open %s: %s\n", output_name, strerror(errno));
    exit(1);
  }
  // A half-written child is removed, so the runner never finds one.
  int written = ann_binary_write(child, &child_genes, fd);
  if (fclose(fd) != 0 || written != 0) {
    fprintf(stderr, "\nCould not write %s: %s\n", output_name, strerror(errno));
    remove(output_name);
    exit(1);
  }
  printf("\n");

  // One machine-readable line for the runner. A child identical to a parent
  // differs from it in 0 weights.
  printf(
    "summary operator=%s differs_from_first=%d differs_from_second=%d\n",
    operator_name,
    count_differences(child, anns[0]),
    count_differences(child, anns[1])
  );
}
