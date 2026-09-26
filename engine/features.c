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

#include <stdlib.h>
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

/* The tactics, near_last, and the board features. */

#define SHAPE_BITS (FEATURE_BIT(FEATURE_HANE) | FEATURE_BIT(FEATURE_CUT) | FEATURE_BIT(FEATURE_EDGE))
#define TACTIC_BITS \
  (FEATURE_BIT(FEATURE_CAPTURE) | FEATURE_BIT(FEATURE_SELF_ATARI) | FEATURE_BIT(FEATURE_SAVES_ATARI))
#define LAST_MOVE_BITS FEATURE_BIT(FEATURE_NEAR_LAST)

unsigned group_features(unsigned groups) {
  return (groups & ANN_GROUP_SHAPES ? SHAPE_BITS : 0) | (groups & ANN_GROUP_TACTICS ? TACTIC_BITS : 0) |
         (groups & ANN_GROUP_LAST_MOVE ? LAST_MOVE_BITS : 0);
}

// Marks for counting each liberty once: a point is marked when
// liberty_mark[p] == liberty_stamp.
static unsigned liberty_mark[MAX_BOARD * MAX_BOARD];
static unsigned liberty_stamp = 0;

// The liberties of the chain whose stones get_string gave.
static int count_liberties(int stones, const int *si, const int *sj) {
  if (++liberty_stamp == 0) {
    memset(liberty_mark, 0, sizeof liberty_mark);
    liberty_stamp = 1;
  }
  int liberties = 0;
  for (int s = 0; s < stones; s++)
    for (int k = 0; k < 4; k++) {
      int ai = si[s] + deltai[k], aj = sj[s] + deltaj[k];
      if (!on_board(ai, aj) || get_board(ai, aj) != EMPTY) continue;
      int pos = POS(ai, aj);
      if (liberty_mark[pos] == liberty_stamp) continue;
      liberty_mark[pos] = liberty_stamp;
      liberties++;
    }
  return liberties;
}

int chain_liberties(int i, int j) {
  if (get_board(i, j) == EMPTY) return 0;
  int si[MAX_BOARD * MAX_BOARD], sj[MAX_BOARD * MAX_BOARD];
  int stones = get_string(i, j, si, sj);
  return count_liberties(stones, si, sj);
}

// Each point's chain liberties (0 where empty), one count per chain.
static void all_liberties(int *liberties) {
  int points = board_size * board_size;
  int si[MAX_BOARD * MAX_BOARD], sj[MAX_BOARD * MAX_BOARD];
  for (int p = 0; p < points; p++) liberties[p] = -1;
  for (int p = 0; p < points; p++) {
    if (liberties[p] >= 0) continue;
    if (get_board(I(p), J(p)) == EMPTY) {
      liberties[p] = 0;
      continue;
    }
    int stones = get_string(I(p), J(p), si, sj);
    int n = count_liberties(stones, si, sj);
    for (int s = 0; s < stones; s++) liberties[POS(si[s], sj[s])] = n;
  }
}

// Whether the last move was the opponent's stone and it is still on the
// board; then its point in *i, *j.
static int opponent_last_stone(int color, int *i, int *j) {
  int li, lj, lc;
  if (last_move(&li, &lj, &lc) != LAST_MOVE_POINT || lc != OTHER_COLOR(color)) return 0;
  if (get_board(li, lj) != lc) return 0;
  *i = li;
  *j = lj;
  return 1;
}

static int opponent_passed(int color) {
  int lc;
  return last_move(NULL, NULL, &lc) == LAST_MOVE_PASS && lc == OTHER_COLOR(color);
}

void move_features_board(int color, unsigned wanted, unsigned *bits) {
  int points = board_size * board_size;
  int other = OTHER_COLOR(color);
  int liberties[MAX_BOARD * MAX_BOARD];
  // One stone of each own chain in atari.
  int atari[MAX_BOARD * MAX_BOARD], ataris = 0;
  int near = 0, li = -1, lj = -1;
  brown_state before;
  int saved = 0;

  if (wanted & TACTIC_BITS) {
    all_liberties(liberties);
    int si[MAX_BOARD * MAX_BOARD], sj[MAX_BOARD * MAX_BOARD];
    int seen[MAX_BOARD * MAX_BOARD] = {0};
    for (int p = 0; p < points; p++) {
      if (seen[p] || get_board(I(p), J(p)) != color || liberties[p] != 1) continue;
      int stones = get_string(I(p), J(p), si, sj);
      for (int s = 0; s < stones; s++) seen[POS(si[s], sj[s])] = 1;
      atari[ataris++] = p;
    }
  }
  if (wanted & LAST_MOVE_BITS) near = opponent_last_stone(color, &li, &lj);

  for (int p = 0; p < points; p++) {
    int i = I(p), j = J(p);
    bits[p] = 0;
    if (!move_allowed(i, j, color)) continue;
    unsigned f = 0;
    if (wanted & SHAPE_BITS) f |= pattern3_families(pattern3_code(i, j, color)) & wanted;
    if (near && p != POS(li, lj) && abs(i - li) <= 1 && abs(j - lj) <= 1) f |= LAST_MOVE_BITS;
    if (wanted & TACTIC_BITS) {
      int empties = 0, captures = 0, touches_atari = 0;
      for (int k = 0; k < 4; k++) {
        int ai = i + deltai[k], aj = j + deltaj[k];
        if (!on_board(ai, aj)) continue;
        int v = get_board(ai, aj);
        if (v == EMPTY) empties++;
        else if (liberties[POS(ai, aj)] == 1) {
          if (v == other) captures = 1;
          else touches_atari = 1;
        }
      }
      if (captures) f |= FEATURE_BIT(FEATURE_CAPTURE);
      // Without a capture, a move with two empty neighbours keeps two
      // liberties, and it can save only a chain in atari it touches. Only
      // the other moves need a trial.
      if (captures || touches_atari || empties < 2) {
        if (!saved) {
          brown_save(&before);
          saved = 1;
        }
        play_move(i, j, color);
        if (!captures && chain_liberties(i, j) == 1) f |= FEATURE_BIT(FEATURE_SELF_ATARI);
        for (int a = 0; a < ataris; a++)
          if (chain_liberties(I(atari[a]), J(atari[a])) >= 2) {
            f |= FEATURE_BIT(FEATURE_SAVES_ATARI);
            break;
          }
        brown_restore(&before);
      }
    }
    bits[p] = f & wanted;
  }
}

unsigned move_features_at(int i, int j, int color) {
  unsigned bits[MAX_BOARD * MAX_BOARD];
  move_features_board(color, (1u << MOVE_FEATURES) - 1, bits);
  return bits[POS(i, j)];
}

int feature_inputs(unsigned groups, int color, double *inputs, unsigned *bits) {
  int points = board_size * board_size;
  int n = ann_layout_inputs(groups, points);
  if (n < 0) return -1;
  unsigned local[MAX_BOARD * MAX_BOARD];
  unsigned *b = bits ? bits : local;
  unsigned wanted = group_features(groups);
  int k = 0;

  inputs[k++] = komi * (color == WHITE ? 1.0 : -1.0);
  for (int p = 0; p < points; p++) {
    int v = get_board(I(p), J(p));
    inputs[k++] = v == EMPTY ? 0.0 : v == color ? 1.0 : -1.0;
  }
  if (wanted) move_features_board(color, wanted, b);
  else memset(b, 0, points * sizeof *b);
  for (int f = 0; f < MOVE_FEATURES; f++) {
    if (!(wanted & FEATURE_BIT(f))) continue;
    for (int p = 0; p < points; p++) inputs[k++] = (b[p] & FEATURE_BIT(f)) ? 1.0 : 0.0;
  }
  if (groups & ANN_GROUP_LIBERTIES) {
    int liberties[MAX_BOARD * MAX_BOARD];
    all_liberties(liberties);
    for (int plane = 1; plane <= 3; plane++)
      for (int p = 0; p < points; p++) {
        int v = get_board(I(p), J(p));
        int l = liberties[p] > 3 ? 3 : liberties[p];
        inputs[k++] = v == EMPTY || l != plane ? 0.0 : v == color ? 1.0 : -1.0;
      }
  }
  if (groups & ANN_GROUP_LAST_MOVE) {
    int li, lj;
    int stone = opponent_last_stone(color, &li, &lj) ? POS(li, lj) : -1;
    for (int p = 0; p < points; p++) inputs[k++] = p == stone ? 1.0 : 0.0;
    inputs[k++] = opponent_passed(color) ? 1.0 : 0.0;
  }
  return k;
}
