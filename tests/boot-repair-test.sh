#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../nginx/repair-overlay/usr/local/sbin/omarchy-boot-repair
source "$PROJECT_ROOT/nginx/repair-overlay/usr/local/sbin/omarchy-boot-repair"

TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMP"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"
}

set_hooks() {
    rm -rf -- "$TEST_TMP/root"
    mkdir -p "$TEST_TMP/root/etc/mkinitcpio.conf.d"
    printf '%s\n' "$1" >"$TEST_TMP/root/etc/mkinitcpio.conf"
    ROOT="$TEST_TMP/root"
    LUKS_UUID="1111-2222"
}

set_hooks 'HOOKS=(base udev encrypt filesystems)'
detect_hook || fail 'encrypt hook was not detected'
assert_eq "$ENCRYPT_HOOK" encrypt
assert_eq "$CRYPT_ARGS" 'cryptdevice=UUID=1111-2222:root root=/dev/mapper/root'

set_hooks '  HOOKS=(base systemd sd-encrypt filesystems)'
detect_hook || fail 'sd-encrypt hook was not detected'
assert_eq "$ENCRYPT_HOOK" sd-encrypt
assert_eq "$CRYPT_ARGS" 'rd.luks.name=1111-2222=root root=/dev/mapper/root'

set_hooks 'HOOKS=(base encrypt filesystems)'
printf '%s\n' 'HOOKS=(base systemd sd-encrypt filesystems)' \
    >"$TEST_TMP/root/etc/mkinitcpio.conf.d/override.conf"
if detect_hook; then
    fail 'conflicting hooks must be rejected'
fi
assert_eq "$ENCRYPT_HOOK" UNKNOWN
[[ "$ENCRYPT_HOOK_ERROR" == Conflicting* ]] || fail 'conflict reason was not retained'

set_hooks 'HOOKS=(base filesystems)'
if detect_hook; then
    fail 'missing encryption hook must be rejected'
fi
assert_eq "$ENCRYPT_HOOK" UNKNOWN

PTTYPE=dos
BOOT_UUID='AAAA-BBBB'
VMLINUX_GRUB='/vmlinuz-linux'
INITRAMFS_GRUB='/initramfs-linux.img'
MICROCODE_GRUB='/intel-ucode.img'
CRYPT_ARGS='cryptdevice=UUID=1111-2222:root root=/dev/mapper/root'
generated="$TEST_TMP/grub.cfg"
write_proposed_grub "$generated"
grep -Fq 'insmod part_msdos' "$generated" || fail 'MBR module missing'
grep -Fq 'search --no-floppy --fs-uuid --set=root AAAA-BBBB' "$generated" || fail 'boot UUID missing'
grep -Fq 'initrd /intel-ucode.img /initramfs-linux.img' "$generated" || fail 'initrd order is wrong'
grep -Fq "$CRYPT_ARGS" "$generated" || fail 'encryption arguments missing'

printf '%s\n' 'boot-repair tests: PASS'
