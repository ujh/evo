/*
 * Evo's layer over GENANN. genann.c and genann.h are upstream GENANN v1.1.1
 * (https://github.com/codeplea/genann, tag v1.1.1), unchanged, so an update
 * is a plain copy; everything Evo adds lives here and in ann.c. Include this
 * header, not genann.h.
 */

#ifndef ANN_H
#define ANN_H

#include <math.h>
#include <stdio.h>
#include <pcg_variants.h>

// GENANN draws its random weights through this macro. PCG makes them
// reproducible from a seed (pcg32_srandom), as the pcg-random library
// suggests for doubles in [0, 1).
#define GENANN_RANDOM() (ldexp(pcg32_random(), -32))

#include "genann.h"

// The .ann format: four native ints (inputs, hidden_layers, hidden,
// outputs), then the native double weights. It has no header, so it is not
// portable across ABIs.

// Returns NULL, after printing why, when the file does not hold a network.
genann *ann_binary_read(FILE *in);
void ann_binary_write(genann const *ann, FILE *out);

#endif
