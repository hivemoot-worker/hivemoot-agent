#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_fails_with() {
  local expected="$1"
  shift

  local stderr_file
  stderr_file="$(mktemp)"

  if "$@" > /dev/null 2> "$stderr_file"; then
    rm -f "$stderr_file"
    fail "command succeeded unexpectedly: $*"
  fi

  if ! grep -Fqx "$expected" "$stderr_file"; then
    echo "Expected stderr line:" >&2
    echo "  $expected" >&2
    echo "Actual stderr:" >&2
    sed 's/^/  /' "$stderr_file" >&2
    rm -f "$stderr_file"
    fail "stderr mismatch for: $*"
  fi

  rm -f "$stderr_file"
}

echo "Running workspace root and agent ID validation checks"

assert_fails_with \
  "WORKSPACE_ROOT must be an absolute path" \
  env TARGET_REPO=owner/repo WORKSPACE_ROOT=relative bash scripts/run-once.sh

assert_fails_with \
  "WORKSPACE_ROOT must be an absolute path" \
  env TARGET_REPO=owner/repo WORKSPACE_ROOT=relative AGENT_ID_01=worker AGENT_GITHUB_TOKEN_01=dummy bash scripts/run-multi.sh

assert_fails_with \
  "WORKSPACE_ROOT must be an absolute path" \
  env TARGET_REPO=owner/repo WORKSPACE_ROOT=relative AGENT_ID_01=worker AGENT_GITHUB_TOKEN_01=dummy bash scripts/run-loop.sh

assert_fails_with \
  "Invalid AGENT_ID: ." \
  env TARGET_REPO=owner/repo AGENT_ID_01=. AGENT_GITHUB_TOKEN_01=dummy bash scripts/run-multi.sh

assert_fails_with \
  "Invalid AGENT_ID: ." \
  env TARGET_REPO=owner/repo AGENT_ID_01=. AGENT_GITHUB_TOKEN_01=dummy bash scripts/run-loop.sh

assert_fails_with \
  "Invalid AGENT_ID: .." \
  env TARGET_REPO=owner/repo AGENT_ID_01=.. AGENT_GITHUB_TOKEN_01=dummy bash scripts/run-multi.sh

assert_fails_with \
  "Invalid AGENT_ID: .." \
  env TARGET_REPO=owner/repo AGENT_ID_01=.. AGENT_GITHUB_TOKEN_01=dummy bash scripts/run-loop.sh

echo "PASS: workspace root and agent ID validation checks"

echo "Running GIT_CLONE_DEPTH validation checks"

assert_fails_with \
  "Unsupported GIT_CLONE_DEPTH: abc. Use 0 (full clone) or a positive integer." \
  env TARGET_REPO=owner/repo GIT_CLONE_DEPTH=abc bash scripts/run-once.sh

assert_fails_with \
  "Unsupported GIT_CLONE_DEPTH: -1. Use 0 (full clone) or a positive integer." \
  env TARGET_REPO=owner/repo GIT_CLONE_DEPTH=-1 bash scripts/run-once.sh

assert_fails_with \
  "Unsupported GIT_CLONE_DEPTH: 1.5. Use 0 (full clone) or a positive integer." \
  env TARGET_REPO=owner/repo GIT_CLONE_DEPTH=1.5 bash scripts/run-once.sh

echo "PASS: GIT_CLONE_DEPTH validation checks"

echo "Running JOB_ID validation checks"

assert_fails_with \
  "Invalid JOB_ID: ../../etc. Use only letters, digits, hyphens, and underscores." \
  env TARGET_REPO=owner/repo JOB_ID=../../etc bash scripts/run-once.sh

assert_fails_with \
  "Invalid JOB_ID: ../escape. Use only letters, digits, hyphens, and underscores." \
  env TARGET_REPO=owner/repo JOB_ID=../escape bash scripts/run-once.sh

assert_fails_with \
  "Invalid JOB_ID: bad/slash. Use only letters, digits, hyphens, and underscores." \
  env TARGET_REPO=owner/repo JOB_ID=bad/slash bash scripts/run-once.sh

assert_fails_with \
  "Invalid JOB_ID: /abs/path. Use only letters, digits, hyphens, and underscores." \
  env TARGET_REPO=owner/repo 'JOB_ID=/abs/path' bash scripts/run-once.sh

assert_fails_with \
  "Invalid JOB_ID: job id. Use only letters, digits, hyphens, and underscores." \
  env TARGET_REPO=owner/repo 'JOB_ID=job id' bash scripts/run-once.sh

assert_fails_with \
  'Invalid JOB_ID: job;id. Use only letters, digits, hyphens, and underscores.' \
  env TARGET_REPO=owner/repo 'JOB_ID=job;id' bash scripts/run-once.sh

echo "PASS: JOB_ID validation checks"

echo "Running URL scheme validation checks"

# Source lib.sh to test validate_url_scheme directly.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"

if ! validate_url_scheme "https://example.com/api"; then
  fail "validate_url_scheme should accept https:// URLs"
fi

if ! validate_url_scheme "http://localhost:3000"; then
  fail "validate_url_scheme should accept http:// URLs"
fi

assert_fails_with \
  "Refusing to send credentials to URL with invalid scheme: file:///etc/passwd" \
  validate_url_scheme "file:///etc/passwd"

assert_fails_with \
  "Refusing to send credentials to URL with invalid scheme: ftp://evil.com" \
  validate_url_scheme "ftp://evil.com"

assert_fails_with \
  "Refusing to send credentials to URL with invalid scheme: gopher://evil.com" \
  validate_url_scheme "gopher://evil.com"

assert_fails_with \
  "Refusing to send credentials to URL with invalid scheme: javascript:alert(1)" \
  validate_url_scheme "javascript:alert(1)"

assert_fails_with \
  "Refusing to send credentials to URL with invalid scheme: " \
  validate_url_scheme ""

assert_fails_with \
  "Refusing to send credentials to URL with invalid scheme: no-scheme.com/path" \
  validate_url_scheme "no-scheme.com/path"

echo "PASS: URL scheme validation checks"
