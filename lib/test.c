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

void binary_persist() {
    genann *first = genann_init(1000, 5, 50, 10);

    ann_genes genes = {0.05, 17.5, 0.25, 0.125, 0.375};

    FILE *out = fopen("persist.bin", "wb");
    lok(ann_binary_write(first, &genes, out) == 0);
    fclose(out);


    ann_genes back = {0};
    FILE *in = fopen("persist.bin", "rb");
    genann *second = ann_binary_read(in, &back);
    fclose(in);
    lok(second != NULL);
    if (!second) { genann_free(first); return; }

    lok(back.copy_chance == 0.05 && back.weight_changes == 17.5 && back.weight_step == 0.25);
    lok(back.activation_rate == 0.125 && back.structure_rate == 0.375);

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
// "EVOANN", a little-endian uint32 version, four int32 sizes, two uint32
// activation codes, the five genes, then the weights, the genes and the
// weights as little-endian IEEE 754 doubles.
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

static void put_genes(buffer *b, ann_genes g) {
    put_f64(b, g.copy_chance);
    put_f64(b, g.weight_changes);
    put_f64(b, g.weight_step);
    put_f64(b, g.activation_rate);
    put_f64(b, g.structure_rate);
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

// A header for a network of the given sizes and activation codes, with GENES.
static buffer header(uint32_t version, int32_t inputs, int32_t layers, int32_t hidden, int32_t outputs,
                     uint32_t hidden_code, uint32_t output_code) {
    buffer b = header_only(version, inputs, layers, hidden, outputs, hidden_code, output_code);
    put_genes(&b, GENES);
    return b;
}

static genann *read_bytes_genes(const buffer *b, ann_genes *genes) {
    FILE *out = fopen("persist.bin", "wb");
    fwrite(b->bytes, 1, b->length, out);
    fclose(out);
    FILE *in = fopen("persist.bin", "rb");
    genann *ann = ann_binary_read(in, genes);
    fclose(in);
    return ann;
}

static genann *read_bytes(const buffer *b) {
    return read_bytes_genes(b, NULL);
}

static int written_bytes_genes(const genann *ann, const ann_genes *genes, buffer *b) {
    FILE *out = fopen("persist.bin", "wb");
    int rc = ann_binary_write(ann, genes, out);
    fclose(out);
    FILE *in = fopen("persist.bin", "rb");
    b->length = fread(b->bytes, 1, sizeof(b->bytes), in);
    fclose(in);
    return rc;
}

static int written_bytes(const genann *ann, buffer *b) {
    return written_bytes_genes(ann, &GENES, b);
}

static genann_actfun ACTIVATIONS[] = {
    genann_act_sigmoid, genann_act_sigmoid_cached, genann_act_threshold,
    genann_act_linear, genann_act_tanh, genann_act_relu
};
#define ACTIVATION_COUNT 6

// Every activation GENANN offers survives a round trip, hidden and output
// alike, and the network computes the same outputs afterwards.
void binary_activations() {
    for (int h = 0; h < ACTIVATION_COUNT; ++h) {
        for (int o = 0; o < ACTIVATION_COUNT; ++o) {
            genann *first = genann_init(3, 2, 4, 2);
            first->activation_hidden = ACTIVATIONS[h];
            first->activation_output = ACTIVATIONS[o];
            buffer b;
            lok(written_bytes(first, &b) == 0);
            genann *second = read_bytes(&b);
            lok(second != NULL);
            if (!second) { genann_free(first); continue; }
            lok(second->activation_hidden == ACTIVATIONS[h]);
            lok(second->activation_output == ACTIVATIONS[o]);
            const double input[3] = {0.5, -1.0, 2.0};
            const double *a = genann_run(first, input);
            const double a0 = a[0], a1 = a[1];
            const double *c = genann_run(second, input);
            lok(a0 == c[0] && a1 == c[1]);
            genann_free(first);
            genann_free(second);
        }
    }
}

// The bytes on disk follow the documented layout, whatever the machine.
void binary_layout() {
    genann *ann = genann_init(1, 1, 1, 1);
    ann->activation_hidden = genann_act_tanh;
    ann->activation_output = genann_act_linear;
    for (int i = 0; i < 4; ++i) ann->weight[i] = i - 1.5;
    buffer expected = header(1, 1, 1, 1, 1, 5, 4);
    for (int i = 0; i < 4; ++i) put_f64(&expected, i - 1.5);
    buffer got;
    lok(written_bytes(ann, &got) == 0);
    lequal((int)got.length, 34 + 5 * 8 + 4 * 8);
    lok(got.length == expected.length && memcmp(got.bytes, expected.bytes, got.length) == 0);

    genann *back = read_bytes(&expected);
    lok(back != NULL);
    if (back) {
        lequal(back->total_weights, 4);
        lok(back->weight[0] == -1.5 && back->weight[3] == 1.5);
        lok(back->activation_hidden == genann_act_tanh);
        lok(back->activation_output == genann_act_linear);
        genann_free(back);
    }
    genann_free(ann);
}

// The genes come back exactly as written, in their own fields, and a
// reader that does not want them passes NULL.
void binary_genes() {
    genann *ann = genann_init(2, 1, 3, 2);
    buffer b;
    lok(written_bytes(ann, &b) == 0);
    ann_genes back = {0};
    genann *second = read_bytes_genes(&b, &back);
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
    second = read_bytes_genes(&b, &back);
    lok(second != NULL && back.weight_changes == 1 && back.copy_chance == 1e-4);
    if (second) genann_free(second);
    lok(written_bytes_genes(ann, &highest, &b) == 0);
    second = read_bytes_genes(&b, &back);
    lok(second != NULL && back.weight_changes == ann->total_weights && back.structure_rate == 0.5);
    if (second) genann_free(second);
    genann_free(ann);
}

// Genes outside their clamps, or not finite, make the file unreadable, and
// the writer refuses to produce such a file (or one without genes).
void binary_read_rejects_bad_genes() {
    const double inf = INFINITY, not_a_number = NAN;
    // A 1-1-1-1 network has 4 weights, so weight_changes may be 1 to 4.
    struct { int gene; double value; } bad[] = {
        {0, 0.9e-4}, {0, 0.11}, {0, not_a_number}, {0, inf}, {0, -inf},
        {1, 0.999}, {1, 4.001}, {1, not_a_number}, {1, inf},
        {2, 0.9e-4}, {2, 10.01}, {2, not_a_number}, {2, -inf},
        {3, 0.9e-4}, {3, 0.51}, {3, not_a_number},
        {4, 0.9e-4}, {4, 0.51}, {4, inf},
    };
    genann *ann = genann_init(1, 1, 1, 1);
    for (size_t k = 0; k < sizeof(bad) / sizeof(bad[0]); ++k) {
        ann_genes g = GENES;
        double *fields[] = {&g.copy_chance, &g.weight_changes, &g.weight_step,
                            &g.activation_rate, &g.structure_rate};
        *fields[bad[k].gene] = bad[k].value;
        lok(ann_genes_invalid(&g, 4) != NULL);
        buffer b = header_only(1, 1, 1, 1, 1, 2, 2);
        put_genes(&b, g);
        for (int i = 0; i < 4; ++i) put_f64(&b, i);
        lok(read_bytes(&b) == NULL);
        buffer ignored;
        lok(written_bytes_genes(ann, &g, &ignored) != 0);
    }
    lok(ann_genes_invalid(&GENES, 4) == NULL);
    buffer ignored;
    lok(written_bytes_genes(ann, NULL, &ignored) != 0);
    genann_free(ann);
}

// Without hidden layers the width means nothing: it is written as 0,
// whatever the network says, and a file must hold 0 there.
void binary_no_hidden_layers() {
    genann *ann = genann_init(2, 0, 7, 3);
    lequal(ann->total_weights, 9);
    for (int i = 0; i < 9; ++i) ann->weight[i] = i;
    buffer expected = header(1, 2, 0, 0, 3, 2, 2);
    for (int i = 0; i < 9; ++i) put_f64(&expected, i);
    buffer got;
    lok(written_bytes(ann, &got) == 0);
    lok(got.length == expected.length && memcmp(got.bytes, expected.bytes, got.length) == 0);
    genann *back = read_bytes(&got);
    lok(back != NULL);
    if (back) {
        lequal(back->hidden, 0);
        lok(back->weight[8] == 8);
        genann_free(back);
    }

    buffer wide = header(1, 2, 0, 7, 3, 2, 2);
    for (int i = 0; i < 9; ++i) put_f64(&wide, i);
    lok(read_bytes(&wide) == NULL);
    genann_free(ann);
}

// Today's mutation load: 0.0004 changes per weight, at least one.
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

static double my_activation(const genann *ann, double a) { (void)ann; return a / 2; }

void binary_read_rejects_bad_files() {
    // A 1-1-1-1 network has 4 weights; this one is valid.
    buffer good = header(1, 1, 1, 1, 1, 2, 2);
    for (int i = 0; i < 4; ++i) put_f64(&good, i);
    genann *ann = read_bytes(&good);
    lok(ann != NULL);
    if (ann) genann_free(ann);

    buffer b = good;
    b.bytes[0] = 'X';
    lok(read_bytes(&b) == NULL); // not an Evo network

    b = header(2, 1, 1, 1, 1, 2, 2);
    for (int i = 0; i < 4; ++i) put_f64(&b, i);
    lok(read_bytes(&b) == NULL); // unknown version

    b = header(1, 1, 1, 1, 1, 7, 2);
    for (int i = 0; i < 4; ++i) put_f64(&b, i);
    lok(read_bytes(&b) == NULL); // unknown hidden activation

    b = header(1, 1, 1, 1, 1, 2, 0);
    for (int i = 0; i < 4; ++i) put_f64(&b, i);
    lok(read_bytes(&b) == NULL); // unknown output activation

    b = good;
    b.length = 20;
    lok(read_bytes(&b) == NULL); // header cut short

    b = good;
    b.length = 34 + 3 * 8 + 4;
    lok(read_bytes(&b) == NULL); // genes cut short

    b = good;
    b.length -= 1;
    lok(read_bytes(&b) == NULL); // weights cut short

    b = good;
    put_f64(&b, 9);
    lok(read_bytes(&b) == NULL); // bytes after the last weight

    // The layout before the genes block, the weights right after the
    // activation codes, is 40 bytes short, even when the first weights
    // would pass as genes. This network (1 input, 3 outputs) has 6 weights.
    b = header_only(1, 1, 0, 0, 3, 2, 2);
    const double old_weights[6] = {0.01, 1, 0.5, 0.02, 0.02, 0.25};
    for (int i = 0; i < 6; ++i) put_f64(&b, old_weights[i]);
    lok(read_bytes(&b) == NULL);

    b = header(1, 1, -1, 1, 1, 2, 2);
    lok(read_bytes(&b) == NULL); // impossible sizes
    b = header(1, 1 << 21, 1, 1, 1, 2, 2);
    lok(read_bytes(&b) == NULL);

    // An activation the format has no code for cannot be written.
    genann *custom = genann_init(1, 1, 1, 1);
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
    lrun("binary_genes", binary_genes);
    lrun("binary_bad_genes", binary_read_rejects_bad_genes);
    lrun("binary_no_layers", binary_no_hidden_layers);
    lrun("default_genes", default_genes);
    lrun("copy", copy);
    lrun("sigmoid", sigmoid);

    lresults();

    return lfails != 0;
}
