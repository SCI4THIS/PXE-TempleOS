#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
IPXE_SOURCE="$PROJECT_ROOT/dnsmasq/ipxe-src"
OUTPUT_ROOT="$PROJECT_ROOT/dnsmasq/tftp"
BUILD_JOBS="${IPXE_BUILD_JOBS:-}"

usage() {
    cat <<'EOF'
Usage: scripts/build-ipxe-artifacts.sh [OPTIONS]

Build the tracked x86 iPXE boot files with the host's normal build toolchain.

Options:
  --source DIR   iPXE source tree (default: pinned dnsmasq/ipxe-src submodule)
  --output DIR   artifact destination (default: dnsmasq/tftp)
  --jobs COUNT   parallel make jobs (default: number of online processors)
  -h, --help     show this help

The builder must be x86-64 and have make, GCC, binutils, Perl, and Python 3.
Custom source and output paths allow this command to run on a worker node with
the repository or output directory provided through shared network storage.
EOF
}

while (($#)); do
    case "$1" in
        --source)
            [[ $# -ge 2 ]] || { printf '%s\n' 'Missing value for --source' >&2; exit 2; }
            IPXE_SOURCE="$(cd -- "$2" && pwd)"
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || { printf '%s\n' 'Missing value for --output' >&2; exit 2; }
            mkdir -p -- "$2"
            OUTPUT_ROOT="$(cd -- "$2" && pwd)"
            shift 2
            ;;
        --jobs)
            [[ $# -ge 2 ]] || { printf '%s\n' 'Missing value for --jobs' >&2; exit 2; }
            BUILD_JOBS="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$(uname -m)" in
    x86_64|amd64) ;;
    *)
        printf 'This builder requires an x86-64 host; detected %s.\n' "$(uname -m)" >&2
        exit 1
        ;;
esac

if [[ -z "$BUILD_JOBS" ]]; then
    BUILD_JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '2')"
fi
[[ "$BUILD_JOBS" =~ ^[1-9][0-9]*$ ]] || {
    printf '%s\n' '--jobs must be a positive integer' >&2
    exit 2
}

missing=()
for command in make gcc ld objcopy perl python3 git sha256sum install; do
    command -v "$command" >/dev/null 2>&1 || missing+=("$command")
done
if ((${#missing[@]})); then
    printf 'Missing build tools: %s\n' "${missing[*]}" >&2
    printf '%s\n' 'Debian/Ubuntu: sudo apt install build-essential binutils perl python3 git coreutils' >&2
    printf '%s\n' 'Arch Linux:     sudo pacman -S base-devel perl python git coreutils' >&2
    exit 1
fi

[[ -f "$IPXE_SOURCE/src/Makefile" ]] || {
    printf 'No initialized iPXE source tree found at %s\n' "$IPXE_SOURCE" >&2
    printf '%s\n' 'Run: git submodule update --init --recursive' >&2
    exit 1
}

[[ -z "$(git -C "$IPXE_SOURCE" status --porcelain)" ]] || {
    printf '%s\n' 'The iPXE source tree has uncommitted changes; refusing an unrepeatable build.' >&2
    exit 1
}

revision="$(git -C "$IPXE_SOURCE" rev-parse HEAD)"
source_url="$(git -C "$IPXE_SOURCE" remote get-url origin 2>/dev/null || printf 'unknown')"
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT

# Build from a disposable copy so generated objects never dirty the submodule.
mkdir -p "$temporary/ipxe"
cp -a "$IPXE_SOURCE/." "$temporary/ipxe/"

printf 'Building iPXE %s with %s job(s)\n' "$revision" "$BUILD_JOBS"
make -C "$temporary/ipxe/src" -j"$BUILD_JOBS" \
    bin/ipxe.pxe \
    bin/undionly.kpxe \
    bin-x86_64-efi/ipxe.efi

artifacts=(
    x86_64-pcbios/ipxe.pxe:bin/ipxe.pxe
    x86_64-pcbios/undionly.kpxe:bin/undionly.kpxe
    x86_64-efi/ipxe.efi:bin-x86_64-efi/ipxe.efi
)

for mapping in "${artifacts[@]}"; do
    destination="${mapping%%:*}"
    source="${mapping#*:}"
    [[ -s "$temporary/ipxe/src/$source" ]] || {
        printf 'Builder did not produce %s\n' "$source" >&2
        exit 1
    }
    install -Dm644 "$temporary/ipxe/src/$source" "$OUTPUT_ROOT/$destination"
done

manifest="$OUTPUT_ROOT/ipxe-build.txt"
{
    printf 'source=%s\n' "$source_url"
    printf 'revision=%s\n' "$revision"
    for mapping in "${artifacts[@]}"; do
        destination="${mapping%%:*}"
        checksum="$(sha256sum "$OUTPUT_ROOT/$destination" | awk '{print $1}')"
        printf 'sha256=%s  %s\n' "$checksum" "$destination"
    done
} >"$manifest"

printf '\nGenerated artifacts in %s:\n' "$OUTPUT_ROOT"
for mapping in "${artifacts[@]}"; do
    printf '  %s\n' "${mapping%%:*}"
done
printf '  ipxe-build.txt\n'
printf '\nReview and commit the generated files.\n'
