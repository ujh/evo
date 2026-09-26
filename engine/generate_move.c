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
#include "generate_move.h"
#include "features.h"

// The .ann reader accepts exactly the board sizes Brown can play.
_Static_assert(ANN_MIN_SIDE == MIN_BOARD && ANN_MAX_SIDE == MAX_BOARD,
               "lib/ann.h's board sides must equal Brown's MIN_BOARD and MAX_BOARD");

// The network's inputs: komi, then one per point. Large enough for any
// board Brown supports; generate_move only runs networks that fit the board.
static double ann_inputs[MAX_BOARD * MAX_BOARD + 1];

// Build input for the neural network. Use 1 for stone of own color, -1 for other color
static void generate_ann_inputs(double *inputs, int color) {
  int ai, aj;
  int input_index = 1;

  // Set komi as the first input
  inputs[0] = komi * (color == WHITE ? 1.0 : -1.0);
  // Set all stones as inputs
  for (ai = 0; ai < board_size; ai++)
    for (aj = 0; aj < board_size; aj++) {
      int v = get_board(ai, aj);
      if (v == EMPTY) {
        inputs[input_index] = 0.0;
      } else {
        if (v == color) {
          inputs[input_index] = 1.0;
        } else {
          inputs[input_index] = -1.0;
        }
      }
      input_index++;
    }
}

void find_and_set_best_move(genann const *ann, int *i, int *j, int color, const double *prediction) {
  int pred_index;
  int best_index = -1;
  for(pred_index = 0; pred_index < ann->outputs - 1; pred_index++) {
    if ((best_index == -1) || (prediction[pred_index] > prediction[best_index])) {
      if (move_allowed(I(pred_index), J(pred_index), color)) best_index = pred_index;
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

int ann_fits_board(genann const *ann, int size) {
  int points = size * size;
  // One input per point plus komi, one output per point plus pass.
  return ann->inputs == points + 1 && ann->outputs == points + 1;
}

void generate_move(genann const *ann, int *i, int *j, int color) {
  generate_ann_inputs(ann_inputs, color);
  double const *prediction = genann_run(ann, ann_inputs);
  find_and_set_best_move(ann, i, j, color, prediction);
}
