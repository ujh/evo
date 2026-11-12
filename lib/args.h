#ifndef ARGS_H
#define ARGS_H

#include <stdint.h>

// The command-line numbers the programs take, parsed strictly: a typo exits
// 1 with a message instead of falling back to a default (for a seed, to an
// unseeded run). A seed is a non-negative decimal integer; a number a finite
// decimal in [min, max]. With both bounds infinite (-HUGE_VAL, HUGE_VAL),
// any finite number is taken, and its range is the caller's to check.
uint64_t parse_seed(const char *text);
double parse_number(const char *name, const char *text, double min, double max);

#endif
