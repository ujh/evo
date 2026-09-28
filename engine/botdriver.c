/*
 * Drives external GTP programs through the bot controller (bot.c), for its
 * tests (bottest.sh, with fakebot), the real-bot smoke check
 * (scripts/smoke-bot-controller.sh), and the response-time measurement
 * (scripts/bot-response-times.sh). Built by plain make, since the smoke
 * check runs where only make has run.
 *
 *   botdriver script
 *   botdriver game SIZE KOMI MAX_MOVES MAIN_TIME DEADLINE BLACK WHITE
 *
 * script reads commands from stdin, one per line, its fields separated
 * by single spaces (the last field takes the rest of the line), and
 * writes one result line per command, flushed at once:
 *   VERB <tab> STATUS <tab> SECONDS <tab> TEXT
 * STATUS is ok, error, timeout, died, or protocol (bot_status), or what
 * the verb says; SECONDS is the call's duration; newlines in TEXT are
 * written as "\n". Bots are named by a slot, a word.
 *   start SLOT COMMAND            bot_start with stderr on the driver's;
 *                                 ok with "pid=N", or launch and why
 *   send SLOT SECONDS COMMAND     bot_command
 *   known SLOT SECONDS NAME       bot_known_command; TEXT is 1 or 0
 *   setup SLOT SECONDS SIZE KOMI MAIN_TIME
 *                                 bot_setup
 *   genmove SLOT SECONDS COLOR SIZE
 *                                 genmove COLOR, then bot_parse_move: TEXT
 *                                 is "point COLUMN ROW", pass, resign, or
 *                                 "invalid REPLY"
 *   quit SLOT SECONDS             bot_quit: answered or unanswered
 *   kill SLOT                     bot_kill
 *   split COMMAND                 bot_split_arguments: STATUS is the count,
 *                                 TEXT each argument in brackets
 *   pid FILE                      writes the driver's process ID to FILE
 *   wait SECONDS                  sleeps
 *   exit N                        exits with status N, bots still running
 *   crash                         dies by SIGSEGV, bots still running
 * A bad line exits 1.
 *
 * game plays one game between the bots BLACK and WHITE (command lines)
 * without a board of its own: bot_setup on each, then genmove to the side
 * to move and play of its answer to the other, until two passes in a row,
 * a resignation, or MAX_MOVES + 1 moves, then bot_quit on each. Each
 * genmove waits for the side's remaining MAIN_TIME plus DEADLINE; every
 * other command waits DEADLINE. One line per call:
 *   COLOR <tab> KIND <tab> STATUS <tab> SECONDS <tab> TEXT
 * KIND is start, setup (all setup commands together), genmove, play, or
 * quit; then "end <tab> passes|limit|resign <tab> LENGTH <tab> MOVES" and
 * exit 0, or, when a call fails, "fail <tab> COLOR <tab> TEXT" and exit 1.
 */

#define _POSIX_C_SOURCE 200809L

#include <ctype.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "bot.h"

static const char *status_name(bot_status s) {
  switch (s) {
  case BOT_OK: return "ok";
  case BOT_ERROR: return "error";
  case BOT_TIMEOUT: return "timeout";
  case BOT_DIED: return "died";
  case BOT_PROTOCOL: return "protocol";
  }
  return "?";
}

// TEXT with newlines as "\n" and tabs as "\t".
static void print_text(const char *text) {
  for (const char *p = text; *p; p++) {
    if (*p == '\n')
      fputs("\\n", stdout);
    else if (*p == '\t')
      fputs("\\t", stdout);
    else
      putchar(*p);
  }
}

static void result(const char *verb, const char *status, double seconds, const char *text) {
  printf("%s\t%s\t%.6f\t", verb, status, seconds);
  print_text(text);
  putchar('\n');
  fflush(stdout);
}

__attribute__((noreturn)) static void bad(const char *line) {
  fprintf(stderr, "botdriver: bad line: %s\n", line);
  exit(1);
}

typedef struct {
  char name[32];
  bot *b;
} slot;

static slot slots[16];

static bot *find(const char *name, const char *line) {
  for (int k = 0; k < 16; k++)
    if (slots[k].b && strcmp(slots[k].name, name) == 0) return slots[k].b;
  bad(line);
}

static void forget(const char *name) {
  for (int k = 0; k < 16; k++)
    if (slots[k].b && strcmp(slots[k].name, name) == 0) slots[k].b = NULL;
}

// Splits off the next space-separated field of *rest; the last one takes
// the rest.
static char *field(char **rest, int last, const char *line) {
  char *f = *rest;
  if (f == NULL || *f == '\0') bad(line);
  if (last) {
    *rest = NULL;
    return f;
  }
  char *space = strchr(f, ' ');
  if (space) {
    *space = '\0';
    *rest = space + 1;
  } else {
    *rest = NULL;
  }
  return f;
}

static void sleep_seconds(double s) {
  double end = bot_now() + s;
  for (double left; (left = end - bot_now()) > 0;) poll(NULL, 0, (int)(left * 1000) + 1);
}

static int script(void) {
  char *line = NULL, *copy = NULL;
  size_t capacity = 0;
  ssize_t length;
  while ((length = getline(&line, &capacity, stdin)) != -1) {
    if (length > 0 && line[length - 1] == '\n') line[--length] = '\0';
    free(copy);
    copy = strdup(line);
    char *rest = line;
    char *verb = field(&rest, 0, copy);
    const char *text;
    double start = bot_now();
    if (strcmp(verb, "start") == 0) {
      char *name = field(&rest, 0, copy);
      char *command = field(&rest, 1, copy);
      int k = 0;
      while (k < 16 && slots[k].b) k++;
      if (k == 16 || strlen(name) >= sizeof(slots[k].name)) bad(copy);
      bot *b = bot_start(command, STDERR_FILENO, &text);
      if (b == NULL) {
        result(verb, "launch", bot_now() - start, text);
      } else {
        snprintf(slots[k].name, sizeof(slots[k].name), "%s", name);
        slots[k].b = b;
        char pid[32];
        snprintf(pid, sizeof(pid), "pid=%d", bot_pid(b));
        result(verb, "ok", bot_now() - start, pid);
      }
    } else if (strcmp(verb, "send") == 0) {
      bot *b = find(field(&rest, 0, copy), copy);
      double seconds = atof(field(&rest, 0, copy));
      bot_status s = bot_command(b, field(&rest, 1, copy), seconds, &text);
      result(verb, status_name(s), bot_now() - start, text);
    } else if (strcmp(verb, "known") == 0) {
      bot *b = find(field(&rest, 0, copy), copy);
      double seconds = atof(field(&rest, 0, copy));
      int known;
      bot_status s = bot_known_command(b, field(&rest, 1, copy), seconds, &known, &text);
      result(verb, status_name(s), bot_now() - start, s == BOT_OK ? (known ? "1" : "0") : text);
    } else if (strcmp(verb, "setup") == 0) {
      bot *b = find(field(&rest, 0, copy), copy);
      double seconds = atof(field(&rest, 0, copy));
      int size = atoi(field(&rest, 0, copy));
      double komi = atof(field(&rest, 0, copy));
      double main_time = atof(field(&rest, 1, copy));
      bot_status s = bot_setup(b, size, komi, main_time, seconds, &text);
      result(verb, status_name(s), bot_now() - start, text);
    } else if (strcmp(verb, "genmove") == 0) {
      bot *b = find(field(&rest, 0, copy), copy);
      double seconds = atof(field(&rest, 0, copy));
      char *color = field(&rest, 0, copy);
      int size = atoi(field(&rest, 1, copy));
      char command[64];
      snprintf(command, sizeof(command), "genmove %s", color);
      bot_status s = bot_command(b, command, seconds, &text);
      char move[BOT_MAX_RESPONSE + 64];
      if (s == BOT_OK) {
        int column, row;
        switch (bot_parse_move(text, size, &column, &row)) {
        case BOT_MOVE_POINT: snprintf(move, sizeof(move), "point %d %d", column, row); break;
        case BOT_MOVE_PASS: snprintf(move, sizeof(move), "pass"); break;
        case BOT_MOVE_RESIGN: snprintf(move, sizeof(move), "resign"); break;
        case BOT_MOVE_INVALID: snprintf(move, sizeof(move), "invalid %s", text); break;
        }
        text = move;
      }
      result(verb, status_name(s), bot_now() - start, text);
    } else if (strcmp(verb, "quit") == 0) {
      char *name = field(&rest, 0, copy);
      bot *b = find(name, copy);
      int answered = bot_quit(b, atof(field(&rest, 1, copy)));
      forget(name);
      result(verb, answered ? "answered" : "unanswered", bot_now() - start, "");
    } else if (strcmp(verb, "kill") == 0) {
      char *name = field(&rest, 1, copy);
      bot_kill(find(name, copy));
      forget(name);
      result(verb, "ok", bot_now() - start, "");
    } else if (strcmp(verb, "split") == 0) {
      char *command = rest ? rest : "";
      char **argv;
      int argc = bot_split_arguments(command, &argv);
      size_t size = strlen(command) + 3 * (size_t)argc + 1;
      char *out = malloc(size), *p = out;
      *p = '\0';
      for (int k = 0; k < argc; k++) p += sprintf(p, "[%s]", argv[k]);
      char count[16];
      snprintf(count, sizeof(count), "%d", argc);
      result(verb, count, 0, out);
      free(out);
      bot_free_arguments(argv);
    } else if (strcmp(verb, "pid") == 0) {
      FILE *f = fopen(field(&rest, 1, copy), "w");
      if (f == NULL) bad(copy);
      fprintf(f, "%ld\n", (long)getpid());
      fclose(f);
      result(verb, "ok", 0, "");
    } else if (strcmp(verb, "wait") == 0) {
      sleep_seconds(atof(field(&rest, 1, copy)));
      result(verb, "ok", bot_now() - start, "");
    } else if (strcmp(verb, "exit") == 0) {
      exit(atoi(field(&rest, 1, copy)));
    } else if (strcmp(verb, "crash") == 0) {
      raise(SIGSEGV);
    } else {
      bad(copy);
    }
  }
  return 0;
}

static const char *color_name[2] = {"black", "white"};

__attribute__((noreturn)) static void game_failed(int side, const char *what, const char *text) {
  printf("fail\t%s\t%s: ", color_name[side], what);
  print_text(text);
  putchar('\n');
  fflush(stdout);
  exit(1);
}

static void game_line(int side, const char *kind, bot_status s, double seconds, const char *text) {
  printf("%s\t%s\t%s\t%.6f\t", color_name[side], kind, status_name(s), seconds);
  print_text(text);
  putchar('\n');
  fflush(stdout);
  if (s != BOT_OK) game_failed(side, kind, text);
}

static int game(char **argv) {
  int size = atoi(argv[0]);
  double komi = atof(argv[1]);
  long max_moves = atol(argv[2]);
  double main_time = atof(argv[3]);
  double deadline = atof(argv[4]);
  bot *bots[2];
  const char *text;
  for (int side = 0; side < 2; side++) {
    double start = bot_now();
    bots[side] = bot_start(argv[5 + side], STDERR_FILENO, &text);
    if (bots[side] == NULL) game_failed(side, "start", text);
    game_line(side, "start", BOT_OK, bot_now() - start, "");
  }
  for (int side = 0; side < 2; side++) {
    double start = bot_now();
    bot_status s = bot_setup(bots[side], size, komi, main_time, deadline, &text);
    game_line(side, "setup", s, bot_now() - start, text);
  }

  double spent[2] = {0, 0};
  char *moves = malloc(8 * (size_t)(max_moves + 2) + 1);
  moves[0] = '\0';
  long length = 0;
  int passes = 0, side = 0;
  const char *end = NULL;
  while (passes < 2 && length <= max_moves) {
    char command[64];
    snprintf(command, sizeof(command), "genmove %s", side == 0 ? "b" : "w");
    double start = bot_now();
    double left = main_time - spent[side];
    bot_status s = bot_command(bots[side], command, (left > 0 ? left : 0) + deadline, &text);
    double took = bot_now() - start;
    spent[side] += took;
    game_line(side, "genmove", s, took, text);
    int column, row;
    char vertex[16];
    bot_move m = bot_parse_move(text, size, &column, &row);
    if (m == BOT_MOVE_INVALID) game_failed(side, "genmove", text);
    if (m == BOT_MOVE_RESIGN) {
      end = "resign";
      break;
    }
    if (m == BOT_MOVE_PASS)
      snprintf(vertex, sizeof(vertex), "pass");
    else
      snprintf(vertex, sizeof(vertex), "%c%d", 'A' + column + (column >= 8), row + 1);
    passes = m == BOT_MOVE_PASS ? passes + 1 : 0;
    sprintf(moves + strlen(moves), "%s%s", length ? "," : "", vertex);
    length++;
    snprintf(command, sizeof(command), "play %s %s", side == 0 ? "b" : "w", vertex);
    start = bot_now();
    s = bot_command(bots[1 - side], command, deadline, &text);
    game_line(1 - side, "play", s, bot_now() - start, text);
    side = 1 - side;
  }
  if (end == NULL) end = passes >= 2 ? "passes" : "limit";
  for (int k = 0; k < 2; k++) {
    double start = bot_now();
    int answered = bot_quit(bots[k], deadline);
    game_line(k, "quit", answered ? BOT_OK : BOT_TIMEOUT, bot_now() - start, "");
  }
  printf("end\t%s\t%ld\t%s\n", end, length, moves);
  free(moves);
  return 0;
}

int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "script") == 0) return script();
  if (argc == 9 && strcmp(argv[1], "game") == 0) return game(argv + 2);
  fprintf(stderr,
          "Usage: %s script\n"
          "       %s game SIZE KOMI MAX_MOVES MAIN_TIME DEADLINE BLACK WHITE\n",
          argv[0], argv[0]);
  return 1;
}
