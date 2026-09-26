/*
 * The arena: plays games between two networks in one process and scores
 * them with the Tromp-Taylor count, without GTP, GoGui, or a referee.
 *
 *   arena SIZE KOMI MAX_MOVES SCHEDULE
 *
 * SCHEDULE has one game per line, "ID BLACK.ann WHITE.ann", the fields
 * separated by spaces or tabs, so no field holds whitespace. IDs must be
 * distinct. The whole schedule is read and checked before the first game.
 *
 * The games follow Brown's rules (simple ko, no superko) and the move
 * filter, exactly as evo plays them through GTP, with Brown's global komi
 * set to KOMI as twogtp's "komi" command sets it. A game ends as twogtp
 * ends one: after two passes in a row, or after MAX_MOVES + 1 moves
 * (twogtp refuses a genmove only once more than MAX_MOVES moves were
 * played). Passes count as moves. There is no time limit.
 *
 * Stdout gets one tab-separated line per game, in schedule order, flushed
 * at once:
 *   ID result=B+3.5 end=passes|limit length=N time_black=S time_white=S
 *     duration=S moves=C3,D4,pass,... ok
 * or, when a network cannot be played (missing, unreadable, does not fit
 * the board), without playing:
 *   ID error=black|white|both message=... ok
 * then "done N" after the last game. Times are monotonic-clock seconds
 * with six decimals: time_black and time_white sum each side's move
 * choices, duration is the whole game. Bad arguments or an unreadable or
 * malformed schedule print a message on stderr and exit 1 before any game.
 */

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "ann.h"
#include "brown.h"
#include "generate_move.h"
#include "score.h"

typedef struct {
  char *id;
  char *black;
  char *white;
} game;

// A network file, loaded once however many games it plays.
typedef struct {
  char *path;
  genann *ann;     // NULL when it cannot be played
  char *problem;   // why, when ann is NULL
} network;

// Each network is allocated on its own, so a pointer to one stays valid
// while the list grows.
static network **networks;
static int network_count;

static void *checked_realloc(void *p, size_t size) {
  void *q = realloc(p, size);
  if (q == NULL) {
    fprintf(stderr, "arena: out of memory\n");
    exit(1);
  }
  return q;
}

static char *checked_strdup(const char *s) {
  char *copy = checked_realloc(NULL, strlen(s) + 1);
  strcpy(copy, s);
  return copy;
}

// Why the network at `path` cannot be played: `reason` follows the path,
// or precedes it when `before` is set.
static char *problem(const char *path, const char *reason, int before) {
  size_t size = strlen(path) + strlen(reason) + 2;
  char *text = checked_realloc(NULL, size);
  snprintf(text, size, "%s %s", before ? reason : path, before ? path : reason);
  return text;
}

// Parses a whole decimal integer in [min, max].
static int parse_int(const char *s, long min, long max, long *value) {
  char *end;
  errno = 0;
  long v = strtol(s, &end, 10);
  if (*s == '\0' || *end != '\0' || errno != 0 || v < min || v > max) return 0;
  *value = v;
  return 1;
}

// Parses a finite number, as the whole string.
static int parse_komi(const char *s, float *value) {
  char *end;
  errno = 0;
  float v = strtof(s, &end);
  if (*s == '\0' || *end != '\0' || errno != 0 || !isfinite(v)) return 0;
  *value = v;
  return 1;
}

static network *load(const char *path) {
  for (int k = 0; k < network_count; k++)
    if (strcmp(networks[k]->path, path) == 0) return networks[k];

  networks = checked_realloc(networks, (network_count + 1) * sizeof(network *));
  network *n = checked_realloc(NULL, sizeof(network));
  networks[network_count++] = n;
  n->path = checked_strdup(path);
  n->ann = NULL;
  n->problem = NULL;

  FILE *in = fopen(path, "rb");
  if (in == NULL) {
    n->problem = problem(path, "cannot open", 1);
    return n;
  }
  genann *ann = ann_binary_read(in, NULL);
  fclose(in);
  if (ann == NULL) {
    n->problem = problem(path, "holds no network", 0);
  } else if (!ann_fits_board(ann, board_size)) {
    char reason[64];
    snprintf(reason, sizeof(reason), "does not fit a %dx%d board", board_size, board_size);
    n->problem = problem(path, reason, 0);
    genann_free(ann);
  } else {
    n->ann = ann;
  }
  return n;
}

// Reads the schedule; exits 1 with a message if it cannot.
static game *read_schedule(const char *path, int *count) {
  FILE *in = fopen(path, "r");
  if (in == NULL) {
    fprintf(stderr, "arena: cannot read schedule %s: %s\n", path, strerror(errno));
    exit(1);
  }
  game *games = NULL;
  *count = 0;
  char *line = NULL;
  size_t capacity = 0;
  ssize_t length;
  int line_number = 0;
  while ((length = getline(&line, &capacity, in)) != -1) {
    line_number++;
    if (length > 0 && line[length - 1] == '\n') line[--length] = '\0';
    char *fields[4];
    int n = 0;
    char *saved;
    for (char *f = strtok_r(line, " \t", &saved); f != NULL; f = strtok_r(NULL, " \t", &saved)) {
      if (n < 4) fields[n] = f;
      n++;
    }
    if (n != 3) {
      fprintf(stderr, "arena: %s line %d: expected ID BLACK.ann WHITE.ann\n", path, line_number);
      exit(1);
    }
    for (int k = 0; k < *count; k++)
      if (strcmp(games[k].id, fields[0]) == 0) {
        fprintf(stderr, "arena: %s line %d: game ID %s appears twice\n", path, line_number, fields[0]);
        exit(1);
      }
    games = checked_realloc(games, (*count + 1) * sizeof(game));
    games[*count].id = checked_strdup(fields[0]);
    games[*count].black = checked_strdup(fields[1]);
    games[*count].white = checked_strdup(fields[2]);
    (*count)++;
  }
  if (ferror(in)) {
    fprintf(stderr, "arena: cannot read schedule %s\n", path);
    exit(1);
  }
  free(line);
  fclose(in);
  return games;
}

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec / 1e9;
}

// Appends a move in GTP vertex notation (columns skip I, row 1 at the
// bottom), as evo answers genmove, or "pass".
static void append_move(char **moves, size_t *used, size_t *capacity, int i, int j) {
  char vertex[8];
  if (i == -1 && j == -1)
    snprintf(vertex, sizeof(vertex), "pass");
  else
    snprintf(vertex, sizeof(vertex), "%c%d", 'A' + j + (j >= 8), board_size - i);
  size_t need = *used + strlen(vertex) + 2;
  if (need > *capacity) {
    *capacity = need * 2;
    *moves = checked_realloc(*moves, *capacity);
  }
  *used += sprintf(*moves + *used, "%s%s", *used ? "," : "", vertex);
}

static void play_game(const game *g, genann const *black, genann const *white, long max_moves) {
  static char *moves = NULL;
  static size_t capacity = 0;
  size_t used = 0;
  double spent[2] = {0, 0};  // black, white
  double start = now();
  long length = 0;
  int passes = 0;
  int color = BLACK;

  if (moves == NULL) {
    capacity = 256;
    moves = checked_realloc(NULL, capacity);
  }
  moves[0] = '\0';
  new_game();
  // twogtp's loop: stop after two passes in a row, else refuse the move
  // once more than max_moves moves were played.
  while (passes < 2 && length <= max_moves) {
    int i, j;
    double before = now();
    generate_move(color == BLACK ? black : white, &i, &j, color);
    spent[color == BLACK ? 0 : 1] += now() - before;
    play_move(i, j, color);
    passes = (i == -1 && j == -1) ? passes + 1 : 0;
    append_move(&moves, &used, &capacity, i, j);
    length++;
    color = OTHER_COLOR(color);
  }

  // The largest margin is the board plus |komi|; komi is only bounded by
  // what a float holds, so leave room for any.
  char result[64];
  format_score(tromp_taylor_score(komi), result, sizeof(result));
  double duration = now() - start;
  printf("%s\tresult=%s\tend=%s\tlength=%ld\ttime_black=%.6f\ttime_white=%.6f\tduration=%.6f\tmoves=%s\tok\n",
         g->id, result, passes >= 2 ? "passes" : "limit", length, spent[0], spent[1], duration, moves);
}

int main(int argc, char **argv) {
  long size, max_moves;
  if (argc != 5) {
    fprintf(stderr, "Usage: %s SIZE KOMI MAX_MOVES SCHEDULE\n", argv[0]);
    return 1;
  }
  if (!parse_int(argv[1], MIN_BOARD, MAX_BOARD, &size)) {
    fprintf(stderr, "arena: SIZE must be a whole number from %d to %d, not %s\n", MIN_BOARD, MAX_BOARD, argv[1]);
    return 1;
  }
  if (!parse_komi(argv[2], &komi)) {
    fprintf(stderr, "arena: KOMI must be a finite number, not %s\n", argv[2]);
    return 1;
  }
  // max_moves + 1 moves must fit a long.
  if (!parse_int(argv[3], 0, 1000000000L, &max_moves)) {
    fprintf(stderr, "arena: MAX_MOVES must be a whole number from 0 to 1000000000, not %s\n", argv[3]);
    return 1;
  }
  board_size = (int)size;

  int count;
  game *games = read_schedule(argv[4], &count);

  for (int k = 0; k < count; k++) {
    network *black = load(games[k].black);
    network *white = load(games[k].white);
    if (black->ann && white->ann) {
      play_game(&games[k], black->ann, white->ann, max_moves);
    } else if (black->ann == NULL && white->ann == NULL) {
      printf("%s\terror=both\tmessage=%s; %s\tok\n", games[k].id, black->problem, white->problem);
    } else {
      network *bad = black->ann ? white : black;
      printf("%s\terror=%s\tmessage=%s\tok\n", games[k].id, black->ann ? "white" : "black", bad->problem);
    }
    if (fflush(stdout) != 0) {
      fprintf(stderr, "arena: cannot write the results: %s\n", strerror(errno));
      return 1;
    }
  }
  printf("done %d\n", count);
  if (fflush(stdout) != 0) {
    fprintf(stderr, "arena: cannot write the results: %s\n", strerror(errno));
    return 1;
  }
  return 0;
}
