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
    require_command python3

    msg_info "Snapshots for ${NAME}"
    local snapshot_json snapshot_details_json snapshot_restore_json snapshot_raw_json snapshot_id snapshot_time snapshot_hostname snapshot_tags snapshot_paths snapshot_restore_bytes snapshot_raw_bytes snapshot_data_size snapshot_snapshot_size
    local -a snapshot_ids=()
    local -a snapshot_details=()

    snapshot_json="$(restic -r "${repo_path}" --password-file "${pass_file}" --retry-lock "${RESTIC_RETRY_LOCK_DEFAULT}" snapshots --host "${NAME}" --json)" || \
      die "Failed to list snapshots for ${NAME}."

    mapfile -t snapshot_ids < <(
      printf '%s' "${snapshot_json}" | python3 -c 'import json, sys; data = json.load(sys.stdin); [print(item["id"]) for item in data]'
    )

    ((${#snapshot_ids[@]} > 0)) || die "No snapshots found for ${NAME}."

    printf '%-10s %-20s %-14s %-24s %-12s %-14s %s\n' "ID" "Time" "Host" "Tags" "Data Size" "Snapshot Size" "Paths"
    printf '%-10s %-20s %-14s %-24s %-12s %-14s %s\n' "----------" "----" "----" "----" "---------" "-------------" "-----"

    for snapshot_id in "${snapshot_ids[@]}"; do
      snapshot_details_json="$(printf '%s' "${snapshot_json}" | python3 -c 'import json, sys; snapshot_id = sys.argv[1]; data = json.load(sys.stdin); item = next((entry for entry in data if entry.get("id") == snapshot_id), None); print("|".join([item.get("time", ""), item.get("hostname", ""), ", ".join(item.get("tags") or []) or "-", ", ".join(item.get("paths") or []) or "-"])) if item is not None else sys.exit(1)' "${snapshot_id}")" || \
        die "Failed to read snapshot metadata for ${snapshot_id}."

      snapshot_restore_json="$(restic -r "${repo_path}" --password-file "${pass_file}" --retry-lock "${RESTIC_RETRY_LOCK_DEFAULT}" stats --mode restore-size --json "${snapshot_id}")" || \
        die "Failed to calculate restore size for snapshot ${snapshot_id}."

      snapshot_raw_json="$(restic -r "${repo_path}" --password-file "${pass_file}" --retry-lock "${RESTIC_RETRY_LOCK_DEFAULT}" stats --mode raw-data --json "${snapshot_id}")" || \
        die "Failed to calculate raw data size for snapshot ${snapshot_id}."

      IFS='|' read -r snapshot_time snapshot_hostname snapshot_tags snapshot_paths <<< "${snapshot_details_json}"

      mapfile -t snapshot_restore_stats < <(
        printf '%s' "${snapshot_restore_json}" | python3 -c 'import json, sys; obj = json.load(sys.stdin); print(obj.get("total_size", 0))'
      )
      snapshot_restore_bytes="${snapshot_restore_stats[0]:-0}"

      mapfile -t snapshot_raw_stats < <(
        printf '%s' "${snapshot_raw_json}" | python3 -c 'import json, sys; obj = json.load(sys.stdin); print(obj.get("total_size", 0))'
      )
      snapshot_raw_bytes="${snapshot_raw_stats[0]:-0}"

      snapshot_data_size="$(format_bytes "${snapshot_restore_bytes}")"
      snapshot_snapshot_size="$(format_bytes "${snapshot_raw_bytes}")"

      printf '%-10s %-20s %-14s %-24s %-12s %-14s %s\n' \
        "${snapshot_id:0:8}" \
        "${snapshot_time:0:19}" \
        "${snapshot_hostname}" \
        "${snapshot_tags}" \
        "${snapshot_data_size}" \
        "${snapshot_snapshot_size}" \
        "${snapshot_paths}"
    done
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

  restic -r "${repo_path}" --password-file "${pass_file}" --retry-lock "${RESTIC_RETRY_LOCK_DEFAULT}" snapshots "${snapshot_a}" --host "${NAME}" >/dev/null 2>&1 || \
    die "Snapshot ${snapshot_a} not found for ${NAME}."
  restic -r "${repo_path}" --password-file "${pass_file}" --retry-lock "${RESTIC_RETRY_LOCK_DEFAULT}" snapshots "${snapshot_b}" --host "${NAME}" >/dev/null 2>&1 || \
    die "Snapshot ${snapshot_b} not found for ${NAME}."

  msg_info "Diff for ${NAME}: ${snapshot_a} -> ${snapshot_b}"
  restic -r "${repo_path}" --password-file "${pass_file}" --retry-lock "${RESTIC_RETRY_LOCK_DEFAULT}" diff "${snapshot_a}" "${snapshot_b}" || \
    die "Failed to diff snapshots for ${NAME}."
}

# Remove older snapshots whose staged source paths are identical to a newer snapshot.
run_prune_identical_snapshots() {
  install_error_trap
  install_signal_traps

  print_header "restic-cli prune"
  load_global_config
  ensure_local_restic

  local server_name="$1"
  local auto_prune="${2:-no}"
  load_server_config "${server_name}"

  local pass_file repo_path
  pass_file="$(password_file_path "${NAME}")"
  repo_path="$(repository_path "${REPOSITORY}")"

  [[ -f "${pass_file}" ]] || die "Password file missing for ${NAME}: ${pass_file}"
  validate_repository "${repo_path}" "${pass_file}"

  local snapshot_ids_json
  snapshot_ids_json="$(restic -r "${repo_path}" --password-file "${pass_file}" --retry-lock "${RESTIC_RETRY_LOCK_DEFAULT}" snapshots --host "${NAME}" --json)" || \
    die "Failed to list snapshots for ${NAME}."

  local -a snapshot_meta_lines=()
  while IFS= read -r snapshot_line; do
    [[ -n "${snapshot_line}" ]] && snapshot_meta_lines+=("${snapshot_line}")
  done < <(
    printf '%s' "${snapshot_ids_json}" | python3 -c 'import json, re, sys; data = json.load(sys.stdin); normalize = lambda path: re.sub(r"^.*?/tmp/stage-[^/]+(?:\.[^/]+)?/", "", path); [print("|".join([item.get("time", ""), item.get("id", ""), (" | ".join(sorted(normalize(path) for path in (item.get("paths") or []))) if (item.get("paths") or []) else "-"), item.get("tree") or "-"])) for item in sorted(data, key=lambda entry: entry.get("time", ""))]'
  )

  ((${#snapshot_meta_lines[@]} > 0)) || die "No snapshots found for ${NAME}."

  local -a sorted_snapshot_meta=()
  while IFS= read -r snapshot_line; do
    [[ -n "${snapshot_line}" ]] && sorted_snapshot_meta+=("${snapshot_line}")
  done < <(printf '%s\n' "${snapshot_meta_lines[@]}" | sort)

  local -A latest_snapshot_for_key=()
  local -A time_for_snapshot=()
  local -A display_paths_for_snapshot=()
  local -A key_for_snapshot=()
  local -a duplicate_snapshot_ids=()
  local snapshot_line

  for snapshot_line in "${sorted_snapshot_meta[@]}"; do
    IFS='|' read -r snapshot_time snapshot_id snapshot_paths snapshot_tree <<< "${snapshot_line}"
    snapshot_key="${snapshot_paths}@@${snapshot_tree}"
    time_for_snapshot["${snapshot_id}"]="${snapshot_time}"
    display_paths_for_snapshot["${snapshot_id}"]="${snapshot_paths}"
    key_for_snapshot["${snapshot_id}"]="${snapshot_key}"

    if [[ -n "${latest_snapshot_for_key[${snapshot_key}]:-}" ]]; then
      duplicate_snapshot_ids+=("${latest_snapshot_for_key[${snapshot_key}]}")
    fi

    latest_snapshot_for_key["${snapshot_key}"]="${snapshot_id}"
  done

  if ((${#duplicate_snapshot_ids[@]} == 0)); then
    msg_info "No identical snapshots found for ${NAME}."
    return 0
  fi

  msg_info "Found ${#duplicate_snapshot_ids[@]} older snapshot(s) with identical staged paths for ${NAME}."
  printf '%-12s %-20s %-54s %-12s\n' "REMOVE_ID" "TIME" "PATHS" "KEEP_ID"
  printf '%-12s %-20s %-54s %-12s\n' "---------" "----" "-----" "-------"

  for snapshot_id in "${duplicate_snapshot_ids[@]}"; do
    printf '%-12s %-20s %-54s %-12s\n' \
      "${snapshot_id:0:12}" \
      "${time_for_snapshot[${snapshot_id}]:0:19}" \
      "${display_paths_for_snapshot[${snapshot_id}]:0:54}" \
      "${latest_snapshot_for_key[${key_for_snapshot[${snapshot_id}]}]:0:12}"
  done

  if [[ "${auto_prune}" != "yes" ]]; then
    local confirm_prune=""
    prompt_yes_no "Forget these older identical snapshots and run restic prune" confirm_prune no
    [[ "${confirm_prune}" == "yes" ]] || die "Prune cancelled by user."
  fi

  restic -r "${repo_path}" --password-file "${pass_file}" --retry-lock "${RESTIC_RETRY_LOCK_DEFAULT}" \
    forget "${duplicate_snapshot_ids[@]}" --prune --verbose || die "Failed to forget identical snapshots for ${NAME}."

  write_operation_log "${NAME}" "prune" "success" "0" "Removed ${#duplicate_snapshot_ids[@]} identical older snapshot(s)"
  msg_success "Removed ${#duplicate_snapshot_ids[@]} identical older snapshot(s) for ${NAME}."
}
