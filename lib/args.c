#include "args.h"

#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

uint64_t parse_seed(const char *text) {
  char *end;
  errno = 0;
  unsigned long long value = strtoull(text, &end, 10);
  if (errno != 0 || end == text || *end != '\0' || text[0] == '-') {
    fprintf(stderr, "seed must be a non-negative integer, got %s\n", text);
    exit(1);
  }
  return value;
}

double parse_number(const char *name, const char *text, double min, double max) {
  char *end;
  errno = 0;
  double value = strtod(text, &end);
  if (errno != 0 || end == text || *end != '\0' || !isfinite(value) || value < min || value > max) {
    if (isinf(min) && isinf(max)) {
      fprintf(stderr, "%s must be a finite number, got %s\n", name, text);
    } else {
      fprintf(stderr, "%s must be a number from %g to %g, got %s\n", name, min, max, text);
    }
    exit(1);
  }
  return value;
}
