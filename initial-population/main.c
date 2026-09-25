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

int main(int argc, char **argv) {

  // Do not buffer stdout
  setbuf(stdout, NULL);

  int population_size, board_size, hidden_layers, hidden;

  if (argc != 5 && argc != 6) {
    fprintf(stderr, "4 arguments required: population_size, board size, no. hidden layers, no. neurons per layer, and optionally a seed!\n");
    exit(1);
  }

  // Without a seed the networks differ on every run.
  if (argc == 6) {
    pcg32_srandom(parse_seed(argv[5]), 54u);
  } else {
    pcg32_srandom(time(NULL), (intptr_t)&rng);
  }

  population_size = atoi(argv[1]);
  board_size = atoi(argv[2]);
  hidden_layers = atoi(argv[3]);
  hidden = atoi(argv[4]);

  printf(
    "population_size = %d, board_size = %d, hidden_layers = %d, hidden = %d\n",
    population_size,
    board_size,
    hidden_layers,
    hidden
  );

  char buffer[10];
  // Pass in the komi
  int inputs = (board_size * board_size) + 1;
  // Allow pass move
  int outputs = (board_size * board_size) + 1;

  for(int i = 1; i <= population_size; i++) {
    printf("\r%d/%d", i, population_size);
    sprintf(buffer, "%04d.ann", i);

    genann *ann = genann_init(inputs, hidden_layers, hidden, outputs);
    if (ann == NULL) {
      fprintf(stderr, "\nCannot build a network with %d hidden layers of %d\n", hidden_layers, hidden);
      exit(1);
    }
    FILE *fd = fopen(buffer, "wb");
    if (fd == NULL) {
      fprintf(stderr, "\nCould not open %s: %s\n", buffer, strerror(errno));
      exit(1);
    }
    int written = ann_binary_write(ann, fd);
    genann_free(ann);
    // A half-written network is removed, so the runner never stores one.
    if (fclose(fd) != 0 || written != 0) {
      fprintf(stderr, "\nCould not write %s\n", buffer);
      remove(buffer);
      exit(1);
    }
  }
  printf("\n");
}
