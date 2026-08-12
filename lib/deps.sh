#!/usr/bin/env bash
# Host preflight and dependency installation.

# Refuse to run anywhere the rest of the tool would misbehave in confusing ways.
preflight_host() {
  [[ "$(uname -s)" == "Darwin" ]] || die "This installer targets macOS. Detected: $(uname -s)."

  local arch; arch="$(uname -m)"
  if [[ "$arch" != "arm64" ]]; then
    warn "Host is $arch, not Apple Silicon. On an x86_64 Mac you should install"
    warn "Omarchy natively or use HVF acceleration instead of this emulator."
  fi

  local free; free="$(free_gib "$STATE_DIR")"
  # 8 GB ISO plus a qcow2 that realistically reaches 40-60 GB once populated.
  if (( free < 70 )); then
    die "Need at least 70 GB free, found ${free} GB on the volume backing $STATE_DIR."
  fi
  ok "Host: macOS $(sw_vers -productVersion) on $arch, ${free} GB free"
}

install_deps() {
  command -v brew >/dev/null 2>&1 \
    || die "Homebrew is required. Install it from https://brew.sh and re-run."

  if command -v qemu-system-x86_64 >/dev/null 2>&1; then
    ok "QEMU $(qemu-system-x86_64 --version | head -1 | awk '{print $4}') already installed"
  else
    log "Installing QEMU (about 700 MB)"
    brew install qemu || die "brew install qemu failed."
    ok "QEMU installed"
  fi

  command -v qemu-img >/dev/null 2>&1 || die "qemu-img missing from the QEMU install."
}

# Confirm this QEMU build actually supports the flags vm.sh is going to pass,
# rather than failing halfway through a boot with an opaque error.
preflight_qemu() {
  local share; share="$(qemu_share_dir)" \
    || die "Could not locate QEMU's share directory."

  [[ -f "$share/edk2-x86_64-code.fd" ]] \
    || die "UEFI firmware edk2-x86_64-code.fd not found in $share."
  [[ -f "$share/edk2-i386-vars.fd" ]] \
    || die "UEFI varstore template edk2-i386-vars.fd not found in $share."
  ok "UEFI firmware found in $share"

  qemu-system-x86_64 -accel help 2>&1 | grep -qw tcg \
    || die "This QEMU build has no TCG accelerator, which is the only option on Apple Silicon."

  qemu-system-x86_64 -display help 2>&1 | grep -qw cocoa \
    || warn "No cocoa display backend. Windowed mode will not work; use --headless."

  # Homebrew's bottle is built without virglrenderer, so there is no GPU
  # passthrough. Say so once here instead of letting the user wonder why
  # Hyprland is slow.
  if ! qemu-system-x86_64 -device help 2>&1 | grep -q 'virtio-vga-gl'; then
    info "No virtio-vga-gl in this build: the guest renders in software (llvmpipe)."
  fi
}
