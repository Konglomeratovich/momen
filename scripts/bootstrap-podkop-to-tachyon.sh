#!/bin/sh
set -eu

# Public entry point for the guarded Podkop 0.7.22 -> Tachyon 1.7.11
# transaction. It intentionally separates backup preparation from Apply so an
# operator can copy the rollback bundle off the router before packages change.

umask 077

MODE=""
CONFIRM=""
CONFIRM_BACKUP=""
ROLLBACK_MANIFEST_SHA256=""

VARIANT=extended-compressed
ROLLBACK_DIR="${TACHYON_ROLLBACK_DIR:-/tmp/podkop-rollback}"
WORK_DIR="${TACHYON_BOOTSTRAP_WORK_DIR:-/tmp/momen-tachyon-bootstrap}"
SOURCE_BASE_URL="${TACHYON_SOURCE_BASE_URL:-https://raw.githubusercontent.com/Konglomeratovich/momen/main/scripts}"
SOURCE_DIR="${TACHYON_BOOTSTRAP_SOURCE_DIR:-}"
ROLLBACK_ASSET_DIR="${TACHYON_ROLLBACK_ASSET_DIR:-}"

AUDIT_NAME=audit-tachyon-readiness.sh
MIGRATOR_NAME=migrate-podkop-to-tachyon.sh
AUDIT_SHA256=172249a0b2f7a1fad639c5d2c551cdeca8638bbfd368a79f06a0cccb68ad3d45
MIGRATOR_SHA256=511737e5f1315fd6f7c764cf4486b7813ef4f330e4244bb2d4bc5dc0c5efb197

PODKOP_APK=podkop-0.7.22-r1.apk
PODKOP_APK_SHA256=5abf1422f73819d0834fd3ca81ccd55aaa7631e8665dc03e8c0d629811302e27
LUCI_APK=luci-app-podkop-0.7.22-r1.apk
LUCI_APK_SHA256=72addad80b71a9f44ea64af011c24b405c98b7a2b94751166a5668deeab7ad53
I18N_APK=luci-i18n-podkop-ru-0.7.22.apk
I18N_APK_SHA256=8977ce5f659b0cafefbcc7ae9f549c6eddf6a95fbfeac934e418b033bcda414a
SING_BOX_APK=sing-box-1.12.17-r1.apk
SING_BOX_APK_SHA256=f5c3536e546a5fa29a70bb304a721019f2f60f59df2b6ef84e994adc4984cfcc

PODKOP_APK_URL=https://github.com/itdoginfo/podkop/releases/download/0.7.22/$PODKOP_APK
LUCI_APK_URL=https://github.com/itdoginfo/podkop/releases/download/0.7.22/$LUCI_APK
I18N_APK_URL=https://github.com/itdoginfo/podkop/releases/download/0.7.22/$I18N_APK
SING_BOX_APK_URL=https://archive.openwrt.org/releases/packages-25.12/aarch64_cortex-a53/packages/$SING_BOX_APK

if [ "${TACHYON_CONTAINER_TEST:-0}" = 1 ] && [ -f /.dockerenv ]; then
    AUDIT_SHA256="${TACHYON_TEST_AUDIT_SHA256:-$AUDIT_SHA256}"
    MIGRATOR_SHA256="${TACHYON_TEST_MIGRATOR_SHA256:-$MIGRATOR_SHA256}"
    PODKOP_APK_SHA256="${TACHYON_TEST_PODKOP_APK_SHA256:-$PODKOP_APK_SHA256}"
    LUCI_APK_SHA256="${TACHYON_TEST_LUCI_APK_SHA256:-$LUCI_APK_SHA256}"
    I18N_APK_SHA256="${TACHYON_TEST_I18N_APK_SHA256:-$I18N_APK_SHA256}"
    SING_BOX_APK_SHA256="${TACHYON_TEST_SING_BOX_APK_SHA256:-$SING_BOX_APK_SHA256}"
fi

usage() {
    cat <<'EOF'
Usage:
  bootstrap-podkop-to-tachyon.sh --plan
  bootstrap-podkop-to-tachyon.sh --preflight \
    --rollback-manifest-sha256 HASH --confirm-backup COPIED-OFF-ROUTER
  bootstrap-podkop-to-tachyon.sh --apply \
    --rollback-manifest-sha256 HASH --confirm-backup COPIED-OFF-ROUTER \
    --confirm MIGRATE-PODKOP-TO-TACHYON

--plan downloads and verifies the pinned helper scripts, creates a fresh
rollback bundle in tmpfs, audits the actual router and prints the bundle
manifest hash. It does not change packages, UCI, services, nftables or routes.

Copy the complete rollback directory off-router before --preflight/--apply.
Those modes require the exact manifest hash printed by --plan and fail closed
if the bundle changed. Apply repeats plan and semantic preflight internally.
EOF
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is missing: $1"
}

is_sha256() {
    [ "${#1}" -eq 64 ] || return 1
    case "$1" in *[!0-9a-fA-F]*) return 1 ;; esac
}

installed_version() {
    package="$1"
    awk -v wanted="$package" '
        BEGIN { RS=""; FS="\n" }
        {
            name=""; version=""
            for (i=1; i<=NF; i++) {
                if ($i ~ /^P:/) name=substr($i, 3)
                if ($i ~ /^V:/) version=substr($i, 3)
            }
            if (name == wanted) { print version; exit }
        }
    ' /lib/apk/db/installed
}

installed_exact() {
    grep -q "^P:$1$" /lib/apk/db/installed
}

sha256_of() {
    sha256sum "$1" | awk '{ print $1 }'
}

verify_file() {
    path="$1"
    expected="$2"
    [ -s "$path" ] || fail "missing file: $path"
    actual="$(sha256_of "$path")"
    [ "$actual" = "$expected" ] || fail "SHA-256 mismatch for $(basename "$path"): $actual"
}

copy_or_download() {
    name="$1"
    url="$2"
    expected="$3"
    destination="$4"
    part="$destination.part"

    if [ -s "$destination" ] && [ "$(sha256_of "$destination")" = "$expected" ]; then
        return 0
    fi

    rm -f "$part"
    if [ -n "$SOURCE_DIR" ] && [ -f "$SOURCE_DIR/$name" ]; then
        cp "$SOURCE_DIR/$name" "$part"
    elif [ -n "$ROLLBACK_ASSET_DIR" ] && [ -f "$ROLLBACK_ASSET_DIR/$name" ]; then
        cp "$ROLLBACK_ASSET_DIR/$name" "$part"
    else
        wget -q -T 30 -O "$part" "$url"
    fi
    verify_file "$part" "$expected"
    mv "$part" "$destination"
}

download_helpers() {
    mkdir -p "$WORK_DIR"
    copy_or_download "$AUDIT_NAME" "$SOURCE_BASE_URL/$AUDIT_NAME" "$AUDIT_SHA256" "$WORK_DIR/$AUDIT_NAME"
    copy_or_download "$MIGRATOR_NAME" "$SOURCE_BASE_URL/$MIGRATOR_NAME" "$MIGRATOR_SHA256" "$WORK_DIR/$MIGRATOR_NAME"
    chmod 0700 "$WORK_DIR/$AUDIT_NAME" "$WORK_DIR/$MIGRATOR_NAME"
}

check_baseline() {
    [ "$(id -u)" -eq 0 ] || fail 'must run as root'
    [ -r /etc/openwrt_release ] || fail '/etc/openwrt_release is missing'
    [ -r /lib/apk/db/installed ] || fail 'apk installed database is missing'
    [ -s /etc/config/podkop ] || fail '/etc/config/podkop is missing or empty'

    release="$(sed -n "s/^DISTRIB_RELEASE='\(.*\)'/\1/p" /etc/openwrt_release | head -n 1)"
    arch="$(sed -n "s/^DISTRIB_ARCH='\(.*\)'/\1/p" /etc/openwrt_release | head -n 1)"
    [ "$release" = 25.12.2 ] || fail "unsupported OpenWrt release: ${release:-unknown}"
    case "$arch" in aarch64*) ;; *) fail "unsupported architecture: ${arch:-unknown}" ;; esac

    [ "$(installed_version podkop)" = 0.7.22-r1 ] || fail 'exact podkop 0.7.22-r1 is required'
    [ "$(installed_version luci-app-podkop)" = 0.7.22-r1 ] || fail 'exact luci-app-podkop 0.7.22-r1 is required'
    [ "$(installed_version luci-i18n-podkop-ru)" = 0.7.22 ] || fail 'exact luci-i18n-podkop-ru 0.7.22 is required'
    [ "$(installed_version sing-box)" = 1.12.17-r1 ] || fail 'exact sing-box 1.12.17-r1 is required'
    if installed_exact tachyon; then
        fail 'mixed Podkop/Tachyon package state is not supported'
    fi
}

already_migrated_healthcheck() {
    installed_exact tachyon || return 1
    installed_exact podkop && fail 'mixed Podkop/Tachyon package state is not supported'
    [ -x /usr/bin/tachyon-core ] || fail 'Tachyon is installed but /usr/bin/tachyon-core is missing'
    /usr/bin/tachyon-core version 2>/dev/null | grep -Fq '1.14.3-extended-2.7.3' || fail 'installed Tachyon core is not the pinned version'
    /etc/init.d/tachyon status >/dev/null 2>&1 || fail 'Tachyon service is not running'
    /etc/init.d/tachyon-core status >/dev/null 2>&1 || fail 'Tachyon core service is not running'
    nft list table inet TachyonTable >/dev/null 2>&1 || fail 'TachyonTable is missing'
    ip rule list | grep -q 'lookup tachyon' || fail 'Tachyon policy rule is missing'
    printf 'ALREADY_MIGRATED=true\n'
    printf 'IDEMPOTENT_HEALTHCHECK_OK=true\n'
    return 0
}

stage_rollback_bundle() {
    mkdir -p "$ROLLBACK_DIR"
    copy_or_download "$PODKOP_APK" "$PODKOP_APK_URL" "$PODKOP_APK_SHA256" "$ROLLBACK_DIR/$PODKOP_APK"
    copy_or_download "$LUCI_APK" "$LUCI_APK_URL" "$LUCI_APK_SHA256" "$ROLLBACK_DIR/$LUCI_APK"
    copy_or_download "$I18N_APK" "$I18N_APK_URL" "$I18N_APK_SHA256" "$ROLLBACK_DIR/$I18N_APK"
    copy_or_download "$SING_BOX_APK" "$SING_BOX_APK_URL" "$SING_BOX_APK_SHA256" "$ROLLBACK_DIR/$SING_BOX_APK"

    set --
    for path in \
        etc/config/podkop \
        etc/config/sing-box \
        etc/config/dhcp \
        etc/config/firewall \
        etc/config/network \
        etc/AdGuardHome.yaml \
        etc/sing-box/config.json \
        etc/momen-r1-cyrillic-tlds.lst \
        etc/apk/world
    do
        [ -e "/$path" ] && set -- "$@" "$path"
    done
    [ "$#" -gt 0 ] || fail 'no configuration paths found for backup'
    tar -C / -czf "$ROLLBACK_DIR/config-backup.tar.gz.new" "$@"
    tar -tzf "$ROLLBACK_DIR/config-backup.tar.gz.new" >/dev/null 2>&1 || fail 'new configuration archive is unreadable'
    mv "$ROLLBACK_DIR/config-backup.tar.gz.new" "$ROLLBACK_DIR/config-backup.tar.gz"

    (
        cd "$ROLLBACK_DIR"
        sha256sum "$PODKOP_APK" "$LUCI_APK" "$I18N_APK" "$SING_BOX_APK" config-backup.tar.gz >SHA256SUMS.new
        sha256sum -c SHA256SUMS.new >/dev/null
        mv SHA256SUMS.new SHA256SUMS
        chmod 0600 "$PODKOP_APK" "$LUCI_APK" "$I18N_APK" "$SING_BOX_APK" config-backup.tar.gz SHA256SUMS
    )
}

verify_rollback_bundle() {
    [ -d "$ROLLBACK_DIR" ] || fail "rollback directory is missing: $ROLLBACK_DIR"
    [ -s "$ROLLBACK_DIR/SHA256SUMS" ] || fail 'rollback SHA256SUMS is missing'
    (
        cd "$ROLLBACK_DIR"
        sha256sum -c SHA256SUMS >/dev/null
    ) || fail 'rollback bundle checksum verification failed'
    tar -tzf "$ROLLBACK_DIR/config-backup.tar.gz" >/dev/null 2>&1 || fail 'rollback configuration archive is unreadable'
    current_manifest_sha="$(sha256_of "$ROLLBACK_DIR/SHA256SUMS")"
    [ "$current_manifest_sha" = "$ROLLBACK_MANIFEST_SHA256" ] || fail "rollback manifest changed: $current_manifest_sha"
}

run_readiness() {
    TACHYON_ROLLBACK_DIR="$ROLLBACK_DIR" ash "$WORK_DIR/$AUDIT_NAME" --variant "$VARIANT"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --plan|--preflight|--apply)
            [ -z "$MODE" ] || { usage >&2; exit 2; }
            MODE="${1#--}"
            ;;
        --rollback-manifest-sha256)
            shift
            [ "$#" -gt 0 ] || { usage >&2; exit 2; }
            ROLLBACK_MANIFEST_SHA256="$1"
            ;;
        --confirm-backup)
            shift
            [ "$#" -gt 0 ] || { usage >&2; exit 2; }
            CONFIRM_BACKUP="$1"
            ;;
        --confirm)
            shift
            [ "$#" -gt 0 ] || { usage >&2; exit 2; }
            CONFIRM="$1"
            ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

[ -n "$MODE" ] || { usage >&2; exit 2; }

for command in ash awk basename cp df du grep head id ip mkdir mv nft rm sed sha256sum tar wget; do
    require_cmd "$command"
done

if already_migrated_healthcheck; then
    exit 0
fi

check_baseline
download_helpers

if [ "$MODE" = plan ]; then
    stage_rollback_bundle
    ROLLBACK_MANIFEST_SHA256="$(sha256_of "$ROLLBACK_DIR/SHA256SUMS")"
    run_readiness
    TACHYON_ROLLBACK_DIR="$ROLLBACK_DIR" ash "$WORK_DIR/$MIGRATOR_NAME" --plan
    printf 'ROLLBACK_DIR=%s\n' "$ROLLBACK_DIR"
    printf 'ROLLBACK_MANIFEST_SHA256=%s\n' "$ROLLBACK_MANIFEST_SHA256"
    printf 'COPY_OFF_ROUTER_REQUIRED=true\n'
    printf 'PLAN_OK=true\n'
    exit 0
fi

is_sha256 "$ROLLBACK_MANIFEST_SHA256" || fail '--rollback-manifest-sha256 must be a 64-character SHA-256'
[ "$CONFIRM_BACKUP" = COPIED-OFF-ROUTER ] || fail 'offline backup confirmation is required: --confirm-backup COPIED-OFF-ROUTER'
[ "$MODE" != apply ] || [ "$CONFIRM" = MIGRATE-PODKOP-TO-TACHYON ] || fail 'Apply confirmation is required: --confirm MIGRATE-PODKOP-TO-TACHYON'
verify_rollback_bundle
run_readiness

TACHYON_ROLLBACK_DIR="$ROLLBACK_DIR" ash "$WORK_DIR/$MIGRATOR_NAME" --plan
TACHYON_ROLLBACK_DIR="$ROLLBACK_DIR" ash "$WORK_DIR/$MIGRATOR_NAME" --preflight

if [ "$MODE" = preflight ]; then
    printf 'BOOTSTRAP_PREFLIGHT_OK=true\n'
    exit 0
fi

TACHYON_ROLLBACK_DIR="$ROLLBACK_DIR" ash "$WORK_DIR/$MIGRATOR_NAME" --apply --confirm MIGRATE-PODKOP-TO-TACHYON
printf 'BOOTSTRAP_MIGRATION_OK=true\n'
