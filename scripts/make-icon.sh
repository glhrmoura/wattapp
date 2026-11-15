#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
swiftc -O Tools/make-icon.swift -o "$WORK/make-icon"
for s in 16 32 128 256 512; do
  "$WORK/make-icon" "$ICONSET/icon_${s}x${s}.png" "$s"
  "$WORK/make-icon" "$ICONSET/icon_${s}x${s}@2x.png" "$((s * 2))"
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
"$WORK/make-icon" Resources/logo.png 512 logo
