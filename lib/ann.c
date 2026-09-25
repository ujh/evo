/*
 * GENANN is compiled here, with ann.h's GENANN_RANDOM, so that every program
 * links one copy of it built the same way.
 */

#include "ann.h"
#include "genann.c"

genann *ann_binary_read(FILE *in) {
    int config[4];

    if (fread(config, sizeof(int), 4, in) < 4) {
        fprintf(stderr, "ann_binary_read: file too short for a network header\n");
        return NULL;
    }

    genann *ann = genann_init(config[0], config[1], config[2], config[3]);
    if (ann == NULL) {
        fprintf(stderr, "ann_binary_read: invalid network dimensions %d %d %d %d\n",
                config[0], config[1], config[2], config[3]);
        return NULL;
    }

    if (fread(ann->weight, sizeof(double), ann->total_weights, in) < (size_t)ann->total_weights) {
        fprintf(stderr, "ann_binary_read: file too short for %d weights\n", ann->total_weights);
        genann_free(ann);
        return NULL;
    }

    return ann;
}

void ann_binary_write(const genann *ann, FILE *out) {
    int config[4];
    config[0] = ann->inputs;
    config[1] = ann->hidden_layers;
    config[2] = ann->hidden;
    config[3] = ann->outputs;
    fwrite(config, sizeof(int), 4, out);
    fwrite(ann->weight, sizeof(double), ann->total_weights, out);
}
