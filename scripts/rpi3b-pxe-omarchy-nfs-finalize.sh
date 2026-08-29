#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  rpi3b-pxe-omarchy-nfs-finalize.sh \
    --server 192.168.1.68 \
    --home-export /mnt/ssd/exports/rw/omarchy-home

Run this INSIDE the staged Omarchy root (normally via arch-chroot).
It converts the staged installation into a generic diskless NFS root:
  - installs nfs-utils + mkinitcpio-nfs-utils
  - removes autodetect from mkinitcpio for generic NIC support
  - adds the net hook
  - adds a late initramfs hook that overlays the RO NFS root with tmpfs
  - mounts the supplied NFS export at /home
  - removes local-disk /, /boot, /home and swap entries from fstab
  - builds initramfs and stable PXE kernel/initramfs symlinks
EOF
}

SERVER=""
HOME_EXPORT=""

while (($#)); do
    case "$1" in
        --server) SERVER="${2:?}"; shift 2 ;;
        --home-export) HOME_EXPORT="${2:?}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -n "$SERVER" ]] || { echo "--server is required" >&2; exit 2; }
[[ -n "$HOME_EXPORT" ]] || { echo "--home-export is required" >&2; exit 2; }
[[ "$(uname -m)" == x86_64 ]] || {
    echo "This finalizer must run in an x86_64 Omarchy root." >&2
    exit 1
}
command -v pacman >/dev/null || {
    echo "pacman was not found; this does not look like an Arch/Omarchy root." >&2
    exit 1
}
command -v mkinitcpio >/dev/null || {
    echo "mkinitcpio was not found." >&2
    exit 1
}

echo "Installing NFS initramfs support..."
pacman -Sy --needed --noconfirm nfs-utils mkinitcpio-nfs-utils

mkdir -p /etc/initcpio/install /etc/initcpio/hooks

cat >/etc/initcpio/install/rpi3b_pxe_overlay <<'EOF'
#!/bin/bash

build() {
    add_module overlay
    add_runscript
}

help() {
    cat <<HELPEOF
Adds a tmpfs OverlayFS upper layer over a read-only NFS root.
HELPEOF
}
EOF

cat >/etc/initcpio/hooks/rpi3b_pxe_overlay <<'EOF'
#!/usr/bin/ash

run_latehook() {
    lower="/run/rpi3b-pxe/lower"
    overlay="/run/rpi3b-pxe/overlay"

    mkdir -p "$lower" "$overlay" /new_root

    # The normal mkinitcpio net/filesystems path has already mounted the
    # read-only NFS root at /new_root.
    mount --move /new_root "$lower" || {
        echo "RPI3B+PXE: unable to move NFS root to overlay lowerdir" >&2
        return 1
    }

    mkdir -p /new_root
    mount -t tmpfs -o mode=0755,size=768M tmpfs "$overlay" || return 1
    mkdir -p "$overlay/upper" "$overlay/work"

    mount -t overlay overlay \
        -o "lowerdir=$lower,upperdir=$overlay/upper,workdir=$overlay/work" \
        /new_root || {
            echo "RPI3B+PXE: unable to mount root OverlayFS" >&2
            return 1
        }
}
EOF

chmod 0755 \
    /etc/initcpio/install/rpi3b_pxe_overlay \
    /etc/initcpio/hooks/rpi3b_pxe_overlay

echo "Configuring mkinitcpio hooks..."
# shellcheck disable=SC1091
source /etc/mkinitcpio.conf

declare -a NEW_HOOKS=()
added_net=0
added_overlay=0
saw_filesystems=0

for hook in "${HOOKS[@]}"; do
    # A shared NFS root must be generic enough to boot different NICs.
    [[ "$hook" == "autodetect" ]] && continue
    [[ "$hook" == "net" ]] && continue
    [[ "$hook" == "rpi3b_pxe_overlay" ]] && continue

    if [[ "$hook" == "filesystems" ]]; then
        NEW_HOOKS+=("net")
        added_net=1
        NEW_HOOKS+=("$hook")
        NEW_HOOKS+=("rpi3b_pxe_overlay")
        added_overlay=1
        saw_filesystems=1
    else
        NEW_HOOKS+=("$hook")
    fi
done

if (( ! saw_filesystems )); then
    (( added_net )) || NEW_HOOKS+=("net")
    NEW_HOOKS+=("filesystems")
    (( added_overlay )) || NEW_HOOKS+=("rpi3b_pxe_overlay")
fi

new_hooks_line="HOOKS=(${NEW_HOOKS[*]})"
tmp="$(mktemp)"
awk -v replacement="$new_hooks_line" '
    BEGIN { replaced=0 }
    /^HOOKS=/ {
        if (!replaced) {
            print replacement
            replaced=1
        }
        next
    }
    { print }
    END {
        if (!replaced) print replacement
    }
' /etc/mkinitcpio.conf >"$tmp"
install -m 0644 "$tmp" /etc/mkinitcpio.conf
rm -f "$tmp"

echo "Configuring diskless fstab..."
tmp="$(mktemp)"
awk '
    /^[[:space:]]*#/ || NF == 0 { print; next }
    $2 == "/" { next }
    $2 == "/home" { next }
    $2 == "/boot" { next }
    $2 == "/efi" { next }
    $2 == "/boot/efi" { next }
    $3 == "swap" { next }
    { print }
' /etc/fstab >"$tmp"

printf '%s:%s\t/home\tnfs\trw,_netdev,nofail,x-systemd.automount\t0\t0\n' \
    "$SERVER" "$HOME_EXPORT" >>"$tmp"
install -m 0644 "$tmp" /etc/fstab
rm -f "$tmp"

# Avoid giving every diskless client the same systemd identity or SSH host keys.
: >/etc/machine-id
rm -f /etc/ssh/ssh_host_* 2>/dev/null || true

echo "Building generic NFS/OverlayFS initramfs..."
mkinitcpio -P

kernel="$(find /boot -maxdepth 1 -type f -name 'vmlinuz-*' \
    ! -name 'vmlinuz-rpi3b-pxe' | sort | head -n1)"
[[ -n "$kernel" ]] || {
    echo "No kernel was found under /boot." >&2
    exit 1
}

pkgbase="${kernel##*/vmlinuz-}"
initramfs="/boot/initramfs-${pkgbase}.img"
[[ -s "$initramfs" ]] || {
    echo "Expected initramfs was not found: $initramfs" >&2
    exit 1
}

ln -sfn "$(basename "$kernel")" /boot/vmlinuz-rpi3b-pxe
ln -sfn "$(basename "$initramfs")" /boot/initramfs-rpi3b-pxe.img

touch /.rpi3b-pxe-nfs-ready

echo
echo "NFS root finalization complete."
echo "Kernel:    $kernel"
echo "Initramfs: $initramfs"
echo "Home:      $SERVER:$HOME_EXPORT"
echo
echo "Return to the RPI3B+PXE TUI and choose:"
echo "  Omarchy -> NFS -> Promote finalized build to RO root"
