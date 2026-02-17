#!/usr/bin/env bash
set -euo pipefail

ignore_file="${1:-.trivyignore}"
report_file="${2:-trivy-report.json}"
today_utc="$(date -u +%Y-%m-%d)"

if [ ! -f "$ignore_file" ]; then
  echo "Ignore file not found: $ignore_file" >&2
  exit 1
fi

if [ ! -f "$report_file" ]; then
  echo "Trivy report not found: $report_file" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required for stale-ignore validation" >&2
  exit 1
fi

entries=""
pending_expiry=""
invalid_metadata=0
line_no=0
while IFS= read -r raw_line || [ -n "$raw_line" ]; do
  line_no=$((line_no + 1))
  line="${raw_line%$'\r'}"
  if [[ -z "${line//[[:space:]]/}" ]]; then
    continue
  fi

  if [[ "$line" =~ ^[[:space:]]*# ]]; then
    if [[ "$line" == *"exp:"* ]]; then
      if [[ "$line" =~ exp:([^[:space:]]+) ]]; then
        expiry_token="${BASH_REMATCH[1]}"
        if [[ ! "$expiry_token" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
          echo "Invalid expiry format in $ignore_file:$line_no: expected exp:YYYY-MM-DD" >&2
          invalid_metadata=1
          pending_expiry=""
          continue
        fi
        normalized_expiry="$(date -u -d "$expiry_token" +%Y-%m-%d 2>/dev/null || true)"
        if [[ "$normalized_expiry" != "$expiry_token" ]]; then
          echo "Invalid expiry date in $ignore_file:$line_no: $expiry_token" >&2
          invalid_metadata=1
          pending_expiry=""
          continue
        fi
        pending_expiry="$expiry_token"
      else
        echo "Invalid expiry metadata in $ignore_file:$line_no: expected exp:YYYY-MM-DD" >&2
        invalid_metadata=1
        pending_expiry=""
      fi
    fi
    continue
  fi

  if [[ "$line" =~ (CVE-[0-9]{4}-[0-9]+) ]]; then
    cve="${BASH_REMATCH[1]}"
    entries+="${cve}"$'\t'"${pending_expiry}"$'\n'
    pending_expiry=""
  fi
done < "$ignore_file"
entries="${entries%$'\n'}"

ignored_cves="$(printf '%s\n' "$entries" | cut -f1 | grep -E '^CVE-[0-9]{4}-[0-9]+$' | sort -u || true)"

if [ "$invalid_metadata" -ne 0 ]; then
  exit 1
fi

if [ -z "$ignored_cves" ]; then
  echo "No CVEs listed in $ignore_file"
  exit 0
fi

present_cves="$(jq -r '
  ..
  | objects
  | select(has("VulnerabilityID"))
  | .VulnerabilityID
' "$report_file" \
  | { grep -E '^CVE-[0-9]{4}-[0-9]+$' || true; } \
  | sort -u)"

stale_cves="$(comm -23 \
  <(printf '%s\n' "$ignored_cves") \
  <(printf '%s\n' "$present_cves"))"

exit_code=0

if [ -n "$stale_cves" ]; then
  echo "Stale CVE suppressions found in $ignore_file:" >&2
  while IFS= read -r cve; do
    [ -n "$cve" ] || continue
    echo "  - $cve" >&2
  done <<< "$stale_cves"
  echo "Remove stale entries or rerun Trivy if the report is outdated." >&2
  exit_code=1
fi

expired_entries="$(
  while IFS=$'\t' read -r cve expiry; do
    [ -n "$cve" ] || continue
    [ -n "$expiry" ] || continue
    if [[ "$expiry" < "$today_utc" ]]; then
      printf '%s\t%s\n' "$cve" "$expiry"
    fi
  done <<< "$entries"
)"

if [ -n "$expired_entries" ]; then
  echo "Expired CVE suppressions found in $ignore_file (today: $today_utc UTC):" >&2
  while IFS=$'\t' read -r cve expiry; do
    [ -n "$cve" ] || continue
    echo "  - $cve (expired $expiry)" >&2
  done <<< "$expired_entries"
  echo "Update or remove expired entries and rerun validation." >&2
  exit_code=1
fi

if [ "$exit_code" -ne 0 ]; then
  exit "$exit_code"
fi

echo "All CVEs in $ignore_file are present in $report_file and have valid expiries"
