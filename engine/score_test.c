/*
 * Tests of the Tromp-Taylor count in score.c: area scoring over Brown's
 * board with no dead-stone removal, and the result text twogtp and GNU Go
 * write.
 */

#include <string.h>

#include "brown.h"
#include "score.h"
#include "minctest.h"

/* Assert two strings are equal. */
#define lsequal(a, b) do {\
    ++ltests;\
    if (strcmp((a), (b)) != 0) {\
        ++lfails;\
        printf("%s:%d (\"%s\" != \"%s\")\n", __FILE__, __LINE__, (a), (b));\
    }} while (0)

// Sets up a position from rows of 'X' (black), 'O' (white) and '.', on a
// board as wide as the rows. The position must have no stone without a
// liberty, so placing the stones captures nothing.
static void setup(const char **rows) {
  board_size = strlen(rows[0]);
  new_game();
  for (int i = 0; i < board_size; i++)
    for (int j = 0; j < board_size; j++) {
      if (rows[i][j] == 'X') play_move(i, j, BLACK);
      if (rows[i][j] == 'O') play_move(i, j, WHITE);
    }
}

// The result text for the current board.
static const char *result(float game_komi) {
  static char text[SCORE_RESULT_SIZE];
  format_score(tromp_taylor_score(game_komi), text, sizeof text);
  return text;
}

void test_an_empty_board_scores_minus_komi() {
  const char *rows[] = {".....", ".....", ".....", ".....", "....."};
  setup(rows);
  lfequal(tromp_taylor_score(6.5), -6.5);
  lsequal(result(6.5), "W+6.5");
}

void test_a_region_bordering_one_color_is_its_territory() {
  // Black's wall on the second column: 5 stones and 5 points of territory.
  // The 15 points right of it border only black too.
  const char *rows[] = {".X...", ".X...", ".X...", ".X...", ".X..."};
  setup(rows);
  lfequal(tromp_taylor_score(0.5), 24.5);
  lsequal(result(0.5), "B+24.5");
}

void test_a_region_bordering_both_colors_counts_for_nobody() {
  // The middle column touches both walls: dame. Each side has its wall and
  // the column behind it.
  const char *rows[] = {".X.O.", ".X.O.", ".X.O.", ".X.O.", ".X.O."};
  setup(rows);
  lfequal(tromp_taylor_score(0), 0);
  lfequal(tromp_taylor_score(-2), 2);
  lsequal(result(-2), "B+2.0");
}

void test_dead_stones_are_counted_as_stones() {
  // A lone white stone inside black's area stays on the board: it counts
  // for white, and the region around it borders both colors.
  const char *rows[] = {".X...", ".X.O.", ".X...", ".X...", ".X..."};
  setup(rows);
  // Black: 5 stones and the first column's 5 points. White: 1 stone.
  lfequal(tromp_taylor_score(0.5), 8.5);
  lsequal(result(0.5), "B+8.5");
}

void test_separate_regions_are_counted_separately() {
  // The left corner region borders only black, the right one only white;
  // the middle one borders both.
  const char *rows[] = {".X.O.", "XX.OO", ".....", ".....", "....."};
  setup(rows);
  // Black: 3 stones and 1 point. White: 3 stones and 1 point.
  lfequal(tromp_taylor_score(0), 0);
}

void test_an_integer_komi_draw_is_written_as_0() {
  const char *rows[] = {".X...", ".X...", ".X...", ".X...", ".X..."};
  setup(rows);
  lfequal(tromp_taylor_score(25), 0);
  lsequal(result(25), "0");
}

void test_whole_point_margins_have_one_decimal() {
  const char *rows[] = {".X...", ".X...", ".X...", ".X...", ".X..."};
  setup(rows);
  lsequal(result(22), "B+3.0");
  lsequal(result(28), "W+3.0");
}

void test_the_smallest_board() {
  const char *rows[] = {"X.", ".."};
  setup(rows);
  lfequal(tromp_taylor_score(0.5), 3.5);
  const char *both[] = {"X.", ".O"};
  setup(both);
  lfequal(tromp_taylor_score(0.5), -0.5);
  lsequal(result(0.5), "W+0.5");
}

void test_the_largest_common_board() {
  const char *empty[19];
  for (int i = 0; i < 19; i++) empty[i] = "...................";
  setup(empty);
  lfequal(tromp_taylor_score(7.5), -7.5);
  const char *one[19];
  for (int i = 0; i < 19; i++) one[i] = empty[i];
  one[18] = "..................X";
  setup(one);
  lfequal(tromp_taylor_score(7.5), 361 - 7.5);
  lsequal(result(7.5), "B+353.5");
}

void test_a_negative_komi_counts_for_black() {
  const char *rows[] = {".....", ".....", ".....", ".....", "....."};
  setup(rows);
  lfequal(tromp_taylor_score(-3), 3);
  lsequal(result(-3), "B+3.0");
}

int main(void) {
  printf("Tromp-Taylor score test suite\n");

  lrun("empty", test_an_empty_board_scores_minus_komi);
  lrun("territory", test_a_region_bordering_one_color_is_its_territory);
  lrun("dame", test_a_region_bordering_both_colors_counts_for_nobody);
  lrun("dead_stones", test_dead_stones_are_counted_as_stones);
  lrun("regions", test_separate_regions_are_counted_separately);
  lrun("draw", test_an_integer_komi_draw_is_written_as_0);
  lrun("whole_points", test_whole_point_margins_have_one_decimal);
  lrun("size_2", test_the_smallest_board);
  lrun("size_19", test_the_largest_common_board);
  lrun("negative_komi", test_a_negative_komi_counts_for_black);

  lresults();
  return lfails != 0;
}
