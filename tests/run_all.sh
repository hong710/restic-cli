#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

tests=(
  "${SCRIPT_DIR}/test_backup_flow.sh"
  "${SCRIPT_DIR}/test_logs_command.sh"
  "${SCRIPT_DIR}/test_prune_identical_snapshots.sh"
  "${SCRIPT_DIR}/test_restore_defaults.sh"
)

printf 'Running %d test(s)\n' "${#tests[@]}"

for test_script in "${tests[@]}"; do
  printf '\n==> %s\n' "$(basename -- "${test_script}")"
  bash "${test_script}"
done

printf '\nAll tests passed.\n'