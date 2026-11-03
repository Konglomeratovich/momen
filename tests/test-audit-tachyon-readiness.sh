#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../scripts/audit-tachyon-readiness.sh"
WORK_DIR="$(mktemp -d)"
PASS=0

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT INT TERM

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -F "$2" "$1" >/dev/null || fail "expected '$2' in $1"; }

new_case() {
    name="$1"
    d="$WORK_DIR/$name"
    mkdir -p "$d/bin" "$d/etc/config" "$d/etc/apk" "$d/lib/apk/db" "$d/proc" "$d/overlay" "$d/tmp" "$d/rollback"
    printf "%s\n" \
        "DISTRIB_RELEASE='25.12.2'" \
        "DISTRIB_ARCH='aarch64_cortex-a53'" \
        "DISTRIB_TARGET='mediatek/filogic'" >"$d/openwrt_release"
    cat >"$d/lib/apk/db/installed" <<'EOF'
P:podkop
V:0.7.22
I:4194304

P:luci-app-podkop
V:0.7.22
I:2097152

P:luci-i18n-podkop-ru
V:0.7.22
I:1048576

P:sing-box
V:1.12.17
I:73400320
EOF
    printf '%s\n' podkop luci-app-podkop luci-i18n-podkop-ru >"$d/etc/apk/world"
    printf '%s\n' "config settings 'settings'" >"$d/etc/config/podkop"
    printf '%s\n' 'MemAvailable:      262144 kB' 'SwapFree:               0 kB' >"$d/proc/meminfo"
    printf '%s\n' rollback >"$d/rollback/podkop.apk"

    cat >"$d/bin/apk" <<'EOF'
#!/bin/sh
exit 0
EOF
    cat >"$d/bin/df" <<'EOF'
#!/bin/sh
case "$1" in
    -Pk)
        case "$2" in
            *overlay) free="${MOCK_OVERLAY_FREE_KB:-131072}" ;;
            *) free="${MOCK_TMP_FREE_KB:-131072}" ;;
        esac
        printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on' "mock 999999 1 $free 1% $2"
        ;;
    -Pi)
        if [ "${MOCK_PI_UNSUPPORTED:-false}" = true ]; then
            exit 1
        fi
        printf '%s\n' 'Filesystem Inodes IUsed IFree IUse% Mounted on' "mock 999999 1 ${MOCK_INODES_FREE:-5000} 1% $2"
        ;;
    -i)
        printf '%s\n' 'Filesystem Inodes IUsed IFree IUse% Mounted on' "mock 999999 1 ${MOCK_INODES_FALLBACK:-5000} 1% $2"
        ;;
    *) exit 2 ;;
esac
EOF
    cat >"$d/bin/du" <<'EOF'
#!/bin/sh
case "$2" in
    *rollback) printf '%s\t%s\n' "${MOCK_ROLLBACK_KB:-4096}" "$2" ;;
    *) printf '4\t%s\n' "$2" ;;
esac
EOF
    chmod +x "$d/bin/apk" "$d/bin/df" "$d/bin/du"
    printf '%s\n' "$d"
}

run_case() {
    d="$1"
    variant="$2"
    shift 2
    env \
        PATH="$d/bin:$PATH" \
        MOCK_OVERLAY_FREE_KB="${MOCK_OVERLAY_FREE_KB:-131072}" \
        MOCK_TMP_FREE_KB="${MOCK_TMP_FREE_KB:-131072}" \
        MOCK_INODES_FREE="${MOCK_INODES_FREE:-5000}" \
        MOCK_PI_UNSUPPORTED="${MOCK_PI_UNSUPPORTED:-false}" \
        MOCK_INODES_FALLBACK="${MOCK_INODES_FALLBACK:-5000}" \
        MOCK_ROLLBACK_KB="${MOCK_ROLLBACK_KB:-4096}" \
        TACHYON_OPENWRT_RELEASE_FILE="$d/openwrt_release" \
        TACHYON_APK_INSTALLED_DB="$d/lib/apk/db/installed" \
        TACHYON_APK_WORLD_FILE="$d/etc/apk/world" \
        TACHYON_MEMINFO_FILE="$d/proc/meminfo" \
        TACHYON_OVERLAY_PATH="$d/overlay" \
        TACHYON_TMP_PATH="$d/tmp" \
        TACHYON_ROLLBACK_DIR="$d/rollback" \
        TACHYON_PODKOP_CONFIG="$d/etc/config/podkop" \
        TACHYON_CONFIG_PATHS="$d/etc/config/podkop" \
        TACHYON_DF_CMD="$d/bin/df" \
        TACHYON_DU_CMD="$d/bin/du" \
        sh "$TARGET" --variant "$variant" "$@"
}

d="$(new_case compressed_ok)"
before_world="$(sha256sum "$d/etc/apk/world")"
before_db="$(sha256sum "$d/lib/apk/db/installed")"
run_case "$d" extended-compressed >"$WORK_DIR/compressed_ok.out"
assert_contains "$WORK_DIR/compressed_ok.out" 'SPACE_OK=true'
assert_contains "$WORK_DIR/compressed_ok.out" 'ROLLBACK_READY=true'
assert_contains "$WORK_DIR/compressed_ok.out" 'APPLY_ALLOWED=true'
assert_contains "$WORK_DIR/compressed_ok.out" 'PODKOP_VERSION=0.7.22'
assert_contains "$WORK_DIR/compressed_ok.out" 'CURRENT_ENGINE_PACKAGE=sing-box'
assert_contains "$WORK_DIR/compressed_ok.out" 'RECLAIMABLE_INSTALLED_KB=78848'
assert_contains "$WORK_DIR/compressed_ok.out" 'SIZE_DATA_OK=true'
[ "$before_world" = "$(sha256sum "$d/etc/apk/world")" ] || fail 'audit changed apk world'
[ "$before_db" = "$(sha256sum "$d/lib/apk/db/installed")" ] || fail 'audit changed installed database'
PASS=$((PASS + 1))

d="$(new_case missing_world_entry)"
sed -i '/^podkop$/d' "$d/etc/apk/world"
if run_case "$d" extended-compressed >"$WORK_DIR/missing_world.out" 2>&1; then
    fail 'missing Podkop world entry was accepted'
fi
assert_contains "$WORK_DIR/missing_world.out" 'PACKAGE_STATE_OK=false'
assert_contains "$WORK_DIR/missing_world.out" 'APPLY_ALLOWED=false'
PASS=$((PASS + 1))

d="$(new_case extended_fits_after_reclaim)"
run_case "$d" extended >"$WORK_DIR/extended.out"
assert_contains "$WORK_DIR/extended.out" 'OVERLAY_FINAL_AFTER_KB=99872'
assert_contains "$WORK_DIR/extended.out" 'SPACE_OK=true'
assert_contains "$WORK_DIR/extended.out" 'APPLY_ALLOWED=true'
PASS=$((PASS + 1))

d="$(new_case measured_engine_size)"
TACHYON_MEASURED_ENGINE_INSTALLED_KB=33333 \
TACHYON_MEASURED_DOWNLOAD_KB=22222 \
    run_case "$d" extended-compressed >"$WORK_DIR/measured_engine.out"
assert_contains "$WORK_DIR/measured_engine.out" 'ENGINE_INSTALLED_KB=33333'
assert_contains "$WORK_DIR/measured_engine.out" 'DOWNLOAD_KB=22222'
assert_contains "$WORK_DIR/measured_engine.out" 'SIZE_SOURCE=measured-engine-and-download'
assert_contains "$WORK_DIR/measured_engine.out" 'OVERLAY_FINAL_AFTER_KB=164299'
PASS=$((PASS + 1))

d="$(new_case extended_reclaim_too_small)"
sed -i 's/I:73400320/I:10485760/' "$d/lib/apk/db/installed"
MOCK_OVERLAY_FREE_KB=59592
if run_case "$d" extended >"$WORK_DIR/extended_small_reclaim.out" 2>&1; then
    fail 'ordinary extended was accepted without enough reclaimable space'
fi
unset MOCK_OVERLAY_FREE_KB
assert_contains "$WORK_DIR/extended_small_reclaim.out" 'RECLAIMABLE_INSTALLED_KB=17408'
assert_contains "$WORK_DIR/extended_small_reclaim.out" 'SPACE_OK=false'
PASS=$((PASS + 1))

d="$(new_case low_tmp)"
MOCK_TMP_FREE_KB=20000
if run_case "$d" extended-compressed >"$WORK_DIR/low_tmp.out" 2>&1; then
    fail 'low tmp space was accepted'
fi
unset MOCK_TMP_FREE_KB
assert_contains "$WORK_DIR/low_tmp.out" 'TMP_FREE_KB=20000'
assert_contains "$WORK_DIR/low_tmp.out" 'SPACE_OK=false'
PASS=$((PASS + 1))

d="$(new_case low_inodes)"
MOCK_INODES_FREE=100
if run_case "$d" extended-compressed >"$WORK_DIR/low_inodes.out" 2>&1; then
    fail 'low inode count was accepted'
fi
unset MOCK_INODES_FREE
assert_contains "$WORK_DIR/low_inodes.out" 'OVERLAY_INODES_FREE=100'
assert_contains "$WORK_DIR/low_inodes.out" 'SPACE_OK=false'
PASS=$((PASS + 1))

d="$(new_case inode_fallback)"
MOCK_PI_UNSUPPORTED=true
MOCK_INODES_FALLBACK=6000
run_case "$d" extended-compressed >"$WORK_DIR/inode_fallback.out"
unset MOCK_PI_UNSUPPORTED MOCK_INODES_FALLBACK
assert_contains "$WORK_DIR/inode_fallback.out" 'OVERLAY_INODES_FREE=6000'
assert_contains "$WORK_DIR/inode_fallback.out" 'INODE_CHECK_SUPPORTED=true'
PASS=$((PASS + 1))

d="$(new_case inode_unavailable)"
MOCK_INODES_FREE=0
MOCK_INODES_FALLBACK=0
run_case "$d" extended-compressed >"$WORK_DIR/inode_unavailable.out"
unset MOCK_INODES_FREE MOCK_INODES_FALLBACK
assert_contains "$WORK_DIR/inode_unavailable.out" 'OVERLAY_INODES_FREE=unknown'
assert_contains "$WORK_DIR/inode_unavailable.out" 'INODE_CHECK_SUPPORTED=false'
PASS=$((PASS + 1))

d="$(new_case no_rollback)"
rm -rf "$d/rollback"
if run_case "$d" extended-compressed >"$WORK_DIR/no_rollback.out" 2>&1; then
    fail 'missing rollback bundle was accepted'
fi
assert_contains "$WORK_DIR/no_rollback.out" 'ROLLBACK_STORAGE=estimated'
assert_contains "$WORK_DIR/no_rollback.out" 'ROLLBACK_READY=false'
assert_contains "$WORK_DIR/no_rollback.out" 'APPLY_ALLOWED=false'
PASS=$((PASS + 1))

d="$(new_case wrong_arch)"
sed -i "s/aarch64_cortex-a53/mips_24kc/" "$d/openwrt_release"
if run_case "$d" extended-compressed >"$WORK_DIR/wrong_arch.out" 2>&1; then
    fail 'wrong architecture was accepted'
fi
assert_contains "$WORK_DIR/wrong_arch.out" 'COMPATIBLE=false'
PASS=$((PASS + 1))

printf 'PASS=%s FAIL=0\n' "$PASS"
