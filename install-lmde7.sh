#!/usr/bin/env bash
#
# install-lmde7.sh
#
# Fully autonomous, fault-tolerant, headless LMDE 7 "Gigi" installer.
# Runs from any RPM-based live USB (OpenMandriva tested; Fedora/Mageia compatible).
# Bootstraps from the official Debian Trixie LXC rootfs, then layers LMDE on top.
#
# USAGE:
#   sudo ./install-lmde7.sh [options]
#
# OPTIONS:
#   -d, --disk PATH         Target disk (default: auto-detected, prompted)
#   -H, --hostname NAME     System hostname (default: lmde-server)
#   -u, --user NAME         Initial sudo user (default: silva)
#   -t, --timezone TZ       e.g. America/Maceio (default: America/Maceio)
#   -l, --locale LOCALE     Primary locale (default: en_US.UTF-8)
#   -k, --keymap MAP        Console keymap (default: br)
#       --no-lmde           Stay pure Debian, skip Mint repo overlay
#       --no-firmware       Skip non-free firmware (smaller install)
#       --static IP/CIDR    Static IP (e.g. 192.168.1.50/24); default DHCP
#       --gateway IP        Gateway for --static
#       --dns "IP IP ..."   DNS servers for --static
#       --reboot            Reboot when finished
#   -y, --yes               Skip ALL confirmations (DANGEROUS)
#   -h, --help              Show this help
#
# ENVIRONMENT (alternative to flags):
#   ROOT_PASSWORD, USER_PASSWORD — if unset, prompted interactively
#
# EXAMPLE:
#   sudo ROOT_PASSWORD='foo' USER_PASSWORD='bar' \
#        ./install-lmde7.sh -d /dev/sda -H box01 -u silva -y --reboot
#

set -Eeuo pipefail
shopt -s nullglob

# ─────────────────────────────────────────────────────────────────────────────
# CONFIG DEFAULTS
# ─────────────────────────────────────────────────────────────────────────────

DISK=""
HOSTNAME_NEW="lmde-server"
USERNAME_NEW="silva"
TIMEZONE="America/Maceio"
LOCALE="en_US.UTF-8"
EXTRA_LOCALES="pt_BR.UTF-8"
KEYMAP="br"
LMDE_CODENAME="gigi"
DEBIAN_CODENAME="trixie"
LAYER_LMDE="yes"
INSTALL_FIRMWARE="yes"
NETWORK_MODE="dhcp"          # dhcp | static
STATIC_ADDR=""
STATIC_GW=""
STATIC_DNS="1.1.1.1 9.9.9.9"
ASSUME_YES="no"
DO_REBOOT="no"
EFI_SIZE="1G"
SWAP_SIZE="2G"
ROOT_LABEL="root"
EFI_LABEL="EFI"
SWAP_LABEL="swap"
ROOTFS_BASE="https://images.linuxcontainers.org/images/debian/${DEBIAN_CODENAME}/amd64/default"
WORKDIR="/tmp/lmde-install"
TARGET="/mnt/target"

ROOT_PASSWORD="${ROOT_PASSWORD:-}"
USER_PASSWORD="${USER_PASSWORD:-}"
ROOT_PWD_GENERATED="no"
USER_PWD_GENERATED="no"

# Runtime state
UEFI_MODE=""
PART_SUFFIX=""
CPU_VENDOR=""
TAR_BIN="tar"
PHASE1_MOUNTS=()

# ─────────────────────────────────────────────────────────────────────────────
# LOGGING & UI
# ─────────────────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'
  C_GREEN=$'\e[1;32m'; C_YELLOW=$'\e[1;33m'
  C_RED=$'\e[1;31m'; C_MAGENTA=$'\e[1;35m'; C_CYAN=$'\e[1;36m'
  C_BLUE=$'\e[1;34m'
else
  C_RESET=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_MAGENTA=''; C_CYAN=''; C_BLUE=''
fi

_ts() { printf '%(%H:%M:%S)T' -1; }
log()  { printf '%s[%s]%s %s\n'        "$C_CYAN"   "$(_ts)" "$C_RESET" "$*"; }
ok()   { printf '%s[%s] ✓%s %s\n'      "$C_GREEN"  "$(_ts)" "$C_RESET" "$*"; }
warn() { printf '%s[%s] ⚠%s %s\n'      "$C_YELLOW" "$(_ts)" "$C_RESET" "$*" >&2; }
err()  { printf '%s[%s] ✗%s %s\n'      "$C_RED"    "$(_ts)" "$C_RESET" "$*" >&2; }
step() { printf '\n%s═══ %s ═══%s\n'   "$C_MAGENTA" "$*" "$C_RESET"; }
ask()  { printf '%s[?]%s %s'           "$C_BLUE"   "$C_RESET" "$*"; }

die() { err "$*"; trap - ERR; exit 1; }

confirm() {
  local prompt="$1"
  [[ "$ASSUME_YES" == "yes" ]] && return 0
  local ans
  ask "$prompt [y/N] "
  read -r ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

prompt_secret() {
  # $1 = variable name, $2 = label
  local _name=$1 _label=$2 _v1 _v2
  while :; do
    ask "$_label: "
    read -rs _v1; echo
    [[ -z "$_v1" ]] && { warn "Empty not allowed"; continue; }
    ask "$_label (confirm): "
    read -rs _v2; echo
    [[ "$_v1" == "$_v2" ]] && { printf -v "$_name" '%s' "$_v1"; return 0; }
    warn "Mismatch, try again"
  done
}

retry() {
  # retry MAX_ATTEMPTS cmd ...
  local max=$1; shift
  local n=0 wait
  until "$@"; do
    n=$((n+1))
    if (( n >= max )); then
      err "Command failed after $max attempts: $*"
      return 1
    fi
    wait=$((n*3))
    warn "Attempt $n/$max failed; retrying in ${wait}s..."
    sleep "$wait"
  done
}

select_tar_impl() {
  # Prefer GNU tar if it is available as gtar; some live media ship bsdtar or
  # BusyBox tar as /bin/tar and those do not support every GNU long option.
  if command -v gtar >/dev/null 2>&1 && gtar --version 2>/dev/null | grep -qi 'GNU tar'; then
    TAR_BIN="gtar"
  else
    TAR_BIN="tar"
  fi
}

tar_supports_option() {
  # $1 = long option without an argument, for example --numeric-owner
  local opt=$1
  "$TAR_BIN" --help 2>&1 | grep -q -- "$opt"
}

tar_version_line() {
  "$TAR_BIN" --version 2>/dev/null | head -n 1 || printf '%s' "$TAR_BIN"
}

# ─────────────────────────────────────────────────────────────────────────────
# CLEANUP / ERROR HANDLING
# ─────────────────────────────────────────────────────────────────────────────

cleanup() {
  local rc=$?
  # Do not let best-effort cleanup commands trigger the global ERR trap and
  # obscure the original failure with duplicate/misleading line numbers.
  trap - ERR
  if (( rc != 0 )); then
    err "Install aborted (exit $rc). Attempting cleanup..."
  fi
  # ORDER MATTERS: shred secrets while filesystem is still mounted
  if [[ -f "$TARGET/root/install.conf" ]]; then
    shred -u "$TARGET/root/install.conf" 2>/dev/null || rm -f "$TARGET/root/install.conf"
  fi
  # Best-effort unmount in reverse order; ignore failures
  if mountpoint -q "$TARGET" 2>/dev/null; then
    log "Unmounting target tree..."
    # Unmount efivars first if bind-mounted
    umount -R "$TARGET/sys/firmware/efi/efivars" 2>/dev/null || true
    if (( ${#PHASE1_MOUNTS[@]} > 0 )); then
      # Iterate in reverse for safer teardown
      local i
      for (( i=${#PHASE1_MOUNTS[@]}-1; i>=0; i-- )); do
        umount -R "${PHASE1_MOUNTS[i]}" 2>/dev/null || umount -lR "${PHASE1_MOUNTS[i]}" 2>/dev/null || true
      done
    fi
    umount -R "$TARGET/boot/efi" 2>/dev/null || true
    umount -R "$TARGET" 2>/dev/null || umount -lR "$TARGET" 2>/dev/null || true
  fi
  swapoff -a 2>/dev/null || true
  return $rc
}

on_error() {
  local line=$1 cmd=$2
  err "Failed at line $line: $cmd"
}

trap 'on_error $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# ARG PARSING
# ─────────────────────────────────────────────────────────────────────────────

print_help() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while (( $# )); do
  case "$1" in
    -d|--disk)        DISK="$2"; shift 2 ;;
    -H|--hostname)    HOSTNAME_NEW="$2"; shift 2 ;;
    -u|--user)        USERNAME_NEW="$2"; shift 2 ;;
    -t|--timezone)    TIMEZONE="$2"; shift 2 ;;
    -l|--locale)      LOCALE="$2"; shift 2 ;;
    -k|--keymap)      KEYMAP="$2"; shift 2 ;;
    --no-lmde)        LAYER_LMDE="no"; shift ;;
    --no-firmware)    INSTALL_FIRMWARE="no"; shift ;;
    --static)         NETWORK_MODE="static"; STATIC_ADDR="$2"; shift 2 ;;
    --gateway)        STATIC_GW="$2"; shift 2 ;;
    --dns)            STATIC_DNS="$2"; shift 2 ;;
    --reboot)         DO_REBOOT="yes"; shift ;;
    -y|--yes)         ASSUME_YES="yes"; shift ;;
    -h|--help)        print_help; exit 0 ;;
    *)                die "Unknown option: $1 (use --help)" ;;
  esac
done

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1 — PRE-FLIGHT
# ─────────────────────────────────────────────────────────────────────────────

phase1_preflight() {
  step "Phase 1.1 — Pre-flight checks"

  [[ $EUID -eq 0 ]] || die "Run as root (sudo)."

  log "User: $(whoami)   Live env: $(uname -srm)"

  # UEFI detection
  if [[ -d /sys/firmware/efi/efivars ]]; then
    UEFI_MODE="yes"
    ok "Booted in UEFI mode"
  else
    UEFI_MODE="no"
    warn "Booted in BIOS/legacy mode — will install GRUB for BIOS"
  fi

  # CPU vendor for microcode
  if grep -qi 'GenuineIntel' /proc/cpuinfo; then
    CPU_VENDOR="intel"
  elif grep -qi 'AuthenticAMD' /proc/cpuinfo; then
    CPU_VENDOR="amd"
  else
    CPU_VENDOR="unknown"
  fi
  log "CPU vendor: $CPU_VENDOR"

  # Network
  log "Testing network..."
  if ! retry 3 ping -c 1 -W 3 deb.debian.org >/dev/null 2>&1; then
    die "No network. Configure it first (nmcli/wpa_supplicant) and re-run."
  fi
  ok "Network reachable"

  # Required tools
  local needed=(wget curl tar xz sgdisk mkfs.ext4 mkfs.vfat mkswap blkid lsblk partprobe chroot udevadm awk sed grep)
  local missing=()
  for t in "${needed[@]}"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done

  if (( ${#missing[@]} )); then
    warn "Missing tools: ${missing[*]}"
    log "Attempting to install via package manager..."
    install_missing_tools "${missing[@]}"
    # Re-check
    local still_missing=()
    for t in "${missing[@]}"; do
      command -v "$t" >/dev/null 2>&1 || still_missing+=("$t")
    done
    (( ${#still_missing[@]} == 0 )) || die "Still missing after install: ${still_missing[*]}"
  fi
  ok "All required tools present"

  select_tar_impl
  log "Using tar: $(tar_version_line)"

  # Passwords
  ROOT_PWD_GENERATED="no"
  USER_PWD_GENERATED="no"
  if [[ -z "$ROOT_PASSWORD" ]]; then
    if [[ "$ASSUME_YES" == "yes" ]]; then
      ROOT_PASSWORD=$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-16)
      ROOT_PWD_GENERATED="yes"
      warn "Generated random root password: $ROOT_PASSWORD  (will be reprinted at the end)"
    else
      prompt_secret ROOT_PASSWORD "Root password"
    fi
  fi
  if [[ -z "$USER_PASSWORD" ]]; then
    if [[ "$ASSUME_YES" == "yes" ]]; then
      USER_PASSWORD=$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-16)
      USER_PWD_GENERATED="yes"
      warn "Generated random user password: $USER_PASSWORD  (will be reprinted at the end)"
    else
      prompt_secret USER_PASSWORD "Password for user '$USERNAME_NEW'"
    fi
  fi

  # Working dir
  mkdir -p "$WORKDIR" "$TARGET"
  ok "Pre-flight passed"
}

install_missing_tools() {
  local pkgs=()
  for t in "$@"; do
    case "$t" in
      sgdisk)    pkgs+=(gptfdisk) ;;
      mkfs.vfat) pkgs+=(dosfstools) ;;
      mkfs.ext4) pkgs+=(e2fsprogs) ;;
      mkswap|blkid|lsblk|partprobe) pkgs+=(util-linux parted) ;;
      xz)        pkgs+=(xz) ;;
      tar)       pkgs+=(tar) ;;
      wget)      pkgs+=(wget) ;;
      curl)      pkgs+=(curl) ;;
      chroot|udevadm) pkgs+=(util-linux systemd) ;;
      *)         pkgs+=("$t") ;;
    esac
  done
  # Dedupe
  local uniq=()
  mapfile -t uniq < <(printf '%s\n' "${pkgs[@]}" | sort -u)
  (( ${#uniq[@]} > 0 )) || return 0
  if   command -v dnf    >/dev/null; then dnf install -y "${uniq[@]}" || true
  elif command -v zypper >/dev/null; then zypper -n install "${uniq[@]}" || true
  elif command -v apt    >/dev/null; then apt update && apt install -y "${uniq[@]}" || true
  elif command -v pacman >/dev/null; then pacman -Sy --noconfirm "${uniq[@]}" || true
  elif command -v urpmi  >/dev/null; then urpmi --auto "${uniq[@]}" || true
  else die "No supported package manager found"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1.2 — TARGET DETECTION & CONFIRMATION
# ─────────────────────────────────────────────────────────────────────────────

phase1_target() {
  step "Phase 1.2 — Target disk selection"

  if [[ -z "$DISK" ]]; then
    log "Available block devices:"
    lsblk -d -o NAME,SIZE,TYPE,MODEL,SERIAL | grep -v 'loop\|sr0' || true
    echo
    ask "Enter target disk (e.g. /dev/sda or /dev/nvme0n1): "
    read -r DISK
  fi

  [[ -b "$DISK" ]] || die "Not a block device: $DISK"

  # Detect partition suffix (nvme/mmcblk need 'p')
  if [[ "$DISK" =~ (nvme|mmcblk|loop) ]]; then
    PART_SUFFIX="p"
  else
    PART_SUFFIX=""
  fi

  # SAFETY: refuse if ANY partition on this disk is currently mounted.
  # This works for overlay-based live systems too (where findmnt / lies).
  local mounted_parts
  mounted_parts=$(awk -v d="${DISK}" '
    {
      src = $1
      # match /dev/sdaN or /dev/nvme0n1pN
      if (src ~ "^"d"p?[0-9]+$") print src
    }
  ' /proc/mounts | sort -u)
  if [[ -n "$mounted_parts" ]]; then
    err "$DISK has currently mounted partitions:"
    while IFS= read -r p; do err "    $p -> $(awk -v s="$p" '$1==s{print $2; exit}' /proc/mounts)"; done <<<"$mounted_parts"
    die "Refusing to wipe a disk with active mounts. If this is your live USB, pick a different target."
  fi

  echo
  warn "════════════════════════════════════════════════════════════"
  warn "About to ERASE $DISK — ALL DATA WILL BE LOST"
  warn "════════════════════════════════════════════════════════════"
  lsblk "$DISK"
  echo
  confirm "Proceed with destructive install on $DISK?" || die "Aborted by user"
  ok "Target confirmed: $DISK (partition suffix: '${PART_SUFFIX}')"
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1.3 — PARTITION, FORMAT, MOUNT
# ─────────────────────────────────────────────────────────────────────────────

phase1_partition() {
  step "Phase 1.3 — Partitioning"

  # Make sure nothing is mounted from this disk
  for mp in $(awk -v d="$DISK" '$1 ~ d {print $2}' /proc/mounts); do
    log "Unmounting stale mount: $mp"
    umount -R "$mp" 2>/dev/null || true
  done
  swapoff -a 2>/dev/null || true

  log "Zapping existing partition tables on $DISK..."
  sgdisk --zap-all "$DISK" >/dev/null
  wipefs -a "$DISK" >/dev/null 2>&1 || true

  if [[ "$UEFI_MODE" == "yes" ]]; then
    log "Creating GPT layout: EFI(${EFI_SIZE}) + swap(${SWAP_SIZE}) + root(rest)"
    sgdisk -n 1:0:+"$EFI_SIZE"  -t 1:ef00 -c 1:"$EFI_LABEL"  "$DISK" >/dev/null
    sgdisk -n 2:0:+"$SWAP_SIZE" -t 2:8200 -c 2:"$SWAP_LABEL" "$DISK" >/dev/null
    sgdisk -n 3:0:0             -t 3:8300 -c 3:"$ROOT_LABEL" "$DISK" >/dev/null
  else
    log "Creating GPT layout (BIOS boot): bios(1M) + swap(${SWAP_SIZE}) + root(rest)"
    sgdisk -n 1:0:+1M           -t 1:ef02 -c 1:"BIOSboot"    "$DISK" >/dev/null
    sgdisk -n 2:0:+"$SWAP_SIZE" -t 2:8200 -c 2:"$SWAP_LABEL" "$DISK" >/dev/null
    sgdisk -n 3:0:0             -t 3:8300 -c 3:"$ROOT_LABEL" "$DISK" >/dev/null
  fi

  partprobe "$DISK"
  udevadm settle
  sleep 1
  ok "Partition table written"
  lsblk "$DISK"
}

phase1_format() {
  step "Phase 1.4 — Filesystems"

  local p1="${DISK}${PART_SUFFIX}1"
  local p2="${DISK}${PART_SUFFIX}2"
  local p3="${DISK}${PART_SUFFIX}3"

  [[ -b "$p2" && -b "$p3" ]] || die "Partitions did not appear: expected $p2, $p3"

  if [[ "$UEFI_MODE" == "yes" ]]; then
    log "mkfs.vfat -F32 $p1"
    mkfs.vfat -F32 -n "$EFI_LABEL" "$p1" >/dev/null
  fi

  log "mkswap $p2"
  mkswap -L "$SWAP_LABEL" "$p2" >/dev/null

  log "mkfs.ext4 $p3"
  mkfs.ext4 -F -L "$ROOT_LABEL" "$p3" >/dev/null

  ok "Filesystems created"
}

phase1_mount() {
  step "Phase 1.5 — Mounting target"

  local p1="${DISK}${PART_SUFFIX}1"
  local p2="${DISK}${PART_SUFFIX}2"
  local p3="${DISK}${PART_SUFFIX}3"

  mount "$p3" "$TARGET"
  PHASE1_MOUNTS+=("$TARGET")
  if [[ "$UEFI_MODE" == "yes" ]]; then
    mkdir -p "$TARGET/boot/efi"
    mount "$p1" "$TARGET/boot/efi"
  fi
  swapon "$p2"

  findmnt "$TARGET"
  ok "Target mounted at $TARGET"
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1.6 — DOWNLOAD + VERIFY + EXTRACT ROOTFS
# ─────────────────────────────────────────────────────────────────────────────

phase1_fetch_rootfs() {
  step "Phase 1.6 — Fetching Debian $DEBIAN_CODENAME rootfs"

  log "Resolving latest build at $ROOTFS_BASE/"
  local latest
  latest=$(retry 5 _fetch_latest_build) || die "Could not determine latest rootfs build"
  log "Latest build: $latest"

  local url="$ROOTFS_BASE/$latest/rootfs.tar.xz"
  local sums="$ROOTFS_BASE/$latest/SHA256SUMS"

  cd "$WORKDIR"
  log "Downloading rootfs.tar.xz..."
  retry 3 wget -q --show-progress -c "$url" -O rootfs.tar.xz || die "Rootfs download failed"

  log "Downloading SHA256SUMS..."
  retry 3 wget -q -c "$sums" -O SHA256SUMS || die "Checksum download failed"

  log "Verifying SHA256..."
  if grep 'rootfs.tar.xz' SHA256SUMS | sha256sum -c -; then
    ok "Checksum OK"
  else
    die "Checksum FAILED — refusing to extract. Delete $WORKDIR/rootfs.tar.xz and retry."
  fi
}

_fetch_latest_build() {
  curl -fsSL "$ROOTFS_BASE/" \
    | grep -oE '[0-9]{8}_[0-9]{2}:[0-9]{2}' \
    | sort -u | tail -1 | grep .   # grep . fails if empty
}

phase1_extract() {
  step "Phase 1.7 — Extracting rootfs to $TARGET"

  local tar_opts=()

  # Preserve ownership and extended attributes when the host tar supports it.
  # GNU tar supports --xattrs-include='*', but bsdtar/BusyBox-style tar builds
  # often do not. Falling back is safe for this Debian/LXC rootfs extraction and
  # avoids aborting on live media with a non-GNU tar implementation.
  if tar_supports_option '--numeric-owner'; then
    tar_opts+=(--numeric-owner)
  else
    warn "$TAR_BIN does not support --numeric-owner; extracting with default owner handling"
  fi

  if tar_supports_option '--xattrs'; then
    tar_opts+=(--xattrs)
    if tar_supports_option '--xattrs-include'; then
      tar_opts+=(--xattrs-include='*')
    else
      warn "$TAR_BIN supports --xattrs but not --xattrs-include='*'; continuing with --xattrs only"
    fi
  else
    warn "$TAR_BIN does not support --xattrs; continuing without extended-attribute restore"
  fi

  log "$TAR_BIN -xpf rootfs.tar.xz -> $TARGET (this can take a minute)"
  "$TAR_BIN" -xpf "$WORKDIR/rootfs.tar.xz" -C "$TARGET" "${tar_opts[@]}"
  sync

  [[ -x "$TARGET/usr/bin/bash" ]] || die "Extract failed — /usr/bin/bash missing"
  ok "Rootfs extracted ($(du -sh "$TARGET" | awk '{print $1}'))"
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1.8 — PREPARE CHROOT (bind mounts, write conf + phase2)
# ─────────────────────────────────────────────────────────────────────────────

phase1_chroot_prep() {
  step "Phase 1.8 — Preparing chroot environment"

  log "Bind-mounting kernel filesystems..."
  for d in dev dev/pts proc sys run; do
    mkdir -p "$TARGET/$d"
    mount --rbind "/$d"  "$TARGET/$d"
    mount --make-rslave  "$TARGET/$d"
    PHASE1_MOUNTS+=("$TARGET/$d")
  done

  if [[ "$UEFI_MODE" == "yes" && -d /sys/firmware/efi/efivars ]]; then
    mount --bind /sys/firmware/efi/efivars "$TARGET/sys/firmware/efi/efivars" 2>/dev/null || \
      warn "Could not bind efivars (grub-install may fail to write NVRAM)"
  fi

  log "Setting up resolv.conf in chroot..."
  # The LXC rootfs may ship /etc/resolv.conf as a (broken) symlink to /run/...
  # Remove it first, then write a real file we know works during install.
  rm -f "$TARGET/etc/resolv.conf"
  if [[ -e /etc/resolv.conf ]]; then
    cp -L /etc/resolv.conf "$TARGET/etc/resolv.conf"
  else
    printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' > "$TARGET/etc/resolv.conf"
  fi
  # Phase 2 will replace this with a systemd-resolved symlink at the end.

  # Compute UUIDs now, while still outside
  local p1="${DISK}${PART_SUFFIX}1"
  local p2="${DISK}${PART_SUFFIX}2"
  local p3="${DISK}${PART_SUFFIX}3"
  local uuid_root uuid_swap uuid_efi=""
  uuid_root=$(blkid -s UUID -o value "$p3")
  uuid_swap=$(blkid -s UUID -o value "$p2")
  [[ "$UEFI_MODE" == "yes" ]] && uuid_efi=$(blkid -s UUID -o value "$p1")

  log "Writing install config into chroot..."
  install -d -m 700 "$TARGET/root"
  cat >"$TARGET/root/install.conf" <<EOF
# Generated by install-lmde7.sh — deleted after phase 2 completes
HOSTNAME_NEW='$HOSTNAME_NEW'
USERNAME_NEW='$USERNAME_NEW'
TIMEZONE='$TIMEZONE'
LOCALE='$LOCALE'
EXTRA_LOCALES='$EXTRA_LOCALES'
KEYMAP='$KEYMAP'
LMDE_CODENAME='$LMDE_CODENAME'
DEBIAN_CODENAME='$DEBIAN_CODENAME'
LAYER_LMDE='$LAYER_LMDE'
INSTALL_FIRMWARE='$INSTALL_FIRMWARE'
NETWORK_MODE='$NETWORK_MODE'
STATIC_ADDR='$STATIC_ADDR'
STATIC_GW='$STATIC_GW'
STATIC_DNS='$STATIC_DNS'
DISK='$DISK'
UEFI_MODE='$UEFI_MODE'
CPU_VENDOR='$CPU_VENDOR'
UUID_ROOT='$uuid_root'
UUID_SWAP='$uuid_swap'
UUID_EFI='$uuid_efi'
ROOT_PASSWORD=$(printf '%q' "$ROOT_PASSWORD")
USER_PASSWORD=$(printf '%q' "$USER_PASSWORD")
EOF
  chmod 600 "$TARGET/root/install.conf"

  log "Writing phase 2 script..."
  write_phase2_script "$TARGET/root/phase2.sh"
  chmod +x "$TARGET/root/phase2.sh"
  ok "Chroot ready"
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2 SCRIPT — embedded as a heredoc, executed inside the chroot
# ─────────────────────────────────────────────────────────────────────────────

write_phase2_script() {
  local out=$1
  cat >"$out" <<'PHASE2_EOF'
#!/usr/bin/env bash
# phase2.sh — runs inside the new system's chroot
set -Eeuo pipefail

C_RESET=$'\e[0m' C_GREEN=$'\e[1;32m' C_YELLOW=$'\e[1;33m'
C_RED=$'\e[1;31m' C_CYAN=$'\e[1;36m' C_MAGENTA=$'\e[1;35m'
_ts() { printf '%(%H:%M:%S)T' -1; }
log()  { printf '%s[%s]%s %s\n'      "$C_CYAN"    "$(_ts)" "$C_RESET" "$*"; }
ok()   { printf '%s[%s] ✓%s %s\n'    "$C_GREEN"   "$(_ts)" "$C_RESET" "$*"; }
warn() { printf '%s[%s] ⚠%s %s\n'    "$C_YELLOW"  "$(_ts)" "$C_RESET" "$*" >&2; }
err()  { printf '%s[%s] ✗%s %s\n'    "$C_RED"     "$(_ts)" "$C_RESET" "$*" >&2; }
step() { printf '\n%s── %s ──%s\n'   "$C_MAGENTA" "$*" "$C_RESET"; }
die()  { err "$*"; exit 1; }

trap 'err "Phase 2 failed at line $LINENO: $BASH_COMMAND"' ERR

# shellcheck disable=SC1091
source /root/install.conf

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

retry_apt() {
  local n=0
  until "$@"; do
    n=$((n+1))
    if (( n >= 4 )); then
      err "apt command failed after 4 attempts: $*"
      return 1
    fi
    warn "apt command failed; retry $n/3 in $((n*3))s..."
    sleep $((n*3))
  done
}

# ── Section 1: Clean up LXC container artifacts ──────────────────────────────
step "Cleaning container-isms"
# Some minimal/LXC rootfs builds omit legacy config directories entirely.
# Create them before truncating/removing files so cleanup is idempotent.
mkdir -p /etc/network /etc/systemd/network
: > /etc/network/interfaces
rm -f /etc/systemd/network/*.network /etc/systemd/network/*.link 2>/dev/null || true
rm -f /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true
systemd-machine-id-setup
rm -f /etc/systemd/system/console-getty.service.d/override.conf 2>/dev/null || true
rm -rf /etc/systemd/system/getty.target.wants/console-getty.service 2>/dev/null || true
# LXC tarball sometimes ships an empty /etc/resolv.conf symlink — fix
[[ -L /etc/resolv.conf && ! -e /etc/resolv.conf ]] && rm -f /etc/resolv.conf
[[ ! -e /etc/resolv.conf ]] && cp -L /proc/self/root/etc/resolv.conf /etc/resolv.conf 2>/dev/null || true
ok "Container artifacts cleaned"

# ── Section 2: APT sources (Debian + optionally LMDE) ────────────────────────
step "Configuring APT sources"
cat >/etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian               ${DEBIAN_CODENAME}         main contrib non-free non-free-firmware
deb http://deb.debian.org/debian               ${DEBIAN_CODENAME}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${DEBIAN_CODENAME}-security main contrib non-free non-free-firmware
EOF

if [[ "$LAYER_LMDE" == "yes" ]]; then
  cat >/etc/apt/sources.list.d/official-package-repositories.list <<EOF
deb http://packages.linuxmint.com ${LMDE_CODENAME} main upstream import backport
EOF
  log "Initial apt update (expect one NO_PUBKEY warning for Mint)..."
  retry_apt apt-get update -o Acquire::AllowInsecureRepositories=true \
                          -o Acquire::AllowDowngradeToInsecureRepositories=true || true
  log "Installing linuxmint-keyring from Debian..."
  retry_apt apt-get install -y --no-install-recommends linuxmint-keyring
fi

log "Final apt update..."
retry_apt apt-get update
ok "APT sources configured"

# ── Section 3: Install kernel, firmware, bootloader, base server stack ──────
step "Installing base system"
BASE_PKGS=(
  linux-image-amd64
  systemd-sysv systemd-resolved
  ifupdown iproute2 iputils-ping
  ca-certificates gnupg
  wget curl less nano vim-nox
  sudo openssh-server
  locales console-setup keyboard-configuration
  bash-completion htop rsync git
  cron logrotate
)

if [[ "$INSTALL_FIRMWARE" == "yes" ]]; then
  BASE_PKGS+=(firmware-linux firmware-misc-nonfree firmware-iwlwifi firmware-realtek)
fi

if [[ "$UEFI_MODE" == "yes" ]]; then
  BASE_PKGS+=(grub-efi-amd64 efibootmgr os-prober)
else
  BASE_PKGS+=(grub-pc os-prober)
fi

case "$CPU_VENDOR" in
  intel) BASE_PKGS+=(intel-microcode) ;;
  amd)   BASE_PKGS+=(amd64-microcode) ;;
esac

retry_apt apt-get install -y --no-install-recommends "${BASE_PKGS[@]}"
ok "Base system installed"

# ── Section 4: LMDE identity packages (no GUI) ───────────────────────────────
if [[ "$LAYER_LMDE" == "yes" ]]; then
  step "Layering LMDE identity"
  retry_apt apt-get install -y --no-install-recommends \
    mint-common mint-mirrors mintsystem mintupdate-cli || \
    warn "Some mint-* packages unavailable; system will still work"
  ok "LMDE layer applied"
fi

# ── Section 5: fstab ─────────────────────────────────────────────────────────
step "Writing /etc/fstab"
{
  echo "# Generated by install-lmde7.sh"
  echo "UUID=$UUID_ROOT  /          ext4  defaults,noatime  0  1"
  [[ -n "$UUID_EFI"  ]] && echo "UUID=$UUID_EFI   /boot/efi  vfat  umask=0077        0  1"
  echo "UUID=$UUID_SWAP  none       swap  sw                0  0"
} > /etc/fstab
cat /etc/fstab
ok "fstab written"

# ── Section 6: Hostname, hosts, locale, timezone, keyboard ───────────────────
step "Hostname / locale / timezone / keyboard"
echo "$HOSTNAME_NEW" > /etc/hostname
cat >/etc/hosts <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME_NEW
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

# Locales
for L in "$LOCALE" $EXTRA_LOCALES; do
  sed -i "s|^# *\(${L}\)|\1|" /etc/locale.gen || true
done
locale-gen
echo "LANG=$LOCALE" > /etc/default/locale

# Timezone
if [[ -e "/usr/share/zoneinfo/$TIMEZONE" ]]; then
  ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  echo "$TIMEZONE" > /etc/timezone
  dpkg-reconfigure -f noninteractive tzdata 2>/dev/null || true
else
  warn "Timezone '$TIMEZONE' not found; leaving default UTC"
fi

# Keyboard
sed -i "s/^XKBLAYOUT=.*/XKBLAYOUT=\"$KEYMAP\"/" /etc/default/keyboard 2>/dev/null || true
ok "Identity configured"

# ── Section 7: Passwords + sudo user ─────────────────────────────────────────
step "Setting passwords and creating user"
echo "root:$ROOT_PASSWORD" | chpasswd
log "Root password set"

if ! id "$USERNAME_NEW" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo,adm,systemd-journal "$USERNAME_NEW"
fi
echo "$USERNAME_NEW:$USER_PASSWORD" | chpasswd
ok "User '$USERNAME_NEW' ready"

# ── Section 8: Network (systemd-networkd) ────────────────────────────────────
step "Configuring network (systemd-networkd)"
mkdir -p /etc/systemd/network
if [[ "$NETWORK_MODE" == "static" ]]; then
  cat >/etc/systemd/network/20-wired.network <<EOF
[Match]
Name=en*

[Network]
Address=$STATIC_ADDR
$( [[ -n "$STATIC_GW" ]] && echo "Gateway=$STATIC_GW" )
$( for d in $STATIC_DNS; do echo "DNS=$d"; done )
EOF
else
  cat >/etc/systemd/network/20-wired.network <<EOF
[Match]
Name=en*

[Network]
DHCP=yes
EOF
fi
systemctl enable systemd-networkd systemd-resolved >/dev/null
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
ok "Networking configured ($NETWORK_MODE)"

# ── Section 9: SSH ───────────────────────────────────────────────────────────
step "Enabling SSH"
systemctl enable ssh >/dev/null
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/'              /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
# Regenerate host keys (the LXC rootfs ships none or stale ones)
rm -f /etc/ssh/ssh_host_*
ssh-keygen -A
ok "SSH ready"

# ── Section 10: GRUB ─────────────────────────────────────────────────────────
step "Installing GRUB bootloader"

# Headless/server-friendly defaults: short timeout, no quiet, no os-prober
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2/' /etc/default/grub
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=""/' /etc/default/grub
if grep -q '^GRUB_DISABLE_OS_PROBER' /etc/default/grub; then
  sed -i 's/^GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=true/' /etc/default/grub
else
  echo 'GRUB_DISABLE_OS_PROBER=true' >> /etc/default/grub
fi

if [[ "$UEFI_MODE" == "yes" ]]; then
  # Try with NVRAM write first; if firmware/env prevents it, fall back to --no-nvram
  if ! grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=LMDE --recheck 2>&1; then
    warn "grub-install with NVRAM write failed; retrying with --no-nvram"
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=LMDE --recheck --no-nvram
  fi
  # Always populate the firmware-fallback path (\EFI\BOOT\BOOTX64.EFI).
  # This rescues us from Dell/HP/Lenovo firmwares that ignore custom NVRAM entries.
  if [[ -f /boot/efi/EFI/LMDE/grubx64.efi ]]; then
    mkdir -p /boot/efi/EFI/BOOT
    cp /boot/efi/EFI/LMDE/grubx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI
    log "Installed firmware-fallback bootloader at \\EFI\\BOOT\\BOOTX64.EFI"
  fi
else
  grub-install --target=i386-pc "$DISK"
fi
update-grub
ok "GRUB installed"

# ── Section 11: initramfs ────────────────────────────────────────────────────
step "Rebuilding initramfs"
update-initramfs -u -k all
ok "initramfs updated"

# ── Section 12: Final sanity checks ──────────────────────────────────────────
step "Post-install sanity"
test -e /boot/vmlinuz-* || die "No kernel in /boot — install incomplete"
test -e /boot/initrd.img-* || die "No initrd in /boot — install incomplete"
if [[ "$UEFI_MODE" == "yes" ]]; then
  test -e /boot/efi/EFI/LMDE/grubx64.efi || die "GRUB EFI binary missing"
fi
[[ "$LAYER_LMDE" == "yes" && -f /etc/linuxmint/info ]] && log "Mint identity: $(grep '^RELEASE\|^CODENAME' /etc/linuxmint/info | xargs)"
ok "All checks passed"

echo
ok "Phase 2 complete — system ready for first boot"
PHASE2_EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1.9 — EXECUTE PHASE 2 INSIDE CHROOT
# ─────────────────────────────────────────────────────────────────────────────

phase1_run_chroot() {
  step "Phase 1.9 — Entering chroot to run phase 2"
  log "chroot $TARGET /bin/bash /root/phase2.sh"
  chroot "$TARGET" /bin/bash /root/phase2.sh
  ok "Phase 2 exited cleanly"
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1.10 — TEARDOWN
# ─────────────────────────────────────────────────────────────────────────────

phase1_teardown() {
  step "Phase 1.10 — Teardown"

  # Secrets first
  if [[ -f "$TARGET/root/install.conf" ]]; then
    shred -u "$TARGET/root/install.conf" 2>/dev/null || rm -f "$TARGET/root/install.conf"
  fi

  sync
  log "Unmounting..."
  # Unmount efivars first if bind-mounted
  umount -R "$TARGET/sys/firmware/efi/efivars" 2>/dev/null || true
  # Reverse order
  for d in run sys proc dev/pts dev; do
    umount -R "$TARGET/$d" 2>/dev/null || umount -lR "$TARGET/$d" 2>/dev/null || true
  done
  umount -R "$TARGET/boot/efi" 2>/dev/null || true
  umount -R "$TARGET" 2>/dev/null || umount -lR "$TARGET" 2>/dev/null || true
  swapoff -a 2>/dev/null || true
  # Clear PHASE1_MOUNTS so the EXIT trap doesn't try again
  PHASE1_MOUNTS=()
  ok "Unmounted"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

main() {
  step "LMDE 7 '$LMDE_CODENAME' headless installer"
  log "Target:    ${DISK:-<auto>}"
  log "Hostname:  $HOSTNAME_NEW"
  log "User:      $USERNAME_NEW"
  log "Timezone:  $TIMEZONE"
  log "Locale:    $LOCALE (extras: $EXTRA_LOCALES)"
  log "Keymap:    $KEYMAP"
  log "Network:   $NETWORK_MODE${STATIC_ADDR:+ ($STATIC_ADDR)}"
  log "Layer LMDE: $LAYER_LMDE"
  log "Reboot:    $DO_REBOOT"

  phase1_preflight
  phase1_target
  phase1_partition
  phase1_format
  phase1_mount
  phase1_fetch_rootfs
  phase1_extract
  phase1_chroot_prep
  phase1_run_chroot
  phase1_teardown

  echo
  printf '%s════════════════════════════════════════════════════════════%s\n' "$C_GREEN" "$C_RESET"
  ok "INSTALL COMPLETE"
  printf '%s════════════════════════════════════════════════════════════%s\n' "$C_GREEN" "$C_RESET"
  log "Disk:       $DISK"
  log "Hostname:   $HOSTNAME_NEW"
  log "User:       $USERNAME_NEW"
  if [[ "$ROOT_PWD_GENERATED" == "yes" || "$USER_PWD_GENERATED" == "yes" ]]; then
    echo
    warn "════════════════════════════════════════════════════════════"
    warn "GENERATED CREDENTIALS — write these down NOW, they won't be shown again:"
    [[ "$ROOT_PWD_GENERATED" == "yes" ]] && warn "  root password:           $ROOT_PASSWORD"
    [[ "$USER_PWD_GENERATED" == "yes" ]] && warn "  $USERNAME_NEW password: $USER_PASSWORD"
    warn "════════════════════════════════════════════════════════════"
  fi
  echo

  if [[ "$DO_REBOOT" == "yes" ]]; then
    local pause=5
    if [[ "$ROOT_PWD_GENERATED" == "yes" || "$USER_PWD_GENERATED" == "yes" ]]; then
      pause=20
      warn "Rebooting in ${pause}s — record the generated passwords above NOW"
    else
      log "Rebooting in ${pause}s... (Ctrl-C to cancel and pull the USB manually)"
    fi
    sleep "$pause"
    systemctl reboot || reboot
  else
    log "Run 'reboot' when ready. Remove the USB during POST."
  fi
}

main "$@"
