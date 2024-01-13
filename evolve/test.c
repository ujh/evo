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

#include "evolve.h"
#include "minctest.h"

double returns_point_three() { return 0.3; }
double returns_point_one() { return 0.1; }
double returns_point_nine_nine() { return 0.99; }
double returns_point_seven() { return 0.7; }

void test_cross_over() {
  genann *nn1 = genann_init(1, 1, 1, 1);
  genann *nn2 = genann_init(1, 1, 1, 1);
  genann *child = cross_over(nn1, nn2, 2);

  lfequal(nn1->weight[0], child->weight[0]);
  lfequal(nn1->weight[1], child->weight[1]);
  lfequal(nn2->weight[2], child->weight[2]);
  lfequal(nn2->weight[3], child->weight[3]);
}

int main(int argc, char **argv) {
  printf("Evolve test suite\n");

  lrun("cross_over", test_cross_over);
}
