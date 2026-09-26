/*
 * Move features: facts about playing at a point, for the player to move,
 * read from Brown's board. They need nothing but brown.o, so any program
 * can link features.o with it. Include brown.h first.
 */

// The move features, each 0 or 1 at a point. move_features_at returns them
// as bits, feature f in FEATURE_BIT(f).
enum {
  FEATURE_HANE, // one of michi's hane shapes (the first four patterns)
  FEATURE_CUT,  // one of michi's cut shapes (the next four)
  FEATURE_EDGE, // one of michi's edge shapes (the last five)
  MOVE_FEATURES // how many there are
};

#define FEATURE_BIT(f) (1u << (f))

// Whether the engine would play at (i, j) for color: a legal move, not
// suicide, and not the opponent's suicide point (in effect an own eye)
// unless it touches an opponent stone. generate_move's move choice uses it,
// so the features and the moves agree on which points count.
int move_allowed(int i, int j, int color);

// The move features of (i, j) for color, as bits; 0 where move_allowed is
// false.
unsigned move_features_at(int i, int j, int color);

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
