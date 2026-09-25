#!/bin/sh
set -eu

# Upload the archives listed in scripts/external-tools.txt to the GitHub
# release that scripts/install-external-tools.sh downloads from. Each archive
# comes from the local installer cache when its checksum matches, and from
# upstream otherwise. Run it after changing the manifest; a new set of
# archives needs a new release tag in the installer.

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
manifest="$project_root/scripts/external-tools.txt"
installer="$project_root/scripts/install-external-tools.sh"
cache_dir="$project_root/.local/evo-tools/cache"
tag=$(sed -n "s|^mirror_url='https://github.com/ujh/evo/releases/download/\(.*\)'\$|\1|p" "$installer")

if [ -z "$tag" ]; then
  printf 'Could not read the release tag from %s\n' "$installer" >&2
  exit 1
fi

checksum() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

if ! gh release view "$tag" >/dev/null 2>&1; then
  gh release create "$tag" --title "External tools ($tag)" --latest=false \
    --notes 'Unmodified upstream archives that scripts/install-external-tools.sh installs. Not a release of Evo.'
fi

mkdir -p "$cache_dir"
grep -v '^#' "$manifest" | while read -r name expected url; do
  archive="$cache_dir/$name"
  if [ ! -f "$archive" ] || [ "$(checksum "$archive")" != "$expected" ]; then
    printf 'Downloading %s from upstream\n' "$name"
    curl --fail --location --retry 3 --output "$archive.part" "$url"
    if [ "$(checksum "$archive.part")" != "$expected" ]; then
      printf 'Checksum mismatch for %s\n' "$name" >&2
      exit 1
    fi
    mv "$archive.part" "$archive"
  fi
  gh release upload "$tag" "$archive" --clobber </dev/null
done
printf 'Release %s holds every archive in %s.\n' "$tag" "$manifest"
