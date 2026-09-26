/*
 * GENANN - Minimal C Artificial Neural Network
 *
 * Copyright (c) 2015-2018 Lewis Van Winkle
 *
 * http://CodePlea.com
 *
 * This software is provided 'as-is', without any express or implied
 * warranty. In no event will the authors be held liable for any damages
 * arising from the use of this software.
 *
 * Permission is granted to anyone to use this software for any purpose,
 * including commercial applications, and to alter it and redistribute it
 * freely, subject to the following restrictions:
 *
 * 1. The origin of this software must not be misrepresented; you must not
 *    claim that you wrote the original software. If you use this software
 *    in a product, an acknowledgement in the product documentation would be
 *    appreciated but is not required.
 * 2. Altered source versions must be plainly marked as such, and must not be
 *    misrepresented as being the original software.
 * 3. This notice may not be removed or altered from any source distribution.
 *
 */

#include "ann.h"
#include "minctest.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <stdlib.h>



void basic() {
    genann *ann = genann_init(1, 0, 0, 1);

    lequal(ann->total_weights, 2);
    double a;


    a = 0;
    ann->weight[0] = 0;
    ann->weight[1] = 0;
    lfequal(0.5, *genann_run(ann, &a));

    a = 1;
    lfequal(0.5, *genann_run(ann, &a));

    a = 11;
    lfequal(0.5, *genann_run(ann, &a));

    a = 1;
    ann->weight[0] = 1;
    ann->weight[1] = 1;
    lfequal(0.5, *genann_run(ann, &a));

    a = 10;
    ann->weight[0] = 1;
    ann->weight[1] = 1;
    lfequal(1.0, *genann_run(ann, &a));

    a = -10;
    lfequal(0.0, *genann_run(ann, &a));

    genann_free(ann);
}


void xor() {
    genann *ann = genann_init(2, 1, 2, 1);
    ann->activation_hidden = genann_act_threshold;
    ann->activation_output = genann_act_threshold;

    lequal(ann->total_weights, 9);

    /* First hidden. */
    ann->weight[0] = .5;
    ann->weight[1] = 1;
    ann->weight[2] = 1;

    /* Second hidden. */
    ann->weight[3] = 1;
    ann->weight[4] = 1;
    ann->weight[5] = 1;

    /* Output. */
    ann->weight[6] = .5;
    ann->weight[7] = 1;
    ann->weight[8] = -1;


    double input[4][2] = {{0, 0}, {0, 1}, {1, 0}, {1, 1}};
    double output[4] = {0, 1, 1, 0};

    lfequal(output[0], *genann_run(ann, input[0]));
    lfequal(output[1], *genann_run(ann, input[1]));
    lfequal(output[2], *genann_run(ann, input[2]));
    lfequal(output[3], *genann_run(ann, input[3]));

    genann_free(ann);
}


void backprop() {
    genann *ann = genann_init(1, 0, 0, 1);

    double input, output;
    input = .5;
    output = 1;

    double first_try = *genann_run(ann, &input);
    genann_train(ann, &input, &output, .5);
    double second_try = *genann_run(ann, &input);
    lok(fabs(first_try - output) > fabs(second_try - output));

    genann_free(ann);
}


void train_and() {
    double input[4][2] = {{0, 0}, {0, 1}, {1, 0}, {1, 1}};
    double output[4] = {0, 0, 0, 1};

    genann *ann = genann_init(2, 0, 0, 1);

    int i, j;

    for (i = 0; i < 50; ++i) {
        for (j = 0; j < 4; ++j) {
            genann_train(ann, input[j], output + j, .8);
        }
    }

    ann->activation_output = genann_act_threshold;
    lfequal(output[0], *genann_run(ann, input[0]));
    lfequal(output[1], *genann_run(ann, input[1]));
    lfequal(output[2], *genann_run(ann, input[2]));
    lfequal(output[3], *genann_run(ann, input[3]));

    genann_free(ann);
}


void train_or() {
    double input[4][2] = {{0, 0}, {0, 1}, {1, 0}, {1, 1}};
    double output[4] = {0, 1, 1, 1};

    genann *ann = genann_init(2, 0, 0, 1);
    genann_randomize(ann);

    int i, j;

    for (i = 0; i < 50; ++i) {
        for (j = 0; j < 4; ++j) {
            genann_train(ann, input[j], output + j, .8);
        }
    }

    ann->activation_output = genann_act_threshold;
    lfequal(output[0], *genann_run(ann, input[0]));
    lfequal(output[1], *genann_run(ann, input[1]));
    lfequal(output[2], *genann_run(ann, input[2]));
    lfequal(output[3], *genann_run(ann, input[3]));

    genann_free(ann);
}



void train_xor() {
    double input[4][2] = {{0, 0}, {0, 1}, {1, 0}, {1, 1}};
    double output[4] = {0, 1, 1, 0};

    genann *ann = genann_init(2, 1, 2, 1);

    int i, j;

    for (i = 0; i < 500; ++i) {
        for (j = 0; j < 4; ++j) {
            genann_train(ann, input[j], output + j, 3);
        }
        /* printf("%1.2f ", xor_score(ann)); */
    }

    ann->activation_output = genann_act_threshold;
    lfequal(output[0], *genann_run(ann, input[0]));
    lfequal(output[1], *genann_run(ann, input[1]));
    lfequal(output[2], *genann_run(ann, input[2]));
    lfequal(output[3], *genann_run(ann, input[3]));

    genann_free(ann);
}



void persist() {
    genann *first = genann_init(1000, 5, 50, 10);

    FILE *out = fopen("persist.txt", "w");
    genann_write(first, out);
    fclose(out);


    FILE *in = fopen("persist.txt", "r");
    genann *second = genann_read(in);
    fclose(in);

    lequal(first->inputs, second->inputs);
    lequal(first->hidden_layers, second->hidden_layers);
    lequal(first->hidden, second->hidden);
    lequal(first->outputs, second->outputs);
    lequal(first->total_weights, second->total_weights);

    int i;
    for (i = 0; i < first->total_weights; ++i) {
        lok(first->weight[i] == second->weight[i]);
    }

    genann_free(first);
    genann_free(second);
}


void copy() {
    genann *first = genann_init(1000, 5, 50, 10);

    genann *second = genann_copy(first);

    lequal(first->inputs, second->inputs);
    lequal(first->hidden_layers, second->hidden_layers);
    lequal(first->hidden, second->hidden);
    lequal(first->outputs, second->outputs);
    lequal(first->total_weights, second->total_weights);

    int i;
    for (i = 0; i < first->total_weights; ++i) {
        lfequal(first->weight[i], second->weight[i]);
    }

    genann_free(first);
    genann_free(second);
}


void sigmoid() {
    double i = -20;
    const double max = 20;
    const double d = .0001;

    while (i < max) {
        lfequal(genann_act_sigmoid(NULL, i), genann_act_sigmoid_cached(NULL, i));
        i += d;
    }
}


// The .ann format, written out byte by byte so the test pins it down:
// "EVOANN", a little-endian uint32 version (2), four int32 sizes, two uint32
// activation codes, the five genes, a uint32 feature-group mask,
// feature_step, the F feature weights, then the weights, every real number
// a little-endian IEEE 754 double. Every network fits a square board of 2x2
// to 23x23: outputs are the points plus pass, inputs the groups' layout.
typedef struct {
    unsigned char bytes[4096];
    size_t length;
} buffer;

static void put_bytes(buffer *b, const void *data, size_t n) {
    memcpy(b->bytes + b->length, data, n);
    b->length += n;
}

static void put_u32(buffer *b, uint32_t v) {
    unsigned char le[4] = {v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff};
    put_bytes(b, le, 4);
}

static void put_f64(buffer *b, double d) {
    uint64_t v;
    memcpy(&v, &d, 8);
    unsigned char le[8];
    for (int i = 0; i < 8; ++i) le[i] = (v >> (8 * i)) & 0xff;
    put_bytes(b, le, 8);
}

// Valid genes for any network, each distinct so a swap would show.
static const ann_genes GENES = {0.03, 1.5, 0.75, 0.0625, 0.1875};
// No feature groups, with a feature_step that is not the default, so a
// reader that made one up would show.
static const ann_features NO_FEATURES = {.groups = 0, .feature_step = 0.125};
// Every group, each weight distinct and within its range.
static const ann_features ALL_FEATURES = {
    .groups = ANN_GROUPS_ALL,
    .feature_step = 0.0625,
    .weights = {0.5, -0.25, 1.5, 9.75, -10, 10, -0.03125},
};

static void put_genes(buffer *b, ann_genes g) {
    put_f64(b, g.copy_chance);
    put_f64(b, g.weight_changes);
    put_f64(b, g.weight_step);
    put_f64(b, g.activation_rate);
    put_f64(b, g.structure_rate);
}

// The feature block: the mask, feature_step, and the groups' F weights.
static void put_features(buffer *b, const ann_features *f) {
    put_u32(b, f->groups);
    put_f64(b, f->feature_step);
    int count = ann_feature_count(f->groups);
    for (int i = 0; i < count; ++i) put_f64(b, f->weights[i]);
}

// The sizes and activation codes of a network, without the genes.
static buffer header_only(uint32_t version, int32_t inputs, int32_t layers, int32_t hidden, int32_t outputs,
                          uint32_t hidden_code, uint32_t output_code) {
    buffer b = {.length = 0};
    put_bytes(&b, "EVOANN", 6);
    put_u32(&b, version);
    put_u32(&b, (uint32_t)inputs);
    put_u32(&b, (uint32_t)layers);
    put_u32(&b, (uint32_t)hidden);
    put_u32(&b, (uint32_t)outputs);
    put_u32(&b, hidden_code);
    put_u32(&b, output_code);
    return b;
}

// A version 2 header for a network of the given sizes and activation codes,
// with GENES and the features.
static buffer header_with(int32_t inputs, int32_t layers, int32_t hidden, int32_t outputs,
                          uint32_t hidden_code, uint32_t output_code, const ann_features *f) {
    buffer b = header_only(2, inputs, layers, hidden, outputs, hidden_code, output_code);
    put_genes(&b, GENES);
    put_features(&b, f);
    return b;
}

// The same, without feature groups.
static buffer header(int32_t inputs, int32_t layers, int32_t hidden, int32_t outputs,
                     uint32_t hidden_code, uint32_t output_code) {
    return header_with(inputs, layers, hidden, outputs, hidden_code, output_code, &NO_FEATURES);
}

// Reads the bytes followed by `zeros` weights of 0, which lets a test give a
// network too big for the buffer all its weights.
static genann *read_padded(const buffer *b, long zeros, ann_genes *genes, ann_features *features) {
    FILE *out = fopen("persist.bin", "wb");
    fwrite(b->bytes, 1, b->length, out);
    static const unsigned char zero[8] = {0};
    for (long i = 0; i < zeros; ++i) fwrite(zero, 1, 8, out);
    fclose(out);
    FILE *in = fopen("persist.bin", "rb");
    genann *ann = ann_binary_read(in, genes, features);
    fclose(in);
    return ann;
}

static genann *read_bytes_all(const buffer *b, ann_genes *genes, ann_features *features) {
    return read_padded(b, 0, genes, features);
}

static genann *read_bytes(const buffer *b) {
    return read_bytes_all(b, NULL, NULL);
}

static int written_bytes_all(const genann *ann, const ann_genes *genes, const ann_features *features, buffer *b) {
    FILE *out = fopen("persist.bin", "wb");
    int rc = ann_binary_write(ann, genes, features, out);
    fclose(out);
    FILE *in = fopen("persist.bin", "rb");
    b->length = fread(b->bytes, 1, sizeof(b->bytes), in);
    fclose(in);
    return rc;
}

static int written_bytes_genes(const genann *ann, const ann_genes *genes, buffer *b) {
    return written_bytes_all(ann, genes, &NO_FEATURES, b);
}

static int written_bytes(const genann *ann, buffer *b) {
    return written_bytes_genes(ann, &GENES, b);
}

static void same_network(const genann *first, const genann *second) {
    lequal(first->inputs, second->inputs);
    lequal(first->hidden_layers, second->hidden_layers);
    lequal(first->hidden, second->hidden);
    lequal(first->outputs, second->outputs);
    lequal(first->total_weights, second->total_weights);
    int same = 1;
    for (int i = 0; i < first->total_weights; ++i) same &= first->weight[i] == second->weight[i];
    lok(same);
}

// A 9x9 network without features and one with every group come back
// weight for weight, with their genes and features.
void binary_persist() {
    genann *first = genann_init(82, 5, 50, 82);

    ann_genes genes = {0.05, 17.5, 0.25, 0.125, 0.375};

    FILE *out = fopen("persist.bin", "wb");
    lok(ann_binary_write(first, &genes, &NO_FEATURES, out) == 0);
    fclose(out);

    ann_genes back = {0};
    ann_features features_back = ALL_FEATURES;
    FILE *in = fopen("persist.bin", "rb");
    genann *second = ann_binary_read(in, &back, &features_back);
    fclose(in);
    lok(second != NULL);
    if (!second) { genann_free(first); return; }

    lok(back.copy_chance == 0.05 && back.weight_changes == 17.5 && back.weight_step == 0.25);
    lok(back.activation_rate == 0.125 && back.structure_rate == 0.375);
    lok(features_back.groups == 0 && features_back.feature_step == 0.125);
    // Without groups there are no feature weights; the unused ones read 0.
    int zero = 1;
    for (int i = 0; i < ANN_MAX_FEATURES; ++i) zero &= features_back.weights[i] == 0;
    lok(zero);
    same_network(first, second);
    genann_free(first);
    genann_free(second);

    first = genann_init(ann_layout_inputs(ANN_GROUPS_ALL, 81), 2, 20, 82);
    lequal(first->inputs, 974);
    out = fopen("persist.bin", "wb");
    lok(ann_binary_write(first, &genes, &ALL_FEATURES, out) == 0);
    fclose(out);
    in = fopen("persist.bin", "rb");
    second = ann_binary_read(in, &back, &features_back);
    fclose(in);
    lok(second != NULL);
    if (!second) { genann_free(first); return; }
    lok(features_back.groups == ANN_GROUPS_ALL && features_back.feature_step == 0.0625);
    lok(memcmp(features_back.weights, ALL_FEATURES.weights, sizeof(ALL_FEATURES.weights)) == 0);
    same_network(first, second);
    genann_free(first);
    genann_free(second);
}

static genann_actfun ACTIVATIONS[] = {
    genann_act_sigmoid, genann_act_sigmoid_cached, genann_act_threshold,
    genann_act_linear, genann_act_tanh, genann_act_relu
};
#define ACTIVATION_COUNT 6

// Every activation GENANN offers survives a round trip, hidden and output
// alike, and the network computes the same outputs afterwards. A 2x2
// board: 5 inputs (komi and 4 points), 5 outputs (4 points and pass).
void binary_activations() {
    for (int h = 0; h < ACTIVATION_COUNT; ++h) {
        for (int o = 0; o < ACTIVATION_COUNT; ++o) {
            genann *first = genann_init(5, 2, 4, 5);
            first->activation_hidden = ACTIVATIONS[h];
            first->activation_output = ACTIVATIONS[o];
            buffer b;
            lok(written_bytes(first, &b) == 0);
            genann *second = read_bytes(&b);
            lok(second != NULL);
            if (!second) { genann_free(first); continue; }
            lok(second->activation_hidden == ACTIVATIONS[h]);
            lok(second->activation_output == ACTIVATIONS[o]);
            const double input[5] = {0.5, -1.0, 2.0, 0.0, 1.0};
            double a[5];
            memcpy(a, genann_run(first, input), sizeof(a));
            const double *c = genann_run(second, input);
            lok(memcmp(a, c, sizeof(a)) == 0);
            genann_free(first);
            genann_free(second);
        }
    }
}

// The bytes on disk follow the documented layout, whatever the machine:
// 86 bytes of header, genes, mask, and feature_step, then 8 per feature
// weight and 8 per weight.
void binary_layout() {
    // 2x2, one hidden neuron: 1 * 6 + 5 * 2 = 16 weights.
    genann *ann = genann_init(5, 1, 1, 5);
    ann->activation_hidden = genann_act_tanh;
    ann->activation_output = genann_act_linear;
    for (int i = 0; i < 16; ++i) ann->weight[i] = i - 1.5;
    buffer expected = header(5, 1, 1, 5, 5, 4);
    for (int i = 0; i < 16; ++i) put_f64(&expected, i - 1.5);
    buffer got;
    lok(written_bytes(ann, &got) == 0);
    lequal((int)got.length, 86 + 16 * 8);
    lok(got.length == expected.length && memcmp(got.bytes, expected.bytes, got.length) == 0);
    // The mask and feature_step follow the genes.
    lok(got.bytes[74] == 0 && got.bytes[75] == 0 && got.bytes[76] == 0 && got.bytes[77] == 0);

    genann *back = read_bytes(&expected);
    lok(back != NULL);
    if (back) {
        lequal(back->total_weights, 16);
        lok(back->weight[0] == -1.5 && back->weight[15] == 13.5);
        lok(back->activation_hidden == genann_act_tanh);
        lok(back->activation_output == genann_act_linear);
        genann_free(back);
    }
    genann_free(ann);

    // With last_move on 2x2 (one feature weight, near_last): 1 + 4 + 4 +
    // 4 + 1 = 14 inputs, and without hidden layers 5 * 15 = 75 weights.
    ann_features last = {.groups = ANN_GROUP_LAST_MOVE, .feature_step = 0.5, .weights = {-2.5}};
    ann = genann_init(14, 0, 0, 5);
    for (int i = 0; i < 75; ++i) ann->weight[i] = i;
    expected = header_only(2, 14, 0, 0, 5, 2, 2);
    put_genes(&expected, GENES);
    put_u32(&expected, 4);
    put_f64(&expected, 0.5);
    put_f64(&expected, -2.5);
    for (int i = 0; i < 75; ++i) put_f64(&expected, i);
    lok(written_bytes_all(ann, &GENES, &last, &got) == 0);
    lequal((int)got.length, 86 + 8 + 75 * 8);
    lok(got.length == expected.length && memcmp(got.bytes, expected.bytes, got.length) == 0);
    genann_free(ann);
}

// Every group on the smallest board: 50 inputs, and without hidden layers
// 5 * 51 = 255 weights, 86 + 7 * 8 + 255 * 8 = 2182 bytes. Each group alone
// comes back too, with only its own weights in the file.
void binary_features() {
    genann *ann = genann_init(ann_layout_inputs(ANN_GROUPS_ALL, 4), 0, 0, 5);
    lequal(ann->inputs, 50);
    lequal(ann->total_weights, 255);
    buffer b;
    lok(written_bytes_all(ann, &GENES, &ALL_FEATURES, &b) == 0);
    lequal((int)b.length, 2182);
    ann_features back;
    memset(&back, 0xff, sizeof(back));
    genann *second = read_bytes_all(&b, NULL, &back);
    lok(second != NULL);
    if (second) {
        same_network(ann, second);
        genann_free(second);
    }
    lok(back.groups == ANN_GROUPS_ALL && back.feature_step == ALL_FEATURES.feature_step);
    lok(memcmp(back.weights, ALL_FEATURES.weights, sizeof(back.weights)) == 0);
    // A reader that does not want the features passes NULL.
    second = read_bytes(&b);
    lok(second != NULL);
    if (second) genann_free(second);
    genann_free(ann);

    unsigned groups[] = {ANN_GROUP_SHAPES, ANN_GROUP_TACTICS, ANN_GROUP_LAST_MOVE, ANN_GROUP_LIBERTIES,
                         ANN_GROUP_TACTICS | ANN_GROUP_LIBERTIES};
    for (size_t k = 0; k < sizeof(groups) / sizeof(groups[0]); ++k) {
        int count = ann_feature_count(groups[k]);
        ann_features f = {.groups = groups[k], .feature_step = ANN_FEATURE_STEP_MAX};
        for (int i = 0; i < count; ++i) f.weights[i] = i + 0.5;
        ann = genann_init(ann_layout_inputs(groups[k], 9), 1, 2, 10);
        lok(written_bytes_all(ann, &GENES, &f, &b) == 0);
        lequal((int)b.length, 86 + 8 * count + 8 * ann->total_weights);
        memset(&back, 0xff, sizeof(back));
        second = read_bytes_all(&b, NULL, &back);
        lok(second != NULL);
        if (second) genann_free(second);
        lok(back.groups == groups[k] && back.feature_step == ANN_FEATURE_STEP_MAX);
        int same = 1;
        for (int i = 0; i < ANN_MAX_FEATURES; ++i) same &= back.weights[i] == (i < count ? i + 0.5 : 0);
        lok(same);
        genann_free(ann);
    }
}

// The genes come back exactly as written, in their own fields, and a
// reader that does not want them passes NULL.
void binary_genes() {
    genann *ann = genann_init(5, 1, 3, 5);
    buffer b;
    lok(written_bytes(ann, &b) == 0);
    ann_genes back = {0};
    genann *second = read_bytes_all(&b, &back, NULL);
    lok(second != NULL);
    lok(back.copy_chance == GENES.copy_chance);
    lok(back.weight_changes == GENES.weight_changes);
    lok(back.weight_step == GENES.weight_step);
    lok(back.activation_rate == GENES.activation_rate);
    lok(back.structure_rate == GENES.structure_rate);
    if (second) genann_free(second);
    second = read_bytes(&b);
    lok(second != NULL);
    if (second) genann_free(second);

    // The bounds themselves are valid; weight_changes may be every weight.
    ann_genes lowest = {ANN_COPY_CHANCE_MIN, ANN_WEIGHT_CHANGES_MIN, ANN_WEIGHT_STEP_MIN,
                        ANN_ACTIVATION_RATE_MIN, ANN_STRUCTURE_RATE_MIN};
    ann_genes highest = {ANN_COPY_CHANCE_MAX, ann->total_weights, ANN_WEIGHT_STEP_MAX,
                         ANN_ACTIVATION_RATE_MAX, ANN_STRUCTURE_RATE_MAX};
    lok(written_bytes_genes(ann, &lowest, &b) == 0);
    second = read_bytes_all(&b, &back, NULL);
    lok(second != NULL && back.weight_changes == 1 && back.copy_chance == 1e-4);
    if (second) genann_free(second);
    lok(written_bytes_genes(ann, &highest, &b) == 0);
    second = read_bytes_all(&b, &back, NULL);
    lok(second != NULL && back.weight_changes == ann->total_weights && back.structure_rate == 0.5);
    if (second) genann_free(second);
    genann_free(ann);
}

// Genes outside their clamps, or not finite, make the file unreadable, and
// the writer refuses to produce such a file (or one without genes).
void binary_read_rejects_bad_genes() {
    const double inf = INFINITY, not_a_number = NAN;
    // A 2x2 network with one hidden neuron has 16 weights, so weight_changes
    // may be 1 to 16.
    struct { int gene; double value; } bad[] = {
        {0, 0.9e-4}, {0, 0.11}, {0, not_a_number}, {0, inf}, {0, -inf},
        {1, 0.999}, {1, 16.001}, {1, not_a_number}, {1, inf},
        {2, 0.9e-4}, {2, 10.01}, {2, not_a_number}, {2, -inf},
        {3, 0.9e-4}, {3, 0.51}, {3, not_a_number},
        {4, 0.9e-4}, {4, 0.51}, {4, inf},
    };
    genann *ann = genann_init(5, 1, 1, 5);
    for (size_t k = 0; k < sizeof(bad) / sizeof(bad[0]); ++k) {
        ann_genes g = GENES;
        double *fields[] = {&g.copy_chance, &g.weight_changes, &g.weight_step,
                            &g.activation_rate, &g.structure_rate};
        *fields[bad[k].gene] = bad[k].value;
        lok(ann_genes_invalid(&g, 16) != NULL);
        buffer b = header_only(2, 5, 1, 1, 5, 2, 2);
        put_genes(&b, g);
        put_features(&b, &NO_FEATURES);
        for (int i = 0; i < 16; ++i) put_f64(&b, i);
        lok(read_bytes(&b) == NULL);
        buffer ignored;
        lok(written_bytes_genes(ann, &g, &ignored) != 0);
    }
    lok(ann_genes_invalid(&GENES, 16) == NULL);
    buffer ignored;
    lok(written_bytes_genes(ann, NULL, &ignored) != 0);
    genann_free(ann);
}

// A feature mask with a bit that is no group, or a feature_step or feature
// weight that is not finite or outside its range, makes the file
// unreadable, and the writer refuses it (and a network without features).
void binary_read_rejects_bad_features() {
    const double inf = INFINITY, not_a_number = NAN;
    // 2x2 with every group, no hidden layers: 255 weights.
    genann *ann = genann_init(50, 0, 0, 5);
    buffer b;
    lok(written_bytes_all(ann, &GENES, &ALL_FEATURES, &b) == 0);
    genann *good = read_bytes(&b);
    lok(good != NULL);
    if (good) genann_free(good);

    // The bounds themselves are valid.
    ann_features edge = ALL_FEATURES;
    edge.feature_step = ANN_FEATURE_STEP_MIN;
    edge.weights[0] = ANN_FEATURE_WEIGHT_MIN;
    edge.weights[6] = ANN_FEATURE_WEIGHT_MAX;
    lok(ann_features_invalid(&edge) == NULL);
    lok(written_bytes_all(ann, &GENES, &edge, &b) == 0);
    good = read_bytes(&b);
    lok(good != NULL);
    if (good) genann_free(good);

    // -1 stands for feature_step, 0 to 6 for a weight.
    struct { int field; double value; } bad[] = {
        {-1, 0.9e-4}, {-1, 1.01}, {-1, 0}, {-1, not_a_number}, {-1, inf},
        {0, -10.01}, {0, 10.01}, {0, not_a_number}, {3, inf}, {3, -inf}, {6, 10.5}, {6, not_a_number},
    };
    for (size_t k = 0; k < sizeof(bad) / sizeof(bad[0]); ++k) {
        ann_features f = ALL_FEATURES;
        if (bad[k].field < 0) f.feature_step = bad[k].value;
        else f.weights[bad[k].field] = bad[k].value;
        lok(ann_features_invalid(&f) != NULL);
        b = header_with(50, 0, 0, 5, 2, 2, &f);
        for (int i = 0; i < 255; ++i) put_f64(&b, 0);
        lok(read_bytes(&b) == NULL);
        buffer ignored;
        lok(written_bytes_all(ann, &GENES, &f, &ignored) != 0);
    }
    genann_free(ann);

    // Unknown bits, alone or beside known ones, on a network that would
    // otherwise fit a 2x2 board without features.
    unsigned masks[] = {16, ANN_GROUPS_ALL | 16, 0x80000000u, 0xffffffffu};
    ann = genann_init(5, 0, 0, 5);
    for (size_t k = 0; k < sizeof(masks) / sizeof(masks[0]); ++k) {
        ann_features f = NO_FEATURES;
        f.groups = masks[k];
        lok(ann_features_invalid(&f) != NULL);
        b = header_only(2, 5, 0, 0, 5, 2, 2);
        put_genes(&b, GENES);
        put_u32(&b, masks[k]);
        put_f64(&b, 0.125);
        for (int i = 0; i < 30; ++i) put_f64(&b, 0);
        lok(read_bytes(&b) == NULL);
        buffer ignored;
        lok(written_bytes_all(ann, &GENES, &f, &ignored) != 0);
    }
    buffer ignored;
    lok(written_bytes_all(ann, &GENES, NULL, &ignored) != 0);
    genann_free(ann);
}

// Without hidden layers the width means nothing: it is written as 0,
// whatever the network says, and a file must hold 0 there.
void binary_no_hidden_layers() {
    genann *ann = genann_init(5, 0, 7, 5);
    lequal(ann->total_weights, 30);
    for (int i = 0; i < 30; ++i) ann->weight[i] = i;
    buffer expected = header(5, 0, 0, 5, 2, 2);
    for (int i = 0; i < 30; ++i) put_f64(&expected, i);
    buffer got;
    lok(written_bytes(ann, &got) == 0);
    lok(got.length == expected.length && memcmp(got.bytes, expected.bytes, got.length) == 0);
    genann *back = read_bytes(&got);
    lok(back != NULL);
    if (back) {
        lequal(back->hidden, 0);
        lok(back->weight[29] == 29);
        genann_free(back);
    }

    buffer wide = header(5, 0, 7, 5, 2, 2);
    for (int i = 0; i < 30; ++i) put_f64(&wide, i);
    lok(read_bytes(&wide) == NULL);
    genann_free(ann);
}

// The default mutation load: 0.0004 changes per weight, at least one.
void default_genes() {
    ann_genes g = ann_default_genes(418);
    lok(g.copy_chance == 0.01);
    lok(g.weight_changes == 1);
    lok(g.weight_step == 0.5);
    lok(g.activation_rate == 0.02);
    lok(g.structure_rate == 0.02);
    lok(ann_default_genes(10000).weight_changes == 0.0004 * 10000);
    lok(ann_default_genes(100000).weight_changes == 40);
    lok(ann_genes_invalid(&g, 418) == NULL);
    g = ann_default_genes(1);
    lok(g.weight_changes == 1 && ann_genes_invalid(&g, 1) == NULL);
}

// The hand-set starting feature weights, in the layout's order, and the
// default feature_step; only the groups' own weights are filled in.
void default_features() {
    lequal(ANN_MAX_FEATURES, 7);
    const char *names[] = {"hane", "cut", "edge", "capture", "self_atari", "saves_atari", "near_last"};
    const unsigned owners[] = {ANN_GROUP_SHAPES, ANN_GROUP_SHAPES, ANN_GROUP_SHAPES, ANN_GROUP_TACTICS,
                               ANN_GROUP_TACTICS, ANN_GROUP_TACTICS, ANN_GROUP_LAST_MOVE};
    const double start[] = {0.05, 0.05, 0.05, 1.0, -1.0, 0.8, 0.05};
    for (int i = 0; i < ANN_MAX_FEATURES; ++i) {
        lok(strcmp(ANN_FEATURES[i].name, names[i]) == 0);
        lok(ANN_FEATURES[i].group == owners[i]);
        lok(ANN_FEATURES[i].start_weight == start[i]);
    }

    ann_features f = ann_default_features(ANN_GROUPS_ALL);
    lok(f.groups == ANN_GROUPS_ALL && f.feature_step == 0.01);
    lok(memcmp(f.weights, start, sizeof(start)) == 0);
    lok(ann_features_invalid(&f) == NULL);

    f = ann_default_features(0);
    lok(f.groups == 0 && f.feature_step == 0.01);
    int zero = 1;
    for (int i = 0; i < ANN_MAX_FEATURES; ++i) zero &= f.weights[i] == 0;
    lok(zero);
    lok(ann_features_invalid(&f) == NULL);

    // Tactics and last_move: capture, self_atari, saves_atari, near_last.
    f = ann_default_features(ANN_GROUP_TACTICS | ANN_GROUP_LAST_MOVE | ANN_GROUP_LIBERTIES);
    const double some[] = {1.0, -1.0, 0.8, 0.05, 0, 0, 0};
    lok(memcmp(f.weights, some, sizeof(some)) == 0);
    lok(ann_features_invalid(&f) == NULL);
}

void feature_layout() {
    // The move features each group adds, in the tables' order: shapes 3
    // (hane, cut, edge), tactics 3 (capture, self_atari, saves_atari),
    // last_move 1 (near_last); liberties none.
    lequal(ann_feature_count(0), 0);
    lequal(ann_feature_count(ANN_GROUP_SHAPES), 3);
    lequal(ann_feature_count(ANN_GROUP_TACTICS), 3);
    lequal(ann_feature_count(ANN_GROUP_LAST_MOVE), 1);
    lequal(ann_feature_count(ANN_GROUP_LIBERTIES), 0);
    lequal(ann_feature_count(ANN_GROUPS_ALL), 7);
    lequal(ann_feature_count(ANN_GROUP_SHAPES | ANN_GROUP_LAST_MOVE), 4);
    lequal((int)ANN_GROUPS_ALL, (int)(ANN_GROUP_SHAPES | ANN_GROUP_TACTICS | ANN_GROUP_LAST_MOVE | ANN_GROUP_LIBERTIES));
    // [komi][N stones][F x N move features][3 x N liberties][N last_move]
    // [opponent_passed].
    lequal(ann_layout_inputs(0, 81), 82);
    lequal(ann_layout_inputs(ANN_GROUPS_ALL, 81), 974);
    lequal(ann_layout_inputs(ANN_GROUPS_ALL, 361), 4334);
    lequal(ann_layout_inputs(ANN_GROUP_SHAPES, 25), 1 + 25 + 3 * 25);
    lequal(ann_layout_inputs(ANN_GROUP_TACTICS, 25), 1 + 25 + 3 * 25);
    lequal(ann_layout_inputs(ANN_GROUP_LAST_MOVE, 25), 1 + 25 + 25 + 25 + 1);
    lequal(ann_layout_inputs(ANN_GROUP_LIBERTIES, 25), 1 + 25 + 3 * 25);
    lequal(ann_layout_inputs(ANN_GROUP_LIBERTIES | ANN_GROUP_LAST_MOVE, 4), 1 + 4 + 4 + 12 + 4 + 1);
    // Unknown bits have no layout.
    lequal(ann_feature_count(16), -1);
    lequal(ann_layout_inputs(ANN_GROUPS_ALL | 16, 81), -1);
    lequal(ann_layout_inputs(0x80000000u, 81), -1);
    // The feature table agrees with the counts.
    for (unsigned groups = 0; groups <= ANN_GROUPS_ALL; ++groups) {
        int count = 0;
        for (int i = 0; i < ANN_MAX_FEATURES; ++i) count += (ANN_FEATURES[i].group & groups) != 0;
        lequal(ann_feature_count(groups), count);
    }
}

static double my_activation(const genann *ann, double a) { (void)ann; return a / 2; }

void binary_read_rejects_bad_files() {
    // A 2x2 network with one hidden neuron has 16 weights; this one is valid.
    buffer good = header(5, 1, 1, 5, 2, 2);
    for (int i = 0; i < 16; ++i) put_f64(&good, i);
    genann *ann = read_bytes(&good);
    lok(ann != NULL);
    if (ann) genann_free(ann);

    buffer b = good;
    b.bytes[0] = 'X';
    lok(read_bytes(&b) == NULL); // not an Evo network

    // Version 1: the same header and genes, then the weights at once.
    b = header_only(1, 5, 1, 1, 5, 2, 2);
    put_genes(&b, GENES);
    for (int i = 0; i < 16; ++i) put_f64(&b, i);
    lok(read_bytes(&b) == NULL);
    // Version 1's bytes labelled version 2 miss the feature block.
    b.bytes[6] = 2;
    lok(read_bytes(&b) == NULL);
    b = good;
    b.bytes[6] = 3;
    lok(read_bytes(&b) == NULL); // unknown version

    b = header(5, 1, 1, 5, 7, 2);
    for (int i = 0; i < 16; ++i) put_f64(&b, i);
    lok(read_bytes(&b) == NULL); // unknown hidden activation

    b = header(5, 1, 1, 5, 2, 0);
    for (int i = 0; i < 16; ++i) put_f64(&b, i);
    lok(read_bytes(&b) == NULL); // unknown output activation

    b = good;
    b.length = 20;
    lok(read_bytes(&b) == NULL); // header cut short

    b = good;
    b.length = 34 + 3 * 8 + 4;
    lok(read_bytes(&b) == NULL); // genes cut short

    b = good;
    b.length = 74 + 2;
    lok(read_bytes(&b) == NULL); // mask cut short

    b = good;
    b.length = 78 + 4;
    lok(read_bytes(&b) == NULL); // feature_step cut short

    buffer features = header_with(50, 0, 0, 5, 2, 2, &ALL_FEATURES);
    b = features;
    b.length -= 12;
    lok(read_bytes(&b) == NULL); // feature weights cut short

    b = good;
    b.length -= 1;
    lok(read_bytes(&b) == NULL); // weights cut short

    b = good;
    put_f64(&b, 9);
    lok(read_bytes(&b) == NULL); // bytes after the last weight

    b = header(5, -1, 1, 5, 2, 2);
    lok(read_bytes(&b) == NULL); // impossible sizes
    b = header(1 << 21, 1, 1, 5, 2, 2);
    lok(read_bytes(&b) == NULL);

    // The outputs must be the points of a square board of 2x2 to 23x23 plus
    // pass, and the inputs komi and the points: 1x1, 24x24, 6 points, and
    // no outputs at all are refused, whatever the weights. 2x2 and 23x23
    // are read.
    struct { int side_points; int valid; } boards[] = {{1, 0}, {4, 1}, {6, 0}, {529, 1}, {576, 0}, {0, 0}, {-1, 0}};
    for (size_t k = 0; k < sizeof(boards) / sizeof(boards[0]); ++k) {
        int points = boards[k].side_points;
        b = header(points + 1, 0, 0, points + 1, 2, 2);
        long weights = points >= 0 ? (long)(points + 1) * (points + 2) : 0;
        ann = read_padded(&b, weights, NULL, NULL);
        lok((ann != NULL) == boards[k].valid);
        if (ann) genann_free(ann);
    }
    // The inputs must be the feature set's layout for that board: 2x2
    // without features has 5 inputs, with last_move 14.
    b = header(6, 0, 0, 5, 2, 2);
    lok(read_padded(&b, 35, NULL, NULL) == NULL);
    b = header(4, 0, 0, 5, 2, 2);
    lok(read_padded(&b, 25, NULL, NULL) == NULL);
    ann_features last = {.groups = ANN_GROUP_LAST_MOVE, .feature_step = 0.5, .weights = {1}};
    b = header_with(5, 0, 0, 5, 2, 2, &last);
    lok(read_padded(&b, 30, NULL, NULL) == NULL);
    b = header_with(14, 0, 0, 5, 2, 2, &last);
    ann = read_padded(&b, 75, NULL, NULL);
    lok(ann != NULL);
    if (ann) genann_free(ann);
    b = header(14, 0, 0, 5, 2, 2);
    lok(read_padded(&b, 75, NULL, NULL) == NULL);

    // An activation the format has no code for cannot be written.
    genann *custom = genann_init(5, 1, 1, 5);
    custom->activation_output = my_activation;
    buffer ignored;
    lok(written_bytes(custom, &ignored) != 0);
    genann_free(custom);
}


int main(int argc, char *argv[])
{
    printf("GENANN TEST SUITE\n");

    lrun("basic", basic);
    lrun("xor", xor);
    lrun("backprop", backprop);
    lrun("train and", train_and);
    lrun("train or", train_or);
    lrun("train xor", train_xor);
    lrun("persist", persist);
    lrun("binary_persist", binary_persist);
    lrun("binary_bad", binary_read_rejects_bad_files);
    lrun("binary_acts", binary_activations);
    lrun("binary_layout", binary_layout);
    lrun("binary_features", binary_features);
    lrun("binary_genes", binary_genes);
    lrun("binary_bad_genes", binary_read_rejects_bad_genes);
    lrun("binary_bad_features", binary_read_rejects_bad_features);
    lrun("binary_no_layers", binary_no_hidden_layers);
    lrun("default_genes", default_genes);
    lrun("default_features", default_features);
    lrun("feature_layout", feature_layout);
    lrun("copy", copy);
    lrun("sigmoid", sigmoid);

    lresults();

    return lfails != 0;
}
