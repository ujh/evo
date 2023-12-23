/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *
 * This is Evo, a simple go program.                             *
 *                                                               *
 * Copyright 2023 by Urban Hafner                                *
 *           2003 and 2004 by Gunnar Farnebäck.                  *
 *                                                               *
 * Permission is hereby granted, free of charge, to any person   *
 * obtaining a copy of this file gtp.c, to deal in the Software  *
 * without restriction, including without limitation the rights  *
 * to use, copy, modify, merge, publish, distribute, and/or      *
 * sell copies of the Software, and to permit persons to whom    *
 * the Software is furnished to do so, provided that the above   *
 * copyright notice(s) and this permission notice appear in all  *
 * copies of the Software and that both the above copyright      *
 * notice(s) and this permission notice appear in supporting     *
 * documentation.                                                *
 *                                                               *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY     *
 * KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE    *
 * WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR       *
 * PURPOSE AND NONINFRINGEMENT OF THIRD PARTY RIGHTS. IN NO      *
 * EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS  *
 * NOTICE BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR    *
 * CONSEQUENTIAL DAMAGES, OR ANY DAMAGES WHATSOEVER RESULTING    *
 * FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF    *
 * CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT    *
 * OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS       *
 * SOFTWARE.                                                     *
 *                                                               *
 * Except as contained in this notice, the name of a copyright   *
 * holder shall not be used in advertising or otherwise to       *
 * promote the sale, use or other dealings in this Software      *
 * without prior written authorization of the copyright holder.  *
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

#include <string.h>
#include <stdlib.h>

#include "brown.h"

// Build input for the neural network. Use 1 for stone of own color, -1 for other color
void generate_ann_inputs(int color) {
  int ai, aj;
  int input_index = 1;

  // Set komi as the first input
  ann_inputs[0] = komi * (color == WHITE ? 1.0 : -1.0);
  // Set all stones as inputs
  for (ai = 0; ai < board_size; ai++)
    for (aj = 0; aj < board_size; aj++) {
      int v = get_board(ai, aj);
      if (v == EMPTY) {
        ann_inputs[input_index] = 0.0;
      } else {
        if (v == color) {
          ann_inputs[input_index] = 1.0;
        } else {
          ann_inputs[input_index] = -1.0;
        }
      }
      input_index++;
    }
}

void find_and_set_best_move(int *i, int *j, int color, const double *prediction) {
  int pred_index, ai, aj, k;
  int best_index = -1;
  for(pred_index = 0; pred_index < ann->outputs - 1; pred_index++) {
    if ((best_index == -1) || (prediction[pred_index] > prediction[best_index])) {
      ai = I(pred_index);
      aj = J(pred_index);
      // Needs to be a legal move and not a suicide
      if (legal_move(ai, aj, color) && !suicide(ai, aj, color)) {
        // Can't be a suicide for the oppponent either
        if (!suicide(ai, aj, OTHER_COLOR(color))) {
          best_index = pred_index;
        } else {
          // Unless it's a capture move
          for (k = 0; k < 4; k++) {
	          int bi = ai + deltai[k];
	          int bj = aj + deltaj[k];
	          if (on_board(bi, bj) && get_board(bi, bj) == OTHER_COLOR(color)) {
              best_index = pred_index;
              break;
            }
          }
        }
      }
    }
  }
  // Check the pass output, which is the last one
  if ((best_index != -1) && (prediction[best_index] > prediction[ann->outputs - 1])) {
    *i = I(best_index);
    *j = J(best_index);
  } else {
    // Pass
    *i = -1;
    *j = -1;
  }
}

void generate_move(int *i, int *j, int color) {
  generate_ann_inputs(color);
  double const *prediction = genann_run(ann, ann_inputs);
  find_and_set_best_move(i, j, color, prediction);
}
