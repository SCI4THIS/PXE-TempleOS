#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/rpi3b-pxe"
CONFIG_FILE="$CONFIG_HOME/config.env"
DOCKER_ENV="$PROJECT_ROOT/.env"
BOOT_IPXE="$CONFIG_HOME/boot.ipxe"
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
    # Avoid ncurses/terminfo so SSH works even when the server does not know
    # the client's TERM value (for example, xterm-kitty).
    printf '\033[2J\033[H'
}

detect_ip() {
    hostname -I 2>/dev/null | awk '{print $1}'
}

default_network_for_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.[0-9]+$ ]]; then
        printf '%s.%s.%s.0/24\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
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

    cd "$PROJECT_ROOT"
    if [[ "$kind" == plugin ]]; then
        "${root[@]}" docker compose -f "$COMPOSE_BASE" -f "$COMPOSE_LAYER" "$@"
    else
        "${root[@]}" docker-compose -f "$COMPOSE_BASE" -f "$COMPOSE_LAYER" "$@"
    fi
}

hash_stream() {
    sha256sum | awk '{print $1 }'
}


build_inputs_hash() {
    {
        printf 'PXE_SERVER_IP=%s\n' "$PXE_SERVER_IP"
        printf 'UID=%s\n' "$(id -u)"
        printf 'GID=%s\n' "$(id -g)"
        printf 'ENABLE_SAMBA=%s\n' "$ENABLE_SAMBA"

        # Hash Docker build inputs, but do not descend into runtime/bind-mounted
        # data. runtime-*.conf/sh are bind-mounted and are handled separately by
        # runtime_inputs_hash().
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
            -print0 |
            sort -z |
            while IFS= read -r -d '' file; do
                printf 'FILE %s\n' "${file#"$PROJECT_ROOT"/}"
                sha256sum "$file"
            done

        # Compose files can change build contexts, arguments, or Dockerfiles.
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
	printf 'BOOT_IPXE=%s\n' "$BOOT_IPXE"
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
        return
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
        printf 'OMARCHY_VERSION=%q\n' "$OMARCHY_VERSION"
    } >"$CONFIG_FILE"
}

path_is_within() {
    local child="${1%/}/" parent="${2%/}/"
    [[ "$child" == "$parent"* ]]
}

validate_config() {
    [[ "$EXPORT_RO" != "$EXPORT_RW" ]] || die "RO and RW exports must be different directories."
    [[ "$BACKUP_DIR" != "$EXPORT_RO" ]] || die "Backup directory may not equal the RO export."
    [[ "$BACKUP_DIR" != "$EXPORT_RW" ]] || die "Backup directory may not equal the RW export."

    if path_is_within "$BACKUP_DIR" "$EXPORT_RO" || path_is_within "$BACKUP_DIR" "$EXPORT_RW"; then
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

    run_root chown "$(id -u):$(id -g)" "$EXPORT_RO/templeos" "$EXPORT_RO/omarchy"
}

write_docker_env() {
    cat >"$DOCKER_ENV" <<__ENV__
PXE_SERVER_IP=$PXE_SERVER_IP
UID=$(id -u)
GID=$(id -g)
EXPORT_RO=$EXPORT_RO
SAMBA_ROOT=$SAMBA_ROOT
BOOT_IPXE_HOST=$BOOT_IPXE
__ENV__
}

templeos_iso() { printf '%s/templeos/TempleOS.ISO\n' "$EXPORT_RO"; }
templeos_part() { printf '%s.part\n' "$(templeos_iso)"; }
templeos_marker() { printf '%s.complete\n' "$(templeos_iso)"; }
templeos_ready() { [[ -s "$(templeos_iso)" ]]; }

omarchy_root() { printf '%s/omarchy\n' "$EXPORT_RO"; }
omarchy_iso() { printf '%s/omarchy-%s.iso\n' "$(omarchy_root)" "$OMARCHY_VERSION"; }
omarchy_part() { printf '%s.part\n' "$(omarchy_iso)"; }
omarchy_sha_cache() { printf '%s/.omarchy-%s.sha256-cache\n' "$(omarchy_root)" "$OMARCHY_VERSION"; }
omarchy_extract_marker() { printf '%s/.omarchy-%s.extracted\n' "$(omarchy_root)" "$OMARCHY_VERSION"; }

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

# Boot readiness is determined by the extracted files themselves.  The source
# ISO may be deleted after extraction without disabling an otherwise valid boot.
omarchy_ready() { omarchy_tree_ready; }

status_word() {
    if "$@"; then printf 'READY'; else printf 'MISSING/INCOMPLETE'; fi
}

download_with_resume() {
    local url="$1" final="$2" partial="$3" marker="${4:-}"
    mkdir -p "$(dirname "$final")"
    [[ -z "$marker" ]] || rm -f "$marker"

    if [[ -f "$final" && ! -f "$partial" ]]; then
        mv "$final" "$partial"
    fi

    wget -c -O "$partial" "$url"
    mv -f "$partial" "$final"
    [[ -z "$marker" ]] || touch "$marker"
}

download_templeos() {
    clear_screen
    log "Downloading TempleOS..."
    download_with_resume "$TEMPLEOS_URL" "$(templeos_iso)" "$(templeos_part)" "$(templeos_marker)"
    generate_boot_ipxe
    log
    log "TempleOS is ready: $(templeos_iso)"
}

verify_omarchy() {
    local iso sha cache state
    iso="$(omarchy_iso)"
    cache="$(omarchy_sha_cache)"
    sha="$(omarchy_expected_sha)" || die "No SHA-256 is configured for Omarchy $OMARCHY_VERSION."

    [[ -s "$iso" ]] || die "Omarchy ISO is missing: $iso"
    printf '%s  %s\n' "$sha" "$iso" | sha256sum -c -
    state="$(stat -c '%s %Y' "$iso")"
    printf '%s\n' "$state" >"$cache"
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
    xorriso -osirrox on -indev "$iso" -extract /arch "$root/arch"

    while IFS= read -r file; do
        [[ -s "$root/$file" ]] || die "Omarchy extraction is incomplete: $root/$file"
    done < <(omarchy_required_files)

    touch "$(omarchy_extract_marker)"
    generate_boot_ipxe
    nfs_configure
}

download_omarchy() {
    local url
    clear_screen
    url="$OMARCHY_URL_BASE/omarchy-${OMARCHY_VERSION}.iso"
    rm -f "$(omarchy_sha_cache)" "$(omarchy_extract_marker)"
    log "Downloading Omarchy $OMARCHY_VERSION..."
    download_with_resume "$url" "$(omarchy_iso)" "$(omarchy_part)"
    verify_omarchy
    extract_omarchy
    log
    log "Omarchy is ready under: $(omarchy_root)"
}

nfs_configure() {
    local tmp
    ensure_directories
    tmp="$(mktemp)"

    cat >"$tmp" <<__EXPORTS__
# Managed by RPI3B+PXE. Edit through ./start.sh.
$EXPORT_RO $PXE_NETWORK(ro,sync,root_squash,no_subtree_check)
$EXPORT_RW $PXE_NETWORK(rw,sync,root_squash,no_subtree_check)
__EXPORTS__

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

generate_boot_ipxe() {
    local tmp
    mkdir -p "$(dirname "$BOOT_IPXE")"
    tmp="$(mktemp "${BOOT_IPXE}.tmp.XXXXXX")"

    {
        cat <<__MENU__
#!ipxe

# Probe tiny readiness endpoints on every PXE boot.  nginx checks the actual
# files behind the configured RO export, so stale markers cannot expose an
# invalid menu entry.
set templeos_ready 0
imgfetch --name templeos-ready http://${PXE_SERVER_IP}/ready/templeos && set templeos_ready 1 ||
imgfree templeos-ready ||

set omarchy_ready 0
imgfetch --name omarchy-ready http://${PXE_SERVER_IP}/ready/omarchy && set omarchy_ready 1 ||
imgfree omarchy-ready ||

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
iseq \${omarchy_ready} 1 && item --key o omarchy Omarchy $OMARCHY_VERSION ||
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

:omarchy
echo Booting Omarchy $OMARCHY_VERSION...
kernel http://${PXE_SERVER_IP}/media/omarchy/arch/boot/x86_64/vmlinuz-linux-t2 \\
  archisobasedir=omarchy/arch \\
  archiso_nfs_srv=${PXE_SERVER_IP}:${EXPORT_RO} \\
  copytoram=n \\
  cms_verify=y \\
  initramfs_async=0 \\
  ip=\${net0/ip}:${PXE_SERVER_IP}:\${net0/gateway}:\${net0/netmask} \\
  BOOTIF=01-\${net0/mac:hexhyp}
initrd http://${PXE_SERVER_IP}/media/omarchy/arch/boot/x86_64/initramfs-linux-t2.img
boot
__MENU__

        cat <<'__MENU__'

:shell
shell
__MENU__
    } >"$tmp"

    mv -f "$tmp" "$BOOT_IPXE"
}

configure_tui() {
    local value old_rw
    old_rw="$EXPORT_RW"

    value="$(whiptail --inputbox 'PXE server IPv4 address' 10 72 "$PXE_SERVER_IP" 3>&1 1>&2 2>&3)" || return 0
    PXE_SERVER_IP="$value"
    value="$(whiptail --inputbox 'PXE client network (CIDR)' 10 72 "$PXE_NETWORK" 3>&1 1>&2 2>&3)" || return 0
    PXE_NETWORK="$value"
    value="$(whiptail --inputbox 'Read-only NFS export' 10 78 "$EXPORT_RO" 3>&1 1>&2 2>&3)" || return 0
    EXPORT_RO="$value"
    value="$(whiptail --inputbox 'Read-write NFS export' 10 78 "$EXPORT_RW" 3>&1 1>&2 2>&3)" || return 0
    EXPORT_RW="$value"

    if [[ "$SAMBA_ROOT" == "$old_rw/samba" ]]; then
        SAMBA_ROOT="$EXPORT_RW/samba"
    fi

    value="$(whiptail --inputbox 'Server-only backup directory' 10 78 "$BACKUP_DIR" 3>&1 1>&2 2>&3)" || return 0
    BACKUP_DIR="$value"
    value="$(whiptail --inputbox 'Samba directory (inside RW export)' 10 78 "$SAMBA_ROOT" 3>&1 1>&2 2>&3)" || return 0
    SAMBA_ROOT="$value"

    validate_config
    save_config
    ensure_directories
    write_docker_env
    generate_boot_ipxe
}

optional_services_tui() {
    local result state
    state=OFF
    [[ "$ENABLE_SAMBA" == 1 ]] && state=ON

    result="$(whiptail --title 'Optional services' --checklist \
        'Select services to enable' 14 72 4 \
        samba 'Samba file sharing' "$state" \
        3>&1 1>&2 2>&3)" || return 0

    if [[ "$result" == *samba* ]]; then ENABLE_SAMBA=1; else ENABLE_SAMBA=0; fi

    save_config
    ensure_directories
    write_docker_env
    generate_boot_ipxe
}

downloads_tui() {
    local choice
    while true; do
        choice="$(whiptail --title 'Boot media' --menu \
            "TempleOS: $(status_word templeos_ready)\nOmarchy $OMARCHY_VERSION: $(status_word omarchy_ready)" \
            19 78 8 \
            templeos 'Download / resume TempleOS' \
            omarchy 'Download / verify / extract Omarchy' \
            verify-omarchy 'Verify existing Omarchy ISO' \
            extract-omarchy 'Re-extract existing Omarchy ISO' \
            back 'Back' \
            3>&1 1>&2 2>&3)" || return 0

        case "$choice" in
            templeos) download_templeos; pause ;;
            omarchy) download_omarchy; pause ;;
            verify-omarchy) clear_screen; verify_omarchy; generate_boot_ipxe; pause ;;
            extract-omarchy) clear_screen; extract_omarchy; pause ;;
            back) return ;;
        esac
    done
}

show_status() {
    local samba nfs
    samba="disabled"
    [[ "$ENABLE_SAMBA" == 1 ]] && samba="enabled"
    nfs="not configured"
    [[ -f "$NFS_EXPORTS_FILE" ]] && nfs="configured"

    whiptail --title 'RPI3B+PXE status' --msgbox \
"PXE server:   $PXE_SERVER_IP
PXE network:  $PXE_NETWORK

RO export:    $EXPORT_RO
RW export:    $EXPORT_RW
Backup:       $BACKUP_DIR

TempleOS:     $(status_word templeos_ready)
Omarchy:      $(status_word omarchy_ready)
NFS:          $nfs
Samba:        $samba" 21 78 || true
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

    if have systemctl; then run_root systemctl enable --now docker || true; fi

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
    [[ "$current_runtime" != "$stored_runtime" ]] && runtime_changed=1

    # Start/reconcile containers without forcing an image build.  If the image
    # state was removed outside this tool, fall back to a build automatically.
    if ! compose up -d --no-build "${services[@]}"; then
        log "Existing images were insufficient; rebuilding and retrying..."
        compose build "${services[@]}"
        compose up -d --no-build "${services[@]}"
	rebuild=1
	current_build="$(build_inputs_hash)"
    fi

    # Bind-mounted nginx configuration changes do not cause Compose to restart
    # an already-running container.  Restart HTTP when those runtime inputs have
    # changed so nginx parses the new readiness/menu configuration
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

stop_services() { compose down; }

show_logs() {
    local rc
    clear_screen
    log "Streaming Docker logs.  Press Ctrl+C to return to the menu."
    log

    # docker compose logs -f normally exits with 130 after Ctrl+C.  Do not let
    # that expected status escape this function under `set -e`.
    set +e
    compose logs --follow --tail=120
    rc=$?
    set -e

    if [[ "$rc" -ne 0 && "$rc" -ne 130 ]]; then
      log
      log "Docker log stream exited with status $rc."
      pause
    fi
    return 0
}

tui() {
    local choice
    load_config
    ensure_directories
    write_docker_env
    generate_boot_ipxe

    while true; do
        choice="$(whiptail --title 'RPI3B+PXE' --menu \
            "PXE server: $PXE_SERVER_IP" 21 78 11 \
            status 'Status' \
            config 'Network / storage configuration' \
            downloads 'Manage boot media' \
            nfs 'Configure / repair NFS exports' \
            optional 'Optional services' \
            backup 'Sync RW export to server-only backup' \
            start 'Start / rebuild PXE services' \
            stop 'Stop PXE services' \
            logs 'View Docker logs' \
            exit 'Exit' \
            3>&1 1>&2 2>&3)" || exit 0

        case "$choice" in
            status) show_status ;;
            config) configure_tui ;;
            downloads) downloads_tui ;;
            nfs) clear_screen; nfs_configure; run_root exportfs -v; pause ;;
            optional) optional_services_tui ;;
            backup) clear_screen; sync_backup; log "RW export synchronized to $BACKUP_DIR/rw"; pause ;;
            start) clear_screen; start_services; show_logs ;;
            stop) clear_screen; stop_services; pause ;;
            logs) show_logs ;;
            exit) exit 0 ;;
        esac
    done
}

main() {
    if [[ "${1:-}" != "--tui" ]]; then bootstrap_dependencies; fi

    have whiptail || die "whiptail is not installed. Run ./start.sh without --tui."
    have wget || die "wget is not installed. Run ./start.sh without --tui."
    have xorriso || die "xorriso is not installed. Run ./start.sh without --tui."
    have rsync || die "rsync is not installed. Run ./start.sh without --tui."
    have exportfs || die "nfs-kernel-server is not installed. Run ./start.sh without --tui."
    have docker || die "docker is not installed. Run ./start.sh without --tui."
    compose_command_kind >/dev/null || die "Docker Compose is not installed. Run ./start.sh without --tui."

    tui
}

main "$@"
