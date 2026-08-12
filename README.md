# omarchy-mac

Run [Omarchy](https://omarchy.org/) on an Apple Silicon Mac, from the command line.

```bash
curl -fsSL https://raw.githubusercontent.com/johnnymackcodes/omarchy-mac/main/bootstrap | bash
```

That checks the host, installs QEMU, downloads and verifies the 8 GB ISO, creates
a sparse 120 GB disk and boots Omarchy's guided installer. Re-running it is safe:
every step is idempotent and the download resumes.

The bootstrap picks its own location rather than cloning into whatever directory
you are standing in. It uses `~/Projects/omarchy-mac` or `~/src/omarchy-mac` if
either parent already exists, otherwise `~/omarchy-mac`. Override with
`OMARCHY_MAC_DIR`. On later runs it fast-forwards the existing checkout instead
of failing, skips the update if you have local edits, and refuses to touch the
path if something unrelated is sitting there.

```bash
# Put it somewhere specific
OMARCHY_MAC_DIR=~/vms/omarchy-mac bash -c "$(curl -fsSL https://raw.githubusercontent.com/johnnymackcodes/omarchy-mac/main/bootstrap)"

# Clone or update without running the installer
curl -fsSL https://raw.githubusercontent.com/johnnymackcodes/omarchy-mac/main/bootstrap | BOOTSTRAP_SYNC=1 bash
```

Or clone it yourself, which is identical from the second command onward:

```bash
git clone https://github.com/johnnymackcodes/omarchy-mac.git && cd omarchy-mac && ./install
```

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

## Measured: tuning does not save this

Boot-to-login of an x86_64 Alpine guest on an M4 Pro (10P/4E, 24 GB), QEMU 11.0.3:

| Config | Boot to login |
|---|---|
| `cpu=max smp=6` (default) | 10s |
| `cpu=Nehalem smp=6` | 13s |
| `cpu=qemu64 smp=6` | 9s |
| `cpu=Nehalem smp=4` | 12s |
| `cpu=Nehalem smp=2` | 12s |
| `cpu=max smp=10` | 10s |

Narrowing the CPU model to avoid TCG's software AVX2 emulation was the obvious
lever, and it does nothing. Neither does changing the vCPU count. Every config
lands within a few seconds of the others. The bottleneck is binary translation
itself, and no flag removes it.

If you are hitting multi-second freezes rather than uniform slowness, try
`VM_DISK_CACHE="unsafe"` for the install. That is the one setting targeting
stalls specifically, since it drops the guest's fsyncs instead of pushing them
through qcow2 onto APFS. Read the warning in `omarchy.conf.example` first.

For anything beyond evaluation, run Omarchy on x86 hardware.

## Starting over

Exiting the install script does not stop the VM. QEMU is backgrounded on purpose
so closing a terminal cannot kill your machine mid-install. Check what you have
before doing anything:

```bash
./omarchy-vm status
```

| Situation | What to run |
|---|---|
| Quit during the 8 GB download | `./install`, the transfer resumes |
| Status says `running` | `./omarchy-vm stop && ./install` |
| Guided installer went wrong | `./omarchy-vm destroy` then `./install` |
| You think the ISO is corrupt | `./omarchy-vm destroy --all` then `./install` |

`destroy` keeps the ISO, so starting over does not mean downloading 8 GB again.
Only `destroy --all` removes it.

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

`bootstrap` clones or fast-forwards the repo and hands off to `install`. It never
force-updates over local changes and never writes to a path holding something
else.

`install` will: install the `qemu` Homebrew formula if missing, write to
`~/.local/share/omarchy-mac`, and download from `iso.omarchy.org`. It does not
touch your boot disk, partition table, or macOS install, and it needs no `sudo`.
`destroy` is the only destructive command and it requires typing `yes`.

If you would rather read before you pipe, the bootstrap is 100 lines:

```bash
curl -fsSL https://raw.githubusercontent.com/johnnymackcodes/omarchy-mac/main/bootstrap | less
```

## License

MIT.
