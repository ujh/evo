/*
 * Tromp-Taylor area scoring over Brown's current board.
 */

#ifndef SCORE_H
#define SCORE_H

#include <stddef.h>

// Room for the longest result format_score writes, such as "B+529.0" or
// "W+579.0" on the largest board with komi 50, and the terminating NUL.
#define SCORE_RESULT_SIZE 16

// Black's margin: black's area minus white's area and game_komi (passed
// in; Brown's global komi is not read). A color's area is its stones plus
// every empty region (4-connected) that borders only that color's stones;
// a region bordering both colors or none counts for nobody. Every stone on
// the board counts: dead stones are not removed.
float tromp_taylor_score(float game_komi);

// Writes the result for a margin as GNU Go's final_score writes it, which
// twogtp passes on unchanged: "B+3.5", "W+0.5", "B+3.0" (one decimal), and
// "0" for a draw.
void format_score(float margin, char *text, size_t size);

#endif
