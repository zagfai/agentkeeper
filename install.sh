#!/bin/sh
# agentkeeper installer — fetch the latest release binary from GitHub.
#
#   curl -fsSL https://raw.githubusercontent.com/zagfai/agentkeeper/main/install.sh | sh
#
# Environment overrides:
#   AGENTKEEPER_REPO=owner/repo     GitHub repository (default: zagfai/agentkeeper)
#   AGENTKEEPER_VERSION=vX.Y.Z      release tag to install (default: latest)
#   AGENTKEEPER_BINDIR=/path        install directory (default: /usr/local/bin)
#   AGENTKEEPER_BASE_URL=url        download base URL (mirrors, or testing)
#   AGENTKEEPER_NO_VERIFY=1         skip sha256 verification (not recommended)
set -eu

REPO="${AGENTKEEPER_REPO:-zagfai/agentkeeper}"
VERSION="${AGENTKEEPER_VERSION:-latest}"
BINDIR="${AGENTKEEPER_BINDIR:-/usr/local/bin}"
BASEURL="${AGENTKEEPER_BASE_URL:-}"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

os=$(uname -s | tr 'A-Z' 'a-z')
[ "$os" = "linux" ] || die "this installer supports Linux only (detected: $os)"
case "$(uname -m)" in
  x86_64|amd64)        arch=amd64 ;;
  aarch64|arm64)       arch=arm64 ;;
  armv7l|armv7)        arch=armv7 ;;
  i386|i486|i586|i686) arch=386 ;;
  riscv64)             arch=riscv64 ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac
name="agentkeeper_${os}_${arch}"

if [ -n "$BASEURL" ]; then
  base="$BASEURL"
elif [ "$VERSION" = "latest" ]; then
  base="https://github.com/$REPO/releases/latest/download"
else
  base="https://github.com/$REPO/releases/download/$VERSION"
fi
bin_url="$base/$name"
sum_url="$base/$name.sha256"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fetch() { # fetch <url> <dest>
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$BASEURL" ]; then
      curl -fsSL --max-time 300 -o "$2" "$1"
    else
      curl -fsSL --proto '=https' --tlsv1.2 --max-time 300 -o "$2" "$1"
    fi
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 300 -O "$2" "$1"
  else
    die "neither curl nor wget is available"
  fi
}

say "Downloading $name ($VERSION) ..."
fetch "$bin_url" "$tmp/$name"
if [ "${AGENTKEEPER_NO_VERIFY:-0}" = "1" ]; then
  say "warning: checksum verification skipped"
else
  fetch "$sum_url" "$tmp/$name.sha256"
  (cd "$tmp" && sha256sum -c "$name.sha256" >/dev/null 2>&1) || die "checksum verification failed"
  say "Checksum OK"
fi

if [ "$(id -u)" = "0" ]; then
  mkdir -p "$BINDIR"
  install -m 0755 "$tmp/$name" "$BINDIR/agentkeeper"
elif [ -d "$BINDIR" ] && [ -w "$BINDIR" ]; then
  install -m 0755 "$tmp/$name" "$BINDIR/agentkeeper"
elif command -v sudo >/dev/null 2>&1; then
  sudo mkdir -p "$BINDIR" && sudo install -m 0755 "$tmp/$name" "$BINDIR/agentkeeper"
else
  BINDIR="$HOME/.local/bin"
  mkdir -p "$BINDIR"
  install -m 0755 "$tmp/$name" "$BINDIR/agentkeeper"
  say "note: $BINDIR may not be in your PATH"
fi

say "Installed: $BINDIR/agentkeeper"
say "Next: create a config (see README) and run: agentkeeper -c agentkeeper.yaml"
