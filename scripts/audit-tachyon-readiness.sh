#!/bin/sh
set -eu

# Read-only readiness audit for migrating an eligible OpenWrt router from
# Podkop to Tachyon. The script intentionally does not refresh apk indexes,
# download files, create backups, change UCI, or touch services. A caller that
# already staged and verified the selected engine should pass its measured
# binary size through TACHYON_MEASURED_ENGINE_INSTALLED_KB.

EXPECTED_RELEASE="25.12.2"
SUPPORTED_ARCH_PREFIX="aarch64"

TACHYON_INSTALLED_KB="${TACHYON_PROJECTED_PACKAGE_KB:-9664}"
EXTENDED_INSTALLED_KB=97760
EXTENDED_DOWNLOAD_KB=34649
COMPRESSED_INSTALLED_KB=20806
COMPRESSED_DOWNLOAD_KB=22900

OVERLAY_TRANSACTION_MARGIN_KB="${TACHYON_OVERLAY_MARGIN_KB:-16384}"
OVERLAY_FINAL_RESERVE_KB="${TACHYON_OVERLAY_RESERVE_KB:-12288}"
TMP_MARGIN_KB="${TACHYON_TMP_MARGIN_KB:-16384}"
RAM_RUNTIME_RESERVE_KB="${TACHYON_RAM_RESERVE_KB:-32768}"
MIN_FREE_INODES="${TACHYON_MIN_FREE_INODES:-1024}"
ROLLBACK_ESTIMATE_KB="${TACHYON_ROLLBACK_ESTIMATE_KB:-16384}"

OPENWRT_RELEASE_FILE="${TACHYON_OPENWRT_RELEASE_FILE:-/etc/openwrt_release}"
APK_INSTALLED_DB="${TACHYON_APK_INSTALLED_DB:-/lib/apk/db/installed}"
APK_WORLD_FILE="${TACHYON_APK_WORLD_FILE:-/etc/apk/world}"
MEMINFO_FILE="${TACHYON_MEMINFO_FILE:-/proc/meminfo}"
OVERLAY_PATH="${TACHYON_OVERLAY_PATH:-/overlay}"
TMP_PATH="${TACHYON_TMP_PATH:-/tmp}"
ROLLBACK_DIR="${TACHYON_ROLLBACK_DIR:-/tmp/podkop-rollback}"
CONFIG_PATHS="${TACHYON_CONFIG_PATHS:-/etc/config/podkop /etc/config/sing-box /etc/config/dhcp /etc/config/firewall /etc/config/network /etc/AdGuardHome.yaml /etc/sing-box/config.json}"
DF_CMD="${TACHYON_DF_CMD:-df}"
DU_CMD="${TACHYON_DU_CMD:-du}"

VARIANT=""
SIZE_SOURCE=release-estimate

is_uint() {
    case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

usage() {
    cat <<'EOF'
Usage: audit-tachyon-readiness.sh --variant extended|extended-compressed

Performs a read-only compatibility, storage, memory, inode, package-state,
configuration and rollback-bundle audit. It prints machine-readable KEY=value
lines and exits non-zero unless Apply is fully allowed.

The first audit may legitimately report ROLLBACK_READY=false. After the exact
rollback APK bundle is staged in tmpfs, rerun with TACHYON_ROLLBACK_DIR pointing
to it. A second copy must be kept off-router; /tmp does not survive a reboot.
EOF
}

fail_usage() {
    printf 'ERROR=%s\n' "$1" >&2
    usage >&2
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --variant)
            shift
            [ "$#" -gt 0 ] || fail_usage '--variant requires a value'
            VARIANT="$1"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) fail_usage "unknown argument: $1" ;;
    esac
    shift
done

case "$VARIANT" in
    extended)
        ENGINE_INSTALLED_KB="$EXTENDED_INSTALLED_KB"
        DOWNLOAD_KB="$EXTENDED_DOWNLOAD_KB"
        ;;
    extended-compressed)
        ENGINE_INSTALLED_KB="$COMPRESSED_INSTALLED_KB"
        DOWNLOAD_KB="$COMPRESSED_DOWNLOAD_KB"
        ;;
    *) fail_usage '--variant must be extended or extended-compressed' ;;
esac

if [ -n "${TACHYON_MEASURED_ENGINE_INSTALLED_KB:-}" ]; then
    is_uint "$TACHYON_MEASURED_ENGINE_INSTALLED_KB" || fail_usage 'TACHYON_MEASURED_ENGINE_INSTALLED_KB must be an unsigned integer'
    [ "$TACHYON_MEASURED_ENGINE_INSTALLED_KB" -gt 0 ] || fail_usage 'TACHYON_MEASURED_ENGINE_INSTALLED_KB must be greater than zero'
    ENGINE_INSTALLED_KB="$TACHYON_MEASURED_ENGINE_INSTALLED_KB"
    SIZE_SOURCE='measured-engine'
fi

if [ -n "${TACHYON_MEASURED_DOWNLOAD_KB:-}" ]; then
    is_uint "$TACHYON_MEASURED_DOWNLOAD_KB" || fail_usage 'TACHYON_MEASURED_DOWNLOAD_KB must be an unsigned integer'
    [ "$TACHYON_MEASURED_DOWNLOAD_KB" -gt 0 ] || fail_usage 'TACHYON_MEASURED_DOWNLOAD_KB must be greater than zero'
    DOWNLOAD_KB="$TACHYON_MEASURED_DOWNLOAD_KB"
    SIZE_SOURCE='measured-engine-and-download'
fi

release_value() {
    key="$1"
    [ -r "$OPENWRT_RELEASE_FILE" ] || return 0
    sed -n "s/^${key}='\(.*\)'/\1/p" "$OPENWRT_RELEASE_FILE" | head -n 1
}

df_value() {
    mode="$1"
    path="$2"
    case "$mode" in
        blocks) "$DF_CMD" -Pk "$path" 2>/dev/null | awk 'END { print $4 }' ;;
        inodes)
            value="$("$DF_CMD" -Pi "$path" 2>/dev/null | awk 'END { print $4 }')"
            if ! is_uint "${value:-}" || [ "$value" -eq 0 ]; then
                value="$("$DF_CMD" -i "$path" 2>/dev/null | awk 'END { print $4 }')"
            fi
            printf '%s\n' "$value"
            ;;
        *) return 1 ;;
    esac
}

installed_exact() {
    package="$1"
    [ -r "$APK_INSTALLED_DB" ] && grep -q "^P:${package}$" "$APK_INSTALLED_DB"
}

installed_version() {
    package="$1"
    [ -r "$APK_INSTALLED_DB" ] || return 0
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
    ' "$APK_INSTALLED_DB"
}

installed_size_kb() {
    package="$1"
    [ -r "$APK_INSTALLED_DB" ] || { printf '0\n'; return; }
    bytes="$(awk -v wanted="$package" '
        BEGIN { RS=""; FS="\n" }
        {
            name=""; installed=""
            for (i=1; i<=NF; i++) {
                if ($i ~ /^P:/) name=substr($i, 3)
                if ($i ~ /^I:/) installed=substr($i, 3)
            }
            if (name == wanted) { print installed; exit }
        }
    ' "$APK_INSTALLED_DB")"
    if is_uint "${bytes:-}"; then
        printf '%s\n' "$(((bytes + 1023) / 1024))"
    else
        printf '0\n'
    fi
}

world_has_package() {
    package="$1"
    [ -r "$APK_WORLD_FILE" ] && grep -Eq "^${package}([[:space:]<>=~].*)?$" "$APK_WORLD_FILE"
}

config_size_kb() {
    total=0
    for path in $CONFIG_PATHS; do
        [ -e "$path" ] || continue
        size="$("$DU_CMD" -sk "$path" 2>/dev/null | awk 'END { print $1 }')"
        is_uint "${size:-}" || continue
        total=$((total + size))
    done
    [ "$total" -ge 1024 ] || total=1024
    printf '%s\n' "$total"
}

OPENWRT_RELEASE="$(release_value DISTRIB_RELEASE)"
OPENWRT_ARCH="$(release_value DISTRIB_ARCH)"
OPENWRT_TARGET="$(release_value DISTRIB_TARGET)"

COMPATIBLE=true
[ "$OPENWRT_RELEASE" = "$EXPECTED_RELEASE" ] || COMPATIBLE=false
case "$OPENWRT_ARCH" in
    "$SUPPORTED_ARCH_PREFIX"*) ;;
    *) COMPATIBLE=false ;;
esac
command -v apk >/dev/null 2>&1 || COMPATIBLE=false

PODKOP_INSTALLED=false
LUCI_PODKOP_INSTALLED=false
PODKOP_CONFIG_PRESENT=false
installed_exact podkop && PODKOP_INSTALLED=true
installed_exact luci-app-podkop && LUCI_PODKOP_INSTALLED=true
[ -s "${TACHYON_PODKOP_CONFIG:-/etc/config/podkop}" ] && PODKOP_CONFIG_PRESENT=true

PODKOP_VERSION="$(installed_version podkop)"
LUCI_PODKOP_VERSION="$(installed_version luci-app-podkop)"
CURRENT_ENGINE_PACKAGE=unknown
CURRENT_ENGINE_VERSION=unknown
for engine_package in sing-box-extended sing-box-lx sing-box-tiny sing-box; do
    if installed_exact "$engine_package"; then
        CURRENT_ENGINE_PACKAGE="$engine_package"
        CURRENT_ENGINE_VERSION="$(installed_version "$engine_package")"
        break
    fi
done

PODKOP_INSTALLED_KB="$(installed_size_kb podkop)"
LUCI_PODKOP_INSTALLED_KB="$(installed_size_kb luci-app-podkop)"
PODKOP_I18N_INSTALLED_KB="$(installed_size_kb luci-i18n-podkop-ru)"
CURRENT_ENGINE_INSTALLED_KB=0
if [ "$CURRENT_ENGINE_PACKAGE" != unknown ]; then
    CURRENT_ENGINE_INSTALLED_KB="$(installed_size_kb "$CURRENT_ENGINE_PACKAGE")"
fi
RECLAIMABLE_INSTALLED_KB=$((PODKOP_INSTALLED_KB + LUCI_PODKOP_INSTALLED_KB + PODKOP_I18N_INSTALLED_KB + CURRENT_ENGINE_INSTALLED_KB))

SIZE_DATA_OK=true
[ "$PODKOP_INSTALLED_KB" -gt 0 ] || SIZE_DATA_OK=false
[ "$LUCI_PODKOP_INSTALLED_KB" -gt 0 ] || SIZE_DATA_OK=false
[ "$CURRENT_ENGINE_INSTALLED_KB" -gt 0 ] || SIZE_DATA_OK=false
if installed_exact luci-i18n-podkop-ru; then
    [ "$PODKOP_I18N_INSTALLED_KB" -gt 0 ] || SIZE_DATA_OK=false
fi

TACHYON_ALREADY_INSTALLED=false
if installed_exact tachyon || installed_exact luci-app-tachyon; then
    TACHYON_ALREADY_INSTALLED=true
fi

PACKAGE_STATE_OK=true
[ "$PODKOP_INSTALLED" = true ] || PACKAGE_STATE_OK=false
[ "$LUCI_PODKOP_INSTALLED" = true ] || PACKAGE_STATE_OK=false
[ "$PODKOP_CONFIG_PRESENT" = true ] || PACKAGE_STATE_OK=false
[ "$TACHYON_ALREADY_INSTALLED" = false ] || PACKAGE_STATE_OK=false
[ -r "$APK_WORLD_FILE" ] || PACKAGE_STATE_OK=false
world_has_package podkop || PACKAGE_STATE_OK=false
world_has_package luci-app-podkop || PACKAGE_STATE_OK=false
[ "$CURRENT_ENGINE_PACKAGE" != unknown ] || PACKAGE_STATE_OK=false
[ "$SIZE_DATA_OK" = true ] || PACKAGE_STATE_OK=false

OVERLAY_FREE_KB="$(df_value blocks "$OVERLAY_PATH")"
TMP_FREE_KB="$(df_value blocks "$TMP_PATH")"
OVERLAY_INODES_FREE="$(df_value inodes "$OVERLAY_PATH")"
MEM_AVAILABLE_KB="$(awk '/^MemAvailable:/ { print $2; exit }' "$MEMINFO_FILE" 2>/dev/null || true)"
SWAP_FREE_KB="$(awk '/^SwapFree:/ { print $2; exit }' "$MEMINFO_FILE" 2>/dev/null || true)"

is_uint "$OVERLAY_FREE_KB" || OVERLAY_FREE_KB=0
is_uint "$TMP_FREE_KB" || TMP_FREE_KB=0
INODE_CHECK_SUPPORTED=true
if ! is_uint "$OVERLAY_INODES_FREE" || [ "$OVERLAY_INODES_FREE" -eq 0 ]; then
    OVERLAY_INODES_FREE=unknown
    INODE_CHECK_SUPPORTED=false
fi
is_uint "$MEM_AVAILABLE_KB" || MEM_AVAILABLE_KB=0
is_uint "$SWAP_FREE_KB" || SWAP_FREE_KB=0

CONFIG_BACKUP_KB="$(config_size_kb)"

ROLLBACK_READY=false
ROLLBACK_STORAGE=estimated
ROLLBACK_KB="$ROLLBACK_ESTIMATE_KB"
if [ -d "$ROLLBACK_DIR" ]; then
    measured="$("$DU_CMD" -sk "$ROLLBACK_DIR" 2>/dev/null | awk 'END { print $1 }')"
    if is_uint "${measured:-}" && [ "$measured" -gt 0 ]; then
        ROLLBACK_KB="$measured"
        ROLLBACK_STORAGE=measured
        ROLLBACK_READY=true
    fi
fi

NEW_INSTALLED_KB=$((TACHYON_INSTALLED_KB + ENGINE_INSTALLED_KB))
OVERLAY_FINAL_AFTER_KB=$((OVERLAY_FREE_KB + RECLAIMABLE_INSTALLED_KB - NEW_INSTALLED_KB))
OVERLAY_MIN_RECLAIM_KB=$((NEW_INSTALLED_KB + OVERLAY_FINAL_RESERVE_KB - OVERLAY_FREE_KB))
[ "$OVERLAY_MIN_RECLAIM_KB" -ge 0 ] || OVERLAY_MIN_RECLAIM_KB=0
OVERLAY_REQUIRED_RECLAIM_KB=$((NEW_INSTALLED_KB + OVERLAY_FINAL_RESERVE_KB + OVERLAY_TRANSACTION_MARGIN_KB - OVERLAY_FREE_KB))
[ "$OVERLAY_REQUIRED_RECLAIM_KB" -ge 0 ] || OVERLAY_REQUIRED_RECLAIM_KB=0
OVERLAY_TRANSACTION_AFTER_KB=$((OVERLAY_FINAL_AFTER_KB - OVERLAY_TRANSACTION_MARGIN_KB))
TMP_REQUIRED_KB=$((DOWNLOAD_KB + CONFIG_BACKUP_KB + ROLLBACK_KB + TMP_MARGIN_KB))
RAM_REQUIRED_KB=$((TMP_REQUIRED_KB + RAM_RUNTIME_RESERVE_KB))

TMP_AFTER_KB=$((TMP_FREE_KB - TMP_REQUIRED_KB))
RAM_AFTER_KB=$((MEM_AVAILABLE_KB + SWAP_FREE_KB - RAM_REQUIRED_KB))

SPACE_OK=true
[ "$OVERLAY_FINAL_AFTER_KB" -ge "$OVERLAY_FINAL_RESERVE_KB" ] || SPACE_OK=false
[ "$OVERLAY_TRANSACTION_AFTER_KB" -ge "$OVERLAY_FINAL_RESERVE_KB" ] || SPACE_OK=false
[ "$TMP_FREE_KB" -ge "$TMP_REQUIRED_KB" ] || SPACE_OK=false
[ $((MEM_AVAILABLE_KB + SWAP_FREE_KB)) -ge "$RAM_REQUIRED_KB" ] || SPACE_OK=false
if [ "$INODE_CHECK_SUPPORTED" = true ]; then
    [ "$OVERLAY_INODES_FREE" -ge "$MIN_FREE_INODES" ] || SPACE_OK=false
fi

APPLY_ALLOWED=true
[ "$COMPATIBLE" = true ] || APPLY_ALLOWED=false
[ "$PACKAGE_STATE_OK" = true ] || APPLY_ALLOWED=false
[ "$SPACE_OK" = true ] || APPLY_ALLOWED=false
[ "$ROLLBACK_READY" = true ] || APPLY_ALLOWED=false

cat <<EOF
AUDIT_MODE=read-only
VARIANT=$VARIANT
OPENWRT_RELEASE=$OPENWRT_RELEASE
OPENWRT_ARCH=$OPENWRT_ARCH
OPENWRT_TARGET=$OPENWRT_TARGET
COMPATIBLE=$COMPATIBLE
SUPPORTED_ARCH_PREFIX=$SUPPORTED_ARCH_PREFIX
PODKOP_INSTALLED=$PODKOP_INSTALLED
LUCI_PODKOP_INSTALLED=$LUCI_PODKOP_INSTALLED
PODKOP_VERSION=$PODKOP_VERSION
LUCI_PODKOP_VERSION=$LUCI_PODKOP_VERSION
CURRENT_ENGINE_PACKAGE=$CURRENT_ENGINE_PACKAGE
CURRENT_ENGINE_VERSION=$CURRENT_ENGINE_VERSION
CURRENT_ENGINE_INSTALLED_KB=$CURRENT_ENGINE_INSTALLED_KB
PODKOP_CONFIG_PRESENT=$PODKOP_CONFIG_PRESENT
TACHYON_ALREADY_INSTALLED=$TACHYON_ALREADY_INSTALLED
PACKAGE_STATE_OK=$PACKAGE_STATE_OK
SIZE_DATA_OK=$SIZE_DATA_OK
PODKOP_INSTALLED_KB=$PODKOP_INSTALLED_KB
LUCI_PODKOP_INSTALLED_KB=$LUCI_PODKOP_INSTALLED_KB
PODKOP_I18N_INSTALLED_KB=$PODKOP_I18N_INSTALLED_KB
RECLAIMABLE_INSTALLED_KB=$RECLAIMABLE_INSTALLED_KB
TACHYON_INSTALLED_KB=$TACHYON_INSTALLED_KB
ENGINE_INSTALLED_KB=$ENGINE_INSTALLED_KB
NEW_INSTALLED_KB=$NEW_INSTALLED_KB
DOWNLOAD_KB=$DOWNLOAD_KB
SIZE_SOURCE=$SIZE_SOURCE
CONFIG_BACKUP_KB=$CONFIG_BACKUP_KB
ROLLBACK_DIR=$ROLLBACK_DIR
ROLLBACK_STORAGE=$ROLLBACK_STORAGE
ROLLBACK_KB=$ROLLBACK_KB
ROLLBACK_READY=$ROLLBACK_READY
OVERLAY_FREE_KB=$OVERLAY_FREE_KB
OVERLAY_MIN_RECLAIM_KB=$OVERLAY_MIN_RECLAIM_KB
OVERLAY_REQUIRED_RECLAIM_KB=$OVERLAY_REQUIRED_RECLAIM_KB
OVERLAY_FINAL_RESERVE_KB=$OVERLAY_FINAL_RESERVE_KB
OVERLAY_FINAL_AFTER_KB=$OVERLAY_FINAL_AFTER_KB
OVERLAY_TRANSACTION_MARGIN_KB=$OVERLAY_TRANSACTION_MARGIN_KB
OVERLAY_TRANSACTION_AFTER_KB=$OVERLAY_TRANSACTION_AFTER_KB
OVERLAY_INODES_FREE=$OVERLAY_INODES_FREE
INODE_CHECK_SUPPORTED=$INODE_CHECK_SUPPORTED
MIN_FREE_INODES=$MIN_FREE_INODES
TMP_FREE_KB=$TMP_FREE_KB
TMP_REQUIRED_KB=$TMP_REQUIRED_KB
TMP_AFTER_KB=$TMP_AFTER_KB
MEM_AVAILABLE_KB=$MEM_AVAILABLE_KB
SWAP_FREE_KB=$SWAP_FREE_KB
RAM_REQUIRED_KB=$RAM_REQUIRED_KB
RAM_AFTER_KB=$RAM_AFTER_KB
SPACE_OK=$SPACE_OK
APPLY_ALLOWED=$APPLY_ALLOWED
EOF

[ "$APPLY_ALLOWED" = true ]
