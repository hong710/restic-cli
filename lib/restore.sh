#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

# Build the ssh command argument used by rsync restore push.
build_restore_ssh_command() {
  local port="$1"
  printf 'ssh -p %s -o BatchMode=yes -o ConnectTimeout=%s -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ServerAliveCountMax=3' \
    "${port}" "${SSH_CONNECT_TIMEOUT}"
}

# Return timestamp used for restore directory suffixes.
restore_stamp() {
  date +"%Y%m%d-%H%M%S"
}

# Pick a restore directory that never overwrites prior restores.
resolve_restore_target() {
  local server_name="$1"
  local base_target="${RESTORE_STORAGE}/${server_name}"

  if [[ ! -e "${base_target}" ]]; then
    printf '%s\n' "${base_target}"
    return 0
  fi

  printf '%s-%s\n' "${base_target}" "$(restore_stamp)"
}

# Pick a dry-run restore preview directory under RESTORE_STORAGE.
resolve_restore_preview_target() {
  local server_name="$1"
  local base_target="${RESTORE_STORAGE}/${server_name}-dry-run"

  if [[ ! -e "${base_target}" ]]; then
    printf '%s\n' "${base_target}"
    return 0
  fi

  printf '%s-%s\n' "${base_target}" "$(restore_stamp)"
}

# Ensure there is at least one snapshot available for restore.
ensure_snapshot_exists() {
  local repo_path="$1"
  local pass_file="$2"
  local host_name="$3"
  local snapshot_id="${4:-latest}"

  if [[ "${snapshot_id}" == "latest" ]]; then
    if ! restic -r "${repo_path}" --password-file "${pass_file}" --retry-lock "${RESTIC_RETRY_LOCK_DEFAULT}" snapshots --host "${host_name}" --latest 1 >/dev/null 2>&1; then
      die "No snapshots found in repository ${repo_path} for host ${host_name}."
    fi
    return 0
  fi

  if ! restic -r "${repo_path}" --password-file "${pass_file}" --retry-lock "${RESTIC_RETRY_LOCK_DEFAULT}" snapshots "${snapshot_id}" --host "${host_name}" >/dev/null 2>&1; then
    die "Snapshot ${snapshot_id} not found for host ${host_name} in ${repo_path}."
  fi
}

# Resolve the local restored path for an original configured path.
# Supports both direct layout (${target_dir}${original_path}) and staged snapshot layouts.
resolve_restored_local_path() {
  local target_dir="$1"
  local original_path="$2"

  local direct_path="${target_dir}${original_path}"
  if [[ -e "${direct_path}" ]]; then
    printf '%s\n' "${direct_path}"
    return 0
  fi

  local suffix="${original_path#/}"
  local -a matches=()
  local candidate

  while IFS= read -r candidate; do
    [[ -n "${candidate}" ]] && matches+=("${candidate}")
  done < <(find "${target_dir}" -mindepth 1 -path "*/${suffix}" -print 2>/dev/null)

  if ((${#matches[@]} == 1)); then
    printf '%s\n' "${matches[0]}"
    return 0
  fi

  if ((${#matches[@]} > 1)); then
    for candidate in "${matches[@]}"; do
      if [[ "${candidate}" == *"/tmp/stage-"*"/${suffix}" ]]; then
        printf '%s\n' "${candidate}"
        return 0
      fi
    done
    printf '%s\n' "${matches[0]}"
    return 0
  fi

  return 1
}

# Copy restored paths from local restore target back to the remote server.
push_restored_paths_to_remote() {
  local target_dir="$1"
  local host="$2"
  local user="$3"
  local port="$4"
  local dry_run_mode="$5"
  shift 5
  local paths=("$@")

  local ssh_cmd
  ssh_cmd="$(build_restore_ssh_command "${port}")"

  local -a rsync_opts
  rsync_opts=( -aHAX --numeric-ids )
  if [[ "${dry_run_mode}" == "yes" ]]; then
    rsync_opts+=( --dry-run )
  fi

  local original_path local_path
  for original_path in "${paths[@]}"; do
    local_path="$(resolve_restored_local_path "${target_dir}" "${original_path}")" || die "Restored path missing locally for ${original_path} under ${target_dir}"

    if [[ "${dry_run_mode}" == "yes" ]]; then
      msg_progress "DRY-RUN push preview to ${user}@${host}:${original_path}"
    else
      msg_progress "Pushing restored path back to ${user}@${host}:${original_path}"
    fi

    if [[ -d "${local_path}" ]]; then
      if ! rsync "${rsync_opts[@]}" --delete \
        -e "${ssh_cmd}" \
        "${local_path}/" \
        "${user}@${host}:${original_path}/"; then
        die "Failed to push directory restore to remote host: ${original_path}"
      fi
    else
      if ! rsync "${rsync_opts[@]}" \
        -e "${ssh_cmd}" \
        "${local_path}" \
        "${user}@${host}:${original_path}"; then
        die "Failed to push file restore to remote host: ${original_path}"
      fi
    fi
  done
}

# Restore the latest snapshot for one server into an isolated folder.
restore_one_server() {
  local server_name="$1"
  local dry_run_first="${2:-yes}"
  local snapshot_id="${3:-latest}"
  local restore_mode="${4:-apply}"

  local start end elapsed status detail
  start="$(date +%s)"
  status="success"
  detail="Restore completed"

  load_server_config "${server_name}"

  local -a paths
  parse_backup_paths "${BACKUP_PATHS}" paths || die "No backup paths configured for ${server_name}"

  local pass_file repo_path target_dir
  pass_file="$(password_file_path "${NAME}")"
  repo_path="$(repository_path "${REPOSITORY}")"

  [[ -f "${pass_file}" ]] || die "Password file missing for ${NAME}: ${pass_file}"
  validate_ssh_connection "${HOST}" "${USER}" "${SSH_PORT}" || die "SSH validation failed for restore push to ${HOST}."
  validate_repository "${repo_path}" "${pass_file}"
  ensure_snapshot_exists "${repo_path}" "${pass_file}" "${NAME}" "${snapshot_id}"

  if [[ "${restore_mode}" == "dry-run" ]]; then
    target_dir="$(resolve_restore_preview_target "${NAME}")"
    mkdir -p -- "${target_dir}"
    msg_info "No-push mode: using local preview target ${target_dir} under RESTORE_STORAGE"
  else
    target_dir="$(resolve_restore_target "${NAME}")"
    mkdir -p -- "${target_dir}"
  fi

  local restore_log="${LOG_DIRECTORY}/restore-${NAME}-$(restore_stamp).log"
  msg_info "Server restore log: ${restore_log}"

  {
    msg_info "Restore started for ${NAME}"
    msg_info "Repository: ${repo_path}"
    msg_info "Restore target: ${target_dir}"

    restic -r "${repo_path}" --password-file "${pass_file}" --retry-lock "${RESTIC_RETRY_LOCK_DEFAULT}" \
      restore "${snapshot_id}" \
      --host "${NAME}" \
      --target "${target_dir}" \
      --verbose

    msg_info "Restore completed locally."
    msg_info "Preparing push of restored data to ${USER}@${HOST}"

    if [[ "${restore_mode}" == "dry-run" ]]; then
      msg_info "No-push mode: previewing remote changes only. No remote writes will be made."
      push_restored_paths_to_remote "${target_dir}" "${HOST}" "${USER}" "${SSH_PORT}" "yes" "${paths[@]}"
    else
      if [[ "${dry_run_first}" == "yes" ]]; then
        msg_info "Running rsync dry-run preview before remote write."
        push_restored_paths_to_remote "${target_dir}" "${HOST}" "${USER}" "${SSH_PORT}" "yes" "${paths[@]}"

        local apply_after_preview=""
        prompt_yes_no "Apply remote restore changes now (run rsync without --dry-run)" apply_after_preview no
        [[ "${apply_after_preview}" == "yes" ]] || die "Remote restore push cancelled after dry-run preview."
      fi

      push_restored_paths_to_remote "${target_dir}" "${HOST}" "${USER}" "${SSH_PORT}" "no" "${paths[@]}"
    fi

    msg_success "Restore completed for ${NAME}"
  } 2>&1 | tee -a "${restore_log}"

  end="$(date +%s)"
  elapsed="$((end - start))"
  write_operation_log "${NAME}" "restore" "${status}" "${elapsed}" "${detail}; mode=${restore_mode}; snapshot=${snapshot_id}; target=${target_dir}; pushed_to=${USER}@${HOST}"

  if [[ "${restore_mode}" == "dry-run" ]]; then
    msg_success "No-push restore preview completed for ${NAME}. No remote changes were applied."
  else
    msg_success "Restored ${NAME} into ${target_dir} and pushed back to ${USER}@${HOST}"
  fi
}

# Wrapper that logs restore failure and exits non-zero.
restore_one_server_safe() {
  local server_name="$1"
  local dry_run_first="${2:-yes}"
  local snapshot_id="${3:-latest}"
  local restore_mode="${4:-apply}"

  local start end elapsed
  start="$(date +%s)"

  if restore_one_server "${server_name}" "${dry_run_first}" "${snapshot_id}" "${restore_mode}"; then
    return 0
  fi

  end="$(date +%s)"
  elapsed="$((end - start))"
  write_operation_log "${server_name}" "restore" "failed" "${elapsed}" "Restore failed"
  return 1
}

# Prompt user to choose a server when none was provided.
choose_server_interactive() {
  local -a servers=()
  local server

  while IFS= read -r server; do
    [[ -n "${server}" ]] && servers+=("${server}")
  done < <(list_server_names)

  ((${#servers[@]} > 0)) || die "No servers configured. Run restic-cli setup first."

  msg_info "Available servers:" >&2
  local i=1
  for server in "${servers[@]}"; do
    printf '  %d) %s\n' "${i}" "${server}" >&2
    ((i+=1))
  done

  local choice
  while true; do
    read -r -p "Select server number: " choice
    if [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#servers[@]})); then
      printf '%s\n' "${servers[$((choice - 1))]}"
      return 0
    fi
    msg_warn "Invalid selection." >&2
  done
}

# Execute restore workflow for a selected server.
run_restore() {
  install_error_trap
  install_signal_traps

  print_header "restic-cli restore"

  load_global_config
  ensure_local_restic
  ensure_local_rsync

  local requested_server="${1:-}"
  local requested_snapshot="${2:-latest}"
  local dry_run_mode="${3:-no}"

  if [[ "${dry_run_mode}" != "yes" && "${dry_run_mode}" != "no" ]]; then
    die "Invalid restore dry-run mode: ${dry_run_mode}"
  fi

  if [[ -z "${requested_server}" ]]; then
    requested_server="$(choose_server_interactive)"
  fi

  local proceed_remote_push="yes"
  local dry_run_first="yes"
  local restore_mode="apply"

  if [[ "${dry_run_mode}" == "yes" ]]; then
    restore_mode="dry-run"
    msg_info "Restore no-push enabled. Snapshot will be restored under RESTORE_STORAGE and remote changes previewed only."
  else
    prompt_yes_no "Push restored data back to remote server ${requested_server}" proceed_remote_push yes
    [[ "${proceed_remote_push}" == "yes" ]] || die "Restore cancelled by user."
    prompt_yes_no "Run rsync dry-run preview before writing to remote server" dry_run_first yes
  fi

  msg_progress "Starting restore for ${requested_server} (snapshot: ${requested_snapshot}; mode: ${restore_mode})"
  restore_one_server_safe "${requested_server}" "${dry_run_first}" "${requested_snapshot}" "${restore_mode}" || die "Restore failed for ${requested_server}."

  run_cleanup

  msg_success "Restore operation finished."
}
