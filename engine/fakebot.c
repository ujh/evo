/*
 * A scripted fake GTP program for the bot controller's tests (bottest.sh),
 * so they need no real bot:
 *
 *   fakebot [OPTION]... [RULE]...
 *
 * It reads commands from stdin, one per line, each with an optional
 * numeric ID, and answers them by the first RULE that matches, else by
 * default: "=ID fake" to name, "=ID pass" to genmove, "=ID false" to
 * known_command, "=ID" to anything else; quit answers and exits (status 0,
 * or --quit-status). At stdin EOF it exits 0 (or waits, with --stay).
 *
 * RULE is NAME=ACTION, for every NAME command, or NAME#K=ACTION, for the
 * Kth NAME command only (from 1). NAME is the command's first word.
 * ACTION is one of
 *   ok:TEXT    answer "=ID TEXT"
 *   err:TEXT   answer "?ID TEXT"
 *   raw:TEXT   write TEXT and nothing else (%i is the ID, %% a percent)
 *   hang       answer nothing, keep reading
 *   stop       answer nothing, stop reading, wait forever
 *   exit:N     exit with status N without answering
 *   crash      die by SIGSEGV without answering
 *   close      close stdout, then wait forever
 *   sleep:S    wait S seconds, then answer by default
 *   flood      write an endless line
 * with the escapes \n, \r, \t, and \\ in TEXT. ok and err end the answer
 * with the empty line; raw does not.
 *
 * Options:
 *   --log FILE       append each command line read to FILE, and "EOF" at
 *                    the end of stdin
 *   --pid FILE       write "PID PGID" to FILE at start
 *   --fds FILE       write the number of open descriptors above 2 to FILE
 *   --stderr TEXT    write TEXT and a newline to stderr at start
 *   --banner TEXT    write TEXT (escapes, no newline added) to stdout at start
 *   --ignore-signals ignore SIGINT, SIGTERM, SIGHUP
 *   --stay           at stdin EOF, wait forever instead of exiting
 *   --quit-status N  the exit status after answering quit
 *   --no-read        never read stdin, wait forever
 *   --exec PROGRAM [ARG]...
 *                    no bot: restore SIGINT's and SIGQUIT's default
 *                    actions and exec PROGRAM (for the tests' background
 *                    jobs, which a shell starts with SIGINT ignored)
 */

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef struct {
  char *name;
  int occurrence; // 0 for every one
  char *action;
} rule;

static rule rules[64];
static int rule_count;
static char *log_path;

static void forever(void) {
  for (;;) pause();
}

static void put(const char *s, size_t n) {
  while (n > 0) {
    ssize_t w = write(STDOUT_FILENO, s, n);
    if (w < 0) {
      if (errno == EINTR) continue;
      exit(3);
    }
    s += w;
    n -= (size_t)w;
  }
}

static void puts_out(const char *s) { put(s, strlen(s)); }

// Writes TEXT with its escapes, and %i as the ID when `id` is set.
static void put_text(const char *text, const char *id) {
  for (const char *p = text; *p; p++) {
    char c = *p;
    if (c == '\\' && p[1]) {
      p++;
      c = *p == 'n' ? '\n' : *p == 'r' ? '\r' : *p == 't' ? '\t' : *p;
    } else if (id && c == '%' && p[1] == 'i') {
      p++;
      puts_out(id);
      continue;
    } else if (id && c == '%' && p[1] == '%') {
      p++;
    }
    put(&c, 1);
  }
}

static void answer(char mark, const char *id, const char *text) {
  put(&mark, 1);
  puts_out(id);
  if (text && *text) {
    puts_out(" ");
    put_text(text, NULL);
  }
  puts_out("\n\n");
}

static void log_line(const char *line) {
  if (log_path == NULL) return;
  FILE *f = fopen(log_path, "a");
  if (f == NULL) exit(3);
  fprintf(f, "%s\n", line);
  fclose(f);
}

static int counts[64];

int main(int argc, char **argv) {
  int stay = 0, quit_status = 0;
  for (int k = 1; k < argc; k++) {
    const char *a = argv[k];
    if (strcmp(a, "--log") == 0 && k + 1 < argc) {
      log_path = argv[++k];
    } else if (strcmp(a, "--pid") == 0 && k + 1 < argc) {
      FILE *f = fopen(argv[++k], "w");
      if (f == NULL) return 3;
      fprintf(f, "%ld %ld\n", (long)getpid(), (long)getpgrp());
      fclose(f);
    } else if (strcmp(a, "--fds") == 0 && k + 1 < argc) {
      int open_fds = 0;
      for (int fd = 3; fd < 256; fd++)
        if (fcntl(fd, F_GETFD) != -1) open_fds++;
      FILE *f = fopen(argv[++k], "w");
      if (f == NULL) return 3;
      fprintf(f, "%d\n", open_fds);
      fclose(f);
    } else if (strcmp(a, "--stderr") == 0 && k + 1 < argc) {
      fprintf(stderr, "%s\n", argv[++k]);
    } else if (strcmp(a, "--banner") == 0 && k + 1 < argc) {
      put_text(argv[++k], NULL);
    } else if (strcmp(a, "--ignore-signals") == 0) {
      signal(SIGINT, SIG_IGN);
      signal(SIGTERM, SIG_IGN);
      signal(SIGHUP, SIG_IGN);
    } else if (strcmp(a, "--stay") == 0) {
      stay = 1;
    } else if (strcmp(a, "--no-read") == 0) {
      forever();
    } else if (strcmp(a, "--exec") == 0 && k + 1 < argc) {
      signal(SIGINT, SIG_DFL);
      signal(SIGQUIT, SIG_DFL);
      execvp(argv[k + 1], argv + k + 1);
      perror("fakebot: exec");
      return 3;
    } else if (strcmp(a, "--quit-status") == 0 && k + 1 < argc) {
      quit_status = atoi(argv[++k]);
    } else {
      char *eq = strchr(a, '=');
      if (eq == NULL || rule_count == 64) {
        fprintf(stderr, "fakebot: bad argument %s\n", a);
        return 3;
      }
      rule *r = &rules[rule_count++];
      r->name = strndup(a, (size_t)(eq - a));
      r->action = eq + 1;
      r->occurrence = 0;
      char *hash = strchr(r->name, '#');
      if (hash) {
        *hash = '\0';
        r->occurrence = atoi(hash + 1);
      }
    }
  }

  char *line = NULL;
  size_t capacity = 0;
  ssize_t length;
  while ((length = getline(&line, &capacity, stdin)) != -1) {
    if (length > 0 && line[length - 1] == '\n') line[--length] = '\0';
    log_line(line);
    char *p = line;
    char id[32] = "";
    size_t n = 0;
    while (*p >= '0' && *p <= '9' && n < sizeof(id) - 1) id[n++] = *p++;
    id[n] = '\0';
    while (*p == ' ') p++;
    char name[64];
    size_t m = strcspn(p, " ");
    if (m >= sizeof(name)) m = sizeof(name) - 1;
    memcpy(name, p, m);
    name[m] = '\0';

    const char *action = NULL;
    for (int k = 0; k < rule_count; k++)
      if (strcmp(rules[k].name, name) == 0) {
        int seen = ++counts[k];
        if (action == NULL && (rules[k].occurrence == 0 || rules[k].occurrence == seen)) action = rules[k].action;
      }

    if (action && strncmp(action, "sleep:", 6) == 0) {
      double s = atof(action + 6);
      struct timespec t = {(time_t)s, (long)((s - (time_t)s) * 1e9)};
      while (nanosleep(&t, &t) != 0 && errno == EINTR) {}
      action = NULL;
    }
    if (action == NULL) {
      if (strcmp(name, "name") == 0)
        answer('=', id, "fake");
      else if (strcmp(name, "genmove") == 0)
        answer('=', id, "pass");
      else if (strcmp(name, "known_command") == 0)
        answer('=', id, "false");
      else
        answer('=', id, NULL);
      if (strcmp(name, "quit") == 0) return quit_status;
    } else if (strncmp(action, "ok:", 3) == 0) {
      answer('=', id, action + 3);
    } else if (strncmp(action, "err:", 4) == 0) {
      answer('?', id, action + 4);
    } else if (strncmp(action, "raw:", 4) == 0) {
      put_text(action + 4, id);
    } else if (strcmp(action, "hang") == 0) {
      // nothing
    } else if (strcmp(action, "stop") == 0) {
      forever();
    } else if (strncmp(action, "exit:", 5) == 0) {
      return atoi(action + 5);
    } else if (strcmp(action, "crash") == 0) {
      signal(SIGSEGV, SIG_DFL);
      raise(SIGSEGV);
    } else if (strcmp(action, "close") == 0) {
      close(STDOUT_FILENO);
      forever();
    } else if (strcmp(action, "flood") == 0) {
      char block[4096];
      memset(block, 'x', sizeof(block));
      for (;;) put(block, sizeof(block));
    } else {
      fprintf(stderr, "fakebot: bad action %s\n", action);
      return 3;
    }
  }
  log_line("EOF");
  if (stay) forever();
  return 0;
}
