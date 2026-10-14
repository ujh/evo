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
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "evolve.h"

// perturb NET OUT WEIGHT_CHANGES WEIGHT_STEP SEED
//
// Writes to OUT a child of NET that differs from it only in its network
// weights: perturb_weights() with the WEIGHT_CHANGES and WEIGHT_STEP given
// (not NET's genes), once, from the generator seeded with SEED after NET is
// read. The child keeps NET's shape, activations, genes, and features, and
// is never a copy by chance: there is no copy check. Prints one line,
// differs=N, the number of weights that differ from NET's. The child is
// written to a temporary file next to OUT and renamed onto it, so OUT is
// either as it was or the whole child. Every refusal exits 1 with a message
// and leaves OUT as it was and no temporary file behind.
static genann *read_network(const char *name, ann_genes *genes, ann_features *features) {
  FILE *in = fopen(name, "rb");
  if (in == NULL) {
    fprintf(stderr, "Could not open %s: %s\n", name, strerror(errno));
    exit(1);
  }
  genann *ann = ann_binary_read(in, genes, features);
  fclose(in);
  if (ann == NULL) {
    fprintf(stderr, "Could not read a network from %s\n", name);
    exit(1);
  }
  return ann;
}

// Writes the child to a new file in OUT's directory and renames it onto OUT.
// The file gets the mode a new file would get (0666 less the umask), not
// mkstemp's 0600.
static void write_network(const char *out_name, genann const *ann, ann_genes const *genes,
                          ann_features const *features) {
  size_t length = strlen(out_name) + sizeof ".tmp.XXXXXX";
  char *temporary = malloc(length);
  snprintf(temporary, length, "%s.tmp.XXXXXX", out_name);
  int fd = mkstemp(temporary);
  if (fd == -1) {
    fprintf(stderr, "Could not create a temporary file for %s: %s\n", out_name, strerror(errno));
    exit(1);
  }
  mode_t mask = umask(0);
  umask(mask);
  FILE *out = fdopen(fd, "wb");
  bool failed = out == NULL || fchmod(fd, 0666 & ~mask) != 0;
  if (!failed) failed = ann_binary_write(ann, genes, features, out) != 0;
  if (out != NULL) {
    if (fclose(out) != 0) failed = true;
  } else {
    close(fd);
  }
  if (failed || rename(temporary, out_name) != 0) {
    fprintf(stderr, "Could not write %s: %s\n", out_name, strerror(errno));
    remove(temporary);
    exit(1);
  }
  free(temporary);
}

int main(int argc, char **argv) {
  if (argc != 6) {
    fprintf(stderr, "usage: perturb NET OUT WEIGHT_CHANGES WEIGHT_STEP SEED\n");
    exit(1);
  }
  const char *net_name = argv[1];
  const char *out_name = argv[2];
  // The genes' ranges: weight_changes runs up to the network's weights, so
  // it is parsed once the network is read.
  double weight_step = parse_number("WEIGHT_STEP", argv[4], ANN_WEIGHT_STEP_MIN, ANN_WEIGHT_STEP_MAX);
  uint64_t seed_value = parse_seed(argv[5]);
  ann_genes genes;
  ann_features features;
  genann *parent = read_network(net_name, &genes, &features);
  double weight_changes = parse_number("WEIGHT_CHANGES", argv[3], ANN_WEIGHT_CHANGES_MIN, parent->total_weights);

  // Seeded after the read, whose genann_init draws, so the child depends
  // only on NET's weights and the seed.
  pcg32_srandom(seed_value, 54u);
  genann *child = genann_copy(parent);
  perturb_weights(child, weight_changes, weight_step);
  write_network(out_name, child, &genes, &features);
  printf("differs=%d\n", count_differences(child, parent));
  genann_free(child);
  genann_free(parent);
  return 0;
}
