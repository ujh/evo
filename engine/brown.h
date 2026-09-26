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

#define VERSION_STRING "1.0"

#define MIN_BOARD 2
#define MAX_BOARD 23

/* These must agree with the corresponding defines in gtp.c. */
#define EMPTY 0
#define WHITE 1
#define BLACK 2

/* Used in the final_status[] array. */
#define DEAD 0
#define ALIVE 1
#define SEKI 2
#define WHITE_TERRITORY 3
#define BLACK_TERRITORY 4
#define UNKNOWN 5

/* Macros to convert between 1D and 2D coordinates. The 2D coordinate
 * (i, j) points to row i and column j, starting with (0,0) in the
 * upper left corner.
 */
#define POS(i, j) ((i) * board_size + (j))
#define I(pos) ((pos) / board_size)
#define J(pos) ((pos) % board_size)

/* Macro to find the opposite color. */
#define OTHER_COLOR(color) (WHITE + BLACK - (color))

extern float komi;
extern int board_size;

/* Offsets for the four directly adjacent neighbors. Used for looping. */
static int deltai[4] = {-1, 1, 0, 0};
static int deltaj[4] = {0, 0, -1, 1};

/* What last_move() reports. */
#define LAST_MOVE_NONE 0
#define LAST_MOVE_PASS 1
#define LAST_MOVE_POINT 2

/* Brown's whole game state: the board, the string links, the ko point, and
 * the last move. board_size, komi, and the final status are not part of it.
 * brown_save copies the state into `state`, and brown_restore makes it the
 * current one again, as often as needed; a caller can keep any number of
 * snapshots (each about 4 kB, since the arrays are sized for MAX_BOARD), so
 * a trial move is: brown_save(&s); play_move(...); ...; brown_restore(&s).
 * A snapshot is only meaningful for the board_size it was taken at. The
 * fields are Brown's own; read the state through the functions below.
 */
typedef struct {
  int board[MAX_BOARD * MAX_BOARD];
  int next_stone[MAX_BOARD * MAX_BOARD];
  int ko_i, ko_j;
  int last_kind, last_i, last_j, last_color;
} brown_state;

void brown_save(brown_state *state);
void brown_restore(brown_state const *state);

void init_brown(void);
// Empties the board and forgets the last move. It keeps the ko point of
// the last move played; that cannot affect the next game, since every move
// resets it, but new_game does not rely on that.
void clear_board(void);
// Starts a game: an empty board, no ko point, and no last move.
void new_game(void);
// The last move: LAST_MOVE_NONE at the start of a game, after clear_board,
// and after handicap stones (which are not moves); LAST_MOVE_PASS after a
// pass; LAST_MOVE_POINT after a stone was played, even when it was a
// suicide and the point is empty again. It sets *i and *j to the point
// (-1, -1 for a pass or none) and *color to the player (EMPTY for none);
// any of them may be NULL.
int last_move(int *i, int *j, int *color);
// Forgets the last move, as after handicap stones placed with play_move.
void clear_last_move(void);
int board_empty(void);
int get_board(int i, int j);
int get_string(int i, int j, int *stonei, int *stonej);
int legal_move(int i, int j, int color);
// Plays a stone at (i, j), or a pass at (-1, -1), for color, without a
// legality check, and records it as the last move.
void play_move(int i, int j, int color);
// A pass for color: play_move(-1, -1, color).
void play_pass(int color);
void compute_final_status(void);
int get_final_status(int i, int j);
void set_final_status(int i, int j, int status);
int valid_fixed_handicap(int handicap);
// Places the stones with play_move and then clears the last move.
void place_fixed_handicap(int handicap);
int suicide(int i, int j, int color);
int on_board(int i, int j);
