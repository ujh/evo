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

// The .ann format holds everything a GENANN network is: the magic "EVOANN",
// a uint32 format version (1), the int32 sizes inputs, hidden_layers,
// hidden, and outputs, a uint32 code for the hidden and then the output
// activation, and the weights as IEEE 754 doubles. Every number is
// little-endian, so a file reads the same on any machine. The codes are
// ANN_ACTIVATIONS' positions plus one.

typedef struct {
    const char *name;
    genann_actfun function;
} ann_activation;

// Every activation GENANN offers, in code order.
extern const ann_activation ANN_ACTIVATIONS[];
extern const int ANN_ACTIVATION_COUNT;

// The activation's name, or NULL for a function GENANN does not offer.
const char *ann_activation_name(genann_actfun function);

// Returns NULL, after printing why, when the file does not hold a network.
genann *ann_binary_read(FILE *in);
// Returns 0, or -1 after printing why: an activation the format has no code
// for, or a failed write.
int ann_binary_write(genann const *ann, FILE *out);

#endif
