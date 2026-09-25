#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tools_root="$project_root/.local/evo-tools"
cache_dir="$tools_root/cache"
releases_dir="$tools_root/releases"
release_id='gnugo-3.8_brown-1.0_amigogtp-1.8_gogui-1.6.0_r4'
release_dir="$releases_dir/$release_id"
# The archives are served from this project's own GitHub release, so setup
# does not depend on the upstream hosts being up. scripts/external-tools.txt
# lists them; `mise run mirror-external-tools` uploads them.
mirror_url='https://github.com/ujh/evo/releases/download/external-tools-r1'
manifest="$project_root/scripts/external-tools.txt"

mkdir -p "$cache_dir" "$releases_dir"

if [ -f "$release_dir/.installed" ]; then
  ln -sfn "releases/$release_id" "$tools_root/current"
  printf 'External tools already installed in %s\n' "$release_dir"
  exit 0
fi

checksum() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

download() {
  name=$1
  expected=$(awk -v name="$name" '$1 == name { print $2 }' "$manifest")
  if [ -z "$expected" ]; then
    printf '%s is not listed in %s\n' "$name" "$manifest" >&2
    exit 1
  fi
  url="$mirror_url/$name"
  archive="$cache_dir/$name"
  if [ -f "$archive" ] && [ "$(checksum "$archive")" = "$expected" ]; then
    return
  fi
  printf 'Downloading %s\n' "$name"
  curl --fail --location --retry 3 --output "$archive.part" "$url"
  if [ "$(checksum "$archive.part")" != "$expected" ]; then
    printf 'Checksum mismatch for %s\n' "$name" >&2
    exit 1
  fi
  mv "$archive.part" "$archive"
}

download gnugo-3.8.tar.gz
download brown-1.0.tar.gz
download amigogtp-1.8.tar.gz
download gogui-v1.6.0-bin.zip

stage=$(mktemp -d "$releases_dir/.stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
mkdir -p "$stage/src" "$stage/bin"

tar -xzf "$cache_dir/gnugo-3.8.tar.gz" -C "$stage/src"
patch -s -p1 -d "$stage/src/gnugo-3.8" <"$project_root/scripts/patches/gnugo-3.8-gg-sort-empty.patch"
printf 'Building GNU Go 3.8\n'
if ! (cd "$stage/src/gnugo-3.8" && CFLAGS='-O2 -fcommon' ./configure --without-curses && make -s) >"$stage/gnugo-build.log" 2>&1; then
  tail -40 "$stage/gnugo-build.log" >&2
  exit 1
fi
cp "$stage/src/gnugo-3.8/interface/gnugo" "$stage/bin/gnugo"

tar -xzf "$cache_dir/brown-1.0.tar.gz" -C "$stage/src"
printf 'Building Brown 1.0\n'
if ! (cd "$stage/src/brown-1.0" && cc -include string.h brown.c gtp.c interface.c -o "$stage/bin/brown") >"$stage/brown-build.log" 2>&1; then
  cat "$stage/brown-build.log" >&2
  exit 1
fi

tar -xzf "$cache_dir/amigogtp-1.8.tar.gz" -C "$stage/src"
printf 'Building AmiGoGtp 1.8\n'
if ! (cd "$stage/src/amigogtp-1.8" && CXXFLAGS='-O2 -include unistd.h' ./configure && make -s) >"$stage/amigogtp-build.log" 2>&1; then
  tail -40 "$stage/amigogtp-build.log" >&2
  exit 1
fi
cp "$stage/src/amigogtp-1.8/amigogtp/amigogtp" "$stage/bin/amigogtp"

printf 'Installing GoGui 1.6.0\n'
unzip -q "$cache_dir/gogui-v1.6.0-bin.zip" -d "$stage/src"
mv "$stage/src/gogui" "$stage/gogui"
ln -s gogui/lib "$stage/lib"
ln -s ../gogui/bin/gogui "$stage/bin/gogui"
ln -s ../gogui/bin/gogui-twogtp "$stage/bin/gogui-twogtp"

rm -rf "$stage/src"
printf '%s\n' "$release_id" > "$stage/.installed"
mv "$stage" "$release_dir"
trap - EXIT HUP INT TERM
ln -sfn "releases/$release_id" "$tools_root/current"
printf 'Installed external tools in %s\n' "$release_dir"
