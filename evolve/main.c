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
#include <limits.h>
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

// A decimal number in [min, max]; anything else is an error.
static double parse_number(const char *name, const char *text, double min, double max) {
  char *end;
  errno = 0;
  double value = strtod(text, &end);
  if (errno != 0 || end == text || *end != '\0' || !isfinite(value) || value < min || value > max) {
    fprintf(stderr, "%s must be a number from %g to %g, got %s\n", name, min, max, text);
    exit(1);
  }
  return value;
}

// A decimal whole number in [min, max]; anything else is an error.
static int parse_whole(const char *name, const char *text, long min, long max) {
  char *end;
  errno = 0;
  long value = strtol(text, &end, 10);
  if (errno != 0 || end == text || *end != '\0' || value < min || value > max) {
    fprintf(stderr, "%s must be a whole number from %ld to %ld, got %s\n", name, min, max, text);
    exit(1);
  }
  return (int)value;
}

// How many weights of the child differ from a parent's, or -1 when their
// shapes differ.
static int count_differences(genann const *child, genann const *parent) {
  if (!same_shape(child, parent)) return -1;
  int differences = 0;
  for (int i = 0; i < child->total_weights; i++) {
    if (child->weight[i] != parent->weight[i]) differences++;
  }
  return differences;
}

int main(int argc, char **argv) {
  // Do not buffer stdout
  setbuf(stdout, NULL);

  if (argc != 9 && argc != 10) {
    fprintf(stderr, "8 arguments required: cross_over_rate, meta_rate, max_hidden_layers, max_layer_size, "
                    "add_layer_size, ann1, ann2, output, and optionally a seed!\n");
    exit(1);
  }

  // Without a seed the child differs on every run.
  if (argc == 10) {
    pcg32_srandom(parse_seed(argv[9]), 54u);
  } else {
    seed();
  }

  double cross_over_rate = parse_number("cross_over_rate", argv[1], 0, 1);
  double meta_rate = parse_number("meta_rate", argv[2], 0, HUGE_VAL);
  // The bounds on the child's shape, and the width of a layer added to a
  // network without hidden layers.
  shape_bounds bounds;
  bounds.max_hidden_layers = parse_whole("max_hidden_layers", argv[3], 0, INT_MAX);
  bounds.max_layer_size = parse_whole("max_layer_size", argv[4], 1, INT_MAX);
  bounds.add_layer_size = parse_whole("add_layer_size", argv[5], 1, bounds.max_layer_size);
  char *ann1_name = argv[6];
  char *ann2_name = argv[7];
  char *output_name = argv[8];

  printf(
    "cross_over_rate = %f, meta_rate = %f, max_hidden_layers = %d, max_layer_size = %d, add_layer_size = %d, "
    "ann1_name = %s, ann2_name = %s\n",
    cross_over_rate,
    meta_rate,
    bounds.max_hidden_layers,
    bounds.max_layer_size,
    bounds.add_layer_size,
    ann1_name,
    ann2_name
  );

  ann_genes genes[2];
  ann_features features[2];
  genann **anns = load_nns(ann1_name, ann2_name, genes, features);
  check_nns(anns);

  breeding result;
  genann *child = breed(anns, genes, cross_over_rate, meta_rate, &bounds, &result);
  printf("%s\n", result.operator_name);

  printf("Saving output to %s ...", output_name);
  FILE *fd = fopen(output_name, "wb");
  if (fd == NULL) {
    fprintf(stderr, "\nCould not open %s: %s\n", output_name, strerror(errno));
    exit(1);
  }
  // A half-written child is removed, so the runner never finds one.
  // The child's features are the picked parent's, unchanged, whatever the
  // operator: nothing breeds them yet.
  int written = ann_binary_write(child, &result.genes, &features[result.picked], fd);
  if (fclose(fd) != 0 || written != 0) {
    fprintf(stderr, "\nCould not write %s: %s\n", output_name, strerror(errno));
    remove(output_name);
    exit(1);
  }
  printf("\n");

  // Two machine-readable lines for the runner, the child's genes last.
  // parent is the picked parent in argument order. A child identical to a
  // parent differs from it in 0 weights, and one of another shape in -1.
  printf(
    "summary operator=%s parent=%s structure=%s activation_changed=%d differs_from_first=%d differs_from_second=%d\n",
    result.operator_name,
    result.picked == 0 ? "first" : "second",
    structure_name(result.outcome.structure),
    result.outcome.activation_changed ? 1 : 0,
    count_differences(child, anns[0]),
    count_differences(child, anns[1])
  );
  ann_print_genes_line(stdout, child, &result.genes);
}
