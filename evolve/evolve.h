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
#include <stdbool.h>

#include "ann.h"

extern pcg32_random_t rng;

void seed();
// Reads both parents and their genes; exits 1 if either cannot be read.
genann **load_nns(char *ann1_name, char *ann2_name, ann_genes genes[2]);
bool nns_compatible(genann **nns);
void check_nns(genann **nns);
// Both store in *picked which parent (0 or 1) the child is built from: the
// one mutated, or the one whose weights come first in a crossover.
genann *child_from_cross_over(genann **nns, int *picked);
genann *child_from_mutation(genann **nns, int *picked);
genann *cross_over(genann *first_parent, genann *second_parent, int cross_over_point);
genann *mutate(genann *parent);
