#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Codex Meter.app"
CONTENTS="$APP/Contents"

cd "$ROOT"
HOME="$ROOT/.home" \
CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/swiftpm-cache" \
swift build --disable-sandbox -c release --product CodexUsageApp
HOME="$ROOT/.home" \
CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/swiftpm-cache" \
swift build --disable-sandbox -c release --product codex-meter-agent

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$ROOT/.build/release/CodexUsageApp" "$CONTENTS/MacOS/CodexUsageApp"
cp "$ROOT/.build/release/codex-meter-agent" "$CONTENTS/Resources/codex-meter-agent"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
echo "$APP"
