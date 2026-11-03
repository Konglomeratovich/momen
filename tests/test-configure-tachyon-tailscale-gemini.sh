#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../scripts/configure-tachyon-tailscale-gemini.sh"
WORK_DIR="$(mktemp -d)"
PASS=0

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT INT TERM

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$PASS" "$1"; }
assert_contains() { grep -F "$2" "$1" >/dev/null || fail "expected '$2' in $1"; }

ROOT="$WORK_DIR/root"
BIN="$WORK_DIR/bin"
CONFIG_DIR="$ROOT/etc/config"
CONFIG_FILE="$CONFIG_DIR/tachyon"
STATE_ROOT="$ROOT/etc/tachyon/tailscale"
BACKUP_ROOT="$ROOT/root/tachyon-backups"
mkdir -p "$BIN" "$CONFIG_DIR" "$STATE_ROOT" "$BACKUP_ROOT" \
    "$ROOT/lib/apk/db" "$ROOT/overlay"

cat >"$ROOT/openwrt_release" <<'EOF'
DISTRIB_RELEASE='25.12.2'
DISTRIB_ARCH='x86_64'
DISTRIB_TARGET='x86/64'
EOF

cat >"$ROOT/lib/apk/db/installed" <<'EOF'
P:tachyon
V:1.7.11

P:luci-app-tachyon
V:1.7.11
EOF

cat >"$ROOT/meminfo" <<'EOF'
MemTotal:         496716 kB
MemAvailable:     196608 kB
EOF
printf '%s\n' '10000.00 9000.00' >"$ROOT/uptime"
cat >"$ROOT/swaps" <<'EOF'
Filename Type Size Used Priority
/dev/zram0 partition 247804 0 100
EOF

write_original_config() {
    cat >"$CONFIG_FILE" <<'EOF'
config settings 'settings'
        option dns_type 'doh'

config section 'main'
        option label 'main'
        option enabled '1'
        option action 'connection'
        list community_lists 'discord'
        list community_lists 'google_ai'
        list excluded_ips '192.0.2.10'
        list excluded_ips '192.0.2.11'

config condition 'cond_main'
        option enabled '1'
        list community_lists 'discord'
        list community_lists 'google_ai'

config section 'DIRECT'
        option enabled '1'
        option action 'bypass'
        list domain 'plex.tv'

config condition 'cond_DIRECT'
        option enabled '1'
        list domain 'plex.tv'
EOF
    chmod 0600 "$CONFIG_FILE"
}
write_original_config

cat >"$BIN/tachyon-core" <<'EOF'
#!/bin/sh
cat <<'OUT'
sing-box version 1.14.3-extended-2.7.3
Tags: with_gvisor,with_quic,with_tailscale
OUT
EOF

cat >"$BIN/init" <<'EOF'
#!/bin/sh
[ "${1:-}" = status ] && printf '%s\n' running
EOF

cat >"$BIN/tachyon" <<'EOF'
#!/bin/sh
set -eu
cmd="${1:-}"
case "$cmd" in
    config_validate)
        candidate="${2:-}"
        candidate_dir="$(dirname "$candidate")"
        [ "$(uci -c "$candidate_dir" -q get tachyon.GEMINI_TAILSCALE)" = section ]
        [ "$(uci -c "$candidate_dir" -q get tachyon.GEMINI_TAILSCALE.action)" = tailscale ]
        [ "$(uci -c "$candidate_dir" -q get tachyon.GEMINI_TAILSCALE.community_lists)" = google_ai ]
        [ -n "$(uci -c "$candidate_dir" -q get tachyon.GEMINI_TAILSCALE.tailscale_exit_node)" ]
        if [ -n "${REAL_PLANNER_LIB:-}" ]; then
            export TACHYON_LIB="$REAL_PLANNER_LIB"
            exec ucode -L "$REAL_PLANNER_LIB" "$REAL_PLANNER_LIB/service/config_plan.uc" validate "$candidate"
        fi
        ;;
    reload)
        reason="${2:-}"
        printf '%s\n' "$reason" >>"$MOCK_RELOAD_LOG"
        if [ "$reason" = tailscale-gemini-enroll ]; then
            [ "${MOCK_RELOAD_FAIL:-0}" != 1 ] || exit 1
            key="$(uci -c "$MOCK_CONFIG_DIR" -q get tachyon.GEMINI_TAILSCALE.tailscale_auth_key 2>/dev/null || true)"
            if [ -n "$key" ]; then
                mkdir -p "$MOCK_STATE_DIR"
                printf '%s\n' fixture-state >"$MOCK_STATE_DIR/tailscaled.state"
            fi
        fi
        ;;
    route_explain)
        target="${3:-}"
        if [ "$target" = gemini.google.com ]; then
            printf '%s\n' \
                ' Verdict: [PROXIED] (Rule: community_list:google_ai -> action tailscale)' \
                '  3. Section:     GEMINI_TAILSCALE (action: tailscale)'
        else
            printf '%s\n' ' Verdict: [DIRECT]' '  3. Section:     (none)'
        fi
        ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$BIN/tachyon" "$BIN/tachyon-core" "$BIN/init"

core_fixture="$("$BIN/tachyon-core" version)"
printf '%s\n' "$core_fixture" | grep -Fq '1.14.3-extended-2.7.3' || fail 'invalid core fixture version'
printf '%s\n' "$core_fixture" | grep -Fq 'with_tailscale' || fail 'core fixture lacks with_tailscale'

run_target() {
    env \
        PATH="$BIN:$PATH" \
        MOCK_CONFIG_DIR="$CONFIG_DIR" \
        MOCK_STATE_DIR="$STATE_ROOT/GEMINI_TAILSCALE" \
        MOCK_RELOAD_LOG="$WORK_DIR/reloads.log" \
        MOCK_RELOAD_FAIL="${MOCK_RELOAD_FAIL:-0}" \
        TACHYON_TS_CONFIG_FILE="$CONFIG_FILE" \
        TACHYON_TS_OPENWRT_RELEASE_FILE="$ROOT/openwrt_release" \
        TACHYON_TS_APK_DB="$ROOT/lib/apk/db/installed" \
        TACHYON_TS_MEMINFO_FILE="$ROOT/meminfo" \
        TACHYON_TS_UPTIME_FILE="$ROOT/uptime" \
        TACHYON_TS_SWAPS_FILE="$ROOT/swaps" \
        TACHYON_TS_OVERLAY_PATH="$ROOT/overlay" \
        TACHYON_TS_STATE_ROOT="$STATE_ROOT" \
        TACHYON_TS_BACKUP_ROOT="$BACKUP_ROOT" \
        TACHYON_TS_TACHYON_BIN="$BIN/tachyon" \
        TACHYON_TS_CORE_BIN="$BIN/tachyon-core" \
        TACHYON_TS_TACHYON_INIT="$BIN/init" \
        TACHYON_TS_CORE_INIT="$BIN/init" \
        TACHYON_TS_VALIDATOR_LIB="${REAL_PLANNER_LIB:-/usr/lib/tachyon}" \
        sh "$TARGET" "$@"
}

before="$(sha256sum "$CONFIG_FILE" | awk '{ print $1 }')"
if run_target --plan --exit-node exit-node.example.test >"$WORK_DIR/hostname.out" 2>&1; then
    fail 'hostname unexpectedly accepted by the pinned-engine gate'
fi
run_target --plan --exit-node 100.100.100.100 >"$WORK_DIR/plan.out"
after="$(sha256sum "$CONFIG_FILE" | awk '{ print $1 }')"
[ "$before" = "$after" ] || fail 'plan changed the configuration'
assert_contains "$WORK_DIR/plan.out" 'PLAN_OK=true'
assert_contains "$WORK_DIR/plan.out" 'SYSTEM_MUTATED=false'
assert_contains "$WORK_DIR/plan.out" 'COPIED_EXCLUDED_DEVICE_COUNT=2'
ok 'plan is read-only and reports resource gates'

key_file="$WORK_DIR/auth.key"
printf '%s\n' 'tskey-auth-fixture-only-not-secret' >"$key_file"
chmod 0600 "$key_file"
run_target --apply --exit-node 100.100.100.100 \
    --auth-key-file "$key_file" \
    --confirm CONFIGURE-GEMINI-TAILSCALE >"$WORK_DIR/apply.out"
[ ! -e "$key_file" ] || fail 'auth-key input file was not removed'
[ -z "$(uci -c "$CONFIG_DIR" -q get tachyon.GEMINI_TAILSCALE.tailscale_auth_key 2>/dev/null || true)" ] || fail 'auth key persisted in UCI'
[ "$(uci -c "$CONFIG_DIR" -q get tachyon.GEMINI_TAILSCALE.action)" = tailscale ] || fail 'tailscale action missing'
[ "$(uci -c "$CONFIG_DIR" -q get tachyon.GEMINI_TAILSCALE.community_lists)" = google_ai ] || fail 'google_ai list missing'
[ "$(uci -c "$CONFIG_DIR" -q get tachyon.GEMINI_TAILSCALE.excluded_ips | wc -w)" -eq 2 ] || fail 'excluded devices were not copied'
main_lists="$(uci -c "$CONFIG_DIR" -q get tachyon.main.community_lists)"
cond_lists="$(uci -c "$CONFIG_DIR" -q get tachyon.cond_main.community_lists)"
! printf '%s\n%s\n' "$main_lists" "$cond_lists" | grep -qw google_ai || fail 'google_ai remains in main'
assert_contains "$WORK_DIR/apply.out" 'TAILSCALE_GEMINI_OK=true'
assert_contains "$WORK_DIR/apply.out" 'AUTH_KEY_PERSISTED=false'
ok 'first Apply enrolls, scrubs the key and preserves exclusions'

run_target --verify >"$WORK_DIR/verify.out"
assert_contains "$WORK_DIR/verify.out" 'TAILSCALE_GEMINI_OK=true'
ok 'verify checks state, services and Gemini route'

stable="$(sha256sum "$CONFIG_FILE" | awk '{ print $1 }')"
run_target --apply --exit-node 100.100.100.100 \
    --confirm CONFIGURE-GEMINI-TAILSCALE >"$WORK_DIR/reapply.out"
[ "$stable" = "$(sha256sum "$CONFIG_FILE" | awk '{ print $1 }')" ] || fail 'idempotent Apply changed configuration'
assert_contains "$WORK_DIR/reapply.out" 'ALREADY_CONFIGURED=true'
ok 'repeated Apply is idempotent and needs no key'

write_original_config
rm -rf "$STATE_ROOT/GEMINI_TAILSCALE"
rollback_hash="$(sha256sum "$CONFIG_FILE" | awk '{ print $1 }')"
failed_key="$WORK_DIR/failed.key"
printf '%s\n' 'tskey-auth-fixture-only-not-secret' >"$failed_key"
chmod 0600 "$failed_key"
if MOCK_RELOAD_FAIL=1 run_target --apply --exit-node 100.100.100.100 \
    --auth-key-file "$failed_key" \
    --confirm CONFIGURE-GEMINI-TAILSCALE >"$WORK_DIR/fail.out" 2>&1; then
    fail 'Apply unexpectedly succeeded when reload failed'
fi
[ "$rollback_hash" = "$(sha256sum "$CONFIG_FILE" | awk '{ print $1 }')" ] || fail 'rollback did not restore exact configuration'
[ ! -e "$failed_key" ] || fail 'failed Apply left the auth-key file behind'
assert_contains "$WORK_DIR/fail.out" 'enrollment failed; restored'
ok 'failed enrollment restores the exact config and removes the key file'

write_original_config
uci -c "$CONFIG_DIR" -q del_list tachyon.main.community_lists=google_ai
uci -c "$CONFIG_DIR" -q del_list tachyon.cond_main.community_lists=google_ai
uci -c "$CONFIG_DIR" commit tachyon
rm -rf "$STATE_ROOT/GEMINI_TAILSCALE"
current_key="$WORK_DIR/current.key"
printf '%s\n' 'tskey-auth-fixture-only-not-secret' >"$current_key"
chmod 0600 "$current_key"
run_target --apply --exit-node 100.100.100.100 \
    --auth-key-file "$current_key" \
    --confirm CONFIGURE-GEMINI-TAILSCALE >"$WORK_DIR/current.out"
[ "$(uci -c "$CONFIG_DIR" -q get tachyon.main.community_lists)" = discord ] || fail 'current main list was changed'
[ "$(uci -c "$CONFIG_DIR" -q get tachyon.cond_main.community_lists)" = discord ] || fail 'current main condition was changed'
assert_contains "$WORK_DIR/current.out" 'TAILSCALE_GEMINI_OK=true'
ok 'Apply supports the current config where google_ai is already absent from main'

run_target --apply --exit-node 100.100.100.101 \
    --confirm CONFIGURE-GEMINI-TAILSCALE >"$WORK_DIR/change-exit.out"
[ "$(uci -c "$CONFIG_DIR" -q get tachyon.GEMINI_TAILSCALE.tailscale_exit_node)" = 100.100.100.101 ] || fail 'exit node was not changed'
assert_contains "$WORK_DIR/change-exit.out" 'TAILSCALE_GEMINI_OK=true'
ok 'existing registration supports changing exit-node IP without an auth key'

printf '%s\n' "PASS=$PASS FAIL=0"
