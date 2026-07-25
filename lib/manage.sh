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
    local snapshot_json snapshot_details_json snapshot_stats_json snapshot_id snapshot_time snapshot_hostname snapshot_tags snapshot_paths snapshot_bytes snapshot_size
    local -a snapshot_ids=()
    local -a snapshot_details=()

    snapshot_json="$(restic -r "${repo_path}" --password-file "${pass_file}" --retry-lock "${RESTIC_RETRY_LOCK_DEFAULT}" snapshots --host "${NAME}" --json)" || \
      die "Failed to list snapshots for ${NAME}."

    mapfile -t snapshot_ids < <(
      printf '%s' "${snapshot_json}" | python3 -c 'import json, sys; data = json.load(sys.stdin); [print(item["id"]) for item in data]'
    )

    ((${#snapshot_ids[@]} > 0)) || die "No snapshots found for ${NAME}."

    printf '%-10s %-20s %-14s %-18s %-12s %s\n' "ID" "Time" "Host" "Tags" "Size" "Paths"
    printf '%-10s %-20s %-14s %-18s %-12s %s\n' "----------" "----" "----" "----" "----" "-----"

    for snapshot_id in "${snapshot_ids[@]}"; do
      snapshot_details_json="$(printf '%s' "${snapshot_json}" | python3 -c 'import json, sys; snapshot_id = sys.argv[1]; data = json.load(sys.stdin); item = next((entry for entry in data if entry.get("id") == snapshot_id), None); print("|".join([item.get("time", ""), item.get("hostname", ""), ", ".join(item.get("tags") or []) or "-", ", ".join(item.get("paths") or []) or "-"])) if item is not None else sys.exit(1)' "${snapshot_id}")" || \
        die "Failed to read snapshot metadata for ${snapshot_id}."

      snapshot_stats_json="$(restic -r "${repo_path}" --password-file "${pass_file}" --retry-lock "${RESTIC_RETRY_LOCK_DEFAULT}" stats --mode restore-size --json --host "${NAME}" "${snapshot_id}")" || \
        die "Failed to calculate size for snapshot ${snapshot_id}."

      IFS='|' read -r snapshot_time snapshot_hostname snapshot_tags snapshot_paths <<< "${snapshot_details_json}"

      mapfile -t snapshot_stats < <(
        printf '%s' "${snapshot_stats_json}" | python3 -c 'import json, sys; obj = json.load(sys.stdin); print(obj.get("total_size", 0))'
      )
      snapshot_bytes="${snapshot_stats[0]:-0}"

      snapshot_size="$(format_bytes "${snapshot_bytes}")"

      printf '%-10s %-20s %-14s %-18s %-12s %s\n' \
        "${snapshot_id:0:8}" \
        "${snapshot_time:0:19}" \
        "${snapshot_hostname}" \
        "${snapshot_tags}" \
        "${snapshot_size}" \
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

# Remove older snapshots whose tree is identical to a newer snapshot.
run_prune_identical_snapshots() {
  install_error_trap
  install_signal_traps

  print_header "restic-cli prune"
  load_global_config
  ensure_local_restic

  local server_name="$1"
  load_server_config "${server_name}"

  local pass_file repo_path
  pass_file="$(password_file_path "${NAME}")"
  repo_path="$(repository_path "${REPOSITORY}")"

  [[ -f "${pass_file}" ]] || die "Password file missing for ${NAME}: ${pass_file}"
  validate_repository "${repo_path}" "${pass_file}"

  local -a snapshot_meta_lines=()
  local snapshot_ids_json
  snapshot_ids_json="$(restic -r "${repo_path}" --password-file "${pass_file}" --retry-lock "${RESTIC_RETRY_LOCK_DEFAULT}" snapshots --host "${NAME}" --json)" || \
    die "Failed to list snapshots for ${NAME}."

  local -a snapshot_ids=()
  while IFS= read -r snapshot_id; do
    [[ -n "${snapshot_id}" ]] && snapshot_ids+=("${snapshot_id}")
  done < <(
    printf '%s\n' "${snapshot_ids_json}" | \
      grep -Eo '"id"[[:space:]]*:[[:space:]]*"[0-9a-f]+"' | \
      sed -E 's/.*"([0-9a-f]+)"$/\1/'
  )

  local snapshot_id snapshot_json snapshot_tree snapshot_time snapshot_bytes snapshot_files
  for snapshot_id in "${snapshot_ids[@]}"; do
    snapshot_json="$(restic -r "${repo_path}" --password-file "${pass_file}" --retry-lock "${RESTIC_RETRY_LOCK_DEFAULT}" cat snapshot "${snapshot_id}")" || \
      die "Failed to read snapshot metadata for ${snapshot_id}."
    snapshot_json="${snapshot_json//$'\n'/ }"

    [[ "${snapshot_json}" =~ \"tree\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] || die "Snapshot ${snapshot_id} is missing tree metadata."
    snapshot_tree="${BASH_REMATCH[1]}"
    [[ "${snapshot_json}" =~ \"time\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] || die "Snapshot ${snapshot_id} is missing time metadata."
    snapshot_time="${BASH_REMATCH[1]}"

    snapshot_bytes="0"
    if [[ "${snapshot_json}" =~ \"total_bytes_processed\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
      snapshot_bytes="${BASH_REMATCH[1]}"
    fi

    snapshot_files="0"
    if [[ "${snapshot_json}" =~ \"total_files_processed\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
      snapshot_files="${BASH_REMATCH[1]}"
    fi

    snapshot_meta_lines+=("${snapshot_time}|${snapshot_id}|${snapshot_tree}|${snapshot_files}|${snapshot_bytes}")
  done

  ((${#snapshot_meta_lines[@]} > 0)) || die "No snapshots found for ${NAME}."

  local -a sorted_snapshot_meta=()
  while IFS= read -r snapshot_line; do
    [[ -n "${snapshot_line}" ]] && sorted_snapshot_meta+=("${snapshot_line}")
  done < <(printf '%s\n' "${snapshot_meta_lines[@]}" | sort)

  local -A latest_snapshot_for_tree=()
  local -A tree_for_snapshot=()
  local -A time_for_snapshot=()
  local -A files_for_snapshot=()
  local -A bytes_for_snapshot=()
  local -a duplicate_snapshot_ids=()
  local snapshot_line

  for snapshot_line in "${sorted_snapshot_meta[@]}"; do
    IFS='|' read -r snapshot_time snapshot_id snapshot_tree snapshot_files snapshot_bytes <<< "${snapshot_line}"
    tree_for_snapshot["${snapshot_id}"]="${snapshot_tree}"
    time_for_snapshot["${snapshot_id}"]="${snapshot_time}"
    files_for_snapshot["${snapshot_id}"]="${snapshot_files}"
    bytes_for_snapshot["${snapshot_id}"]="${snapshot_bytes}"

    if [[ -n "${latest_snapshot_for_tree[${snapshot_tree}]:-}" ]]; then
      duplicate_snapshot_ids+=("${latest_snapshot_for_tree[${snapshot_tree}]}")
    fi

    latest_snapshot_for_tree["${snapshot_tree}"]="${snapshot_id}"
  done

  if ((${#duplicate_snapshot_ids[@]} == 0)); then
    msg_info "No identical snapshots found for ${NAME}."
    return 0
  fi

  msg_info "Found ${#duplicate_snapshot_ids[@]} older snapshot(s) with identical data for ${NAME}."
  printf '%-12s %-20s %-8s %-12s %-12s %-12s\n' "REMOVE_ID" "TIME" "FILES" "BYTES" "TREE" "KEEP_ID"
  printf '%-12s %-20s %-8s %-12s %-12s %-12s\n' "---------" "----" "-----" "-----" "----" "-------"

  for snapshot_id in "${duplicate_snapshot_ids[@]}"; do
    snapshot_tree="${tree_for_snapshot[${snapshot_id}]}"
    printf '%-12s %-20s %-8s %-12s %-12s %-12s\n' \
      "${snapshot_id:0:12}" \
      "${time_for_snapshot[${snapshot_id}]:0:19}" \
      "${files_for_snapshot[${snapshot_id}]}" \
      "${bytes_for_snapshot[${snapshot_id}]}" \
      "${snapshot_tree:0:12}" \
      "${latest_snapshot_for_tree[${snapshot_tree}]:0:12}"
  done

  local confirm_prune=""
  prompt_yes_no "Forget these older identical snapshots and run restic prune" confirm_prune no
  [[ "${confirm_prune}" == "yes" ]] || die "Prune cancelled by user."

  restic -r "${repo_path}" --password-file "${pass_file}" --retry-lock "${RESTIC_RETRY_LOCK_DEFAULT}" \
    forget "${duplicate_snapshot_ids[@]}" --prune --verbose || die "Failed to forget identical snapshots for ${NAME}."

  write_operation_log "${NAME}" "prune" "success" "0" "Removed ${#duplicate_snapshot_ids[@]} identical older snapshot(s)"
  msg_success "Removed ${#duplicate_snapshot_ids[@]} identical older snapshot(s) for ${NAME}."
}
