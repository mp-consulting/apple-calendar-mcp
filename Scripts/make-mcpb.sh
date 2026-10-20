#!/bin/sh
# Packs the server into a Claude app extension (.mcpb): double-click to install in Claude.
#   Scripts/make-mcpb.sh [app] [output]
#   defaults: ~/Library/Caches/AppleCalendarMCP/dist/Apple Calendar MCP.app -> …/dist/AppleCalendarMCP.mcpb
# Run Scripts/build-app.sh first: the bundled server is its signed, universal standalone copy (dist/apple-calendar-mcp),
# signed with the identifier apple-calendar-mcp, which the app's bridge accepts.
# Needs Node (npx) for the official packer, @anthropic-ai/mcpb.
set -eu
cd "$(dirname "$0")/.."

CACHE="$HOME/Library/Caches/AppleCalendarMCP"
APP="${1:-$CACHE/dist/Apple Calendar MCP.app}"
OUT="${2:-$CACHE/dist/AppleCalendarMCP.mcpb}"
STAGE="$CACHE/mcpb"
SERVER="$(dirname "$APP")/apple-calendar-mcp"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
# The standalone server has no Info.plist: the manifest passes the app's commit (APPLE_CALENDAR_MCP_COMMIT), marked
# ".mcpb" so the activity log tells the extension from the app's server.
COMMIT="$(/usr/libexec/PlistBuddy -c 'Print :AppleCalendarMCPCommit' "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)"

rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE/server"
ditto "$SERVER" "$STAGE/server/apple-calendar-mcp"
sips -s format png -Z 512 Resources/AppIcon.icns --out "$STAGE/icon.png" >/dev/null
TOOLS="$("$SERVER" tools-json)"
python3 - "$STAGE/manifest.json" "$VERSION" "$TOOLS" "$COMMIT" <<'PY'
import sys
out, version, tools, commit = sys.argv[1:5]
text = open("Resources/mcpb/manifest.json").read().replace("__VERSION__", version).replace("__TOOLS__", tools)
text = text.replace("__COMMIT__", commit)
open(out, "w").write(text)
PY
npx --yes @anthropic-ai/mcpb@2.1.2 validate "$STAGE/manifest.json"
npx --yes @anthropic-ai/mcpb@2.1.2 pack "$STAGE" "$OUT"
rm -rf "$STAGE"
echo "Built $OUT"
