#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [ "$expected" != "$actual" ]; then
    fail "${message} (expected='${expected}' actual='${actual}')"
  fi
}

assert_not_workspace_path() {
  local path="$1"
  local message="$2"
  if printf '%s' "$path" | grep -Eq '^/workspace/'; then
    fail "${message}: ${path}"
  fi
}

assert_not_workspace_home_path() {
  local path="$1"
  local message="$2"
  if printf '%s' "$path" | grep -Eq '^/workspace/.+/home(/|$)'; then
    fail "${message}: ${path}"
  fi
}

echo "Running ephemeral credential storage checks"

# shellcheck source=scripts/lib.sh
. scripts/lib.sh
# shellcheck source=scripts/opencode-helpers.sh
. scripts/opencode-helpers.sh

assert_eq "1" "$(normalize_ephemeral_credential_storage "1")" "normalize 1"
assert_eq "1" "$(normalize_ephemeral_credential_storage "true")" "normalize true"
assert_eq "0" "$(normalize_ephemeral_credential_storage "0")" "normalize 0"
assert_eq "0" "$(normalize_ephemeral_credential_storage "")" "normalize empty"
if normalize_ephemeral_credential_storage "invalid" >/dev/null 2>&1; then
  fail "normalize_ephemeral_credential_storage accepted invalid value"
fi

assert_eq \
  "/workspace/repo/run-123/home" \
  "$(resolve_job_home "/workspace/repo" "run-123" "0")" \
  "persistent run-once HOME path"
assert_eq \
  "/workspace/repo/homes/worker" \
  "$(resolve_managed_agent_home "/workspace/repo" "worker" "0")" \
  "persistent managed HOME path"

test_suffix="test-$$"
ephemeral_job_home="$(resolve_job_home "/workspace/repo" "$test_suffix" "1")"
ephemeral_agent_home="$(resolve_managed_agent_home "/workspace/repo" "$test_suffix" "1")"

assert_not_workspace_path "$ephemeral_job_home" "ephemeral run-once HOME must be outside /workspace"
assert_not_workspace_path "$ephemeral_agent_home" "ephemeral managed HOME must be outside /workspace"
assert_not_workspace_home_path "$ephemeral_job_home" "ephemeral run-once HOME must not match /workspace/**/home"

tmp_source_home="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_source_home"
  rm -rf "$ephemeral_job_home"
  rm -rf "$ephemeral_agent_home"
}
trap cleanup EXIT

mkdir -p "$tmp_source_home/.claude" "$tmp_source_home/.config/claude"
printf '%s' '{"claudeAiOauth":{"accessToken":"ephemeral-token","expiresAt":4102444800000}}' \
  > "$tmp_source_home/.claude/.credentials.json"
printf '%s' '{"hasCompletedOnboarding":true}' \
  > "$tmp_source_home/.claude.json"
printf '%s' '{"foo":"bar"}' > "$tmp_source_home/.config/claude/settings.json"

AGENT_PROVIDER=claude
seed_provider_auth "$ephemeral_job_home" "$tmp_source_home"
seed_shared_provider_state "$ephemeral_agent_home" "$tmp_source_home"

[ -f "$ephemeral_job_home/.claude/.credentials.json" ] \
  || fail "run-once auth seeding missing credentials in ephemeral HOME"
[ -f "$ephemeral_agent_home/.claude/.credentials.json" ] \
  || fail "managed auth seeding missing credentials in ephemeral HOME"
[ -f "$ephemeral_agent_home/.claude.json" ] \
  || fail "managed auth seeding missing onboarding file in ephemeral HOME"

echo "PASS: Ephemeral credential storage checks"
