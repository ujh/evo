# Checks genes lines of networks with every feature group: each feature
# weight lies within noise * |w| of its starting weight w (ANN_FEATURES in
# lib/ann.c), and the noise, w times 1 + u, moved at least one weight down
# (u < 0) and one up (u > 0). Exits 1 otherwise.
BEGIN {
  start["fw_hane"] = 0.05; start["fw_cut"] = 0.05; start["fw_edge"] = 0.05
  start["fw_capture"] = 1; start["fw_self_atari"] = -1; start["fw_saves_atari"] = 0.8
  start["fw_near_last"] = 0.05
  down = 0; up = 0
}
{
  seen = 0
  for (i = 1; i <= NF; i++) {
    if (split($i, kv, "=") != 2 || !(kv[1] in start)) continue
    w = start[kv[1]]; v = kv[2] + 0; a = w < 0 ? -w : w; d = v - w
    if (d < 0) d = -d
    if (d > noise * a * (1 + 1e-12)) { print "out of range: " $i > "/dev/stderr"; failed = 1; exit 1 }
    u = v / w - 1
    if (u < 0) down = 1
    if (u > 0) up = 1
    seen++
  }
  if (seen != 7) { print "expected 7 feature weights: " $0 > "/dev/stderr"; failed = 1; exit 1 }
}
END {
  if (failed) exit 1
  if (!down || !up) { print "the noise did not move feature weights both ways" > "/dev/stderr"; exit 1 }
}
