#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/backup.sh"

# Print whether a configured server is due and return 0 when due.
scheduler_server_due() {
  local server_name="$1"
  local now_epoch="$2"

  load_server_config "${server_name}"

  local last_epoch
  last_epoch="$(read_last_backup_epoch "${NAME}")"

  if is_backup_due "${BACKUP_FREQUENCY}" "${BACKUP_TIME}" "${BACKUP_DAY}" "${BACKUP_ANCHOR_DATE}" "${last_epoch}" "${now_epoch}"; then
    msg_info "${NAME} is due (${BACKUP_FREQUENCY} ${BACKUP_DAY:+${BACKUP_DAY} }${BACKUP_TIME}, last_success=${last_epoch})"
    return 0
  fi

  msg_info "${NAME} is not due yet (${BACKUP_FREQUENCY} ${BACKUP_DAY:+${BACKUP_DAY} }${BACKUP_TIME}, last_success=${last_epoch})"
  return 1
}

# Run scheduled backups for any server whose configured frequency is due.
run_due_backups() {
  install_error_trap
  install_signal_traps

  print_header "backupctl run-due"

  load_global_config
  ensure_local_restic
  ensure_local_rsync

  local -a servers=()
  local server
  while IFS= read -r server; do
    [[ -n "${server}" ]] && servers+=("${server}")
  done < <(list_server_names)

  ((${#servers[@]} > 0)) || die "No server configs found in ${SERVER_CONFIG_DIR}."

  local now_epoch
  now_epoch="$(date +%s)"

  local due_count=0
  local failed_count=0

  for server in "${servers[@]}"; do
    if scheduler_server_due "${server}" "${now_epoch}"; then
      ((due_count+=1))
      if ! backup_one_server_safe "${server}"; then
        ((failed_count+=1))
        msg_error "Scheduled backup failed for ${server}"
      fi
      run_cleanup
    fi
  done

  if (( due_count == 0 )); then
    msg_info "No servers are due for backup."
    return 0
  fi

  if (( failed_count > 0 )); then
    die "Scheduled backups completed with ${failed_count} failed server(s)."
  fi

  msg_success "Scheduled backups completed for ${due_count} due server(s)."
}
