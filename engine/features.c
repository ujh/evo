/*
 * Move features for Evo, read from Brown's board.
 *
 * Copyright 2026 by Urban Hafner (MIT licence, see LICENSE).
 *
 * The 3x3 shapes (pat3_source below) and the way they are expanded
 * (expand() and its helpers, after pat3_expand) come from michi,
 * https://github.com/pasky/michi (michi.py's pat3src), under this licence:
 *
 *   Copyright (c) 2015 Petr Baudis <pasky@ucw.cz>
 *
 *   Permission is hereby granted, free of charge, to any person obtaining
 *   a copy of this software and associated documentation files (the
 *   "Software"), to deal in the Software without restriction, including
 *   without limitation the rights to use, copy, modify, merge, publish,
 *   distribute, sublicense, and/or sell copies of the Software, and to
 *   permit persons to whom the Software is furnished to do so, subject to
 *   the following conditions:
 *
 *   The above copyright notice and this permission notice shall be
 *   included in all copies or substantial portions of the Software.
 *
 *   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 *   EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 *   MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 *   NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
 *   LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
 *   OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
 *   WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

#include <string.h>

#include "brown.h"
#include "features.h"

int move_allowed(int i, int j, int color) {
  int other = OTHER_COLOR(color);
  if (!legal_move(i, j, color) || suicide(i, j, color)) return 0;
  // The opponent's suicide point is in effect an own eye: refused, unless
  // it touches an opponent stone (then it captures or fills a liberty).
  if (!suicide(i, j, other)) return 1;
  for (int k = 0; k < 4; k++) {
    int bi = i + deltai[k];
    int bj = j + deltaj[k];
    if (on_board(bi, bj) && get_board(bi, bj) == other) return 1;
  }
  return 0;
}

/* The 3x3 shapes. */

// michi's pat3src, the MoGo playout patterns, rows top to bottom around the
// candidate point in the centre: 'X' and 'O' are the two colours, 'x' is
// anything but 'X' (empty, 'O', or off the board), 'o' anything but 'O',
// '?' anything, '.' empty, ' ' off the board.
static const struct {
  unsigned family;
  const char *rows;
} pat3_source[] = {
  {FEATURE_HANE, "XOX" "..." "???"}, // enclosing hane
  {FEATURE_HANE, "XO." "..." "?.?"}, // non-cutting hane
  {FEATURE_HANE, "XO?" "X.." "x.?"}, // magari
  {FEATURE_HANE, ".O." "X.." "..."}, // katatsuke or diagonal attachment
  {FEATURE_CUT, "XO?" "O.o" "?o?"},  // unprotected cut (kiri)
  {FEATURE_CUT, "XO?" "O.X" "???"},  // peeped cut (kiri)
  {FEATURE_CUT, "?X?" "O.O" "ooo"},  // de
  {FEATURE_CUT, "OX?" "o.O" "???"},  // cut keima
  {FEATURE_EDGE, "X.?" "O.?" "   "}, // chase
  {FEATURE_EDGE, "OX?" "X.O" "   "}, // block side cut
  {FEATURE_EDGE, "?X?" "x.O" "   "}, // block side connection
  {FEATURE_EDGE, "?XO" "x.x" "   "}, // sagari
  {FEATURE_EDGE, "?OX" "X.O" "   "}, // side cut
};

// Per code, the families it matches, as FEATURE_BITs.
static unsigned char pat3_table[PATTERN3_CODES];
static int pat3_built = 0;

// A pattern is 9 characters, row by row.
static void rotate90(const char *p, char *out) {
  for (int r = 0; r < 3; r++)
    for (int c = 0; c < 3; c++) out[3 * r + c] = p[3 * (2 - c) + r];
}

static void flip_vertically(const char *p, char *out) {
  for (int r = 0; r < 3; r++)
    for (int c = 0; c < 3; c++) out[3 * r + c] = p[3 * (2 - r) + c];
}

static void flip_horizontally(const char *p, char *out) {
  for (int r = 0; r < 3; r++)
    for (int c = 0; c < 3; c++) out[3 * r + c] = p[3 * r + 2 - c];
}

static void swap_colors(const char *p, char *out) {
  static const char from[] = "XxOo";
  static const char to[] = "OoXx";
  for (int k = 0; k < 9; k++) {
    const char *at = strchr(from, p[k]);
    out[k] = p[k] != '\0' && at ? to[at - from] : p[k];
  }
}

// Marks the code of a pattern without wildcards, 'X' as own.
static void mark(const char *p, unsigned family) {
  unsigned code = 0;
  int k = 0;
  for (int n = 0; n < 9; n++) {
    if (n == 4) continue; // the centre, always '.'
    unsigned state = p[n] == 'X' ? NEIGHBOUR_OWN
                   : p[n] == 'O' ? NEIGHBOUR_OPPONENT
                   : p[n] == ' ' ? NEIGHBOUR_OFF_BOARD
                                 : NEIGHBOUR_EMPTY;
    code |= state << (2 * k);
    k++;
  }
  pat3_table[code] |= FEATURE_BIT(family);
}

// michi's pat_wildcards: every pattern the wildcards stand for.
static void expand_wildcards(char *p, unsigned family) {
  for (int n = 0; n < 9; n++) {
    const char *options = p[n] == '?' ? ".XO " : p[n] == 'x' ? ".O " : p[n] == 'o' ? ".X " : NULL;
    if (!options) continue;
    char wildcard = p[n];
    for (const char *o = options; *o; o++) {
      p[n] = *o;
      expand_wildcards(p, family);
    }
    p[n] = wildcard;
    return;
  }
  mark(p, family);
}

// michi's pat3_expand: the pattern and its quarter turn, each as is and
// flipped vertically, each of those as is and flipped horizontally, each of
// those as is and with the colours swapped, and all their wildcards. That
// covers all 8 orientations and both colours.
static void expand(const char *pattern, unsigned family) {
  char p[4][10] = {{0}}, q[10] = {0};
  memcpy(p[0], pattern, 9);
  rotate90(p[0], p[1]);
  for (int a = 0; a < 2; a++) {
    char v[2][10] = {{0}};
    memcpy(v[0], p[a], 9);
    flip_vertically(p[a], v[1]);
    for (int b = 0; b < 2; b++) {
      char h[2][10] = {{0}};
      memcpy(h[0], v[b], 9);
      flip_horizontally(v[b], h[1]);
      for (int c = 0; c < 2; c++) {
        memcpy(q, h[c], 9);
        expand_wildcards(q, family);
        swap_colors(h[c], q);
        expand_wildcards(q, family);
      }
    }
  }
}

static void build_pat3_table(void) {
  memset(pat3_table, 0, sizeof pat3_table);
  for (size_t n = 0; n < sizeof pat3_source / sizeof pat3_source[0]; n++)
    expand(pat3_source[n].rows, pat3_source[n].family);
  pat3_built = 1;
}

unsigned pattern3_families(unsigned code) {
  if (!pat3_built) build_pat3_table();
  return code < PATTERN3_CODES ? pat3_table[code] : 0;
}

unsigned pattern3_code(int i, int j, int color) {
  unsigned code = 0;
  int k = 0;
  for (int di = -1; di <= 1; di++)
    for (int dj = -1; dj <= 1; dj++) {
      if (di == 0 && dj == 0) continue;
      int ni = i + di, nj = j + dj;
      unsigned state;
      if (!on_board(ni, nj)) state = NEIGHBOUR_OFF_BOARD;
      else if (get_board(ni, nj) == EMPTY) state = NEIGHBOUR_EMPTY;
      else if (get_board(ni, nj) == color) state = NEIGHBOUR_OWN;
      else state = NEIGHBOUR_OPPONENT;
      code |= state << (2 * k);
      k++;
    }
  return code;
}

unsigned move_features_at(int i, int j, int color) {
  if (!move_allowed(i, j, color)) return 0;
  return pattern3_families(pattern3_code(i, j, color));
}
