#!/usr/bin/env bash
# Verifies TLS config against Mozilla Intermediate baseline.
# Requires: docker (for sslyze image) OR sslyze installed locally.
# Usage: test-tls.sh <hostname>
set -euo pipefail
TARGET="${1:?usage: test-tls.sh <hostname>}"

if command -v sslyze >/dev/null 2>&1; then
  RUNNER=(sslyze --json_out=/dev/stdout)
elif command -v docker >/dev/null 2>&1; then
  RUNNER=(docker run --rm nablac0d3/sslyze:latest --json_out=/dev/stdout)
else
  echo "ERROR: sslyze or docker required" >&2
  exit 2
fi

OUTPUT=$("${RUNNER[@]}" "$TARGET" 2>/dev/null)

if echo "$OUTPUT" | jq -e '
    .server_scan_results[0].scan_result
    | (.tls_1_0_cipher_suites.result.accepted_cipher_suites | length == 0)
    and (.tls_1_1_cipher_suites.result.accepted_cipher_suites | length == 0)
    and (.tls_1_3_cipher_suites.result.accepted_cipher_suites | length > 0)
    and (.heartbleed.result.is_vulnerable_to_heartbleed == false)
    and (.robot.result.robot_result == "NOT_VULNERABLE_NO_ORACLE")
' >/dev/null 2>&1; then
  echo "TLS baseline PASS: $TARGET"
  exit 0
else
  echo "TLS baseline FAIL: $TARGET"
  echo "$OUTPUT" | jq '.server_scan_results[0].scan_result | {tls_1_0:.tls_1_0_cipher_suites.result.accepted_cipher_suites, tls_1_1:.tls_1_1_cipher_suites.result.accepted_cipher_suites, tls_1_3:.tls_1_3_cipher_suites.result.accepted_cipher_suites|length, heartbleed:.heartbleed.result.is_vulnerable_to_heartbleed, robot:.robot.result.robot_result}' 2>/dev/null
  exit 1
fi
