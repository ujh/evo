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

#include <stdio.h>
#include <stdlib.h>  /* for rand() and srand() */
#include <string.h>

#include "brown.h"
#include "generate_move.h"
#include "gtp.h"
#include "interface.h"

/* Forward declarations. */
static int gtp_protocol_version(char *s);
static int gtp_name(char *s);
static int gtp_version(char *s);
static int gtp_known_command(char *s);
static int gtp_list_commands(char *s);
static int gtp_quit(char *s);
static int gtp_boardsize(char *s);
static int gtp_clear_board(char *s);
static int gtp_komi(char *s);
static int gtp_fixed_handicap(char *s);
static int gtp_place_free_handicap(char *s);
static int gtp_set_free_handicap(char *s);
static int gtp_play(char *s);
static int gtp_genmove(char *s);
static int gtp_final_score(char *s);
static int gtp_final_status_list(char *s);
static int gtp_showboard(char *s);

/* List of known commands. */
static struct gtp_command commands[] = {
  {"protocol_version",    gtp_protocol_version},
  {"name",                gtp_name},
  {"version",             gtp_version},
  {"known_command",    	  gtp_known_command},
  {"list_commands",    	  gtp_list_commands},
  {"quit",             	  gtp_quit},
  {"boardsize",        	  gtp_boardsize},
  {"clear_board",      	  gtp_clear_board},
  {"komi",        	  gtp_komi},
  {"fixed_handicap",   	  gtp_fixed_handicap},
  {"place_free_handicap", gtp_place_free_handicap},
  {"set_free_handicap",   gtp_set_free_handicap},
  {"play",            	  gtp_play},
  {"genmove",             gtp_genmove},
  {"final_score",         gtp_final_score},
  {"final_status_list",   gtp_final_status_list},
  {"showboard",        	  gtp_showboard},
  {NULL,                  NULL}
};

genann *ann = NULL;
double *ann_inputs = NULL;

void allocate_ann(char *ann_save_file) {
  int points = board_size * board_size;
  // Komi as input
  int input_size = points + 1;
  // Allow pass move as output
  int output_size = points + 1;

  fprintf(stderr, "Loading NN ...");

  if (ann != NULL) genann_free(ann);
  if (ann_save_file == NULL) {
    ann = genann_init(input_size, 5, points * 10, output_size);
  } else {
    FILE *fd = fopen(ann_save_file, "rb");
    ann = genann_binary_read(fd);
    fclose(fd);
  }

  fprintf(
    stderr,
    "\rLoaded NN with %d inputs, %d outputs, %d layers, %d neurons per layer, %d total neurons\n",
    ann->inputs,
    ann->outputs,
    ann->hidden_layers,
    ann->hidden,
    ann->total_weights
  );
}

void allocate_ann_inputs() {
  if (ann_inputs != NULL) free(ann_inputs);
  ann_inputs = malloc(ann->inputs * sizeof(double));
}

int boot(int argc, char **argv) {
  /* Make sure that stdout is not block buffered. */
  setbuf(stdout, NULL);

  /* Inform the GTP utility functions about the initial board size. */
  gtp_internal_set_boardsize(board_size);

  // Initialize the NN
  allocate_ann(argc > 1 ? argv[1] : NULL);
  allocate_ann_inputs();

  /* Initialize the board. */
  init_brown();

  /* Process GTP commands. */
  gtp_main_loop(commands, stdin, NULL);

  return 0;
}

/* We are talking version 2 of the protocol. */
static int
gtp_protocol_version(char *s)
{
  return gtp_success("2");
}

static int
gtp_name(char *s)
{
  return gtp_success("Brown");
}

static int
gtp_version(char *s)
{
  return gtp_success(VERSION_STRING);
}

static int
gtp_known_command(char *s)
{
  int i;
  char command_name[GTP_BUFSIZE];

  /* If no command name supplied, return false (this command never
   * fails according to specification).
   */
  if (sscanf(s, "%s", command_name) < 1)
    return gtp_success("false");

  for (i = 0; commands[i].name; i++)
    if (!strcmp(command_name, commands[i].name))
      return gtp_success("true");

  return gtp_success("false");
}

static int
gtp_list_commands(char *s)
{
  int i;

  gtp_start_response(GTP_SUCCESS);

  for (i = 0; commands[i].name; i++)
    gtp_printf("%s\n", commands[i].name);

  gtp_printf("\n");
  return GTP_OK;
}

static int
gtp_quit(char *s)
{
  gtp_success("");
  return GTP_QUIT;
}

static int
gtp_boardsize(char *s)
{
  int boardsize;

  if (sscanf(s, "%d", &boardsize) < 1)
    return gtp_failure("boardsize not an integer");

  if (boardsize < MIN_BOARD || boardsize > MAX_BOARD)
    return gtp_failure("unacceptable size");

  board_size = boardsize;
  gtp_internal_set_boardsize(boardsize);
  init_brown();

  return gtp_success("");
}

static int
gtp_clear_board(char *s)
{
  clear_board();
  return gtp_success("");
}

static int
gtp_komi(char *s)
{
  if (sscanf(s, "%f", &komi) < 1)
    return gtp_failure("komi not a float");

  return gtp_success("");
}

/* Common code for fixed_handicap and place_free_handicap. */
static int
place_handicap(char *s, int fixed)
{
  int handicap;
  int m, n;
  int first_stone = 1;

  if (!board_empty())
    return gtp_failure("board not empty");

  if (sscanf(s, "%d", &handicap) < 1)
    return gtp_failure("handicap not an integer");

  if (handicap < 2)
    return gtp_failure("invalid handicap");

  if (fixed && !valid_fixed_handicap(handicap))
    return gtp_failure("invalid handicap");

  if (fixed)
    place_fixed_handicap(handicap);
  else
    place_free_handicap(handicap);

  gtp_start_response(GTP_SUCCESS);
  for (m = 0; m < board_size; m++)
    for (n = 0; n < board_size; n++)
      if (get_board(m, n) != EMPTY) {
	if (first_stone)
	  first_stone = 0;
	else
	  gtp_printf(" ");
	gtp_mprintf("%m", m, n);
      }
  return gtp_finish_response();
}

static int
gtp_fixed_handicap(char *s)
{
  return place_handicap(s, 1);
}

static int
gtp_place_free_handicap(char *s)
{
  return place_handicap(s, 0);
}

static int
gtp_set_free_handicap(char *s)
{
  int i, j;
  int n;
  int handicap = 0;

  if (!board_empty())
    return gtp_failure("board not empty");

  while ((n = gtp_decode_coord(s, &i, &j)) > 0) {
    s += n;

    if (get_board(i, j) != EMPTY) {
      clear_board();
      return gtp_failure("repeated vertex");
    }

    play_move(i, j, BLACK);
    handicap++;
  }

  if (sscanf(s, "%*s") != EOF) {
      clear_board();
      return gtp_failure("invalid coordinate");
  }

  if (handicap < 2 || handicap >= board_size * board_size) {
      clear_board();
      return gtp_failure("invalid handicap");
  }

  return gtp_success("");
}

static int
gtp_play(char *s)
{
  int i, j;
  int color = EMPTY;

  if (!gtp_decode_move(s, &color, &i, &j))
    return gtp_failure("invalid color or coordinate");

  if (!legal_move(i, j, color))
    return gtp_failure("illegal move");

  play_move(i, j, color);
  return gtp_success("");
}

static int
gtp_genmove(char *s)
{
  int i, j;
  int color = EMPTY;

  if (!gtp_decode_color(s, &color))
    return gtp_failure("invalid color");

  generate_move(&i, &j, color);
  play_move(i, j, color);

  gtp_start_response(GTP_SUCCESS);
  gtp_mprintf("%m", i, j);
  return gtp_finish_response();
}

/* Compute final score. We use area scoring since that is the only
 * option that makes sense for this move generation algorithm.
 */
static int
gtp_final_score(char *s)
{
  float score = komi;
  int i, j;

  compute_final_status();
  for (i = 0; i < board_size; i++)
    for (j = 0; j < board_size; j++) {
      int status = get_final_status(i, j);
      if (status == BLACK_TERRITORY)
	score--;
      else if (status == WHITE_TERRITORY)
	score++;
      else if ((status == ALIVE) ^ (get_board(i, j) == WHITE))
	score--;
      else
	score++;
    }

  if (score > 0.0)
    return gtp_success("W+%3.1f", score);
  if (score < 0.0)
    return gtp_success("B+%3.1f", -score);
  return gtp_success("0");
}

static int
gtp_final_status_list(char *s)
{
  int n;
  int i, j;
  int status = UNKNOWN;
  char status_string[GTP_BUFSIZE];
  int first_string;

  if (sscanf(s, "%s %n", status_string, &n) != 1)
    return gtp_failure("missing status");

  if (!strcmp(status_string, "alive"))
    status = ALIVE;
  else if (!strcmp(status_string, "dead"))
    status = DEAD;
  else if (!strcmp(status_string, "seki"))
    status = SEKI;
  else
    return gtp_failure("invalid status");

  compute_final_status();

  gtp_start_response(GTP_SUCCESS);

  first_string = 1;
  for (i = 0; i < board_size; i++)
    for (j = 0; j < board_size; j++)
      if (get_final_status(i, j) == status) {
	int k;
	int stonei[MAX_BOARD * MAX_BOARD];
	int stonej[MAX_BOARD * MAX_BOARD];
	int num_stones = get_string(i, j, stonei, stonej);
	/* Clear the status so we don't find the string again. */
	for (k = 0; k < num_stones; k++)
	  set_final_status(stonei[k], stonej[k], UNKNOWN);

	if (first_string)
	  first_string = 0;
	else
	  gtp_printf("\n");

	gtp_print_vertices(num_stones, stonei, stonej);
      }

  return gtp_finish_response();
}

/* Write a row of letters, skipping 'I'. */
static void
letters(void)
{
  int i;

  printf("  ");
  for (i = 0; i < board_size; i++)
    printf(" %c", 'A' + i + (i >= 8));
}

static int
gtp_showboard(char *s)
{
  int i, j;
  int symbols[3] = {'.', 'O', 'X'};

  gtp_start_response(GTP_SUCCESS);
  gtp_printf("\n");

  letters();

  for (i = 0; i < board_size; i++) {
    printf("\n%2d", board_size - i);

    for (j = 0; j < board_size; j++)
      printf(" %c", symbols[get_board(i, j)]);

    printf(" %d", board_size - i);
  }

  printf("\n");
  letters();
  return gtp_finish_response();
}
