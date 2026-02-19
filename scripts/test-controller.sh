#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_contains() {
  local file="$1"
  local expected="$2"

  if ! grep -Fq -- "$expected" "$file"; then
    echo "Expected to find: $expected" >&2
    echo "In file: $file" >&2
    sed 's/^/  /' "$file" >&2 || true
    fail "missing expected content"
  fi
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  if [ "$expected" != "$actual" ]; then
    fail "${message} (expected=${expected} actual=${actual})"
  fi
}

setup_mock_docker() {
  local mock_bin="$1"
  mkdir -p "$mock_bin"

  cat > "${mock_bin}/docker" <<'EOF_MOCK'
#!/usr/bin/env bash
set -euo pipefail

state_dir="${MOCK_DOCKER_STATE_DIR:?MOCK_DOCKER_STATE_DIR is required}"
mkdir -p "$state_dir"

cmd="${1:-}"
shift || true

counter_file="${state_dir}/counter"
active_file="${state_dir}/active-container"
run_log_file="${state_dir}/docker-run.log"
overlap_file="${state_dir}/overlap.log"

next_id() {
  local current=0
  if [ -f "$counter_file" ]; then
    current="$(cat "$counter_file")"
  fi
  current=$((current + 1))
  printf '%s' "$current" > "$counter_file"
  printf 'mock-container-%s' "$current"
}

case "$cmd" in
  run)
    if [ -s "$active_file" ]; then
      echo "overlap" >> "$overlap_file"
    fi

    printf '%s\n' "$*" >> "$run_log_file"

    container_id="$(next_id)"
    printf '%s\n' "$container_id" > "$active_file"
    printf '%s\n' "$container_id"
    ;;

  logs)
    # Keep an active process for `docker logs -f` until controller kills it.
    echo "mock log stream"
    while true; do
      sleep 1
    done
    ;;

  wait)
    sleep "${MOCK_DOCKER_WAIT_SLEEP_SECS:-0}"
    printf '%s\n' "${MOCK_DOCKER_WAIT_EXIT:-0}"
    ;;

  rm)
    rm -f "$active_file"
    ;;

  ps)
    if [ -s "$active_file" ]; then
      cat "$active_file"
    fi
    ;;

  stop)
    rm -f "$active_file"
    ;;

  *)
    echo "unexpected docker invocation: ${cmd} $*" >&2
    exit 1
    ;;
esac
EOF_MOCK

  chmod +x "${mock_bin}/docker"
}

run_success_case() {
  local repo_root="$1"
  local case_dir="$2"

  mkdir -p "$case_dir"
  setup_mock_docker "${case_dir}/mock-bin"

  env -i \
    PATH="${case_dir}/mock-bin:${PATH}" \
    HOME="${case_dir}/home" \
    MOCK_DOCKER_STATE_DIR="${case_dir}/mock-state" \
    MOCK_DOCKER_WAIT_SLEEP_SECS="1" \
    TARGET_REPO="owner/repo" \
    CONTROLLER_RUN_MODE="once" \
    CONTROLLER_MAX_WORKERS="2" \
    CONTROLLER_WORKSPACE_ROOT="${case_dir}/workspace" \
    WORKER_IMAGE="hivemoot-agent:test" \
    AGENT_ID_01="worker" \
    AGENT_GITHUB_TOKEN_01="token-1" \
    AGENT_ID_02="builder" \
    AGENT_GITHUB_TOKEN_02="token-2" \
    AGENT_TIMEOUT_SECONDS="120" \
    PERIODIC_INTERVAL_SECS="60" \
    PERIODIC_JITTER_SECS="0" \
    bash "${repo_root}/scripts/controller.sh"

  if [ -s "${case_dir}/mock-state/overlap.log" ]; then
    fail "per-repo lock failed; detected overlapping worker launches"
  fi

  run_log="${case_dir}/mock-state/docker-run.log"
  [ -f "$run_log" ] || fail "missing docker run log"

  assert_file_contains "$run_log" "--cap-drop=ALL"
  assert_file_contains "$run_log" "--security-opt=no-new-privileges"
  assert_file_contains "$run_log" "--read-only"
  assert_file_contains "$run_log" "--tmpfs /tmp:size=2g,mode=1777"
  assert_file_contains "$run_log" "--tmpfs /usr/local/share/npm-global:size=1g"
  assert_file_contains "$run_log" "-e RUN_MODE=once"
  assert_file_contains "$run_log" "-e TARGET_REPO=owner/repo"
  assert_file_contains "$run_log" "-e JOB_ID="
  assert_file_contains "$run_log" "-e HIVEMOOT_CLI_UPDATE=skip"

  shopt -s nullglob
  status_files=("${case_dir}/workspace"/workspaces/*/.hivemoot/status)
  summary_files=("${case_dir}/workspace"/workspaces/*/.hivemoot/summary)
  job_specs=("${case_dir}/workspace"/jobs/*/job.json)
  shopt -u nullglob

  assert_eq "2" "${#status_files[@]}" "expected one status file per agent"
  assert_eq "2" "${#summary_files[@]}" "expected one summary file per agent"
  assert_eq "2" "${#job_specs[@]}" "expected one job spec per agent"

  for status_file in "${status_files[@]}"; do
    assert_eq "completed" "$(cat "$status_file")" "expected completed job status"
  done

  for summary_file in "${summary_files[@]}"; do
    assert_file_contains "$summary_file" "status=completed"
    assert_file_contains "$summary_file" "trigger=periodic"
    assert_file_contains "$summary_file" "exit_code=0"
  done

  for spec_file in "${job_specs[@]}"; do
    assert_file_contains "$spec_file" '"trigger": {'
    assert_file_contains "$spec_file" '"type": "periodic"'
    assert_file_contains "$spec_file" '"timeout_seconds": 120'
  done

  echo "PASS: success case writes expected spawn flags and job artifacts"
}

run_failure_case() {
  local repo_root="$1"
  local case_dir="$2"

  mkdir -p "$case_dir"
  setup_mock_docker "${case_dir}/mock-bin"

  if env -i \
    PATH="${case_dir}/mock-bin:${PATH}" \
    HOME="${case_dir}/home" \
    MOCK_DOCKER_STATE_DIR="${case_dir}/mock-state" \
    MOCK_DOCKER_WAIT_EXIT="17" \
    TARGET_REPO="owner/repo" \
    CONTROLLER_RUN_MODE="once" \
    CONTROLLER_MAX_WORKERS="1" \
    CONTROLLER_WORKSPACE_ROOT="${case_dir}/workspace" \
    WORKER_IMAGE="hivemoot-agent:test" \
    AGENT_ID_01="worker" \
    AGENT_GITHUB_TOKEN_01="token-1" \
    AGENT_TIMEOUT_SECONDS="90" \
    PERIODIC_INTERVAL_SECS="60" \
    PERIODIC_JITTER_SECS="0" \
    bash "${repo_root}/scripts/controller.sh"; then
    fail "controller succeeded unexpectedly in failure case"
  fi

  shopt -s nullglob
  status_files=("${case_dir}/workspace"/workspaces/*/.hivemoot/status)
  summary_files=("${case_dir}/workspace"/workspaces/*/.hivemoot/summary)
  shopt -u nullglob

  assert_eq "1" "${#status_files[@]}" "expected one status file"
  assert_eq "1" "${#summary_files[@]}" "expected one summary file"

  assert_eq "failed" "$(cat "${status_files[0]}")" "expected failed job status"
  assert_file_contains "${summary_files[0]}" "status=failed"
  assert_file_contains "${summary_files[0]}" "exit_code=17"

  echo "PASS: failure case records failed sentinel with exit code"
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d "${repo_root}/.tmp-controller-test.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

echo "Running controller script checks"
run_success_case "$repo_root" "${tmpdir}/success"
run_failure_case "$repo_root" "${tmpdir}/failure"
echo "PASS: controller script checks"
