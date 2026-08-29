#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage:
  sudo ./omarchy-nfs-stage.sh \
    --server 192.168.1.68 \
    --build-export /mnt/ssd/exports/rw/omarchy-nfs-build \
    --home-export /mnt/ssd/exports/rw/omarchy-home

Run this FROM an installed x86_64 Omarchy system.

Before running it, enable:
  RPI3B+PXE -> Omarchy -> NFS -> Enable temporary build export

The temporary build export deliberately uses no_root_squash so rsync can
preserve the installed system's UIDs/GIDs and permissions. Disable it after
the TUI promotes the finalized build into the read-only export.
EOF
}

SERVER=""
BUILD_EXPORT=""
HOME_EXPORT=""

while (($#)); do
    case "$1" in
        --server) SERVER="${2:?}"; shift 2 ;;
        --build-export) BUILD_EXPORT="${2:?}"; shift 2 ;;
        --home-export) HOME_EXPORT="${2:?}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ $EUID -eq 0 ]] || {
    echo "Run this script with sudo/root." >&2
    exit 1
}
[[ "$(uname -m)" == x86_64 ]] || {
    echo "This staging script must run on x86_64." >&2
    exit 1
}
[[ -n "$SERVER" && -n "$BUILD_EXPORT" && -n "$HOME_EXPORT" ]] || {
    usage >&2
    exit 2
}

for cmd in mount umount rsync chroot; do
    command -v "$cmd" >/dev/null || {
        echo "Required command not found: $cmd" >&2
        exit 1
    }
done

MOUNT="$(mktemp -d /tmp/rpi3b-pxe-omarchy-build.XXXXXX)"
ROOT="$MOUNT/root"
mounted=0
binds=()

cleanup() {
    set +e
    for ((i=${#binds[@]}-1; i>=0; i--)); do
        umount -R "${binds[$i]}" 2>/dev/null
    done
    (( mounted )) && umount "$MOUNT" 2>/dev/null
    rmdir "$MOUNT" 2>/dev/null
}
trap cleanup EXIT

echo "Mounting temporary Omarchy build export..."
mount -t nfs -o rw,vers=4.2 "$SERVER:$BUILD_EXPORT" "$MOUNT"
mounted=1
mkdir -p "$ROOT"

echo "Staging installed Omarchy root to NFS..."
rsync -aHAXx --numeric-ids --delete \
    --exclude='/boot/*' \
    --exclude='/home/*' \
    --exclude='/dev/*' \
    --exclude='/proc/*' \
    --exclude='/sys/*' \
    --exclude='/run/*' \
    --exclude='/tmp/*' \
    --exclude='/mnt/*' \
    --exclude='/media/*' \
    --exclude='/lost+found' \
    / "$ROOT/"

mkdir -p "$ROOT/boot" "$ROOT/home"

# /boot and /home are commonly separate mounts/subvolumes, so copy them explicitly.
if [[ -d /boot ]]; then
    rsync -aHAX --numeric-ids --delete /boot/ "$ROOT/boot/"
fi
if [[ -d /home ]]; then
    rsync -aHAX --numeric-ids --delete /home/ "$ROOT/home/"
fi

install -Dm755 \
    "$SCRIPT_DIR/rpi3b-pxe-omarchy-nfs-finalize.sh" \
    "$ROOT/root/rpi3b-pxe-omarchy-nfs-finalize.sh"

# Ensure DNS works in the chroot even when the source uses a runtime resolver symlink.
cp -Lf /etc/resolv.conf "$ROOT/etc/resolv.conf"

echo "Preparing chroot mounts..."
mount --rbind /dev "$ROOT/dev"
mount --make-rslave "$ROOT/dev"
binds+=("$ROOT/dev")

mount -t proc proc "$ROOT/proc"
binds+=("$ROOT/proc")

mount -t sysfs sysfs "$ROOT/sys"
binds+=("$ROOT/sys")

mount --rbind /run "$ROOT/run"
mount --make-rslave "$ROOT/run"
binds+=("$ROOT/run")

echo "Finalizing staged NFS root..."
chroot "$ROOT" /root/rpi3b-pxe-omarchy-nfs-finalize.sh \
    --server "$SERVER" \
    --home-export "$HOME_EXPORT"

echo
echo "Build tree is finalized."
echo "Return to RPI3B+PXE and choose:"
echo "  Omarchy -> NFS -> Promote finalized build to RO root"
echo "Then disable the temporary build export."
