#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "${ROOT_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT_DIR}/lib/manage.sh"

fail() {
  printf 'TEST FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local needle="$1"
  local haystack="$2"
  local message="$3"

  if [[ "${haystack}" != *"${needle}"* ]]; then
    fail "${message}: missing [${needle}]"
  fi
}

tmp_root="$(mktemp -d)"
trap 'rm -rf -- "${tmp_root}"' EXIT

LOG_DIRECTORY="${tmp_root}/logs"
mkdir -p -- "${LOG_DIRECTORY}"

cat > "${LOG_DIRECTORY}/backup.log" <<'EOF'
2026-07-27T14:00:00Z | server=prod | operation=backup | status=success | duration=12s | Snapshot completed
2026-07-27T14:05:00Z | server=prod | operation=prune | status=success | duration=2s | Removed 1 identical older snapshot(s)
2026-07-27T14:06:00Z | server=db01 | operation=backup | status=failed | duration=4s | SSH failed
EOF

load_global_config() { return 0; }

output="$(run_logs 10)"

assert_contains "TIME" "${output}" "logs output should include header"
assert_contains "operation" "${output}" "logs output should include operation values"
assert_contains "backup" "${output}" "logs output should include backup operation"
assert_contains "prune" "${output}" "logs output should include prune operation"
assert_contains "Snapshot completed" "${output}" "logs output should include detail text"

filtered_output="$(run_logs prod 10)"
assert_contains "prod" "${filtered_output}" "filtered logs should include matching server"
if [[ "${filtered_output}" == *"db01"* ]]; then
  fail "filtered logs should not include other servers"
fi

missing_output="$(run_logs unknown-server 10)"
assert_contains "No log entries found for server unknown-server." "${missing_output}" "missing server filter should show clear message"

printf 'TEST PASS: logs command shows readable recent entries\n'
