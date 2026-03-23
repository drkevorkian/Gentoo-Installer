# AGENTS.md

## Cursor Cloud specific instructions

### Overview

This repository contains a single Bash script (`gentoo_installer.sh`) — an automated **Gentoo Linux bare-metal installer**. It partitions two disks into a software RAID array, extracts a Stage3 tarball, and bootstraps a full Gentoo system (kernel, bootloader, services). It is **not** a typical application — it is an infrastructure provisioning tool.

### Development tooling

- **Lint:** `shellcheck gentoo_installer.sh` — static analysis for Bash scripts (installed via `apt-get install -y shellcheck`).
- **Syntax check:** `bash -n gentoo_installer.sh` — quick parse-time validation.
- There is no test framework, build system, or package manager in this repo.

### Running the script

**Do NOT run `gentoo_installer.sh` in a cloud agent VM.** The script destructively partitions and formats real block devices. It requires:
- Root privileges on a live Gentoo (or compatible) environment
- Two physical disks (`/dev/sda`, `/dev/sdb` by default)
- Explicit safety flags: `ARMED=YES WIPE_DISKS=YES CONFIRM_ERASE=ERASE-sda-sdb`

For development, validate changes with `bash -n` and `shellcheck` only.

### Shellcheck notes

- SC2317 ("unreachable") warnings on lines 325–363 are expected: the script intentionally redefines `ensure_md_present`, `ensure_target_mounted`, `ensure_stage3_present`, `ensure_chrootprep`, and `chroot_run` later in the file (lines 569–594). Shellcheck sees the first definitions as dead code. These are false positives.
- SC2016 on line 550 is intentional: single quotes prevent variable expansion so the expression evaluates inside the chroot, not the host shell.
- SC2034 warnings for `OPT_PKGS` and `PHASES` — these arrays are defined for documentation/future use.
