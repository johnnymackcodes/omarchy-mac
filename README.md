# omarchy-mac

Run [Omarchy](https://omarchy.org/) on an Apple Silicon Mac, from the command line.

```bash
git clone https://github.com/johnnymackcodes/omarchy-mac.git
cd omarchy-mac
./install
```

That checks the host, installs QEMU, downloads and verifies the 8 GB ISO, creates
a sparse 120 GB disk and boots Omarchy's guided installer. Re-running it is safe:
every step is idempotent and the download resumes.

## Read this before you start

Omarchy is x86_64 only, and your Mac is not. This runs the real, unmodified
Omarchy ISO through full CPU emulation. That is a deliberate tradeoff, and it is
worth understanding exactly which one.

**Why there is no faster option on this hardware:**

- **Bare metal is impossible.** Asahi Linux is the only project that boots Linux
  natively on Apple Silicon, and it does not support M3 or M4. Apple changed the
  boot path in the M4 generation, `m1n1` fails to run, and that work is on hold
  with no announced timeline. Dual booting and wiping macOS are both off the table.
- **A native ARM build does not exist.** Omarchy's package repo carries 184
  packages for `x86_64` and exactly one for `aarch64` (just the keyring). Their
  mirror 404s on every aarch64 path, and `install/preflight/guard.sh` aborts
  unless `uname -m` reports `x86_64`. Running it on Arch Linux ARM means
  maintaining a fork with a substituted package set.
- **So x86 emulation it is.** No hardware virtualisation exists for x86_64 guests
  on an ARM host, so QEMU translates every instruction. This is the same engine
  UTM wraps, driven directly so the whole thing scripts.

**What that feels like in practice:** SSH into the guest and the terminal is
genuinely usable. The Hyprland desktop renders through llvmpipe in software
because Homebrew's QEMU is built without `virglrenderer`, so there is no
`virtio-vga-gl` and no GPU acceleration at all. Animations stutter and Chromium
is painful. Run `./omarchy-vm tune` for the guest config that makes the desktop
bearable.

If you want to *live* in Omarchy rather than evaluate it, the honest answer is a
cheap x86 mini PC running it on bare metal, with this Mac as the client.

## Commands

```
./omarchy-vm doctor          Check host, QEMU build and UEFI firmware
./omarchy-vm iso             Download and verify the ISO
./omarchy-vm iso --latest    Is the pinned version still current?
./omarchy-vm install         Boot the installer media

./omarchy-vm start           Boot from disk in a window
./omarchy-vm start --headless   Boot with VNC instead of a window
./omarchy-vm stop            ACPI power-down, escalating to kill after 60s
./omarchy-vm restart
./omarchy-vm status          State, disk usage, ports

./omarchy-vm ssh yourname    SSH in on localhost:2222
./omarchy-vm vnc             Open the VNC console
./omarchy-vm log             Tail the QEMU log
./omarchy-vm monitor         QEMU monitor console

./omarchy-vm tune            Guest config for software rendering
./omarchy-vm destroy         Delete the disk (asks first)
./omarchy-vm destroy --all   Also delete the ISO
```

## Configuration

Copy `omarchy.conf.example` to `omarchy.conf`. Defaults are tuned for a 14-core
(10P/4E), 24 GB M4 Pro:

| Setting | Default | Notes |
|---|---|---|
| `VM_CPUS` | 6 | More vCPUs than performance cores costs more than it returns under TCG |
| `VM_MEMORY` | 8192 | MB |
| `VM_DISK_SIZE` | 120G | Sparse qcow2, grows only as the guest fills it |
| `VM_CPU_MODEL` | max | Everything TCG can emulate, the most compatible choice |
| `SSH_PORT` | 2222 | Forwarded to the guest's 22 |
| `OMARCHY_VERSION` | 3.8.4 | Pinned so upstream cannot change what you install |

Set `OMARCHY_USER` to your guest account and `./omarchy-vm ssh` needs no argument.

## Where things live

The checkout stays small. Everything heavy goes to
`~/.local/share/omarchy-mac`, overridable with `OMARCHY_MAC_STATE`:

```
iso/omarchy-3.8.4.iso          8.0 GB
iso/omarchy-3.8.4.iso.sha256   recorded digest
vm/omarchy.qcow2               grows toward 120 GB
vm/uefi-vars.fd                this VM's UEFI variables
run/qemu.pid, run/monitor.sock
log/qemu.log
```

Budget roughly 70 GB free to start and expect 40 to 60 GB of real usage once the
guest is populated.

## On ISO integrity

Omarchy publishes no checksum next to the ISO. `.sha256`, `.sha256sum`,
`SHA256SUMS` and `SHA256SUMS.txt` all return 404 as of 3.8.4, and there is no
signature. So the automatic checks here are what is actually available: the
download is matched against the server's `Content-Length`, and the SHA-256 of
what arrived is recorded to a sidecar and re-verified on later runs. That catches
truncation and silent substitution after the fact, not a compromised first
download. Set `OMARCHY_ISO_SHA256` to a digest you trust for real verification.

## What runs on your machine

`install` will: install the `qemu` Homebrew formula if missing, write to
`~/.local/share/omarchy-mac`, and download from `iso.omarchy.org`. It does not
touch your boot disk, partition table, or macOS install, and it needs no `sudo`.
`destroy` is the only destructive command and it requires typing `yes`.

## License

MIT.
