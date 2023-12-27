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

#include <math.h>
#include <stdlib.h>

#include "evolve.h"

int main(int argc, char **argv) {
  // Do not buffer stdout
  setbuf(stdout, NULL);
  seed();

  if (argc != 4) {
    fprintf(stderr, "3 arguments required: cross_over_rate, ann1, ann2!\n");
    exit(1);
  }

  double cross_over_rate = atof(argv[1]);
  char *ann1_name = argv[2];
  char *ann2_name = argv[3];

  printf(
    "cross_over_rate = %f, ann1_name = %s, ann2_name = %s\n",
    cross_over_rate,
    ann1_name,
    ann2_name
  );

  genann **anns = load_nns(ann1_name, ann2_name);
  check_nns(anns);

  genann *child = NULL;

  if (GENANN_RANDOM() < cross_over_rate) {
    child = child_from_cross_over(anns);
  } else {
    child = child_from_mutation(anns);
  }

  printf("Saving output to child.ann ...");
  FILE *fd = fopen("child.ann", "w");
  genann_write(child, fd);
  fclose(fd);
  printf("\n");
}
