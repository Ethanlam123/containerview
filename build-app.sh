#!/usr/bin/env bash
# Build + assemble ContainerDashboard.app. Pure SPM (no Xcode project):
#   - `swift build -c release` produces the server binary (ContainerDashboard).
#   - `swiftc` compiles the AppKit/WebKit shell standalone (it has no Vapor
#     dependency, so it stays out of the SwiftPM package to avoid clashing with
#     the server's @main).
# The shell is the CFBundleExecutable (ContainerDashboard); the server ships
# beside it as ContainerDashboardServer. See docs/desktop-app-plan.md (Phase 4).
set -euo pipefail

cd "$(dirname "$0")"

APP="build/ContainerDashboard.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "==> Building server (swift build -c release)"
swift build -c release
SERVER_BIN=".build/release/ContainerDashboard"

echo "==> Compiling shell (swiftc)"
mkdir -p build/shell
SHELL_BIN="build/shell/ContainerDashboard"
swiftc -O App/Shell/main.swift -o "$SHELL_BIN" -framework Cocoa -framework WebKit

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

# install preserves the exec bit; plain cp under a umask can drop it, and
# LaunchServices refuses a non-executable CFBundleExecutable.
install -m 0755 "$SHELL_BIN"        "$MACOS/ContainerDashboard"
install -m 0755 "$SERVER_BIN"       "$MACOS/ContainerDashboardServer"
cp -R Resources/Public              "$RESOURCES/Public"
cp App/Info.plist                   "$CONTENTS/Info.plist"

echo "==> Asserting exec bits"
[[ -x "$MACOS/ContainerDashboard" ]]       || { echo "missing exec bit: shell"  >&2; exit 1; }
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
