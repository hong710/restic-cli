#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

# Emit timestamp for per-run log filenames.
run_stamp() {
  date +"%Y%m%d-%H%M%S"
}

# Convert a raw backup path to a relative entry for restic backup.
path_to_relative_entry() {
  local abs_path="$1"
  local normalized="${abs_path#/}"
  printf './%s\n' "${normalized}"
}

# Build the ssh command argument used by rsync.
build_rsync_ssh_command() {
  local port="$1"
  printf 'ssh -p %s -o BatchMode=yes -o ConnectTimeout=%s -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ServerAliveCountMax=3' \
    "${port}" "${SSH_CONNECT_TIMEOUT}"
}

# Copy configured remote paths from server into a local staging tree.
stage_remote_data() {
  local staging_dir="$1"
  local host="$2"
  local user="$3"
  local port="$4"
  shift 4
  local paths=("$@")

  local ssh_cmd
  ssh_cmd="$(build_rsync_ssh_command "${port}")"

  local remote_path
  for remote_path in "${paths[@]}"; do
    msg_progress "Staging ${remote_path} from ${user}@${host}"

    if ! rsync -aR --numeric-ids --delete \
      -e "${ssh_cmd}" \
      "${user}@${host}:${remote_path}" \
      "${staging_dir}/"; then
      die "Failed to stage remote path from ${host}: ${remote_path}"
    fi
  done
}

# Run restic backup using staged paths as relative inputs.
run_restic_backup() {
  local server_name="$1"
  local repo_path="$2"
  local pass_file="$3"
  local staging_dir="$4"
  shift 4
  local paths=("$@")

  local -a rel_paths
  local -a restic_args
  local p
  for p in "${paths[@]}"; do
    rel_paths+=("$(path_to_relative_entry "${p}")")
  done

  ((${#rel_paths[@]} > 0)) || die "No paths available to back up for ${server_name}"

  restic_args=(
    -r "${repo_path}"
    --password-file "${pass_file}"
    --retry-lock "${RESTIC_RETRY_LOCK_DEFAULT}"
    backup
    "${rel_paths[@]}"
    --host "${server_name}"
    --tag "server:${server_name}"
    --verbose
  )

  msg_progress "Creating Restic snapshot for ${server_name}"
  (
    cd -- "${staging_dir}"
    restic "${restic_args[@]}"
  )
}

# Apply repository retention policy for a server after backup.
apply_retention_policy() {
  local server_name="$1"
  local repo_path="$2"
  local pass_file="$3"
  local retention_policy="$4"
  local keep_last

  validate_retention_policy "${retention_policy}" || die "Invalid retention policy for ${server_name}: ${retention_policy}"
  keep_last="$(retention_policy_to_keep_last "${retention_policy}")" || die "Cannot map retention policy for ${server_name}: ${retention_policy}"

  msg_progress "Applying retention policy ${retention_policy} for ${server_name}"
  restic -r "${repo_path}" --password-file "${pass_file}" --retry-lock "${RESTIC_RETRY_LOCK_DEFAULT}" \
    forget --host "${server_name}" --keep-last "${keep_last}" --prune --verbose
}

# Run backup for a single configured server.
backup_one_server() {
  local server_name="$1"

  local start end elapsed status detail
  start="$(date +%s)"
  status="success"
  detail="Snapshot completed"

  load_server_config "${server_name}"

  local -a paths
  parse_backup_paths "${BACKUP_PATHS}" paths || die "No backup paths configured for ${server_name}"

  local pass_file repo_path staging_dir
  pass_file="$(password_file_path "${NAME}")"
  repo_path="$(repository_path "${REPOSITORY}")"

  [[ -f "${pass_file}" ]] || die "Password file missing for ${NAME}: ${pass_file}"

  if ! validate_ssh_connection "${HOST}" "${USER}" "${SSH_PORT}"; then
    die "SSH validation failed for ${NAME} (${USER}@${HOST}:${SSH_PORT})"
  fi

  validate_repository "${repo_path}" "${pass_file}"

  staging_dir="$(create_temp_workspace "stage-${NAME}")"

  local server_log="${LOG_DIRECTORY}/backup-${NAME}-$(run_stamp).log"
  msg_info "Server backup log: ${server_log}"

  {
    msg_info "Backup started for ${NAME}"
    msg_info "Repository: ${repo_path}"
    msg_info "Staging directory: ${staging_dir}"

    stage_remote_data "${staging_dir}" "${HOST}" "${USER}" "${SSH_PORT}" "${paths[@]}"
    run_restic_backup "${NAME}" "${repo_path}" "${pass_file}" "${staging_dir}" "${paths[@]}"
    apply_retention_policy "${NAME}" "${repo_path}" "${pass_file}" "${RETENTION_POLICY}"
    record_last_backup_epoch "${NAME}"

    msg_success "Backup completed for ${NAME}"
  } 2>&1 | tee -a "${server_log}"

  end="$(date +%s)"
  elapsed="$((end - start))"
  write_operation_log "${NAME}" "backup" "${status}" "${elapsed}" "${detail}"
}

# Run backup workflow for one server and capture failures as logs.
backup_one_server_safe() {
  local server_name="$1"

  local start end elapsed
  start="$(date +%s)"

  if backup_one_server "${server_name}"; then
    return 0
  fi

  end="$(date +%s)"
  elapsed="$((end - start))"
  write_operation_log "${server_name}" "backup" "failed" "${elapsed}" "Backup failed"
  return 1
}

# Resolve which server(s) to back up.
resolve_backup_targets() {
  local requested_server="${1:-}"
  local -n _target_ref="$2"

  _target_ref=()

  if [[ -n "${requested_server}" ]]; then
    _target_ref+=("${requested_server}")
    return 0
  fi

  local server
  while IFS= read -r server; do
    [[ -n "${server}" ]] && _target_ref+=("${server}")
  done < <(list_server_names)

  ((${#_target_ref[@]} > 0)) || die "No server configs found in ${SERVER_CONFIG_DIR}. Run restic-cli setup first."
}

# Execute backup workflow for all resolved servers.
run_backup() {
  install_error_trap
  install_signal_traps

  print_header "restic-cli backup"

  load_global_config
  ensure_local_restic
  ensure_local_rsync

  local requested_server="${1:-}"
  local -a targets
  resolve_backup_targets "${requested_server}" targets

  msg_info "Backup targets: ${targets[*]}"

  local failed_count=0
  local target

  for target in "${targets[@]}"; do
    msg_progress "Starting backup for ${target}"

    if ! backup_one_server_safe "${target}"; then
      ((failed_count+=1))
      msg_error "Backup failed for ${target}"
    fi

    run_cleanup
  done

  if ((failed_count > 0)); then
    die "Backup completed with ${failed_count} failed server(s). Check logs in ${LOG_DIRECTORY}."
  fi

  msg_success "Backup completed for all targets."
}
