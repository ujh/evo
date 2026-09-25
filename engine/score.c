/*
 * Tromp-Taylor area scoring over Brown's current board.
 */

#include <math.h>
#include <stdio.h>

#include "brown.h"
#include "score.h"

// Flood-fills the empty region holding (i, j), marking its points in seen,
// and returns its size. *borders gets the bits BLACK and WHITE for the
// colors of the stones next to the region.
static int fill_region(int i, int j, int *seen, int *borders) {
  static int stack[MAX_BOARD * MAX_BOARD];
  int top = 0;
  int size = 0;
  seen[POS(i, j)] = 1;
  stack[top++] = POS(i, j);
  while (top > 0) {
    int pos = stack[--top];
    size++;
    for (int k = 0; k < 4; k++) {
      int ai = I(pos) + deltai[k];
      int aj = J(pos) + deltaj[k];
      if (!on_board(ai, aj)) continue;
      int color = get_board(ai, aj);
      if (color != EMPTY) {
        *borders |= color;
      } else if (!seen[POS(ai, aj)]) {
        seen[POS(ai, aj)] = 1;
        stack[top++] = POS(ai, aj);
      }
    }
  }
  return size;
}

float tromp_taylor_score(float game_komi) {
  int seen[MAX_BOARD * MAX_BOARD] = {0};
  int black = 0;
  int white = 0;
  for (int i = 0; i < board_size; i++)
    for (int j = 0; j < board_size; j++) {
      int color = get_board(i, j);
      if (color == BLACK) {
        black++;
      } else if (color == WHITE) {
        white++;
      } else if (!seen[POS(i, j)]) {
        int borders = 0;
        int size = fill_region(i, j, seen, &borders);
        if (borders == BLACK) black += size;
        if (borders == WHITE) white += size;
      }
    }
  return black - (white + game_komi);
}

void format_score(float margin, char *text, size_t size) {
  if (margin == 0)
    snprintf(text, size, "0");
  else
    snprintf(text, size, "%c+%.1f", margin > 0 ? 'B' : 'W', fabs(margin));
}
