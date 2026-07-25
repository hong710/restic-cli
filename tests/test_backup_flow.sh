#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "${ROOT_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT_DIR}/lib/backup.sh"
# shellcheck disable=SC1091
source "${ROOT_DIR}/lib/manage.sh"

fail() {
  printf 'TEST FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  [[ "${actual}" == "${expected}" ]] || fail "${message}: expected [${expected}], got [${actual}]"
}

assert_file_exists() {
  local path="$1"
  [[ -e "${path}" ]] || fail "missing expected file or directory: ${path}"
}

tmp_root="$(mktemp -d)"
trap 'rm -rf -- "${tmp_root}"' EXIT

TMP_DIR_DEFAULT="${tmp_root}/tmp"
mkdir -p -- "${TMP_DIR_DEFAULT}" "${tmp_root}/servers" "${tmp_root}/passwords" "${tmp_root}/backups"

SERVER_CONFIG_DIR="${tmp_root}/servers"
PASSWORD_DIRECTORY="${tmp_root}/passwords"
BACKUP_STORAGE="${tmp_root}/backups"
RESTORE_STORAGE="${tmp_root}/restore"
LOG_DIRECTORY="${tmp_root}/logs"
mkdir -p -- "${RESTORE_STORAGE}" "${LOG_DIRECTORY}"

cat > "${SERVER_CONFIG_DIR}/prod.conf" <<'EOF'
NAME="prod"
HOST="10.0.0.10"
USER="root"
SSH_PORT="22"
REPOSITORY="prod-repo"
BACKUP_PATHS="
/var/lib/app
"
BACKUP_FREQUENCY="once a day"
BACKUP_TIME="02:00"
BACKUP_DAY=""
BACKUP_ANCHOR_DATE=""
RETENTION_POLICY="5snapshots"
EOF

printf 'secret\n' > "${PASSWORD_DIRECTORY}/shared.pass"

load_server_config() {
  local server_name="$1"
  # shellcheck disable=SC1090
  source "${SERVER_CONFIG_DIR}/${server_name}.conf"
}

validate_ssh_connection() { return 0; }
validate_repository() { return 0; }
stage_remote_data() { return 0; }
apply_retention_policy() { return 0; }
record_last_backup_epoch() { return 0; }

run_restic_backup() {
  printf '%s\n' "$4" > "${tmp_root}/restic_backup_staging_dir"
  printf '%s\n' "$5" > "${tmp_root}/restic_backup_paths"
  printf 'yes\n' > "${tmp_root}/restic_backup_called"
}

run_prune_identical_snapshots() {
  printf '%s\n' "$1" > "${tmp_root}/prune_server"
  printf '%s\n' "${2:-no}" > "${tmp_root}/prune_auto_flag"
  printf 'yes\n' > "${tmp_root}/prune_called"
}

backup_one_server "prod"

assert_eq "yes" "$(<"${tmp_root}/restic_backup_called")" "backup helper should invoke restic backup"
assert_eq "${TMP_DIR_DEFAULT}/stage-prod" "$(<"${tmp_root}/restic_backup_staging_dir")" "backup should use a stable staging directory"
assert_eq "yes" "$(<"${tmp_root}/prune_called")" "backup should invoke identical-snapshot prune"
assert_eq "prod" "$(<"${tmp_root}/prune_server")" "prune should target the same server"
assert_eq "yes" "$(<"${tmp_root}/prune_auto_flag")" "prune should run in noninteractive mode"
assert_file_exists "${TMP_DIR_DEFAULT}/stage-prod"

printf 'TEST PASS: backup flow uses stable staging and automatic prune\n'