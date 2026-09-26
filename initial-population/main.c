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
#include <time.h>

#include "ann.h"

pcg32_random_t rng;

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

// A gene is a finite decimal number; anything else is an error. Whether it
// lies in its range is checked once the network's size is known.
static double parse_gene(const char *name, const char *text) {
  char *end;
  errno = 0;
  double value = strtod(text, &end);
  if (errno != 0 || end == text || *end != '\0' || !isfinite(value)) {
    fprintf(stderr, "%s must be a finite number, got %s\n", name, text);
    exit(1);
  }
  return value;
}

int main(int argc, char **argv) {

  // Do not buffer stdout
  setbuf(stdout, NULL);

  int population_size, board_size, hidden_layers, hidden;

  if (argc != 10 && argc != 11) {
    fprintf(stderr, "9 arguments required: population_size, board size, no. hidden layers, no. neurons per layer, "
                    "copy_chance, weight_changes, weight_step, activation_rate, structure_rate, and optionally a seed!\n");
    exit(1);
  }

  // Without a seed the networks differ on every run.
  if (argc == 11) {
    pcg32_srandom(parse_seed(argv[10]), 54u);
  } else {
    pcg32_srandom(time(NULL), (intptr_t)&rng);
  }

  population_size = atoi(argv[1]);
  board_size = atoi(argv[2]);
  hidden_layers = atoi(argv[3]);
  hidden = atoi(argv[4]);
  // A network plays one square board, and the .ann reader refuses others.
  if (board_size < ANN_MIN_SIDE || board_size > ANN_MAX_SIDE) {
    fprintf(stderr, "board size must be %d to %d, got %s\n", ANN_MIN_SIDE, ANN_MAX_SIDE, argv[2]);
    exit(1);
  }
  // Every network starts with the same genes.
  ann_genes genes = {
    .copy_chance = parse_gene("copy_chance", argv[5]),
    .weight_changes = parse_gene("weight_changes", argv[6]),
    .weight_step = parse_gene("weight_step", argv[7]),
    .activation_rate = parse_gene("activation_rate", argv[8]),
    .structure_rate = parse_gene("structure_rate", argv[9]),
  };

  printf(
    "population_size = %d, board_size = %d, hidden_layers = %d, hidden = %d\n",
    population_size,
    board_size,
    hidden_layers,
    hidden
  );

  // No feature groups yet: every network sees only komi and the stones.
  ann_features features = ann_default_features(0);

  char buffer[32];
  // Komi, the stones, and the features' inputs
  int inputs = ann_layout_inputs(features.groups, board_size * board_size);
  // Allow pass move
  int outputs = (board_size * board_size) + 1;

  for(int i = 1; i <= population_size; i++) {
    snprintf(buffer, sizeof(buffer), "%04d.ann", i);

    genann *ann = genann_init(inputs, hidden_layers, hidden, outputs);
    if (ann == NULL) {
      fprintf(stderr, "Cannot build a network with %d hidden layers of %d\n", hidden_layers, hidden);
      exit(1);
    }
    const char *bad = ann_genes_invalid(&genes, ann->total_weights);
    if (bad) {
      fprintf(stderr, "%s is out of range for a network of %d weights\n", bad, ann->total_weights);
      exit(1);
    }
    FILE *fd = fopen(buffer, "wb");
    if (fd == NULL) {
      fprintf(stderr, "Could not open %s: %s\n", buffer, strerror(errno));
      exit(1);
    }
    int written = ann_binary_write(ann, &genes, &features, fd);
    // A half-written network is removed, so the runner never stores one.
    if (fclose(fd) != 0 || written != 0) {
      fprintf(stderr, "Could not write %s\n", buffer);
      remove(buffer);
      exit(1);
    }
    // One machine-readable line per network, in file order.
    ann_print_genes_line(stdout, ann, &genes, &features);
    genann_free(ann);
  }
}
