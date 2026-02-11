#!/usr/bin/env bash
# /run/media/gentoo/UUI/scripts/gentoo_installer.sh
set -Eeuo pipefail
IFS=$'\n\t'

: "${ARMED:=NO}"
: "${WIPE_DISKS:=NO}"
: "${CONFIRM_ERASE:=}"

: "${STAGE3:=https://distfiles.gentoo.org/releases/amd64/autobuilds/20260201T164555Z/stage3-amd64-systemd-20260201T164555Z.tar.xz}"

: "${DISK_A:=/dev/sda}"
: "${DISK_B:=/dev/sdb}"
: "${TARGET:=/mnt/gentoo}"
: "${MD:=/dev/md0}"
: "${EFI_SIZE:=512M}"

: "${ROOT_RAID_LEVEL:=raid1}"  # raid1 or raid0
: "${ROOT_FS:=ext4}"
: "${SWAP_SIZE_GB:=16}"
: "${MAKE_JOBS_DEFAULT:=4}"
: "${NODE_JOBS:=2}"

# If profile ends up amd64/x32, nodejs is impossible. Default: abort.
: "${ALLOW_X32_NO_NODE:=NO}"   # YES => skip nodejs on x32 instead of failing

: "${LOG:=/root/gentoo_install.log}"
: "${STATE:=/root/gentoo_install.state}"
: "${STAGE3_CACHE_DIR:=/root/stage3-cache}"
: "${STAGE3_CACHE_FILE:=}"
: "${RO_CHECK_INTERVAL:=15}"

# Packages: keep node separate so we can handle x32 cleanly.
PKGS_CORE="sys-kernel/gentoo-kernel-bin sys-kernel/installkernel sys-fs/mdadm sys-kernel/dracut sys-boot/grub net-misc/openssh app-admin/sudo www-servers/apache dev-lang/php dev-db/mariadb dev-db/phpmyadmin net-ftp/vsftpd dev-lang/python"
PKGS_NODE="net-libs/nodejs"

OPT_PKGS=( "www-apps/webmin" "net-analyzer/netdata" )
PHASES=( time wipe partition mkfsraid mount stage3 chroot install passwd )

mkdir -p /root
touch "$LOG"
chmod 600 "$LOG" || true
exec > >(tee -a "$LOG") 2>&1

die(){ echo "FATAL: $*" >&2; exit 1; }

on_err(){
  local ec=$?
  local line=${BASH_LINENO[0]:-?}
  local cmd=${BASH_COMMAND:-?}
  echo
  echo "==================== INSTALLER CRASH ===================="
  echo "Exit code : $ec"
  echo "Line      : $line"
  echo "Command   : $cmd"
  echo "Log       : $LOG"
  echo "State     : $STATE"
  echo "========================================================="
  echo
  exit "$ec"
}
trap on_err ERR

phase(){ echo; echo "===== PHASE: $* ====="; }
need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"; }
need_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
disk_base(){ basename "$1"; }

require_inputs(){
  [[ "$ARMED" == "YES" ]] || die "Set ARMED=YES"
  [[ "$WIPE_DISKS" == "YES" ]] || die "Set WIPE_DISKS=YES"
  [[ -b "$DISK_A" ]] || die "Disk not found: $DISK_A"
  [[ -b "$DISK_B" ]] || die "Disk not found: $DISK_B"
  [[ "$DISK_A" != "$DISK_B" ]] || die "DISK_A and DISK_B must differ"
  [[ -n "$STAGE3" ]] || die "STAGE3 is empty"
  local expect="ERASE-$(disk_base "$DISK_A")-$(disk_base "$DISK_B")"
  [[ "$CONFIRM_ERASE" == "$expect" ]] || die "Set CONFIRM_ERASE=$expect"
}

init_state(){ touch "$STATE"; chmod 600 "$STATE" || true; }
step_done(){ grep -qE "^DONE[[:space:]]+$1([[:space:]]|$)" "$STATE"; }
mark_done(){ printf "DONE %s %s\n" "$1" "$(date -Is)" >> "$STATE"; }

run_step(){
  local s="$1"; shift
  if step_done "$s"; then echo "==> SKIP: $s"; return 0; fi
  echo "==> RUN : $s"
  "$@"
  echo "==> OK  : $s"
  mark_done "$s"
}

truncate_state_from_phase(){
  local target="$1"
  [[ -n "$target" ]] || die "internal: empty phase for truncate"
  [[ -f "$STATE" ]] || { echo "STATE: none -> no-op truncate"; return 0; }

  local tmp found=0
  tmp="$(mktemp)"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "$line" =~ ^DONE[[:space:]]+$target([[:space:]]|$) ]]; then found=1; break; fi
    echo "$line" >> "$tmp"
  done < "$STATE"

  if [[ "$found" -eq 1 ]]; then
    cp -a "$tmp" "$STATE"
    echo "STATE TRUNCATED: removed $target and later entries"
  else
    echo "STATE: phase '$target' not present -> no-op truncate"
  fi
  rm -f "$tmp" || true
}

RO_WATCHDOG_PID=""
ro_watchdog(){
  while true; do
    sleep "$RO_CHECK_INTERVAL" || true
    if mountpoint -q "$TARGET"; then
      local opts; opts="$(findmnt -n -o OPTIONS "$TARGET" 2>/dev/null || true)"
      if echo "$opts" | grep -qE '(^|,)ro(,|$)'; then
        echo; echo "!!! READ-ONLY MOUNT on $TARGET !!!"
        findmnt "$TARGET" || true
        dmesg -T | tail -n 120 || true
        exit 88
      fi
    fi
    if mountpoint -q "$TARGET/boot/efi"; then
      local eopts; eopts="$(findmnt -n -o OPTIONS "$TARGET/boot/efi" 2>/dev/null || true)"
      if echo "$eopts" | grep -qE '(^|,)ro(,|$)'; then
        echo; echo "!!! READ-ONLY MOUNT on $TARGET/boot/efi !!!"
        findmnt "$TARGET/boot/efi" || true
        dmesg -T | tail -n 120 || true
        exit 89
      fi
    fi
  done
}
start_watchdog(){ phase "watchdog:start"; ro_watchdog & RO_WATCHDOG_PID=$!; echo "Watchdog PID: $RO_WATCHDOG_PID"; }
stop_watchdog(){ phase "watchdog:stop"; kill "$RO_WATCHDOG_PID" 2>/dev/null || true; wait "$RO_WATCHDOG_PID" 2>/dev/null || true; }

refuse_dangerous_disks(){
  local root_src root_pk
  root_src="$(findmnt -n -o SOURCE / || true)"
  [[ -n "$root_src" ]] || die "Cannot determine current root device"
  root_pk="$(lsblk -no PKNAME "$root_src" 2>/dev/null || true)"
  if [[ -n "$root_pk" ]]; then
    [[ "/dev/$root_pk" != "$DISK_A" ]] || die "Refusing: DISK_A appears to back current /"
    [[ "/dev/$root_pk" != "$DISK_B" ]] || die "Refusing: DISK_B appears to back current /"
  fi

  local here_src here_pk
  here_src="$(findmnt -n -o SOURCE --target "$(pwd)" 2>/dev/null || true)"
  if [[ -n "$here_src" ]]; then
    here_pk="$(lsblk -no PKNAME "$here_src" 2>/dev/null || true)"
    if [[ -n "$here_pk" ]]; then
      [[ "/dev/$here_pk" != "$DISK_A" ]] || die "Refusing: running from DISK_A storage"
      [[ "/dev/$here_pk" != "$DISK_B" ]] || die "Refusing: running from DISK_B storage"
    fi
  fi
}

preflight_cleanup(){
  phase "preflight_cleanup"
  umount -R "$TARGET" 2>/dev/null || true

  while read -r tgt src; do
    [[ -n "$tgt" ]] || continue
    [[ "$tgt" != "/" ]] || continue
    umount -l "$tgt" 2>/dev/null || true
  done < <(findmnt -rn -o TARGET,SOURCE | awk -v a="$DISK_A" -v b="$DISK_B" '$2 ~ "^"a || $2 ~ "^"b || $2 ~ "^/dev/md" {print $1, $2}')

  for md in /dev/md*; do
    [[ -b "$md" ]] || continue
    if mdadm --detail "$md" 2>/dev/null | grep -Eq "$(printf '%s|%s' "$DISK_A" "$DISK_B")"; then
      mdadm --stop "$md" 2>/dev/null || true
      mdadm --remove "$md" 2>/dev/null || true
    fi
  done

  swapoff -a 2>/dev/null || true
  udevadm settle 2>/dev/null || true
}

confirm_destroy(){
  echo
  echo "THIS WILL DESTROY ALL DATA ON:"
  echo "  $DISK_A  ($(lsblk -dn -o MODEL,SERIAL,SIZE "$DISK_A" 2>/dev/null || true))"
  echo "  $DISK_B  ($(lsblk -dn -o MODEL,SERIAL,SIZE "$DISK_B" 2>/dev/null || true))"
  echo
  echo "Type: I_UNDERSTAND"
  read -r ans
  [[ "$ans" == "I_UNDERSTAND" ]] || die "Not confirmed"
}

stage3_cache_path(){
  mkdir -p "$STAGE3_CACHE_DIR"
  if [[ -n "${STAGE3_CACHE_FILE:-}" ]]; then echo "$STAGE3_CACHE_DIR/$STAGE3_CACHE_FILE"; return; fi
  echo "$STAGE3_CACHE_DIR/$(basename "$STAGE3")"
}

fetch_stage3_if_needed(){
  phase "stage3:cache"
  local dst; dst="$(stage3_cache_path)"
  if [[ -f "$dst" && -s "$dst" ]]; then echo "Stage3 cache exists: $dst"; return; fi
  echo "Downloading Stage3 -> $dst"
  wget -O "$dst" "$STAGE3"
}

step_time(){ phase "time"; echo "Time now: $(date -Is)"; }

step_wipe(){
  phase "wipe"
  refuse_dangerous_disks
  confirm_destroy
  preflight_cleanup
  for d in "$DISK_A" "$DISK_B"; do
    sgdisk --zap-all "$d" || true
    sgdisk -o "$d" || true
    wipefs -a "$d" || true
    partprobe "$d" 2>/dev/null || true
  done
  udevadm settle || true
}

step_partition(){
  phase "partition"
  for d in "$DISK_A" "$DISK_B"; do
    sgdisk -n1:0:+"$EFI_SIZE" -t1:EF00 -c1:EFI "$d"
    sgdisk -n2:0:0           -t2:FD00 -c2:RAIDROOT "$d"
    partprobe "$d" 2>/dev/null || true
  done
  udevadm settle || true
}

mdadm_supports(){ mdadm --help 2>&1 | grep -qE "$1"; }
mdadm_create_strategy(){
  if mdadm_supports '(^|[[:space:]])--yes($|[[:space:]])'; then echo "yes_flag_long"
  elif mdadm_supports '(^|[[:space:]])-y($|[[:space:]])'; then echo "yes_flag_short"
  else echo "yes_pipe"; fi
}

min_member_kib_from_sectors(){
  local a_sec b_sec min_sec
  a_sec="$(blockdev --getsz "${DISK_A}2")"
  b_sec="$(blockdev --getsz "${DISK_B}2")"
  if [[ "$a_sec" -le "$b_sec" ]]; then min_sec="$a_sec"; else min_sec="$b_sec"; fi
  echo $(( min_sec / 2 ))
}

wipe_member_signatures(){
  mdadm --stop "$MD" 2>/dev/null || true
  mdadm --remove "$MD" 2>/dev/null || true
  mdadm --zero-superblock --force "${DISK_A}2" "${DISK_B}2" 2>/dev/null || true
  wipefs -a "${DISK_A}2" "${DISK_B}2" || true
  udevadm settle || true
}

mdadm_create_attempt(){
  local level="$1" raid_devs="$2" bitmap_arg="$3" size_kib="$4"
  local strat; strat="$(mdadm_create_strategy)"
  echo "mdadm: attempt strategy=$strat level=$level size_kib=$size_kib"

  case "$strat" in
    yes_flag_long)
      mdadm --create "$MD" --metadata=1.2 --level="$level" --raid-devices="$raid_devs" \
        --size="$size_kib" ${bitmap_arg:+$bitmap_arg} --force --yes "${DISK_A}2" "${DISK_B}2"
      ;;
    yes_flag_short)
      mdadm --create "$MD" --metadata=1.2 --level="$level" --raid-devices="$raid_devs" \
        --size="$size_kib" ${bitmap_arg:+$bitmap_arg} --force -y "${DISK_A}2" "${DISK_B}2"
      ;;
    yes_pipe)
      set +o pipefail
      yes | mdadm --create "$MD" --metadata=1.2 --level="$level" --raid-devices="$raid_devs" \
        --size="$size_kib" ${bitmap_arg:+$bitmap_arg} --force "${DISK_A}2" "${DISK_B}2"
      local rc=$?
      set -o pipefail
      if [[ "$rc" -ne 0 && "$rc" -ne 141 ]]; then return "$rc"; fi
      [[ -b "$MD" ]] || return 1
      ;;
    *) return 2 ;;
  esac
}

mdadm_create_with_retry(){
  local level="$1" raid_devs="$2" bitmap_arg="$3"
  local base_kib; base_kib="$(min_member_kib_from_sectors)"
  local margins=(262144 524288 1048576 2097152 4194304 8388608)

  for m in "${margins[@]}"; do
    local size_kib=$(( base_kib - m ))
    [[ "$size_kib" -gt 0 ]] || die "Computed size_kib <= 0 (base_kib=$base_kib margin_kib=$m)"
    wipe_member_signatures
    if mdadm_create_attempt "$level" "$raid_devs" "$bitmap_arg" "$size_kib"; then
      echo "mdadm: create succeeded with size_kib=$size_kib"
      return 0
    fi
    echo "mdadm: create failed with size_kib=$size_kib (trying smaller)"
  done
  die "mdadm create failed after retries (base_kib=$base_kib)"
}

step_mkfsraid(){
  phase "mkfsraid"
  preflight_cleanup
  mkfs.vfat -F32 "${DISK_A}1"
  mkfs.vfat -F32 "${DISK_B}1"

  local level raid_devs bitmap_arg=""
  case "$ROOT_RAID_LEVEL" in
    raid1) level=1; raid_devs=2; bitmap_arg="--bitmap=internal" ;;
    raid0) level=0; raid_devs=2; bitmap_arg="" ;;
    *) die "ROOT_RAID_LEVEL must be raid1 or raid0" ;;
  esac

  mdadm_create_with_retry "$level" "$raid_devs" "$bitmap_arg"
  udevadm settle || true
  mkfs.ext4 -F "$MD"
}

# ------------------------- ENSURE (resume-safe) -----------------------------

ensure_md_present(){
  [[ -b "$MD" ]] && return 0
  echo "ensure: $MD missing -> attempting assemble"
  mdadm --assemble --scan || true
  [[ -b "$MD" ]] || die "RAID device missing: $MD"
}

ensure_target_mounted(){
  ensure_md_present
  mkdir -p "$TARGET" "$TARGET/boot/efi"
  mountpoint -q "$TARGET" || mount "$MD" "$TARGET"
  mountpoint -q "$TARGET/boot/efi" || mount "${DISK_A}1" "$TARGET/boot/efi"
}

ensure_stage3_present(){
  ensure_target_mounted
  [[ -x "$TARGET/bin/bash" ]] && return 0
  phase "ensure:stage3_repair"
  fetch_stage3_if_needed
  local tarball; tarball="$(stage3_cache_path)"
  cd "$TARGET"
  tar xpf "$tarball" --xattrs-include='*.*' --numeric-owner
  [[ -x "$TARGET/bin/bash" ]] || die "Stage3 repair failed: $TARGET/bin/bash missing"
}

ensure_chrootprep(){
  ensure_stage3_present
  mkdir -p "$TARGET"/{proc,sys,dev,run,etc,boot/efi,var/db/repos,etc/portage/repos.conf}
  cp -L /etc/resolv.conf "$TARGET/etc/resolv.conf" 2>/dev/null || true
  mountpoint -q "$TARGET/proc" || mount -t proc /proc "$TARGET/proc"
  mountpoint -q "$TARGET/sys"  || { mount --rbind /sys "$TARGET/sys"; mount --make-rslave "$TARGET/sys"; }
  mountpoint -q "$TARGET/dev"  || { mount --rbind /dev "$TARGET/dev"; mount --make-rslave "$TARGET/dev"; }
  mountpoint -q "$TARGET/run"  || { mount --rbind /run "$TARGET/run" 2>/dev/null || true; mount --make-rslave "$TARGET/run" 2>/dev/null || true; }
}

chroot_run(){
  local cmd="$1"
  ensure_chrootprep
  echo "CHROOT> $cmd"
  chroot "$TARGET" /bin/bash -lc "$cmd"
}

# ------------------------- Install steps ------------------------------------

chroot_bootstrap_portage(){
  phase "install:portage_bootstrap"
  chroot_run "
set -euo pipefail

mkdir -p /etc/portage/repos.conf /var/db/repos
cat > /etc/portage/repos.conf/gentoo.conf <<'EOF'
[gentoo]
location = /var/db/repos/gentoo
sync-type = webrsync
EOF

emerge-webrsync
test -d /var/db/repos/gentoo/profiles || { echo 'ERROR: gentoo repo missing profiles after webrsync'; exit 1; }

# Pick an amd64 systemd profile, EXCLUDING x32.
pid=''
if command -v eselect >/dev/null 2>&1; then
  pid=\$(
    eselect profile list | awk '
      /default\\/linux\\/amd64/ && /systemd/ && \$0 !~ /\\/x32\\// {
        gsub(/\\[/, \"\", \$1); gsub(/\\]/, \"\", \$1);
        pid=\$1
      }
      END { if (pid != \"\") { print pid; exit 0 } else { exit 1 } }'
  ) || true

  if [ -n \"\$pid\" ]; then
    eselect profile set \"\$pid\"
  fi
fi

# Verify we did NOT land on amd64/x32.
p=\$(readlink -f /etc/portage/make.profile 2>/dev/null || true)
if echo \"\$p\" | grep -q '/amd64/x32/'; then
  echo \"ERROR: selected x32 profile (\$p). Node/V8 is masked on x32.\"
  exit 2
fi

eselect profile show || true

# Ensure sync-type is real for ongoing syncs
cat > /etc/portage/repos.conf/gentoo.conf <<'EOF'
[gentoo]
location = /var/db/repos/gentoo
sync-type = rsync
sync-uri = rsync://rsync.gentoo.org/gentoo-portage
auto-sync = yes
EOF
"
}

chroot_create_swap_and_node_tuning(){
  phase "install:swap+node"
  chroot_run "
set -euo pipefail

SWAPFILE=/swapfile
if ! swapon --show=NAME 2>/dev/null | grep -qx \"\$SWAPFILE\"; then
  rm -f \"\$SWAPFILE\" || true
  SWAP_GB='${SWAP_SIZE_GB}'
  fallocate -l \${SWAP_GB}G \"\$SWAPFILE\" 2>/dev/null || dd if=/dev/zero of=\"\$SWAPFILE\" bs=1M count=\$((SWAP_GB*1024)) status=progress
  chmod 600 \"\$SWAPFILE\"
  mkswap \"\$SWAPFILE\"
  swapon \"\$SWAPFILE\"
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

mkdir -p /etc/portage/package.env /etc/portage/env
cat > /etc/portage/env/nodejs.conf <<EOF
MAKEOPTS='-j${NODE_JOBS}'
EOF
grep -q '^net-libs/nodejs ' /etc/portage/package.env/nodejs 2>/dev/null || echo 'net-libs/nodejs nodejs.conf' >> /etc/portage/package.env/nodejs
"
}

chroot_profile_guard_and_node_plan(){
  phase "install:profile_guard"
  chroot_run "
set -euo pipefail
p=\$(readlink -f /etc/portage/make.profile 2>/dev/null || true)
echo \"Active profile: \$p\"
if echo \"\$p\" | grep -q '/amd64/x32/'; then
  if [ '${ALLOW_X32_NO_NODE}' = 'YES' ]; then
    echo 'NOTICE: x32 profile detected; will skip nodejs.'
    exit 0
  fi
  echo 'ERROR: x32 profile detected; nodejs/v8 is masked on x32. Refusing to continue.'
  exit 3
fi
"
}

chroot_emerge_node_if_possible(){
  phase "install:node"
  if [[ "${ALLOW_X32_NO_NODE}" == "YES" ]]; then
    # still try; but if x32 guard lets it through, node probably works.
    :
  fi

  chroot_run "
set -euo pipefail

# Try to emerge node; if masked due to keyword only, allow ~amd64. If hard-masked, fail.
if emerge -p ${PKGS_NODE} >/dev/null 2>&1; then
  emerge --ask=n --autounmask-write=y --autounmask-continue=y -av ${PKGS_NODE}
  exit 0
fi

# If masked, attempt keywording (~amd64) automatically, but only if not x32.
mkdir -p /etc/portage/package.accept_keywords
echo '${PKGS_NODE} ~amd64' > /etc/portage/package.accept_keywords/nodejs

if emerge -p ${PKGS_NODE} >/dev/null 2>&1; then
  emerge --ask=n --autounmask-write=y --autounmask-continue=y -av ${PKGS_NODE}
  exit 0
fi

echo 'ERROR: nodejs still not mergeable after ~amd64 keyword attempt.'
emerge -p ${PKGS_NODE} || true
exit 1
"
}

step_install(){
  phase "install"
  chroot_run "source /etc/profile && env-update || true"
  chroot_bootstrap_portage

  phase "install:make.conf"
  chroot_run "
set -euo pipefail
cat > /etc/portage/make.conf <<EOF
COMMON_FLAGS='-O2 -pipe'
CFLAGS=\"\\\${COMMON_FLAGS}\"
CXXFLAGS=\"\\\${COMMON_FLAGS}\"
FCFLAGS=\"\\\${COMMON_FLAGS}\"
FFLAGS=\"\\\${COMMON_FLAGS}\"
MAKEOPTS='-j${MAKE_JOBS_DEFAULT}'
FEATURES='parallel-fetch'
ACCEPT_LICENSE='*'
EOF
"

  phase "install:php_fpm_use"
  chroot_run "mkdir -p /etc/portage/package.use; printf '%s\n' 'dev-lang/php fpm' > /etc/portage/package.use/php-fpm"

  chroot_create_swap_and_node_tuning
  chroot_profile_guard_and_node_plan

  phase "install:packages_core"
  chroot_run "emerge --ask=n --autounmask-write=y --autounmask-continue=y -av ${PKGS_CORE}"

  # Node is optional-but-requested: install unless x32 guard says skip
  if [[ "${ALLOW_X32_NO_NODE}" == "YES" ]]; then
    # only skip if actually x32; guard already printed notice
    if chroot_run "readlink -f /etc/portage/make.profile | grep -q '/amd64/x32/'"; then
      echo "NOTICE: skipping nodejs due to x32 profile + ALLOW_X32_NO_NODE=YES"
    else
      chroot_emerge_node_if_possible
    fi
  else
    chroot_emerge_node_if_possible
  fi

  phase "install:etc_update"
  chroot_run "yes -5 | etc-update || true"

  phase "install:mdadm_fstab"
  chroot_run "
set -euo pipefail
mdadm --detail --scan > /etc/mdadm.conf || true
EFI_UUID=\$(blkid -s UUID -o value ${DISK_A}1)
ROOT_UUID=\$(blkid -s UUID -o value ${MD})
cat > /etc/fstab <<EOF
UUID=\${ROOT_UUID}  /          ext4  noatime,errors=remount-ro  0 1
UUID=\${EFI_UUID}   /boot/efi   vfat  umask=0077               0 2
/swapfile           none       swap  sw                       0 0
EOF
"

  phase "install:initramfs"
  chroot_run 'KVER="$(ls -1 /lib/modules | sort -V | tail -n1)"; dracut --force --kver "$KVER" --add mdraid'

  phase "install:services"
  chroot_run "systemctl enable sshd apache2 mariadb vsftpd || true; systemctl list-unit-files | grep -q '^php-fpm\\.service' && systemctl enable php-fpm || true"

  phase "install:grub"
  chroot_run "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Gentoo --recheck; grub-mkconfig -o /boot/grub/grub.cfg"

  phase "install:esp_mirror"
  mkdir -p /mnt/espb
  mount "${DISK_B}1" /mnt/espb
  rsync -aHAX --delete "$TARGET/boot/efi/" /mnt/espb/
  umount /mnt/espb
  rmdir /mnt/espb || true
}

step_passwd(){ phase "passwd"; ensure_chrootprep; chroot "$TARGET" passwd; }

# Ensure (resume-safe)
ensure_md_present(){ [[ -b "$MD" ]] && return 0; mdadm --assemble --scan || true; [[ -b "$MD" ]] || die "RAID device missing: $MD"; }
ensure_target_mounted(){ ensure_md_present; mkdir -p "$TARGET" "$TARGET/boot/efi"; mountpoint -q "$TARGET" || mount "$MD" "$TARGET"; mountpoint -q "$TARGET/boot/efi" || mount "${DISK_A}1" "$TARGET/boot/efi"; }
ensure_stage3_present(){
  ensure_target_mounted
  [[ -x "$TARGET/bin/bash" ]] && return 0
  fetch_stage3_if_needed
  local tarball; tarball="$(stage3_cache_path)"
  cd "$TARGET"
  tar xpf "$tarball" --xattrs-include='*.*' --numeric-owner
  [[ -x "$TARGET/bin/bash" ]] || die "Stage3 repair failed: $TARGET/bin/bash missing"
}
ensure_chrootprep(){
  ensure_stage3_present
  mkdir -p "$TARGET"/{proc,sys,dev,run,etc,boot/efi,var/db/repos,etc/portage/repos.conf}
  cp -L /etc/resolv.conf "$TARGET/etc/resolv.conf" 2>/dev/null || true
  mountpoint -q "$TARGET/proc" || mount -t proc /proc "$TARGET/proc"
  mountpoint -q "$TARGET/sys"  || { mount --rbind /sys "$TARGET/sys"; mount --make-rslave "$TARGET/sys"; }
  mountpoint -q "$TARGET/dev"  || { mount --rbind /dev "$TARGET/dev"; mount --make-rslave "$TARGET/dev"; }
  mountpoint -q "$TARGET/run"  || { mount --rbind /run "$TARGET/run" 2>/dev/null || true; mount --make-rslave "$TARGET/run" 2>/dev/null || true; }
}
chroot_run(){
  local cmd="$1"
  ensure_chrootprep
  echo "CHROOT> $cmd"
  chroot "$TARGET" /bin/bash -lc "$cmd"
}

finish_msg(){
  echo
  echo "DONE."
  echo "Log  : $LOG"
  echo "State: $STATE"
  echo
  echo "Next:"
  echo "  umount -R $TARGET"
  echo "  reboot"
}

main(){
  local RESET=0 RESET_PHASE="" FORCE_MD=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reset) RESET=1; shift ;;
      --reset-phase) shift; [[ $# -gt 0 ]] || die "--reset-phase requires arg"; RESET_PHASE="$1"; shift ;;
      --force-md-recreate) FORCE_MD=1; shift ;;
      -h|--help) exit 0 ;;
      *) die "Unknown arg: $1" ;;
    esac
  done

  need_root
  need_cmd sgdisk; need_cmd mdadm; need_cmd wipefs; need_cmd partprobe; need_cmd udevadm
  need_cmd rsync; need_cmd tar; need_cmd mount; need_cmd umount; need_cmd findmnt; need_cmd lsblk
  need_cmd mkfs.vfat; need_cmd mkfs.ext4; need_cmd mktemp; need_cmd yes; need_cmd blockdev; need_cmd wget

  require_inputs
  init_state

  echo "Log  : $LOG"
  echo "State: $STATE"
  echo "Disks: $DISK_A $DISK_B  RAID: $MD  Target: $TARGET  RAID_LEVEL: $ROOT_RAID_LEVEL"
  echo "Stage3: $STAGE3"
  echo "mdadm strategy: $(mdadm_create_strategy)"
  echo

  if [[ "$RESET" -eq 1 ]]; then rm -f "$STATE"; init_state; fi
  if [[ "$FORCE_MD" -eq 1 ]]; then truncate_state_from_phase mkfsraid; fi
  if [[ -n "$RESET_PHASE" ]]; then truncate_state_from_phase "$RESET_PHASE"; fi

  start_watchdog

  run_step time      step_time
  run_step wipe      step_wipe
  run_step partition step_partition
  run_step mkfsraid  step_mkfsraid

  phase "ensure:mount";  ensure_target_mounted; step_done mount  || mark_done mount
  phase "ensure:stage3"; ensure_stage3_present; step_done stage3 || mark_done stage3
  phase "ensure:chroot"; ensure_chrootprep;     step_done chroot || mark_done chroot

  run_step install   step_install
  run_step passwd    step_passwd

  stop_watchdog
  finish_msg
}

main "$@"
