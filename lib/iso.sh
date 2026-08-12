#!/usr/bin/env bash
# Omarchy ISO download and integrity checking.

# Upstream publishes no checksum file alongside the ISO (verified: .sha256,
# .sha256sum, SHA256SUMS and SHA256SUMS.txt all 404 as of 3.8.4). So the
# strongest automatic check available is the Content-Length, and we record the
# SHA-256 we actually got so later runs detect silent changes. Pin a known-good
# digest via OMARCHY_ISO_SHA256 to get real verification.
iso_remote_size() {
  curl -sIL --max-time 30 "$ISO_URL" \
    | awk 'tolower($1) == "content-length:" { gsub(/\r/, "", $2); print $2 }' \
    | tail -1
}

iso_download() {
  ensure_dirs

  local remote_size
  remote_size="$(iso_remote_size || true)"
  if [[ -z "$remote_size" ]]; then
    warn "Could not read the ISO size from $ISO_URL. Continuing without a size check."
  else
    info "Remote ISO: $(human_bytes "$remote_size") ($remote_size bytes)"
  fi

  if [[ -f "$ISO_FILE" ]]; then
    local local_size
    local_size="$(stat -f%z "$ISO_FILE")"
    if [[ -n "$remote_size" && "$local_size" == "$remote_size" ]]; then
      ok "ISO already downloaded: $ISO_FILE"
      iso_verify
      return 0
    fi
    warn "Existing ISO is $(human_bytes "$local_size"), expected $(human_bytes "${remote_size:-0}"). Resuming."
  fi

  log "Downloading Omarchy $OMARCHY_VERSION"
  info "$ISO_URL"
  info "This is about 8 GB. The transfer resumes if interrupted; re-run to continue."
  # -C - resumes a partial file, --retry rides out brief network drops.
  curl -fL --progress-bar -C - --retry 5 --retry-delay 3 \
    -o "$ISO_FILE" "$ISO_URL" \
    || die "ISO download failed. Re-run to resume from where it stopped."

  local got; got="$(stat -f%z "$ISO_FILE")"
  if [[ -n "$remote_size" && "$got" != "$remote_size" ]]; then
    die "Downloaded $(human_bytes "$got") but expected $(human_bytes "$remote_size"). Re-run to resume."
  fi
  ok "Downloaded $(human_bytes "$got")"

  iso_verify
}

iso_verify() {
  local sidecar="$ISO_FILE.sha256"
  local expected="${OMARCHY_ISO_SHA256:-}"

  # Hashing 8 GB takes a while, so only do it when there is something to
  # compare against or nothing recorded yet.
  if [[ -z "$expected" && -f "$sidecar" ]]; then
    expected="$(awk '{print $1}' "$sidecar")"
  fi

  if [[ -z "$expected" && ! -f "$sidecar" ]]; then
    log "Recording SHA-256 of the ISO (upstream publishes none)"
    local digest; digest="$(shasum -a 256 "$ISO_FILE" | awk '{print $1}')"
    printf '%s  %s\n' "$digest" "$(basename "$ISO_FILE")" >"$sidecar"
    ok "SHA-256 $digest"
    info "Recorded in $sidecar. Compare it against another download if you want"
    info "a second opinion, or pin it with OMARCHY_ISO_SHA256."
    return 0
  fi

  log "Verifying ISO against $expected"
  local actual; actual="$(shasum -a 256 "$ISO_FILE" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    die "SHA-256 mismatch. Expected $expected, got $actual. Delete $ISO_FILE and re-download."
  fi
  ok "SHA-256 matches"
}

# Report the version currently advertised on omarchy.org so the pinned default
# can be bumped deliberately rather than drifting.
iso_check_latest() {
  local latest
  latest="$(curl -sSL --max-time 30 https://omarchy.org/ \
    | grep -oE 'omarchy-[0-9]+\.[0-9]+\.[0-9]+\.iso' \
    | head -1 | sed -E 's/omarchy-(.*)\.iso/\1/')"

  if [[ -z "$latest" ]]; then
    warn "Could not determine the latest version from omarchy.org."
    return 1
  fi

  if [[ "$latest" == "$OMARCHY_VERSION" ]]; then
    ok "Pinned version $OMARCHY_VERSION is current"
  else
    warn "Pinned $OMARCHY_VERSION, but omarchy.org now offers $latest."
    info "Set OMARCHY_VERSION=$latest in omarchy.conf to move up."
  fi
}
