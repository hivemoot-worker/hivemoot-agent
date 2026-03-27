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

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"

  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'Actual output:\n%s\n' "$haystack" >&2
    fail "$message"
  fi
}

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

prompt_file="${tmp_dir}/custom-prompt.md"
printf '%s\n' "# Custom prompt" > "$prompt_file"

agent_ids=("worker")
agent_tokens=("install-token")
declare -A agent_skill_lists=()
unset AGENT_SKILLS || true

codex() {
  return 0
}

hivemoot() {
  return 0
}

gh() {
  local token="${GH_TOKEN:-}"

  if [ "${1:-}" != "api" ]; then
    return 1
  fi
  shift

  case "${1:-}" in
    user)
      [ "$token" = "user-token" ] && printf '%s\n' "user-login" && return 0
      return 1
      ;;
    installation)
      [ "$token" = "install-token" ] && printf '%s\n' "123" && return 0
      return 1
      ;;
    repos/owner/repo)
      if [ "$token" = "user-token" ] || [ "$token" = "install-token" ]; then
        printf '%s\n' "owner/repo"
        return 0
      fi
      return 1
      ;;
  esac

  return 1
}

log() {
  printf '%s\n' "$*"
}

# shellcheck source=scripts/lib.sh
. scripts/lib.sh
# shellcheck source=scripts/lib-slots.sh
. scripts/lib-slots.sh

echo "Running shared preflight helper checks"

test_preflight_allows_installation_tokens_outside_watch_mode() {
  local failures=0

  preflight_check_common "codex" "subscription" "$prompt_file" "owner/repo" "user_or_installation" "${tmp_dir}" \
    || failures=$?

  assert_eq "0" "$failures" \
    "preflight_check_common should accept installation tokens outside mention watch mode"
}

test_preflight_requires_user_tokens_for_watch_mode() {
  local stderr_file="${tmp_dir}/user-only.stderr"
  local failures=0

  set +e
  preflight_check_common "codex" "subscription" "$prompt_file" "owner/repo" "user_only" "${tmp_dir}" \
    > /dev/null 2> "$stderr_file"
  failures=$?
  set -e

  if [ "$failures" -eq 0 ]; then
    fail "preflight_check_common should fail when WATCH_MENTIONS requires a user token"
  fi

  assert_eq "1" "$failures" "user-only token validation should report exactly one failure"
  assert_contains "$(cat "$stderr_file")" \
    "Pre-flight: token for agent 'worker' is not a valid user token (required for WATCH_MENTIONS=1)." \
    "user-only token validation should explain the WATCH_MENTIONS requirement"
}

test_finish_preflight_check_failure_message() {
  local stderr_file="${tmp_dir}/finish.stderr"
  local status=0

  set +e
  (finish_preflight_check 2 "codex" "auto" "owner/repo" 1) > /dev/null 2> "$stderr_file"
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    fail "finish_preflight_check should exit non-zero when failures are present"
  fi

  assert_eq "1" "$status" "finish_preflight_check should exit 1 on failure"
  assert_contains "$(cat "$stderr_file")" \
    "Pre-flight: 2 check(s) failed. Fix the above errors and retry." \
    "finish_preflight_check should emit the standardized failure summary"
}

test_finish_preflight_check_success_message() {
  local stdout_file="${tmp_dir}/finish.stdout"

  finish_preflight_check 0 "codex" "auto" "owner/repo" 1 > "$stdout_file"

  assert_contains "$(cat "$stdout_file")" \
    "Pre-flight: all checks passed (provider=codex auth=auto repo=owner/repo agents=1)" \
    "finish_preflight_check should emit the standardized success summary"
}

test_preflight_allows_installation_tokens_outside_watch_mode
test_preflight_requires_user_tokens_for_watch_mode
test_finish_preflight_check_failure_message
test_finish_preflight_check_success_message

echo "PASS: shared preflight helper checks"
