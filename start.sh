#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/rpi3b-pxe"
CONFIG_FILE="$CONFIG_HOME/config.env"
DOCKER_ENV="$PROJECT_ROOT/.env"
RUNTIME_HOME="$CONFIG_HOME/runtime"
BOOT_IPXE="$RUNTIME_HOME/boot.ipxe"

COMPOSE_BASE="$PROJECT_ROOT/docker-compose.yml"
COMPOSE_LAYER="$PROJECT_ROOT/docker-compose.rpi3b-pxe.yml"
NFS_EXPORTS_FILE="/etc/exports.d/rpi3b-pxe.exports"

STATE_HOME="$CONFIG_HOME/state"
BUILD_HASH_FILE="$STATE_HOME/build-inputs.sha256"
RUNTIME_HASH_FILE="$STATE_HOME/runtime-inputs.sha256"

DEFAULT_EXPORT_RO="/mnt/ssd/exports/ro"
DEFAULT_EXPORT_RW="/mnt/ssd/exports/rw"
DEFAULT_BACKUP_DIR="/mnt/ssd/bkup"
DEFAULT_OMARCHY_VERSION="4.0.1"

TEMPLEOS_URL="https://templeos.org/Downloads/TempleOS.ISO"
OMARCHY_URL_BASE="https://iso.omarchy.org"
OMARCHY_4_0_1_SHA256="69cbb4e10d98ad831c3c9f245b5757a9d1fedfd0c9592780e977d6f950dea8c3"

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

run_root() {
    if (( EUID == 0 )); then
        "$@"
    else
        have sudo || die "sudo is required for host configuration."
        sudo "$@"
    fi
}

pause() {
    printf '\nPress Enter to continue...'
    read -r _
}

clear_screen() {
    # Do not depend on remote terminfo entries such as xterm-kitty.
    printf '\033[2J\033[H'
}

detect_ip() {
    hostname -I 2>/dev/null | awk '{print $1}'
}

default_network_for_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.[0-9]+$ ]]; then
        printf '%s.%s.%s.0/24\n' \
            "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    else
        printf '192.168.1.0/24\n'
    fi
}

compose_command_kind() {
    if docker compose version >/dev/null 2>&1; then
        printf 'plugin\n'
    elif have docker-compose && docker-compose version >/dev/null 2>&1; then
        printf 'legacy\n'
    else
        return 1
    fi
}

compose() {
    local kind root=()
    kind="$(compose_command_kind)" || die "Docker Compose is not installed."

    if ! docker info >/dev/null 2>&1 && (( EUID != 0 )); then
        root=(sudo)
    fi

    (
        cd "$PROJECT_ROOT"
        if [[ "$kind" == plugin ]]; then
            "${root[@]}" docker compose \
                -f "$COMPOSE_BASE" \
                -f "$COMPOSE_LAYER" \
                "$@"
        else
            "${root[@]}" docker-compose \
                -f "$COMPOSE_BASE" \
                -f "$COMPOSE_LAYER" \
                "$@"
        fi
    )
}

hash_stream() {
    sha256sum | awk '{print $1}'
}

build_inputs_hash() {
    {
        printf 'PXE_SERVER_IP=%s\n' "$PXE_SERVER_IP"
        printf 'UID=%s\n' "$(id -u)"
        printf 'GID=%s\n' "$(id -g)"
        printf 'ENABLE_SAMBA=%s\n' "$ENABLE_SAMBA"
        printf 'OMARCHY_NFS_BUILD_EXPORT=%s\n' "$OMARCHY_NFS_BUILD_EXPORT"

        # Hash Docker build inputs, not runtime/bind-mounted data.
        find \
            "$PROJECT_ROOT/dnsmasq" \
            "$PROJECT_ROOT/nginx" \
            "$PROJECT_ROOT/samba" \
            \( \
                -path "$PROJECT_ROOT/dnsmasq/tftp" -o \
                -path "$PROJECT_ROOT/nginx/www" -o \
                -path "$PROJECT_ROOT/samba/shared" \
            \) -prune -o \
            -type f \
            ! -path "$PROJECT_ROOT/nginx/runtime-start.sh" \
            ! -path "$PROJECT_ROOT/nginx/runtime-nginx.conf" \
            -print0 2>/dev/null |
            sort -z |
            while IFS= read -r -d '' file; do
                printf 'FILE %s\n' "${file#"$PROJECT_ROOT"/}"
                sha256sum "$file"
            done

        for file in "$COMPOSE_BASE" "$COMPOSE_LAYER"; do
            if [[ -f "$file" ]]; then
                printf 'FILE %s\n' "${file#"$PROJECT_ROOT"/}"
                sha256sum "$file"
            fi
        done
    } | hash_stream
}

runtime_inputs_hash() {
    {
        printf 'PXE_SERVER_IP=%s\n' "$PXE_SERVER_IP"
        printf 'EXPORT_RO=%s\n' "$EXPORT_RO"
        printf 'SAMBA_ROOT=%s\n' "$SAMBA_ROOT"
        printf 'BOOT_RUNTIME_DIR=%s\n' "$RUNTIME_HOME"
        printf 'ENABLE_SAMBA=%s\n' "$ENABLE_SAMBA"

        for file in \
            "$COMPOSE_BASE" \
            "$COMPOSE_LAYER" \
            "$PROJECT_ROOT/nginx/runtime-start.sh" \
            "$PROJECT_ROOT/nginx/runtime-nginx.conf"
        do
            if [[ -f "$file" ]]; then
                printf 'FILE %s\n' "${file#"$PROJECT_ROOT"/}"
                sha256sum "$file"
            fi
        done
    } | hash_stream
}

stored_hash() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    cat "$file"
}

store_hash() {
    local file="$1" value="$2"
    mkdir -p "$STATE_HOME"
    printf '%s\n' "$value" >"$file"
}

bootstrap_dependencies() {
    local missing=() packages=() answer

    printf 'RPI3B+PXE bootstrap\n\n'
    printf 'Checking host dependencies...\n'

    check_dependency() {
        local command="$1" package="$2"
        if have "$command"; then
            printf '[OK]   %s\n' "$command"
        else
            printf '[MISS] %s\n' "$command"
            missing+=("$command")
            packages+=("$package")
        fi
    }

    check_dependency whiptail whiptail
    check_dependency wget wget
    check_dependency xorriso xorriso
    check_dependency rsync rsync
    check_dependency exportfs nfs-kernel-server
    check_dependency docker docker.io

    if compose_command_kind >/dev/null 2>&1; then
        printf '[OK]   docker compose\n'
    else
        printf '[MISS] docker compose\n'
        missing+=("docker compose")
        packages+=("docker-compose")
    fi

    if ((${#missing[@]} == 0)); then
        return 0
    fi

    have apt-get || die "Missing dependencies and apt-get is unavailable."

    printf '\nThe following packages are required:\n  %s\n\n' "${packages[*]}"
    read -r -p 'Install missing dependencies? [Y/n] ' answer
    case "${answer:-Y}" in
        [Yy]|[Yy][Ee][Ss]) ;;
        *) die "Dependencies are required before the TUI can start." ;;
    esac

    run_root apt-get update
    run_root apt-get install -y "${packages[@]}"

    if have systemctl; then
        run_root systemctl enable --now docker || true
        run_root systemctl enable --now nfs-kernel-server || true
    fi

    exec "$0" --tui
}

write_default_config() {
    local ip network
    ip="$(detect_ip)"
    [[ -n "$ip" ]] || ip="192.168.1.68"
    network="$(default_network_for_ip "$ip")"

    mkdir -p "$CONFIG_HOME"
    {
        printf 'PXE_SERVER_IP=%q\n' "$ip"
        printf 'PXE_NETWORK=%q\n' "$network"
        printf 'EXPORT_RO=%q\n' "$DEFAULT_EXPORT_RO"
        printf 'EXPORT_RW=%q\n' "$DEFAULT_EXPORT_RW"
        printf 'BACKUP_DIR=%q\n' "$DEFAULT_BACKUP_DIR"
        printf 'SAMBA_ROOT=%q\n' "$DEFAULT_EXPORT_RW/samba"
        printf 'ENABLE_SAMBA=0\n'
        printf 'OMARCHY_NFS_BUILD_EXPORT=0\n'
        printf 'OMARCHY_VERSION=%q\n' "$DEFAULT_OMARCHY_VERSION"
    } >"$CONFIG_FILE"
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] || write_default_config

    # Generated by this script using shell-escaped scalar values.
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    : "${PXE_SERVER_IP:?PXE_SERVER_IP is missing from config}"
    : "${PXE_NETWORK:?PXE_NETWORK is missing from config}"
    : "${EXPORT_RO:?EXPORT_RO is missing from config}"
    : "${EXPORT_RW:?EXPORT_RW is missing from config}"
    : "${BACKUP_DIR:?BACKUP_DIR is missing from config}"
    : "${SAMBA_ROOT:?SAMBA_ROOT is missing from config}"
    : "${ENABLE_SAMBA:=0}"
    : "${OMARCHY_NFS_BUILD_EXPORT:=0}"
    : "${OMARCHY_VERSION:=$DEFAULT_OMARCHY_VERSION}"
}

save_config() {
    mkdir -p "$CONFIG_HOME"
    {
        printf 'PXE_SERVER_IP=%q\n' "$PXE_SERVER_IP"
        printf 'PXE_NETWORK=%q\n' "$PXE_NETWORK"
        printf 'EXPORT_RO=%q\n' "$EXPORT_RO"
        printf 'EXPORT_RW=%q\n' "$EXPORT_RW"
        printf 'BACKUP_DIR=%q\n' "$BACKUP_DIR"
        printf 'SAMBA_ROOT=%q\n' "$SAMBA_ROOT"
        printf 'ENABLE_SAMBA=%q\n' "$ENABLE_SAMBA"
        printf 'OMARCHY_NFS_BUILD_EXPORT=%q\n' "$OMARCHY_NFS_BUILD_EXPORT"
        printf 'OMARCHY_VERSION=%q\n' "$OMARCHY_VERSION"
    } >"$CONFIG_FILE"
}

path_is_within() {
    local child="${1%/}/" parent="${2%/}/"
    [[ "$child" == "$parent"* ]]
}

validate_config() {
    [[ "$EXPORT_RO" != "$EXPORT_RW" ]] ||
        die "RO and RW exports must be different directories."

    [[ "$BACKUP_DIR" != "$EXPORT_RO" ]] ||
        die "Backup directory may not equal the RO export."

    [[ "$BACKUP_DIR" != "$EXPORT_RW" ]] ||
        die "Backup directory may not equal the RW export."

    if path_is_within "$BACKUP_DIR" "$EXPORT_RO" ||
       path_is_within "$BACKUP_DIR" "$EXPORT_RW"; then
        die "Backup directory must not be inside an exported directory."
    fi

    if ! path_is_within "$SAMBA_ROOT" "$EXPORT_RW"; then
        die "The Samba directory must be inside the RW export."
    fi
}

ensure_directories() {
    validate_config

    run_root mkdir -p \
        "$EXPORT_RO/templeos" \
        "$EXPORT_RO/omarchy" \
        "$EXPORT_RW" \
        "$BACKUP_DIR"

    if [[ "$ENABLE_SAMBA" == 1 ]]; then
        run_root mkdir -p "$SAMBA_ROOT"
    fi

    # These directories contain files downloaded/generated by the TUI.
    run_root chown "$(id -u):$(id -g)" \
        "$EXPORT_RO/templeos" \
        "$EXPORT_RO/omarchy"
}

write_docker_env() {
    mkdir -p "$RUNTIME_HOME"
    chmod 0755 "$RUNTIME_HOME"

    cat >"$DOCKER_ENV" <<__ENV__
PXE_SERVER_IP=$PXE_SERVER_IP
UID=$(id -u)
GID=$(id -g)
EXPORT_RO=$EXPORT_RO
SAMBA_ROOT=$SAMBA_ROOT
BOOT_RUNTIME_DIR=$RUNTIME_HOME
__ENV__
}

templeos_iso() {
    printf '%s/templeos/TempleOS.ISO\n' "$EXPORT_RO"
}

templeos_part() {
    printf '%s.part\n' "$(templeos_iso)"
}

templeos_ready() {
    # Final name is only installed after wget exits successfully.
    [[ -s "$(templeos_iso)" ]]
}

omarchy_root() {
    printf '%s/omarchy\n' "$EXPORT_RO"
}

omarchy_iso() {
    printf '%s/omarchy-%s.iso\n' "$(omarchy_root)" "$OMARCHY_VERSION"
}

omarchy_part() {
    printf '%s.part\n' "$(omarchy_iso)"
}

omarchy_sha_cache() {
    printf '%s/.omarchy-%s.sha256-cache\n' "$(omarchy_root)" "$OMARCHY_VERSION"
}

omarchy_extract_marker() {
    printf '%s/.omarchy-%s.extracted\n' "$(omarchy_root)" "$OMARCHY_VERSION"
}

omarchy_expected_sha() {
    case "$OMARCHY_VERSION" in
        4.0.1) printf '%s\n' "$OMARCHY_4_0_1_SHA256" ;;
        *) return 1 ;;
    esac
}

omarchy_required_files() {
    cat <<'__FILES__'
arch/boot/x86_64/vmlinuz-linux-t2
arch/boot/x86_64/initramfs-linux-t2.img
arch/x86_64/airootfs.sfs
__FILES__
}

omarchy_iso_verified() {
    local iso cache state
    iso="$(omarchy_iso)"
    cache="$(omarchy_sha_cache)"

    [[ -s "$iso" && -f "$cache" ]] || return 1

    state="$(stat -c '%s %Y' "$iso")"
    [[ "$(cat "$cache")" == "$state" ]]
}

omarchy_tree_ready() {
    local root file
    root="$(omarchy_root)"

    while IFS= read -r file; do
        [[ -s "$root/$file" ]] || return 1
    done < <(omarchy_required_files)
}

# Boot readiness depends only on the extracted files, not a stale marker or
# whether the source ISO was retained.
omarchy_ready() {
    omarchy_tree_ready
}

omarchy_nfs_ro_root() {
    printf '%s/omarchy-nfs/root\n' "$EXPORT_RO"
}

omarchy_nfs_build_export() {
    printf '%s/omarchy-nfs-build\n' "$EXPORT_RW"
}

omarchy_nfs_build_root() {
    printf '%s/root\n' "$(omarchy_nfs_build_export)"
}

omarchy_nfs_home() {
    printf '%s/omarchy-home\n' "$EXPORT_RW"
}

omarchy_nfs_required_files() {
    cat <<'__FILES__'
.rpi3b-pxe-nfs-ready
etc/os-release
boot/vmlinuz-rpi3b-pxe
boot/initramfs-rpi3b-pxe.img
__FILES__
}

omarchy_nfs_build_ready() {
    local root file
    root="$(omarchy_nfs_build_root)"

    while IFS= read -r file; do
        [[ -e "$root/$file" ]] || return 1
    done < <(omarchy_nfs_required_files)
}

omarchy_nfs_ready() {
    local root file
    root="$(omarchy_nfs_ro_root)"

    while IFS= read -r file; do
        [[ -e "$root/$file" ]] || return 1
    done < <(omarchy_nfs_required_files)
}

status_word() {
    if "$@"; then
        printf 'READY'
    else
        printf 'MISSING/INCOMPLETE'
    fi
}

download_with_resume() {
    local url="$1" final="$2" partial="$3"

    mkdir -p "$(dirname "$final")"

    # If a previous version placed an unfinished file at the final path, let
    # wget resume it as the .part file. The final name is only restored on a
    # successful wget exit.
    if [[ -f "$final" && ! -f "$partial" ]]; then
        mv "$final" "$partial"
    fi

    wget -c -O "$partial" "$url"
    mv -f "$partial" "$final"
}

download_templeos() {
    clear_screen
    log "Downloading TempleOS..."
    download_with_resume \
        "$TEMPLEOS_URL" \
        "$(templeos_iso)" \
        "$(templeos_part)"

    generate_boot_ipxe
    log
    log "TempleOS is ready: $(templeos_iso)"
}

verify_omarchy() {
    local iso sha cache state actual

    iso="$(omarchy_iso)"
    cache="$(omarchy_sha_cache)"
    sha="$(omarchy_expected_sha)" ||
        die "No SHA-256 is configured for Omarchy $OMARCHY_VERSION."

    [[ -s "$iso" ]] || die "Omarchy ISO is missing: $iso"

    log "Verifying SHA-256 for Omarchy $OMARCHY_VERSION..."
    log "This reads the entire ISO. Byte progress will be shown below."

    # dd writes progress to stderr while sha256sum receives the bytes on stdin.
    actual="$(
        dd if="$iso" bs=16M status=progress |
            sha256sum |
            awk '{print $1}'
    )"

    if [[ "$actual" != "$sha" ]]; then
        rm -f "$cache"
        die "Omarchy SHA-256 verification failed."
    fi

    state="$(stat -c '%s %Y' "$iso")"
    printf '%s\n' "$state" >"$cache"

    log "Omarchy SHA-256 verified."
}

extract_omarchy() {
    local iso root file

    iso="$(omarchy_iso)"
    root="$(omarchy_root)"

    omarchy_iso_verified || verify_omarchy

    rm -f "$(omarchy_extract_marker)"
    rm -rf "$root/arch"
    mkdir -p "$root"

    log "Extracting /arch from Omarchy $OMARCHY_VERSION..."
    xorriso \
        -osirrox on \
        -indev "$iso" \
        -extract /arch "$root/arch"

    while IFS= read -r file; do
        [[ -s "$root/$file" ]] ||
            die "Omarchy extraction is incomplete: $root/$file"
    done < <(omarchy_required_files)

    touch "$(omarchy_extract_marker)"
    generate_boot_ipxe
    nfs_configure

    log "Omarchy extraction complete."
}

download_omarchy() {
    local url

    clear_screen
    url="$OMARCHY_URL_BASE/omarchy-${OMARCHY_VERSION}.iso"

    rm -f "$(omarchy_sha_cache)" "$(omarchy_extract_marker)"

    log "Downloading Omarchy $OMARCHY_VERSION..."
    download_with_resume \
        "$url" \
        "$(omarchy_iso)" \
        "$(omarchy_part)"

    verify_omarchy
    extract_omarchy

    log
    log "Omarchy is ready under: $(omarchy_root)"
}

nfs_configure() {
    local tmp

    ensure_directories

    tmp="$(mktemp)"
    {
        cat <<__EXPORTS__
# Managed by RPI3B+PXE. Edit through ./start.sh.
$EXPORT_RO $PXE_NETWORK(ro,sync,root_squash,no_subtree_check)
$EXPORT_RW $PXE_NETWORK(rw,sync,root_squash,no_subtree_check)
__EXPORTS__

        if [[ "$OMARCHY_NFS_BUILD_EXPORT" == 1 ]]; then
            cat <<__EXPORTS__
# TEMPORARY: required only while staging an Omarchy NFS root.
# Disable this after the build is promoted to the RO export.
$(omarchy_nfs_build_export) $PXE_NETWORK(rw,sync,no_subtree_check,no_root_squash)
__EXPORTS__
        fi
    } >"$tmp"

    run_root mkdir -p /etc/exports.d
    run_root install -m 0644 "$tmp" "$NFS_EXPORTS_FILE"
    rm -f "$tmp"

    if have systemctl; then
        run_root systemctl enable --now nfs-kernel-server || true
    fi

    run_root exportfs -ra
}

sync_backup() {
    local dest="$BACKUP_DIR/rw"

    run_root mkdir -p "$dest"
    run_root rsync -a "$EXPORT_RW/" "$dest/"
}

promote_omarchy_nfs() {
    local build ro home

    build="$(omarchy_nfs_build_root)"
    ro="$(omarchy_nfs_ro_root)"
    home="$(omarchy_nfs_home)"

    omarchy_nfs_build_ready ||
        die "The Omarchy NFS build tree is not finalized yet: $build"

    run_root mkdir -p "$ro" "$home"

    # Seed persistent home directories without overwriting an existing user's
    # files on later promotions.
    if [[ -d "$build/home" ]]; then
        run_root rsync -aHAX --numeric-ids --ignore-existing \
            "$build/home/" "$home/"
    fi

    # Promote the prepared system as a shared read-only base. /home is excluded
    # because clients mount the RW home export there after switch_root.
    run_root rsync -aHAX --numeric-ids --delete \
        --exclude='/dev/*' \
        --exclude='/proc/*' \
        --exclude='/sys/*' \
        --exclude='/run/*' \
        --exclude='/tmp/*' \
        --exclude='/mnt/*' \
        --exclude='/media/*' \
        --exclude='/home/*' \
        "$build/" "$ro/"

    run_root mkdir -p "$ro/home"
    generate_boot_ipxe

    log "Omarchy NFS root promoted to:"
    log "  $ro"
    log "Persistent /home:"
    log "  $home"
}

toggle_omarchy_nfs_build_export() {
    if [[ "$OMARCHY_NFS_BUILD_EXPORT" == 1 ]]; then
        OMARCHY_NFS_BUILD_EXPORT=0
        log "Disabling temporary no_root_squash Omarchy build export..."
    else
        if ! whiptail --yesno \
            "NFS build mode temporarily exports:\n\n$(omarchy_nfs_build_export)\n\nwith no_root_squash to $PXE_NETWORK.\n\nThis is intentionally privileged and should be disabled immediately after staging/finalizing the NFS root.\n\nEnable it?" \
            18 78; then
            return 0
        fi
        OMARCHY_NFS_BUILD_EXPORT=1
        log "Enabling temporary no_root_squash Omarchy build export..."
    fi

    save_config
    nfs_configure
}

show_omarchy_nfs_instructions() {
    whiptail --title 'Omarchy - NFS build workflow' --msgbox \
"1. Enable NFS Build Export here.

2. On an x86_64 Omarchy installation, copy scripts/omarchy-nfs-stage.sh from this repo.

3. Run:
   sudo ./omarchy-nfs-stage.sh \\
     --server $PXE_SERVER_IP \\
     --build-export $(omarchy_nfs_build_export) \\
     --home-export $(omarchy_nfs_home)

4. Return here and choose Promote Build to RO.

5. Disable NFS Build Export.

After promotion, PXE shows Omarchy - NFS. Its root is RO NFS + a RAM overlay; /home is the RW NFS export." \
        24 78 || true
}

generate_boot_ipxe() {
    local tmp

    mkdir -p "$RUNTIME_HOME"
    chmod 0755 "$RUNTIME_HOME"
    tmp="$(mktemp "${BOOT_IPXE}.tmp.XXXXXX")"

    {
        cat <<__MENU__
#!ipxe
# Probe readiness endpoints on every PXE boot. nginx checks actual server files.
set templeos_ready 0
imgfetch --name templeos-ready http://${PXE_SERVER_IP}/ready/templeos && set templeos_ready 1 ||
imgfree templeos-ready ||

set omarchy_install_ready 0
imgfetch --name omarchy-install-ready http://${PXE_SERVER_IP}/ready/omarchy-install && set omarchy_install_ready 1 ||
imgfree omarchy-install-ready ||

set omarchy_nfs_ready 0
imgfetch --name omarchy-nfs-ready http://${PXE_SERVER_IP}/ready/omarchy-nfs && set omarchy_nfs_ready 1 ||
imgfree omarchy-nfs-ready ||

set tinycore_ready 0
imgfetch --name tinycore-ready http://${PXE_SERVER_IP}/ready/tinycore && set tinycore_ready 1 ||
imgfree tinycore-ready ||

menu RPI3B+PXE Network Boot Menu
item --key a alpine Alpine Linux
__MENU__

        if [[ "$ENABLE_SAMBA" == 1 ]]; then
            echo 'item --key d alpine-dev Alpine Linux - Development'
        fi

        cat <<__MENU__
iseq \${templeos_ready} 1 && item --key t templeos Temple OS (Alpine Linux + QEMU) ||
iseq \${omarchy_install_ready} 1 && item --key o omarchy-install Omarchy - Install ||
iseq \${omarchy_nfs_ready} 1 && item --key n omarchy-nfs Omarchy - NFS ||
item --key r omarchy-repair Omarchy - Boot Repair
iseq \${tinycore_ready} 1 && item --key c tinycore Tiny Core Linux ||
item --key s shell iPXE shell

choose --default alpine target || goto alpine
goto \${target}

:tinycore
echo Booting TinyCore...
kernel http://${PXE_SERVER_IP}/tinycore/vmlinuz
initrd http://${PXE_SERVER_IP}/tinycore/corepure64.gz
boot

:alpine
echo Booting Alpine...
kernel http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/v3.23/releases/x86_64/netboot-3.23.3/vmlinuz-lts \\
  modules=loop,squashfs quiet nomodeset \\
  alpine_repo=http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/alpine/v3.23/main,http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/alpine/v3.23/community \\
  modloop=http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/v3.23/releases/x86_64/netboot-3.23.3/modloop-lts \\
  ntp=pool.ntp.org \\
  ip=dhcp
initrd http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/v3.23/releases/x86_64/netboot-3.23.3/initramfs-lts
boot
__MENU__

        if [[ "$ENABLE_SAMBA" == 1 ]]; then
            cat <<__MENU__

:alpine-dev
echo Booting Alpine Development...
kernel http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/v3.23/releases/x86_64/netboot-3.23.3/vmlinuz-lts \\
  modules=loop,squashfs quiet nomodeset \\
  alpine_repo=http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/alpine/v3.23/main,http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/alpine/v3.23/community \\
  apkovl=http://${PXE_SERVER_IP}/dev-apkovl.tar.gz \\
  modloop=http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/v3.23/releases/x86_64/netboot-3.23.3/modloop-lts \\
  pkgs=build-base,git,python3,meson,ninja,pkgconf,glib-dev,pixman-dev,zlib-dev,libaio-dev,util-linux-dev,alsa-lib-dev,sdl2-dev,eudev-dev,libdrm-dev,linux-headers,cifs-utils,alpine-sdk,sudo,mesa-dev,mesa-egl,mesa-gbm,libepoxy-dev,flex,bison,elfutils-dev,diffutils,grep,perl \\
  ntp=pool.ntp.org \\
  ip=dhcp
initrd http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/v3.23/releases/x86_64/netboot-3.23.3/initramfs-lts
boot
__MENU__
        fi

        cat <<__MENU__

:templeos
echo Booting TempleOS...
kernel http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/v3.23/releases/x86_64/netboot-3.23.3/vmlinuz-lts \\
  modules=loop,squashfs quiet nomodeset \\
  alpine_repo=http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/alpine/v3.23/main,http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/alpine/v3.23/community \\
  apkovl=http://${PXE_SERVER_IP}/templeos-apkovl.tar.gz \\
  modloop=http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/v3.23/releases/x86_64/netboot-3.23.3/modloop-lts \\
  ntp=pool.ntp.org \\
  ip=dhcp
initrd http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/v3.23/releases/x86_64/netboot-3.23.3/initramfs-lts
boot

:omarchy-install
echo Booting Omarchy installer...
kernel http://${PXE_SERVER_IP}/media/omarchy/arch/boot/x86_64/vmlinuz-linux-t2 \\
  archisobasedir=omarchy/arch \\
  archiso_nfs_srv=${PXE_SERVER_IP}:${EXPORT_RO} \\
  copytoram=n \\
  initramfs_async=0 \\
  ip=\${net0/ip}:${PXE_SERVER_IP}:\${net0/gateway}:\${net0/netmask} \\
  BOOTIF=01-\${net0/mac:hexhyp}
initrd http://${PXE_SERVER_IP}/media/omarchy/arch/boot/x86_64/initramfs-linux-t2.img
boot

:omarchy-nfs
echo Booting Omarchy from read-only NFS root...
kernel http://${PXE_SERVER_IP}/media/omarchy-nfs/root/boot/vmlinuz-rpi3b-pxe \\
  root=/dev/nfs \\
  rootfstype=nfs \\
  rootflags=ro \\
  nfsroot=${PXE_SERVER_IP}:$(omarchy_nfs_ro_root),ro,vers=4.2 \\
  ip=:::::eth0:dhcp \\
  BOOTIF=01-\${net0/mac:hexhyp}
initrd http://${PXE_SERVER_IP}/media/omarchy-nfs/root/boot/initramfs-rpi3b-pxe.img
boot


:omarchy-repair
echo Booting Omarchy Boot Repair...
kernel http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/v3.23/releases/x86_64/netboot-3.23.3/vmlinuz-lts \
  modules=loop,squashfs,btrfs,dm-crypt quiet nomodeset \
  alpine_repo=http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/alpine/v3.23/main,http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/alpine/v3.23/community \
  apkovl=http://${PXE_SERVER_IP}/rpi3b-pxe-extra/omarchy-repair-apkovl.tar.gz \
  modloop=http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/v3.23/releases/x86_64/netboot-3.23.3/modloop-lts \
  pkgs=bash,newt,cryptsetup,btrfs-progs,grub-bios,lsblk,blkid,findmnt,mount,umount,sfdisk,kbd \
  ntp=pool.ntp.org \
  ip=dhcp
initrd http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/v3.23/releases/x86_64/netboot-3.23.3/initramfs-lts
boot

:shell
shell
__MENU__
    } >"$tmp"

    chmod 0644 "$tmp"
    mv -f "$tmp" "$BOOT_IPXE"
}

compose_stack_status() {
    local expected=2 running=0 services

    [[ "$ENABLE_SAMBA" == 1 ]] && expected=3

    services="$(compose ps --services --filter status=running 2>/dev/null || true)"

    grep -qx 'dnsmasq' <<<"$services" && ((running+=1))
    grep -qx 'http' <<<"$services" && ((running+=1))

    if [[ "$ENABLE_SAMBA" == 1 ]]; then
        grep -qx 'samba' <<<"$services" && ((running+=1))
    fi

    if (( running == expected )); then
        printf 'RUNNING (%d/%d)' "$running" "$expected"
    elif (( running == 0 )); then
        printf 'STOPPED (0/%d)' "$expected"
    else
        printf 'PARTIAL (%d/%d)' "$running" "$expected"
    fi
}

nfs_status_word() {
    if [[ -f "$NFS_EXPORTS_FILE" ]]; then
        printf 'CONFIGURED'
    else
        printf 'NOT CONFIGURED'
    fi
}

samba_status_word() {
    if [[ "$ENABLE_SAMBA" == 1 ]]; then
        printf 'ENABLED'
    else
        printf 'DISABLED'
    fi
}

configure_nfs_settings_tui() {
    local value
    local old_rw="$EXPORT_RW"
    local new_ip="$PXE_SERVER_IP"
    local new_network="$PXE_NETWORK"
    local new_ro="$EXPORT_RO"
    local new_rw="$EXPORT_RW"
    local new_samba="$SAMBA_ROOT"

    value="$(
        whiptail --inputbox \
            'PXE server IPv4 address' 10 72 "$new_ip" \
            3>&1 1>&2 2>&3
    )" || return 0
    new_ip="$value"

    value="$(
        whiptail --inputbox \
            'PXE client network (CIDR)' 10 72 "$new_network" \
            3>&1 1>&2 2>&3
    )" || return 0
    new_network="$value"

    value="$(
        whiptail --inputbox \
            'Read-only NFS export' 10 78 "$new_ro" \
            3>&1 1>&2 2>&3
    )" || return 0
    new_ro="$value"

    value="$(
        whiptail --inputbox \
            'Read-write NFS export' 10 78 "$new_rw" \
            3>&1 1>&2 2>&3
    )" || return 0
    new_rw="$value"

    if [[ "$new_ro" == "$new_rw" ]]; then
        whiptail --msgbox \
            'RO and RW exports must be different directories.' \
            9 68
        return 0
    fi

    if path_is_within "$BACKUP_DIR" "$new_ro" ||
       path_is_within "$BACKUP_DIR" "$new_rw"; then
        whiptail --msgbox \
            'The backup directory may not be inside either NFS export.' \
            9 72
        return 0
    fi

    # Preserve the conventional <RW>/samba relationship when it is still in use.
    if [[ "$SAMBA_ROOT" == "$old_rw/samba" ]]; then
        new_samba="$new_rw/samba"
    elif ! path_is_within "$SAMBA_ROOT" "$new_rw"; then
        whiptail --msgbox \
            'The current Samba path would be outside the new RW export. Configure Samba first, or keep the current RW export.' \
            11 76
        return 0
    fi

    PXE_SERVER_IP="$new_ip"
    PXE_NETWORK="$new_network"
    EXPORT_RO="$new_ro"
    EXPORT_RW="$new_rw"
    SAMBA_ROOT="$new_samba"

    save_config
    ensure_directories
    write_docker_env
    generate_boot_ipxe
}

configure_backup_tui() {
    local value

    value="$(
        whiptail --inputbox \
            'Server-only backup directory' 10 78 "$BACKUP_DIR" \
            3>&1 1>&2 2>&3
    )" || return 0

    if path_is_within "$value" "$EXPORT_RO" ||
       path_is_within "$value" "$EXPORT_RW"; then
        whiptail --msgbox \
            'The backup directory may not be inside either exported directory.' \
            9 72
        return 0
    fi

    BACKUP_DIR="$value"
    save_config
    ensure_directories
}

configure_samba_path_tui() {
    local value

    value="$(
        whiptail --inputbox \
            'Samba directory (must be inside RW export)' \
            10 78 "$SAMBA_ROOT" \
            3>&1 1>&2 2>&3
    )" || return 0

    if ! path_is_within "$value" "$EXPORT_RW"; then
        whiptail --msgbox \
            'The Samba directory must be inside the RW export.' \
            9 68
        return 0
    fi

    SAMBA_ROOT="$value"
    save_config
    ensure_directories
    write_docker_env
}

omarchy_nfs_tui() {
    local choice build_state

    while true; do
        if [[ "$OMARCHY_NFS_BUILD_EXPORT" == 1 ]]; then
            build_state="ENABLED - no_root_squash"
        else
            build_state="DISABLED"
        fi

        choice="$(
            whiptail \
                --title 'Omarchy - NFS' \
                --menu \
                "Boot root: $(status_word omarchy_nfs_ready)\nBuild tree: $(status_word omarchy_nfs_build_ready)\nBuild export: $build_state\nRO root: $(omarchy_nfs_ro_root)\nRW home: $(omarchy_nfs_home)" \
                23 84 8 \
                instructions 'Show NFS build instructions' \
                build-export 'Enable / disable temporary build export' \
                promote 'Promote finalized build to RO root' \
                back 'Back' \
                3>&1 1>&2 2>&3
        )" || return 0

        case "$choice" in
            instructions)
                show_omarchy_nfs_instructions
                ;;
            build-export)
                clear_screen
                toggle_omarchy_nfs_build_export
                pause
                ;;
            promote)
                clear_screen
                promote_omarchy_nfs
                pause
                ;;
            back)
                return 0
                ;;
        esac
    done
}

omarchy_tui() {
    local choice

    while true; do
        choice="$(
            whiptail \
                --title "Omarchy $OMARCHY_VERSION" \
                --menu \
                "Installer media: $(status_word omarchy_ready)\nNFS root: $(status_word omarchy_nfs_ready)\nInstaller ISO verified: $(status_word omarchy_iso_verified)" \
                20 82 7 \
                install-media 'Manage Omarchy installer media' \
                nfs 'Manage Omarchy - NFS' \
                back 'Back' \
                3>&1 1>&2 2>&3
        )" || return 0

        case "$choice" in
            install-media)
                while true; do
                    local media_choice
                    media_choice="$(
                        whiptail \
                            --title 'Omarchy - Install media' \
                            --menu \
                            "Status: $(status_word omarchy_ready)\nLocation: $(omarchy_root)" \
                            19 78 6 \
                            download 'Download / resume, verify, and extract' \
                            verify 'Verify existing ISO' \
                            extract 'Re-extract existing ISO' \
                            back 'Back' \
                            3>&1 1>&2 2>&3
                    )" || break

                    case "$media_choice" in
                        download) download_omarchy; pause ;;
                        verify) clear_screen; verify_omarchy; generate_boot_ipxe; pause ;;
                        extract) clear_screen; extract_omarchy; pause ;;
                        back) break ;;
                    esac
                done
                ;;
            nfs)
                omarchy_nfs_tui
                ;;
            back)
                return 0
                ;;
        esac
    done
}

templeos_tui() {
    local choice

    while true; do
        choice="$(
            whiptail \
                --title 'TempleOS' \
                --menu \
                "Status: $(status_word templeos_ready)\nISO: $(templeos_iso)" \
                17 78 5 \
                download 'Download / resume TempleOS' \
                back 'Back' \
                3>&1 1>&2 2>&3
        )" || return 0

        case "$choice" in
            download)
                download_templeos
                pause
                ;;
            back)
                return 0
                ;;
        esac
    done
}

samba_tui() {
    local choice action

    while true; do
        if [[ "$ENABLE_SAMBA" == 1 ]]; then
            action='Disable Samba'
        else
            action='Enable Samba'
        fi

        choice="$(
            whiptail \
                --title 'Samba' \
                --menu \
                "Status: $(samba_status_word)\nShare path: $SAMBA_ROOT\nRW export: $EXPORT_RW" \
                18 78 6 \
                toggle "$action" \
                path 'Configure Samba directory' \
                back 'Back' \
                3>&1 1>&2 2>&3
        )" || return 0

        case "$choice" in
            toggle)
                if [[ "$ENABLE_SAMBA" == 1 ]]; then
                    ENABLE_SAMBA=0
                else
                    ENABLE_SAMBA=1
                fi

                save_config
                ensure_directories
                write_docker_env
                generate_boot_ipxe
                ;;
            path)
                configure_samba_path_tui
                ;;
            back)
                return 0
                ;;
        esac
    done
}

nfs_tui() {
    local choice

    while true; do
        choice="$(
            whiptail \
                --title 'NFS' \
                --menu \
                "Status: $(nfs_status_word)\nNetwork: $PXE_NETWORK\nRO: $EXPORT_RO\nRW: $EXPORT_RW" \
                20 78 7 \
                config 'Configure PXE network and export paths' \
                apply 'Apply / repair NFS exports' \
                show 'Show active NFS exports' \
                back 'Back' \
                3>&1 1>&2 2>&3
        )" || return 0

        case "$choice" in
            config)
                configure_nfs_settings_tui
                ;;
            apply)
                clear_screen
                nfs_configure
                log 'NFS exports applied.'
                pause
                ;;
            show)
                clear_screen
                run_root exportfs -v
                pause
                ;;
            back)
                return 0
                ;;
        esac
    done
}

backup_tui() {
    local choice

    while true; do
        choice="$(
            whiptail \
                --title 'Backup' \
                --menu \
                "Backup directory: $BACKUP_DIR\nSource: $EXPORT_RW" \
                17 78 6 \
                config 'Configure backup directory' \
                sync 'Sync RW export now' \
                back 'Back' \
                3>&1 1>&2 2>&3
        )" || return 0

        case "$choice" in
            config)
                configure_backup_tui
                ;;
            sync)
                clear_screen
                sync_backup
                log "RW export synchronized to $BACKUP_DIR/rw"
                pause
                ;;
            back)
                return 0
                ;;
        esac
    done
}

start_services() {
    local current_build stored_build current_runtime stored_runtime
    local rebuild=0 runtime_changed=0
    local services=(dnsmasq http)

    ensure_directories
    write_docker_env
    nfs_configure
    generate_boot_ipxe
    mkdir -p "$STATE_HOME"

    if have systemctl; then
        run_root systemctl enable --now docker || true
    fi

    if [[ "$ENABLE_SAMBA" == 1 ]]; then
        services+=(samba)
    else
        compose stop samba >/dev/null 2>&1 || true
        compose rm -f samba >/dev/null 2>&1 || true
    fi

    current_build="$(build_inputs_hash)"
    stored_build="$(stored_hash "$BUILD_HASH_FILE" 2>/dev/null || true)"

    if [[ "$current_build" != "$stored_build" ]]; then
        rebuild=1
        log "Docker build inputs changed; rebuilding images..."
        compose build "${services[@]}"
    else
        log "Docker build inputs unchanged; skipping image rebuild."
    fi

    current_runtime="$(runtime_inputs_hash)"
    stored_runtime="$(stored_hash "$RUNTIME_HASH_FILE" 2>/dev/null || true)"

    if [[ "$current_runtime" != "$stored_runtime" ]]; then
        runtime_changed=1
    fi

    # Reconcile containers without rebuilding if possible.
    if ! compose up -d --no-build "${services[@]}"; then
        log "Existing images were insufficient; rebuilding and retrying..."
        compose build "${services[@]}"
        compose up -d --no-build "${services[@]}"
        rebuild=1
        current_build="$(build_inputs_hash)"
    fi

    # Bind-mounted nginx config changes do not automatically make a running
    # nginx process parse the new file.
    if (( runtime_changed )); then
        log "Runtime configuration changed; restarting nginx..."
        compose restart http
    fi

    store_hash "$BUILD_HASH_FILE" "$current_build"
    store_hash "$RUNTIME_HASH_FILE" "$current_runtime"

    generate_boot_ipxe

    if (( rebuild )); then
        log "Images rebuilt."
    fi
}

stop_services() {
    compose down
}

monitor_services() {
    local rc

    clear_screen
    log "Monitoring Docker Compose. Press Ctrl+C to return to the menu."
    log

    # Ctrl+C normally makes `docker compose logs -f` exit 130. That is normal
    # navigation, not a fatal error.
    set +e
    compose logs --follow --tail=120
    rc=$?
    set -e

    if [[ "$rc" -ne 0 && "$rc" -ne 130 ]]; then
        log
        log "Docker Compose monitor exited with status $rc."
        pause
    fi

    return 0
}

tui() {
    local choice compose_state

    load_config
    ensure_directories
    write_docker_env
    generate_boot_ipxe

    while true; do
        compose_state="$(compose_stack_status)"

        choice="$(
            whiptail \
                --title 'RPI3B+PXE' \
                --menu \
                "PXE server: $PXE_SERVER_IP\nDocker Compose: $compose_state" \
                23 78 11 \
                omarchy "Omarchy [Install: $(status_word omarchy_ready), NFS: $(status_word omarchy_nfs_ready)]" \
                templeos "TempleOS [$(status_word templeos_ready)]" \
                samba "Samba [$(samba_status_word)]" \
                nfs "NFS [$(nfs_status_word)]" \
                backup 'Backup settings / sync' \
                start 'Start / reconcile PXE services' \
                stop 'Stop PXE services' \
                monitor 'Monitor Docker Compose' \
                exit 'Exit' \
                3>&1 1>&2 2>&3
        )" || exit 0

        case "$choice" in
            omarchy)
                omarchy_tui
                ;;
            templeos)
                templeos_tui
                ;;
            samba)
                samba_tui
                ;;
            nfs)
                nfs_tui
                ;;
            backup)
                backup_tui
                ;;
            start)
                clear_screen
                start_services
                monitor_services
                ;;
            stop)
                clear_screen
                stop_services
                pause
                ;;
            monitor)
                monitor_services
                ;;
            exit)
                exit 0
                ;;
        esac
    done
}

main() {
    if [[ "${1:-}" != "--tui" ]]; then
        bootstrap_dependencies
    fi

    have whiptail ||
        die "whiptail is not installed. Run ./start.sh without --tui."

    have wget ||
        die "wget is not installed. Run ./start.sh without --tui."

    have xorriso ||
        die "xorriso is not installed. Run ./start.sh without --tui."

    have rsync ||
        die "rsync is not installed. Run ./start.sh without --tui."

    have exportfs ||
        die "nfs-kernel-server is not installed. Run ./start.sh without --tui."

    have docker ||
        die "docker is not installed. Run ./start.sh without --tui."

    compose_command_kind >/dev/null ||
        die "Docker Compose is not installed. Run ./start.sh without --tui."

    tui
}

main "$@"
