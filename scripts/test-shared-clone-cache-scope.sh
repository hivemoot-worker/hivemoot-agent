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
    fail "${message} (expected=${expected} actual=${actual})"
  fi
}

assert_exists() {
  local path="$1"

  if [ ! -e "$path" ]; then
    fail "expected path to exist: ${path}"
  fi
}

assert_not_exists() {
  local path="$1"

  if [ -e "$path" ]; then
    fail "expected path to be absent: ${path}"
  fi
}

setup_mocks() {
  local mock_bin="$1"
  mkdir -p "$mock_bin"

  cat > "${mock_bin}/gh" <<'EOF_GH'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "api" ] && [ "${2:-}" = "user" ]; then
  printf '%s\n' "${MOCK_GH_LOGIN:?MOCK_GH_LOGIN is required}"
  exit 0
fi

if [ "${1:-}" = "api" ] && [[ "${2:-}" == repos/* ]]; then
  printf '%s\n' "${2#repos/}"
  exit 0
fi

if [ "${1:-}" = "auth" ] && [ "${2:-}" = "setup-git" ]; then
  exit 0
fi

echo "unexpected gh invocation: $*" >&2
exit 1
EOF_GH

  cat > "${mock_bin}/git" <<'EOF_GIT'
#!/usr/bin/env bash
set -euo pipefail

real_git="${REAL_GIT_BIN:?REAL_GIT_BIN is required}"
log_file="${MOCK_GIT_LOG_FILE:?MOCK_GIT_LOG_FILE is required}"

if [ "${1:-}" = "hash-object" ]; then
  exec "$real_git" "$@"
fi

if [ "${1:-}" = "-C" ]; then
  shift 2
fi

case "${1:-}" in
  clone)
    printf '%s\n' "$*" >> "$log_file"
    dest="${*: -1}"
    if printf '%s\n' "$*" | grep -Fq -- '--mirror'; then
      mkdir -p "$dest"
      : > "${dest}/packed-refs"
    else
      mkdir -p "${dest}/.git"
    fi
    exit 0
    ;;
  config|fetch|reset|clean|branch|rev-parse)
    exit 0
    ;;
esac

echo "unexpected git invocation: $*" >&2
exit 1
EOF_GIT

  cat > "${mock_bin}/codex" <<'EOF_CODEX'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "exec" ]; then
  printf '{"type":"thread.started","thread_id":"mock-thread"}\n'
  exit 0
fi

echo "unexpected codex invocation: $*" >&2
exit 1
EOF_CODEX

  chmod +x "${mock_bin}/gh" "${mock_bin}/git" "${mock_bin}/codex"
}

run_case() {
  local repo_root="$1"
  local case_dir="$2"
  local mock_bin="$3"
  local workspace_root="$4"
  local gh_login="$5"
  local stdout_log="${case_dir}/run.log"

  mkdir -p "$case_dir"

  if ! env -i \
      PATH="${mock_bin}:${PATH}" \
      HOME="${case_dir}/home" \
      REAL_GIT_BIN="${REAL_GIT_BIN}" \
      MOCK_GIT_LOG_FILE="${case_dir}/git.log" \
      MOCK_GH_LOGIN="${gh_login}" \
      TARGET_REPO="owner/repo" \
      WORKSPACE_ROOT="${workspace_root}" \
      AGENT_PROVIDER="codex" \
      AGENT_AUTH_MODE="api_key" \
      OPENAI_API_KEY="test-openai-key" \
      AGENT_GITHUB_TOKEN="test-github-token" \
      SHARED_CLONE_CACHE="1" \
      GIT_CLONE_DEPTH="1" \
      SESSION_RESUME="0" \
      bash "${repo_root}/scripts/run-once.sh" >"${stdout_log}" 2>&1; then
    sed 's/^/  /' "${stdout_log}" >&2 || true
    fail "run-once.sh failed for login ${gh_login}"
  fi
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d "${repo_root}/.tmp-shared-clone-cache-scope.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

REAL_GIT_BIN="$(command -v git)"

mock_bin="${tmpdir}/mock-bin"
setup_mocks "${mock_bin}"
shared_workspace_root="${tmpdir}/workspace"
run_case "$repo_root" "${tmpdir}/alice" "${mock_bin}" "${shared_workspace_root}" "alice"
run_case "$repo_root" "${tmpdir}/bob" "${mock_bin}" "${shared_workspace_root}" "bob"

alice_scope="$(printf '%s' 'user:alice' | "${REAL_GIT_BIN}" hash-object --stdin)"
bob_scope="$(printf '%s' 'user:bob' | "${REAL_GIT_BIN}" hash-object --stdin)"

alice_mirror="${shared_workspace_root}/.git-cache/owner/repo/${alice_scope}/mirror.git"
bob_mirror="${shared_workspace_root}/.git-cache/owner/repo/${bob_scope}/mirror.git"

assert_exists "${alice_mirror}/packed-refs"
assert_exists "${bob_mirror}/packed-refs"
assert_not_exists "${shared_workspace_root}/.git-cache/owner/repo/mirror.git"

mirror_scope_count="$(find "${shared_workspace_root}/.git-cache/owner/repo" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d '[:space:]')"
lock_count="$(find "${shared_workspace_root}/.git-cache/locks" -maxdepth 1 -name '*.lock' | wc -l | tr -d '[:space:]')"
assert_eq "2" "${mirror_scope_count}" "expected one mirror scope per token identity"
assert_eq "2" "${lock_count}" "expected one token-scoped lock file per token identity"

echo "PASS: shared clone cache scopes mirrors by token identity"
