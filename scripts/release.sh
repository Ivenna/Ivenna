#!/usr/bin/env sh
set -eu

usage() {
  printf '%s\n' 'Usage: scripts/release.sh VERSION' \
    'Test and package Ivenna for the host architecture on GNU/Linux.' \
    'The archive, checksum, and build record are written to dist/VERSION/.' \
    'Start VERSION with an ASCII letter or digit. The rest may also include periods, underscores, and hyphens.'
}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$#" -eq 1 ] || fail 'Supply one version label. See scripts/release.sh --help.'
version="$1"
export LC_ALL=C
case "$version" in
  -h|--help) usage; exit 0 ;;
  ''|[!a-zA-Z0-9]*|*[!a-zA-Z0-9._-]*) fail "Invalid version label '$version'. See scripts/release.sh --help." ;;
esac

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd -P)
cd "$root"

commit=null
dirty=null
if [ "$(git rev-parse --show-toplevel 2>/dev/null)" = "$root" ]; then
  revision=$(git rev-parse HEAD)
  commit="\"$revision\""
  changes=$(git status --porcelain)
  dirty=false
  if [ -n "$changes" ]; then
    dirty=true
  fi
fi

[ "$(uname -s)" = Linux ] || fail 'Building a release requires Linux.'
target="$(uname -m)-linux-gnu"
glibc_min=2.28
set -- "-Dtarget=native-linux-gnu.$glibc_min" -Dcpu=baseline -Doptimize=safe
expected_zig=$(cat .zig-version)
zig_version=$(zig version)
[ "$zig_version" = "$expected_zig" ] || fail "Expected Zig $expected_zig, found $zig_version."

out="$root/dist/$version"
[ ! -e "$out" ] || fail "Package already exists: $out"
mkdir -p "$root/dist"
stage=$(mktemp -d "$root/dist/.release.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
trap 'exit 1' HUP INT TERM

zig build test "$@" --summary all
zig build release "$@" --prefix "$stage/build"

asset="ivenna-$target-$version"
mkdir "$stage/package"
cd "$stage/package"
tar -czf "$asset.tar.gz" -C "$stage/build/bin" ivenna -C "$stage/build" LICENSE licenses
sha256sum "$asset.tar.gz" > "$asset.sha256"
cat > "$asset.json" <<JSON
{
  "version": "$version",
  "commit": $commit,
  "dirty": $dirty,
  "target": "$target",
  "glibc_min": "$glibc_min",
  "zig": "$zig_version",
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
cd "$root"
mv -T -- "$stage/package" "$out"
printf 'Package written to %s\n' "$out"
