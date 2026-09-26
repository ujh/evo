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

// GROUPS is none, all, or a comma-separated list of group names
// (ANN_GROUP_NAMES), each at most once, in any order.
static unsigned parse_groups(const char *text) {
  if (strcmp(text, "none") == 0) return 0;
  if (strcmp(text, "all") == 0) return ANN_GROUPS_ALL;
  unsigned groups = 0;
  const char *start = text;
  for (;;) {
    size_t length = strcspn(start, ",");
    unsigned group = 0;
    for (int i = 0; i < ANN_GROUP_COUNT; ++i) {
      if (strlen(ANN_GROUP_NAMES[i].name) == length && strncmp(start, ANN_GROUP_NAMES[i].name, length) == 0) {
        group = ANN_GROUP_NAMES[i].group;
      }
    }
    if (group == 0 || (groups & group)) {
      fprintf(stderr, "groups must be none, all, or distinct group names separated by commas, got %s\n", text);
      exit(1);
    }
    groups |= group;
    if (start[length] == '\0') return groups;
    start += length + 1;
  }
}

int main(int argc, char **argv) {

  // Do not buffer stdout
  setbuf(stdout, NULL);

  int population_size, board_size, hidden_layers, hidden;

  if (argc != 13 && argc != 14) {
    fprintf(stderr, "12 arguments required: population_size, board size, no. hidden layers, no. neurons per layer, "
                    "copy_chance, weight_changes, weight_step, activation_rate, structure_rate, feature groups, "
                    "feature weight noise, feature_step, and optionally a seed!\n");
    exit(1);
  }

  // Without a seed the networks differ on every run.
  if (argc == 14) {
    pcg32_srandom(parse_seed(argv[13]), 54u);
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

  // Every network starts with the groups' starting feature weights, each
  // with its own noise, and the same feature_step.
  ann_features features = ann_default_features(parse_groups(argv[10]));
  double noise = parse_gene("noise", argv[11]);
  if (noise < 0 || noise > 1) {
    fprintf(stderr, "noise must be 0 to 1, got %s\n", argv[11]);
    exit(1);
  }
  features.feature_step = parse_gene("feature_step", argv[12]);
  if (ann_features_invalid(&features)) {
    fprintf(stderr, "feature_step must be %g to %g, got %s\n", ANN_FEATURE_STEP_MIN, ANN_FEATURE_STEP_MAX, argv[12]);
    exit(1);
  }
  int feature_count = ann_feature_count(features.groups);

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
    // After the network's weights, from the same stream: each starting
    // feature weight times 1 + u, u uniform within the noise, so no sign
    // flips. Without move features nothing is drawn.
    ann_features network_features = features;
    for (int f = 0; f < feature_count; ++f) {
      network_features.weights[f] *= 1 + noise * (2 * GENANN_RANDOM() - 1);
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
    int written = ann_binary_write(ann, &genes, &network_features, fd);
    // A half-written network is removed, so the runner never stores one.
    if (fclose(fd) != 0 || written != 0) {
      fprintf(stderr, "Could not write %s\n", buffer);
      remove(buffer);
      exit(1);
    }
    // One machine-readable line per network, in file order.
    ann_print_genes_line(stdout, ann, &genes, &network_features);
    genann_free(ann);
  }
}
