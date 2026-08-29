#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
URL="http://tinycorelinux.net/17.x/x86_64/release"
ISO_FILE="${TMPDIR:-/tmp}/CorePure64-17.0.iso"
DEST="$PROJECT_ROOT/nginx/www/tinycore"

for command in curl bsdtar; do
    command -v "$command" >/dev/null || {
        printf 'Required command not found: %s\n' "$command" >&2
        exit 1
    }
done

[[ -s "$ISO_FILE" ]] || curl -fL "$URL/CorePure64-17.0.iso" -o "$ISO_FILE"

temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT

bsdtar -xf "$ISO_FILE" -C "$temporary" boot/vmlinuz64 boot/corepure64.gz
mkdir -p "$DEST"
install -m 0644 "$temporary/boot/vmlinuz64" "$DEST/vmlinuz"
install -m 0644 "$temporary/boot/corepure64.gz" "$DEST/corepure64.gz"

printf 'Tiny Core boot files installed in %s\n' "$DEST"
