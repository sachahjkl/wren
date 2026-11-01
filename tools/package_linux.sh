#!/usr/bin/env bash
# Makes the Linux release file from a finished ./build.sh release: build/dist/wren-<version>-linux-x64.tar.gz, one folder
# with the executable and what it says about what it needs, and its SHA-256 in build/dist/SHA256SUMS-linux.txt.
#   tools/package_linux.sh [version]     (default: APP_VERSION of src/browser/about.odin)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
V="${1:-$(sed -n 's/^APP_VERSION *:: *"\([^"]*\)".*/\1/p' src/browser/about.odin | head -1)}"
[ -n "$V" ] || { echo "APP_VERSION not found in src/browser/about.odin" >&2; exit 1; }
[ -x build/wren ] || { echo "build/wren is missing: run ./build.sh release first" >&2; exit 1; }

NAME="wren-$V-linux-x64"
STAGE="build/dist/$NAME"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp build/wren "$STAGE/wren"
strip --strip-debug "$STAGE/wren" 2>/dev/null || true
cp LICENSE* "$STAGE/" 2>/dev/null || true
cat > "$STAGE/README.txt" <<EOF
Wren $V for Linux x86-64, an early preview. Start it with ./wren

It needs, from your distribution:
  to start      glibc 2.39 or later (Ubuntu 24.04, Debian 13, Fedora 40), libopus, libasound, libfontconfig
                  Debian, Ubuntu: apt install libopus0 libasound2 libfontconfig1
                  Fedora: dnf install opus alsa-lib fontconfig
                  Arch: pacman -S opus alsa-lib fontconfig
  for a window  libwayland-client and libxkbcommon, or libxcb and libxkbcommon-x11; for the theme's cursors, libwayland-cursor or libxcb-cursor (optional)
                a Vulkan or OpenGL driver (Mesa's is enough)
  for H.264     Cisco's openh264; AV1 and VP9 are built in
  for dialogs   zenity or kdialog

https://github.com/sachahjkl/wren
EOF
tar -C build/dist -czf "build/dist/$NAME.tar.gz" "$NAME"
rm -rf "$STAGE"
(cd build/dist && sha256sum "$NAME.tar.gz" > SHA256SUMS-linux.txt)
echo "build/dist/$NAME.tar.gz: $(du -h "build/dist/$NAME.tar.gz" | cut -f1)"
