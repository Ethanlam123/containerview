#!/usr/bin/env bash
# Build (if needed) and run the Container dashboard. CWD is forced to this
# script's directory so FileMiddleware can resolve Resources/Public/ for both
# `swift run` and the release binary.
set -euo pipefail

cd "$(dirname "$0")"

release=0
allow_remote=0
exec_enabled=0
for arg in "$@"; do
  case "$arg" in
    --release) release=1 ;;
    --allow-remote) allow_remote=1 ;;
    --exec) exec_enabled=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

if [[ $release -eq 1 ]]; then
  swift build -c release
  binary=".build/release/ContainerDashboard"
else
  binary="swift run"
fi

export CONTAINER_DASHBOARD_ALLOW_REMOTE="$allow_remote"
export CONTAINERDASHBOARD_ENABLE_EXEC="$exec_enabled"
exec $binary
