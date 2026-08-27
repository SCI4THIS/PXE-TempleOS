#!/usr/bin/env bash
set -euo pipefail

OMARCHY_VERSION="4.0.1"
OMARCHY_URL="https://iso.omarchy.org/omarchy-${OMARCHY_VERSION}.iso"
OMARCHY_SHA256="69cbb4e10d98ad831c3c9f245b5757a9d1fedfd0c9592780e977d6f950dea8c3"

ISO="/tmp/omarchy-${OMARCHY_VERSION}.iso"
DEST="$(pwd)/nginx/www/omarchy"

command -v wget >/dev/null || {
    echo "ERROR: wget is required" >&2
    exit 1
}

command -v xorriso >/dev/null || {
    echo "ERROR: xorriso is required" >&2
    exit 1
}

echo "Downloading Omarchy ${OMARCHY_VERSION}..."
wget -c -O "$ISO" "$OMARCHY_URL"

echo "Verifying SHA-256..."
echo "${OMARCHY_SHA256}  ${ISO}" | sha256sum -c -

echo "Removing old Omarchy PXE files..."
rm -rf "$DEST"
mkdir -p "$DEST"

echo "Extracting /arch from ISO..."
xorriso \
    -osirrox on \
    -indev "$ISO" \
    -extract /arch "$DEST/arch"

echo
echo "Checking required PXE files..."

REQUIRED_FILES=(
    "arch/boot/x86_64/vmlinuz-linux-t2"
    "arch/boot/x86_64/initramfs-linux-t2.img"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "$DEST/$file" ]]; then
        echo "ERROR: Required file was not found:"
        echo "  $DEST/$file"
        exit 1
    fi
    ls -lh "$DEST/$file"
done

echo
echo "Omarchy PXE tree installed at:"
echo "  $DEST"
echo
echo "Kernel URL:"
echo "  /omarchy/arch/boot/x86_64/vmlinuz-linux-t2"
echo
echo "Initramfs URL:"
echo "  /omarchy/arch/boot/x86_64/initramfs-linux-t2.img"

rm -f "$ISO"

echo
echo "Done."
