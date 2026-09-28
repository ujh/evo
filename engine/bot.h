#ifndef BOT_H
#define BOT_H

/*
 * A controller for external GTP programs ("bots"), for a program that
 * plays them (the arena). It starts a bot from its stored command line,
 * sends it GTP commands with command IDs, reads each answer within a
 * deadline, and kills and reaps it. It links no board code: moves go in
 * and out as GTP vertices.
 *
 * A bot runs in a process group of its own, with its stdin and stdout on
 * pipes (close-on-exec, so a later bot never holds an earlier one's
 * pipes) and its stderr on a descriptor the caller gives (the chunk's
 * .err file). A terminal's Ctrl-C therefore reaches only the program that
 * controls the bots, which kills and reaps every live bot on SIGINT,
 * SIGTERM, SIGHUP, SIGQUIT, a crash signal (SIGSEGV, SIGBUS, SIGFPE,
 * SIGILL, SIGABRT), and at exit, then restores the signal's default action
 * and raises it again, so its parent sees it die by that signal (a shell
 * reports 128 + the signal). A signal that was ignored when the first bot
 * started stays ignored. SIGPIPE is ignored from then on, so a bot that
 * closes its stdin gives an error, not the controller's death; the bots
 * get the original SIGPIPE action.
 *
 * Times are seconds on bot_now()'s clock, which does not count system
 * sleep (CLOCK_UPTIME_RAW on macOS, whose CLOCK_MONOTONIC counts it;
 * CLOCK_MONOTONIC elsewhere). Every wait is a poll() against a deadline
 * on that clock, so no call waits longer than the seconds it is given
 * (plus the time to kill and reap a bot).
 */

#include <stddef.h>

typedef struct bot bot;

typedef enum {
  BOT_OK,       // answered "=": the reply is its text
  BOT_ERROR,    // answered "?": the reply is the error text; the bot lives
  BOT_TIMEOUT,  // no whole answer within the deadline: killed and reaped
  BOT_DIED,     // closed its output, exited, or its input broke (EOF,
                // broken pipe, crash): killed if still running, and reaped
  BOT_PROTOCOL, // an answer that is not GTP (wrong ID, too long): killed
                // and reaped
} bot_status;

// The longest answer, all its lines, and the longest line read outside
// an answer, in bytes. A longer one is BOT_PROTOCOL.
#define BOT_MAX_RESPONSE 65536

// Splits a command line into an argv, as twogtp's StringUtil.splitArguments
// does (GoGui 1.6.0), since the stored opponent commands are written for
// twogtp:
//   - whitespace outside double quotes separates arguments; whitespace is
//     Java's Character.isWhitespace (ASCII space, \t \n \v \f \r, 0x1c-0x1f,
//     and the UTF-8 encoded Unicode spaces other than the no-break ones);
//   - a double quote opens or closes quoting and is dropped. Opening does
//     not end the argument ('ab"c d"' is one argument, 'abc d'); closing
//     ends it, even when empty ('""' is one empty argument, '"a"b' is two);
//   - a backslash stays in the argument and only stops the next character,
//     if a double quote, from opening or closing quoting ('a\"b' is 'a\"b');
//     a backslash after a backslash does not;
//   - an unclosed quote runs to the end.
// Returns the argument count; *argv gets a NULL-terminated array, to free
// with bot_free_arguments.
int bot_split_arguments(const char *command, char ***argv);
void bot_free_arguments(char **argv);

// The clock of every deadline, in seconds.
double bot_now(void);

// Sets up the signal cleanup (see the top). bot_start calls it; call it
// earlier to have SIGPIPE ignored before any bot runs. Idempotent.
void bot_init(void);

// Starts the bot `command` (split with bot_split_arguments and started
// with execvp, never through a shell; a program name without a slash that
// names an existing file in the working directory is that file, as twogtp
// makes such a name absolute), its stderr on `stderr_fd`. Returns the bot,
// or NULL with *message set to why (no program, a failed pipe or fork, or
// execvp's error), a static text valid until the next call. stderr_fd
// becomes the bot's stderr, but is not closed in the bot as well, so pass
// 2 (the arena's stderr) or a descriptor with FD_CLOEXEC; otherwise the
// bot holds a second copy of it.
bot *bot_start(const char *command, int stderr_fd, const char **message);

// The bot's process ID (0 once reaped).
int bot_pid(const bot *b);

// Sends `command` (one line, without the newline) with the next command
// ID, and waits for its answer until `seconds` have passed since the call.
// The answer is "=ID" or "?ID" (the ID it was sent), then the reply text,
// possibly over several lines, then an empty line. Lines before an answer
// that do not start with "=" or "?" are skipped, as twogtp skips them; a
// "\r" before a line's "\n" is dropped. *text gets the reply for BOT_OK
// and BOT_ERROR (spaces and tabs after the ID and at the end removed,
// lines joined by "\n", possibly empty), and otherwise what went wrong,
// one line; it lives in the bot until its next call. Once a call returns
// BOT_TIMEOUT, BOT_DIED or BOT_PROTOCOL the bot is gone and every later
// call returns BOT_DIED.
bot_status bot_command(bot *b, const char *command, double seconds, const char **text);

// Asks known_command NAME; *known is 1 when the reply is "true", ignoring
// case, 0 when it is anything else. A "?" answer is BOT_ERROR.
bot_status bot_known_command(bot *b, const char *name, double seconds, int *known, const char **text);

// A new game: known_command time_settings, then boardsize SIZE,
// clear_board, komi KOMI (as twogtp writes komi: at most three decimals,
// no trailing zeros, "6.5", "7"), and, only when time_settings is known,
// "time_settings M 0 0" with M = ceil(main_time), absolute time without
// byo-yomi. Each command gets `seconds`. Stops at the first command that
// does not answer "=", with its status; *text then starts with that
// command's name. BOT_OK when every one answered "=".
bot_status bot_setup(bot *b, int size, double komi, double main_time, double seconds, const char **text);

// A genmove reply, ignoring case: a vertex such as "C3" (columns A-Z
// without I, rows 1 to SIZE from the bottom), "pass", or "resign".
typedef enum { BOT_MOVE_POINT, BOT_MOVE_PASS, BOT_MOVE_RESIGN, BOT_MOVE_INVALID } bot_move;

// Parses a genmove reply for a SIZE board; for a point, *column and *row
// get its column from the left and row from the bottom, both from 0.
bot_move bot_parse_move(const char *reply, int size, int *column, int *row);

// Ends the bot and frees it: sends quit and waits `seconds` for its
// answer, closes its stdin, waits for it to exit until `seconds` have
// passed since the call, then kills it if it still runs, and reaps it.
// Its exit status is ignored. Returns 1 when it answered quit in time.
int bot_quit(bot *b, double seconds);

// Kills the bot at once (SIGKILL), reaps it, and frees it.
void bot_kill(bot *b);

#endif
