/*
 * GENANN is compiled here, with ann.h's GENANN_RANDOM, so that every program
 * links one copy of it built the same way.
 */

#include "ann.h"
#include "genann.c"

#include <stdint.h>

const ann_activation ANN_ACTIVATIONS[] = {
    {"sigmoid", genann_act_sigmoid},
    {"sigmoid_cached", genann_act_sigmoid_cached},
    {"threshold", genann_act_threshold},
    {"linear", genann_act_linear},
    {"tanh", genann_act_tanh},
    {"relu", genann_act_relu},
};
const int ANN_ACTIVATION_COUNT = sizeof(ANN_ACTIVATIONS) / sizeof(ANN_ACTIVATIONS[0]);

static const char MAGIC[6] = {'E', 'V', 'O', 'A', 'N', 'N'};
static const uint32_t VERSION = 2;

// The code for an activation, or 0 for a function GENANN does not offer.
static uint32_t activation_code(genann_actfun function) {
    for (int i = 0; i < ANN_ACTIVATION_COUNT; ++i) {
        if (ANN_ACTIVATIONS[i].function == function) return i + 1;
    }
    return 0;
}

const char *ann_activation_name(genann_actfun function) {
    uint32_t code = activation_code(function);
    return code ? ANN_ACTIVATIONS[code - 1].name : NULL;
}

ann_genes ann_default_genes(int total_weights) {
    ann_genes genes = {
        .copy_chance = 0.01,
        .weight_changes = fmax(ANN_WEIGHT_CHANGES_MIN, 0.0004 * total_weights),
        .weight_step = 0.5,
        .activation_rate = 0.02,
        .structure_rate = 0.02,
    };
    return genes;
}

const ann_feature ANN_FEATURES[ANN_MAX_FEATURES] = {
    {"hane", ANN_GROUP_SHAPES, 0.05},
    {"cut", ANN_GROUP_SHAPES, 0.05},
    {"edge", ANN_GROUP_SHAPES, 0.05},
    {"capture", ANN_GROUP_TACTICS, 1.0},
    {"self_atari", ANN_GROUP_TACTICS, -1.0},
    {"saves_atari", ANN_GROUP_TACTICS, 0.8},
    {"near_last", ANN_GROUP_LAST_MOVE, 0.05},
};

ann_features ann_default_features(unsigned groups) {
    ann_features features = {.groups = groups, .feature_step = 0.01};
    int count = 0;
    for (int i = 0; i < ANN_MAX_FEATURES; ++i) {
        if (ANN_FEATURES[i].group & groups) features.weights[count++] = ANN_FEATURES[i].start_weight;
    }
    return features;
}

int ann_feature_count(unsigned groups) {
    if (groups & ~ANN_GROUPS_ALL) return -1;
    return (groups & ANN_GROUP_SHAPES ? 3 : 0) + (groups & ANN_GROUP_TACTICS ? 3 : 0) +
           (groups & ANN_GROUP_LAST_MOVE ? 1 : 0);
}

int ann_layout_inputs(unsigned groups, int points) {
    int features = ann_feature_count(groups);
    if (features < 0) return -1;
    return 1 + points + features * points + (groups & ANN_GROUP_LIBERTIES ? 3 * points : 0) +
           (groups & ANN_GROUP_LAST_MOVE ? points + 1 : 0);
}

void ann_print_genes_line(FILE *out, const genann *ann, const ann_genes *genes) {
    fprintf(out,
            "genes layers=%d width=%d act_hidden=%s act_output=%s copy_chance=%.17g weight_changes=%.17g "
            "weight_step=%.17g activation_rate=%.17g structure_rate=%.17g\n",
            ann->hidden_layers,
            ann->hidden_layers ? ann->hidden : 0,
            ann_activation_name(ann->activation_hidden),
            ann_activation_name(ann->activation_output),
            genes->copy_chance,
            genes->weight_changes,
            genes->weight_step,
            genes->activation_rate,
            genes->structure_rate);
}

// NaN fails both comparisons, so it is outside every range.
static int in_range(double value, double min, double max) {
    return isfinite(value) && value >= min && value <= max;
}

const char *ann_genes_invalid(const ann_genes *genes, int total_weights) {
    if (!in_range(genes->copy_chance, ANN_COPY_CHANCE_MIN, ANN_COPY_CHANCE_MAX)) return "copy_chance";
    if (!in_range(genes->weight_changes, ANN_WEIGHT_CHANGES_MIN, total_weights)) return "weight_changes";
    if (!in_range(genes->weight_step, ANN_WEIGHT_STEP_MIN, ANN_WEIGHT_STEP_MAX)) return "weight_step";
    if (!in_range(genes->activation_rate, ANN_ACTIVATION_RATE_MIN, ANN_ACTIVATION_RATE_MAX)) return "activation_rate";
    if (!in_range(genes->structure_rate, ANN_STRUCTURE_RATE_MIN, ANN_STRUCTURE_RATE_MAX)) return "structure_rate";
    return NULL;
}

const char *ann_features_invalid(const ann_features *features) {
    if (ann_feature_count(features->groups) < 0) return "groups";
    if (!in_range(features->feature_step, ANN_FEATURE_STEP_MIN, ANN_FEATURE_STEP_MAX)) return "feature_step";
    int count = 0;
    for (int i = 0; i < ANN_MAX_FEATURES; ++i) {
        if (!(ANN_FEATURES[i].group & features->groups)) continue;
        if (!in_range(features->weights[count++], ANN_FEATURE_WEIGHT_MIN, ANN_FEATURE_WEIGHT_MAX)) {
            return ANN_FEATURES[i].name;
        }
    }
    return NULL;
}

// The side of the square board with that many points plus pass, or 0 when
// there is none from ANN_MIN_SIDE to ANN_MAX_SIDE.
static int board_side(int outputs) {
    for (int side = ANN_MIN_SIDE; side <= ANN_MAX_SIDE; ++side) {
        if (side * side + 1 == outputs) return side;
    }
    return 0;
}

static int read_u32(FILE *in, uint32_t *v) {
    unsigned char b[4];
    if (fread(b, 1, 4, in) != 4) return 0;
    *v = (uint32_t)b[0] | (uint32_t)b[1] << 8 | (uint32_t)b[2] << 16 | (uint32_t)b[3] << 24;
    return 1;
}

static int read_f64(FILE *in, double *d) {
    unsigned char b[8];
    if (fread(b, 1, 8, in) != 8) return 0;
    uint64_t v = 0;
    for (int i = 7; i >= 0; --i) v = v << 8 | b[i];
    memcpy(d, &v, 8);
    return 1;
}

static int write_u32(FILE *out, uint32_t v) {
    unsigned char b[4] = {v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff};
    return fwrite(b, 1, 4, out) == 4;
}

static int write_f64(FILE *out, double d) {
    uint64_t v;
    memcpy(&v, &d, 8);
    unsigned char b[8];
    for (int i = 0; i < 8; ++i) b[i] = (v >> (8 * i)) & 0xff;
    return fwrite(b, 1, 8, out) == 8;
}

genann *ann_binary_read(FILE *in, ann_genes *genes, ann_features *features) {
    char magic[sizeof(MAGIC)];
    uint32_t version, sizes[4], codes[2];

    if (fread(magic, 1, sizeof(MAGIC), in) != sizeof(MAGIC) || memcmp(magic, MAGIC, sizeof(MAGIC)) != 0) {
        fprintf(stderr, "ann_binary_read: not an Evo network file\n");
        return NULL;
    }
    if (!read_u32(in, &version) || version != VERSION) {
        fprintf(stderr, "ann_binary_read: unsupported format version\n");
        return NULL;
    }
    for (int i = 0; i < 4; ++i) {
        if (!read_u32(in, &sizes[i])) {
            fprintf(stderr, "ann_binary_read: file too short for a network header\n");
            return NULL;
        }
    }
    for (int i = 0; i < 2; ++i) {
        if (!read_u32(in, &codes[i])) {
            fprintf(stderr, "ann_binary_read: file too short for a network header\n");
            return NULL;
        }
        if (codes[i] < 1 || codes[i] > (uint32_t)ANN_ACTIVATION_COUNT) {
            fprintf(stderr, "ann_binary_read: unknown activation code %u\n", codes[i]);
            return NULL;
        }
    }

    double gene_values[5];
    for (int i = 0; i < 5; ++i) {
        if (!read_f64(in, &gene_values[i])) {
            fprintf(stderr, "ann_binary_read: file too short for the genes\n");
            return NULL;
        }
    }
    ann_genes read_genes = {gene_values[0], gene_values[1], gene_values[2], gene_values[3], gene_values[4]};

    uint32_t groups;
    if (!read_u32(in, &groups)) {
        fprintf(stderr, "ann_binary_read: file too short for the feature groups\n");
        return NULL;
    }
    int feature_count = ann_feature_count(groups);
    if (feature_count < 0) {
        fprintf(stderr, "ann_binary_read: unknown feature groups in mask %u\n", groups);
        return NULL;
    }
    ann_features read_features = {.groups = groups};
    int ok = read_f64(in, &read_features.feature_step);
    for (int i = 0; ok && i < feature_count; ++i) ok = read_f64(in, &read_features.weights[i]);
    if (!ok) {
        fprintf(stderr, "ann_binary_read: file too short for the features\n");
        return NULL;
    }
    const char *bad_feature = ann_features_invalid(&read_features);
    if (bad_feature) {
        fprintf(stderr, "ann_binary_read: feature weight or step %s is not finite or out of range\n", bad_feature);
        return NULL;
    }

    int inputs = (int32_t)sizes[0], hidden_layers = (int32_t)sizes[1];
    int hidden = (int32_t)sizes[2], outputs = (int32_t)sizes[3];
    if (hidden_layers == 0 && hidden != 0) {
        fprintf(stderr, "ann_binary_read: %d hidden neurons without hidden layers\n", hidden);
        return NULL;
    }
    int side = board_side(outputs);
    if (side == 0) {
        fprintf(stderr, "ann_binary_read: %d outputs are no board of %dx%d to %dx%d plus pass\n",
                outputs, ANN_MIN_SIDE, ANN_MIN_SIDE, ANN_MAX_SIDE, ANN_MAX_SIDE);
        return NULL;
    }
    if (inputs != ann_layout_inputs(groups, side * side)) {
        fprintf(stderr, "ann_binary_read: %d inputs, but the feature groups need %d on a %dx%d board\n",
                inputs, ann_layout_inputs(groups, side * side), side, side);
        return NULL;
    }
    genann *ann = genann_init(inputs, hidden_layers, hidden, outputs);
    if (ann == NULL) {
        fprintf(stderr, "ann_binary_read: invalid network dimensions %d %d %d %d\n",
                inputs, hidden_layers, hidden, outputs);
        return NULL;
    }
    const char *bad = ann_genes_invalid(&read_genes, ann->total_weights);
    if (bad) {
        fprintf(stderr, "ann_binary_read: gene %s is not finite or out of range\n", bad);
        genann_free(ann);
        return NULL;
    }
    ann->activation_hidden = ANN_ACTIVATIONS[codes[0] - 1].function;
    ann->activation_output = ANN_ACTIVATIONS[codes[1] - 1].function;

    for (int i = 0; i < ann->total_weights; ++i) {
        if (!read_f64(in, ann->weight + i)) {
            fprintf(stderr, "ann_binary_read: file too short for %d weights\n", ann->total_weights);
            genann_free(ann);
            return NULL;
        }
    }
    if (fgetc(in) != EOF) {
        fprintf(stderr, "ann_binary_read: bytes after the last of %d weights\n", ann->total_weights);
        genann_free(ann);
        return NULL;
    }

    if (genes) *genes = read_genes;
    if (features) *features = read_features;
    return ann;
}

int ann_binary_write(const genann *ann, const ann_genes *genes, const ann_features *features, FILE *out) {
    uint32_t hidden_code = activation_code(ann->activation_hidden);
    uint32_t output_code = activation_code(ann->activation_output);
    if (!hidden_code || !output_code) {
        fprintf(stderr, "ann_binary_write: the network uses an activation GENANN does not offer\n");
        return -1;
    }
    if (genes == NULL) {
        fprintf(stderr, "ann_binary_write: no genes given\n");
        return -1;
    }
    const char *bad = ann_genes_invalid(genes, ann->total_weights);
    if (bad) {
        fprintf(stderr, "ann_binary_write: gene %s is not finite or out of range\n", bad);
        return -1;
    }

    if (features == NULL) {
        fprintf(stderr, "ann_binary_write: no features given\n");
        return -1;
    }
    const char *bad_feature = ann_features_invalid(features);
    if (bad_feature && strcmp(bad_feature, "groups") == 0) {
        fprintf(stderr, "ann_binary_write: unknown feature groups in mask %u\n", features->groups);
        return -1;
    }
    if (bad_feature) {
        fprintf(stderr, "ann_binary_write: feature weight or step %s is not finite or out of range\n", bad_feature);
        return -1;
    }

    // Without hidden layers the width means nothing, so it is always 0.
    int hidden = ann->hidden_layers ? ann->hidden : 0;
    int ok = fwrite(MAGIC, 1, sizeof(MAGIC), out) == sizeof(MAGIC)
        && write_u32(out, VERSION)
        && write_u32(out, (uint32_t)ann->inputs)
        && write_u32(out, (uint32_t)ann->hidden_layers)
        && write_u32(out, (uint32_t)hidden)
        && write_u32(out, (uint32_t)ann->outputs)
        && write_u32(out, hidden_code)
        && write_u32(out, output_code)
        && write_f64(out, genes->copy_chance)
        && write_f64(out, genes->weight_changes)
        && write_f64(out, genes->weight_step)
        && write_f64(out, genes->activation_rate)
        && write_f64(out, genes->structure_rate)
        && write_u32(out, features->groups)
        && write_f64(out, features->feature_step);
    int feature_count = ann_feature_count(features->groups);
    for (int i = 0; ok && i < feature_count; ++i) ok = write_f64(out, features->weights[i]);
    for (int i = 0; ok && i < ann->total_weights; ++i) ok = write_f64(out, ann->weight[i]);
    if (!ok) {
        fprintf(stderr, "ann_binary_write: write failed\n");
        return -1;
    }
    return 0;
}
