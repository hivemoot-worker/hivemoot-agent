#!/usr/bin/env bash
# shellcheck disable=SC2154  # globals are supplied by controller/main.sh

[ -n "${HIVEMOOT_CONTROLLER_CORE_COMMON_LOADED:-}" ] && return 0
HIVEMOOT_CONTROLLER_CORE_COMMON_LOADED=1

sanitize_lock_key() {
  local value="$1"
  printf '%s' "$value" | tr -c 'A-Za-z0-9' '_'
}

ensure_agent_lock_file() {
  local repo="$1"
  local agent_id="$2"
  local lock_key="${repo}:${agent_id}"
  local repo_key=""
  local lock_file="${repo_lock_files[$lock_key]:-}"

  if [ -n "$lock_file" ]; then
    return 0
  fi

  repo_key="$(sanitize_lock_key "${repo}__${agent_id}")"
  lock_file="${lock_dir}/agent-${repo_key}.lock"
  mkdir -p "$(dirname "$lock_file")"
  : > "$lock_file"
  chmod 600 "$lock_file" 2>/dev/null || true
  repo_lock_files["$lock_key"]="$lock_file"
}

generate_job_id() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    tr '[:upper:]' '[:lower:]' < /proc/sys/kernel/random/uuid | head -n 1
    return 0
  fi

  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
    return 0
  fi

  printf 'job-%s-%s' "$(date +%s)" "$RANDOM"
}

write_job_spec() {
  local job_file="$1"
  local job_id="$2"
  local repo="$3"
  local agent_id="$4"
  local trigger_type="$5"
  local timeout_seconds="$6"

  cat > "$job_file" <<JSON
{
  "job_id": "${job_id}",
  "repo": "${repo}",
  "agent_id": "${agent_id}",
  "role": "${agent_id}",
  "trigger": {
    "type": "${trigger_type}"
  },
  "timeout_seconds": ${timeout_seconds}
}
JSON
}

write_job_status() {
  local job_workspace="$1"
  local job_id="$2"
  local repo="$3"
  local agent_id="$4"
  local trigger_type="$5"
  local status="$6"
  local exit_code="$7"

  local status_dir="${job_workspace}/.hivemoot"
  local status_file="${status_dir}/status"
  local summary_file="${status_dir}/summary"

  mkdir -p "$status_dir"

  printf '%s\n' "$status" > "$status_file"
  cat > "$summary_file" <<EOF_SUMMARY
job_id=${job_id}
repo=${repo}
agent_id=${agent_id}
trigger=${trigger_type}
status=${status}
exit_code=${exit_code}
updated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF_SUMMARY
}

global_slot_timeout_for_trigger() {
  local trigger_type="$1"
  trigger_type="$(normalize_trigger_name "$trigger_type")"
  controller_invoke_trigger_hook global_slot_timeout_secs "$trigger_type"
}

mark_global_slot_timeout() {
  local job_state_dir="$1"
  local timeout_secs="$2"
  local marker_file="${job_state_dir}/global-slot-timeout"

  mkdir -p "$job_state_dir"
  cat > "$marker_file" <<EOF_TIMEOUT
timeout_secs=${timeout_secs}
EOF_TIMEOUT
  chmod 600 "$marker_file" 2>/dev/null || true
}

mark_shutdown_cancelled() {
  local job_run_dir="$1"
  local marker_file="${job_run_dir}/shutdown-cancelled"

  mkdir -p "$job_run_dir"
  : > "$marker_file"
  chmod 600 "$marker_file" 2>/dev/null || true
}

read_global_slot_timeout_secs() {
  local marker_file="$1"
  awk -F= '/^timeout_secs=/{print $2; exit}' "$marker_file" 2>/dev/null || true
}

agent_backoff_file() {
  local agent_id="$1"
  printf '%s/%s\n' "$agent_backoff_root" "$agent_id"
}

classify_periodic_failure() {
  local log_file="$1"
  local classified=""

  [ -s "$log_file" ] || {
    printf 'normal\n'
    return 0
  }

  if grep -qiF \
    -e 'TerminalQuotaError' \
    -e 'quota exhausted' \
    -e 'billing_hard_limit_reached' \
    -e 'You have exhausted your capacity' \
    -e '429 Too Many Requests' \
    -e 'rate_limit_exceeded' \
    "$log_file" 2>/dev/null; then
    printf 'quota\n'
    return 0
  fi

  classified="$(classify_worker_log_failure "$log_file" 2>/dev/null || true)"
  if [ -n "$classified" ]; then
    printf 'auth\n'
    return 0
  fi

  if grep -qiF \
    -e 'authentication failed' \
    -e 'auth error' \
    -e 'token expired' \
    -e 'Invalid API key' \
    -e 'Unauthorized' \
    "$log_file" 2>/dev/null; then
    printf 'auth\n'
    return 0
  fi

  printf 'normal\n'
}

calculate_quota_backoff_delay() {
  local consecutive="$1"
  local delay="$quota_backoff_floor_secs"
  local attempt=0

  if [ "$consecutive" -le 0 ] || [ "$delay" -le 0 ]; then
    printf '0\n'
    return 0
  fi

  for ((attempt = 1; attempt < consecutive; attempt++)); do
    if [ "$delay" -ge "$quota_backoff_max_secs" ]; then
      delay="$quota_backoff_max_secs"
      break
    fi
    delay=$((delay * 2))
  done

  if [ "$delay" -gt "$quota_backoff_max_secs" ]; then
    delay="$quota_backoff_max_secs"
  fi

  if [ "$quota_backoff_jitter_pct" -gt 0 ] && [ "$delay" -gt 0 ]; then
    local jitter=$((delay * quota_backoff_jitter_pct / 100))
    if [ "$jitter" -gt 0 ]; then
      local span=$((jitter * 2 + 1))
      local offset=$((RANDOM % span - jitter))
      delay=$((delay + offset))
      if [ "$delay" -lt 1 ]; then
        delay=1
      fi
    fi
  fi

  printf '%s\n' "$delay"
}

read_agent_backoff_until() {
  local agent_id="$1"
  local backoff_file=""
  local backoff_until=""

  backoff_file="$(agent_backoff_file "$agent_id")"
  [ -f "$backoff_file" ] || {
    printf '0\n'
    return 0
  }

  backoff_until="$(awk -F= '/^backoff_until=/{print $2; exit}' "$backoff_file" 2>/dev/null || true)"
  case "$backoff_until" in
    ''|*[!0-9]*)
      printf '0\n'
      ;;
    *)
      printf '%s\n' "$backoff_until"
      ;;
  esac
}

read_agent_backoff_consecutive() {
  local agent_id="$1"
  local backoff_file=""
  local consecutive=""

  backoff_file="$(agent_backoff_file "$agent_id")"
  [ -f "$backoff_file" ] || {
    printf '0\n'
    return 0
  }

  consecutive="$(awk -F= '/^consecutive=/{print $2; exit}' "$backoff_file" 2>/dev/null || true)"
  case "$consecutive" in
    ''|*[!0-9]*)
      printf '0\n'
      ;;
    *)
      printf '%s\n' "$consecutive"
      ;;
  esac
}

write_agent_backoff() {
  local agent_id="$1"
  local backoff_until="$2"
  local consecutive="$3"
  local backoff_file=""

  backoff_file="$(agent_backoff_file "$agent_id")"
  mkdir -p "$agent_backoff_root"
  printf 'backoff_until=%s\nconsecutive=%s\n' "$backoff_until" "$consecutive" > "$backoff_file"
  chmod 600 "$backoff_file" 2>/dev/null || true
}

clear_agent_backoff() {
  local agent_id="$1"
  rm -f "$(agent_backoff_file "$agent_id")" 2>/dev/null || true
}

append_env_if_set() {
  local var_name="$1"
  local value="${!var_name:-}"

  if [ -n "$value" ]; then
    docker_run_args+=( -e "${var_name}=${value}" )
  fi
}

append_bind_mount_specs() {
  local var_name="$1"
  local mounts="${!var_name:-}"
  local mount_spec=""

  [ -z "$mounts" ] && return 0

  while IFS= read -r mount_spec; do
    mount_spec="$(trim "$mount_spec")"
    [ -z "$mount_spec" ] && continue
    case "$mount_spec" in
      *..*)
        echo "${var_name} contains path traversal: ${mount_spec}" >&2
        return 1
        ;;
      /*:/opt/hivemoot-agent/skills/*:ro) ;;
      /*:/opt/hivemoot-agent/workloads/*/skills/*:ro) ;;
      *)
        echo "${var_name} contains invalid mount spec: ${mount_spec}" >&2
        return 1
        ;;
    esac
    docker_run_args+=( -v "$mount_spec" )
  done <<< "$mounts"
}

append_secret_env() {
  local var_name="$1"
  local file_var_name="${var_name}_FILE"
  local value="${!var_name:-}"
  local file_value="${!file_var_name:-}"

  if [ -n "$value" ] && [ -n "$file_value" ]; then
    echo "Set either ${var_name} or ${file_var_name}, not both." >&2
    return 1
  fi

  if [ -n "$file_value" ]; then
    case "$file_value" in
      /*) ;;
      *)
        echo "${file_var_name} must be an absolute path when mounting secret files: ${file_value}" >&2
        return 1
        ;;
    esac
    if [ ! -f "$file_value" ]; then
      echo "${file_var_name} does not exist: ${file_value}" >&2
      return 1
    fi
    docker_run_args+=( -v "${file_value}:${file_value}:ro" )
    docker_run_args+=( -e "${file_var_name}=${file_value}" )
    return 0
  fi

  if [ -n "$value" ]; then
    docker_run_args+=( -e "${var_name}=${value}" )
  fi
}

cleanup_job_home_credentials() {
  local job_home="$1"
  local gemini_auth_dir="${job_home}/.gemini"
  local auth_file=""
  local -a gemini_auth_files=(
    "oauth_creds.json"
    "google_accounts.json"
    "settings.json"
    "mcp-oauth-tokens.json"
    "mcp-oauth-tokens-v2.json"
    ".env"
  )

  rm -f "${job_home}/.codex/auth.json" 2>/dev/null || true
  rmdir "${job_home}/.codex" 2>/dev/null || true

  for auth_file in "${gemini_auth_files[@]}"; do
    rm -f "${gemini_auth_dir}/${auth_file}" 2>/dev/null || true
  done
  rmdir "${gemini_auth_dir}" 2>/dev/null || true
}

classify_worker_log_failure() {
  classify_run_failure_from_file "$1"
}

file_mtime_epoch() {
  local path="$1"
  local fallback="$2"
  local mtime=""

  if mtime="$(stat -c %Y "$path" 2>/dev/null)"; then
    printf '%s\n' "$mtime"
    return 0
  fi

  if mtime="$(stat -f %m "$path" 2>/dev/null)"; then
    printf '%s\n' "$mtime"
    return 0
  fi

  printf '%s\n' "$fallback"
}
