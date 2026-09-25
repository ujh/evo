#!/bin/sh
set -eu

# Checks that the arena (engine/arena) plays and scores a game as GoGui
# does. Seeded random networks play a fixed sample of pairings, with both
# colors, once through the arena and once through gogui-twogtp with evo and
# the GNU Go referee, at the same komi and move limit. The check fails when
#   - the moves or the length of a game differ;
#   - the arena's result differs from a Tromp-Taylor count, made here, of
#     the final position of twogtp's game (loaded into GNU Go);
#   - on a game ended by two passes in which GNU Go finds no dead stones,
#     the arena's winner differs from the referee's;
#   - fewer than $min_compared games reach that comparison;
#   - twogtp reports an error other than the move limit, or no referee
#     result.
# Other winner differences are expected: the Tromp-Taylor count keeps dead
# stones on the board, and at the move limit the referee judges an
# unfinished position. They are counted and printed only.

root=$(cd "$(dirname "$0")/.." && pwd)
arena="$root/engine/arena"
evo="$root/engine/evo"
generator="$root/initial-population/initial-population"
for program in "$arena" "$evo" "$generator"; do
  if [ ! -x "$program" ]; then
    printf 'build %s first (mise run build)\n' "$program" >&2
    exit 1
  fi
done

scratch=$(mktemp -d "${TMPDIR:-/tmp}/evo-arena-agreement.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM

komi=6.5
referee='gnugo --mode gtp --chinese-rules'
# The sample below yields 10 such games; fewer means the sample or the
# networks changed so that the winner comparison no longer tests much.
min_compared=5

failed=0
fail() {
  printf '%s\n' "$*" >&2
  failed=1
}

games=0
same_moves=0
same_count=0
compared=0
agreed=0
dead_games=0
dead_differ=0
limit_games=0
limit_differ=0

# The winner of a result such as B+3.5, W+0.5, or 0.
winner() {
  case $1 in
    B+*) printf 'B' ;;
    W+*) printf 'W' ;;
    *) printf '%s' "$1" ;;
  esac
}

# field LINE KEY: the value of KEY=... in a tab-separated arena line.
field() {
  printf '%s\n' "$1" | awk -F '\t' -v key="$2=" '
    { for (i = 1; i <= NF; i++) if (index($i, key) == 1) print substr($i, length(key) + 1) }
  '
}

# The moves of an SGF game as GTP vertices (C3, pass), comma-separated.
# SGF counts columns from the left and rows from the top; GTP skips the
# letter I and counts rows from the bottom.
sgf_moves() {
  awk -v size="$2" '
    { s = s $0 }
    END {
      letters = "ABCDEFGHJKLMNOPQRSTUVWXYZ"
      out = ""
      while (match(s, /;[BW]\[([a-z][a-z])?\]/)) {
        node = substr(s, RSTART, RLENGTH)
        s = substr(s, RSTART + RLENGTH)
        if (length(node) == 4) {
          move = "pass"
        } else {
          x = index("abcdefghijklmnopqrstuvwxyz", substr(node, 4, 1))
          y = index("abcdefghijklmnopqrstuvwxyz", substr(node, 5, 1))
          if (x > size || y > size) move = "pass"
          else move = substr(letters, x, 1) (size - y + 1)
        }
        out = out (out == "" ? "" : ",") move
      }
      print out
    }
  ' "$1"
}

# tromp_taylor SIZE BLACK WHITE: the Tromp-Taylor result of a position given
# as two lists of GTP vertices: each color's stones plus the empty regions
# that border only that color, black minus white minus komi.
tromp_taylor() {
  awk -v size="$1" -v komi="$komi" -v black="$2" -v white="$3" '
    function place(list, color,    n, k, v, x, y) {
      n = split(list, v, " ")
      for (k = 1; k <= n; k++) {
        x = index("ABCDEFGHJKLMNOPQRSTUVWXYZ", toupper(substr(v[k], 1, 1)))
        y = substr(v[k], 2) + 0
        board[x, y] = color
      }
    }
    BEGIN {
      place(black, "b")
      place(white, "w")
      score["b"] = 0
      score["w"] = 0
      for (x = 1; x <= size; x++) {
        for (y = 1; y <= size; y++) {
          if ((x, y) in board) {
            score[board[x, y]]++
            continue
          }
          if ((x, y) in seen) continue
          # Flood the empty region from (x, y).
          top = 0
          stack_x[++top] = x
          stack_y[top] = y
          seen[x, y] = 1
          points = 0
          borders = ""
          while (top > 0) {
            px = stack_x[top]
            py = stack_y[top--]
            points++
            for (d = 0; d < 4; d++) {
              nx = px + (d == 0) - (d == 1)
              ny = py + (d == 2) - (d == 3)
              if (nx < 1 || ny < 1 || nx > size || ny > size) continue
              if ((nx, ny) in board) {
                if (index(borders, board[nx, ny]) == 0) borders = borders board[nx, ny]
              } else if (!((nx, ny) in seen)) {
                seen[nx, ny] = 1
                stack_x[++top] = nx
                stack_y[top] = ny
              }
            }
          }
          if (borders == "b" || borders == "w") score[borders] += points
        }
      }
      margin = score["b"] - score["w"] - komi
      if (margin > 0) printf "B+%.1f\n", margin
      else if (margin < 0) printf "W+%.1f\n", -margin
      else print "0"
    }
  '
}

# gnugo_answers SGF SIZE: loads the game into GNU Go and writes the answers
# to list_stones black, list_stones white, and final_status_list dead, one
# per line, to $scratch/answers. Fails when GNU Go refuses a command.
gnugo_answers() {
  printf 'boardsize %s\nloadsgf %s\nlist_stones black\nlist_stones white\nfinal_status_list dead\nquit\n' \
    "$2" "$1" | $referee 2>/dev/null | awk '
      /^[=?]/ {
        if ($0 ~ /^\?/) bad = 1
        n++
        answer[n] = substr($0, 3)
        next
      }
      NF > 0 && n > 0 { answer[n] = answer[n] " " $0 }
      END {
        if (bad || n != 6) exit 1
        for (k = 3; k <= 5; k++) print answer[k]
      }
    ' >"$scratch/answers"
}

# check_game SIZE MAX_MOVES ID BLACK WHITE: compares the game twogtp played
# with the arena's line for ID in $scratch/arena-SIZE.
check_game() {
  size=$1
  max_moves=$2
  id=$3
  games=$((games + 1))
  line=$(grep "^$id	" "$scratch/arena-$size" || true)
  if [ -z "$line" ] || [ -n "$(field "$line" error)" ]; then
    fail "$id: the arena did not play it: $line"
    return
  fi
  result=$(field "$line" result)
  end=$(field "$line" end)
  length=$(field "$line" length)
  moves=$(field "$line" moves)

  prefix="$scratch/$id"
  if [ ! -f "$prefix.dat" ] || [ ! -f "$prefix-0.sgf" ]; then
    fail "$id: twogtp wrote no result: $(cat "$prefix.err")"
    return
  fi
  # RES_R, LEN, ERR, and ERR_MSG, one per line, since any may be empty.
  awk -F '\t' '!/^#/ { print $4; print $7; print $12; print $13 }' "$prefix.dat" >"$prefix.row"
  referee_result=''
  twogtp_length=''
  error=''
  message=''
  { read -r referee_result; read -r twogtp_length; read -r error; read -r message; } <"$prefix.row" || true
  if [ "${error:-}" != 0 ] && [ "${message:-}" != 'move limit exceeded' ]; then
    fail "$id: twogtp error: ${message:-none given}"
    return
  fi
  case ${referee_result:-} in
    B+* | W+* | 0) ;;
    *)
      fail "$id: no referee result: ${referee_result:-}"
      return
      ;;
  esac
  # A game that twogtp stopped at the move limit ended by the limit in the
  # arena too, and a game that ended by passes did not.
  if [ "$message" = 'move limit exceeded' ]; then twogtp_end=limit; else twogtp_end=passes; fi

  twogtp_moves=$(sgf_moves "$prefix-0.sgf" "$size")
  if [ "$moves" = "$twogtp_moves" ] && [ "$length" = "$twogtp_length" ] && [ "$end" = "$twogtp_end" ]; then
    same_moves=$((same_moves + 1))
  else
    fail "$id: the games differ:
  arena  $end, $length moves: $moves
  twogtp $twogtp_end, $twogtp_length moves: $twogtp_moves"
  fi

  if ! gnugo_answers "$prefix-0.sgf" "$size"; then
    fail "$id: GNU Go could not load or list the final position"
    return
  fi
  { read -r black; read -r white; read -r dead; } <"$scratch/answers"
  count=$(tromp_taylor "$size" "$black" "$white")
  if [ "$result" = "$count" ]; then
    same_count=$((same_count + 1))
  else
    fail "$id: the arena scored $result, the Tromp-Taylor count of twogtp's final position is $count"
  fi

  differ=0
  if [ "$(winner "$result")" != "$(winner "$referee_result")" ]; then differ=1; fi
  if [ "$end" = limit ]; then
    limit_games=$((limit_games + 1))
    limit_differ=$((limit_differ + differ))
  elif [ -n "$(printf '%s' "$dead" | tr -d ' ')" ]; then
    dead_games=$((dead_games + 1))
    dead_differ=$((dead_differ + differ))
  else
    compared=$((compared + 1))
    if [ "$differ" -eq 0 ]; then
      agreed=$((agreed + 1))
    else
      fail "$id: two passes and no dead stones, but the arena scored $result and the referee $referee_result"
    fi
  fi
}

# sample SIZE MAX_MOVES COUNT SEED: COUNT networks with one hidden layer of
# 20 neurons from SEED, every ordered pairing of two of them played in the
# arena, and the games added to $scratch/games for twogtp.
sample() {
  size=$1
  population="$scratch/networks-$size"
  mkdir "$population"
  (cd "$population" && "$generator" "$3" "$size" 1 20 "$4" >/dev/null)
  : >"$scratch/schedule-$size"
  for black in "$population"/*.ann; do
    for white in "$population"/*.ann; do
      if [ "$black" != "$white" ]; then
        printf '%sx%s-%s-%s %s %s\n' "$size" "$size" "$(basename "$black" .ann)" \
          "$(basename "$white" .ann)" "$black" "$white" >>"$scratch/schedule-$size"
      fi
    done
  done
  if ! "$arena" "$size" "$komi" "$2" "$scratch/schedule-$size" >"$scratch/arena-$size" </dev/null; then
    fail "the arena failed on the ${size}x$size sample"
  fi
  while read -r id black white; do
    printf '%s %s %s %s %s\n' "$size" "$2" "$id" "$black" "$white" >>"$scratch/games"
  done <"$scratch/schedule-$size"
}

# Plays every game in $scratch/games through twogtp, in $lanes processes
# at once, each writing $scratch/ID.dat, ID-0.sgf, and ID.err.
play_twogtp() {
  lane=0
  while [ "$lane" -lt "$lanes" ]; do
    awk -v lanes="$lanes" -v lane="$lane" 'NR % lanes == lane' "$scratch/games" |
      while read -r size max_moves id black white; do
        gogui-twogtp -black "$evo $black" -white "$evo $white" -referee "$referee" \
          -games 1 -size "$size" -komi "$komi" -maxmoves "$max_moves" -auto -force \
          -sgffile "$scratch/$id" </dev/null >/dev/null 2>"$scratch/$id.err" || true
      done &
    lane=$((lane + 1))
  done
  wait
}

: >"$scratch/games"
sample 9 120 5 7
sample 5 40 8 7
lanes=4
play_twogtp
while read -r size max_moves id black white; do
  check_game "$size" "$max_moves" "$id" "$black" "$white"
done <"$scratch/games"

printf 'Arena agreement: %d games, moves identical in %d, Tromp-Taylor recount identical in %d\n' \
  "$games" "$same_moves" "$same_count"
printf '  two passes, no dead stones: %d compared, %d agree with the referee (minimum %d)\n' \
  "$compared" "$agreed" "$min_compared"
printf '  winner differs from the referee, not a failure: %d of %d with dead stones, %d of %d at the move limit\n' \
  "$dead_differ" "$dead_games" "$limit_differ" "$limit_games"
if [ "$compared" -lt "$min_compared" ]; then
  fail "only $compared games ended by two passes with no dead stones; need $min_compared"
fi
if [ "$failed" -ne 0 ]; then
  printf 'The arena disagrees with GoGui and GNU Go\n' >&2
  exit 1
fi
printf 'The arena plays and scores as GoGui and GNU Go do\n'
