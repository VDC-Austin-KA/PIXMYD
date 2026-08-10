#!/usr/bin/env bash
#
# Everything about the iOS app that can be checked without a Mac.
#
#   cd apps/ios && ./verify.sh
#
# Needs a Swift toolchain on Linux (or WSL). It does three things:
#
#   1. Runs the tests for the portable subset — the fusion, meshing, export and
#      NMEA code, which is where a bug produces a wrong measurement rather than
#      a crash.
#   2. Parses every remaining source, catching syntax errors that would
#      otherwise wait for a cloud build.
#   3. Lints for `switch` in argument position (see below).
#
# What it cannot do is type-check anything that imports UIKit, SwiftUI, ARKit or
# Metal. Those frameworks do not exist off Apple platforms. A green run here
# means "no reason not to try a real build", not "this compiles".
set -u
cd "$(dirname "$0")" || exit 1

failures=0

echo "=== Tests (portable subset) ==="
if ! swift test 2>&1 | grep -E 'error:|Executed [0-9]+ tests' | tail -4; then
  failures=1
fi

FRONTEND=$(command -v swift-frontend || find "${HOME}/.local/share/swiftly/toolchains" \
  -name swift-frontend -type f 2>/dev/null | head -1)

if [ -n "${FRONTEND:-}" ]; then
  echo "=== Parse (every source) ==="
  for file in $(find PIXMYD -name '*.swift' | sort); do
    out=$("$FRONTEND" -parse "$file" 2>&1)
    if [ -n "$out" ]; then
      echo "$out" | head -6
      failures=1
    fi
  done
  echo "done"
else
  echo "=== Parse: swift-frontend not found, skipped ==="
fi

# `switch` is an expression only in a return, a throw, or the right-hand side of
# an assignment. As a call argument it is a compile error — and a *semantic*
# one, so `-parse` accepts it and only a real build rejects it. That cost a
# cloud build once, which is the whole reason this check exists.
echo "=== Lint: switch in argument position ==="
for file in $(find PIXMYD PIXMYDTests -name '*.swift' | sort); do
  hits=$(awk '
    /^[[:space:]]*switch[[:space:]]/ && prev ~ /[(,][[:space:]]*$/ {
      printf "%s:%d: switch used as an argument; hoist it into a variable or a computed property\n", FILENAME, NR
    }
    { if ($0 !~ /^[[:space:]]*$/) prev = $0 }
  ' "$file")
  if [ -n "$hits" ]; then
    echo "$hits"
    failures=1
  fi
done
echo "done"

exit $failures
