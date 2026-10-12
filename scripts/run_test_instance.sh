#!/bin/bash
# Restarts HeadsUp with the test hook enabled and an isolated settings suite.
# Usage: scripts/run_test_instance.sh <defaults-suite> [extra VAR=value ...]
cd "$(dirname "$0")/.."
SUITE="${1:-headsup.test}"; shift || true
pkill -f "HeadsUp.app/Contents/MacOS/HeadsUp" 2>/dev/null; sleep 1
env HEADSUP_TEST_CONTROL=1 HEADSUP_DEFAULTS_SUITE="$SUITE" "$@" build/HeadsUp.app/Contents/MacOS/HeadsUp >/dev/null 2>&1 &
sleep 3
