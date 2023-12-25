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

#include <stdlib.h>

#include "genann.h"

int main(int argc, char **argv) {
  // Do not buffer stdout
  setbuf(stdout, NULL);

  int population_size, board_size, hidden_layers, hidden;

  if (argc != 5) {
    fprintf(stderr, "4 arguments required: population_size, board size, no. hidden layers, no. neurons per layer!\n");
    exit(1);
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

    FILE *fd = fopen(buffer, "w");
    genann *ann = genann_init(inputs, hidden_layers, hidden, outputs);
    genann_write(ann, fd);
    genann_free(ann);
    fclose(fd);
  }
  printf("\n");
}
