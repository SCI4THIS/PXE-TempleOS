#!/usr/bin/env bash
set -euo pipefail

OMARCHY_VERSION="4.0.1"
OMARCHY_URL="https://iso.omarchy.org/omarchy-${OMARCHY_VERSION}.iso"
OMARCHY_SHA256="69cbb4e10d98ad831c3c9f245b5757a9d1fedfd0c9592780e977d6f950dea8c3"

WORKDIR="/mnt/ssd"
ISO="${WORKDIR}/omarchy-${OMARCHY_VERSION}.iso"
SHA_CACHE="${WORKDIR}/.omarchy-${OMARCHY_VERSION}.sha256-cache"

DEST="$(pwd)/nginx/www/omarchy"
EXTRACT_OK="${DEST}/.omarchy-${OMARCHY_VERSION}.extracted"

REQUIRED_FILES=(
    "arch/boot/x86_64/vmlinuz-linux-t2"
    "arch/boot/x86_64/initramfs-linux-t2.img"
)

command -v wget >/dev/null || {
    echo "ERROR: wget is required" >&2
    exit 1
}

command -v xorriso >/dev/null || {
    echo "ERROR: xorriso is required" >&2
    exit 1
}

mkdir -p "$WORKDIR"

if [[ -f "$ISO" ]]; then
    echo "Using existing ISO:"
    echo "  $ISO"
else
    echo "Downloading Omarchy ${OMARCHY_VERSION}..."
    wget -c -O "$ISO" "$OMARCHY_URL"
fi

CURRENT_STATE="$(stat -c '%s %Y' "$ISO")"

if [[ -f "$SHA_CACHE" ]] &&
   [[ "$(cat "$SHA_CACHE")" == "$CURRENT_STATE" ]]; then
    echo "ISO unchanged since previous SHA-256 verification; skipping checksum."
else
    echo "Verifying SHA-256..."
    echo "${OMARCHY_SHA256}  ${ISO}" | sha256sum -c -

    # Only cache the result after successful verification.
    CURRENT_STATE="$(stat -c '%s %Y' "$ISO")"
    printf '%s\n' "$CURRENT_STATE" > "$SHA_CACHE"
fi

EXTRACT_VALID=true

if [[ ! -f "$EXTRACT_OK" ]]; then
    EXTRACT_VALID=false
else
    for file in "${REQUIRED_FILES[@]}"; do
        if [[ ! -f "$DEST/$file" ]]; then
            EXTRACT_VALID=false
            break
        fi
    done
fi

if [[ "$EXTRACT_VALID" == true ]]; then
    echo "Omarchy ${OMARCHY_VERSION} PXE tree is already extracted; skipping extraction."
else
    echo "Preparing Omarchy PXE tree..."

    rm -rf "$DEST"
    mkdir -p "$DEST"

    echo "Extracting /arch from ISO..."
    xorriso \
        -osirrox on \
        -indev "$ISO" \
        -extract /arch "$DEST/arch"

    echo "Checking required PXE files..."

    for file in "${REQUIRED_FILES[@]}"; do
        if [[ ! -f "$DEST/$file" ]]; then
            echo "ERROR: Required file was not found after extraction:" >&2
            echo "  $DEST/$file" >&2
            exit 1
        fi
    done

    # Mark extraction complete only after all required files are present.
    touch "$EXTRACT_OK"
fi

echo
echo "Required PXE files:"
for file in "${REQUIRED_FILES[@]}"; do
    ls -lh "$DEST/$file"
done

echo
echo "Omarchy PXE tree:"
echo "  $DEST"

echo
echo "Kernel URL:"
echo "  /omarchy/arch/boot/x86_64/vmlinuz-linux-t2"

echo
echo "Initramfs URL:"
echo "  /omarchy/arch/boot/x86_64/initramfs-linux-t2.img"

echo
echo "Done."
