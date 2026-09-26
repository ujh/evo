/*
 * Tests of the features in features.c: michi's 3x3 shape tables (hane,
 * cut, edge) and their lookup on Brown's board, the tactical move features
 * (capture, self_atari, saves_atari) against a plain reference, near_last,
 * the board inputs (liberties, last_move, opponent_passed), the input
 * layout per feature-group mask, and that a move feature is 0 at a point
 * the engine would not play. Linked with brown.o, features.o, and libann.a
 * (for the layout counts) alone, which also checks that features.o needs
 * nothing else.
 */

#include <string.h>

#include "brown.h"
#include "ann.h"
#include "features.h"
#include "minctest.h"

// Fails with the case's description, for checks inside loops.
#define lcase(test, ...) do {\
    ++ltests;\
    if (!(test)) {\
        ++lfails;\
        printf("%s:%d error: ", __FILE__, __LINE__);\
        printf(__VA_ARGS__);\
        printf("\n");\
    }} while (0)

static const unsigned HANE = FEATURE_BIT(FEATURE_HANE);
static const unsigned CUT = FEATURE_BIT(FEATURE_CUT);
static const unsigned EDGE = FEATURE_BIT(FEATURE_EDGE);
static const unsigned SHAPES = FEATURE_BIT(FEATURE_HANE) | FEATURE_BIT(FEATURE_CUT) | FEATURE_BIT(FEATURE_EDGE);
static const unsigned CAPTURE = FEATURE_BIT(FEATURE_CAPTURE);
static const unsigned SELF_ATARI = FEATURE_BIT(FEATURE_SELF_ATARI);
static const unsigned SAVES_ATARI = FEATURE_BIT(FEATURE_SAVES_ATARI);
static const unsigned NEAR_LAST = FEATURE_BIT(FEATURE_NEAR_LAST);
static const unsigned ALL_FEATURES = (1u << MOVE_FEATURES) - 1;

// Sets up a position from rows of 'X' (black), 'O' (white) and '.', on a
// board as wide as the rows. The position must have no stone without a
// liberty, so placing the stones captures nothing.
static void setup(const char **rows) {
  board_size = strlen(rows[0]);
  new_game();
  for (int i = 0; i < board_size; i++)
    for (int j = 0; j < board_size; j++) {
      if (rows[i][j] == 'X') play_move(i, j, BLACK);
      if (rows[i][j] == 'O') play_move(i, j, WHITE);
    }
  // Placing the stones is no move of the game.
  clear_last_move();
}

/* The tables. */

// Which families a neighbourhood code is in, as a table of 0/1 per code.
static int in_family(unsigned code, int feature) {
  return (pattern3_families(code) & FEATURE_BIT(feature)) != 0;
}

static int count(int a, int b) {
  int n = 0;
  for (unsigned code = 0; code < PATTERN3_CODES; code++)
    if (in_family(code, a) && in_family(code, b)) n++;
  return n;
}

// The entry counts of michi's expansion (pat3_expand on pat3src, as a set
// per family), and how the families overlap.
void test_table_counts() {
  lequal(count(FEATURE_HANE, FEATURE_HANE), 1536);
  lequal(count(FEATURE_CUT, FEATURE_CUT), 13884);
  lequal(count(FEATURE_EDGE, FEATURE_EDGE), 1120);
  lequal(count(FEATURE_HANE, FEATURE_CUT), 384);
  lequal(count(FEATURE_CUT, FEATURE_EDGE), 320);
  lequal(count(FEATURE_HANE, FEATURE_EDGE), 8);
  // No other bit is ever set.
  int other = 0;
  for (unsigned code = 0; code < PATTERN3_CODES; code++)
    if (pattern3_families(code) & ~SHAPES) other++;
  lequal(other, 0);
}

// FNV-1a (32 bit) over the 65,536 codes in order, one byte per code: 1 when
// the code is in the family, else 0.
static unsigned fnv1a(int feature) {
  unsigned h = 2166136261u;
  for (unsigned code = 0; code < PATTERN3_CODES; code++) {
    h ^= (unsigned)in_family(code, feature);
    h *= 16777619u;
  }
  return h;
}

// The tables hold exactly michi's sets. The hashes come from michi.py's own
// pat3src and pat3_expand, with its patterns mapped to codes as
// pattern3_code does ('.' 0, 'X' 1, 'x' 2, ' ' 3, the 8 neighbours in row
// order, neighbour k in bits 2k and 2k+1; since every family is closed
// under colour swap, which colour is 1 does not matter):
//
//   fams = {'hane': pat3src[0:4], 'cut': pat3src[4:8], 'edge': pat3src[8:13]}
//   for name, pats in fams.items():
//       s = set(p.replace('O', 'x') for pat in pats for p in pat3_expand(pat))
//       table = bytearray(65536)
//       for p in s:
//           cells = p[:4] + p[5:]
//           table[sum({'.': 0, 'X': 1, 'x': 2, ' ': 3}[c] << 2 * k
//                     for k, c in enumerate(cells))] = 1
//       h = 2166136261
//       for b in table: h = ((h ^ b) * 16777619) & 0xffffffff
void test_tables_are_michis() {
  lok(fnv1a(FEATURE_HANE) == 0xf0e87f4du);
  lok(fnv1a(FEATURE_CUT) == 0xdeebd4d5u);
  lok(fnv1a(FEATURE_EDGE) == 0x86ca4065u);
}

// The neighbour states of a code as a 3x3 grid (the centre unused).
static void decode(unsigned code, int grid[3][3]) {
  int k = 0;
  for (int r = 0; r < 3; r++)
    for (int c = 0; c < 3; c++) {
      if (r == 1 && c == 1) continue;
      grid[r][c] = (code >> (2 * k)) & 3;
      k++;
    }
}

static unsigned encode(int grid[3][3]) {
  unsigned code = 0;
  int k = 0;
  for (int r = 0; r < 3; r++)
    for (int c = 0; c < 3; c++) {
      if (r == 1 && c == 1) continue;
      code |= (unsigned)grid[r][c] << (2 * k);
      k++;
    }
  return code;
}

// Every family is closed under rotation, reflection, and colour swap.
void test_tables_are_symmetric() {
  int broken = 0;
  for (unsigned code = 0; code < PATTERN3_CODES; code++) {
    int grid[3][3], rot[3][3], flip[3][3], swap[3][3];
    decode(code, grid);
    for (int r = 0; r < 3; r++)
      for (int c = 0; c < 3; c++) {
        rot[r][c] = grid[2 - c][r];
        flip[r][c] = grid[r][2 - c];
        int s = grid[r][c];
        swap[r][c] = s == NEIGHBOUR_OWN ? NEIGHBOUR_OPPONENT : s == NEIGHBOUR_OPPONENT ? NEIGHBOUR_OWN : s;
      }
    unsigned families = pattern3_families(code);
    if (pattern3_families(encode(rot)) != families) broken++;
    if (pattern3_families(encode(flip)) != families) broken++;
    if (pattern3_families(encode(swap)) != families) broken++;
  }
  lequal(broken, 0);
}

/* Shapes on the board. */

// A concrete 3x3 neighbourhood, rows top to bottom: 'X' and 'O' are the two
// colours, '.' empty, '#' off the board. The centre is empty. `families`
// is what michi's sets say about it (checked with the script above).
typedef struct {
  const char *rows[3];
  unsigned families;
} shape;

static const shape interior[] = {
  {{"XOX", "...", "..."}, 1},  // enclosing hane
  {{".O.", "X..", "..."}, 1},  // katatsuke
  {{"XO.", "O..", "..."}, 2},  // unprotected cut
  {{".X.", "O.O", "..."}, 2},  // de
  {{"XO.", "X..", "O.."}, 3},  // magari, also a cut
  {{"...", "..X", "XOX"}, 3},  // hane and cut
  {{"...", "...", "..."}, 0},
  {{"XOO", "...", "..."}, 0},
};

static const shape edge[] = {
  {{"XOX", "...", "###"}, 5},  // enclosing hane on the edge, also an edge shape
  {{"X..", "O..", "###"}, 4},  // chase
  {{"X.X", "O.O", "###"}, 4},
  {{"OX.", "X.O", "###"}, 6},  // block side cut, also a cut
  {{"XO.", "O.X", "###"}, 6},  // peeped cut on the edge
  {{"...", "...", "###"}, 0},
};

static const shape corner[] = {
  {{"###", "#..", "#XO"}, 4},
  {{"###", "#.X", "#.O"}, 4},
  {{"###", "#.X", "#OX"}, 4},
};

// The shape turned by `orientation` (0-3: that many quarter turns; 4-7 the
// same, then mirrored).
static void orient(const shape *s, int orientation, char out[3][3]) {
  char grid[3][3], turned[3][3];
  for (int r = 0; r < 3; r++)
    for (int c = 0; c < 3; c++) grid[r][c] = s->rows[r][c];
  for (int t = 0; t < orientation % 4; t++) {
    for (int r = 0; r < 3; r++)
      for (int c = 0; c < 3; c++) turned[r][c] = grid[2 - c][r];
    memcpy(grid, turned, sizeof grid);
  }
  for (int r = 0; r < 3; r++)
    for (int c = 0; c < 3; c++) out[r][c] = orientation >= 4 ? grid[r][2 - c] : grid[r][c];
}

static int all_off(char a, char b, char c) {
  return a == '#' && b == '#' && c == '#';
}

// Puts the shape on an empty board of `size` around a centre that lies on
// the edges its '#' cells call for and elsewhere at (free_i, free_j), with
// 'X' as `x_color`. Returns 0 if the shape's '#' cells are not exactly the
// points off the board there, or if a stone did not stay.
static int place(char grid[3][3], int size, int free_i, int free_j, int x_color, int *ci, int *cj) {
  int i = free_i, j = free_j;
  if (all_off(grid[0][0], grid[0][1], grid[0][2])) i = 0;
  if (all_off(grid[2][0], grid[2][1], grid[2][2])) i = size - 1;
  if (all_off(grid[0][0], grid[1][0], grid[2][0])) j = 0;
  if (all_off(grid[0][2], grid[1][2], grid[2][2])) j = size - 1;
  board_size = size;
  new_game();
  for (int r = 0; r < 3; r++)
    for (int c = 0; c < 3; c++) {
      int pi = i + r - 1, pj = j + c - 1;
      if ((grid[r][c] == '#') != !on_board(pi, pj)) return 0;
      if (grid[r][c] == 'X') play_move(pi, pj, x_color);
      if (grid[r][c] == 'O') play_move(pi, pj, OTHER_COLOR(x_color));
    }
  for (int r = 0; r < 3; r++)
    for (int c = 0; c < 3; c++) {
      if (grid[r][c] == '#') continue;
      int want = grid[r][c] == 'X' ? x_color : grid[r][c] == 'O' ? OTHER_COLOR(x_color) : EMPTY;
      if (get_board(i + r - 1, j + c - 1) != want) return 0;
    }
  *ci = i;
  *cj = j;
  return 1;
}

static const int sizes[] = {5, 9, 19};

// Each shape in all 8 orientations, with either colour as 'X', for either
// player to move, on 5x5, 9x9, and 19x19, at three places: for a shape in
// the middle, next to three of the edges (not next to a corner, where a
// stone of it could be captured); for an edge shape, along its edge; a
// corner shape has one place per orientation. The centre has exactly the
// shape's families.
static void check_shapes(const shape *shapes, int n, const char *kind) {
  for (int s = 0; s < n; s++)
    for (int z = 0; z < 3; z++) {
      int size = sizes[z];
      int frees[3] = {1, size / 2, size - 2};
      for (int f = 0; f < 3; f++)
        for (int o = 0; o < 8; o++)
          for (int x_color = WHITE; x_color <= BLACK; x_color++)
            for (int to_move = WHITE; to_move <= BLACK; to_move++) {
              char grid[3][3];
              int i, j;
              orient(&shapes[s], o, grid);
              int other = frees[f] == size / 2 ? 1 : size / 2;
              int placed = place(grid, size, frees[f], other, x_color, &i, &j);
              lcase(placed, "%s shape %d orientation %d size %d", kind, s, o, size);
              if (!placed) continue;
              unsigned got = move_features_at(i, j, to_move) & SHAPES;
              lcase(got == shapes[s].families,
                    "%s shape %d orientation %d size %d at %d,%d x %d to move %d: %u, want %u",
                    kind, s, o, size, i, j, x_color, to_move, got, shapes[s].families);
            }
    }
}

void test_shapes_in_the_middle() {
  check_shapes(interior, sizeof interior / sizeof interior[0], "interior");
}

void test_shapes_on_the_edge() {
  check_shapes(edge, sizeof edge / sizeof edge[0], "edge");
}

void test_shapes_in_the_corner() {
  check_shapes(corner, sizeof corner / sizeof corner[0], "corner");
}

// An occupied centre has no features, whatever its neighbours.
void test_an_occupied_point_has_no_features() {
  const char *rows[] = {".....", ".XOX.", "..X..", ".....", "....."};
  setup(rows);
  lok(pattern3_families(pattern3_code(2, 2, BLACK)) == HANE);
  lequal((int)move_features_at(2, 2, BLACK), 0);
  lequal((int)move_features_at(2, 2, WHITE), 0);
  // The same neighbours around an empty centre: a hane.
  const char *empty[] = {".....", ".XOX.", ".....", ".....", "....."};
  setup(empty);
  lequal((int)(move_features_at(2, 2, BLACK) & SHAPES), (int)HANE);
}

/* Points the engine would not play. */

// The corner cut (own stones on both sides, an opponent stone on the
// diagonal) is in michi's cut set, but the engine plays it for neither
// player: for the player whose stones they are it is an own eye (the
// opponent's suicide point, touching no opponent stone), for the other a
// suicide. In every orientation and on every size.
void test_refused_corner_cut() {
  static const shape s = {{"###", "#.X", "#XO"}, 2};
  for (int z = 0; z < 3; z++)
    for (int o = 0; o < 8; o++)
      for (int x_color = WHITE; x_color <= BLACK; x_color++) {
        char grid[3][3];
        int i, j;
        orient(&s, o, grid);
        lcase(place(grid, sizes[z], 1, 1, x_color, &i, &j), "orientation %d size %d", o, sizes[z]);
        lcase(pattern3_families(pattern3_code(i, j, x_color)) == CUT, "orientation %d", o);
        lcase(pattern3_families(pattern3_code(i, j, OTHER_COLOR(x_color))) == CUT, "orientation %d", o);
        lcase(!move_allowed(i, j, x_color), "orientation %d", o);
        lcase(!move_allowed(i, j, OTHER_COLOR(x_color)), "orientation %d", o);
        lcase(move_features_at(i, j, x_color) == 0, "own eye, orientation %d size %d", o, sizes[z]);
        lcase(move_features_at(i, j, OTHER_COLOR(x_color)) == 0, "suicide, orientation %d size %d", o, sizes[z]);
      }
}

// The opponent's suicide point is still played when it touches an opponent
// stone (here it captures it), and then has its features; for the opponent
// it is a suicide and has none.
void test_own_eye_exception() {
  const char *rows[] = {".X...", "OX...", "X....", ".....", "....."};
  setup(rows);
  lok(suicide(0, 0, WHITE));
  lok(pattern3_families(pattern3_code(0, 0, BLACK)) == EDGE);
  lok(move_allowed(0, 0, BLACK));
  lequal((int)(move_features_at(0, 0, BLACK) & SHAPES), (int)EDGE);
  lok(move_features_at(0, 0, BLACK) & CAPTURE);
  lok(!move_allowed(0, 0, WHITE));
  lequal((int)move_features_at(0, 0, WHITE), 0);
}

// The illegal ko recapture has no features; once the ko is gone the same
// point has them.
void test_ko_point() {
  const char *rows[] = {"O.O..", "XO...", ".....", ".....", "....."};
  setup(rows);
  play_move(0, 1, BLACK); // captures the white stone in the corner
  lequal(get_board(0, 0), EMPTY);
  lok(!legal_move(0, 0, WHITE));
  lok(pattern3_families(pattern3_code(0, 0, WHITE)) == CUT);
  lequal((int)move_features_at(0, 0, WHITE), 0);
  // Black may fill the ko: white could take there, so it is no own eye.
  lequal((int)(move_features_at(0, 0, BLACK) & SHAPES), (int)CUT);
  // Moves elsewhere end the ko.
  play_move(4, 4, WHITE);
  play_move(3, 3, BLACK);
  lok(legal_move(0, 0, WHITE));
  lequal((int)(move_features_at(0, 0, WHITE) & SHAPES), (int)CUT);
}

// The code reads the 8 neighbours in row order, off the board as its own
// state, and colours from the mover's view.
void test_pattern3_code() {
  const char *rows[] = {"XO...", ".....", ".....", ".....", "....."};
  setup(rows);
  // Centre (1,1): neighbours (0,0) X, (0,1) O, the rest empty.
  lequal((int)pattern3_code(1, 1, BLACK), NEIGHBOUR_OWN | NEIGHBOUR_OPPONENT << 2);
  lequal((int)pattern3_code(1, 1, WHITE), NEIGHBOUR_OPPONENT | NEIGHBOUR_OWN << 2);
  // Centre (1,0): the left column is off the board; (0,0) is up, (0,1) up right.
  unsigned off = NEIGHBOUR_OFF_BOARD;
  lequal((int)pattern3_code(1, 0, BLACK),
         (int)(off | NEIGHBOUR_OWN << 2 | NEIGHBOUR_OPPONENT << 4 | off << 6 | off << 10));
}

/* Tactics. */

// The move features of every point, from move_features_board.
static unsigned board_bits[MAX_BOARD * MAX_BOARD];

static unsigned features_of(int i, int j, int color) {
  move_features_board(color, ALL_FEATURES, board_bits);
  return board_bits[POS(i, j)];
}

// Black takes a ko: a capture, and not self-atari although the stone is
// left with one liberty. White cannot take back at once, so the point has
// no features for it.
void test_ko_capture() {
  const char *rows[] = {
    ".......",
    "..XO...",
    ".XO.O..",
    "..XO...",
    ".......",
    ".......",
    ".......",
  };
  setup(rows);
  unsigned f = features_of(2, 3, BLACK);
  lok(f & CAPTURE);
  lok(!(f & SELF_ATARI));
  lok(!(f & SAVES_ATARI));
  lequal((int)(move_features_at(2, 3, BLACK) & ~SHAPES), (int)CAPTURE);
  play_move(2, 3, BLACK);
  lequal(get_board(2, 2), EMPTY);
  lequal((int)move_features_at(2, 2, WHITE), 0);
}

// A capture that leaves the capturing chain with one liberty: a capture,
// not self-atari; and it does not save the black chain that was in atari,
// which still has one liberty. For white the same point captures the black
// chain and saves the white stone in atari.
void test_capture_leaving_one_liberty() {
  const char *rows[] = {"OXO..", ".XO..", "OO...", ".....", "....."};
  setup(rows);
  unsigned f = features_of(1, 0, BLACK);
  lok(f & CAPTURE);
  lok(!(f & SELF_ATARI));
  lok(!(f & SAVES_ATARI));
  unsigned w = features_of(1, 0, WHITE);
  lok(w & CAPTURE);
  lok(!(w & SELF_ATARI));
  lok(w & SAVES_ATARI);
  // The move itself: the chain is left with the captured point only.
  play_move(1, 0, BLACK);
  lequal(chain_liberties(1, 0), 1);
}

// The black stone in atari at (2,1) is saved by capturing the white stone
// at (2,2) from (2,3), which does not touch it, and by extending to (3,1).
void test_saves_atari_by_capturing_away() {
  const char *rows[] = {
    ".......",
    ".OX....",
    "OXO....",
    "..X....",
    ".......",
    ".......",
    ".......",
  };
  setup(rows);
  lequal(chain_liberties(2, 1), 1);
  lequal(chain_liberties(2, 2), 1);
  unsigned f = features_of(2, 3, BLACK);
  lok(f & CAPTURE);
  lok(f & SAVES_ATARI);
  lok(!(f & SELF_ATARI));
  unsigned e = features_of(3, 1, BLACK);
  lok(e & SAVES_ATARI);
  lok(!(e & CAPTURE));
  lok(!(e & SELF_ATARI));
  // Elsewhere nothing is saved.
  lok(!(features_of(5, 5, BLACK) & SAVES_ATARI));
}

// Extending a stone in atari along the edge into one more liberty only:
// not saved, and self-atari. For white the same point captures it.
void test_extension_that_does_not_save() {
  const char *rows[] = {"XO...", ".O...", ".....", ".....", "....."};
  setup(rows);
  lequal(chain_liberties(0, 0), 1);
  unsigned f = features_of(1, 0, BLACK);
  lok(!(f & SAVES_ATARI));
  lok(f & SELF_ATARI);
  lok(!(f & CAPTURE));
  unsigned w = features_of(1, 0, WHITE);
  lok(w & CAPTURE);
  lok(!(w & SELF_ATARI));
  lok(!(w & SAVES_ATARI));
}

// Filling the own last liberty but one in the middle of the board.
void test_self_atari() {
  const char *rows[] = {".....", "..O..", ".O.O.", ".....", "....."};
  setup(rows);
  // Black at (2,2) has one liberty, (3,2): self-atari.
  unsigned f = features_of(2, 2, BLACK);
  lok(f & SELF_ATARI);
  lok(!(f & CAPTURE));
  // White there has 4 liberties as a chain of four.
  lok(!(features_of(2, 2, WHITE) & SELF_ATARI));
  // An open point is no self-atari.
  lok(!(features_of(4, 4, BLACK) & SELF_ATARI));
}

/* The last move. */

static int all_near_last(int color, int *count) {
  move_features_board(color, ALL_FEATURES, board_bits);
  int n = 0;
  for (int p = 0; p < board_size * board_size; p++)
    if (board_bits[p] & NEAR_LAST) n++;
  *count = n;
  return n;
}

// near_last is set at the 8 points around the opponent's last stone where
// the engine would play, including one whose trial move captures; the
// trial moves do not become the last move.
void test_near_last_with_a_capture() {
  const char *rows[] = {
    ".......",
    "..XO...",
    ".XO....",
    "..XO...",
    ".......",
    ".......",
    ".......",
  };
  setup(rows);
  play_move(2, 4, WHITE);
  int n;
  all_near_last(BLACK, &n);
  lequal(n, 6); // the 8 around (2,4) but the stones at (1,3) and (3,3)
  // (2,3), captures the ko stone, next to the last stone.
  lok(board_bits[POS(2, 3)] & CAPTURE);
  lok(board_bits[POS(2, 3)] & NEAR_LAST);
  // (1,3) and (3,3) are stones: no features.
  lequal((int)board_bits[POS(1, 3)], 0);
  // Two points away: not near.
  lok(!(board_bits[POS(2, 6)] & NEAR_LAST));
  for (int di = -1; di <= 1; di++)
    for (int dj = -1; dj <= 1; dj++)
      if ((di || dj) && get_board(2 + di, 4 + dj) == EMPTY)
        lcase(board_bits[POS(2 + di, 4 + dj)] & NEAR_LAST, "near %d,%d", 2 + di, 4 + dj);
  int i, j, c;
  lequal(last_move(&i, &j, &c), LAST_MOVE_POINT);
  lequal(i, 2);
  lequal(j, 4);
  lequal(c, WHITE);
  // The board is unchanged.
  lequal(get_board(2, 2), WHITE);
  lequal(get_board(2, 3), EMPTY);
  // For white the last stone is its own: nothing is near.
  all_near_last(WHITE, &n);
  lequal(n, 0);
}

// The last_move plane and opponent_passed of the inputs, for a mask with
// only the last_move group: [komi][N stones][N near_last][N last_move]
// [opponent_passed].
static double inputs[4400];

static void last_move_inputs(int color, double **near, double **plane, double *passed) {
  int points = board_size * board_size;
  int n = feature_inputs(ANN_GROUP_LAST_MOVE, color, inputs, NULL);
  lequal(n, ann_layout_inputs(ANN_GROUP_LAST_MOVE, points));
  *near = inputs + 1 + points;
  *plane = inputs + 1 + 2 * points;
  *passed = inputs[1 + 3 * points];
}

static int count_nonzero(const double *plane) {
  int n = 0;
  for (int p = 0; p < board_size * board_size; p++)
    if (plane[p] != 0) n++;
  return n;
}

void test_last_move_inputs() {
  const char *rows[] = {".....", ".....", ".....", ".....", "....."};
  double *near, *plane, passed;
  setup(rows);

  // At the start: nothing.
  last_move_inputs(BLACK, &near, &plane, &passed);
  lequal(count_nonzero(near), 0);
  lequal(count_nonzero(plane), 0);
  lok(passed == 0);

  // After white's stone: its point in the plane, for black only.
  play_move(1, 1, WHITE);
  last_move_inputs(BLACK, &near, &plane, &passed);
  lequal(count_nonzero(plane), 1);
  lok(plane[POS(1, 1)] == 1);
  lequal(count_nonzero(near), 8);
  lok(near[POS(0, 0)] == 1 && near[POS(2, 2)] == 1);
  lok(passed == 0);
  last_move_inputs(WHITE, &near, &plane, &passed);
  lequal(count_nonzero(plane), 0);
  lequal(count_nonzero(near), 0);
  lok(passed == 0);

  // After white's pass: opponent_passed for black, nothing else.
  play_pass(WHITE);
  last_move_inputs(BLACK, &near, &plane, &passed);
  lequal(count_nonzero(plane), 0);
  lequal(count_nonzero(near), 0);
  lok(passed == 1);
  last_move_inputs(WHITE, &near, &plane, &passed);
  lok(passed == 0);
  lequal(count_nonzero(plane), 0);

  // After a black stone in the corner: 3 points near it for white.
  play_move(0, 4, BLACK);
  last_move_inputs(WHITE, &near, &plane, &passed);
  lequal(count_nonzero(plane), 1);
  lok(plane[POS(0, 4)] == 1);
  lequal(count_nonzero(near), 3);
  lok(near[POS(0, 3)] == 1 && near[POS(1, 3)] == 1 && near[POS(1, 4)] == 1);
  lok(passed == 0);
}

// A suicide leaves no stone: nothing is near the empty point.
void test_last_move_after_a_suicide() {
  const char *rows[] = {".X...", "X....", ".....", ".....", "....."};
  double *near, *plane, passed;
  setup(rows);
  lok(suicide(0, 0, WHITE));
  play_move(0, 0, WHITE);
  lequal(get_board(0, 0), EMPTY);
  lequal(last_move(NULL, NULL, NULL), LAST_MOVE_POINT);
  last_move_inputs(BLACK, &near, &plane, &passed);
  lequal(count_nonzero(plane), 0);
  lequal(count_nonzero(near), 0);
  lok(passed == 0);
}

// Handicap stones are not moves.
void test_last_move_after_handicap() {
  double *near, *plane, passed;
  board_size = 9;
  new_game();
  place_fixed_handicap(4);
  last_move_inputs(WHITE, &near, &plane, &passed);
  lequal(count_nonzero(plane), 0);
  lequal(count_nonzero(near), 0);
  lok(passed == 0);
  board_size = 19;
  new_game();
  place_fixed_handicap(9);
  last_move_inputs(WHITE, &near, &plane, &passed);
  lequal(count_nonzero(plane), 0);
  lequal(count_nonzero(near), 0);
}

/* Liberties. */

// Each stone is +1 (own) or -1 (opponent) in the plane of its chain's
// liberties (1, 2, 3 or more), for the player to move; empty points are 0
// in all three.
void test_liberty_planes() {
  const char *rows[] = {
    "XO...",  // (0,0) X: 1 liberty; (0,1) O: 2
    ".....",
    "..XX.",  // a black chain of 2: 6
    "O...O",  // (3,0) O: 3; (3,4) O: 2
    "....X",  // (4,4) X: 1
  };
  setup(rows);
  int points = 25;
  struct { int i, j, libs, black; } want[] = {
    {0, 0, 1, 1}, {0, 1, 2, 0}, {2, 2, 6, 1}, {2, 3, 6, 1}, {3, 0, 3, 0}, {3, 4, 2, 0}, {4, 4, 1, 1},
  };
  int stones = sizeof want / sizeof want[0];
  for (int k = 0; k < stones; k++)
    lcase(chain_liberties(want[k].i, want[k].j) == want[k].libs, "liberties at %d,%d: %d",
          want[k].i, want[k].j, chain_liberties(want[k].i, want[k].j));
  lequal(chain_liberties(1, 1), 0);
  for (int color = WHITE; color <= BLACK; color++) {
    int n = feature_inputs(ANN_GROUP_LIBERTIES, color, inputs, NULL);
    lequal(n, 1 + 25 + 75);
    double *plane[3] = {inputs + 26, inputs + 26 + points, inputs + 26 + 2 * points};
    for (int k = 0; k < stones; k++) {
      int p = POS(want[k].i, want[k].j);
      int in = (want[k].libs > 3 ? 3 : want[k].libs) - 1;
      double sign = (want[k].black ? BLACK : WHITE) == color ? 1 : -1;
      for (int l = 0; l < 3; l++) {
        double v = l == in ? sign : 0;
        lcase(plane[l][p] == v, "color %d plane %d at %d,%d: %g, want %g", color, l, want[k].i, want[k].j, plane[l][p], v);
      }
    }
    int nonzero = count_nonzero(plane[0]) + count_nonzero(plane[1]) + count_nonzero(plane[2]);
    lequal(nonzero, stones);
  }
}

/* The layout. */

// Every group mask on 5x5, 9x9, and 19x19: the size, komi and the stones
// first, then each plane in the layout's order holding what the parts say
// (move_features_board, chain_liberties, last_move), and nothing written
// beyond the layout.
void test_input_layout() {
  for (int z = 0; z < 3; z++) {
    int size = sizes[z];
    board_size = size;
    new_game();
    // A few stones, a chain in atari, and a white last move.
    play_move(0, 0, BLACK);
    play_move(0, 1, WHITE);
    play_move(1, 1, BLACK);
    play_move(size - 1, size - 1, WHITE);
    play_move(size - 2, size - 1, BLACK);
    play_move(2, 2, WHITE);
    komi = 6.5;
    int points = size * size;
    for (unsigned groups = 0; groups <= ANN_GROUPS_ALL; groups++)
      for (int color = WHITE; color <= BLACK; color++) {
        int expected = ann_layout_inputs(groups, points);
        for (int k = 0; k < 4400; k++) inputs[k] = 99;
        unsigned bits[MAX_BOARD * MAX_BOARD];
        int n = feature_inputs(groups, color, inputs, bits);
        lcase(n == expected, "groups %u size %d: %d inputs, want %d", groups, size, n, expected);
        lcase(inputs[expected] == 99, "groups %u size %d: wrote beyond", groups, size);
        lcase(inputs[0] == (color == WHITE ? 6.5 : -6.5), "komi");
        int k = 1;
        for (int p = 0; p < points; p++, k++) {
          int v = get_board(I(p), J(p));
          double want = v == EMPTY ? 0 : v == color ? 1 : -1;
          lcase(inputs[k] == want, "stone at %d", p);
        }
        unsigned wanted = group_features(groups);
        move_features_board(color, ALL_FEATURES, board_bits);
        for (int f = 0; f < MOVE_FEATURES; f++) {
          if (!(wanted & FEATURE_BIT(f))) continue;
          for (int p = 0; p < points; p++, k++) {
            double want = (board_bits[p] & FEATURE_BIT(f)) ? 1 : 0;
            lcase(inputs[k] == want, "groups %u size %d feature %d at %d", groups, size, f, p);
            lcase((bits[p] & FEATURE_BIT(f)) == (board_bits[p] & FEATURE_BIT(f)), "bits");
          }
        }
        for (int p = 0; p < points; p++)
          lcase((bits[p] & ~wanted) == 0, "groups %u: bit outside the groups at %d", groups, p);
        if (groups & ANN_GROUP_LIBERTIES)
          for (int l = 1; l <= 3; l++)
            for (int p = 0; p < points; p++, k++) {
              int v = get_board(I(p), J(p));
              int libs = v == EMPTY ? 0 : chain_liberties(I(p), J(p));
              if (libs > 3) libs = 3;
              double want = libs != l ? 0 : v == color ? 1 : -1;
              lcase(inputs[k] == want, "groups %u liberties %d at %d", groups, l, p);
            }
        if (groups & ANN_GROUP_LAST_MOVE) {
          for (int p = 0; p < points; p++, k++)
            lcase(inputs[k] == (color == BLACK && p == POS(2, 2) ? 1 : 0), "last_move at %d", p);
          lcase(inputs[k] == 0, "opponent_passed");
          k++;
        }
        lcase(k == expected, "groups %u: checked %d of %d", groups, k, expected);
      }
  }
}

// The groups' move features, in the tables' order.
void test_group_features() {
  lequal((int)group_features(0), 0);
  lequal((int)group_features(ANN_GROUP_SHAPES), (int)SHAPES);
  lequal((int)group_features(ANN_GROUP_TACTICS), (int)(CAPTURE | SELF_ATARI | SAVES_ATARI));
  lequal((int)group_features(ANN_GROUP_LAST_MOVE), (int)NEAR_LAST);
  lequal((int)group_features(ANN_GROUP_LIBERTIES), 0);
  lequal((int)group_features(ANN_GROUPS_ALL), (int)ALL_FEATURES);
  lequal(MOVE_FEATURES, ann_feature_count(ANN_GROUPS_ALL));
  for (unsigned groups = 0; groups <= ANN_GROUPS_ALL; groups++)
    lcase(__builtin_popcount(group_features(groups)) == ann_feature_count(groups), "groups %u", groups);
}

/* Against a reference. */

// The liberties of the chain at (i, j), by flood fill over get_board.
static int reference_liberties(int i, int j) {
  int color = get_board(i, j);
  static int seen[MAX_BOARD * MAX_BOARD], stack[MAX_BOARD * MAX_BOARD];
  memset(seen, 0, sizeof seen);
  int top = 0, libs = 0;
  stack[top++] = POS(i, j);
  seen[POS(i, j)] = 1;
  while (top) {
    int p = stack[--top];
    for (int k = 0; k < 4; k++) {
      int ni = I(p) + deltai[k], nj = J(p) + deltaj[k];
      if (!on_board(ni, nj) || seen[POS(ni, nj)]) continue;
      if (get_board(ni, nj) == EMPTY) {
        seen[POS(ni, nj)] = 1;
        libs++;
      } else if (get_board(ni, nj) == color) {
        seen[POS(ni, nj)] = 1;
        stack[top++] = POS(ni, nj);
      }
    }
  }
  return libs;
}

// The own stones in chains in atari, for reference_tactics.
static int atari[MAX_BOARD * MAX_BOARD];

static void find_atari(int color) {
  for (int p = 0; p < board_size * board_size; p++)
    atari[p] = get_board(I(p), J(p)) == color && reference_liberties(I(p), J(p)) == 1;
}

// The tactics by their definitions: play the move, compare the boards.
// find_atari(color) must have run on the position.
static unsigned reference_tactics(int i, int j, int color) {
  if (!move_allowed(i, j, color)) return 0;
  int points = board_size * board_size;
  int before[MAX_BOARD * MAX_BOARD];
  for (int p = 0; p < points; p++) before[p] = get_board(I(p), J(p));
  brown_state s;
  brown_save(&s);
  play_move(i, j, color);
  unsigned f = 0;
  int captured = 0;
  for (int p = 0; p < points; p++)
    if (before[p] == OTHER_COLOR(color) && get_board(I(p), J(p)) == EMPTY) captured = 1;
  if (captured) f |= CAPTURE;
  if (!captured && reference_liberties(i, j) == 1) f |= SELF_ATARI;
  for (int p = 0; p < points; p++)
    if (atari[p] && reference_liberties(I(p), J(p)) >= 2) f |= SAVES_ATARI;
  brown_restore(&s);
  return f;
}

// A small deterministic generator for the random positions.
static unsigned lcg_state;
static int next_random(int n) {
  lcg_state = lcg_state * 1103515245u + 12345u;
  return (int)((lcg_state >> 16) % (unsigned)n);
}

// Random games on 5x5, 9x9, and 19x19 (many chains in atari, captures,
// suicides refused by move_allowed, edges and corners): after every move,
// every point's tactics for both players agree with the reference, the
// liberty planes with reference_liberties, and computing them changes
// neither the board nor the last move.
void test_random_positions() {
  lcg_state = 1;
  int positions = 0, seen_capture = 0, seen_self_atari = 0, seen_saves = 0;
  for (int z = 0; z < 3; z++)
    for (int game = 0; game < (z == 2 ? 2 : 12); game++) {
      board_size = sizes[z];
      new_game();
      int points = board_size * board_size;
      for (int move = 0; move < points * 2; move++) {
        int color = move % 2 ? WHITE : BLACK;
        int p = next_random(points + 1);
        if (p == points || !move_allowed(I(p), J(p), color)) {
          // Try a few more before passing.
          int k;
          for (k = 0; k < 20; k++) {
            p = next_random(points);
            if (move_allowed(I(p), J(p), color)) break;
          }
          if (k == 20) {
            play_pass(color);
            continue;
          }
        }
        play_move(I(p), J(p), color);
        if (move % 3) continue;
        positions++;
        brown_state before;
        brown_save(&before);
        for (int to_move = WHITE; to_move <= BLACK; to_move++) {
          move_features_board(to_move, ALL_FEATURES, board_bits);
          find_atari(to_move);
          for (int q = 0; q < points; q++) {
            unsigned want = reference_tactics(I(q), J(q), to_move);
            unsigned got = board_bits[q] & (CAPTURE | SELF_ATARI | SAVES_ATARI);
            lcase(got == want, "size %d game %d move %d point %d,%d for %d: %u, want %u",
                  board_size, game, move, I(q), J(q), to_move, got, want);
            if (want & CAPTURE) seen_capture = 1;
            if (want & SELF_ATARI) seen_self_atari = 1;
            if (want & SAVES_ATARI) seen_saves = 1;
            if (get_board(I(q), J(q)) != EMPTY)
              lcase(chain_liberties(I(q), J(q)) == reference_liberties(I(q), J(q)), "liberties");
          }
          feature_inputs(ANN_GROUPS_ALL, to_move, inputs, NULL);
        }
        brown_state after;
        brown_save(&after);
        lcase(memcmp(&before, &after, sizeof before) == 0, "state changed at size %d move %d", board_size, move);
      }
    }
  lok(positions > 100);
  lok(seen_capture && seen_self_atari && seen_saves);
}

int main(void) {
  printf("Move features test suite\n");

  lrun("counts", test_table_counts);
  lrun("michi", test_tables_are_michis);
  lrun("symmetric", test_tables_are_symmetric);
  lrun("code", test_pattern3_code);
  lrun("middle", test_shapes_in_the_middle);
  lrun("edge", test_shapes_on_the_edge);
  lrun("corner", test_shapes_in_the_corner);
  lrun("occupied", test_an_occupied_point_has_no_features);
  lrun("corner_cut", test_refused_corner_cut);
  lrun("eye_exception", test_own_eye_exception);
  lrun("ko", test_ko_point);
  lrun("ko_capture", test_ko_capture);
  lrun("one_liberty", test_capture_leaving_one_liberty);
  lrun("saves_away", test_saves_atari_by_capturing_away);
  lrun("no_save", test_extension_that_does_not_save);
  lrun("self_atari", test_self_atari);
  lrun("near_last", test_near_last_with_a_capture);
  lrun("last_move", test_last_move_inputs);
  lrun("last_suicide", test_last_move_after_a_suicide);
  lrun("last_handicap", test_last_move_after_handicap);
  lrun("liberties", test_liberty_planes);
  lrun("layout", test_input_layout);
  lrun("groups", test_group_features);
  lrun("random", test_random_positions);

  lresults();
  return lfails != 0;
}
