/*
 * Tests of the Go rules the experiment depends on: Brown's board code
 * (captures, suicide, simple ko, pass), the filter generate_move applies
 * to the network's choice, and how the feature weights change that choice.
 * They pin down what the engine does today.
 */

#include <string.h>

#include "brown.h"
#include "ann.h"
#include "generate_move.h"
#include "features.h"
#include "minctest.h"

// Sets up a position from rows of 'X' (black), 'O' (white) and '.', on a
// board as wide as the rows. The position must have no stone without a
// liberty, so placing the stones captures nothing.
static void setup(const char **rows) {
  board_size = strlen(rows[0]);
  clear_board();
  play_move(-1, -1, BLACK); // a pass: clears the ko point (and records a pass as the last move)
  for (int i = 0; i < board_size; i++)
    for (int j = 0; j < board_size; j++) {
      if (rows[i][j] == 'X') play_move(i, j, BLACK);
      if (rows[i][j] == 'O') play_move(i, j, WHITE);
    }
}

// The board as rows, for comparing whole positions.
static int board_is(const char **rows) {
  for (int i = 0; i < board_size; i++)
    for (int j = 0; j < board_size; j++) {
      int want = rows[i][j] == 'X' ? BLACK : rows[i][j] == 'O' ? WHITE : EMPTY;
      if (get_board(i, j) != want) return 0;
    }
  return 1;
}

void test_captures_a_stone_in_the_middle() {
  const char *start[] = {".....", "..X..", ".XO..", "..X..", "....."};
  setup(start);
  play_move(2, 3, BLACK);
  const char *end[] = {".....", "..X..", ".X.X.", "..X..", "....."};
  lok(board_is(end));
}

void test_captures_a_string_on_the_edge_and_in_the_corner() {
  const char *start[] = {"OO.X.", "XX...", ".....", ".....", "....."};
  setup(start);
  play_move(0, 2, BLACK);
  const char *end[] = {"..XX.", "XX...", ".....", ".....", "....."};
  lok(board_is(end));
}

void test_one_move_captures_two_strings() {
  const char *start[] = {".X.X.", "XO.OX", ".X.X.", ".....", "....."};
  setup(start);
  play_move(1, 2, BLACK);
  const char *end[] = {".X.X.", "X.X.X", ".X.X.", ".....", "....."};
  lok(board_is(end));
}

void test_a_string_with_another_liberty_is_not_captured() {
  const char *start[] = {".....", "..X..", ".XO..", ".....", "....."};
  setup(start);
  play_move(2, 3, BLACK);
  lequal(get_board(2, 2), WHITE);
}

void test_joined_stones_form_one_string() {
  const char *start[] = {".....", ".X.X.", ".....", ".....", "....."};
  setup(start);
  play_move(1, 2, BLACK);
  int si[25], sj[25];
  lequal(get_string(1, 1, si, sj), 3);
}

void test_an_occupied_point_is_illegal() {
  const char *start[] = {".....", "..X..", ".....", ".....", "....."};
  setup(start);
  lok(!legal_move(1, 2, WHITE));
  lok(!legal_move(1, 2, BLACK));
  lok(legal_move(-1, -1, WHITE)); // pass is always legal
}

// A single white stone in black's eye has no liberty. Brown calls it
// suicide, but legal_move allows it; playing it removes nothing, since the
// stone has no friendly neighbor, and leaves the board unchanged.
void test_suicide_of_a_single_stone() {
  const char *start[] = {".X...", "X....", ".....", ".....", "....."};
  setup(start);
  lok(suicide(0, 0, WHITE));
  lok(legal_move(0, 0, WHITE));
  play_move(0, 0, WHITE);
  lok(board_is(start));
}

// Suicide of a string removes the whole string it joins.
void test_suicide_removes_the_friendly_string() {
  const char *start[] = {"O.X..", "XX...", ".....", ".....", "....."};
  setup(start);
  lok(suicide(0, 1, WHITE));
  play_move(0, 1, WHITE);
  const char *end[] = {"..X..", "XX...", ".....", ".....", "....."};
  lok(board_is(end));
}

// Filling your own last liberty is not suicide when it captures.
void test_a_capture_is_not_suicide() {
  const char *start[] = {".OX..", "OX...", "X....", ".....", "....."};
  setup(start);
  lok(!suicide(0, 0, BLACK));
  play_move(0, 0, BLACK);
  const char *end[] = {"X.X..", ".X...", "X....", ".....", "....."};
  lok(board_is(end));
}

// Simple ko: taking back a single stone at once is illegal, but legal after
// any other move, including a pass. The capturer may fill the ko.
void test_simple_ko() {
  const char *start[] = {".XO..", "X.XO.", ".XO..", ".....", "....."};
  setup(start);
  play_move(1, 1, WHITE); // captures the black stone at (1,2)
  lequal(get_board(1, 2), EMPTY);
  lok(!legal_move(1, 2, BLACK));
  lok(legal_move(1, 2, WHITE));
  play_move(4, 4, BLACK);
  lok(legal_move(1, 2, BLACK));

  setup(start);
  play_move(1, 1, WHITE);
  play_move(-1, -1, BLACK); // a pass also ends the ko
  lok(legal_move(1, 2, BLACK));
}

// new_game leaves an empty board and no ko point, whatever the last game
// left behind: a game in which the same shape arises through other moves
// may retake at the old ko point at once. (clear_board alone passes this
// too, since every move resets the ko point and the ko check needs an
// opponent stone next to it; the test pins the behavior, not new_game.)
void test_new_game_forgets_the_ko() {
  const char *start[] = {".XO..", "X.XO.", ".XO..", ".....", "....."};
  setup(start);
  play_move(1, 1, WHITE); // ko: black may not retake at (1,2) now
  lok(!legal_move(1, 2, BLACK));

  new_game();
  lok(board_empty());
  // Every point is open to both colors on the empty board.
  for (int i = 0; i < board_size; i++)
    for (int j = 0; j < board_size; j++)
      lok(legal_move(i, j, BLACK) && legal_move(i, j, WHITE));
  // The ko shape again, with white's last stone placed without a capture.
  const char *rebuilt[] = {".XO..", "XO.O.", ".XO..", ".....", "....."};
  const int moves[][3] = {
    {0, 1, BLACK}, {0, 2, WHITE}, {1, 0, BLACK}, {1, 3, WHITE},
    {2, 1, BLACK}, {2, 2, WHITE}, {1, 1, WHITE}};
  for (int k = 0; k < 7; k++) {
    lok(legal_move(moves[k][0], moves[k][1], moves[k][2]));
    play_move(moves[k][0], moves[k][1], moves[k][2]);
  }
  lok(board_is(rebuilt));
  lok(legal_move(1, 2, BLACK)); // captures (1,1): no ko applies
}

// Capturing two stones makes no ko, even when the capturing stone is left
// with a single liberty: black may take it back at once.
void test_no_ko_after_capturing_two_stones() {
  const char *start[] = {".....", ".XOO.", "X.XXO", ".XOO.", "....."};
  setup(start);
  play_move(2, 1, WHITE);
  const char *end[] = {".....", ".XOO.", "XO..O", ".XOO.", "....."};
  lok(board_is(end));
  lok(legal_move(2, 2, BLACK));
}

// Capturing one stone with a stone that then has more than one liberty is
// no ko either.
void test_no_ko_when_the_capturing_stone_has_liberties_left() {
  const char *start[] = {".XO..", "X.XO.", "..O..", ".....", "....."};
  setup(start);
  play_move(1, 1, WHITE); // captures (1,2); (1,1) keeps (2,1) as well
  lequal(get_board(1, 2), EMPTY);
  lok(legal_move(1, 2, BLACK));
}

// Everything a snapshot must bring back, read through Brown's interface:
// the board, each stone's string in link order, which moves are legal for
// either color (so the ko point), and the last move.
typedef struct {
  int size;
  int board[MAX_BOARD * MAX_BOARD];
  int string[MAX_BOARD * MAX_BOARD][MAX_BOARD * MAX_BOARD];
  int legal[2][MAX_BOARD * MAX_BOARD];
  int last, last_i, last_j, last_color;
} observed;

static void observe(observed *o) {
  memset(o, 0, sizeof(*o));
  o->size = board_size;
  for (int pos = 0; pos < board_size * board_size; pos++) {
    int i = I(pos), j = J(pos);
    o->board[pos] = get_board(i, j);
    if (o->board[pos] != EMPTY) {
      int si[MAX_BOARD * MAX_BOARD], sj[MAX_BOARD * MAX_BOARD];
      int n = get_string(i, j, si, sj);
      for (int k = 0; k < n; k++) o->string[pos][k] = POS(si[k], sj[k]) + 1;
    }
    o->legal[0][pos] = legal_move(i, j, BLACK);
    o->legal[1][pos] = legal_move(i, j, WHITE);
  }
  o->last = last_move(&o->last_i, &o->last_j, &o->last_color);
}

static observed before_trial, after_trial;

// A trial move that captures a string, restored: the captured stones come
// back with their string links, and the ko point and last move are the
// ones from before the trial.
void test_restore_undoes_a_capture() {
  // White's last move took a ko at (1,1), so black may not retake at (1,2).
  const char *start[] = {".XO..", "X.XO.", ".XO..", "OO...", "XX..."};
  setup(start);
  play_move(1, 1, WHITE);
  lok(!legal_move(1, 2, BLACK));
  observe(&before_trial);
  brown_state saved;
  brown_save(&saved);

  play_move(4, 2, WHITE); // captures the two black stones in the corner
  lequal(get_board(4, 0), EMPTY);
  lequal(get_board(4, 1), EMPTY);
  play_move(4, 0, BLACK); // reuses the captured points' links
  brown_restore(&saved);

  observe(&after_trial);
  lok(memcmp(&before_trial, &after_trial, sizeof(observed)) == 0);
  lok(!legal_move(1, 2, BLACK));
  int i, j, color;
  lequal(last_move(&i, &j, &color), LAST_MOVE_POINT);
  lok(i == 1 && j == 1 && color == WHITE);
}

// A trial ko capture sets a ko point and a last move of its own; restoring
// removes both.
void test_restore_undoes_a_ko_capture() {
  const char *start[] = {".XO..", "X.XO.", ".XO..", ".....", "....."};
  setup(start);
  play_pass(BLACK);
  observe(&before_trial);
  brown_state saved;
  brown_save(&saved);

  play_move(1, 1, WHITE); // ko capture of (1,2)
  lok(!legal_move(1, 2, BLACK));
  brown_restore(&saved);

  observe(&after_trial);
  lok(memcmp(&before_trial, &after_trial, sizeof(observed)) == 0);
  lok(legal_move(1, 1, WHITE));
  int i, j, color;
  lequal(last_move(&i, &j, &color), LAST_MOVE_PASS);
  lok(i == -1 && j == -1 && color == BLACK);
}

// A snapshot can be restored more than once.
void test_restore_twice() {
  const char *start[] = {".....", "..X..", ".XO..", "..X..", "....."};
  setup(start);
  observe(&before_trial);
  brown_state saved;
  brown_save(&saved);
  play_move(2, 3, BLACK);
  brown_restore(&saved);
  play_move(3, 2, WHITE);
  brown_restore(&saved);
  observe(&after_trial);
  lok(memcmp(&before_trial, &after_trial, sizeof(observed)) == 0);
}

static int last_is(int kind, int want_i, int want_j, int want_color) {
  int i = 99, j = 99, color = 99;
  return last_move(&i, &j, &color) == kind && i == want_i && j == want_j && color == want_color;
}

// Brown records the last move: a point and its color, a pass and its
// color, or none at the start of a game.
void test_last_move() {
  board_size = 5;
  new_game();
  lok(last_is(LAST_MOVE_NONE, -1, -1, EMPTY));
  play_move(2, 3, BLACK);
  lok(last_is(LAST_MOVE_POINT, 2, 3, BLACK));
  play_pass(WHITE);
  lok(last_is(LAST_MOVE_PASS, -1, -1, WHITE));
  play_move(1, 1, BLACK);
  play_move(-1, -1, WHITE); // play_move's pass is a pass too
  lok(last_is(LAST_MOVE_PASS, -1, -1, WHITE));
  play_move(1, 2, BLACK);
  clear_last_move();
  lok(last_is(LAST_MOVE_NONE, -1, -1, EMPTY));
  // The arguments may be NULL.
  play_move(3, 3, WHITE);
  lequal(last_move(NULL, NULL, NULL), LAST_MOVE_POINT);

  new_game();
  lok(last_is(LAST_MOVE_NONE, -1, -1, EMPTY));
  play_move(0, 0, BLACK);
  clear_board();
  lok(last_is(LAST_MOVE_NONE, -1, -1, EMPTY));
}

// A capture is the capturing stone's move.
void test_last_move_after_a_capture() {
  const char *start[] = {".....", "..X..", ".XO..", "..X..", "....."};
  setup(start);
  play_move(2, 3, BLACK);
  lok(last_is(LAST_MOVE_POINT, 2, 3, BLACK));
}

// A suicide is still the last move, at a point that is empty again.
void test_last_move_after_a_suicide() {
  const char *start[] = {"O.X..", "XX...", ".....", ".....", "....."};
  setup(start);
  play_move(0, 1, WHITE);
  lok(last_is(LAST_MOVE_POINT, 0, 1, WHITE));
  lequal(get_board(0, 1), EMPTY);
}

// Fixed handicap stones are not moves.
void test_fixed_handicap_leaves_no_last_move() {
  board_size = 9;
  new_game();
  play_move(4, 4, WHITE);
  clear_board();
  place_fixed_handicap(4);
  lequal(get_board(6, 2), BLACK);
  lok(last_is(LAST_MOVE_NONE, -1, -1, EMPTY));
}

// A prediction that scores `best` highest, `second` next, and everything
// else, pass included, lowest.
static void predict(double *prediction, int points, int best, int second, int pass_high) {
  for (int k = 0; k <= points; k++) prediction[k] = 0.0;
  if (best >= 0) prediction[best] = 0.9;
  if (second >= 0) prediction[second] = 0.8;
  if (pass_high) prediction[points] = 1.0;
}

// generate_move plays the highest-scoring point that is legal, not suicide,
// and not the opponent's suicide point (an own eye) unless it touches an
// opponent stone. It passes when nothing is allowed or pass scores at least
// as high.
void test_the_move_filter() {
  genann *ann = genann_init(26, 0, 0, 26);
  double prediction[26];
  int i, j;

  // Occupied: the next best point is played.
  const char *occupied[] = {"X....", ".....", ".....", ".....", "....."};
  setup(occupied);
  predict(prediction, 25, POS(0, 0), POS(2, 2), 0);
  find_and_set_best_move(ann, &i, &j, WHITE, prediction);
  lok(i == 2 && j == 2);

  // Suicide: skipped.
  const char *eye[] = {".X...", "X....", ".....", ".....", "....."};
  setup(eye);
  predict(prediction, 25, POS(0, 0), POS(3, 3), 0);
  find_and_set_best_move(ann, &i, &j, WHITE, prediction);
  lok(i == 3 && j == 3);

  // Black's own eye is white's suicide point, and touches no white stone:
  // black does not fill it.
  find_and_set_best_move(ann, &i, &j, BLACK, prediction);
  lok(i == 3 && j == 3);

  // White's suicide point is still played when it touches a white stone:
  // here it captures the white stone in the corner.
  const char *atari[] = {"O.X..", "XX...", ".....", ".....", "....."};
  setup(atari);
  lok(suicide(0, 1, WHITE));
  predict(prediction, 25, POS(0, 1), POS(3, 3), 0);
  find_and_set_best_move(ann, &i, &j, BLACK, prediction);
  lok(i == 0 && j == 1);

  // Illegal ko recapture: skipped.
  const char *ko[] = {".XO..", "X.XO.", ".XO..", ".....", "....."};
  setup(ko);
  play_move(1, 1, WHITE);
  predict(prediction, 25, POS(1, 2), POS(4, 4), 0);
  find_and_set_best_move(ann, &i, &j, BLACK, prediction);
  lok(i == 4 && j == 4);

  // Pass scores highest: pass.
  setup(occupied);
  predict(prediction, 25, POS(2, 2), -1, 1);
  find_and_set_best_move(ann, &i, &j, BLACK, prediction);
  lok(i == -1 && j == -1);

  // A tie with pass passes too, as saturated cached sigmoid outputs do.
  predict(prediction, 25, POS(2, 2), -1, 0);
  prediction[25] = prediction[POS(2, 2)];
  find_and_set_best_move(ann, &i, &j, BLACK, prediction);
  lok(i == -1 && j == -1);

  // Nothing allowed: pass.
  const char *full[] = {"XXXXX", "XXXXX", "XX.XX", "XXXXX", "XXXX."};
  setup(full);
  predict(prediction, 25, POS(2, 2), POS(4, 4), 0);
  find_and_set_best_move(ann, &i, &j, BLACK, prediction);
  lok(i == -1 && j == -1);

  genann_free(ann);
}

// The move choice refuses exactly the points move_allowed refuses, so the
// move features, which are 0 where move_allowed is false, never point at a
// move the engine would not play.
void test_the_move_choice_follows_move_allowed() {
  genann *ann = genann_init(26, 0, 0, 26);
  double prediction[26];
  const char *positions[][5] = {
    {".X...", "X....", ".....", ".....", "....."},
    {"O.X..", "XX...", ".....", ".....", "....."},
    {".XO..", "X.XO.", ".XO..", ".....", "....."},
    {".X.O.", "X.XO.", "OX.OO", ".OXX.", "XX.O."},
    {"XXXXX", "XXXXX", "XX.XX", "XXXXX", "XXXX."},
  };
  int refused = 0, allowed = 0;
  for (int n = 0; n < 5; n++) {
    setup(positions[n]);
    if (n == 2) play_move(1, 1, WHITE); // a ko
    for (int color = WHITE; color <= BLACK; color++)
      for (int p = 0; p < 25; p++) {
        int i, j;
        predict(prediction, 25, p, -1, 0);
        find_and_set_best_move(ann, &i, &j, color, prediction);
        int played = i == I(p) && j == J(p);
        lok(played == move_allowed(I(p), J(p), color));
        if (played) allowed++; else refused++;
      }
  }
  // Both kinds occur, and not only on occupied points.
  lok(allowed > 0 && refused > 0);
  genann_free(ann);
}

// A network without hidden layers whose every weight is 0, with linear
// outputs, for a board of `size` with the groups: every point scores 0 and
// pass `pass_score`, so its moves follow from the feature weights alone.
static genann *zero_network(int size, unsigned groups, double pass_score) {
  int points = size * size;
  int inputs = ann_layout_inputs(groups, points);
  genann *ann = genann_init(inputs, 0, 0, points + 1);
  ann->activation_output = genann_act_linear;
  for (int k = 0; k < ann->total_weights; k++) ann->weight[k] = 0.0;
  ann->weight[points * (inputs + 1)] = -pass_score; // the bias input is -1
  return ann;
}

// The tactics features with the weights given, in ANN_FEATURES' order.
static ann_features tactics(double capture, double self_atari, double saves_atari) {
  ann_features f = {.groups = ANN_GROUP_TACTICS, .feature_step = 0.01,
                    .weights = {capture, self_atari, saves_atari}};
  return f;
}

// The input buffer holds the largest layout Brown can play.
void test_the_input_buffer_fits_every_layout() {
  lok(GENERATE_MOVE_MAX_INPUTS == ann_layout_inputs(ANN_GROUPS_ALL, MAX_BOARD * MAX_BOARD));
}

// A network fits a board when its inputs are its feature set's layout for
// the board, and its outputs the points plus pass.
void test_ann_fits_board_with_features() {
  genann *plain = zero_network(5, 0, 0.0);
  genann *tactical = zero_network(5, ANN_GROUP_TACTICS, 0.0);
  ann_features none = ann_default_features(0);
  ann_features with = ann_default_features(ANN_GROUP_TACTICS);
  ann_features shapes = ann_default_features(ANN_GROUP_SHAPES);
  lok(ann_fits_board(plain, NULL, 5));
  lok(ann_fits_board(plain, &none, 5));
  lok(!ann_fits_board(plain, &with, 5));
  lok(!ann_fits_board(plain, NULL, 9));
  lok(ann_fits_board(tactical, &with, 5));
  lok(ann_fits_board(tactical, &shapes, 5)); // shapes adds 3 planes too
  lok(!ann_fits_board(tactical, NULL, 5));
  lok(!ann_fits_board(tactical, &none, 5));
  lok(!ann_fits_board(tactical, &with, 9));
  genann_free(plain);
  genann_free(tactical);
}

// Without features, generate_move plays what the network scores highest
// among the allowed points, as find_and_set_best_move picks.
void test_generate_move_without_features() {
  const char *atari[] = {".....", ".....", "...X.", "..XO.", "...X."};
  genann *ann = zero_network(5, 0, -1.0);
  ann_features none = ann_default_features(0);
  int i, j;
  setup(atari);
  generate_move(ann, NULL, &i, &j, BLACK);
  lok(i == 0 && j == 0); // every point ties, so the first allowed one
  generate_move(ann, &none, &i, &j, BLACK);
  lok(i == 0 && j == 0);
  genann_free(ann);
}

// A positive capture weight makes the capture the best point.
void test_generate_move_captures_with_a_capture_weight() {
  const char *atari[] = {".....", ".....", "...X.", "..XO.", "...X."};
  genann *ann = zero_network(5, ANN_GROUP_TACTICS, -1.0);
  ann_features f = tactics(1.0, 0.0, 0.0);
  int i, j;
  setup(atari);
  generate_move(ann, &f, &i, &j, BLACK);
  lok(i == 3 && j == 4);
  // White has nothing to capture and plays the first allowed point.
  generate_move(ann, &f, &i, &j, WHITE);
  lok(i == 0 && j == 0);
  // A zero weight changes nothing.
  f = tactics(0.0, 0.0, 0.0);
  generate_move(ann, &f, &i, &j, BLACK);
  lok(i == 0 && j == 0);
  genann_free(ann);
}

// A negative self_atari weight skips a self-atari the network would play.
void test_generate_move_avoids_self_atari() {
  const char *start[] = {".O...", ".....", ".....", ".....", "....."};
  genann *ann = zero_network(5, ANN_GROUP_TACTICS, -1.0);
  ann_features f = tactics(0.0, 0.0, 0.0);
  int i, j;
  setup(start);
  generate_move(ann, &f, &i, &j, BLACK);
  lok(i == 0 && j == 0); // A5 is a self-atari
  f = tactics(0.0, -10.0, 0.0);
  generate_move(ann, &f, &i, &j, BLACK);
  lok(i == 0 && j == 2);
  genann_free(ann);
}

// The weights of every feature at a point add up, and are compared with
// the pass output, which they never change.
void test_feature_weights_add_up_and_leave_pass_alone() {
  // Black's A5 is in atari; C5 captures B5 and saves A5, A4 only saves it.
  const char *start[] = {"XO...", ".X...", ".....", ".....", "....."};
  genann *ann = zero_network(5, ANN_GROUP_TACTICS, 0.5);
  int i, j;
  setup(start);
  ann_features f = tactics(0.3, 0.0, 0.3);
  generate_move(ann, &f, &i, &j, BLACK);
  lok(i == 0 && j == 2);
  // Alone, neither weight beats pass.
  f = tactics(0.3, 0.0, 0.0);
  generate_move(ann, &f, &i, &j, BLACK);
  lok(i == -1 && j == -1);
  f = tactics(0.0, 0.0, 0.3);
  generate_move(ann, &f, &i, &j, BLACK);
  lok(i == -1 && j == -1);
  // A tie with pass still passes.
  f = tactics(0.25, 0.0, 0.25);
  generate_move(ann, &f, &i, &j, BLACK);
  lok(i == -1 && j == -1);
  genann_free(ann);
}

// A network with every group reads its features' weights in ANN_FEATURES'
// order: only the capture weight (the fourth) is set.
void test_feature_weights_follow_the_feature_order() {
  const char *atari[] = {".....", ".....", "...X.", "..XO.", "...X."};
  genann *ann = zero_network(5, ANN_GROUPS_ALL, -1.0);
  ann_features f = {.groups = ANN_GROUPS_ALL, .feature_step = 0.01,
                    .weights = {0, 0, 0, 1.0, 0, 0, 0}};
  int i, j;
  setup(atari);
  generate_move(ann, &f, &i, &j, BLACK);
  lok(i == 3 && j == 4);
  // The move features were trial moves only: the board is as before.
  lok(board_is(atari));
  genann_free(ann);
}

int main(void) {
  printf("Go rules test suite\n");

  lrun("capture", test_captures_a_stone_in_the_middle);
  lrun("capture_edge", test_captures_a_string_on_the_edge_and_in_the_corner);
  lrun("capture_two", test_one_move_captures_two_strings);
  lrun("no_capture", test_a_string_with_another_liberty_is_not_captured);
  lrun("strings", test_joined_stones_form_one_string);
  lrun("occupied", test_an_occupied_point_is_illegal);
  lrun("suicide_one", test_suicide_of_a_single_stone);
  lrun("suicide_many", test_suicide_removes_the_friendly_string);
  lrun("capture_ok", test_a_capture_is_not_suicide);
  lrun("ko", test_simple_ko);
  lrun("new_game", test_new_game_forgets_the_ko);
  lrun("no_ko_two", test_no_ko_after_capturing_two_stones);
  lrun("no_ko_libs", test_no_ko_when_the_capturing_stone_has_liberties_left);
  lrun("restore_take", test_restore_undoes_a_capture);
  lrun("restore_ko", test_restore_undoes_a_ko_capture);
  lrun("restore_twice", test_restore_twice);
  lrun("last_move", test_last_move);
  lrun("last_capture", test_last_move_after_a_capture);
  lrun("last_suicide", test_last_move_after_a_suicide);
  lrun("last_handicap", test_fixed_handicap_leaves_no_last_move);
  lrun("move_filter", test_the_move_filter);
  lrun("move_allowed", test_the_move_choice_follows_move_allowed);
  lrun("input_buffer", test_the_input_buffer_fits_every_layout);
  lrun("fits_features", test_ann_fits_board_with_features);
  lrun("no_features", test_generate_move_without_features);
  lrun("w_capture", test_generate_move_captures_with_a_capture_weight);
  lrun("w_self_atari", test_generate_move_avoids_self_atari);
  lrun("weights_add", test_feature_weights_add_up_and_leave_pass_alone);
  lrun("weight_order", test_feature_weights_follow_the_feature_order);

  lresults();
  return lfails != 0;
}
