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

#include "ann.h"

// The move policy. It reads Brown's board, board_size, and komi, and needs
// nothing from the GTP code, so any program can link it with brown.o and
// features.o.

// The most inputs a network can have: every feature group on a 23x23
// board (lib/ann.h's layout: komi, the stones, 7 move feature planes, 3
// liberty planes, the last_move plane, and opponent_passed).
#define GENERATE_MOVE_MAX_INPUTS (2 + (1 + ANN_MAX_FEATURES + 3 + 1) * ANN_MAX_SIDE * ANN_MAX_SIDE)

// Whether `ann` has the inputs of its feature set's layout (features NULL:
// no groups, komi and the stones only) and one output per point plus pass
// for a board of `size`.
int ann_fits_board(genann const *ann, ann_features const *features, int size);
// The move `ann`, with its features (NULL for none), plays for `color` on
// the current board: the inputs of its groups (feature_inputs), the
// network's scores, each point's score plus the weight of every move
// feature of the groups that is 1 there (pass unchanged), and then
// find_and_set_best_move. Callers must check ann_fits_board(ann, features,
// board_size) first.
void generate_move(genann const *ann, ann_features const *features, int *i, int *j, int color);
// Picks the highest-scoring point in `prediction` (one score per point of
// `ann`'s outputs, then pass) that move_allowed (features.h) accepts, or
// pass.
void find_and_set_best_move(genann const *ann, int *i, int *j, int color, const double *prediction);
