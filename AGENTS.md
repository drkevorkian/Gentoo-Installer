# AGENTS.md

## Cursor Cloud specific instructions

### Overview

This repository contains a single Bash script (`gentoo_installer.sh`) — an automated **Gentoo Linux bare-metal installer**. It partitions two disks into a software RAID array, extracts a Stage3 tarball, and bootstraps a full Gentoo system (kernel, bootloader, services). It is **not** a typical application — it is an infrastructure provisioning tool.

### Development tooling

- **Lint:** `shellcheck gentoo_installer.sh` — static analysis for Bash scripts (installed via `apt-get install -y shellcheck`).
- **Syntax check:** `bash -n gentoo_installer.sh` — quick parse-time validation.
- There is no test framework, build system, or package manager in this repo.

### Running the script in a QEMU VM

The script can be tested in a nested QEMU VM (TCG software emulation, no KVM required). Steps:

1. **Install QEMU:** `sudo apt-get install -y qemu-system-x86 qemu-utils`
2. **Create two virtual disks:** `qemu-img create -f qcow2 disk1.qcow2 20G && qemu-img create -f qcow2 disk2.qcow2 20G`
3. **Download Gentoo minimal install ISO** from `https://distfiles.gentoo.org/releases/amd64/autobuilds/current-install-amd64-minimal/`
4. **Extract kernel/initrd from ISO** (GRUB doesn't support serial console out of the box):
   ```
   7z e gentoo-minimal.iso boot/gentoo boot/gentoo.igz -oiso-extract
   ```
5. **Boot with serial console** (bypassing GRUB):
   ```
   qemu-system-x86_64 -m 4G -smp 4 -accel tcg,thread=multi -cpu max \
     -hda disk1.qcow2 -hdb disk2.qcow2 -cdrom gentoo-minimal.iso \
     -netdev user,id=net0 -device e1000,netdev=net0 \
     -kernel iso-extract/gentoo -initrd iso-extract/gentoo.igz \
     -append 'dokeymap nodhcp root=live:CDLABEL=Gentoo-amd64-20260322 rd.live.dir=/ rd.live.squashimg=image.squashfs cdroot console=ttyS0,115200' \
     -nographic -no-reboot
   ```
6. **Inside the VM**, configure networking (`dhcpcd <interface>`), transfer the script, then run:
   ```
   ARMED=YES WIPE_DISKS=YES CONFIRM_ERASE=ERASE-sda-sdb bash gentoo_installer.sh
   ```
7. Type `I_UNDERSTAND` when prompted.

**Caveats discovered during testing:**
- The network interface in the VM uses predictable names (e.g., `ens3`), not `eth0`.
- Pre-downloading the stage3 tarball and serving it via a local HTTP server (`python3 -m http.server`) avoids slow downloads through QEMU NAT. The VM can reach the host at `10.0.2.2`.
- TCG mode is ~50x slower than native. The disk/partition/RAID phases complete in minutes, but `emerge` (compilation) takes hours.
- The CDLABEL in the `-append` parameter must match the ISO version (check with `7z l` or the GRUB config inside the ISO).

### Script design notes (from maintainer)

- **Known timing races:** Some steps execute before the previous command fully completes (e.g., EFI partition not found, mount point missing). This is a known issue the maintainer is actively fixing — not a one-off environment glitch. The script's state/resume mechanism (`run_step` + state file) is designed to recover from these by re-running.
- **Intentional human checkpoint:** The `emerge` package list step (`install:packages_core`) deliberately requires a human to type **Yes** to confirm the package merge. This is the final interactive gate before long-running compilation begins. Do not try to fully automate past this point.
- **Active development:** The maintainer is actively fixing bugs (including with ChatGPT). Before filing issues or attempting fixes, check whether the latest `main` branch already addresses the problem.

### Issues observed during VM testing

1. **`ensure_target_mounted` (line 570):** Creates `/mnt/gentoo/boot/efi` directory *before* mounting the root filesystem on `/mnt/gentoo`. After the mount, the directory is hidden by the fresh ext4 filesystem. This is one of the known timing/ordering issues described above. Workaround: manually `mount /dev/md0 /mnt/gentoo && mkdir -p /mnt/gentoo/boot/efi && mount /dev/sda1 /mnt/gentoo/boot/efi` then re-run the script (it resumes from state).
2. **Profile selection in `chroot_bootstrap_portage`:** The awk filter selects any `amd64` + `systemd` profile but does not exclude `musl` profiles. On images where the musl/hardened/systemd profile ranks last, it may be selected, causing glibc-dependent packages to fail during `emerge`.

### Shellcheck notes

- SC2317 ("unreachable") warnings on lines 325–363 are expected: the script intentionally redefines `ensure_md_present`, `ensure_target_mounted`, `ensure_stage3_present`, `ensure_chrootprep`, and `chroot_run` later in the file (lines 569–594). Shellcheck sees the first definitions as dead code. These are false positives.
- SC2016 on line 550 is intentional: single quotes prevent variable expansion so the expression evaluates inside the chroot, not the host shell.
- SC2034 warnings for `OPT_PKGS` and `PHASES` — these arrays are defined for documentation/future use.
