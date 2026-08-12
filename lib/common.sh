#!/usr/bin/env bash
# Shared config, logging and guards for omarchy-mac.

set -euo pipefail

# ---------------------------------------------------------------- paths

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_DIR

# All heavy artifacts (ISO, disk image, UEFI vars, runtime sockets) live
# outside the git repo so the checkout stays a few hundred KB.
STATE_DIR="${OMARCHY_MAC_STATE:-$HOME/.local/share/omarchy-mac}"
export STATE_DIR

ISO_DIR="$STATE_DIR/iso"
VM_DIR="$STATE_DIR/vm"
RUN_DIR="$STATE_DIR/run"
LOG_DIR="$STATE_DIR/log"

DISK_IMG="$VM_DIR/omarchy.qcow2"
UEFI_VARS="$VM_DIR/uefi-vars.fd"
INSTALLED_MARKER="$VM_DIR/.installed"
PID_FILE="$RUN_DIR/qemu.pid"
MONITOR_SOCK="$RUN_DIR/monitor.sock"
QEMU_LOG="$LOG_DIR/qemu.log"

# ---------------------------------------------------------------- defaults

# Omarchy publishes one ISO per release at a predictable URL.
OMARCHY_VERSION_DEFAULT="3.8.4"
# Byte length of the 3.8.4 ISO, used as a cheap truncation check.
OMARCHY_ISO_BYTES_DEFAULT="7957577728"

# Host is an Apple Silicon Mac, so x86_64 runs under TCG with no hardware
# virtualisation available. These defaults are tuned for a 10P/4E, 24 GB M4 Pro
# and are all overridable from omarchy.conf or the environment.
VM_CPUS_DEFAULT="6"
VM_MEMORY_DEFAULT="8192"
VM_DISK_SIZE_DEFAULT="120G"
SSH_PORT_DEFAULT="2222"
VNC_DISPLAY_DEFAULT="1"

# ---------------------------------------------------------------- config

# omarchy.conf in the repo root overrides the defaults above; the environment
# overrides omarchy.conf. Copy omarchy.conf.example to get started.
load_config() {
  if [[ -f "$REPO_DIR/omarchy.conf" ]]; then
    # shellcheck disable=SC1091
    source "$REPO_DIR/omarchy.conf"
  fi

  OMARCHY_VERSION="${OMARCHY_VERSION:-$OMARCHY_VERSION_DEFAULT}"
  OMARCHY_ISO_BYTES="${OMARCHY_ISO_BYTES:-$OMARCHY_ISO_BYTES_DEFAULT}"
  VM_CPUS="${VM_CPUS:-$VM_CPUS_DEFAULT}"
  VM_MEMORY="${VM_MEMORY:-$VM_MEMORY_DEFAULT}"
  VM_DISK_SIZE="${VM_DISK_SIZE:-$VM_DISK_SIZE_DEFAULT}"
  SSH_PORT="${SSH_PORT:-$SSH_PORT_DEFAULT}"
  VNC_DISPLAY="${VNC_DISPLAY:-$VNC_DISPLAY_DEFAULT}"

  ISO_URL="${OMARCHY_ISO_URL:-https://iso.omarchy.org/omarchy-${OMARCHY_VERSION}.iso}"
  ISO_FILE="$ISO_DIR/omarchy-${OMARCHY_VERSION}.iso"

  export OMARCHY_VERSION OMARCHY_ISO_BYTES VM_CPUS VM_MEMORY VM_DISK_SIZE
  export SSH_PORT VNC_DISPLAY ISO_URL ISO_FILE
}

# ---------------------------------------------------------------- output

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=""; C_DIM=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

log()    { printf '%s==>%s %s\n' "$C_BLUE$C_BOLD" "$C_RESET" "$*"; }
ok()     { printf '%s  ok%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
info()   { printf '%s     %s%s\n' "$C_DIM" "$*" "$C_RESET"; }
warn()   { printf '%swarn%s %s\n' "$C_YELLOW$C_BOLD" "$C_RESET" "$*" >&2; }
die()    { printf '%sfail%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$*" >&2; exit 1; }

confirm() {
  local prompt="$1" answer
  read -r -p "$prompt " answer
  [[ "$answer" == "yes" ]]
}

# ---------------------------------------------------------------- helpers

ensure_dirs() { mkdir -p "$ISO_DIR" "$VM_DIR" "$RUN_DIR" "$LOG_DIR"; }

# Free space in GiB on the volume backing a path (walks up to an existing dir).
free_gib() {
  local path="$1"
  while [[ ! -d "$path" ]]; do path="$(dirname "$path")"; done
  df -g "$path" | awk 'NR==2 {print $4}'
}

human_bytes() {
  awk -v b="$1" 'BEGIN {
    split("B KB MB GB TB", u, " "); i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf "%.1f %s", b, u[i]
  }'
}

qemu_share_dir() {
  local prefix
  prefix="$(brew --prefix qemu 2>/dev/null || true)"
  if [[ -n "$prefix" && -d "$prefix/share/qemu" ]]; then
    printf '%s\n' "$prefix/share/qemu"
    return 0
  fi
  # Fall back to walking up from the binary for non-Homebrew installs.
  local bin resolved
  bin="$(command -v qemu-system-x86_64 2>/dev/null)" || return 1
  resolved="$(cd "$(dirname "$bin")/../share/qemu" 2>/dev/null && pwd)" || return 1
  printf '%s\n' "$resolved"
}

vm_pid() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null)" || return 1
  [[ -n "$pid" ]] || return 1
  # A stale pidfile after a crash would otherwise report a dead VM as running.
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s\n' "$pid"
}

vm_running() { vm_pid >/dev/null 2>&1; }
