#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

# Escape a value for safe insertion into a shell assignment.
escape_shell_value() {
  local value="$1"
  printf '%q' "${value}"
}

# Upsert a key=value assignment in config.conf.
set_global_config_key() {
  local key="$1"
  local value="$2"
  local escaped

  escaped="$(escape_shell_value "${value}")"

  if [[ ! -f "${GLOBAL_CONFIG_FILE}" ]]; then
    cat > "${GLOBAL_CONFIG_FILE}" <<'EOF'
BACKUP_STORAGE=
RESTORE_STORAGE=
LOG_DIRECTORY=
PASSWORD_DIRECTORY=
SHARED_PASSWORD_FILE=shared.pass
EOF
  fi

  if grep -qE "^${key}=" "${GLOBAL_CONFIG_FILE}"; then
    sed -i -E "s|^${key}=.*$|${key}=${escaped}|" "${GLOBAL_CONFIG_FILE}"
  else
    printf '%s=%s\n' "${key}" "${escaped}" >> "${GLOBAL_CONFIG_FILE}"
  fi
}

# Ask for backup paths until the user enters an empty line.
collect_backup_paths() {
  local -n _out_ref="$1"
  local input

  _out_ref=()
  msg_info "Enter directories/files to back up, one per line. Press Enter on empty line to finish."

  while true; do
    read -r -p "Path: " input
    [[ -z "${input}" ]] && break

    if [[ "${input}" != /* ]]; then
      msg_warn "Path must be absolute (start with /): ${input}"
      continue
    fi

    _out_ref+=("${input}")
  done

  ((${#_out_ref[@]} > 0)) || die "At least one backup path is required."
}

# Ask for retention policy from fixed choices.
prompt_retention_policy() {
  local result_var="$1"
  local default_value="${2:-30days}"
  local choice
  local selected

  while true; do
    printf 'Retention policy options:\n'
    printf '  1) 7days\n'
    printf '  2) 14days\n'
    printf '  3) 30days\n'
    read -r -p "Select retention policy [default: ${default_value}]: " choice

    case "${choice}" in
      "" )
        selected="${default_value}"
        ;;
      1)
        selected="7days"
        ;;
      2)
        selected="14days"
        ;;
      3)
        selected="30days"
        ;;
      *)
        msg_warn "Invalid selection. Choose 1, 2, or 3."
        continue
        ;;
    esac

    if validate_retention_policy "${selected}"; then
      printf -v "${result_var}" '%s' "${selected}"
      return 0
    fi
  done
}

# Ask for backup frequency from fixed choices.
prompt_backup_frequency() {
  local result_var="$1"
  local default_value="${2:-once a day}"
  local choice
  local selected

  while true; do
    printf 'Backup frequency options:\n'
    printf '  1) once a day\n'
    printf '  2) once a week\n'
    printf '  3) every 2wk\n'
    read -r -p "Select backup frequency [default: ${default_value}]: " choice

    case "${choice}" in
      "" )
        selected="${default_value}"
        ;;
      1)
        selected="once a day"
        ;;
      2)
        selected="once a week"
        ;;
      3)
        selected="every 2wk"
        ;;
      *)
        msg_warn "Invalid selection. Choose 1, 2, or 3."
        continue
        ;;
    esac

    if validate_backup_frequency "${selected}"; then
      printf -v "${result_var}" '%s' "${selected}"
      return 0
    fi
  done
}

# Ask until a valid HH:MM backup time is entered.
prompt_backup_time() {
  local result_var="$1"
  local default_value="${2:-02:00}"
  local value

  while true; do
    prompt_with_default "Backup time (HH:MM)" "${default_value}" value
    if validate_backup_time "${value}"; then
      printf -v "${result_var}" '%s' "${value}"
      return 0
    fi
    msg_warn "Invalid backup time. Use 24-hour HH:MM format, for example 02:00."
  done
}

# Ask for backup day from fixed weekday choices.
prompt_backup_day() {
  local result_var="$1"
  local default_value="${2:-Sun}"
  local choice
  local selected

  while true; do
    printf 'Backup day options:\n'
    printf '  1) Mon\n'
    printf '  2) Tue\n'
    printf '  3) Wed\n'
    printf '  4) Thu\n'
    printf '  5) Fri\n'
    printf '  6) Sat\n'
    printf '  7) Sun\n'
    read -r -p "Select backup day [default: ${default_value}]: " choice

    case "${choice}" in
      "" ) selected="${default_value}" ;;
      1) selected="Mon" ;;
      2) selected="Tue" ;;
      3) selected="Wed" ;;
      4) selected="Thu" ;;
      5) selected="Fri" ;;
      6) selected="Sat" ;;
      7) selected="Sun" ;;
      *)
        msg_warn "Invalid selection. Choose 1 to 7."
        continue
        ;;
    esac

    if validate_backup_day "${selected}"; then
      printf -v "${result_var}" '%s' "${selected}"
      return 0
    fi
  done
}

# Validate backup paths exist on the remote host.
validate_remote_paths_exist() {
  local host="$1"
  local user="$2"
  local port="$3"
  shift 3

  local path
  for path in "$@"; do
    msg_progress "Validating remote path: ${path}"
    if ! ssh_exec "${host}" "${user}" "${port}" "test -e '${path//\'/\'\\\'\'}'"; then
      die "Remote path does not exist on ${host}: ${path}"
    fi
  done
}

# Install Restic on the remote host when missing.
ensure_remote_restic() {
  local host="$1"
  local user="$2"
  local port="$3"

  if ssh_exec "${host}" "${user}" "${port}" "command -v restic >/dev/null 2>&1"; then
    msg_success "Remote Restic is already installed on ${host}."
    return 0
  fi

  msg_warn "Restic not found on ${host}. Attempting installation via apt-get."

  local remote_install_cmd
  remote_install_cmd=$(
    cat <<'EOF'
set -Eeuo pipefail
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y restic
else
  echo "apt-get not available" >&2
  exit 1
fi
EOF
  )

  if ! ssh_exec "${host}" "${user}" "${port}" "bash -s" <<< "${remote_install_cmd}"; then
    die "Failed to install Restic on remote host ${host}. Install it manually and rerun setup."
  fi

  if ! ssh_exec "${host}" "${user}" "${port}" "command -v restic >/dev/null 2>&1"; then
    die "Remote Restic still missing after installation attempt on ${host}."
  fi

  msg_success "Remote Restic installed on ${host}."
}

# Generate and store a shared password file with strict permissions.
create_password_file() {
  local server_name="${1:-}"
  [[ -n "${server_name}" ]] || true
  local pass_file

  pass_file="$(password_file_path "${server_name}")"
  if [[ -f "${pass_file}" ]]; then
    msg_warn "Shared password file already exists and will be reused: ${pass_file}" >&2
    printf '%s\n' "${pass_file}"
    return 0
  fi

  umask 077
  openssl rand -base64 48 > "${pass_file}"
  chmod 600 "${pass_file}"
  msg_success "Shared password generated: ${pass_file}" >&2
  printf '%s\n' "${pass_file}"
}

# Copy password to remote host for optional local restore operations.
copy_password_to_remote() {
  local host="$1"
  local user="$2"
  local port="$3"
  local pass_file="$4"
  local server_name="$5"

  local copy_decision=""
  prompt_yes_no "Copy password to remote host for emergency restore use" copy_decision no

  if [[ "${copy_decision}" != "yes" ]]; then
    msg_info "Skipping remote password copy."
    return 0
  fi

  local remote_path="/etc/restic/${server_name}.pass"
  local temp_remote="/tmp/${server_name}.pass.$$"

  msg_progress "Copying password to remote host ${host}:${remote_path}"
  cat "${pass_file}" | ssh "${SSH_OPTS_COMMON[@]}" -p "${port}" "${user}@${host}" \
    "set -Eeuo pipefail; umask 077; mkdir -p /etc/restic; cat > '${temp_remote}'; mv '${temp_remote}' '${remote_path}'; chmod 600 '${remote_path}'"

  msg_success "Password copied to remote host: ${remote_path}"
}

# Create and initialize repository for the given server.
create_and_init_repository() {
  local server_name="$1"
  local repository_name="$2"
  local pass_file="$3"
  local repo_path

  repo_path="$(repository_path "${repository_name}")"
  mkdir -p -- "${repo_path}"

  if [[ -n "$(ls -A -- "${repo_path}" 2>/dev/null)" ]]; then
    msg_warn "Repository path is not empty, reusing existing repository: ${repo_path}"
  fi

  if ! restic -r "${repo_path}" --password-file "${pass_file}" snapshots --no-lock >/dev/null 2>&1; then
    msg_progress "Initializing Restic repository: ${repo_path}"
    restic -r "${repo_path}" --password-file "${pass_file}" init >/dev/null
  else
    msg_info "Repository already initialized: ${repo_path}"
  fi

  validate_repository "${repo_path}" "${pass_file}"
  msg_success "Repository is ready: ${repo_path}"
}

# Persist server-specific configuration to servers/<name>.conf.
write_server_config() {
  local server_name="$1"
  local host="$2"
  local user="$3"
  local port="$4"
  local repository_name="$5"
  local backup_frequency="$6"
  local backup_time="$7"
  local backup_day="$8"
  local backup_anchor_date="$9"
  local retention_policy="${10}"
  shift 10
  local paths=("$@")

  local config_path
  config_path="$(server_config_path "${server_name}")"

  {
    printf 'NAME="%s"\n' "${server_name}"
    printf 'HOST="%s"\n' "${host}"
    printf 'USER="%s"\n' "${user}"
    printf 'SSH_PORT="%s"\n' "${port}"
    printf 'REPOSITORY="%s"\n' "${repository_name}"
    printf 'BACKUP_FREQUENCY="%s"\n' "${backup_frequency}"
    printf 'BACKUP_TIME="%s"\n' "${backup_time}"
    printf 'BACKUP_DAY="%s"\n' "${backup_day}"
    printf 'BACKUP_ANCHOR_DATE="%s"\n' "${backup_anchor_date}"
    printf 'RETENTION_POLICY="%s"\n' "${retention_policy}"
    printf 'BACKUP_PATHS="\n'

    local p
    for p in "${paths[@]}"; do
      printf '%s\n' "${p}"
    done

    printf '"\n'
  } > "${config_path}"

  chmod 600 "${config_path}"
  msg_success "Server config written: ${config_path}"
}

# Validate final setup state for server and global paths.
final_validation() {
  local server_name="$1"

  load_global_config
  load_server_config "${server_name}"

  local pass_file repo_path
  pass_file="$(password_file_path "${server_name}")"
  repo_path="$(repository_path "${REPOSITORY}")"

  [[ -f "${pass_file}" ]] || die "Password file missing after setup: ${pass_file}"
  validate_repository "${repo_path}" "${pass_file}"
  validate_ssh_connection "${HOST}" "${USER}" "${SSH_PORT}" || die "SSH validation failed after setup."
}

# Run the interactive setup workflow.
run_setup_wizard() {
  install_error_trap
  install_signal_traps

  print_header "backupctl setup"
  msg_info "Interactive setup started."

  ensure_project_directories
  ensure_local_restic
  ensure_local_openssl

  local server_name host user port backup_storage restore_storage
  local backup_frequency backup_time backup_day backup_anchor_date retention_policy
  local -a paths

  prompt_non_empty "Server name" server_name
  validate_server_name "${server_name}" || die "Invalid server name. Use only letters, numbers, dot, underscore, dash."

  prompt_non_empty "Server IP or hostname" host
  prompt_with_default "SSH user" "root" user
  prompt_with_default "SSH port" "22" port

  [[ "${port}" =~ ^[0-9]{1,5}$ ]] || die "Invalid SSH port: ${port}"

  if [[ -f "${GLOBAL_CONFIG_FILE}" ]]; then
    # Load existing defaults for smoother setup.
    # shellcheck disable=SC1090
    source "${GLOBAL_CONFIG_FILE}"
  fi

  prompt_with_default "Backup storage location" "${BACKUP_STORAGE:-/home/data/backups}" backup_storage
  prompt_with_default "Restore location" "${RESTORE_STORAGE:-/home/data/restore}" restore_storage

  mkdir -p -- "${backup_storage}" "${restore_storage}"
  [[ -w "${backup_storage}" ]] || die "Backup storage is not writable: ${backup_storage}"
  [[ -w "${restore_storage}" ]] || die "Restore storage is not writable: ${restore_storage}"

  collect_backup_paths paths
  prompt_backup_frequency backup_frequency "${BACKUP_FREQUENCY:-once a day}"
  prompt_backup_time backup_time "${BACKUP_TIME:-02:00}"
  backup_day=""
  backup_anchor_date=""
  if [[ "${backup_frequency}" == "once a week" || "${backup_frequency}" == "every 2wk" ]]; then
    prompt_backup_day backup_day "${BACKUP_DAY:-$(current_weekday_name)}"
  fi
  if [[ "${backup_frequency}" == "every 2wk" ]]; then
    backup_anchor_date="$(date +%F)"
  fi
  prompt_retention_policy retention_policy "${RETENTION_POLICY:-30days}"

  msg_progress "Testing SSH connectivity to ${user}@${host}:${port}"
  validate_ssh_connection "${host}" "${user}" "${port}" || die "SSH test failed. Check connectivity, keys, and credentials."
  msg_success "SSH test passed."

  validate_remote_paths_exist "${host}" "${user}" "${port}" "${paths[@]}"
  ensure_remote_restic "${host}" "${user}" "${port}"

  set_global_config_key "BACKUP_STORAGE" "${backup_storage}"
  set_global_config_key "RESTORE_STORAGE" "${restore_storage}"
  set_global_config_key "LOG_DIRECTORY" "${LOG_DIR_DEFAULT}"
  set_global_config_key "PASSWORD_DIRECTORY" "${PASSWORD_DIR_DEFAULT}"
  set_global_config_key "SHARED_PASSWORD_FILE" "shared.pass"

  load_global_config

  local pass_file
  pass_file="$(create_password_file "${server_name}")"

  create_and_init_repository "${server_name}" "${server_name}" "${pass_file}"
  copy_password_to_remote "${host}" "${user}" "${port}" "${pass_file}" "${server_name}"

  write_server_config "${server_name}" "${host}" "${user}" "${port}" "${server_name}" "${backup_frequency}" "${backup_time}" "${backup_day}" "${backup_anchor_date}" "${retention_policy}" "${paths[@]}"
  final_validation "${server_name}"

  write_operation_log "${server_name}" "setup" "success" "0" "Setup completed successfully"

  msg_success "Setup completed for server: ${server_name}"
  msg_info "You can now run: ./backupctl backup"
}
