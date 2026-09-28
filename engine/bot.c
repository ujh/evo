// The bot controller: see bot.h.

#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE // CLOCK_UPTIME_RAW

#include "bot.h"

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdarg.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

struct bot {
  pid_t pid;    // 0 once reaped
  int in, out;  // the bot's stdin (we write) and stdout (we read); -1 closed
  long next_id; // the next command's ID
  int gone;     // killed or dead: every call fails
  char *buffer; // bytes read and not yet used, `used` of them
  size_t used;
  size_t line;  // the bytes of the line read_line returned, with its "\n"
  char *text;   // the last reply or message
  size_t text_capacity;
};

// ---------------------------------------------------------------------
// Splitting, as twogtp's StringUtil.splitArguments

// The length of the whitespace character at s (Java's isWhitespace, in
// UTF-8), or 0.
static int whitespace(const unsigned char *s) {
  if (*s == ' ' || (*s >= '\t' && *s <= '\r') || (*s >= 0x1c && *s <= 0x1f)) return 1;
  if (s[0] == 0xe1 && s[1] == 0x9a && s[2] == 0x80) return 3; // U+1680
  if (s[0] == 0xe2 && s[1] == 0x80 &&
      ((s[2] >= 0x80 && s[2] <= 0x86) || (s[2] >= 0x88 && s[2] <= 0x8a) || s[2] == 0xa8 || s[2] == 0xa9))
    return 3; // U+2000-2006, U+2008-200A, U+2028, U+2029
  if (s[0] == 0xe2 && s[1] == 0x81 && s[2] == 0x9f) return 3; // U+205F
  if (s[0] == 0xe3 && s[1] == 0x80 && s[2] == 0x80) return 3; // U+3000
  return 0;
}

static void *checked_realloc(void *p, size_t size) {
  void *q = realloc(p, size);
  if (q == NULL) {
    fprintf(stderr, "bot: out of memory\n");
    exit(1);
  }
  return q;
}

int bot_split_arguments(const char *command, char ***argv) {
  const unsigned char *s = (const unsigned char *)command;
  size_t length = strlen(command);
  char **args = checked_realloc(NULL, sizeof(char *));
  int count = 0;
  char *token = checked_realloc(NULL, length + 1);
  size_t used = 0;
  int escape = 0, quoted = 0;
#define PUSH()                                                                                                         \
  do {                                                                                                                 \
    token[used] = '\0';                                                                                                \
    args = checked_realloc(args, (count + 2) * sizeof(char *));                                                        \
    args[count] = checked_realloc(NULL, used + 1);                                                                     \
    memcpy(args[count++], token, used + 1);                                                                            \
    used = 0;                                                                                                          \
  } while (0)
  for (size_t k = 0; k < length;) {
    unsigned char c = s[k];
    int space = whitespace(s + k);
    if (c == '"' && !escape) {
      if (quoted) PUSH();
      quoted = !quoted;
      k++;
    } else if (space && !quoted) {
      if (used > 0) PUSH();
      k += (size_t)space;
    } else {
      int n = space ? space : 1;
      memcpy(token + used, s + k, (size_t)n);
      used += (size_t)n;
      k += (size_t)n;
    }
    escape = c == '\\' && !escape;
  }
  if (used > 0) PUSH();
#undef PUSH
  free(token);
  args[count] = NULL;
  *argv = args;
  return count;
}

void bot_free_arguments(char **argv) {
  for (char **a = argv; *a; a++) free(*a);
  free(argv);
}

// ---------------------------------------------------------------------
// The clock

double bot_now(void) {
  struct timespec t;
#ifdef CLOCK_UPTIME_RAW
  clock_gettime(CLOCK_UPTIME_RAW, &t);
#else
  clock_gettime(CLOCK_MONOTONIC, &t);
#endif
  return t.tv_sec + t.tv_nsec / 1e9;
}

// Milliseconds until `deadline`, rounded up, for poll(); 0 once passed.
static int milliseconds_until(double deadline) {
  double left = deadline - bot_now();
  if (left <= 0) return 0;
  double ms = ceil(left * 1000);
  return ms > 1e9 ? 1000000000 : (int)ms;
}

// ---------------------------------------------------------------------
// Live bots and signal cleanup

// The signals after which every live bot is killed and reaped.
static const int cleanup_signals[] = {SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGABRT};
#define CLEANUP_SIGNALS (int)(sizeof(cleanup_signals) / sizeof(cleanup_signals[0]))

// The actions before bot_init, which the bots get back.
static struct sigaction original_actions[CLEANUP_SIGNALS], original_pipe;
static sigset_t cleanup_set;
static int initialized;

// The live bots' process IDs, changed only with the cleanup signals
// blocked, so a handler never sees a half-made change.
#define MAX_BOTS 64
static volatile pid_t live[MAX_BOTS];

static void block(sigset_t *old) { sigprocmask(SIG_BLOCK, &cleanup_set, old); }
static void unblock(const sigset_t *old) { sigprocmask(SIG_SETMASK, old, NULL); }

// Async-signal-safe: kills and reaps every live bot.
static void kill_all(void) {
  for (int k = 0; k < MAX_BOTS; k++) {
    pid_t pid = live[k];
    if (pid > 0) {
      kill(pid, SIGKILL);
      while (waitpid(pid, NULL, 0) == -1 && errno == EINTR) {}
      live[k] = 0;
    }
  }
}

static void cleanup_handler(int signal) {
  int saved = errno;
  kill_all();
  // Die by the signal itself, so the parent sees it.
  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_handler = SIG_DFL;
  sigemptyset(&action.sa_mask);
  sigaction(signal, &action, NULL);
  sigset_t set;
  sigemptyset(&set);
  sigaddset(&set, signal);
  sigprocmask(SIG_UNBLOCK, &set, NULL);
  raise(signal);
  errno = saved;
}

static void cleanup_at_exit(void) {
  sigset_t old;
  block(&old);
  kill_all();
  unblock(&old);
}

void bot_init(void) {
  if (initialized) return;
  initialized = 1;
  sigemptyset(&cleanup_set);
  for (int k = 0; k < CLEANUP_SIGNALS; k++) {
    sigaction(cleanup_signals[k], NULL, &original_actions[k]);
    sigaddset(&cleanup_set, cleanup_signals[k]);
  }
  for (int k = 0; k < CLEANUP_SIGNALS; k++) {
    if (original_actions[k].sa_handler == SIG_IGN) continue;
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = cleanup_handler;
    action.sa_mask = cleanup_set;
    sigaction(cleanup_signals[k], &action, NULL);
  }
  struct sigaction ignore;
  memset(&ignore, 0, sizeof(ignore));
  ignore.sa_handler = SIG_IGN;
  sigemptyset(&ignore.sa_mask);
  sigaction(SIGPIPE, &ignore, &original_pipe);
  atexit(cleanup_at_exit);
}

static int track(pid_t pid) {
  for (int k = 0; k < MAX_BOTS; k++)
    if (live[k] == 0) {
      live[k] = pid;
      return 1;
    }
  return 0;
}

static void untrack(pid_t pid) {
  for (int k = 0; k < MAX_BOTS; k++)
    if (live[k] == pid) live[k] = 0;
}

// Reaps the bot, with the cleanup signals blocked so a handler cannot
// signal a reaped (possibly reused) process ID. Waits when `wait`, else
// only collects an exited bot. Returns 1 when reaped, with its status.
static int reap(bot *b, int wait, int *status) {
  if (b->pid == 0) return 1;
  sigset_t old;
  block(&old);
  pid_t r;
  while ((r = waitpid(b->pid, status, wait ? 0 : WNOHANG)) == -1 && errno == EINTR) {}
  if (r == b->pid || (r == -1 && errno == ECHILD)) {
    untrack(b->pid);
    b->pid = 0;
    r = 1;
  } else {
    r = 0;
  }
  unblock(&old);
  return (int)r;
}

static void close_pipes(bot *b) {
  if (b->in >= 0) close(b->in);
  if (b->out >= 0) close(b->out);
  b->in = b->out = -1;
}

// Kills and reaps the bot; it is gone from now on.
static void end(bot *b) {
  if (b->pid > 0) {
    kill(b->pid, SIGKILL);
    reap(b, 1, NULL);
  }
  close_pipes(b);
  b->gone = 1;
}

// ---------------------------------------------------------------------
// Starting

static char start_message[512];

static void set_cloexec(int fd) { fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC); }
static void set_nonblocking(int fd) { fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK); }

static int make_pipe(int fds[2]) {
  if (pipe(fds) != 0) return 0;
  set_cloexec(fds[0]);
  set_cloexec(fds[1]);
  return 1;
}

bot *bot_start(const char *command, int stderr_fd, const char **message) {
  bot_init();
  char **argv;
  if (bot_split_arguments(command, &argv) == 0) {
    bot_free_arguments(argv);
    *message = "the command names no program";
    return NULL;
  }
  // twogtp makes an existing file's name absolute, so a name without a
  // slash that is a file here is that file, not one on the PATH.
  char *program = argv[0];
  char *local = NULL;
  struct stat st;
  if (strchr(program, '/') == NULL && *program && stat(program, &st) == 0) {
    local = checked_realloc(NULL, strlen(program) + 3);
    sprintf(local, "./%s", program);
    program = local;
  }

  int in[2], out[2], report[2];
  if (!make_pipe(in)) goto pipe_failed;
  if (!make_pipe(out)) {
    close(in[0]);
    close(in[1]);
    goto pipe_failed;
  }
  if (!make_pipe(report)) {
    close(in[0]);
    close(in[1]);
    close(out[0]);
    close(out[1]);
    goto pipe_failed;
  }

  // Block the cleanup signals until the new bot is tracked, so a signal
  // between fork and tracking cannot leave it running.
  sigset_t old;
  block(&old);
  pid_t pid = fork();
  if (pid == 0) {
    // The child: its own process group, the original signal actions and
    // mask, the pipes on 0 and 1, stderr on stderr_fd, then exec.
    setpgid(0, 0);
    for (int k = 0; k < CLEANUP_SIGNALS; k++) sigaction(cleanup_signals[k], &original_actions[k], NULL);
    sigaction(SIGPIPE, &original_pipe, NULL);
    sigprocmask(SIG_SETMASK, &old, NULL);
    if (dup2(in[0], STDIN_FILENO) < 0 || dup2(out[1], STDOUT_FILENO) < 0 ||
        (stderr_fd != STDERR_FILENO && dup2(stderr_fd, STDERR_FILENO) < 0)) {
      int e = errno;
      (void)!write(report[1], &e, sizeof(e));
      _exit(127);
    }
    execvp(program, argv);
    int e = errno;
    (void)!write(report[1], &e, sizeof(e));
    _exit(127);
  }
  int fork_errno = errno;
  if (pid > 0) {
    setpgid(pid, pid); // also here, so the group exists before any kill
    if (!track(pid)) {
      kill(pid, SIGKILL);
      while (waitpid(pid, NULL, 0) == -1 && errno == EINTR) {}
      pid = -2;
    }
  }
  unblock(&old);
  close(in[0]);
  close(out[1]);
  close(report[1]);

  if (pid < 0) {
    close(in[1]);
    close(out[0]);
    close(report[0]);
    if (pid == -2)
      snprintf(start_message, sizeof(start_message), "more than %d bots at once", MAX_BOTS);
    else
      snprintf(start_message, sizeof(start_message), "cannot start %s: %s", argv[0], strerror(fork_errno));
    free(local);
    bot_free_arguments(argv);
    *message = start_message;
    return NULL;
  }

  // The report pipe closes on exec; a failed exec writes its errno first.
  int e;
  ssize_t n;
  while ((n = read(report[0], &e, sizeof(e))) == -1 && errno == EINTR) {}
  close(report[0]);
  bot *b = checked_realloc(NULL, sizeof(bot));
  b->pid = pid;
  b->in = in[1];
  b->out = out[0];
  b->next_id = 1;
  b->gone = 0;
  b->buffer = checked_realloc(NULL, BOT_MAX_RESPONSE + 1);
  b->used = 0;
  b->line = 0;
  b->text = NULL;
  b->text_capacity = 0;
  set_nonblocking(b->in);
  set_nonblocking(b->out);
  if (n == (ssize_t)sizeof(e)) {
    reap(b, 1, NULL);
    snprintf(start_message, sizeof(start_message), "cannot start %s: %s", argv[0], strerror(e));
    close_pipes(b);
    free(b->buffer);
    free(b);
    free(local);
    bot_free_arguments(argv);
    *message = start_message;
    return NULL;
  }
  free(local);
  bot_free_arguments(argv);
  return b;

pipe_failed:
  snprintf(start_message, sizeof(start_message), "cannot start %s: %s", argv[0], strerror(errno));
  free(local);
  bot_free_arguments(argv);
  *message = start_message;
  return NULL;
}

int bot_pid(const bot *b) { return (int)b->pid; }

// ---------------------------------------------------------------------
// Commands and answers

// Sets the bot's text, on one line (control characters as spaces) unless
// `lines`.
__attribute__((format(printf, 3, 4))) static void set_text(bot *b, int lines, const char *format, ...) {
  va_list args;
  va_start(args, format);
  int n = vsnprintf(NULL, 0, format, args);
  va_end(args);
  if ((size_t)n + 1 > b->text_capacity) {
    b->text_capacity = (size_t)n + 1;
    b->text = checked_realloc(b->text, b->text_capacity);
  }
  va_start(args, format);
  vsnprintf(b->text, (size_t)n + 1, format, args);
  va_end(args);
  for (char *p = b->text; *p; p++)
    if ((unsigned char)*p < 0x20 && !(lines && *p == '\n')) *p = ' ';
}

// Why a bot that closed its output or its input is gone: kills it if it
// has not exited within a second, and reaps it.
static void describe_death(bot *b) {
  int status = 0, reaped = 0;
  close_pipes(b);
  double deadline = bot_now() + 1;
  while (!(reaped = reap(b, 0, &status)) && bot_now() < deadline) poll(NULL, 0, 10);
  if (!reaped) {
    end(b);
    set_text(b, 0, "closed its output");
  } else if (WIFEXITED(status)) {
    set_text(b, 0, "exited with status %d", WEXITSTATUS(status));
  } else if (WIFSIGNALED(status)) {
    set_text(b, 0, "killed by signal %d", WTERMSIG(status));
  } else {
    set_text(b, 0, "exited");
  }
  b->gone = 1;
}

// Writes the whole of `s` before `deadline`. 1 on success; 0 when the
// deadline passed; -1 when the bot's input is closed.
static int write_all(bot *b, const char *s, size_t n, double deadline) {
  while (n > 0) {
    ssize_t w = write(b->in, s, n);
    if (w > 0) {
      s += w;
      n -= (size_t)w;
      continue;
    }
    if (w < 0 && errno == EINTR) continue;
    if (w < 0 && errno != EAGAIN && errno != EWOULDBLOCK) return -1;
    struct pollfd p = {b->in, POLLOUT, 0};
    int ms = milliseconds_until(deadline);
    if (ms == 0) return 0;
    int r = poll(&p, 1, ms);
    if (r < 0 && errno != EINTR) return -1;
    if (r > 0 && (p.revents & (POLLERR | POLLNVAL))) return -1;
  }
  return 1;
}

// Reads one line: returns its length (without "\n" and a "\r" before it),
// with the line at b->buffer as a string, to be dropped with drop_line;
// -1 at the deadline; -2 at EOF or a read error; -3 when the line is
// longer than BOT_MAX_RESPONSE.
static ssize_t read_line(bot *b, double deadline) {
  for (;;) {
    char *newline = memchr(b->buffer, '\n', b->used);
    if (newline) {
      size_t length = (size_t)(newline - b->buffer);
      b->line = length + 1;
      *newline = '\0';
      if (length > 0 && b->buffer[length - 1] == '\r') b->buffer[--length] = '\0';
      return (ssize_t)length;
    }
    if (b->used >= BOT_MAX_RESPONSE) return -3;
    ssize_t r = read(b->out, b->buffer + b->used, BOT_MAX_RESPONSE - b->used);
    if (r > 0) {
      b->used += (size_t)r;
      continue;
    }
    if (r == 0) return -2;
    if (errno == EINTR) continue;
    if (errno != EAGAIN && errno != EWOULDBLOCK) return -2;
    struct pollfd p = {b->out, POLLIN, 0};
    int ms = milliseconds_until(deadline);
    if (ms == 0) return -1;
    if (poll(&p, 1, ms) < 0 && errno != EINTR) return -2;
  }
}

// Drops the line read_line returned (and its newline).
static void drop_line(bot *b) {
  memmove(b->buffer, b->buffer + b->line, b->used - b->line);
  b->used -= b->line;
  b->line = 0;
}

static int blank(char c) { return c == ' ' || c == '\t'; }

bot_status bot_command(bot *b, const char *command, double seconds, const char **text) {
  double deadline = bot_now() + seconds;
  *text = b->text;
  if (b->gone) {
    set_text(b, 0, "the bot is gone");
    *text = b->text;
    return BOT_DIED;
  }
  char name[64];
  size_t m = strcspn(command, " ");
  if (m >= sizeof(name)) m = sizeof(name) - 1;
  memcpy(name, command, m);
  name[m] = '\0';

  long id = b->next_id++;
  size_t size = strlen(command) + 32;
  char *line = checked_realloc(NULL, size);
  int n = snprintf(line, size, "%ld %s\n", id, command);
  int w = write_all(b, line, (size_t)n, deadline);
  free(line);
  bot_status status;
  if (w == 0) goto timeout;
  if (w < 0) {
    describe_death(b);
    *text = b->text;
    return BOT_DIED;
  }

  // Skip lines until an answer starts, as twogtp does.
  ssize_t length;
  for (;;) {
    length = read_line(b, deadline);
    if (length < 0) break;
    if (b->buffer[0] == '=' || b->buffer[0] == '?') break;
    drop_line(b);
  }
  if (length == -1) goto timeout;
  if (length == -2) goto died;
  if (length == -3) goto too_long;

  // The answer's first line: "=ID" or "?ID", then blanks and text.
  char mark = b->buffer[0];
  const char *p = b->buffer + 1;
  const char *digits = p;
  while (*p >= '0' && *p <= '9') p++;
  if (*p != '\0' && !blank(*p)) {
    while (*p != '\0' && !blank(*p)) p++;
  }
  size_t id_length = (size_t)(p - digits);
  char expected[32];
  snprintf(expected, sizeof(expected), "%ld", id);
  if (id_length != strlen(expected) || strncmp(digits, expected, id_length) != 0) {
    if (id_length == 0)
      set_text(b, 0, "answered without ID to command %ld", id);
    else
      set_text(b, 0, "answered with ID %.*s to command %ld", (int)(id_length > 40 ? 40 : id_length), digits, id);
    end(b);
    *text = b->text;
    return BOT_PROTOCOL;
  }
  while (blank(*p)) p++;

  // Collect the reply until the empty line.
  char *reply = checked_realloc(NULL, BOT_MAX_RESPONSE + 1);
  size_t used = strlen(p);
  memcpy(reply, p, used + 1);
  drop_line(b);
  for (;;) {
    length = read_line(b, deadline);
    if (length < 0) break;
    if (length == 0) {
      drop_line(b);
      break;
    }
    if (used + 1 + (size_t)length > BOT_MAX_RESPONSE) {
      length = -4;
      break;
    }
    reply[used++] = '\n';
    memcpy(reply + used, b->buffer, (size_t)length + 1);
    used += (size_t)length;
    drop_line(b);
  }
  if (length < 0) {
    free(reply);
    if (length == -1) goto timeout;
    if (length == -2) goto died;
    if (length == -3) goto too_long;
    end(b);
    set_text(b, 0, "an answer longer than %d bytes", BOT_MAX_RESPONSE);
    *text = b->text;
    return BOT_PROTOCOL;
  }
  while (used > 0 && (blank(reply[used - 1]) || reply[used - 1] == '\n')) reply[--used] = '\0';
  set_text(b, 1, "%s", reply);
  free(reply);
  *text = b->text;
  return mark == '=' ? BOT_OK : BOT_ERROR;

timeout:
  end(b);
  set_text(b, 0, "no answer to %s within %.3f s", name, seconds);
  status = BOT_TIMEOUT;
  goto done;
died:
  describe_death(b);
  status = BOT_DIED;
  goto done;
too_long:
  end(b);
  set_text(b, 0, "a line longer than %d bytes", BOT_MAX_RESPONSE);
  status = BOT_PROTOCOL;
done:
  *text = b->text;
  return status;
}

static int same_ignoring_case(const char *a, const char *b) {
  for (; *a && *b; a++, b++) {
    char x = *a >= 'A' && *a <= 'Z' ? *a - 'A' + 'a' : *a;
    char y = *b >= 'A' && *b <= 'Z' ? *b - 'A' + 'a' : *b;
    if (x != y) return 0;
  }
  return *a == *b;
}

bot_status bot_known_command(bot *b, const char *name, double seconds, int *known, const char **text) {
  char command[128];
  snprintf(command, sizeof(command), "known_command %s", name);
  bot_status s = bot_command(b, command, seconds, text);
  *known = s == BOT_OK && same_ignoring_case(*text, "true");
  return s;
}

// Komi as twogtp writes it (Java's DecimalFormat, English: at most three
// decimals, without trailing zeros or a trailing point).
static void format_komi(double komi, char *out, size_t size) {
  snprintf(out, size, "%.3f", komi);
  char *point = strchr(out, '.');
  if (point) {
    char *end = out + strlen(out) - 1;
    while (end > point && *end == '0') *end-- = '\0';
    if (end == point) *end = '\0';
  }
}

bot_status bot_setup(bot *b, int size, double komi, double main_time, double seconds, const char **text) {
  int known;
  char command[96];
  bot_status s = bot_known_command(b, "time_settings", seconds, &known, text);
  if (s != BOT_OK) snprintf(command, sizeof(command), "known_command");
  // twogtp's sequence: boardsize, clear_board and komi when it starts, then
  // boardsize and clear_board again for the game. Brown reseeds its moves
  // on boardsize, so its games repeat twogtp's only with both.
  for (int step = 0; step < 6 && s == BOT_OK; step++) {
    if (step == 0 || step == 3) {
      snprintf(command, sizeof(command), "boardsize %d", size);
    } else if (step == 1 || step == 4) {
      snprintf(command, sizeof(command), "clear_board");
    } else if (step == 2) {
      char k[64];
      format_komi(komi, k, sizeof(k));
      snprintf(command, sizeof(command), "komi %s", k);
    } else {
      if (!known) break;
      snprintf(command, sizeof(command), "time_settings %.0f 0 0", ceil(main_time));
    }
    s = bot_command(b, command, seconds, text);
  }
  if (s == BOT_OK) {
    set_text(b, 0, "%s", "");
  } else {
    command[strcspn(command, " ")] = '\0';
    char *reason = checked_realloc(NULL, strlen(*text) + 1);
    strcpy(reason, *text);
    set_text(b, 0, "%s: %s", command, reason);
    free(reason);
  }
  *text = b->text;
  return s;
}

bot_move bot_parse_move(const char *reply, int size, int *column, int *row) {
  if (same_ignoring_case(reply, "pass")) return BOT_MOVE_PASS;
  if (same_ignoring_case(reply, "resign")) return BOT_MOVE_RESIGN;
  char letter = reply[0] >= 'a' && reply[0] <= 'z' ? reply[0] - 'a' + 'A' : reply[0];
  if (letter < 'A' || letter > 'Z' || letter == 'I') return BOT_MOVE_INVALID;
  int x = letter - 'A' - (letter > 'I');
  const char *p = reply + 1;
  if (*p < '1' || *p > '9') return BOT_MOVE_INVALID;
  int y = 0;
  for (; *p >= '0' && *p <= '9'; p++) {
    y = y * 10 + (*p - '0');
    if (y > size) return BOT_MOVE_INVALID;
  }
  if (*p != '\0' || x >= size || y < 1) return BOT_MOVE_INVALID;
  *column = x;
  *row = y - 1;
  return BOT_MOVE_POINT;
}

// ---------------------------------------------------------------------
// Ending

static void release(bot *b) {
  free(b->buffer);
  free(b->text);
  free(b);
}

int bot_quit(bot *b, double seconds) {
  double deadline = bot_now() + seconds;
  const char *text;
  int answered = !b->gone && bot_command(b, "quit", seconds, &text) == BOT_OK;
  if (b->pid > 0) {
    close_pipes(b);
    while (!reap(b, 0, NULL) && bot_now() < deadline) poll(NULL, 0, 10);
  }
  end(b);
  release(b);
  return answered;
}

void bot_kill(bot *b) {
  end(b);
  release(b);
}
