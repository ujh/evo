/*
 * Loads a network the way the arena and evo do, in a process that never calls
 * genann_init, and prints what it computes, so that the lib Makefile can
 * compare it with the drawing load. genann_init fills the lookup table that
 * sigmoid_cached reads; test.c calls it and would hide a play load that
 * leaves the table empty (every output 0).
 *
 *   play_test write FILE   a 2x2 network, two hidden layers, sigmoid_cached
 *   play_test play FILE    ann_binary_read_for_play, then the outputs
 *   play_test draw FILE    ann_binary_read, then the outputs
 *
 * The outputs are printed in hexadecimal, so equal lines are equal doubles.
 */

#include "ann.h"
#include <stdio.h>
#include <string.h>

static int run(genann *ann) {
    if (ann == NULL) return 1;
    for (int k = 0; k < 3; ++k) {
        double input[5];
        for (int i = 0; i < 5; ++i) input[i] = (i + k) % 3 - 1;
        const double *out = genann_run(ann, input);
        for (int i = 0; i < ann->outputs; ++i) printf("%a\n", out[i]);
    }
    genann_free(ann);
    return 0;
}

int main(int argc, char *argv[]) {
    if (argc != 3) {
        fprintf(stderr, "usage: play_test write|play|draw FILE\n");
        return 2;
    }
    const char *mode = argv[1];
    FILE *file = fopen(argv[2], strcmp(mode, "write") == 0 ? "wb" : "rb");
    if (file == NULL) {
        perror(argv[2]);
        return 1;
    }
    int rc;
    if (strcmp(mode, "write") == 0) {
        // Weights of up to ±10, so the sigmoids see more than their middle.
        pcg32_srandom(11, 13);
        genann *ann = genann_init(5, 2, 4, 5);
        for (int i = 0; i < ann->total_weights; ++i) ann->weight[i] *= 20;
        ann_genes genes = ann_default_genes(ann->total_weights);
        ann_features features = ann_default_features(0);
        rc = ann_binary_write(ann, &genes, &features, file) != 0;
        genann_free(ann);
    } else if (strcmp(mode, "play") == 0) {
        rc = run(ann_binary_read_for_play(file, NULL, NULL));
    } else if (strcmp(mode, "draw") == 0) {
        rc = run(ann_binary_read(file, NULL, NULL));
    } else {
        fprintf(stderr, "play_test: unknown mode %s\n", mode);
        rc = 2;
    }
    fclose(file);
    return rc;
}
