#!/bin/sh
# Build release assets for multiple CPU architectures (with sha256 files) into dist/.
# Usage: sh scripts/release.sh [targets...]
#   targets: amd64 arm64 armv7 386 riscv64   (default: all of them)
# Then upload everything in dist/ to a GitHub release, e.g.:
#   gh release create v0.1.0 dist/* --title "agentkeeper v0.1.0"
set -eu
cd "$(dirname "$0")/.."
mkdir -p dist
targets="${*:-amd64 arm64 armv7 386 riscv64}"
for t in $targets; do
  goarch="$t"; goarm=""
  if [ "$t" = "armv7" ]; then goarch=arm; goarm=7; fi
  out="agentkeeper_linux_$t"
  echo "building dist/$out ..."
  env CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" ${goarm:+GOARM=$goarm} \
    go build -trimpath -ldflags "-s -w" -o "dist/$out" .
  (cd dist && sha256sum "$out" > "$out.sha256")
done
ls -l dist/
