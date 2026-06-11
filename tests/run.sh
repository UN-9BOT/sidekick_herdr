#!/usr/bin/env bash
# Run all sidekick_herdr tests.
# - unit: plenary.busted, no real herdr required
# - e2e:  bash tests, require real herdr; auto-detected by `herdr --version`
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"
cd "$PLUGIN_ROOT"

failed=0
passed=0

echo "=== unit tests ==="
unit_out=$(nvim -l tests/minit.lua tests/spec/session_spec.lua 2>&1)
echo "$unit_out" | tail -5
if echo "$unit_out" | grep -q "Tests Failed"; then
  failed=$((failed+1))
  echo "unit: FAILED"
else
  passed=$((passed+1))
  echo "unit: PASSED"
fi

if [ "${HERDR_E2E:-0}" != "1" ]; then
  if herdr --version >/dev/null 2>&1; then
    HERDR_E2E=1
  else
    echo "herdr not installed; skipping e2e (set HERDR_E2E=1 to override)"
    echo "summary: $passed passed, $failed failed"
    [ "$failed" -eq 0 ]
    exit 0
  fi
fi

echo
for t in "$HERE"/test-*.bash; do
  echo "=== $(basename "$t") ==="
  if bash "$t"; then
    passed=$((passed+1))
  else
    failed=$((failed+1))
  fi
  echo
done

echo "summary: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
