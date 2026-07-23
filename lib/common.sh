#!/usr/bin/env bash
set -Eeuo pipefail

# Shared utilities for restic-cli modules.
# shellcheck disable=SC2034
RESTIC_CLI_VERSION="1.0.0"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

GLOBAL_CONFIG_FILE="${PROJECT_ROOT}/config.conf"
SERVER_CONFIG_DIR="${PROJECT_ROOT}/servers"
PASSWORD_DIR_DEFAULT="${PROJECT_ROOT}/passwords"
LOG_DIR_DEFAULT="${PROJECT_ROOT}/logs"
TMP_DIR_DEFAULT="${PROJECT_ROOT}/tmp"

# These values are loaded from config.conf.
BACKUP_STORAGE=""
RESTORE_STORAGE=""
LOG_DIRECTORY="${LOG_DIR_DEFAULT}"
PASSWORD_DIRECTORY="${PASSWORD_DIR_DEFAULT}"
SHARED_PASSWORD_FILE="shared.pass"
SCHEDULER_STATE_SUBDIR="scheduler"
RESTIC_RETRY_LOCK_DEFAULT="5m"

# Runtime settings.
SSH_CONNECT_TIMEOUT="10"
SSH_OPTS_COMMON=(
  -o BatchMode=yes
  -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}"
  -o StrictHostKeyChecking=accept-new
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=3
)

# Cleanup paths registered during runtime.
CLEANUP_PATHS=()

# Color definitions for terminal output.
if [[ -t 1 ]]; then
  C_RESET='\033[0m'
  C_RED='\033[0;31m'
  C_GREEN='\033[0;32m'
  C_YELLOW='\033[0;33m'
  C_BLUE='\033[0;34m'
  C_CYAN='\033[0;36m'
  C_BOLD='\033[1m'
else
  C_RESET=''
  C_RED=''
  C_GREEN=''
  C_YELLOW=''
  C_BLUE=''
  C_CYAN=''
  C_BOLD=''
fi

# Variables loaded from each server config by load_server_config.
NAME=""
HOST=""
USER=""
SSH_PORT=""
REPOSITORY=""
BACKUP_PATHS=""
BACKUP_FREQUENCY=""
BACKUP_TIME=""
BACKUP_DAY=""
BACKUP_ANCHOR_DATE=""
RETENTION_POLICY=""

# Print a timestamp in UTC for logs.
now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Print a friendly local timestamp.
now_local() {
  date +"%Y-%m-%d %H:%M:%S"
}

# Print a blue informational line.
msg_info() {
  local text="$1"
  printf '%b[%s] INFO%b %s\n' "${C_BLUE}" "$(now_local)" "${C_RESET}" "${text}"
}

# Print a cyan progress line.
msg_progress() {
  local text="$1"
  printf '%b[%s] ... %b %s\n' "${C_CYAN}" "$(now_local)" "${C_RESET}" "${text}"
}

# Print a yellow warning line.
msg_warn() {
  local text="$1"
  printf '%b[%s] WARN%b %s\n' "${C_YELLOW}" "$(now_local)" "${C_RESET}" "${text}"
}

# Print a green success line.
msg_success() {
  local text="$1"
  printf '%b[%s] OK  %b %s\n' "${C_GREEN}" "$(now_local)" "${C_RESET}" "${text}"
}

# Print a red error line to stderr.
msg_error() {
  local text="$1"
  printf '%b[%s] ERR %b %s\n' "${C_RED}" "$(now_local)" "${C_RESET}" "${text}" >&2
}

# Exit with an error message.
die() {
  local text="$1"
  msg_error "${text}"
  exit 1
}

# Catch unhandled command failures and stop with context.
on_unhandled_error() {
  local exit_code="$1"
  local line_no="$2"
  local file_name="$3"
  msg_error "Unhandled error in ${file_name}:${line_no} (exit ${exit_code})."
  run_cleanup
  exit "${exit_code}"
}

# Register error trap for the current shell.
install_error_trap() {
  trap 'on_unhandled_error $? ${LINENO} ${BASH_SOURCE[0]}' ERR
}

# Register signal traps to cleanup temp files.
install_signal_traps() {
  trap 'run_cleanup; exit 130' INT
  trap 'run_cleanup; exit 143' TERM
}

# Add a path to the cleanup list.
register_cleanup_path() {
  local path="$1"
  CLEANUP_PATHS+=("${path}")
}

# Delete all registered cleanup paths if they still exist.
run_cleanup() {
  local path
  for path in "${CLEANUP_PATHS[@]:-}"; do
    if [[ -n "${path}" && -e "${path}" ]]; then
      rm -rf -- "${path}" || true
    fi
  done
  CLEANUP_PATHS=()
}

# Ensure all required project directories exist.
ensure_project_directories() {
  mkdir -p -- "${SERVER_CONFIG_DIR}" "${PASSWORD_DIR_DEFAULT}" "${LOG_DIR_DEFAULT}" "${TMP_DIR_DEFAULT}"
}

# Ensure a command exists in PATH.
require_command() {
  local cmd="$1"
  command -v -- "${cmd}" >/dev/null 2>&1 || die "Required command not found: ${cmd}"
}

# Read and validate global config file.
load_global_config() {
  ensure_project_directories

  if [[ ! -f "${GLOBAL_CONFIG_FILE}" ]]; then
    die "Global config missing: ${GLOBAL_CONFIG_FILE}. Run restic-cli init first."
  fi

  # shellcheck disable=SC1090
  source "${GLOBAL_CONFIG_FILE}"

  BACKUP_STORAGE="${BACKUP_STORAGE:-}"
  RESTORE_STORAGE="${RESTORE_STORAGE:-}"
  LOG_DIRECTORY="${LOG_DIRECTORY:-${LOG_DIR_DEFAULT}}"
  PASSWORD_DIRECTORY="${PASSWORD_DIRECTORY:-${PASSWORD_DIR_DEFAULT}}"
  SHARED_PASSWORD_FILE="${SHARED_PASSWORD_FILE:-shared.pass}"

  [[ -n "${BACKUP_STORAGE}" ]] || die "BACKUP_STORAGE is empty in ${GLOBAL_CONFIG_FILE}"
  [[ -n "${RESTORE_STORAGE}" ]] || die "RESTORE_STORAGE is empty in ${GLOBAL_CONFIG_FILE}"
  [[ -n "${SHARED_PASSWORD_FILE}" ]] || die "SHARED_PASSWORD_FILE is empty in ${GLOBAL_CONFIG_FILE}"

  if [[ "${SHARED_PASSWORD_FILE}" == *"/"* ]]; then
    die "SHARED_PASSWORD_FILE must be a filename, not a path: ${SHARED_PASSWORD_FILE}"
  fi

  mkdir -p -- "${BACKUP_STORAGE}" "${RESTORE_STORAGE}" "${LOG_DIRECTORY}" "${PASSWORD_DIRECTORY}" "${TMP_DIR_DEFAULT}"

  [[ -d "${BACKUP_STORAGE}" ]] || die "BACKUP_STORAGE is not a directory: ${BACKUP_STORAGE}"
  [[ -d "${RESTORE_STORAGE}" ]] || die "RESTORE_STORAGE is not a directory: ${RESTORE_STORAGE}"
  [[ -w "${BACKUP_STORAGE}" ]] || die "BACKUP_STORAGE is not writable: ${BACKUP_STORAGE}"
  [[ -w "${RESTORE_STORAGE}" ]] || die "RESTORE_STORAGE is not writable: ${RESTORE_STORAGE}"
}

# Return the directory storing scheduler state files.
scheduler_state_dir() {
  printf '%s/%s\n' "${LOG_DIRECTORY}" "${SCHEDULER_STATE_SUBDIR}"
}

# Return scheduler state file path for a server.
scheduler_state_file() {
  local server_name="$1"
  printf '%s/%s.last_success\n' "$(scheduler_state_dir)" "${server_name}"
}

# Return a safe server config path for a server name.
server_config_path() {
  local server_name="$1"
  printf '%s/%s.conf\n' "${SERVER_CONFIG_DIR}" "${server_name}"
}

# Return a safe password file path for a server name.
password_file_path() {
  local _server_name="${1:-}"
  printf '%s/%s\n' "${PASSWORD_DIRECTORY}" "${SHARED_PASSWORD_FILE}"
}

# Return repository path for a server config.
repository_path() {
  local repository_name="$1"
  printf '%s/%s\n' "${BACKUP_STORAGE}" "${repository_name}"
}

# Validate a server name for filesystem use.
validate_server_name() {
  local server_name="$1"
  [[ "${server_name}" =~ ^[a-zA-Z0-9._-]+$ ]] || return 1
  return 0
}

# Validate backup frequency against supported options.
validate_backup_frequency() {
  local frequency="$1"
  case "${frequency}" in
    "once a day"|"once a week"|"every 2wk")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Validate backup time as HH:MM in 24-hour format.
validate_backup_time() {
  local backup_time="$1"
  [[ "${backup_time}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || return 1
  return 0
}

# Validate backup day against supported weekday names.
validate_backup_day() {
  local backup_day="$1"
  case "${backup_day}" in
    Mon|Tue|Wed|Thu|Fri|Sat|Sun)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Validate anchor date as YYYY-MM-DD.
validate_anchor_date() {
  local anchor_date="$1"
  [[ "${anchor_date}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  date -d "${anchor_date}" +%F >/dev/null 2>&1 || return 1
  return 0
}

# Return the current weekday name in short format.
current_weekday_name() {
  date +"%a"
}

# Convert weekday short name to ISO weekday number.
backup_day_to_iso_weekday() {
  local backup_day="$1"
  case "${backup_day}" in
    Mon) printf '1\n' ;;
    Tue) printf '2\n' ;;
    Wed) printf '3\n' ;;
    Thu) printf '4\n' ;;
    Fri) printf '5\n' ;;
    Sat) printf '6\n' ;;
    Sun) printf '7\n' ;;
    *) return 1 ;;
  esac
}

# Build an epoch from a YYYY-MM-DD date and HH:MM time.
epoch_for_date_and_time() {
  local date_value="$1"
  local time_value="$2"
  date -d "${date_value} ${time_value}" +%s
}

# Return latest daily scheduled epoch not later than now.
latest_daily_schedule_epoch() {
  local now_epoch="$1"
  local backup_time="$2"
  local today_epoch scheduled_epoch

  today_epoch="$(date -d "@${now_epoch}" +%F)"
  scheduled_epoch="$(epoch_for_date_and_time "${today_epoch}" "${backup_time}")"

  if (( scheduled_epoch <= now_epoch )); then
    printf '%s\n' "${scheduled_epoch}"
  else
    epoch_for_date_and_time "$(date -d "${today_epoch} -1 day" +%F)" "${backup_time}"
  fi
}

# Return latest weekly scheduled epoch not later than now.
latest_weekly_schedule_epoch() {
  local now_epoch="$1"
  local backup_day="$2"
  local backup_time="$3"
  local target_weekday current_weekday offset_days today_date candidate_date candidate_epoch

  target_weekday="$(backup_day_to_iso_weekday "${backup_day}")" || return 1
  current_weekday="$(date -d "@${now_epoch}" +%u)"
  offset_days="$((current_weekday - target_weekday))"

  today_date="$(date -d "@${now_epoch}" +%F)"
  candidate_date="$(date -d "${today_date} ${offset_days} days" +%F)"
  candidate_epoch="$(epoch_for_date_and_time "${candidate_date}" "${backup_time}")"

  if (( candidate_epoch <= now_epoch )); then
    printf '%s\n' "${candidate_epoch}"
  else
    epoch_for_date_and_time "$(date -d "${candidate_date} -7 days" +%F)" "${backup_time}"
  fi
}

# Return first weekly scheduled epoch on or after anchor date.
first_weekly_schedule_on_or_after_epoch() {
  local anchor_date="$1"
  local backup_day="$2"
  local backup_time="$3"
  local target_weekday anchor_weekday offset_days candidate_date candidate_epoch

  target_weekday="$(backup_day_to_iso_weekday "${backup_day}")" || return 1
  anchor_weekday="$(date -d "${anchor_date}" +%u)"
  offset_days="$((target_weekday - anchor_weekday))"
  if (( offset_days < 0 )); then
    offset_days="$((offset_days + 7))"
  fi

  candidate_date="$(date -d "${anchor_date} +${offset_days} days" +%F)"
  candidate_epoch="$(epoch_for_date_and_time "${candidate_date}" "${backup_time}")"
  printf '%s\n' "${candidate_epoch}"
}

# Return latest biweekly scheduled epoch not later than now, or 0 if schedule has not started.
latest_biweekly_schedule_epoch() {
  local now_epoch="$1"
  local backup_day="$2"
  local backup_time="$3"
  local anchor_date="$4"
  local anchor_epoch candidate_epoch diff_days

  anchor_epoch="$(first_weekly_schedule_on_or_after_epoch "${anchor_date}" "${backup_day}" "${backup_time}")" || return 1
  if (( now_epoch < anchor_epoch )); then
    printf '0\n'
    return 0
  fi

  candidate_epoch="$(latest_weekly_schedule_epoch "${now_epoch}" "${backup_day}" "${backup_time}")" || return 1

  while (( candidate_epoch >= anchor_epoch )); do
    diff_days="$(((candidate_epoch - anchor_epoch) / 86400))"
    if (( diff_days % 14 == 0 )); then
      printf '%s\n' "${candidate_epoch}"
      return 0
    fi
    candidate_epoch="$((candidate_epoch - 604800))"
  done

  printf '0\n'
  return 0
}

# Return latest scheduled epoch for a configured schedule, or 0 when not yet started.
latest_scheduled_backup_epoch() {
  local frequency="$1"
  local backup_time="$2"
  local backup_day="$3"
  local anchor_date="$4"
  local now_epoch="$5"

  case "${frequency}" in
    "once a day")
      latest_daily_schedule_epoch "${now_epoch}" "${backup_time}"
      ;;
    "once a week")
      latest_weekly_schedule_epoch "${now_epoch}" "${backup_day}" "${backup_time}"
      ;;
    "every 2wk")
      latest_biweekly_schedule_epoch "${now_epoch}" "${backup_day}" "${backup_time}" "${anchor_date}"
      ;;
    *)
      return 1
      ;;
  esac
}

# Validate retention policy against supported options.
validate_retention_policy() {
  local policy="$1"
  case "${policy}" in
    "1snapshots"|"3snapshots"|"5snapshots"|"7snapshots")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Map retention label to restic --keep-last value.
retention_policy_to_keep_last() {
  local policy="$1"
  case "${policy}" in
    "1snapshots")
      printf '1\n'
      ;;
    "3snapshots")
      printf '3\n'
      ;;
    "5snapshots")
      printf '5\n'
      ;;
    "7snapshots")
      printf '7\n'
      ;;
    *)
      return 1
      ;;
  esac
}

# Read the last successful backup epoch for a server, or 0 if none exists.
read_last_backup_epoch() {
  local server_name="$1"
  local state_file
  state_file="$(scheduler_state_file "${server_name}")"

  if [[ ! -f "${state_file}" ]]; then
    printf '0\n'
    return 0
  fi

  local value
  value="$(<"${state_file}")"
  if [[ "${value}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${value}"
    return 0
  fi

  die "Invalid scheduler state in ${state_file}"
}

# Record the current epoch as the last successful backup for a server.
record_last_backup_epoch() {
  local server_name="$1"
  local epoch_value="${2:-$(date +%s)}"
  local state_dir state_file

  [[ "${epoch_value}" =~ ^[0-9]+$ ]] || die "Invalid epoch value for ${server_name}: ${epoch_value}"

  state_dir="$(scheduler_state_dir)"
  state_file="$(scheduler_state_file "${server_name}")"
  mkdir -p -- "${state_dir}"
  printf '%s\n' "${epoch_value}" > "${state_file}"
}

# Return success when a backup is due based on schedule fields and last success epoch.
is_backup_due() {
  local frequency="$1"
  local backup_time="$2"
  local backup_day="$3"
  local anchor_date="$4"
  local last_epoch="$5"
  local now_epoch="$6"
  local scheduled_epoch

  validate_backup_frequency "${frequency}" || return 1
  validate_backup_time "${backup_time}" || return 1
  [[ "${last_epoch}" =~ ^[0-9]+$ ]] || return 1
  [[ "${now_epoch}" =~ ^[0-9]+$ ]] || return 1

  if [[ "${frequency}" == "once a week" || "${frequency}" == "every 2wk" ]]; then
    validate_backup_day "${backup_day}" || return 1
  fi

  if [[ "${frequency}" == "every 2wk" ]]; then
    validate_anchor_date "${anchor_date}" || return 1
  fi

  scheduled_epoch="$(latest_scheduled_backup_epoch "${frequency}" "${backup_time}" "${backup_day}" "${anchor_date}" "${now_epoch}")" || return 1
  [[ "${scheduled_epoch}" =~ ^[0-9]+$ ]] || return 1

  if (( scheduled_epoch == 0 )); then
    return 1
  fi

  if (( last_epoch < scheduled_epoch )); then
    return 0
  fi

  return 1
}

# Load a server config into global variables.
load_server_config() {
  local server_name="$1"
  local config_path
  config_path="$(server_config_path "${server_name}")"

  [[ -f "${config_path}" ]] || die "Server config not found: ${config_path}"

  NAME=""
  HOST=""
  USER=""
  SSH_PORT=""
  REPOSITORY=""
  BACKUP_PATHS=""
  BACKUP_FREQUENCY=""
  BACKUP_TIME=""
  BACKUP_DAY=""
  BACKUP_ANCHOR_DATE=""
  RETENTION_POLICY=""

  # shellcheck disable=SC1090
  source "${config_path}"

  NAME="${NAME:-}"
  HOST="${HOST:-}"
  USER="${USER:-}"
  SSH_PORT="${SSH_PORT:-}"
  REPOSITORY="${REPOSITORY:-}"
  BACKUP_PATHS="${BACKUP_PATHS:-}"
  BACKUP_FREQUENCY="${BACKUP_FREQUENCY:-once a day}"
  BACKUP_TIME="${BACKUP_TIME:-02:00}"
  BACKUP_DAY="${BACKUP_DAY:-}"
  BACKUP_ANCHOR_DATE="${BACKUP_ANCHOR_DATE:-}"
  RETENTION_POLICY="${RETENTION_POLICY:-7snapshots}"

  [[ -n "${NAME}" ]] || die "NAME missing in ${config_path}"
  [[ -n "${HOST}" ]] || die "HOST missing in ${config_path}"
  [[ -n "${USER}" ]] || die "USER missing in ${config_path}"
  [[ -n "${SSH_PORT}" ]] || die "SSH_PORT missing in ${config_path}"
  [[ -n "${REPOSITORY}" ]] || die "REPOSITORY missing in ${config_path}"
  [[ -n "${BACKUP_PATHS}" ]] || die "BACKUP_PATHS missing in ${config_path}"
  [[ -n "${BACKUP_FREQUENCY}" ]] || die "BACKUP_FREQUENCY missing in ${config_path}"
  [[ -n "${BACKUP_TIME}" ]] || die "BACKUP_TIME missing in ${config_path}"
  [[ -n "${RETENTION_POLICY}" ]] || die "RETENTION_POLICY missing in ${config_path}"

  [[ "${SSH_PORT}" =~ ^[0-9]{1,5}$ ]] || die "Invalid SSH_PORT in ${config_path}: ${SSH_PORT}"
  validate_server_name "${NAME}" || die "Invalid NAME in ${config_path}: ${NAME}"
  validate_backup_frequency "${BACKUP_FREQUENCY}" || die "Invalid BACKUP_FREQUENCY in ${config_path}: ${BACKUP_FREQUENCY}"
  validate_backup_time "${BACKUP_TIME}" || die "Invalid BACKUP_TIME in ${config_path}: ${BACKUP_TIME}"
  if [[ "${BACKUP_FREQUENCY}" == "once a week" || "${BACKUP_FREQUENCY}" == "every 2wk" ]]; then
    [[ -n "${BACKUP_DAY}" ]] || die "BACKUP_DAY missing in ${config_path}"
    validate_backup_day "${BACKUP_DAY}" || die "Invalid BACKUP_DAY in ${config_path}: ${BACKUP_DAY}"
  fi
  if [[ "${BACKUP_FREQUENCY}" == "every 2wk" ]]; then
    [[ -n "${BACKUP_ANCHOR_DATE}" ]] || die "BACKUP_ANCHOR_DATE missing in ${config_path}"
    validate_anchor_date "${BACKUP_ANCHOR_DATE}" || die "Invalid BACKUP_ANCHOR_DATE in ${config_path}: ${BACKUP_ANCHOR_DATE}"
  fi
  validate_retention_policy "${RETENTION_POLICY}" || die "Invalid RETENTION_POLICY in ${config_path}: ${RETENTION_POLICY}"
}

# Emit server names based on config file names.
list_server_names() {
  local config_file base
  shopt -s nullglob
  for config_file in "${SERVER_CONFIG_DIR}"/*.conf; do
    base="$(basename -- "${config_file}")"
    printf '%s\n' "${base%.conf}"
  done
  shopt -u nullglob
}

# Convert BACKUP_PATHS multiline string into array.
parse_backup_paths() {
  local raw_input="$1"
  local -n _result_ref="$2"
  local line trimmed

  _result_ref=()
  while IFS= read -r line; do
    trimmed="${line//[$'\t\r']/}"
    trimmed="${trimmed## }"
    trimmed="${trimmed%% }"

    if [[ -n "${trimmed}" ]]; then
      _result_ref+=("${trimmed}")
    fi
  done <<< "${raw_input}"

  ((${#_result_ref[@]} > 0)) || return 1
  return 0
}

# Build SSH target and execute a remote command.
ssh_exec() {
  local host="$1"
  local user="$2"
  local port="$3"
  shift 3

  ssh "${SSH_OPTS_COMMON[@]}" -p "${port}" "${user}@${host}" "$@"
}

# Test SSH connectivity with a short remote command.
validate_ssh_connection() {
  local host="$1"
  local user="$2"
  local port="$3"

  if ! ssh_exec "${host}" "${user}" "${port}" "echo ssh-ok" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# Ensure local Restic exists.
ensure_local_restic() {
  require_command restic
}

# Ensure local rsync exists.
ensure_local_rsync() {
  require_command rsync
}

# Ensure openssl exists for password generation.
ensure_local_openssl() {
  require_command openssl
}

# Validate that repository is initialized and readable.
validate_repository() {
  local repo_path="$1"
  local pass_file="$2"

  [[ -d "${repo_path}" ]] || die "Repository directory missing: ${repo_path}"
  [[ -f "${pass_file}" ]] || die "Password file missing: ${pass_file}"

  if ! restic -r "${repo_path}" --password-file "${pass_file}" snapshots --last --no-lock >/dev/null 2>&1; then
    # snapshots --last fails on empty repositories, so list snapshots normally.
    if ! restic -r "${repo_path}" --password-file "${pass_file}" snapshots --no-lock >/dev/null 2>&1; then
      die "Repository validation failed: ${repo_path}"
    fi
  fi
}

# Write a structured operation log entry.
write_operation_log() {
  local server="$1"
  local operation="$2"
  local status="$3"
  local duration_seconds="$4"
  local detail="$5"

  local log_file="${LOG_DIRECTORY}/backup.log"
  mkdir -p -- "${LOG_DIRECTORY}"

  printf '%s | server=%s | operation=%s | status=%s | duration=%ss | %s\n' \
    "$(now_utc)" "${server}" "${operation}" "${status}" "${duration_seconds}" "${detail}" \
    >> "${log_file}"
}

# Print a title header for command sections.
print_header() {
  local title="$1"
  printf '\n%b%s%b\n' "${C_BOLD}" "${title}" "${C_RESET}"
}

# Ask the user for input with a default value.
prompt_with_default() {
  local prompt_label="$1"
  local default_value="$2"
  local result_var="$3"
  local answer

  if [[ -n "${default_value}" ]]; then
    read -r -p "${prompt_label} [${default_value}]: " answer
    answer="${answer:-${default_value}}"
  else
    read -r -p "${prompt_label}: " answer
  fi

  printf -v "${result_var}" '%s' "${answer}"
}

# Ask until a non-empty value is entered.
prompt_non_empty() {
  local prompt_label="$1"
  local result_var="$2"
  local answer=""

  while [[ -z "${answer}" ]]; do
    read -r -p "${prompt_label}: " answer
    if [[ -z "${answer}" ]]; then
      msg_warn "Value cannot be empty."
    fi
  done

  printf -v "${result_var}" '%s' "${answer}"
}

# Ask for yes/no confirmation.
prompt_yes_no() {
  local prompt_label="$1"
  local result_var="$2"
  local default_choice="${3:-yes}"
  local answer=""

  while true; do
    if [[ "${default_choice}" == "yes" ]]; then
      read -r -p "${prompt_label} [Y/n]: " answer
      answer="${answer:-Y}"
    else
      read -r -p "${prompt_label} [y/N]: " answer
      answer="${answer:-N}"
    fi

    case "${answer}" in
      Y|y|Yes|yes)
        printf -v "${result_var}" '%s' "yes"
        return 0
        ;;
      N|n|No|no)
        printf -v "${result_var}" '%s' "no"
        return 0
        ;;
      *)
        msg_warn "Please answer yes or no."
        ;;
    esac
  done
}

# Create a timestamped temporary workspace.
create_temp_workspace() {
  local prefix="$1"
  local dir

  dir="$(mktemp -d "${TMP_DIR_DEFAULT}/${prefix}.XXXXXX")"
  register_cleanup_path "${dir}"
  printf '%s\n' "${dir}"
}

# Run a command with tee logging to a per-command log file.
run_logged_command() {
  local log_file="$1"
  shift

  mkdir -p -- "$(dirname -- "${log_file}")"
  "$@" 2>&1 | tee -a "${log_file}"
}
