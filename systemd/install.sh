#!/usr/bin/env bash
set -Eeuo pipefail

SYSTEMD_SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SYSTEMD_SOURCE_DIR}/.." && pwd)"
SYSTEMD_TARGET_DIR="/etc/systemd/system"
LOGROTATE_TARGET_DIR="/etc/logrotate.d"
SERVICE_NAME="restic-scheduler.service"
TIMER_NAME="restic-scheduler.timer"
LOGROTATE_NAME="restic-cli"
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
  [[ -x "${PROJECT_ROOT}/restic-cli" ]] || die "restic-cli is missing or not executable at ${PROJECT_ROOT}/restic-cli"
}

# Copy the service unit as-is.
install_service_unit() {
  cp -f -- "${SERVICE_SOURCE_PATH}" "${SERVICE_TARGET_PATH}"
}

# Configure service paths to match this checkout layout.
configure_service_paths() {
  local restic_cli_path
  restic_cli_path="$(readlink -f -- "${PROJECT_ROOT}/restic-cli")"

  sed -i '/^Environment=PROJECT_ROOT=/d' "${SERVICE_TARGET_PATH}"
  sed -i "s|^ExecStart=.*|ExecStart=${restic_cli_path} run-due|" "${SERVICE_TARGET_PATH}"

  if grep -q '^WorkingDirectory=' "${SERVICE_TARGET_PATH}"; then
    sed -i "s|^WorkingDirectory=.*|WorkingDirectory=${PROJECT_ROOT}|" "${SERVICE_TARGET_PATH}"
  else
    sed -i "/^Type=oneshot/a WorkingDirectory=${PROJECT_ROOT}" "${SERVICE_TARGET_PATH}"
  fi
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
  require_command sed
  require_command grep
  verify_source_files

  install_service_unit
  configure_service_paths
  install_timer_unit
  install_logrotate_config

  systemctl daemon-reload
  systemctl enable "${TIMER_NAME}" >/dev/null
  systemctl restart "${TIMER_NAME}"

  printf 'Installed, enabled, and restarted %s\n' "${TIMER_NAME}"
  printf 'Installed logrotate config %s\n' "${LOGROTATE_TARGET_PATH}"
  printf 'Configured service ExecStart=%s run-due and WorkingDirectory=%s\n' "$(readlink -f -- "${PROJECT_ROOT}/restic-cli")" "${PROJECT_ROOT}"
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
  systemctl daemon-reload
  systemctl reset-failed || true

  printf 'Removed %s, %s, and %s\n' "${SERVICE_NAME}" "${TIMER_NAME}" "${LOGROTATE_NAME}"
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
