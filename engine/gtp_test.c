/*
 * Tests of what evo's GTP commands leave behind in Brown's game state:
 * which move counts as the last one after play, genmove, clear_board, and
 * the handicap commands. It runs evo's own command table (interface.c) on
 * command scripts and reads Brown's state afterwards; the answers go to
 * /dev/null, since enginetest.sh checks them.
 */

#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "brown.h"
#include "ann.h"
#include "interface.h"
#include "minctest.h"

// A network for a board of `size` without hidden layers and with linear
// outputs. It scores the points from the top left down, row by row, and
// pass lowest, so it plays the first allowed point; with `passes`, every
// output is 0, and the tie passes.
static genann *network(int size, int passes) {
  int points = size * size;
  genann *net = genann_init(points + 1, 0, 0, points + 1);
  net->activation_output = genann_act_linear;
  for (int k = 0; k < net->total_weights; k++) net->weight[k] = 0.0;
  if (!passes)
    for (int k = 0; k <= points; k++)
      // The bias weight multiplies a constant -1 input.
      net->weight[k * (points + 2)] = k == points ? 1.0 : -1.0 + k * 0.01;
  return net;
}

// Runs GTP commands, one per line, through evo's command table.
static void gtp(const char *commands) {
  FILE *in = fmemopen((void *)commands, strlen(commands), "r");
  fflush(stdout);
  int saved = dup(STDOUT_FILENO);
  int null = open("/dev/null", O_WRONLY);
  dup2(null, STDOUT_FILENO);
  close(null);
  run_gtp(in);
  fflush(stdout);
  dup2(saved, STDOUT_FILENO);
  close(saved);
  fclose(in);
}

static int last_is(int kind, int want_i, int want_j, int want_color) {
  int i = 99, j = 99, color = 99;
  return last_move(&i, &j, &color) == kind && i == want_i && j == want_j && color == want_color;
}

static void use(genann *net) {
  if (ann != NULL) genann_free(ann);
  ann = net;
}

void test_play_and_pass() {
  use(network(5, 1));
  gtp("boardsize 5\nclear_board\n");
  lok(last_is(LAST_MOVE_NONE, -1, -1, EMPTY));
  gtp("boardsize 5\nclear_board\nplay b C3\n");
  lok(last_is(LAST_MOVE_POINT, 2, 2, BLACK));
  gtp("boardsize 5\nclear_board\nplay b C3\nplay w pass\n");
  lok(last_is(LAST_MOVE_PASS, -1, -1, WHITE));
  // An illegal move is refused and changes nothing.
  gtp("boardsize 5\nclear_board\nplay b C3\nplay w C3\n");
  lok(last_is(LAST_MOVE_POINT, 2, 2, BLACK));
  gtp("boardsize 5\nclear_board\nplay b C3\nclear_board\n");
  lok(last_is(LAST_MOVE_NONE, -1, -1, EMPTY));
}

// GTP play accepts suicide: the stone is removed at once, but it was the
// last move.
void test_suicide() {
  use(network(5, 1));
  gtp("boardsize 5\nclear_board\nplay b B5\nplay b A4\nplay w A5\n");
  lok(last_is(LAST_MOVE_POINT, 0, 0, WHITE));
  lequal(get_board(0, 0), EMPTY);
}

void test_genmove() {
  use(network(5, 0));
  gtp("boardsize 5\nclear_board\nplay b A5\ngenmove w\n");
  lok(last_is(LAST_MOVE_POINT, 0, 1, WHITE));
  lequal(get_board(0, 1), WHITE);
  use(network(5, 1));
  gtp("boardsize 5\nclear_board\nplay b A5\ngenmove w\n");
  lok(last_is(LAST_MOVE_PASS, -1, -1, WHITE));
}

// Handicap stones are not moves, even when they follow a move.
void test_handicap() {
  use(network(9, 0));
  gtp("boardsize 9\nclear_board\nfixed_handicap 3\n");
  lequal(get_board(2, 2), BLACK);
  lok(last_is(LAST_MOVE_NONE, -1, -1, EMPTY));

  gtp("boardsize 9\nclear_board\nset_free_handicap A1 B2 C3\n");
  lequal(get_board(8, 0), BLACK);
  lequal(get_board(6, 2), BLACK);
  lok(last_is(LAST_MOVE_NONE, -1, -1, EMPTY));

  // Its error paths clear the board, and with it the stones placed so far.
  gtp("boardsize 9\nclear_board\nset_free_handicap A1 A1\n");
  lok(board_empty());
  lok(last_is(LAST_MOVE_NONE, -1, -1, EMPTY));

  // The network places free handicap stones with its own moves.
  gtp("boardsize 9\nclear_board\nplace_free_handicap 2\n");
  lequal(get_board(0, 0), BLACK);
  lequal(get_board(0, 1), BLACK);
  lok(last_is(LAST_MOVE_NONE, -1, -1, EMPTY));
  gtp("boardsize 9\nclear_board\nplace_free_handicap 2\nplay w E5\n");
  lok(last_is(LAST_MOVE_POINT, 4, 4, WHITE));
}

// place_free_handicap plays the network with its features. The network
// sees the liberty planes (liberties group): on 9x9 it scores the points as
// network() does, plus 10 at E5 when A9 holds an own stone with two
// liberties (plane 2 at A9). Its first stone goes to A9, the first point;
// its second to E5, which it plays only if it reads its feature inputs.
void test_free_handicap_with_features() {
  int points = 81;
  int inputs = ann_layout_inputs(ANN_GROUP_LIBERTIES, points);
  genann *net = genann_init(inputs, 0, 0, points + 1);
  net->activation_output = genann_act_linear;
  for (int k = 0; k < net->total_weights; k++) net->weight[k] = 0.0;
  for (int k = 0; k <= points; k++)
    net->weight[k * (inputs + 1)] = k == points ? 1.0 : -1.0 + k * 0.01;
  int e5 = 4 * 9 + 4;
  int plane2_at_a9 = 1 + points + points; // komi, stones, plane 1, then plane 2's first point
  net->weight[e5 * (inputs + 1) + 1 + plane2_at_a9] = 10.0;
  use(net);
  network_features = ann_default_features(ANN_GROUP_LIBERTIES);

  gtp("boardsize 9\nclear_board\nplace_free_handicap 2\n");
  lequal(get_board(0, 0), BLACK);
  lequal(get_board(4, 4), BLACK);
  lequal(get_board(0, 1), EMPTY);
  lok(last_is(LAST_MOVE_NONE, -1, -1, EMPTY));

  network_features = ann_default_features(0);
}

int main(void) {
  printf("GTP state test suite\n");

  lrun("play", test_play_and_pass);
  lrun("suicide", test_suicide);
  lrun("genmove", test_genmove);
  lrun("handicap", test_handicap);
  lrun("free_features", test_free_handicap_with_features);

  lresults();
  return lfails != 0;
}
