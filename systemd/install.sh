#!/usr/bin/env bash
set -Eeuo pipefail

SYSTEMD_SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SYSTEMD_SOURCE_DIR}/.." && pwd)"
SYSTEMD_TARGET_DIR="/etc/systemd/system"
LOGROTATE_TARGET_DIR="/etc/logrotate.d"
SERVICE_NAME="restic-scheduler.service"
TIMER_NAME="restic-scheduler.timer"
LOGROTATE_NAME="restic-backupctl"
CLI_LINK_PATH="/usr/local/bin/restic-backupctl"
SERVICE_SOURCE_PATH="${SYSTEMD_SOURCE_DIR}/${SERVICE_NAME}"
TIMER_SOURCE_PATH="${SYSTEMD_SOURCE_DIR}/${TIMER_NAME}"
SERVICE_TARGET_PATH="${SYSTEMD_TARGET_DIR}/${SERVICE_NAME}"
TIMER_TARGET_PATH="${SYSTEMD_TARGET_DIR}/${TIMER_NAME}"
LOGROTATE_SOURCE_PATH="${PROJECT_ROOT}/logrotate/${LOGROTATE_NAME}"
LOGROTATE_TARGET_PATH="${LOGROTATE_TARGET_DIR}/${LOGROTATE_NAME}"

# Print installer usage.
print_usage() {
  cat <<'EOF'
Usage:
  ./systemd/install.sh -i    Copy scheduler units and logrotate config into the system
  ./systemd/install.sh -rm   Remove scheduler units and logrotate config from the system
EOF
}

# Exit with an error message.
die() {
  local message="$1"
  printf 'Error: %s\n' "${message}" >&2
  exit 1
}

# Ensure the script is running with root privileges.
require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "This action must be run as root. Use sudo ./systemd/install.sh -i or sudo ./systemd/install.sh -rm"
  fi
}

# Ensure a required command exists.
require_command() {
  local command_name="$1"
  command -v -- "${command_name}" >/dev/null 2>&1 || die "Required command not found: ${command_name}"
}

# Ensure installer source files exist before installation.
verify_source_files() {
  [[ -f "${SERVICE_SOURCE_PATH}" ]] || die "Missing source unit: ${SERVICE_SOURCE_PATH}"
  [[ -f "${TIMER_SOURCE_PATH}" ]] || die "Missing source unit: ${TIMER_SOURCE_PATH}"
  [[ -f "${LOGROTATE_SOURCE_PATH}" ]] || die "Missing logrotate config: ${LOGROTATE_SOURCE_PATH}"
  [[ -x "${PROJECT_ROOT}/backupctl" ]] || die "backupctl is missing or not executable at ${PROJECT_ROOT}/backupctl"
}

# Install a stable CLI symlink target for systemd ExecStart.
install_cli_link() {
  ln -sfn -- "${PROJECT_ROOT}/backupctl" "${CLI_LINK_PATH}"
}

# Remove the stable CLI symlink if present.
remove_cli_link() {
  rm -f -- "${CLI_LINK_PATH}"
}

# Copy the service unit as-is.
install_service_unit() {
  cp -f -- "${SERVICE_SOURCE_PATH}" "${SERVICE_TARGET_PATH}"
}

# Copy the timer unit as-is.
install_timer_unit() {
  cp -f -- "${TIMER_SOURCE_PATH}" "${TIMER_TARGET_PATH}"
}

# Copy the logrotate config as-is.
install_logrotate_config() {
  cp -f -- "${LOGROTATE_SOURCE_PATH}" "${LOGROTATE_TARGET_PATH}"
}

# Install, reload, and enable the scheduler timer.
install_scheduler() {
  require_root
  require_command systemctl
  require_command cp
  require_command ln
  verify_source_files

  install_service_unit
  install_timer_unit
  install_logrotate_config
  install_cli_link

  systemctl daemon-reload
  systemctl enable --now "${TIMER_NAME}"

  printf 'Installed and enabled %s\n' "${TIMER_NAME}"
  printf 'Installed logrotate config %s\n' "${LOGROTATE_TARGET_PATH}"
  printf 'Installed CLI link %s -> %s/backupctl\n' "${CLI_LINK_PATH}" "${PROJECT_ROOT}"
  systemctl status "${TIMER_NAME}" --no-pager || true
}

# Stop, disable, and remove the scheduler timer and service.
remove_scheduler() {
  require_root
  require_command systemctl

  if systemctl list-unit-files | grep -q "^${TIMER_NAME}"; then
    systemctl disable --now "${TIMER_NAME}" || true
  fi

  rm -f -- "${SERVICE_TARGET_PATH}" "${TIMER_TARGET_PATH}"
  rm -f -- "${LOGROTATE_TARGET_PATH}"
  remove_cli_link
  systemctl daemon-reload
  systemctl reset-failed || true

  printf 'Removed %s, %s, %s, and %s\n' "${SERVICE_NAME}" "${TIMER_NAME}" "${LOGROTATE_NAME}" "${CLI_LINK_PATH}"
}

# Dispatch CLI arguments.
main() {
  local action="${1:-}"

  case "${action}" in
    -i)
      install_scheduler
      ;;
    -rm)
      remove_scheduler
      ;;
    -h|--help|"")
      print_usage
      ;;
    *)
      print_usage
      die "Unknown option: ${action}"
      ;;
  esac
}

main "$@"
