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

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  [[ "${actual}" == "${expected}" ]] || fail "${message}: expected [${expected}], got [${actual}]"
}

count_matches() {
  local needle="$1"
  local haystack="$2"

  python3 -c 'import sys; print(sys.argv[2].count(sys.argv[1]))' "${needle}" "${haystack}"
}

tmp_root="$(mktemp -d)"
trap 'rm -rf -- "${tmp_root}"' EXIT

SERVER_CONFIG_DIR="${tmp_root}/servers"
PASSWORD_DIRECTORY="${tmp_root}/passwords"
BACKUP_STORAGE="${tmp_root}/backups"
RESTORE_STORAGE="${tmp_root}/restore"
LOG_DIRECTORY="${tmp_root}/logs"
mkdir -p -- "${SERVER_CONFIG_DIR}" "${PASSWORD_DIRECTORY}" "${BACKUP_STORAGE}" "${RESTORE_STORAGE}" "${LOG_DIRECTORY}"

TMP_DIR_DEFAULT="${tmp_root}/tmp"
mkdir -p -- "${TMP_DIR_DEFAULT}"

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

validate_repository() { return 0; }
ensure_local_restic() { return 0; }

prompt_yes_no() {
  local _prompt="$1"
  local _result_var="$2"
  local _default="$3"
  printf -v "${_result_var}" '%s' yes
}

TEST_SCENARIO="duplicates"

restic() {
  local joined="$*"

  if [[ "${joined}" == *' snapshots --host prod --json' ]]; then
    if [[ "${TEST_SCENARIO}" == "duplicates" ]]; then
      cat <<'JSON'
[
  {"time":"2026-07-25T03:16:28","id":"old1","paths":["/home/nfs/restic/restic-cli/tmp/stage-prod.Ejbalm/root/app/finbook/docker/data"],"hostname":"prod","tree":"tree-abc"},
  {"time":"2026-07-25T03:23:26","id":"old2","paths":["/home/nfs/restic/restic-cli/tmp/stage-prod.FxX35Z/root/app/finbook/docker/data"],"hostname":"prod","tree":"tree-abc"},
  {"time":"2026-07-25T04:01:27","id":"new3","paths":["/home/nfs/restic/restic-cli/tmp/stage-prod/root/app/finbook/docker/data"],"hostname":"prod","tree":"tree-abc"}
]
JSON
      return 0
    fi

    if [[ "${TEST_SCENARIO}" == "dirs_only_changed" ]]; then
      cat <<'JSON'
[
  {"time":"2026-07-25T03:16:28","id":"old1","paths":["/home/nfs/restic/restic-cli/tmp/stage-prod.Ejbalm/root/app/finbook/docker/data"],"hostname":"prod","tree":"tree-abc"},
  {"time":"2026-07-25T04:01:27","id":"new3","paths":["/home/nfs/restic/restic-cli/tmp/stage-prod/root/app/finbook/docker/data"],"hostname":"prod","tree":"tree-def"}
]
JSON
      return 0
    fi

    if [[ "${TEST_SCENARIO}" == "trailing_slash" ]]; then
      cat <<'JSON'
[
  {"time":"2026-07-25T03:16:28","id":"old1","paths":["/home/nfs/restic/restic-cli/tmp/stage-prod.Ejbalm/root/app/finbook/docker/data/"],"hostname":"prod","tree":"tree-abc"},
  {"time":"2026-07-25T04:01:27","id":"new3","paths":["/home/nfs/restic/restic-cli/tmp/stage-prod/root/app/finbook/docker/data"],"hostname":"prod","tree":"tree-def"}
]
JSON
      return 0
    fi

    if [[ "${TEST_SCENARIO}" == "dir_added" ]]; then
      cat <<'JSON'
[
  {"time":"2026-07-25T03:16:28","id":"old1","paths":["/home/nfs/restic/restic-cli/tmp/stage-prod.Ejbalm/root/app/finbook/docker/data"],"hostname":"prod","tree":"tree-abc"},
  {"time":"2026-07-25T04:01:27","id":"new3","paths":["/home/nfs/restic/restic-cli/tmp/stage-prod/root/app/finbook/docker/data"],"hostname":"prod","tree":"tree-dir-added"}
]
JSON
      return 0
    fi

    cat <<'JSON'
[
  {"time":"2026-07-25T03:16:28","id":"old1","paths":["/home/nfs/restic/restic-cli/tmp/stage-prod.Ejbalm/root/app/finbook/docker/data"],"hostname":"prod","tree":"tree-abc"},
  {"time":"2026-07-25T04:01:27","id":"new3","paths":["/home/nfs/restic/restic-cli/tmp/stage-prod/root/app/finbook/docker/data"],"hostname":"prod","tree":"tree-def"}
]
JSON
    return 0
  fi

  if [[ "${joined}" == *' diff old1 new3' ]]; then
    if [[ "${TEST_SCENARIO}" == "dirs_only_changed" || "${TEST_SCENARIO}" == "trailing_slash" ]]; then
      cat <<'EOF'
Files:           0 new,     0 removed,     0 changed
Dirs:            0 new,     0 removed,     3 changed
Others:          0 new,     0 removed
EOF
      return 0
    fi

    if [[ "${TEST_SCENARIO}" == "dir_added" ]]; then
      cat <<'EOF'
Files:           0 new,     0 removed,     0 changed
Dirs:            1 new,     0 removed,     3 changed
Others:          0 new,     0 removed
EOF
      return 0
    fi

    if [[ "${TEST_SCENARIO}" == "dirs_line_no_changed" ]]; then
      cat <<'EOF'
Files:           0 new,     0 removed,     0 changed
Dirs:            0 new,     0 removed
Others:          0 new,     0 removed
EOF
      return 0
    fi

    cat <<'EOF'
Files:           0 new,     0 removed,     1 changed
Dirs:            0 new,     0 removed,     3 changed
Others:          0 new,     0 removed
EOF
    return 0
  fi

  if [[ "${joined}" == *' forget '* ]]; then
    printf '%s\n' "${joined}" > "${tmp_root}/forget_args"
    return 0
  fi

  fail "unexpected restic invocation: ${joined}"
}

load_global_config() { return 0; }
print_header() { return 0; }
msg_info() { return 0; }
msg_success() { return 0; }

run_prune_identical_snapshots "prod" yes

forget_args="$(<"${tmp_root}/forget_args")"
assert_eq 1 "$(count_matches 'old1' "${forget_args}")" "older snapshot old1 should be forgotten"
assert_eq 1 "$(count_matches 'old2' "${forget_args}")" "older snapshot old2 should be forgotten"
assert_eq 0 "$(count_matches 'new3' "${forget_args}")" "latest snapshot new3 should not be forgotten"

rm -f -- "${tmp_root}/forget_args"
TEST_SCENARIO="dirs_only_changed"
run_prune_identical_snapshots "prod" yes

forget_args="$(<"${tmp_root}/forget_args")"
assert_eq 1 "$(count_matches 'old1' "${forget_args}")" "dirs-only changed should forget older snapshot"
assert_eq 0 "$(count_matches 'new3' "${forget_args}")" "dirs-only changed should keep latest snapshot"

rm -f -- "${tmp_root}/forget_args"
TEST_SCENARIO="trailing_slash"
run_prune_identical_snapshots "prod" yes

forget_args="$(<"${tmp_root}/forget_args")"
assert_eq 1 "$(count_matches 'old1' "${forget_args}")" "trailing slash path should still be treated as duplicate"
assert_eq 0 "$(count_matches 'new3' "${forget_args}")" "trailing slash path should keep latest snapshot"

rm -f -- "${tmp_root}/forget_args"
TEST_SCENARIO="changed"
run_prune_identical_snapshots "prod" yes

if [[ -f "${tmp_root}/forget_args" ]]; then
  fail "changed snapshot content should not be forgotten"
fi

rm -f -- "${tmp_root}/forget_args"
TEST_SCENARIO="dir_added"
run_prune_identical_snapshots "prod" yes

if [[ -f "${tmp_root}/forget_args" ]]; then
  fail "new directory should prevent pruning as identical"
fi

rm -f -- "${tmp_root}/forget_args"
TEST_SCENARIO="dirs_line_no_changed"
run_prune_identical_snapshots "prod" yes

forget_args="$(<"${tmp_root}/forget_args")"
assert_eq 1 "$(count_matches 'old1' "${forget_args}")" "dirs line without changed count should still be parsed as identical"
assert_eq 0 "$(count_matches 'new3' "${forget_args}")" "dirs line without changed count should keep latest snapshot"

printf 'TEST PASS: prune groups staged-path duplicates\n'