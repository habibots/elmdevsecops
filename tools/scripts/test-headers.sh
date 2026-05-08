#!/usr/bin/env bash
# Verifies expected security headers are present on the target URL.
# Usage: test-headers.sh <url>
set -euo pipefail
TARGET="${1:?usage: test-headers.sh <url>}"

REQUIRED_HEADERS=(
  "strict-transport-security"
  "x-content-type-options"
  "referrer-policy"
  "permissions-policy"
  "content-security-policy"
)

HEADERS=$(curl -fsSL -I "$TARGET" | tr '[:upper:]' '[:lower:]' || true)
FAIL=0
for h in "${REQUIRED_HEADERS[@]}"; do
  if echo "$HEADERS" | grep -q "^$h:"; then
    echo "PASS: $h"
  else
    echo "FAIL: missing $h"
    FAIL=1
  fi
done
exit $FAIL
