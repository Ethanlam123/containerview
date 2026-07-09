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

# Copied assets can carry resource forks / Finder info / quarantine xattrs that
# codesign rejects ("resource fork, Finder information, or similar detritus not
# allowed"). Strip them off the whole bundle before signing. Use the absolute
# path: a conda-provided `xattr` shim may shadow Apple's tool and lacks -r.
/usr/bin/xattr -cr "$APP"

echo "==> Ad-hoc signing (per Mach-O then bundle; --deep is deprecated and unneeded)"
codesign --force -s - "$MACOS/ContainerDashboardServer"
codesign --force -s - "$MACOS/ContainerDashboard"
codesign --force -s - "$APP"

echo "==> Built: $APP"
