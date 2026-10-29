#!/bin/ash
# shellcheck shell=dash
set -eu

SCRIPT_VERSION='1.0.0'
SUPPORTED_OPENWRT_VERSION='25.12.2'
SUPPORTED_PODKOP_VERSION='0.7.22'
SUPPORTED_PODKOP_PACKAGE='podkop-0.7.22-r1'
FORKOP_VERSION='1.0.5'

FORKOP_BACKEND='forkop_1.0.5.apk'
FORKOP_BACKEND_SHA256='8d514180b3e27c73179c021f1a659b23aaf765003f9810659f7ad1ca34152439'
FORKOP_LUCI='luci-app-forkop_1.0.5.apk'
FORKOP_LUCI_SHA256='58a5a3e1decf8de5a988ae19ef7594aebf8716abaaa26a2cc169c377903e29e7'
FORKOP_I18N='luci-i18n-forkop-ru_1.0.5.apk'
FORKOP_I18N_SHA256='9c124fd2a11e0a4dd1e2492e3685fec0d8dfe8600a3d5aa28fa14f9d0e008ceb'

PODKOP_BACKEND='podkop-0.7.22-r1.apk'
PODKOP_BACKEND_SHA256='5abf1422f73819d0834fd3ca81ccd55aaa7631e8665dc03e8c0d629811302e27'
PODKOP_LUCI='luci-app-podkop-0.7.22-r1.apk'
PODKOP_LUCI_SHA256='72addad80b71a9f44ea64af011c24b405c98b7a2b94751166a5668deeab7ad53'
PODKOP_I18N='luci-i18n-podkop-ru-0.7.22.apk'
PODKOP_I18N_SHA256='8977ce5f659b0cafefbcc7ae9f549c6eddf6a95fbfeac934e418b033bcda414a'

FORKOP_RELEASE_BASE='https://github.com/ushan0v/forkop/releases/download/1.0.5'
PODKOP_RELEASE_BASE='https://github.com/itdoginfo/podkop/releases/download/0.7.22'
PPTP_PACKAGES='kmod-gre kmod-pptp ppp-mod-pptp kmod-nf-nathelper kmod-nf-nathelper-extra tcpdump'
PPTP_MODULES='gre ip_gre nf_conntrack_pptp nf_nat_pptp pptp pppox ppp_generic'

ROOT="${MOMEN_ROOT:-}"
BACKUP_PARENT="${MOMEN_BACKUP_PARENT:-$(printf '%s' "$ROOT")/root}"
ASSET_SOURCE_DIR="${MOMEN_ASSET_SOURCE_DIR:-}"
SKIP_RUNTIME_CHECKS="${MOMEN_SKIP_RUNTIME_CHECKS:-0}"
TEST_MODE="${MOMEN_TEST_MODE:-0}"

MODE=''
ROLLBACK_DIR=''
WORK_DIR=''
BACKUP_DIR=''
MUTATION_STARTED=0
APPLY_COMPLETE=0
PODKOP_WAS_ENABLED=0
PODKOP_WAS_RUNNING=0
PODKOP_I18N_INSTALLED=0
DOWNLOAD_PROXY_SECTION=''
PPTP_PREEXISTING_PACKAGES=''

path() {
    printf '%s%s\n' "$ROOT" "$1"
}

info() {
    printf '%s\n' "$1"
}

warn() {
    printf 'WARNING: %s\n' "$1" >&2
}

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: $0 MODE

Modes:
  --audit                 Read-only compatibility and source-state audit.
  --plan                  Audit, download and verify pinned packages, then run
                          apk installation/removal simulations. No persistent changes.
  --apply                 Plan, create a local backup, migrate Podkop 0.7.22 to
                          Forkop 1.0.5, verify Forkop, then remove Podkop packages.
  --verify                Verify an already completed migration.
  --rollback BACKUP_DIR   Remove Forkop and restore Podkop from a backup created
                          by this script.
  --help                  Show this help.

The script supports OpenWrt 25.12.2 with apk only. It never uploads configuration
or backup data. Backups stay on the router with mode 0700/0600.
EOF
}

parse_args() {
    [ "$#" -gt 0 ] || {
        usage >&2
        exit 2
    }

    case "$1" in
    --audit|--plan|--apply|--verify)
        MODE="$1"
        [ "$#" -eq 1 ] || fail "$1 does not accept additional arguments"
        ;;
    --rollback)
        [ "$#" -eq 2 ] || fail '--rollback requires exactly one BACKUP_DIR'
        MODE="$1"
        ROLLBACK_DIR="$2"
        ;;
    --help|-h)
        usage
        exit 0
        ;;
    *)
        fail "unsupported argument: $1"
        ;;
    esac
}

cleanup() {
    [ -z "$WORK_DIR" ] || rm -rf "$WORK_DIR"
}

auto_rollback_on_failure() {
    status=$?
    cleanup

    if [ "$status" -ne 0 ] && [ "$MUTATION_STARTED" -eq 1 ] && [ "$APPLY_COMPLETE" -eq 0 ] && [ -n "$BACKUP_DIR" ]; then
        warn 'migration failed after changes started; automatic rollback is starting'
        if rollback_from_backup "$BACKUP_DIR"; then
            warn "automatic rollback completed; backup retained at $BACKUP_DIR"
        else
            warn "automatic rollback failed; preserve the router and use: ash $0 --rollback $BACKUP_DIR"
        fi
    fi

    exit "$status"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

require_root() {
    if command -v id >/dev/null 2>&1 && [ "$(id -u)" != '0' ]; then
        fail 'run this script as root'
    fi
}

init_work_dir() {
    [ -z "$WORK_DIR" ] || return 0
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/momen-forkop.XXXXXX")" || fail 'cannot create temporary directory'
    chmod 0700 "$WORK_DIR"
}

package_installed() {
    apk info -e "$1" >/dev/null 2>&1
}

installed_package_record() {
    apk list --installed "$1" 2>/dev/null | awk '{ print $1; exit }'
}

service_enabled() {
    service_path="$1"
    [ -x "$service_path" ] && "$service_path" enabled >/dev/null 2>&1
}

service_running() {
    service_path="$1"
    [ -x "$service_path" ] || return 1
    "$service_path" running >/dev/null 2>&1 && return 0
    [ "$("$service_path" status 2>/dev/null || true)" = 'running' ]
}

forkop_status_running() {
    printf '%s' "$1" | grep -Eq '"running"[[:space:]]*:[[:space:]]*1([[:space:],}]|$)'
}

uci_get() {
    uci -q get "$1" 2>/dev/null || true
}

uci_list_contains() {
    uci_path="$1"
    expected="$2"
    for value in $(uci_get "$uci_path"); do
        [ "$value" = "$expected" ] && return 0
    done
    return 1
}

word_count() {
    printf '%s\n' "$1" | awk '{ for (i = 1; i <= NF; i++) count++ } END { print count + 0 }'
}

word_list_contains() {
    list="$1"
    expected="$2"
    for value in $list; do
        [ "$value" = "$expected" ] && return 0
    done
    return 1
}

read_podkop_version() {
    constants_file="$(path /usr/lib/podkop/constants.sh)"
    [ -r "$constants_file" ] || return 1
    sed -n 's/^PODKOP_VERSION="\([^"]*\)".*/\1/p' "$constants_file" | head -n 1 | sed 's/^v//'
}

validate_section_name() {
    case "$1" in
    ''|*[!A-Za-z0-9_-]*) return 1 ;;
    *) return 0 ;;
    esac
}

audit_platform() {
    release_file="$(path /etc/openwrt_release)"
    os_release_file="$(path /etc/os-release)"
    [ -r "$release_file" ] || fail "OpenWrt release metadata is unavailable: $release_file"

    # shellcheck disable=SC1090
    . "$release_file"
    os_id=''
    if [ -r "$os_release_file" ]; then
        # shellcheck disable=SC1090
        os_id="$(. "$os_release_file"; printf '%s' "${ID:-}")"
    fi

    [ "${DISTRIB_ID:-}" = 'OpenWrt' ] || [ "$os_id" = 'openwrt' ] ||
        fail "unsupported firmware identity (DISTRIB_ID=${DISTRIB_ID:-unknown}, ID=${os_id:-unknown})"

    [ "${DISTRIB_RELEASE:-}" = "$SUPPORTED_OPENWRT_VERSION" ] ||
        fail "OpenWrt $SUPPORTED_OPENWRT_VERSION is required (found ${DISTRIB_RELEASE:-unknown})"

    info "OPENWRT_VERSION=${DISTRIB_RELEASE}"
    info 'PACKAGE_MANAGER=apk'
    info "MIGRATION_SCRIPT_VERSION=$SCRIPT_VERSION"
}

audit_space() {
    filesystem_path='/'
    [ ! -d "$(path /overlay)" ] || filesystem_path="$(path /overlay)"
    [ "$filesystem_path" != '/' ] || filesystem_path="${ROOT:-/}"
    available_kb="$(df -Pk "$filesystem_path" | awk 'NR == 2 { print $4 }')"
    required_kb='32768'
    case "$available_kb" in
    ''|*[!0-9]*) fail 'cannot determine free space' ;;
    esac
    [ "$available_kb" -ge "$required_kb" ] ||
        fail "insufficient free space (required_kb=$required_kb available_kb=$available_kb)"
    info "FREE_SPACE_KB=$available_kb"
    info "REQUIRED_FREE_SPACE_KB=$required_kb"
}

audit_source_config() {
    podkop_config="$(path /etc/config/podkop)"
    podkop_init="$(path /etc/init.d/podkop)"
    podkop_bin="$(path /usr/bin/podkop)"
    tld_file="$(path /etc/momen-r1-cyrillic-tlds.lst)"

    [ -r "$podkop_config" ] || fail 'Podkop configuration is unavailable'
    [ -x "$podkop_init" ] || fail 'Podkop init script is unavailable'
    [ -x "$podkop_bin" ] || fail 'Podkop executable is unavailable'

    podkop_version="$(read_podkop_version || true)"
    [ "$podkop_version" = "$SUPPORTED_PODKOP_VERSION" ] ||
        fail "Podkop $SUPPORTED_PODKOP_VERSION is required (found ${podkop_version:-unknown})"

    podkop_package="$(installed_package_record podkop)"
    [ "$podkop_package" = "$SUPPORTED_PODKOP_PACKAGE" ] ||
        fail "exact package $SUPPORTED_PODKOP_PACKAGE is required (found ${podkop_package:-missing})"
    package_installed luci-app-podkop || fail 'luci-app-podkop is not installed'

    [ "$(uci_get podkop.settings.dns_type)" = 'doh' ] || fail 'Podkop DNS type must be doh'
    [ "$(uci_get podkop.settings.dns_server)" = 'common.dot.dns.yandex.net' ] ||
        fail 'Podkop DNS server must be common.dot.dns.yandex.net'
    [ "$(uci_get podkop.settings.bootstrap_dns_server)" = '77.88.8.8' ] ||
        fail 'Podkop bootstrap DNS server must be 77.88.8.8'

    [ "$(uci_get podkop.DIRECT)" = 'section' ] || fail 'managed Podkop DIRECT section is missing'
    [ "$(uci_get podkop.DIRECT.connection_type)" = 'exclusion' ] ||
        fail 'Podkop DIRECT section must use connection_type=exclusion'
    [ "$(uci_get podkop.DIRECT.managed_by)" = 'vless-podkop-v3' ] ||
        fail 'Podkop DIRECT section is not managed by the audited momen installer'
    [ "$(uci_get podkop.DIRECT.user_domain_list_type)" = 'text' ] ||
        fail 'Podkop DIRECT section must use the text domain list'

    direct_text="$(uci_get podkop.DIRECT.user_domains_text)"
    direct_text_count="$(word_count "$direct_text")"
    [ "$direct_text_count" -eq 720 ] ||
        fail "Podkop DIRECT text catalog must contain 720 domains (found $direct_text_count)"
    uci_list_contains podkop.DIRECT.local_domain_lists '/etc/momen-r1-cyrillic-tlds.lst' ||
        fail 'Podkop DIRECT section does not reference the Cyrillic TLD list'
    [ -r "$tld_file" ] || fail 'Cyrillic TLD list is unavailable'
    tld_count="$(sed '/^[[:space:]]*$/d' "$tld_file" | wc -l | tr -d '[:space:]')"
    [ "$tld_count" -eq 4 ] || fail "Cyrillic TLD list must contain 4 entries (found $tld_count)"

    [ "$(uci_get podkop.settings.download_lists_via_proxy)" = '1' ] ||
        fail 'Podkop list downloads are not configured through a connection section'
    DOWNLOAD_PROXY_SECTION="$(uci_get podkop.settings.download_lists_via_proxy_section)"
    validate_section_name "$DOWNLOAD_PROXY_SECTION" || fail 'invalid Podkop download proxy section name'
    [ "$(uci_get "podkop.$DOWNLOAD_PROXY_SECTION")" = 'section' ] ||
        fail "Podkop download proxy section does not exist: $DOWNLOAD_PROXY_SECTION"
    source_connection_type="$(uci_get "podkop.$DOWNLOAD_PROXY_SECTION.connection_type")"
    case "$source_connection_type" in
    proxy|vpn) ;;
    *) fail "Podkop download proxy section must be proxy or vpn (found ${source_connection_type:-unknown})" ;;
    esac

    PODKOP_I18N_INSTALLED=0
    package_installed luci-i18n-podkop-ru && PODKOP_I18N_INSTALLED=1
    PODKOP_WAS_ENABLED=0
    PODKOP_WAS_RUNNING=0
    service_enabled "$podkop_init" && PODKOP_WAS_ENABLED=1
    service_running "$podkop_init" && PODKOP_WAS_RUNNING=1
    PPTP_PREEXISTING_PACKAGES=''
    pptp_preexisting_count=0
    for package_name in $PPTP_PACKAGES; do
        if package_installed "$package_name"; then
            PPTP_PREEXISTING_PACKAGES="$PPTP_PREEXISTING_PACKAGES $package_name"
            pptp_preexisting_count=$((pptp_preexisting_count + 1))
        fi
    done
    PPTP_PREEXISTING_PACKAGES="${PPTP_PREEXISTING_PACKAGES# }"

    info "PODKOP_VERSION=$podkop_version"
    info "PODKOP_PACKAGE=$podkop_package"
    info "PODKOP_SERVICE_ENABLED=$PODKOP_WAS_ENABLED"
    info "PODKOP_SERVICE_RUNNING=$PODKOP_WAS_RUNNING"
    info "PODKOP_I18N_INSTALLED=$PODKOP_I18N_INSTALLED"
    info "DIRECT_TEXT_DOMAINS=$direct_text_count"
    info "DIRECT_TLD_DOMAINS=$tld_count"
    info "DOWNLOAD_PROXY_SECTION=$DOWNLOAD_PROXY_SECTION"
    info "PPTP_SUPPORT_PACKAGES_PRESENT=$pptp_preexisting_count"
    info 'SOURCE_CONFIG_COMPATIBLE=true'
}

audit_current_state() {
    for command_name in apk ash awk chmod cp cut date df grep head mktemp mkdir rm sed sha256sum tar tr uci wc wget; do
        require_command "$command_name"
    done
    require_root
    audit_platform
    audit_space

    if package_installed forkop || package_installed luci-app-forkop; then
        if ! package_installed podkop && ! package_installed luci-app-podkop; then
            info 'ALREADY_MIGRATED=true'
            return 10
        fi
        fail 'both Podkop and Forkop packages are present; use --verify or restore a known backup before retrying'
    fi

    audit_source_config
    info 'AUDIT_RESULT=compatible'
}

asset_hash() {
    case "$1" in
    "$FORKOP_BACKEND") printf '%s\n' "$FORKOP_BACKEND_SHA256" ;;
    "$FORKOP_LUCI") printf '%s\n' "$FORKOP_LUCI_SHA256" ;;
    "$FORKOP_I18N") printf '%s\n' "$FORKOP_I18N_SHA256" ;;
    "$PODKOP_BACKEND") printf '%s\n' "$PODKOP_BACKEND_SHA256" ;;
    "$PODKOP_LUCI") printf '%s\n' "$PODKOP_LUCI_SHA256" ;;
    "$PODKOP_I18N") printf '%s\n' "$PODKOP_I18N_SHA256" ;;
    *) return 1 ;;
    esac
}

asset_base_url() {
    case "$1" in
    "$FORKOP_BACKEND"|"$FORKOP_LUCI"|"$FORKOP_I18N") printf '%s\n' "$FORKOP_RELEASE_BASE" ;;
    "$PODKOP_BACKEND"|"$PODKOP_LUCI"|"$PODKOP_I18N") printf '%s\n' "$PODKOP_RELEASE_BASE" ;;
    *) return 1 ;;
    esac
}

copy_or_download_asset() {
    name="$1"
    destination="$2"
    expected_hash="$(asset_hash "$name")" || fail "unknown asset: $name"

    if [ "$TEST_MODE" = '1' ] && [ -n "${MOMEN_TEST_EXPECTED_SHA256:-}" ]; then
        expected_hash="$MOMEN_TEST_EXPECTED_SHA256"
    fi

    if [ -n "$ASSET_SOURCE_DIR" ]; then
        [ -r "$ASSET_SOURCE_DIR/$name" ] || fail "local asset is unavailable: $ASSET_SOURCE_DIR/$name"
        cp "$ASSET_SOURCE_DIR/$name" "$destination"
    else
        base_url="$(asset_base_url "$name")"
        wget -q -T 20 -O "$destination" "$base_url/$name" || fail "download failed: $base_url/$name"
    fi

    actual_hash="$(sha256sum "$destination" | awk '{ print $1 }')"
    [ "$actual_hash" = "$expected_hash" ] ||
        fail "SHA-256 mismatch for $name (expected=$expected_hash actual=$actual_hash)"
    info "ASSET_VERIFIED=$name"
}

prepare_assets() {
    init_work_dir
    asset_dir="$WORK_DIR/assets"
    mkdir -p "$asset_dir"

    for name in "$FORKOP_BACKEND" "$FORKOP_LUCI" "$PODKOP_BACKEND" "$PODKOP_LUCI"; do
        copy_or_download_asset "$name" "$asset_dir/$name"
    done
    if [ "$PODKOP_I18N_INSTALLED" -eq 1 ]; then
        copy_or_download_asset "$FORKOP_I18N" "$asset_dir/$FORKOP_I18N"
        copy_or_download_asset "$PODKOP_I18N" "$asset_dir/$PODKOP_I18N"
    fi
}

forkop_asset_arguments() {
    printf '%s\n' "$WORK_DIR/assets/$FORKOP_BACKEND"
    printf '%s\n' "$WORK_DIR/assets/$FORKOP_LUCI"
    [ "$PODKOP_I18N_INSTALLED" -eq 0 ] || printf '%s\n' "$WORK_DIR/assets/$FORKOP_I18N"
}

podkop_installed_packages() {
    printf '%s\n' podkop luci-app-podkop
    [ "$PODKOP_I18N_INSTALLED" -eq 0 ] || printf '%s\n' luci-i18n-podkop-ru
}

simulate_transactions() {
    # Word splitting is intentional: the lists contain validated local paths/package names only.
    # shellcheck disable=SC2046
    apk add --simulate --allow-untrusted $(forkop_asset_arguments) </dev/null >/dev/null ||
        fail 'Forkop installation simulation failed'
    # shellcheck disable=SC2046
    apk del --simulate $(podkop_installed_packages) </dev/null >/dev/null ||
        fail 'Podkop removal simulation failed'
    # shellcheck disable=SC2086
    apk add --simulate $PPTP_PACKAGES </dev/null >/dev/null ||
        fail 'PPTP/GRE support package installation simulation failed'
    info 'FORKOP_INSTALL_SIMULATION=passed'
    info 'PODKOP_REMOVE_SIMULATION=passed'
    info 'PPTP_SUPPORT_INSTALL_SIMULATION=passed'
}

run_plan() {
    if audit_current_state; then
        :
    else
        audit_status=$?
        [ "$audit_status" -ne 10 ] || return 10
        return "$audit_status"
    fi
    prepare_assets
    simulate_transactions
    info 'PLAN_RESULT=ready'
}

backup_manifest_add() {
    manifest="$1"
    absolute="$2"
    [ -e "$(path "$absolute")" ] || return 0
    printf '%s\n' "${absolute#/}" >> "$manifest"
}

create_backup() {
    timestamp="$(date +%Y%m%d-%H%M%S)"
    BACKUP_DIR="$BACKUP_PARENT/momen-podkop-to-forkop-$timestamp"
    [ ! -e "$BACKUP_DIR" ] || BACKUP_DIR="$BACKUP_DIR.$$"
    mkdir -p "$BACKUP_DIR/packages"
    chmod 0700 "$BACKUP_DIR" "$BACKUP_DIR/packages"

    cp "$WORK_DIR/assets/$PODKOP_BACKEND" "$BACKUP_DIR/packages/$PODKOP_BACKEND"
    cp "$WORK_DIR/assets/$PODKOP_LUCI" "$BACKUP_DIR/packages/$PODKOP_LUCI"
    if [ "$PODKOP_I18N_INSTALLED" -eq 1 ]; then
        cp "$WORK_DIR/assets/$PODKOP_I18N" "$BACKUP_DIR/packages/$PODKOP_I18N"
    fi
    chmod 0600 "$BACKUP_DIR"/packages/*

    manifest="$BACKUP_DIR/snapshot-files.txt"
    : > "$manifest"
    for backup_path in \
        /etc/config/podkop \
        /etc/config/dhcp \
        /etc/apk/world \
        /etc/init.d/podkop \
        /etc/momen-r1-cyrillic-tlds.lst \
        /usr/bin/podkop \
        /usr/lib/podkop \
        /www/luci-static/resources/view/podkop \
        /usr/share/luci/menu.d/luci-app-podkop.json \
        /usr/share/rpcd/acl.d/luci-app-podkop.json; do
        backup_manifest_add "$manifest" "$backup_path"
    done
    [ -s "$manifest" ] || fail 'backup manifest is empty'

    archive="$BACKUP_DIR/podkop-snapshot.tar.gz"
    tar -C "${ROOT:-/}" -czf "$archive" -T "$manifest" || fail 'failed to create Podkop snapshot'
    chmod 0600 "$archive" "$manifest"
    sha256sum "$archive" > "$BACKUP_DIR/podkop-snapshot.tar.gz.sha256"
    chmod 0600 "$BACKUP_DIR/podkop-snapshot.tar.gz.sha256"

    cat > "$BACKUP_DIR/state.env" <<EOF
BACKUP_FORMAT=1
PODKOP_VERSION=$SUPPORTED_PODKOP_VERSION
PODKOP_PACKAGE=$SUPPORTED_PODKOP_PACKAGE
PODKOP_WAS_ENABLED=$PODKOP_WAS_ENABLED
PODKOP_WAS_RUNNING=$PODKOP_WAS_RUNNING
PODKOP_I18N_INSTALLED=$PODKOP_I18N_INSTALLED
DOWNLOAD_PROXY_SECTION=$DOWNLOAD_PROXY_SECTION
PPTP_PREEXISTING_PACKAGES='$PPTP_PREEXISTING_PACKAGES'
EOF
    chmod 0600 "$BACKUP_DIR/state.env"

    apk list --installed > "$BACKUP_DIR/packages.before.txt"
    chmod 0600 "$BACKUP_DIR/packages.before.txt"
    info "BACKUP_DIR=$BACKUP_DIR"
    info 'BACKUP_CREATED=true'
}

verify_pptp_support() {
    for package_name in $PPTP_PACKAGES; do
        package_installed "$package_name" || fail "PPTP/GRE support package is missing: $package_name"
    done

    if [ "$SKIP_RUNTIME_CHECKS" != '1' ]; then
        require_command modprobe
        require_command lsmod
        for module_name in $PPTP_MODULES; do
            modprobe "$module_name" >/dev/null 2>&1 || fail "kernel module cannot be loaded: $module_name"
        done
        loaded_modules="$(lsmod)"
        for module_name in $PPTP_MODULES; do
            printf '%s\n' "$loaded_modules" | awk -v module="$module_name" '$1 == module { found=1 } END { exit !found }' ||
                fail "kernel module is not loaded: $module_name"
        done
        info 'PPTP_KERNEL_MODULES_VALID=true'
    else
        info 'PPTP_KERNEL_MODULES_VALID=skipped'
    fi
    info 'PPTP_SUPPORT_VALID=true'
}

install_and_verify_pptp_support() {
    # Package names are fixed constants defined by this script.
    # shellcheck disable=SC2086
    apk add $PPTP_PACKAGES </dev/null || fail 'PPTP/GRE support package installation failed'
    info 'PPTP_SUPPORT_PACKAGES_INSTALLED=true'
    verify_pptp_support
}

restore_podkop_dnsmasq() {
    podkop_bin="$(path /usr/bin/podkop)"
    if [ -x "$podkop_bin" ]; then
        "$podkop_bin" restore_dnsmasq >/dev/null 2>&1 ||
            "$podkop_bin" dnsmasq_restore >/dev/null 2>&1 ||
            warn 'Podkop did not confirm dnsmasq restoration; the DHCP config backup is retained'
    fi
}

deactivate_podkop() {
    podkop_init="$(path /etc/init.d/podkop)"
    "$podkop_init" stop >/dev/null 2>&1 || fail 'failed to stop Podkop'
    restore_podkop_dnsmasq
    "$podkop_init" disable >/dev/null 2>&1 || fail 'failed to disable Podkop autostart'
    info 'PODKOP_DEACTIVATED=true'
}

install_forkop_packages() {
    # shellcheck disable=SC2046
    apk add --allow-untrusted $(forkop_asset_arguments) </dev/null || fail 'Forkop package installation failed'
    package_installed forkop || fail 'forkop package is missing after installation'
    package_installed luci-app-forkop || fail 'luci-app-forkop package is missing after installation'
    if [ "$PODKOP_I18N_INSTALLED" -eq 1 ]; then
        package_installed luci-i18n-forkop-ru || fail 'Forkop Russian translation package is missing'
    fi
    info "FORKOP_VERSION=$FORKOP_VERSION"
    info 'FORKOP_PACKAGES_INSTALLED=true'
}

preserve_sing_box_package() {
    package_installed sing-box || fail 'Podkop sing-box package is missing before migration'
    # Podkop owns sing-box as a dependency. Mark it explicitly in apk world so
    # apk del podkop cannot autoremove Forkop's already validated runtime.
    apk add sing-box </dev/null || fail 'failed to preserve sing-box for Forkop'
    package_installed sing-box || fail 'sing-box package disappeared during preservation'
    info 'SING_BOX_PACKAGE_PRESERVED=true'
}

migrate_configuration() {
    podkop_config="$(path /etc/config/podkop)"
    forkop_config="$(path /etc/config/forkop)"
    forkop_lib="$(path /usr/lib/forkop)"
    migration="$forkop_lib/config/migration.uc"

    require_command ucode
    [ -r "$migration" ] || fail 'Forkop migration module is unavailable'
    cp "$podkop_config" "$forkop_config"
    chmod 0600 "$forkop_config"

    FORKOP_CONFIG_NAME='forkop' FORKOP_LIB="$forkop_lib" \
        ucode -L "$forkop_lib" "$migration" migrate-podkop || fail 'Forkop rejected the Podkop configuration migration'
    chmod 0600 "$forkop_config"
    info 'CONFIG_MIGRATED=true'
}

normalize_forkop_direct_catalog() {
    tld_file="$(path /etc/momen-r1-cyrillic-tlds.lst)"
    direct_text="$(uci_get forkop.DIRECT.user_domains_text)"
    direct_text_count="$(word_count "$direct_text")"
    [ "$direct_text_count" -eq 720 ] ||
        fail "Forkop legacy DIRECT text catalog count is $direct_text_count, expected 720"
    [ -r "$tld_file" ] || fail 'Cyrillic TLD list is unavailable during Forkop normalization'
    tld_domains="$(sed '/^[[:space:]]*$/d' "$tld_file" | tr '\n' ' ')"
    tld_count="$(word_count "$tld_domains")"
    [ "$tld_count" -eq 4 ] || fail "Forkop Cyrillic TLD catalog count is $tld_count, expected 4"

    # Forkop 1.0.5 preserves these Podkop options during migration, but its
    # runtime rejects local_domain_lists and does not consume user_domains_text.
    # Move all 724 suffixes to Forkop's supported combined domain field.
    uci set "forkop.DIRECT.domain=$direct_text $tld_domains"
    uci -q delete forkop.DIRECT.user_domains_text || true
    uci -q delete forkop.DIRECT.user_domain_list_type || true
    uci -q delete forkop.DIRECT.local_domain_lists || true
    uci commit forkop
    info 'FORKOP_DIRECT_CATALOG_NORMALIZED=true'
    info 'FORKOP_DIRECT_DOMAIN_COUNT=724'
}

validate_forkop_config() {
    forkop_config="$(path /etc/config/forkop)"
    tld_file="$(path /etc/momen-r1-cyrillic-tlds.lst)"
    [ -r "$forkop_config" ] || fail 'Forkop configuration is unavailable'
    [ "$(uci_get forkop.settings.dns_type)" = 'doh' ] || fail 'Forkop DNS type validation failed'
    uci_list_contains forkop.settings.dns_server 'common.dot.dns.yandex.net' ||
        fail 'Forkop Yandex DoH server validation failed'
    uci_list_contains forkop.settings.bootstrap_dns_server '77.88.8.8' ||
        fail 'Forkop bootstrap DNS validation failed'
    [ "$(uci_get forkop.DIRECT)" = 'section' ] || fail 'Forkop DIRECT section is missing'
    [ "$(uci_get forkop.DIRECT.action)" = 'bypass' ] || fail 'Forkop DIRECT action must be bypass'
    [ -z "$(uci_get forkop.DIRECT.user_domains_text)" ] ||
        fail 'Forkop DIRECT still contains the unsupported Podkop user_domains_text option'
    [ -z "$(uci_get forkop.DIRECT.local_domain_lists)" ] ||
        fail 'Forkop DIRECT still contains the unsupported local_domain_lists matcher'
    direct_domain_count="$(word_count "$(uci_get forkop.DIRECT.domain)")"
    [ "$direct_domain_count" -eq 724 ] || fail "Forkop DIRECT catalog count is $direct_domain_count, expected 724"
    tld_count="$(sed '/^[[:space:]]*$/d' "$tld_file" | wc -l | tr -d '[:space:]')"
    [ "$tld_count" -eq 4 ] || fail 'Forkop Cyrillic TLD catalog validation failed'
    while IFS= read -r tld_domain; do
        [ -z "$tld_domain" ] || uci_list_contains forkop.DIRECT.domain "$tld_domain" ||
            fail "Forkop DIRECT catalog lost Cyrillic TLD: $tld_domain"
    done < "$tld_file"
    [ "$(uci_get forkop.settings.download_lists_via_proxy)" = '1' ] ||
        fail 'Forkop list download routing validation failed'
    migrated_download_section="$(uci_get forkop.settings.download_lists_via_proxy_section)"
    [ "$migrated_download_section" = "$DOWNLOAD_PROXY_SECTION" ] ||
        fail 'Forkop download proxy section name changed unexpectedly'
    [ "$(uci_get "forkop.$DOWNLOAD_PROXY_SECTION")" = 'section' ] ||
        fail 'Forkop connection section is missing after migration'
    [ "$(uci_get "forkop.$DOWNLOAD_PROXY_SECTION.action")" = 'connection' ] ||
        fail 'Forkop proxy/VPN section was not converted to action=connection'
    info 'FORKOP_CONFIG_VALID=true'
    info "DIRECT_DOMAINS=$direct_domain_count"
}

activate_and_verify_forkop() {
    forkop_init="$(path /etc/init.d/forkop)"
    forkop_bin="$(path /usr/bin/forkop)"
    [ -x "$forkop_init" ] || fail 'Forkop init script is unavailable'
    [ -x "$forkop_bin" ] || fail 'Forkop executable is unavailable'

    if [ "$PODKOP_WAS_ENABLED" -eq 1 ]; then
        "$forkop_init" enable >/dev/null 2>&1 || fail 'failed to enable Forkop autostart'
    else
        "$forkop_init" disable >/dev/null 2>&1 || fail 'failed to disable Forkop autostart'
    fi
    "$forkop_init" start >/dev/null 2>&1 || "$forkop_init" restart >/dev/null 2>&1 ||
        fail 'failed to start Forkop'
    "$forkop_bin" reload >/dev/null 2>&1 || fail 'Forkop reload failed'
    status_output="$($forkop_bin get_status 2>/dev/null || true)"
    forkop_status_running "$status_output" || fail 'Forkop does not report running state'
    if [ "$SKIP_RUNTIME_CHECKS" != '1' ]; then
        require_command nslookup
        nslookup ya.ru 127.0.0.1 >/dev/null 2>&1 || fail 'post-migration DNS lookup failed'
    fi
    if [ "$PODKOP_WAS_RUNNING" -eq 0 ]; then
        "$forkop_init" stop >/dev/null 2>&1 || fail 'failed to restore stopped service state'
    fi
    info 'FORKOP_RUNTIME_VALID=true'
}

remove_podkop_packages() {
    # shellcheck disable=SC2046
    apk del $(podkop_installed_packages) </dev/null || fail 'Podkop package removal failed'
    package_installed podkop && fail 'podkop package is still installed'
    package_installed luci-app-podkop && fail 'luci-app-podkop package is still installed'
    info 'PODKOP_PACKAGES_REMOVED=true'
}

verify_completed_migration() {
    package_installed forkop || fail 'forkop package is not installed'
    package_installed luci-app-forkop || fail 'luci-app-forkop package is not installed'
    package_installed sing-box || fail 'sing-box package is not installed for Forkop'
    package_installed podkop && fail 'podkop package is still installed'
    package_installed luci-app-podkop && fail 'luci-app-podkop package is still installed'
    verify_pptp_support

    DOWNLOAD_PROXY_SECTION="$(uci_get forkop.settings.download_lists_via_proxy_section)"
    validate_section_name "$DOWNLOAD_PROXY_SECTION" || fail 'Forkop download proxy section is invalid'
    validate_forkop_config

    forkop_init="$(path /etc/init.d/forkop)"
    forkop_bin="$(path /usr/bin/forkop)"
    [ -x "$forkop_init" ] || fail 'Forkop init script is unavailable'
    [ -x "$forkop_bin" ] || fail 'Forkop executable is unavailable'
    if service_running "$forkop_init"; then
        status_output="$($forkop_bin get_status 2>/dev/null || true)"
        forkop_status_running "$status_output" || fail 'Forkop backend status validation failed'
        info 'FORKOP_SERVICE_RUNNING=true'
    else
        info 'FORKOP_SERVICE_RUNNING=false'
    fi
    info 'VERIFY_RESULT=passed'
}

run_apply() {
    if run_plan; then
        :
    else
        plan_status=$?
        if [ "$plan_status" -eq 10 ]; then
            verify_completed_migration
            info 'APPLY_RESULT=already-migrated'
            return 0
        fi
        return "$plan_status"
    fi

    create_backup
    MUTATION_STARTED=1
    install_and_verify_pptp_support
    deactivate_podkop
    install_forkop_packages
    preserve_sing_box_package
    migrate_configuration
    normalize_forkop_direct_catalog
    validate_forkop_config
    activate_and_verify_forkop
    remove_podkop_packages
    verify_completed_migration
    APPLY_COMPLETE=1
    info "ROLLBACK_COMMAND=ash $0 --rollback $BACKUP_DIR"
    info 'APPLY_RESULT=migrated'
}

safe_backup_dir() {
    candidate="$1"
    [ -n "$candidate" ] || return 1
    [ -d "$candidate" ] || return 1
    case "$candidate" in
    "$BACKUP_PARENT"/momen-podkop-to-forkop-*) return 0 ;;
    *) return 1 ;;
    esac
}

rollback_from_backup() {
    candidate="$1"
    safe_backup_dir "$candidate" || {
        warn "refusing unexpected backup path: $candidate"
        return 1
    }
    [ -r "$candidate/state.env" ] || return 1
    [ -r "$candidate/podkop-snapshot.tar.gz" ] || return 1
    [ -r "$candidate/podkop-snapshot.tar.gz.sha256" ] || return 1
    (cd "$candidate" && sha256sum -c podkop-snapshot.tar.gz.sha256 >/dev/null) || return 1

    # state.env is generated by create_backup with validated scalar values only.
    # shellcheck disable=SC1091
    . "$candidate/state.env"
    [ "${BACKUP_FORMAT:-}" = '1' ] || return 1
    [ "${PODKOP_VERSION:-}" = "$SUPPORTED_PODKOP_VERSION" ] || return 1

    forkop_init="$(path /etc/init.d/forkop)"
    [ ! -x "$forkop_init" ] || "$forkop_init" stop >/dev/null 2>&1 || true
    if [ -e "$(path /etc/config/forkop)" ]; then
        cp "$(path /etc/config/forkop)" "$candidate/forkop-config.before-rollback"
        chmod 0600 "$candidate/forkop-config.before-rollback"
    fi

    forkop_packages=''
    package_installed luci-i18n-forkop-ru && forkop_packages="$forkop_packages luci-i18n-forkop-ru"
    package_installed luci-app-forkop && forkop_packages="$forkop_packages luci-app-forkop"
    package_installed forkop && forkop_packages="$forkop_packages forkop"
    if [ -n "$forkop_packages" ]; then
        # shellcheck disable=SC2086
        apk del $forkop_packages </dev/null || return 1
    fi

    podkop_assets="$candidate/packages/$PODKOP_BACKEND $candidate/packages/$PODKOP_LUCI"
    if [ "${PODKOP_I18N_INSTALLED:-0}" = '1' ]; then
        podkop_assets="$podkop_assets $candidate/packages/$PODKOP_I18N"
    fi
    # shellcheck disable=SC2086
    apk add --allow-untrusted $podkop_assets </dev/null || return 1
    tar -C "${ROOT:-/}" -xzf "$candidate/podkop-snapshot.tar.gz" || return 1

    pptp_added_packages=''
    for package_name in $PPTP_PACKAGES; do
        if ! word_list_contains "${PPTP_PREEXISTING_PACKAGES:-}" "$package_name" && package_installed "$package_name"; then
            pptp_added_packages="$pptp_added_packages $package_name"
        fi
    done
    if [ -n "$pptp_added_packages" ]; then
        # shellcheck disable=SC2086
        apk del $pptp_added_packages </dev/null || return 1
    fi

    podkop_init="$(path /etc/init.d/podkop)"
    if [ "${PODKOP_WAS_ENABLED:-0}" = '1' ]; then
        "$podkop_init" enable >/dev/null 2>&1 || return 1
    else
        "$podkop_init" disable >/dev/null 2>&1 || true
    fi
    if [ "${PODKOP_WAS_RUNNING:-0}" = '1' ]; then
        "$podkop_init" restart >/dev/null 2>&1 || "$podkop_init" start >/dev/null 2>&1 || return 1
    else
        "$podkop_init" stop >/dev/null 2>&1 || true
    fi

    package_installed podkop || return 1
    package_installed luci-app-podkop || return 1
    info 'ROLLBACK_RESULT=restored'
    return 0
}

run_rollback() {
    for command_name in apk cp sha256sum tar; do
        require_command "$command_name"
    done
    require_root
    rollback_from_backup "$ROLLBACK_DIR" || fail 'rollback did not complete'
}

main() {
    parse_args "$@"
    trap cleanup EXIT

    case "$MODE" in
    --audit)
        if audit_current_state; then
            :
        else
            status=$?
            [ "$status" -eq 10 ] || return "$status"
            verify_completed_migration
        fi
        ;;
    --plan)
        if run_plan; then
            :
        else
            status=$?
            if [ "$status" -eq 10 ]; then
                verify_completed_migration
                info 'PLAN_RESULT=already-migrated'
            else
                return "$status"
            fi
        fi
        ;;
    --apply)
        trap auto_rollback_on_failure EXIT
        run_apply
        cleanup
        trap - EXIT
        ;;
    --verify)
        for command_name in apk awk grep sed tr uci wc; do
            require_command "$command_name"
        done
        require_root
        verify_completed_migration
        ;;
    --rollback)
        run_rollback
        ;;
    esac
}

main "$@"
