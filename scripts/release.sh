#!/usr/bin/env sh
# Build a release artifact from this source tree.
#
# Usage: scripts/release.sh [VERSION] [--skip-tests] [--deploy]
#   VERSION       default: `git describe --tags --always --dirty` or a UTC timestamp
#   --skip-tests  skip `zig build test` (only when the same commit passed CI)
#   --deploy      copy the binary to /usr/local/bin/ivenna after keeping the old one
#
# Output: dist/<version>/ivenna, ivenna.sha256, buildinfo.json
set -eu

version=""
skip_tests=0
deploy=0
for arg in "$@"; do
  case "$arg" in
    --skip-tests) skip_tests=1 ;;
    --deploy) deploy=1 ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) version="$arg" ;;
  esac
done

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

zig=$(command -v zig 2>/dev/null || echo "$HOME/.local/bin/zig")
[ -x "$zig" ] || { echo "zig not found; install $(cat .zig-version)" >&2; exit 1; }

commit=unknown
if command -v git >/dev/null 2>&1 && git rev-parse --verify HEAD >/dev/null 2>&1; then
  commit=$(git rev-parse HEAD)
  [ -n "$version" ] || version=$(git describe --tags --always --dirty 2>/dev/null || true)
fi
[ -n "$version" ] || version=$(date -u +%Y%m%dT%H%M%SZ)

echo "release $version (commit $commit, zig $("$zig" version))"

"$zig" build -Doptimize=ReleaseFast

if [ "$skip_tests" -eq 0 ]; then
  "$zig" build test --summary all
fi

out="$root/dist/$version"
mkdir -p "$out"
cp "$root/zig-out/bin/ivenna" "$out/ivenna"
chmod 755 "$out/ivenna"
(cd "$out" && sha256sum ivenna > ivenna.sha256)
sha=$(cut -d' ' -f1 "$out/ivenna.sha256")
cat > "$out/buildinfo.json" <<JSON
{
  "version": "$version",
  "commit": "$commit",
  "zig": "$("$zig" version)",
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "host": "$(uname -m)-$(uname -s | tr '[:upper:]' '[:lower:]')",
  "sha256": "$sha",
  "skipped_tests": $skip_tests
}
JSON
echo "artifact: $out/ivenna ($sha)"

if [ "$deploy" -eq 1 ]; then
  [ "$(id -u)" -eq 0 ] || { echo "--deploy needs root" >&2; exit 1; }
  keep="/srv/ivenna/backups/releases/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$keep"
  if [ -f /usr/local/bin/ivenna ]; then
    cp -p /usr/local/bin/ivenna "$keep/ivenna.previous"
    sha256sum /usr/local/bin/ivenna > "$keep/ivenna.previous.sha256"
  fi
  install -m 755 "$out/ivenna" /usr/local/bin/ivenna.new
  mv /usr/local/bin/ivenna.new /usr/local/bin/ivenna
  cp "$out/buildinfo.json" "$keep/buildinfo.json"
  echo "installed; previous binary kept in $keep"
  echo "restart with: systemctl restart ivenna"
fi
