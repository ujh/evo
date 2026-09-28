/*
 * The arena: plays games between two networks in one process and scores
 * them with the Tromp-Taylor count, without GTP, GoGui, or a referee. It
 * has two invocations with their own input and output, and a query:
 *
 *   arena SIZE KOMI MAX_MOVES SCHEDULE          (legacy, network-only)
 *   arena --mixed SIZE KOMI MAX_MOVES MAIN_TIME RESPONSE_DEADLINE GRACE MANIFEST
 *   arena --protocol
 *
 * --protocol prints the protocol version of the --mixed invocation, "3",
 * on a line of its own and exits 0. A later arena that changes the
 * --mixed input or output prints a higher number.
 *
 * The games follow Brown's rules (simple ko, no superko) and the move
 * filter, exactly as evo plays them through GTP, with Brown's global komi
 * set to KOMI as twogtp's "komi" command sets it. A game ends as twogtp
 * ends one: after two passes in a row, or after MAX_MOVES + 1 moves
 * (twogtp refuses a genmove only once more than MAX_MOVES moves were
 * played). Passes count as moves. SIZE is 2-23, KOMI a finite number,
 * MAX_MOVES a whole number from 0 to 1000000000.
 *
 * Legacy invocation
 * -----------------
 *
 * SCHEDULE has one game per line, "ID BLACK.ann WHITE.ann", the fields
 * separated by spaces or tabs, so no field holds whitespace. IDs must be
 * distinct. The whole schedule is read and checked before the first game.
 * There is no time limit.
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
 *
 * The --mixed invocation
 * ----------------------
 *
 * Plays games between networks and external GTP programs ("bots"), with a
 * clock. MAIN_TIME is each side's absolute main time per game, in seconds
 * (no byo-yomi, no overtime); RESPONSE_DEADLINE bounds a bot's answer to
 * any command but genmove (setup, play, quit), in seconds, and is not
 * charged to its clock; GRACE is how long past its remaining main time a
 * bot's genmove answer is waited for, in seconds. Each is a decimal
 * number of seconds, digits with an optional fraction ("600", "0.05"),
 * at most 1000000; MAIN_TIME and RESPONSE_DEADLINE are above 0, GRACE
 * may be 0.
 *
 * MANIFEST is a text file of lines, each a kind and its fields separated
 * by single tabs, with no empty field and no control character (bytes
 * below 0x20 other than the separating tab, 0x7f, NUL), so a field may
 * hold spaces but never a tab. A blank line is an error; the last line
 * may lack its newline. First the players, then the games:
 *
 *   network PLAYER PATH      a network, read from the .ann file at PATH
 *   bot PLAYER               an external GTP program
 *   game GAME BLACK WHITE    a game between two declared players
 *   command GAME COLOR COMMAND
 *                            the command line that starts the bot playing
 *                            COLOR (black or white) in the declared GAME
 *
 * PLAYER and GAME IDs are printable ASCII without spaces (bytes 0x21-0x7e);
 * player IDs are distinct among all players, game IDs among all games.
 * No player line may follow a game line. A player may play both colors
 * of a game, and need not play at all. Every bot side of every game has
 * exactly one command line, and a network side none; a command line
 * comes after its game line. COMMAND is the whole command, program and
 * arguments, in the stored opponent format (for example
 * "gnugo --level 0 --mode gtp --seed 12345"); it is per game so that a
 * seed can differ from game to game, and it holds a non-space character.
 * The arena never splits a manifest field at whitespace except COMMAND,
 * which it splits into an argv as twogtp's StringUtil.splitArguments
 * does and starts with execvp, not through a shell. The whole manifest
 * is read and checked before anything is written to stdout.
 *
 * Stdout starts with the header "arena protocol 3 ready", written once
 * the arguments and the manifest are checked and before any network is
 * loaded or game played. Then one tab-separated record per game, in
 * manifest order, each flushed at once and ending in the field "ok":
 *
 * a played game:
 *   GAME result=R end=passes|limit|resign|time length=N time_black=S
 *     time_white=S duration=S moves=M ok
 *   R is the Tromp-Taylor score for passes and limit ("B+3.5", "W+0.5",
 *   "0"), B+R or W+R when the other side's bot resigned, B+T or W+T when
 *   the other side's network ran out of main time (checked after each of
 *   its moves; the overrunning move is in the moves).
 * a game in which one network cannot be played (missing, unreadable, does
 * not fit the board), which that network loses without a move:
 *   GAME end=network_error error=black|white message=TEXT ok
 * a failed game, which stops the arena:
 *   GAME end=network_error error=both message=TEXT ok
 *   GAME end=timeout|illegal|crash|launch error=black|white length=N
 *     time_black=S time_white=S duration=S moves=M message=TEXT ok
 *   error names the failing bot's color. timeout: the bot missed a
 *   deadline from its first play or genmove on, or its genmove answer
 *   took it past main time; illegal: its genmove answer is not a legal
 *   move on the arena's board; crash: it died, or answered with a GTP
 *   error, from its first play or genmove on; launch: it could not be
 *   started, or failed or missed its deadline on a setup command
 *   (known_command, boardsize, clear_board, komi, time_settings). The
 *   moves and times are those completed before the failure; the failing
 *   side's time includes the wait that failed.
 *
 * M is the moves, comma-separated, in GTP vertices: "pass" in lowercase,
 * coordinates in uppercase ("C3"; columns skip I, row 1 at the bottom),
 * empty for a game without moves. N is their number. S is seconds with
 * six decimals: time_black and time_white sum each side's genmove times
 * (the time charged against main time), duration is the whole game.
 * TEXT is a non-empty message on one line, without tabs. After the last
 * record, when every game has one, the trailer "done N" counts them.
 *
 * Exit status: 0 after the trailer; 2 right after a failure record, with
 * no later game played and no trailer; 1, with a message on stderr, for
 * bad arguments, a manifest that cannot be read or is malformed (before
 * the header), or an error such as a failed write. The arena's own
 * failures never exit 130 or 143, which the runner reads as an interrupt.
 *
 * Not yet: this arena refuses (exit 1, before the header) a manifest
 * whose games include a bot, so it writes none of resign, time, timeout,
 * illegal, crash, launch. The times use CLOCK_MONOTONIC and there is no
 * main-time check yet.
 */

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "ann.h"
#include "brown.h"
#include "generate_move.h"
#include "score.h"

#define PROTOCOL 3

// The largest MAIN_TIME, RESPONSE_DEADLINE, and GRACE, in seconds.
#define MAX_SECONDS 1000000.0

enum { SIDE_BLACK, SIDE_WHITE };

typedef struct {
  char *id;
  char *black;     // the network paths; NULL for a bot (--mixed only)
  char *white;
  char *player[2]; // the player IDs (--mixed only)
  char *command[2]; // each bot side's command; NULL for a network
} game;

// The --mixed invocation's time arguments, in seconds. Not used yet: bots
// are refused, and the main-time check comes with the clock.
static double main_time, response_deadline, genmove_grace;

// A network file, loaded once however many games it plays.
typedef struct {
  char *path;
  genann *ann;     // NULL when it cannot be played
  ann_features features; // its feature groups and weights
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
  genann *ann = ann_binary_read(in, NULL, &n->features);
  fclose(in);
  if (ann == NULL) {
    n->problem = problem(path, "holds no network", 0);
  } else if (!ann_fits_board(ann, &n->features, board_size)) {
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
    games[*count].player[SIDE_BLACK] = games[*count].player[SIDE_WHITE] = NULL;
    games[*count].command[SIDE_BLACK] = games[*count].command[SIDE_WHITE] = NULL;
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

// Parses a decimal number of seconds, digits with an optional fraction
// ("600", "0.05"), as the whole string, in [0, MAX_SECONDS]; above 0
// unless zero_allowed.
static int parse_seconds(const char *s, int zero_allowed, double *value) {
  const char *p = s;
  while (*p >= '0' && *p <= '9') p++;
  if (p == s) return 0;
  if (*p == '.') {
    const char *fraction = ++p;
    while (*p >= '0' && *p <= '9') p++;
    if (p == fraction) return 0;
  }
  if (*p != '\0') return 0;
  double v = strtod(s, NULL);
  if (!isfinite(v) || v > MAX_SECONDS || (v == 0 && !zero_allowed)) return 0;
  *value = v;
  return 1;
}

// A manifest player: a network with its path, or a bot.
typedef struct {
  char *id;
  char *path; // NULL for a bot
} player;

static const char *manifest_path;
static int manifest_line;

// Stops the arena for a bad manifest line: message on stderr, exit 1.
__attribute__((noreturn, format(printf, 1, 2))) static void manifest_error(const char *format, ...) {
  va_list args;
  va_start(args, format);
  fprintf(stderr, "arena: %s line %d: ", manifest_path, manifest_line);
  vfprintf(stderr, format, args);
  fprintf(stderr, "\n");
  va_end(args);
  exit(1);
}

// Player and game IDs: printable ASCII without spaces.
static int valid_id(const char *s) {
  for (const unsigned char *p = (const unsigned char *)s; *p; p++)
    if (*p < 0x21 || *p > 0x7e) return 0;
  return *s != '\0';
}

static player *find_player(player *players, int count, const char *id) {
  for (int k = 0; k < count; k++)
    if (strcmp(players[k].id, id) == 0) return &players[k];
  return NULL;
}

static game *find_game(game *games, int count, const char *id) {
  for (int k = 0; k < count; k++)
    if (strcmp(games[k].id, id) == 0) return &games[k];
  return NULL;
}

// Reads and checks the --mixed manifest (see the top of the file); exits 1
// with a message if it cannot be read or is malformed.
static game *read_manifest(const char *path, int *count) {
  FILE *in = fopen(path, "r");
  if (in == NULL) {
    fprintf(stderr, "arena: cannot read manifest %s: %s\n", path, strerror(errno));
    exit(1);
  }
  manifest_path = path;
  manifest_line = 0;
  player *players = NULL;
  int player_count = 0;
  game *games = NULL;
  *count = 0;
  char *line = NULL;
  size_t capacity = 0;
  ssize_t length;
  while ((length = getline(&line, &capacity, in)) != -1) {
    manifest_line++;
    if (length > 0 && line[length - 1] == '\n') line[--length] = '\0';
    if ((ssize_t)strlen(line) != length) manifest_error("holds a NUL byte");
    for (const unsigned char *p = (const unsigned char *)line; *p; p++)
      if ((*p < 0x20 && *p != '\t') || *p == 0x7f) manifest_error("holds a control character");
    char *fields[5];
    int n = 0;
    for (char *f = line;; n++) {
      char *tab = strchr(f, '\t');
      if (n < 5) fields[n] = f;
      if (tab == NULL) break;
      *tab = '\0';
      f = tab + 1;
    }
    n++;
    for (int k = 0; k < n && k < 5; k++)
      if (*fields[k] == '\0') manifest_error("has an empty field (fields are separated by single tabs)");
    const char *kind = fields[0];

    if (strcmp(kind, "network") == 0 || strcmp(kind, "bot") == 0) {
      int bot = kind[0] == 'b';
      if (n != (bot ? 2 : 3)) manifest_error(bot ? "expected bot PLAYER" : "expected network PLAYER PATH");
      if (*count > 0) manifest_error("player %s follows a game; players come first", fields[1]);
      if (!valid_id(fields[1])) manifest_error("player ID %s is not printable ASCII without spaces", fields[1]);
      if (find_player(players, player_count, fields[1]))
        manifest_error("player ID %s appears twice", fields[1]);
      players = checked_realloc(players, (player_count + 1) * sizeof(player));
      players[player_count].id = checked_strdup(fields[1]);
      players[player_count].path = bot ? NULL : checked_strdup(fields[2]);
      player_count++;
    } else if (strcmp(kind, "game") == 0) {
      if (n != 4) manifest_error("expected game GAME BLACK WHITE");
      if (!valid_id(fields[1])) manifest_error("game ID %s is not printable ASCII without spaces", fields[1]);
      if (find_game(games, *count, fields[1])) manifest_error("game ID %s appears twice", fields[1]);
      player *sides[2];
      for (int side = SIDE_BLACK; side <= SIDE_WHITE; side++) {
        sides[side] = find_player(players, player_count, fields[2 + side]);
        if (sides[side] == NULL) manifest_error("player %s is not declared", fields[2 + side]);
      }
      games = checked_realloc(games, (*count + 1) * sizeof(game));
      game *g = &games[(*count)++];
      g->id = checked_strdup(fields[1]);
      g->black = sides[SIDE_BLACK]->path;
      g->white = sides[SIDE_WHITE]->path;
      for (int side = SIDE_BLACK; side <= SIDE_WHITE; side++) {
        g->player[side] = sides[side]->id;
        g->command[side] = NULL;
      }
    } else if (strcmp(kind, "command") == 0) {
      if (n != 4) manifest_error("expected command GAME COLOR COMMAND");
      game *g = find_game(games, *count, fields[1]);
      if (g == NULL) manifest_error("game %s is not declared before its command", fields[1]);
      int side;
      if (strcmp(fields[2], "black") == 0)
        side = SIDE_BLACK;
      else if (strcmp(fields[2], "white") == 0)
        side = SIDE_WHITE;
      else
        manifest_error("color %s is not black or white", fields[2]);
      if ((side == SIDE_BLACK ? g->black : g->white) != NULL)
        manifest_error("game %s: %s is the network %s, which takes no command", g->id, fields[2], g->player[side]);
      if (g->command[side] != NULL) manifest_error("game %s: a second command for %s", g->id, fields[2]);
      if (strspn(fields[3], " ") == strlen(fields[3])) manifest_error("the command is blank");
      g->command[side] = checked_strdup(fields[3]);
    } else {
      manifest_error("unknown kind %s: expected network, bot, game, or command", kind);
    }
  }
  if (ferror(in)) {
    fprintf(stderr, "arena: cannot read manifest %s\n", path);
    exit(1);
  }
  free(line);
  fclose(in);

  for (int k = 0; k < *count; k++)
    for (int side = SIDE_BLACK; side <= SIDE_WHITE; side++)
      if ((side == SIDE_BLACK ? games[k].black : games[k].white) == NULL && games[k].command[side] == NULL) {
        fprintf(stderr, "arena: %s: game %s: no command for its %s player %s\n", path, games[k].id,
                side == SIDE_BLACK ? "black" : "white", games[k].player[side]);
        exit(1);
      }
  for (int k = 0; k < *count; k++)
    if (games[k].black == NULL || games[k].white == NULL) {
      fprintf(stderr, "arena: %s: game %s: bot players are not supported yet\n", path, games[k].id);
      exit(1);
    }
  // The players' IDs and paths live on in the games.
  free(players);
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

static void play_game(const game *g, network const *black, network const *white, long max_moves) {
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
    network const *mover = color == BLACK ? black : white;
    double before = now();
    generate_move(mover->ann, &mover->features, &i, &j, color);
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

static void flush_results(void) {
  if (fflush(stdout) != 0) {
    fprintf(stderr, "arena: cannot write the results: %s\n", strerror(errno));
    exit(1);
  }
}

static void usage(const char *program) {
  fprintf(stderr,
          "Usage: %s SIZE KOMI MAX_MOVES SCHEDULE\n"
          "       %s --mixed SIZE KOMI MAX_MOVES MAIN_TIME RESPONSE_DEADLINE GRACE MANIFEST\n"
          "       %s --protocol\n",
          program, program, program);
  exit(1);
}

// Sets the board size and komi, and max_moves, from SIZE KOMI MAX_MOVES;
// exits 1 with a message if one is bad.
static void parse_game_arguments(char **args, long *max_moves) {
  long size;
  if (!parse_int(args[0], MIN_BOARD, MAX_BOARD, &size)) {
    fprintf(stderr, "arena: SIZE must be a whole number from %d to %d, not %s\n", MIN_BOARD, MAX_BOARD, args[0]);
    exit(1);
  }
  if (!parse_komi(args[1], &komi)) {
    fprintf(stderr, "arena: KOMI must be a finite number, not %s\n", args[1]);
    exit(1);
  }
  // max_moves + 1 moves must fit a long.
  if (!parse_int(args[2], 0, 1000000000L, max_moves)) {
    fprintf(stderr, "arena: MAX_MOVES must be a whole number from 0 to 1000000000, not %s\n", args[2]);
    exit(1);
  }
  board_size = (int)size;
}

// arena SIZE KOMI MAX_MOVES SCHEDULE
static int legacy_main(char **argv) {
  long max_moves;
  parse_game_arguments(argv + 1, &max_moves);

  int count;
  game *games = read_schedule(argv[4], &count);

  for (int k = 0; k < count; k++) {
    network *black = load(games[k].black);
    network *white = load(games[k].white);
    if (black->ann && white->ann) {
      play_game(&games[k], black, white, max_moves);
    } else if (black->ann == NULL && white->ann == NULL) {
      printf("%s\terror=both\tmessage=%s; %s\tok\n", games[k].id, black->problem, white->problem);
    } else {
      network *bad = black->ann ? white : black;
      printf("%s\terror=%s\tmessage=%s\tok\n", games[k].id, black->ann ? "white" : "black", bad->problem);
    }
    flush_results();
  }
  printf("done %d\n", count);
  flush_results();
  return 0;
}

// arena --mixed SIZE KOMI MAX_MOVES MAIN_TIME RESPONSE_DEADLINE GRACE MANIFEST
static int mixed_main(char **argv) {
  long max_moves;
  parse_game_arguments(argv + 2, &max_moves);
  if (!parse_seconds(argv[5], 0, &main_time)) {
    fprintf(stderr, "arena: MAIN_TIME must be decimal seconds above 0 and at most %.0f, not %s\n", MAX_SECONDS,
            argv[5]);
    exit(1);
  }
  if (!parse_seconds(argv[6], 0, &response_deadline)) {
    fprintf(stderr, "arena: RESPONSE_DEADLINE must be decimal seconds above 0 and at most %.0f, not %s\n",
            MAX_SECONDS, argv[6]);
    exit(1);
  }
  if (!parse_seconds(argv[7], 1, &genmove_grace)) {
    fprintf(stderr, "arena: GRACE must be decimal seconds from 0 to %.0f, not %s\n", MAX_SECONDS, argv[7]);
    exit(1);
  }

  int count;
  game *games = read_manifest(argv[8], &count);
  printf("arena protocol %d ready\n", PROTOCOL);
  flush_results();

  for (int k = 0; k < count; k++) {
    network *black = load(games[k].black);
    network *white = load(games[k].white);
    if (black->ann && white->ann) {
      play_game(&games[k], black, white, max_moves);
    } else if (black->ann == NULL && white->ann == NULL) {
      // Neither side can play: a failed game, which stops the arena.
      printf("%s\tend=network_error\terror=both\tmessage=%s; %s\tok\n", games[k].id, black->problem, white->problem);
      flush_results();
      return 2;
    } else {
      network *bad = black->ann ? white : black;
      printf("%s\tend=network_error\terror=%s\tmessage=%s\tok\n", games[k].id, black->ann ? "white" : "black",
             bad->problem);
    }
    flush_results();
  }
  printf("done %d\n", count);
  flush_results();
  return 0;
}

int main(int argc, char **argv) {
  if (argc >= 2 && strcmp(argv[1], "--protocol") == 0) {
    if (argc != 2) usage(argv[0]);
    printf("%d\n", PROTOCOL);
    flush_results();
    return 0;
  }
  if (argc >= 2 && strcmp(argv[1], "--mixed") == 0) {
    if (argc != 9) usage(argv[0]);
    return mixed_main(argv);
  }
  if (argc != 5) usage(argv[0]);
  return legacy_main(argv);
}
