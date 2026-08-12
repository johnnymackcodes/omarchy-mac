#!/usr/bin/env bash
# QEMU VM construction and lifecycle.

vm_create_disk() {
  ensure_dirs

  if [[ -f "$DISK_IMG" ]]; then
    ok "Disk image exists: $DISK_IMG ($(human_bytes "$(stat -f%z "$DISK_IMG")") on disk)"
  else
    log "Creating $VM_DISK_SIZE qcow2 disk"
    qemu-img create -f qcow2 "$DISK_IMG" "$VM_DISK_SIZE" >/dev/null \
      || die "Could not create $DISK_IMG."
    ok "Created $DISK_IMG (sparse, grows as used)"
  fi

  # Each VM needs its own writable copy of the UEFI variable store, otherwise
  # boot entries have nowhere to persist.
  if [[ ! -f "$UEFI_VARS" ]]; then
    local share; share="$(qemu_share_dir)"
    cp "$share/edk2-i386-vars.fd" "$UEFI_VARS" || die "Could not seed UEFI varstore."
    ok "Seeded UEFI varstore"
  fi
}

# Populates the QEMU_ARGS array.
#   $1  boot source: "iso" attaches the installer media, "disk" does not
#   $2  display: "window" (Cocoa) or "headless" (VNC on localhost)
vm_build_args() {
  local boot_from="$1" display_mode="$2"
  local share; share="$(qemu_share_dir)"

  QEMU_ARGS=(
    -name "omarchy"
    -machine q35
    # No hardware virtualisation exists for x86_64 guests on Apple Silicon, so
    # this is pure binary translation. thread=multi spreads the translated
    # blocks across host cores; the large tb-size cuts re-translation.
    -accel tcg,thread=multi,tb-size=1024
    -cpu "${VM_CPU_MODEL:-max}"
    -smp "$VM_CPUS"
    -m "$VM_MEMORY"

    # Split UEFI: read-only firmware plus this VM's own variable store.
    -drive "if=pflash,format=raw,readonly=on,file=$share/edk2-x86_64-code.fd"
    -drive "if=pflash,format=raw,file=$UEFI_VARS"

    -drive "if=none,id=hd0,file=$DISK_IMG,format=qcow2,cache=writeback,discard=unmap"
    -device virtio-blk-pci,drive=hd0

    -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22"
    -device virtio-net-pci,netdev=net0

    # Arch generates a pacman keyring during install and will stall for a long
    # time on a starved entropy pool without this.
    -object rng-random,filename=/dev/urandom,id=rng0
    -device virtio-rng-pci,rng=rng0

    -device virtio-vga
    # An absolute pointing device, so the mouse is not captured by the window.
    -device qemu-xhci,id=xhci
    -device usb-tablet

    -rtc base=localtime,clock=host
    -pidfile "$PID_FILE"
    -monitor "unix:$MONITOR_SOCK,server,nowait"
  )

  if [[ "$boot_from" == "iso" ]]; then
    QEMU_ARGS+=(-cdrom "$ISO_FILE" -boot order=dc,menu=on)
  else
    QEMU_ARGS+=(-boot order=cd,menu=on)
  fi

  if [[ "${VM_AUDIO:-1}" == "1" ]]; then
    QEMU_ARGS+=(-audiodev coreaudio,id=snd0 -device intel-hda -device hda-duplex,audiodev=snd0)
  fi

  if [[ "$display_mode" == "headless" ]]; then
    QEMU_ARGS+=(-display none -vnc "127.0.0.1:${VNC_DISPLAY}")
  else
    QEMU_ARGS+=(-display cocoa)
  fi
}

vm_start() {
  local boot_from="$1" display_mode="$2"

  if vm_running; then
    die "VM is already running (pid $(vm_pid)). Use 'omarchy-vm stop' first."
  fi

  ensure_dirs
  rm -f "$MONITOR_SOCK" "$PID_FILE"

  vm_build_args "$boot_from" "$display_mode"

  log "Starting VM: ${VM_CPUS} vCPU, $((VM_MEMORY / 1024)) GB RAM, ${display_mode}"
  printf '%s\n' "--- $(date) ---" >>"$QEMU_LOG"

  # Cocoa needs a real GUI session and refuses to daemonize, so background it
  # here and let -pidfile record the pid for both modes.
  nohup qemu-system-x86_64 "${QEMU_ARGS[@]}" >>"$QEMU_LOG" 2>&1 &
  local shell_pid=$!

  # Give QEMU a moment to either come up or fail on a bad flag.
  local waited=0
  while (( waited < 50 )); do
    if ! kill -0 "$shell_pid" 2>/dev/null; then
      warn "QEMU exited immediately. Last lines of $QEMU_LOG:"
      tail -20 "$QEMU_LOG" >&2
      die "VM failed to start."
    fi
    [[ -S "$MONITOR_SOCK" ]] && break
    sleep 0.2
    waited=$((waited + 1))
  done

  ok "VM running (pid $(cat "$PID_FILE" 2>/dev/null || echo "$shell_pid"))"
  if [[ "$display_mode" == "headless" ]]; then
    info "VNC on 127.0.0.1:$((5900 + VNC_DISPLAY))"
    info "Connect with: open vnc://127.0.0.1:$((5900 + VNC_DISPLAY))"
  fi
  info "SSH forwarded on localhost:${SSH_PORT} once the guest is up"
  info "QEMU log: $QEMU_LOG"
}

# Ask the guest to shut down cleanly through the QEMU monitor, and only
# escalate to a kill if it ignores us.
vm_stop() {
  local pid
  pid="$(vm_pid)" || { ok "VM is not running"; return 0; }

  log "Sending ACPI power-down to the guest"
  if [[ -S "$MONITOR_SOCK" ]]; then
    printf 'system_powerdown\n' | nc -U "$MONITOR_SOCK" >/dev/null 2>&1 || true
  fi

  local waited=0
  while (( waited < 60 )); do
    kill -0 "$pid" 2>/dev/null || { ok "Guest shut down cleanly"; rm -f "$PID_FILE"; return 0; }
    sleep 1
    waited=$((waited + 1))
  done

  warn "Guest did not shut down within 60s, terminating QEMU"
  kill "$pid" 2>/dev/null || true
  sleep 2
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  rm -f "$PID_FILE"
  ok "VM stopped"
}

vm_status() {
  printf '%sOmarchy VM%s\n' "$C_BOLD" "$C_RESET"
  printf '  version    %s\n' "$OMARCHY_VERSION"
  printf '  state dir  %s\n' "$STATE_DIR"

  if vm_running; then
    printf '  status     %srunning%s (pid %s)\n' "$C_GREEN" "$C_RESET" "$(vm_pid)"
  else
    printf '  status     %sstopped%s\n' "$C_DIM" "$C_RESET"
  fi

  if [[ -f "$DISK_IMG" ]]; then
    printf '  disk       %s allocated of %s virtual\n' \
      "$(human_bytes "$(stat -f%z "$DISK_IMG")")" "$VM_DISK_SIZE"
  else
    printf '  disk       %snot created%s\n' "$C_DIM" "$C_RESET"
  fi

  if [[ -f "$ISO_FILE" ]]; then
    printf '  iso        %s\n' "$ISO_FILE"
  else
    printf '  iso        %snot downloaded%s\n' "$C_DIM" "$C_RESET"
  fi

  if [[ -f "$INSTALLED_MARKER" ]]; then
    printf '  install    %scomplete%s (%s)\n' "$C_GREEN" "$C_RESET" "$(cat "$INSTALLED_MARKER")"
  else
    printf '  install    %snot yet booted from disk%s, run: omarchy-vm install\n' "$C_YELLOW" "$C_RESET"
  fi

  printf '  resources  %s vCPU, %s MB RAM\n' "$VM_CPUS" "$VM_MEMORY"
  printf '  ssh        localhost:%s\n' "$SSH_PORT"
}
