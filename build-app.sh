#!/usr/bin/env bash
# Build + assemble ContainerDashboard.app. Pure SPM (no Xcode project):
#   - `swift build -c release` builds BOTH the server (ContainerDashboard) and
#     the native SwiftUI app (ContainerDashboardApp, links SwiftTerm).
# The app is the CFBundleExecutable (ContainerDashboard); the server ships
# beside it as ContainerDashboardServer. The native UI no longer loads the web
# dashboard, so Resources/Public is not bundled (the server still serves it for
# `swift run` / browser mode).
set -euo pipefail

cd "$(dirname "$0")"

APP="build/ContainerDashboard.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "==> Building server + native app (swift build -c release)"
# Build ALL targets: the app target does not depend on the server target (it
# spawns the server binary out-of-process), so a --target filter would skip the
# server binary and the bundle would have no ContainerDashboardServer.
swift build -c release
SERVER_BIN=".build/release/ContainerDashboard"
APP_BIN=".build/release/ContainerDashboardApp"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

# install preserves the exec bit; plain cp under a umask can drop it, and
# LaunchServices refuses a non-executable CFBundleExecutable.
install -m 0755 "$APP_BIN"          "$MACOS/ContainerDashboard"
install -m 0755 "$SERVER_BIN"       "$MACOS/ContainerDashboardServer"
cp App/Info.plist                   "$CONTENTS/Info.plist"

echo "==> Asserting exec bits"
[[ -x "$MACOS/ContainerDashboard" ]]       || { echo "missing exec bit: app"    >&2; exit 1; }
[[ -x "$MACOS/ContainerDashboardServer" ]] || { echo "missing exec bit: server" >&2; exit 1; }

# codesign rejects Finder info / resource forks / file-provider tags as
# "resource fork, Finder information, or similar detritus not allowed". Finder/
# LaunchServices stamps com.apple.FinderInfo on the bundle dir once the app has
# been opened, and copied assets can carry their own. `xattr -cr` clears them.
# (com.apple.provenance is also present on every compiled Mach-O but does NOT
# block signing and cannot be removed, so it is left in place.) Absolute path: a
# conda-provided `xattr` shim may shadow Apple's tool and lacks -r.
/usr/bin/xattr -cr "$APP"

echo "==> Ad-hoc signing (auxiliary server binary, then the bundle which signs the main exec)"
codesign --force -s - "$MACOS/ContainerDashboardServer"
# Signing the main executable can prompt LaunchServices to stamp com.apple.FinderInfo
# on the bundle dir, which the bundle sign then rejects as detritus; clear again.
/usr/bin/xattr -cr "$APP"
codesign --force -s - "$APP"

echo "==> Built: $APP"
