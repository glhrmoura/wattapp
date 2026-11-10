#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
APP_PATH="$(./scripts/build-app.sh | tail -1)"
osascript -e 'tell application id "com.glhrmoura.wattapp" to quit' >/dev/null 2>&1 || true
for _ in {1..50}; do
  pgrep -xq WattApp || break
  sleep 0.1
done
pkill -x WattApp >/dev/null 2>&1 || true
pkill -x wattapp-bridge >/dev/null 2>&1 || true
open "$APP_PATH"
