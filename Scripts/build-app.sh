#!/bin/sh
# Builds "Apple Calendar MCP.app" (release): the menu bar app, with the apple-calendar-mcp server in its own bundle at
# Contents/Helpers/Apple Calendar MCP Server.app (the path MCP clients start), so both share one signed location.
# Also dist/apple-calendar-mcp: the same server alone, for the Claude extension (Scripts/make-mcpb.sh).
#   Scripts/build-app.sh            -> ~/Library/Caches/AppleCalendarMCP/dist/Apple Calendar MCP.app
#   Scripts/build-app.sh --install  -> also copies it to ~/Applications and relaunches it
# Build output lives outside the repo: files in Documents carry Finder metadata, which codesign
# refuses ("resource fork, Finder information, or similar detritus").
# Signing: SIGN_IDENTITY; else a "Developer ID Application" identity from the keychain; else the
# local "Apple Calendar MCP Local Signing" certificate (Scripts/create-signing-identity.sh); else ad-hoc.
# A stable signature keeps the Calendars grant across rebuilds, and the bridge between the server and the app only
# accepts code signed like itself (same team, or the same local certificate): an ad-hoc build cannot use it.
# Developer ID also gets a secure timestamp, which notarization requires.
# VERSION and BUILD_NUMBER, when set, stamp the bundle's version (the release workflow sets them); the git commit is
# stamped too (AppleCalendarMCPCommit).
# ARCHS picks the architectures (default: universal, "arm64 x86_64"; set ARCHS=arm64 for faster local builds).
set -eu
cd "$(dirname "$0")/.."

CACHE="$HOME/Library/Caches/AppleCalendarMCP"
BUILD="$CACHE/build"
APP="$CACHE/dist/Apple Calendar MCP.app"

ARCH_FLAGS=""
for arch in ${ARCHS:-arm64 x86_64}; do ARCH_FLAGS="$ARCH_FLAGS --arch $arch"; done
swift build -c release $ARCH_FLAGS --scratch-path "$BUILD" --product CalendarMCPBar
swift build -c release $ARCH_FLAGS --scratch-path "$BUILD" --product apple-calendar-mcp
BIN="$(swift build -c release $ARCH_FLAGS --scratch-path "$BUILD" --show-bin-path)"

[ -f Resources/AppIcon.icns ] || swift Scripts/make-icon.swift Resources

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ditto --norsrc --noextattr "$BIN/CalendarMCPBar" "$APP/Contents/MacOS/Apple Calendar MCP"
ditto --norsrc --noextattr Resources/Info.plist "$APP/Contents/Info.plist"
ditto --norsrc --noextattr Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
VERSION="${VERSION:-$(sed -n 's/.*?? "\([0-9][0-9.]*\)".*/\1/p' Sources/CalendarMCPKit/CalendarMCPServer.swift | head -n 1)}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-$VERSION}" "$APP/Contents/Info.plist"
# The commit, so the server can say which build a client started (CalendarMCPVersion.build); "-dirty" with local changes.
COMMIT="$(git rev-parse --short=7 HEAD 2>/dev/null || echo unknown)"
git diff --quiet HEAD 2>/dev/null || COMMIT="$COMMIT-dirty"
/usr/libexec/PlistBuddy -c "Set :AppleCalendarMCPCommit $COMMIT" "$APP/Contents/Info.plist"
# The server's bundle shares the app's version and usage descriptions, under its own identifier (the bridge knows both).
HELPER="$APP/Contents/Helpers/Apple Calendar MCP Server.app"
mkdir -p "$HELPER/Contents/MacOS"
ditto --norsrc --noextattr "$BIN/apple-calendar-mcp" "$HELPER/Contents/MacOS/apple-calendar-mcp"
cp "$APP/Contents/Info.plist" "$HELPER/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable apple-calendar-mcp" -c "Set :CFBundleName Apple Calendar MCP Server" \
    -c "Set :CFBundleDisplayName Apple Calendar MCP Server" -c "Set :CFBundleIdentifier com.mpconsulting.AppleCalendarMCP.Server" \
    -c "Delete :CFBundleIconFile" "$HELPER/Contents/Info.plist"
STANDALONE="$(dirname "$APP")/apple-calendar-mcp"
ditto --norsrc --noextattr "$BIN/apple-calendar-mcp" "$STANDALONE"
xattr -cr "$APP"

if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -n 1)"
fi
if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-certificate -c "Apple Calendar MCP Local Signing" -Z 2>/dev/null | awk '/SHA-1/ {print $3}')"
fi
case "${SIGN_IDENTITY:-}" in "Developer ID"*) TIMESTAMP=--timestamp ;; *) TIMESTAMP= ;; esac

# Nested code first, then the app around it.
for target in "$HELPER" "$APP"; do
    codesign --force --options runtime $TIMESTAMP --entitlements Resources/entitlements.plist --sign "${SIGN_IDENTITY:--}" "$target"
done
codesign --force --options runtime $TIMESTAMP --entitlements Resources/entitlements.plist \
    --identifier apple-calendar-mcp --sign "${SIGN_IDENTITY:--}" "$STANDALONE"
codesign --verify --strict --deep "$APP"
echo "Built $APP $VERSION ($(lipo -archs "$APP/Contents/MacOS/Apple Calendar MCP"), signed by ${SIGN_IDENTITY:--})"

if [ "${1:-}" = "--install" ]; then
    DEST="$HOME/Applications/Apple Calendar MCP.app"
    pkill -x "Apple Calendar MCP" 2>/dev/null && sleep 1 || true
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    open "$DEST"
    echo "Installed and launched $DEST"
fi
