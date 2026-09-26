/*
 * Features: facts about the position for the player to move, read from
 * Brown's board, as a network's inputs. Move features are per point, facts
 * about playing there; board features are the liberty planes, the last
 * move, and whether the opponent passed. They need nothing but brown.o and
 * lib/libann.a (for the layout's counts), so any program can link
 * features.o with them. Include brown.h first.
 */

#include "ann.h"

// The move features, each 0 or 1 at a point, in the order of the input
// layout (ANN_GROUP_* in lib/ann.h). move_features_at and
// move_features_board return them as bits, feature f in FEATURE_BIT(f).
enum {
  FEATURE_HANE,        // shapes: one of michi's hane shapes (the first four patterns)
  FEATURE_CUT,         // shapes: one of michi's cut shapes (the next four)
  FEATURE_EDGE,        // shapes: one of michi's edge shapes (the last five)
  FEATURE_CAPTURE,     // tactics: the move captures at least one stone (ko captures too)
  FEATURE_SELF_ATARI,  // tactics: it captures nothing and leaves its chain one liberty
  FEATURE_SAVES_ATARI, // tactics: an own chain in atari has two or more liberties after
                       // it, by extending or by capturing, touching it or not
  FEATURE_NEAR_LAST,   // last_move: one of the 8 points around the opponent's last
                       // stone, if the last move was the opponent's stone and it
                       // is still on the board
  MOVE_FEATURES        // how many there are
};

#define FEATURE_BIT(f) (1u << (f))

// The FEATURE_BITs of the move features of the groups (ANN_GROUP_* bits).
unsigned group_features(unsigned groups);

// Whether the engine would play at (i, j) for color: a legal move, not
// suicide, and not the opponent's suicide point (in effect an own eye)
// unless it touches an opponent stone. generate_move's move choice uses it,
// so the features and the moves agree on which points count.
int move_allowed(int i, int j, int color);

// The move features of (i, j) for color, as bits; 0 where move_allowed is
// false. It computes the whole board, so use move_features_board for more
// than one point.
unsigned move_features_at(int i, int j, int color);

// The move features in `wanted` (FEATURE_BITs; the others stay 0) of every
// point for color, in bits[POS(i, j)], in one pass: at most one trial move
// per point, only where a tactical feature could be 1, played and undone
// with brown_save and brown_restore, so the board, the ko point, and the
// last move are as before.
void move_features_board(int color, unsigned wanted, unsigned *bits);

// The liberties of the chain at (i, j), 0 at an empty point.
int chain_liberties(int i, int j);

// Fills inputs with a network's inputs for the groups (ANN_GROUP_* bits),
// for color, in lib/ann.h's layout: komi (positive for white, negative for
// black), each point's stone (1 own, -1 opponent, 0 empty), then each move
// feature of the groups as a plane of 0/1, the liberty planes (at each
// stone +1 own or -1 opponent in the plane for its chain's 1, 2, or 3 or
// more liberties), the last_move plane (1 at the opponent's last stone,
// under near_last's condition), and opponent_passed (1 if the last move was
// the opponent's pass). Points in row order. Returns the number of inputs
// written, ann_layout_inputs(groups, board_size^2), or -1 for a mask with a
// bit that is no group (writing nothing). Unless bits is NULL, it also
// stores each point's move features of the groups there, as
// move_features_board does.
int feature_inputs(unsigned groups, int color, double *inputs, unsigned *bits);

/* The 3x3 shapes. */

// A point's 8 neighbours, in row order (up left, up, up right, left, right,
// down left, down, down right), neighbour k in bits 2k and 2k+1, give one
// of PATTERN3_CODES codes. Colours are from the mover's view.
#define NEIGHBOUR_EMPTY 0
#define NEIGHBOUR_OWN 1
#define NEIGHBOUR_OPPONENT 2
#define NEIGHBOUR_OFF_BOARD 3
#define PATTERN3_CODES 65536

// The code of (i, j)'s neighbours for color.
unsigned pattern3_code(int i, int j, int color);

// The shape families (FEATURE_BIT of FEATURE_HANE, FEATURE_CUT, and
// FEATURE_EDGE) a code matches, with an empty centre, whatever the moves'
// legality. The tables are built on first use.
unsigned pattern3_families(unsigned code);
