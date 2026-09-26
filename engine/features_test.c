/*
 * Tests of the move features in features.c: michi's 3x3 shape tables
 * (hane, cut, edge) and their lookup on Brown's board, and that a feature is
 * 0 at a point the engine would not play. Linked with brown.o and features.o
 * alone, which also checks that features.o needs nothing else.
 */

#include <string.h>

#include "brown.h"
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
              unsigned got = move_features_at(i, j, to_move);
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
  lequal((int)move_features_at(2, 2, BLACK), (int)HANE);
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
  lequal((int)move_features_at(0, 0, BLACK), (int)EDGE);
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
  lequal((int)move_features_at(0, 0, BLACK), (int)CUT);
  // Moves elsewhere end the ko.
  play_move(4, 4, WHITE);
  play_move(3, 3, BLACK);
  lok(legal_move(0, 0, WHITE));
  lequal((int)move_features_at(0, 0, WHITE), (int)CUT);
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

  lresults();
  return lfails != 0;
}
