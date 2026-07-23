#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

# Print configured servers with host and policy metadata.
run_servers() {
  install_error_trap
  install_signal_traps

  print_header "restic-cli servers"
  load_global_config

  local -a servers=()
  local server
  while IFS= read -r server; do
    [[ -n "${server}" ]] && servers+=("${server}")
  done < <(list_server_names)

  ((${#servers[@]} > 0)) || die "No server configs found in ${SERVER_CONFIG_DIR}."

  printf '%-18s %-20s %-8s %-14s %-8s %-6s %-10s\n' "SERVER" "HOST" "PORT" "FREQUENCY" "TIME" "DAY" "RETENTION"
  printf '%-18s %-20s %-8s %-14s %-8s %-6s %-10s\n' "------" "----" "----" "---------" "----" "---" "---------"

  for server in "${servers[@]}"; do
    load_server_config "${server}"
    printf '%-18s %-20s %-8s %-14s %-8s %-6s %-10s\n' "${NAME}" "${HOST}" "${SSH_PORT}" "${BACKUP_FREQUENCY}" "${BACKUP_TIME}" "${BACKUP_DAY:--}" "${RETENTION_POLICY}"
  done
}

# Remove a server from backup target list by deleting its config only.
run_remove_server() {
  install_error_trap
  install_signal_traps

  print_header "restic-cli remove"
  load_global_config

  local server_name="$1"
  validate_server_name "${server_name}" || die "Invalid server name: ${server_name}"

  local config_path
  config_path="$(server_config_path "${server_name}")"
  [[ -f "${config_path}" ]] || die "Server config not found: ${config_path}"

  local confirm=""
  prompt_yes_no "Remove ${server_name} from backup list (repository data will be kept)" confirm no
  [[ "${confirm}" == "yes" ]] || die "Remove cancelled by user."

  rm -f -- "${config_path}" || die "Failed to remove server config: ${config_path}"
  write_operation_log "${server_name}" "remove" "success" "0" "Removed from backup list; repository kept"

  msg_success "Removed ${server_name} from backup list."
  msg_info "Repository data was kept in ${BACKUP_STORAGE}/${server_name}"
}

# Show snapshots for one server or all configured servers.
run_snapshots() {
  install_error_trap
  install_signal_traps

  print_header "restic-cli snapshots"
  load_global_config
  ensure_local_restic

  local requested_server="${1:-}"
  local -a targets=()

  if [[ -n "${requested_server}" ]]; then
    targets=("${requested_server}")
  else
    local server
    while IFS= read -r server; do
      [[ -n "${server}" ]] && targets+=("${server}")
    done < <(list_server_names)
  fi

  ((${#targets[@]} > 0)) || die "No server configs found in ${SERVER_CONFIG_DIR}."

  local target
  for target in "${targets[@]}"; do
    load_server_config "${target}"

    local pass_file repo_path
    pass_file="$(password_file_path "${NAME}")"
    repo_path="$(repository_path "${REPOSITORY}")"

    [[ -f "${pass_file}" ]] || die "Password file missing for ${NAME}: ${pass_file}"
    validate_repository "${repo_path}" "${pass_file}"

    msg_info "Snapshots for ${NAME}"
    restic -r "${repo_path}" --password-file "${pass_file}" snapshots --host "${NAME}" || die "Failed to list snapshots for ${NAME}"
    printf '\n'
  done
}

# Compare two snapshots for one configured server.
run_snapshot_diff() {
  install_error_trap
  install_signal_traps

  print_header "restic-cli diff"
  load_global_config
  ensure_local_restic

  local server_name="$1"
  local snapshot_a="$2"
  local snapshot_b="$3"

  load_server_config "${server_name}"

  local pass_file repo_path
  pass_file="$(password_file_path "${NAME}")"
  repo_path="$(repository_path "${REPOSITORY}")"

  [[ -f "${pass_file}" ]] || die "Password file missing for ${NAME}: ${pass_file}"
  validate_repository "${repo_path}" "${pass_file}"

  restic -r "${repo_path}" --password-file "${pass_file}" snapshots "${snapshot_a}" --host "${NAME}" >/dev/null 2>&1 || \
    die "Snapshot ${snapshot_a} not found for ${NAME}."
  restic -r "${repo_path}" --password-file "${pass_file}" snapshots "${snapshot_b}" --host "${NAME}" >/dev/null 2>&1 || \
    die "Snapshot ${snapshot_b} not found for ${NAME}."

  msg_info "Diff for ${NAME}: ${snapshot_a} -> ${snapshot_b}"
  restic -r "${repo_path}" --password-file "${pass_file}" diff "${snapshot_a}" "${snapshot_b}" || \
    die "Failed to diff snapshots for ${NAME}."
}
