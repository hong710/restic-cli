#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "${ROOT_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT_DIR}/lib/restore.sh"

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

tmp_root="$(mktemp -d)"
trap 'rm -rf -- "${tmp_root}"' EXIT

RESTORE_STORAGE="${tmp_root}/restore"
mkdir -p -- "${RESTORE_STORAGE}"

preview_target="$(resolve_restore_preview_target "prod")"
assert_eq "${RESTORE_STORAGE}/prod-local" "${preview_target}" "no-push target should use -local suffix"

load_global_config() { return 0; }
ensure_local_restic() { return 0; }
ensure_local_rsync() { return 0; }
run_cleanup() { return 0; }
msg_progress() { return 0; }
msg_success() { return 0; }
msg_info() { return 0; }

restore_one_server_safe() {
  printf '%s\n' "$1" > "${tmp_root}/server"
  printf '%s\n' "$2" > "${tmp_root}/dry_run_first"
  printf '%s\n' "$3" > "${tmp_root}/snapshot"
  printf '%s\n' "$4" > "${tmp_root}/mode"
  return 0
}

run_restore "prod" "9e6af64e"

assert_eq "prod" "$(<"${tmp_root}/server")" "restore should target the requested server"
assert_eq "yes" "$(<"${tmp_root}/dry_run_first")" "restore should keep dry-run preview flag enabled"
assert_eq "9e6af64e" "$(<"${tmp_root}/snapshot")" "restore should pass the requested snapshot"
assert_eq "dry-run" "$(<"${tmp_root}/mode")" "restore should default to no-push mode"

printf 'TEST PASS: restore defaults to no-push and uses -local target naming\n'