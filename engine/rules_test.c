/*
 * Tests of the Go rules the experiment depends on: Brown's board code
 * (captures, suicide, simple ko, pass) and the filter generate_move applies
 * to the network's choice. They pin down what the engine does today.
 */

#include <string.h>

#include "brown.h"
#include "generate_move.h"
#include "interface.h"
#include "minctest.h"

// Sets up a position from rows of 'X' (black), 'O' (white) and '.', on a
// board as wide as the rows. The position must have no stone without a
// liberty, so placing the stones captures nothing.
static void setup(const char **rows) {
  board_size = strlen(rows[0]);
  clear_board();
  play_move(-1, -1, BLACK); // clears the ko point
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
// opponent stone; otherwise, or when pass scores higher, it passes.
void test_the_move_filter() {
  genann *saved = ann;
  ann = genann_init(26, 0, 0, 26);
  double prediction[26];
  int i, j;

  // Occupied: the next best point is played.
  const char *occupied[] = {"X....", ".....", ".....", ".....", "....."};
  setup(occupied);
  predict(prediction, 25, POS(0, 0), POS(2, 2), 0);
  find_and_set_best_move(&i, &j, WHITE, prediction);
  lok(i == 2 && j == 2);

  // Suicide: skipped.
  const char *eye[] = {".X...", "X....", ".....", ".....", "....."};
  setup(eye);
  predict(prediction, 25, POS(0, 0), POS(3, 3), 0);
  find_and_set_best_move(&i, &j, WHITE, prediction);
  lok(i == 3 && j == 3);

  // Black's own eye is white's suicide point, and touches no white stone:
  // black does not fill it.
  find_and_set_best_move(&i, &j, BLACK, prediction);
  lok(i == 3 && j == 3);

  // Illegal ko recapture: skipped.
  const char *ko[] = {".XO..", "X.XO.", ".XO..", ".....", "....."};
  setup(ko);
  play_move(1, 1, WHITE);
  predict(prediction, 25, POS(1, 2), POS(4, 4), 0);
  find_and_set_best_move(&i, &j, BLACK, prediction);
  lok(i == 4 && j == 4);

  // Pass scores highest: pass.
  setup(occupied);
  predict(prediction, 25, POS(2, 2), -1, 1);
  find_and_set_best_move(&i, &j, BLACK, prediction);
  lok(i == -1 && j == -1);

  // Nothing allowed: pass.
  const char *full[] = {"XXXXX", "XXXXX", "XX.XX", "XXXXX", "XXXX."};
  setup(full);
  predict(prediction, 25, POS(2, 2), POS(4, 4), 0);
  find_and_set_best_move(&i, &j, BLACK, prediction);
  lok(i == -1 && j == -1);

  genann_free(ann);
  ann = saved;
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
  lrun("no_ko_two", test_no_ko_after_capturing_two_stones);
  lrun("no_ko_libs", test_no_ko_when_the_capturing_stone_has_liberties_left);
  lrun("move_filter", test_the_move_filter);

  lresults();
  return lfails != 0;
}
