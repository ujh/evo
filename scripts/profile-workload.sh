#!/bin/sh
set -eu

# Profiles one of the two fixed workloads of docs/performance.md
# ("Fixed workloads"): creates the workload's experiment, runs generations
# 0 and 1 as two `mise run run NAME CONCURRENCY one-generation`
# invocations, records per invocation the command line, the runner's
# timings line, wall time, peak RSS, the runner's CPU time and GC totals,
# game counts, disk use, and the arena's load time over the generation's
# networks, writes it all to a results file, prints a summary, and deletes
# the experiment.
#
# The workloads keep their panel when the defaults change: after creating
# the experiment, and before any run, the script replaces its opponents
# and benchmark panel with those the workloads were defined with (the
# pinned panel below): tournament Brown `brown` x5 and AmiGo `amigogtp`
# x10; benchmark Brown, AmiGo, GnuGoLevel0 `gnugo --level 0 --mode gtp`,
# Gen0Champion, PreviousCheckpoint. It then checks that the database holds
# the requested panel (the pinned one, or the defaults with
# --default-panel), exits if not, and names the stored panel in the
# summary.
#
#   scripts/profile-workload.sh small|large [--results FILE] [--keep] [--tiny] [--default-panel]
#
# --results FILE  where the results go (default
#                 ${TMPDIR:-/tmp}/evo-profile-WORKLOAD-TIMESTAMP.txt); each
#                 invocation's full output goes next to it as FILE.genN.log.
# --keep          keep the experiment afterwards (default: delete it).
# --tiny          a 4-network, 2-round, 2-benchmark-game version, only to
#                 test this script. It is not the workload and its numbers
#                 mean nothing.
# --default-panel the panels a new experiment gets today (SetupExperiment's
#                 defaults) instead of the pinned one, to measure what the
#                 defaults cost against it.
#
# Numbers that are recorded need a quiet machine (see docs/performance.md).
# On Ctrl-C or a failed invocation the experiment is kept for inspection.

usage() {
  printf 'usage: %s small|large [--results FILE] [--keep] [--tiny] [--default-panel]\n' "$0" >&2
  exit 2
}

root=$(cd "$(dirname "$0")/.." && pwd)
# A relative --results path is relative to the caller's directory.
caller=$(pwd)
cd "$root"

[ $# -ge 1 ] || usage
workload=$1
shift
results=''
keep=0
tiny=0
default_panel=0
while [ $# -gt 0 ]; do
  case $1 in
    --results) [ $# -ge 2 ] || usage; results=$2; shift 2 ;;
    --keep) keep=1; shift ;;
    --tiny) tiny=1; shift ;;
    --default-panel) default_panel=1; shift ;;
    *) usage ;;
  esac
done

# The workloads. Settings are those of the experiments they are modeled on
# (bigrun and even-bigger), with keep_every 1 so generation 0 runs the
# benchmark; the seeds are those experiments' seeds. Concurrency 3: the
# M3 has only 4 performance cores, and the OS and other work need one
# (owner, 29 Sep 2026; docs/performance.md).
concurrency=3
case $workload in
  small)
    seed=777
    min_free_gib=2
    settings="--board-size 9 --population-size 50 --hidden-layers 1 --layer-size 100
      --max-hidden-layers 3 --max-layer-size 150 --features shapes,tactics,last_move,liberties
      --cross-over-rate 0.5 --game-length 10 --max-moves 200 --tournament-rounds 10
      --tournament-size 3 --keep-every 1 --benchmark-games 20 --benchmark-opening-moves 4
      --komi 6.5 --meta-rate 0.2 --initial-copy-chance 0.01 --initial-weight-changes 42.3128
      --initial-weight-step 0.5 --initial-activation-rate 0.05 --initial-structure-rate 0.1
      --initial-feature-noise 0.3 --initial-feature-step 0.01"
    ;;
  large)
    seed=5318103715471647440
    # Peak about 9 GiB: while generation 1 is bred, networks/0/ and
    # networks/1.partial/ (4.3 GiB each) plus a small database.
    min_free_gib=15
    settings="--board-size 9 --population-size 1000 --hidden-layers 10 --layer-size 200
      --max-hidden-layers 100 --max-layer-size 1000 --features shapes,tactics,last_move,liberties
      --cross-over-rate 0.4 --game-length 10 --max-moves 200 --tournament-rounds 10
      --tournament-size 3 --keep-every 1 --benchmark-games 20 --benchmark-opening-moves 4
      --komi 6.5 --meta-rate 0.2 --initial-copy-chance 0.01 --initial-weight-changes 229.3128
      --initial-weight-step 0.5 --initial-activation-rate 0.02 --initial-structure-rate 0.02
      --initial-feature-noise 0.3 --initial-feature-step 0.01"
    ;;
  *) usage ;;
esac
name="profile-$workload"
if [ "$tiny" -eq 1 ]; then
  name="$name-tiny"
  min_free_gib=1
  # Later options win, so these replace the workload's values.
  settings="$settings --population-size 4 --tournament-rounds 2 --benchmark-games 2"
fi
experiment="$root/experiments/$name"

# The pinned panel, as SQL on the new experiment's database: the opponents
# and benchmark panel the workloads were defined with (docs/performance.md,
# "Fixed workloads"), before the michi levels and GNU Go joined the
# defaults.
pinned_panel_sql="begin;
  delete from opponents;
  insert into opponents (position, name, command, copies) values
    (0, 'Brown', 'brown', 5), (1, 'AmiGo', 'amigogtp', 10);
  delete from benchmark_opponents;
  insert into benchmark_opponents (position, name, kind, command) values
    (0, 'Brown', 'bot', 'brown'), (1, 'AmiGo', 'bot', 'amigogtp'),
    (2, 'GnuGoLevel0', 'bot', 'gnugo --level 0 --mode gtp'),
    (3, 'Gen0Champion', 'initial_champion', null),
    (4, 'PreviousCheckpoint', 'previous_checkpoint', null);
  commit;"
# The same panel as the rows the database must then hold, in sqlite3's
# output format (name|command|copies, then name|kind|command).
pinned_opponents='Brown|brown|5
AmiGo|amigogtp|10'
pinned_benchmark='Brown|bot|brown
AmiGo|bot|amigogtp
GnuGoLevel0|bot|gnugo --level 0 --mode gtp
Gen0Champion|initial_champion|
PreviousCheckpoint|previous_checkpoint|'
if [ "$default_panel" -eq 1 ]; then
  panel='default (SetupExperiment defaults)'
else
  panel='pinned (tournament Brown x5, AmiGo x10; benchmark Brown, AmiGo, GnuGoLevel0, Gen0Champion, PreviousCheckpoint)'
fi

[ -n "$results" ] || results="${TMPDIR:-/tmp}/evo-profile-$name-$(date +%Y%m%d-%H%M%S).txt"
case $results in /*) ;; *) results="$caller/$results" ;; esac
case $results in
  "$root"/*) printf 'the results file must be outside the repository: %s\n' "$results" >&2; exit 2 ;;
esac

os=$(uname -s)
case $os in
  Darwin) time_flag=-l ;;
  Linux) time_flag=-v ;;
  *) printf 'unsupported system %s\n' "$os" >&2; exit 1 ;;
esac
if ! /usr/bin/time "$time_flag" true >/dev/null 2>&1; then
  printf '/usr/bin/time %s does not work here (on Linux install GNU time)\n' "$time_flag" >&2
  exit 1
fi
command -v sqlite3 >/dev/null 2>&1 || { printf 'sqlite3 is missing\n' >&2; exit 1; }

if [ -e "$experiment" ]; then
  printf '%s exists; delete it first, the workload must start fresh\n' "$experiment" >&2
  exit 1
fi

mkdir -p "$root/experiments"
free_kib=$(df -Pk "$root/experiments" | awk 'NR == 2 { print $4 }')
free_gib=$(awk -v k="$free_kib" 'BEGIN { printf "%.1f", k / 1048576 }')
if awk -v k="$free_kib" -v min="$min_free_gib" 'BEGIN { exit !(k < min * 1048576) }'; then
  printf 'only %s GiB free for experiments/ (df), the %s workload needs at least %s GiB; nothing was created\n' \
    "$free_gib" "$workload" "$min_free_gib" >&2
  exit 1
fi

mkdir -p "$(dirname "$results")"
: > "$results"
out() { printf '%s\n' "$*" >> "$results"; }

sampler_pid=''
cleanup() { [ -z "$sampler_pid" ] || kill "$sampler_pid" 2>/dev/null || true; }
trap cleanup EXIT
trap 'printf "\ninterrupted; %s is kept, delete it when done\n" "$experiment" >&2; exit 130' INT TERM

out "# Workload profile: $workload$( [ "$tiny" -eq 0 ] || printf ' TINY TEST RUN, NOT THE WORKLOAD: its numbers mean nothing')"
out "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
out "git: $(git rev-parse HEAD)$(git diff --quiet HEAD 2>/dev/null || printf ' (uncommitted changes)')"
out "experiment: experiments/$name, seed $seed, concurrency $concurrency"
out "panel requested: $panel"
out "free disk before (df, experiments/): $free_gib GiB, required $min_free_gib GiB"
out ''
out '## Hardware'
if [ "$os" = Darwin ]; then
  out "model: $(sysctl -n hw.model) $(sysctl -n machdep.cpu.brand_string)"
  out "cores: $(sysctl -n hw.ncpu) ($(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || echo ?) performance, $(sysctl -n hw.perflevel1.physicalcpu 2>/dev/null || echo ?) efficiency)"
  out "ram: $(sysctl -n hw.memsize | awk '{ printf "%.1f GiB", $1 / 1073741824 }')"
  out "os: $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)"
else
  out "model: $(awk -F': ' '/^model name/ { print $2; exit }' /proc/cpuinfo)"
  out "cores: $(nproc)"
  out "ram: $(awk '/^MemTotal/ { printf "%.1f GiB", $2 / 1048576 }' /proc/meminfo)"
  out "os: $(uname -srm)"
fi
out ''

# Builds and checks the programs once, so the first invocation's build (the
# runner builds on an experiment's first run) and every invocation's doctor
# step (a dependency of `mise run run`) find nothing to do.
mise run build >/dev/null
mise run doctor >/dev/null

create="mise run new-experiment $name $(echo $settings) --seed $seed"
out '## Create'
out "command: $create"
# shellcheck disable=SC2086
mise run new-experiment "$name" $settings --seed "$seed" >> "$results" 2>&1
if [ "$default_panel" -eq 0 ]; then
  out 'panel: pinned, set with sqlite3 before any run'
  sqlite3 "$experiment/experiment.sqlite3" "$pinned_panel_sql"
else
  out 'panel: the defaults new-experiment stored'
fi
stored_opponents=$(sqlite3 "$experiment/experiment.sqlite3" 'select name, command, copies from opponents order by position')
stored_benchmark=$(sqlite3 "$experiment/experiment.sqlite3" 'select name, kind, command from benchmark_opponents order by position')
out 'opponents: name|command|copies'
printf '%s\n' "$stored_opponents" | sed 's/^/    /' >> "$results"
out 'benchmark_opponents: name|kind|command'
printf '%s\n' "$stored_benchmark" | sed 's/^/    /' >> "$results"

# Checks that the database holds the requested panel, so a pin that did not
# take cannot pass as the workload: the pinned rows above, or with
# --default-panel SetupExperiment's defaults.
if [ "$default_panel" -eq 1 ]; then
  expected=$(mise exec -- ruby -e 'require_relative "ruby/setup_experiment"
    SetupExperiment::DEFAULT_OPPONENTS.each { |o| puts [o[:name], o[:command], o[:copies]].join("|") }
    puts "--"
    SetupExperiment::DEFAULT_BENCHMARK.each { |b| puts [b[:name], b[:kind], b[:command]].join("|") }')
else
  expected=$(printf '%s\n--\n%s' "$pinned_opponents" "$pinned_benchmark")
fi
stored=$(printf '%s\n--\n%s' "$stored_opponents" "$stored_benchmark")
if [ "$stored" != "$expected" ]; then
  out "panel check FAILED: the database does not hold the requested panel; expected:"
  printf '%s\n' "$expected" | sed 's/^/    /' >> "$results"
  printf 'the panel in %s is not the requested one (%s); stored (opponents, --, benchmark_opponents):\n%s\nexpected:\n%s\n%s is kept.\n' \
    "$experiment/experiment.sqlite3" "$panel" "$stored" "$expected" "$experiment" >&2
  exit 1
fi
# What the summary names: the stored panel itself, read back from the
# database.
stored_panel="$( [ "$default_panel" -eq 1 ] && printf default || printf pinned ), checked against the database: tournament $(sqlite3 "$experiment/experiment.sqlite3" \
  "select group_concat(name || ' x' || copies, ', ') from (select name, copies from opponents order by position)"); benchmark $(sqlite3 "$experiment/experiment.sqlite3" \
  "select group_concat(name, ', ') from (select name from benchmark_opponents order by position)")"
out "panel check: the database holds the requested panel ($stored_panel)"
out ''

# Samples every second the resident memory of every process under this
# script except the sampler itself: the summed RSS (shared pages counted
# once per process, so an upper bound on physical memory) and the runner's.
sampler='
  own=$$; root=$1; samples=$2
  while :; do
    ps -A -o pid= -o ppid= -o rss= -o comm= | awk -v root="$root" -v own="$own" "
      { parent[\$1] = \$2; rss[\$1] = \$3; comm[\$1] = \$4 }
      END {
        total = 0; runner = 0; n = 0
        for (p in parent) {
          q = p; inside = 0
          while (q != \"\" && q > 1) {
            if (q == own) { inside = 0; break }
            if (q == root && p != root) { inside = 1; break }
            q = parent[q]
          }
          if (!inside) continue
          total += rss[p]; n++
          if (comm[p] ~ /ruby\$/ && rss[p] > runner) runner = rss[p]
        }
        print total, runner, n
      }" >> "$samples"
    sleep 1
  done'

# field KEY LINE: the value of KEY=VALUE in LINE.
field() { printf '%s\n' "$2" | tr ' ' '\n' | awk -F= -v k="$1" '$1 == k { print $2 }'; }

# setup_parts LINE: the parts of setup in LINE that ran, as
# "clear 0.1 s, breed 30.2 s (hash 3.0 s, store 5.0 s within it), ...".
# hash and store are within breed, so they are not listed as parts of
# their own.
setup_parts() {
  printf '%s\n' "$1" | tr ' ' '\n' | awk -F= '
    $1 ~ /^setup_/ { sub(/^setup_/, "", $1); name[++n] = $1; value[$1] = $2 }
    END {
      for (i = 1; i <= n; i++) {
        k = name[i]
        if (k == "hash" || k == "store") continue
        s = k " " value[k] " s"
        if (k == "breed") {
          w = ""
          if ("hash" in value) w = "hash " value["hash"] " s"
          if ("store" in value) w = w (w ? ", " : "") "store " value["store"] " s"
          if (w) s = s " (" w " within it)"
        }
        p = p (p ? ", " : "") s
      }
      print p
    }'
}

summary=''
run_generation() {
  generation=$1
  log="$results.gen$generation.log"
  times="$results.gen$generation.time"
  profile="$results.gen$generation.profile"
  samples="$results.gen$generation.samples"
  status_file="$results.gen$generation.status"
  : > "$samples"
  command="mise run run $name $concurrency one-generation"

  sh -c "$sampler" sampler "$$" "$samples" &
  sampler_pid=$!
  start=$(date +%s)
  { EVO_PROFILE="$profile" STATUS="$status_file" /usr/bin/time "$time_flag" \
      sh -c '"$@" 2>&1; s=$?; echo "$s" > "$STATUS"; exit "$s"' sh \
      mise run run "$name" "$concurrency" one-generation | tee "$log"; } 2> "$times" || true
  end=$(date +%s)
  kill "$sampler_pid" 2>/dev/null || true
  wait "$sampler_pid" 2>/dev/null || true
  sampler_pid=''

  status=$(cat "$status_file" 2>/dev/null || echo '?')
  out "## Invocation $((generation + 1)): generation $generation"
  out "command: EVO_PROFILE=$profile $command"
  out "exit status: $status, wall $((end - start)) s by the clock"
  reentry=''
  if [ "$generation" -gt 0 ]; then
    # A one-generation run first re-enters the last finished generation:
    # it empties work/ and deletes the network directories it no longer
    # needs (its networks/N/ stays; a finished tournament skips verifying
    # it), then finds nothing left to play. That is in this invocation's
    # wall time, /usr/bin/time, and runner profile, but not in its timings
    # line. Its length comes from the two generation headers' clock times,
    # to the second.
    reentry=$(awk '/^\*\*\* GENERATION / { split($5, t, ":"); s[++n] = t[1] * 3600 + t[2] * 60 + t[3] }
      END { if (n >= 2) { d = s[2] - s[1]; if (d < 0) d += 86400; print d } }' "$log")
    out "note: this invocation first re-entered generation $((generation - 1)) (emptied work/ and deleted stale network directories) before generation $generation; its wall time, /usr/bin/time and runner profile include that, the timings line does not. Re-entry took about ${reentry:-?} s (generation headers, 1 s resolution)."
  fi
  timings=$(grep '^timings ' "$log" || true)
  out "timings line: ${timings:-none}"
  line=$(cat "$profile" 2>/dev/null || true)
  out "runner profile (the runner process only; child_* = processes it waited for): ${line:-none}"
  out "/usr/bin/time $time_flag (covers mise, the runner, and every process they waited for; max RSS is the largest single process, not a sum):"
  sed 's/^/    /' "$times" >> "$results"
  peak=$(awk '$1 > t { t = $1 } $2 > r { r = $2 } END { printf "%.0f %.0f", t / 1024, r / 1024 }' "$samples")
  out "sampled peak RSS, 1 s samples: summed over the whole process tree $(echo "$peak" | cut -d' ' -f1) MiB, runner process $(echo "$peak" | cut -d' ' -f2) MiB ($(wc -l < "$samples" | tr -d ' ') samples)"
  if [ "$status" != 0 ]; then
    out "invocation failed; experiment kept at $experiment"
    printf 'invocation for generation %s failed (status %s); see %s. %s is kept.\n' \
      "$generation" "$status" "$log" "$experiment" >&2
    exit 1
  fi

  db="$experiment/experiment.sqlite3"
  out 'games (tournament, by scorer): scorer|games|failures|summed duration s'
  sqlite3 "$db" "select scorer, count(*), sum(failure is not null), round(sum(duration), 3)
    from games where generation = $generation group by scorer" | sed 's/^/    /' >> "$results"
  out 'benchmark games: games|failures|summed duration s'
  sqlite3 "$db" "select count(*), sum(failure is not null), round(sum(duration), 3)
    from benchmark_games where generation = $generation" | sed 's/^/    /' >> "$results"
  # Only checkpoint champions are stored; the generation's networks are
  # files in networks/N/ (their count and bytes are in the arena load line).
  out 'stored networks (checkpoint champions): generation|count|bytes'
  sqlite3 "$db" "select generation, count(*), sum(length(weights)) from networks group by generation" |
    sed 's/^/    /' >> "$results"
  out "disk: experiment $(du -sk "$experiment" | awk '{ printf "%.2f GiB", $1 / 1048576 }'), database $(du -sk "$db" | awk '{ printf "%.2f GiB", $1 / 1048576 }'), networks/ $(du -sk "$experiment/networks" | awk '{ printf "%.2f GiB", $1 / 1048576 }'), work/ $(du -sk "$experiment/work" | awk '{ printf "%.2f GiB", $1 / 1048576 }'); df free $(df -Pk "$experiment" | awk 'NR == 2 { printf "%.1f GiB", $4 / 1048576 }')"

  # The arena's startup and load cost: one arena over every network of the
  # generation (networks/N/), each loaded once, playing one move per game
  # (max_moves 0). An untimed first run warms the file cache, so the three
  # timed runs compare.
  schedule="$results.gen$generation.schedule"
  generation_networks="$experiment/networks/$generation"
  find "$generation_networks" -maxdepth 1 -name '*.ann' | sort |
    awk '{ n[NR] = $0 } END { for (i = 1; i <= NR; i += 2) print "g" i, n[i], n[(i < NR) ? i + 1 : 1] }' > "$schedule"
  networks=$(find "$generation_networks" -maxdepth 1 -name '*.ann' | wc -l | tr -d ' ')
  bytes=$(find "$generation_networks" -maxdepth 1 -name '*.ann' -exec ls -l {} + | awk '{ s += $5 } END { print s + 0 }')
  out "arena load (a separate run after the invocation, after an untimed warm-up run, so a warm file cache): $networks networks, $bytes bytes, $(wc -l < "$schedule" | tr -d ' ') games at max_moves 0"
  loads=''
  ( cd "$experiment/work" && ../arena 9 6.5 0 "$schedule" > /dev/null )
  for run in 1 2 3; do
    arena_out="$results.gen$generation.arena.out"
    arena_time="$results.gen$generation.arena.time"
    ( cd "$experiment/work" && /usr/bin/time "$time_flag" ../arena 9 6.5 0 "$schedule" > "$arena_out" 2> "$arena_time" )
    games_s=$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^duration=/) { sub(/duration=/, "", $i); s += $i } } END { printf "%.3f", s }' "$arena_out")
    if [ "$os" = Darwin ]; then
      wall=$(awk '/ real / { print $1 }' "$arena_time")
      rss=$(awk '/maximum resident set size/ { printf "%.0f", $1 / 1048576 }' "$arena_time")
    else
      wall=$(awk -F': ' '/Elapsed \(wall clock\)/ { n = split($2, t, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + t[i]; print s }' "$arena_time")
      rss=$(awk -F': ' '/Maximum resident set size/ { printf "%.0f", $2 / 1024 }' "$arena_time")
    fi
    out "    run $run: wall $wall s, games $games_s s, max RSS $rss MiB, $(tail -n 1 "$arena_out")"
    loads="$loads ${wall}s"
    rm -f "$arena_out" "$arena_time"
  done
  rm -f "$schedule" "$status_file"
  out ''

  summary="$summary
generation $generation: exit $status, wall $((end - start)) s$( [ -z "$reentry" ] || printf ' (including about %s s re-entering generation %s)' "$reentry" $((generation - 1))), runner total $(field total "$timings") s, setup $(field setup "$timings") s ($(setup_parts "$timings")), tournament $(field tournament "$timings") s (ruby $(field ruby "$timings") s, worker $(field worker "$timings") s), benchmark $(field benchmark "$timings") s, games $(field games "$timings"), failures $(field failures "$timings")
  runner CPU user $(field utime "$line") s sys $(field stime "$line") s, allocated objects $(field total_allocated_objects "$line"), GC runs $(field gc_count "$line")$( [ -z "$reentry" ] || printf ' (re-entry included)')
  peak RSS: tree sum $(echo "$peak" | cut -d' ' -f1) MiB, runner $(echo "$peak" | cut -d' ' -f2) MiB; arena load of $networks networks:$loads"
}

run_generation 0
run_generation 1

if [ "$keep" -eq 1 ]; then
  out "experiment kept at $experiment"
else
  rm -rf "$experiment"
  out "experiment deleted"
fi

printf '\n== %s workload%s ==\npanel: %s%s\nresults: %s (logs next to it)\n' "$workload" \
  "$( [ "$tiny" -eq 0 ] || printf ' (TINY TEST RUN, NOT THE WORKLOAD)')" "$stored_panel" "$summary" "$results"
