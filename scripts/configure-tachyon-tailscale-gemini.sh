#!/bin/sh
set -u

EXPECTED_RELEASE="${TACHYON_TS_EXPECTED_RELEASE:-25.12.2}"
EXPECTED_TACHYON="${TACHYON_TS_EXPECTED_TACHYON:-1.7.11}"
EXPECTED_ENGINE="${TACHYON_TS_EXPECTED_ENGINE:-1.14.3-extended-2.7.3}"
SECTION="${TACHYON_TS_SECTION:-GEMINI_TAILSCALE}"
CONDITION="cond_${SECTION}"
COMMUNITY_LIST="google_ai"
CONTROL_URL="${TACHYON_TS_CONTROL_URL:-https://controlplane.tailscale.com}"
HOSTNAME="${TACHYON_TS_HOSTNAME:-tachyon-gemini}"
SOURCE_SECTION="${TACHYON_TS_EXCLUDED_SOURCE_SECTION:-main}"
CONFIG_FILE="${TACHYON_TS_CONFIG_FILE:-/etc/config/tachyon}"
CONFIG_DIR="$(dirname "$CONFIG_FILE")"
OPENWRT_RELEASE_FILE="${TACHYON_TS_OPENWRT_RELEASE_FILE:-/etc/openwrt_release}"
APK_DB="${TACHYON_TS_APK_DB:-/lib/apk/db/installed}"
MEMINFO_FILE="${TACHYON_TS_MEMINFO_FILE:-/proc/meminfo}"
UPTIME_FILE="${TACHYON_TS_UPTIME_FILE:-/proc/uptime}"
SWAPS_FILE="${TACHYON_TS_SWAPS_FILE:-/proc/swaps}"
OVERLAY_PATH="${TACHYON_TS_OVERLAY_PATH:-/overlay}"
STATE_ROOT="${TACHYON_TS_STATE_ROOT:-/etc/tachyon/tailscale}"
STATE_DIR="$STATE_ROOT/$SECTION"
BACKUP_ROOT="${TACHYON_TS_BACKUP_ROOT:-/root/tachyon-backups}"
TACHYON_BIN="${TACHYON_TS_TACHYON_BIN:-/usr/bin/tachyon}"
CORE_BIN="${TACHYON_TS_CORE_BIN:-/usr/bin/tachyon-core}"
TACHYON_INIT="${TACHYON_TS_TACHYON_INIT:-/etc/init.d/tachyon}"
CORE_INIT="${TACHYON_TS_CORE_INIT:-/etc/init.d/tachyon-core}"
VALIDATOR_LIB="${TACHYON_TS_VALIDATOR_LIB:-/usr/lib/tachyon}"
MIN_MEM_KB="${TACHYON_TS_MIN_MEM_KB:-131072}"
MIN_SWAP_KB="${TACHYON_TS_MIN_SWAP_KB:-65536}"
MIN_OVERLAY_KB="${TACHYON_TS_MIN_OVERLAY_KB:-8192}"
MIN_OOM_AGE_SECONDS="${TACHYON_TS_MIN_OOM_AGE_SECONDS:-3600}"
CONFIRM_TOKEN="CONFIGURE-GEMINI-TAILSCALE"
MODE=""
EXIT_NODE=""
AUTH_KEY_FILE=""
CONFIRM=""
CANDIDATE_DIR=""
KEY_VALUE=""

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; return 1; }

cleanup() {
    KEY_VALUE=""
    if [ "$MODE" = apply ] && [ -n "$AUTH_KEY_FILE" ] && [ -f "$AUTH_KEY_FILE" ]; then
        rm -f "$AUTH_KEY_FILE"
    fi
    if [ -n "$CANDIDATE_DIR" ] && [ -d "$CANDIDATE_DIR" ]; then
        rm -rf "$CANDIDATE_DIR"
    fi
}
trap cleanup EXIT INT TERM

usage() {
    cat <<'EOF'
Usage:
  configure-tachyon-tailscale-gemini.sh --plan --exit-node TAILSCALE_IPV4
  configure-tachyon-tailscale-gemini.sh --apply --exit-node TAILSCALE_IPV4 \
      --auth-key-file /tmp/tailscale-auth.key \
      --confirm CONFIGURE-GEMINI-TAILSCALE
  configure-tachyon-tailscale-gemini.sh --verify

The auth-key file is required only for the first enrollment. It must contain
one tskey-auth-... value and have mode 0600. The script removes that file after
Apply and does not print the key. A repeated Apply uses the persisted userspace
Tailscale state and does not require a new key.
EOF
}

release_value() {
    sed -n "s/^$1='\(.*\)'/\1/p" "$OPENWRT_RELEASE_FILE" 2>/dev/null | head -n 1
}

package_version() {
    awk -v package="$1" '
        $0 == "P:" package { found=1; next }
        found && /^V:/ { sub(/^V:/, ""); print; exit }
        found && /^$/ { exit }
    ' "$APK_DB" 2>/dev/null
}

numeric_value() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

meminfo_kb() {
    awk -v key="$1" '$1 == key ":" { print $2; exit }' "$MEMINFO_FILE" 2>/dev/null
}

swap_total_kb() {
    awk 'NR > 1 { total += $3 } END { print total + 0 }' "$SWAPS_FILE" 2>/dev/null
}

overlay_free_kb() {
    df -Pk "$OVERLAY_PATH" 2>/dev/null | awk 'NR == 2 { print $4; exit }'
}

last_oom_age_seconds() {
    uptime_seconds="$(cut -d. -f1 "$UPTIME_FILE" 2>/dev/null)"
    last_oom="$(dmesg 2>/dev/null | sed -n 's/^\[\([0-9][0-9]*\)\..*Out of memory:.*/\1/p' | tail -n 1)"
    if ! numeric_value "$uptime_seconds"; then
        printf '%s\n' unknown
    elif [ -z "$last_oom" ]; then
        printf '%s\n' none
    elif numeric_value "$last_oom" && [ "$uptime_seconds" -ge "$last_oom" ]; then
        printf '%s\n' "$((uptime_seconds - last_oom))"
    else
        printf '%s\n' unknown
    fi
}

state_ready() {
    [ -d "$STATE_DIR" ] || return 1
    find "$STATE_DIR" -type f 2>/dev/null | grep -q .
}

safe_exit_node() {
    # This pinned engine cannot resolve an exit-node hostname during startup.
    printf '%s\n' "$1" | awk -F. '
        NF != 4 { exit 1 }
        { for (i=1; i<=4; i++) if ($i !~ /^[0-9]+$/ || $i > 255) exit 1 }
        $1 != 100 || $2 < 64 || $2 > 127 { exit 1 }
    '
}

safe_section() {
    case "$1" in
        ''|*[!A-Za-z0-9_]*) return 1 ;;
        *) return 0 ;;
    esac
}

safe_hostname() {
    case "$1" in
        ''|*[!A-Za-z0-9-]*) return 1 ;;
        -*) return 1 ;;
        *) return 0 ;;
    esac
}

safe_control_url() {
    case "$1" in
        https://*[!A-Za-z0-9._:/-]*) return 1 ;;
        https://*) return 0 ;;
        *) return 1 ;;
    esac
}

check_secret_file() {
    [ -f "$AUTH_KEY_FILE" ] || fail "auth-key file is missing: $AUTH_KEY_FILE" || return 1
    [ ! -L "$AUTH_KEY_FILE" ] || fail 'auth-key file must not be a symlink' || return 1
    if command -v stat >/dev/null 2>&1; then
        mode="$(stat -c '%a' "$AUTH_KEY_FILE" 2>/dev/null || true)"
    elif busybox stat --help >/dev/null 2>&1; then
        mode="$(busybox stat -c '%a' "$AUTH_KEY_FILE" 2>/dev/null || true)"
    else
        # BusyBox in the target OpenWrt image has neither stat nor find -printf.
        # shellcheck disable=SC2012
        permissions="$(LC_ALL=C ls -ld "$AUTH_KEY_FILE" 2>/dev/null | awk '{ print $1; exit }')"
        [ "$permissions" = '-rw-------' ] || fail 'auth-key file permissions must be -rw-------' || return 1
        mode=600
    fi
    [ "$mode" = 600 ] || fail 'auth-key file mode must be exactly 0600' || return 1
    KEY_VALUE="$(sed -n '1p' "$AUTH_KEY_FILE")"
    [ -n "$KEY_VALUE" ] || fail 'auth-key file is empty' || return 1
    [ "$(wc -l <"$AUTH_KEY_FILE" | tr -d ' ')" -le 1 ] || fail 'auth-key file must contain one line' || return 1
    case "$KEY_VALUE" in
        tskey-auth-* )
            case "$KEY_VALUE" in
                *[!A-Za-z0-9-]*) fail 'auth-key file contains unsafe characters'; return 1 ;;
            esac
            ;;
        *) fail 'auth-key file does not contain a Tailscale auth key'; return 1 ;;
    esac
}

compatibility_check() {
    [ "$(id -u)" = 0 ] || fail 'run as root' || return 1
    for cmd in awk cp cut date df dmesg find grep ls sed uci; do
        command -v "$cmd" >/dev/null 2>&1 || fail "$cmd is required" || return 1
    done
    [ -r "$CONFIG_FILE" ] || fail "Tachyon config is missing: $CONFIG_FILE" || return 1
    [ -x "$TACHYON_BIN" ] || fail 'Tachyon CLI is missing' || return 1
    [ -x "$CORE_BIN" ] || fail 'tachyon-core is missing' || return 1
    [ -x "$TACHYON_INIT" ] || fail 'Tachyon init script is missing' || return 1
    [ -x "$CORE_INIT" ] || fail 'tachyon-core init script is missing' || return 1

    release="$(release_value DISTRIB_RELEASE)"
    tachyon_version="$(package_version tachyon)"
    core_info="$($CORE_BIN version 2>/dev/null)"
    [ "$release" = "$EXPECTED_RELEASE" ] || fail "expected OpenWrt $EXPECTED_RELEASE, found ${release:-unknown}" || return 1
    case "$tachyon_version" in
        "$EXPECTED_TACHYON"|"$EXPECTED_TACHYON"-r*) ;;
        *) fail "expected Tachyon $EXPECTED_TACHYON, found ${tachyon_version:-unknown}"; return 1 ;;
    esac
    printf '%s\n' "$core_info" | grep -Fq "$EXPECTED_ENGINE" || fail 'unexpected tachyon-core version' || return 1
    printf '%s\n' "$core_info" | grep -Fq 'with_tailscale' || fail 'active core lacks with_tailscale' || return 1

    section_type="$(uci -c "$CONFIG_DIR" -q get "tachyon.$SECTION" 2>/dev/null || true)"
    if [ -n "$section_type" ] && [ "$section_type" != section ]; then
        fail "$SECTION already exists with type '$section_type'"
        return 1
    fi
    existing_action="$(uci -c "$CONFIG_DIR" -q get "tachyon.$SECTION.action" 2>/dev/null || true)"
    if [ -n "$existing_action" ] && [ "$existing_action" != tailscale ]; then
        fail "$SECTION already exists with action '$existing_action'"
        return 1
    fi
    condition_type="$(uci -c "$CONFIG_DIR" -q get "tachyon.$CONDITION" 2>/dev/null || true)"
    if [ -n "$condition_type" ] && [ "$condition_type" != condition ]; then
        fail "$CONDITION already exists with type '$condition_type'"
        return 1
    fi
}

resource_check() {
    mem_available="$(meminfo_kb MemAvailable)"
    swap_total="$(swap_total_kb)"
    overlay_free="$(overlay_free_kb)"
    oom_age="$(last_oom_age_seconds)"
    numeric_value "$mem_available" || fail 'cannot determine MemAvailable' || return 1
    numeric_value "$swap_total" || fail 'cannot determine swap size' || return 1
    numeric_value "$overlay_free" || fail 'cannot determine overlay free space' || return 1
    [ "$mem_available" -ge "$MIN_MEM_KB" ] || fail "MemAvailable is below ${MIN_MEM_KB} KiB" || return 1
    [ "$swap_total" -ge "$MIN_SWAP_KB" ] || fail "active swap is below ${MIN_SWAP_KB} KiB" || return 1
    [ "$overlay_free" -ge "$MIN_OVERLAY_KB" ] || fail "overlay free space is below ${MIN_OVERLAY_KB} KiB" || return 1
    case "$oom_age" in
        none) ;;
        unknown) fail 'cannot determine age of the last OOM event'; return 1 ;;
        *) [ "$oom_age" -ge "$MIN_OOM_AGE_SECONDS" ] || fail "last OOM is newer than ${MIN_OOM_AGE_SECONDS} seconds" || return 1 ;;
    esac
}

token_count() {
    printf '%s\n' "$1" | awk '{ n += NF } END { print n + 0 }'
}

remove_exact_list_token() {
    config_dir="$1"
    section="$2"
    option="$3"
    unwanted="$4"
    values="$(uci -c "$config_dir" -q get "tachyon.$section.$option" 2>/dev/null || true)"
    [ -n "$values" ] || return 0
    uci -c "$config_dir" -q delete "tachyon.$section.$option" 2>/dev/null || true
    for value in $values; do
        [ "$value" = "$unwanted" ] && continue
        uci -c "$config_dir" -q add_list "tachyon.$section.$option=$value" || return 1
    done
}

prepare_candidate() {
    config_dir="$1"
    include_key="$2"
    mkdir -m 0700 "$config_dir" || return 1
    cp -p "$CONFIG_FILE" "$config_dir/tachyon" || return 1
    chmod 0600 "$config_dir/tachyon" || return 1

    uci -c "$config_dir" -q delete "tachyon.$SECTION" 2>/dev/null || true
    uci -c "$config_dir" -q delete "tachyon.$CONDITION" 2>/dev/null || true
    uci -c "$config_dir" -q batch <<EOF || return 1
set tachyon.$SECTION=section
set tachyon.$SECTION.label='Gemini via Tailscale'
set tachyon.$SECTION.enabled='1'
set tachyon.$SECTION.action='tailscale'
add_list tachyon.$SECTION.condition_refs='$CONDITION'
add_list tachyon.$SECTION.community_lists='$COMMUNITY_LIST'
set tachyon.$SECTION.tailscale_control_url='$CONTROL_URL'
set tachyon.$SECTION.tailscale_hostname='$HOSTNAME'
set tachyon.$SECTION.tailscale_ephemeral='0'
set tachyon.$SECTION.tailscale_accept_routes='1'
set tachyon.$SECTION.tailscale_exit_node='$EXIT_NODE'
set tachyon.$SECTION.tailscale_exit_node_allow_lan_access='1'
set tachyon.$CONDITION=condition
set tachyon.$CONDITION.label='Google AI'
set tachyon.$CONDITION.enabled='1'
set tachyon.$CONDITION.condition_type='atomic'
add_list tachyon.$CONDITION.community_lists='$COMMUNITY_LIST'
EOF

    excluded="$(uci -c "$config_dir" -q get "tachyon.$SOURCE_SECTION.excluded_ips" 2>/dev/null || true)"
    for address in $excluded; do
        uci -c "$config_dir" -q add_list "tachyon.$SECTION.excluded_ips=$address" || return 1
        uci -c "$config_dir" -q add_list "tachyon.$CONDITION.excluded_ips=$address" || return 1
    done
    remove_exact_list_token "$config_dir" main community_lists "$COMMUNITY_LIST" || return 1
    remove_exact_list_token "$config_dir" cond_main community_lists "$COMMUNITY_LIST" || return 1

    if [ "$include_key" = 1 ]; then
        uci -c "$config_dir" -q set "tachyon.$SECTION.tailscale_auth_key=$KEY_VALUE" || return 1
    else
        uci -c "$config_dir" -q delete "tachyon.$SECTION.tailscale_auth_key" 2>/dev/null || true
    fi
    uci -c "$config_dir" -q reorder "tachyon.$SECTION=1" || return 1
    uci -c "$config_dir" -q commit tachyon || return 1
    chmod 0600 "$config_dir/tachyon" || return 1
}

validate_candidate() {
    candidate="$1"
    log_file="$2"
    if ! "$TACHYON_BIN" config_validate "$candidate" >"$log_file" 2>&1; then
        # 1.7.11 planner omits tailscale although the runtime validator and
        # generator support it. Correct only this omission in a private copy.
        grep -Fq "unsupported action 'tailscale'" "$log_file" || {
            fail 'Tachyon rejected the candidate configuration (not the known tailscale planner defect)'
            return 1
        }
        planner="$VALIDATOR_LIB/service/config_plan.uc"
        planner_hash="$(sha256sum "$planner" 2>/dev/null | awk '{print $1}')"
        [ "$planner_hash" = 997ee8ee8f667ae625c8c6d48d100169ddf518e612fb468ecde7cd258d51c4f0 ] || {
            fail 'planner hash differs from verified 1.7.11; refusing compatibility patch'
            return 1
        }
        command -v ucode >/dev/null 2>&1 || return 1
        private_planner="$CANDIDATE_DIR/config_plan.uc"
        sed 's/connection: true, group: true, desync: true, direct: true,/connection: true, group: true, desync: true, direct: true, tailscale: true,/' \
            "$planner" >"$private_planner" || return 1
        if ! TACHYON_LIB="$VALIDATOR_LIB" ucode -L "$VALIDATOR_LIB" \
            "$private_planner" validate "$candidate" >"$log_file" 2>&1; then
            fail 'candidate rejected by the corrected 1.7.11 planner'
            return 1
        fi
        log 'PLANNER_1_7_11_PRIVATE_COMPATIBILITY_FIX=true'
    fi
}

verify_config() {
    config_dir="$1"
    [ "$(uci -c "$config_dir" -q get "tachyon.$SECTION")" = section ] || fail 'Tailscale section is missing' || return 1
    [ "$(uci -c "$config_dir" -q get "tachyon.$SECTION.action")" = tailscale ] || fail 'Tailscale action is incorrect' || return 1
    [ "$(uci -c "$config_dir" -q get "tachyon.$SECTION.tailscale_exit_node")" = "$EXIT_NODE" ] || fail 'exit node does not match' || return 1
    [ "$(uci -c "$config_dir" -q get "tachyon.$SECTION.community_lists")" = "$COMMUNITY_LIST" ] || fail 'Google AI list is not exact' || return 1
    [ "$(uci -c "$config_dir" -q get "tachyon.$CONDITION.community_lists")" = "$COMMUNITY_LIST" ] || fail 'Google AI condition is not exact' || return 1
    [ -z "$(uci -c "$config_dir" -q get "tachyon.$SECTION.tailscale_auth_key" 2>/dev/null || true)" ] || fail 'auth key remains in persistent configuration' || return 1
    main_lists="$(uci -c "$config_dir" -q get tachyon.main.community_lists 2>/dev/null || true)"
    cond_lists="$(uci -c "$config_dir" -q get tachyon.cond_main.community_lists 2>/dev/null || true)"
    [ "$(printf '%s\n%s\n' "$main_lists" "$cond_lists" | awk -v x="$COMMUNITY_LIST" '{for(i=1;i<=NF;i++) if($i==x)n++} END{print n+0}')" -eq 0 ] || fail 'Google AI remains in main' || return 1
}

service_running() {
    "$1" status 2>/dev/null | grep -q running
}

runtime_verify() {
    limit=90
    while [ "$limit" -gt 0 ]; do
        if service_running "$TACHYON_INIT" && service_running "$CORE_INIT" && state_ready; then
            break
        fi
        sleep 2
        limit=$((limit - 2))
    done
    [ "$limit" -gt 0 ] || fail 'Tachyon services or userspace Tailscale state did not become ready' || return 1
    route="$($TACHYON_BIN route_explain 127.0.0.1 gemini.google.com 443 tcp 2>/dev/null)"
    printf '%s\n' "$route" | grep -q 'Verdict: \[PROXIED\]' || fail 'Gemini is not routed through a proxy endpoint' || return 1
    printf '%s\n' "$route" | grep -Fq "Section:     $SECTION" || fail "Gemini did not match $SECTION" || return 1
}

restore_backup() {
    backup_file="$1"
    cp "$backup_file" "$CONFIG_FILE" 2>/dev/null || return 1
    chmod 0600 "$CONFIG_FILE" 2>/dev/null || true
    "$TACHYON_BIN" reload tailscale-gemini-rollback >/dev/null 2>&1 || true
}

print_plan() {
    resource_check || return 1
    state=false
    state_ready && state=true
    excluded="$(uci -c "$CONFIG_DIR" -q get "tachyon.$SOURCE_SECTION.excluded_ips" 2>/dev/null || true)"
    log 'PLAN_OK=true'
    log "OPENWRT_RELEASE=$EXPECTED_RELEASE"
    log "TACHYON_VERSION=$EXPECTED_TACHYON"
    log "ENGINE_VERSION=$EXPECTED_ENGINE"
    log "SECTION=$SECTION"
    log 'ACTION=tailscale'
    log "COMMUNITY_LIST=$COMMUNITY_LIST"
    log 'EXIT_NODE_PROVIDED=true'
    log "PERSISTED_TAILSCALE_STATE=$state"
    log "COPIED_EXCLUDED_DEVICE_COUNT=$(token_count "$excluded")"
    log "MEM_AVAILABLE_KB=$(meminfo_kb MemAvailable)"
    log "SWAP_TOTAL_KB=$(swap_total_kb)"
    log "OVERLAY_FREE_KB=$(overlay_free_kb)"
    log "LAST_OOM_AGE_SECONDS=$(last_oom_age_seconds)"
    log 'AUTH_KEY_WILL_NOT_BE_PERSISTED=true'
    log 'SYSTEM_MUTATED=false'
}

apply_change() {
    resource_check || return 1
    first_enrollment=0
    if ! state_ready; then
        first_enrollment=1
        [ -n "$AUTH_KEY_FILE" ] || fail 'first enrollment requires --auth-key-file' || return 1
        check_secret_file || return 1
    fi

    CANDIDATE_DIR="/tmp/tachyon-tailscale-gemini.$$.candidate"
    prepare_candidate "$CANDIDATE_DIR" "$first_enrollment" || return 1
    validate_candidate "$CANDIDATE_DIR/tachyon" "$CANDIDATE_DIR/validate-with-key.log" || return 1

    auth_free_dir="$CANDIDATE_DIR/auth-free"
    prepare_candidate "$auth_free_dir" 0 || return 1
    validate_candidate "$auth_free_dir/tachyon" "$CANDIDATE_DIR/validate-without-key.log" || return 1
    verify_config "$auth_free_dir" || return 1

    if cmp -s "$CONFIG_FILE" "$auth_free_dir/tachyon" && state_ready; then
        [ -z "$AUTH_KEY_FILE" ] || rm -f "$AUTH_KEY_FILE"
        log 'ALREADY_CONFIGURED=true'
        log 'SYSTEM_MUTATED=false'
        return 0
    fi

    stamp="$(date +%Y%m%d-%H%M%S)"
    backup_dir="$BACKUP_ROOT/tailscale-gemini.$stamp.$$"
    mkdir -p "$BACKUP_ROOT" || return 1
    chmod 0700 "$BACKUP_ROOT" || return 1
    mkdir -m 0700 "$backup_dir" || return 1
    cp -p "$CONFIG_FILE" "$backup_dir/tachyon" || return 1
    chmod 0600 "$backup_dir/tachyon" || return 1

    if ! cp "$CANDIDATE_DIR/tachyon" "$CONFIG_FILE" || ! chmod 0600 "$CONFIG_FILE"; then
        restore_backup "$backup_dir/tachyon" || true
        fail "could not install candidate; restored $backup_dir/tachyon"
        return 1
    fi

    if ! "$TACHYON_BIN" reload tailscale-gemini-enroll >/dev/null 2>&1 || ! state_ready; then
        restore_backup "$backup_dir/tachyon" || true
        [ -z "$AUTH_KEY_FILE" ] || rm -f "$AUTH_KEY_FILE"
        fail "enrollment failed; restored $backup_dir/tachyon"
        return 1
    fi

    if ! cp "$auth_free_dir/tachyon" "$CONFIG_FILE" || ! chmod 0600 "$CONFIG_FILE" ||
       ! "$TACHYON_BIN" reload tailscale-gemini-scrub-key >/dev/null 2>&1 ||
       ! runtime_verify; then
        restore_backup "$backup_dir/tachyon" || true
        [ -z "$AUTH_KEY_FILE" ] || rm -f "$AUTH_KEY_FILE"
        fail "post-enrollment verification failed; restored $backup_dir/tachyon"
        return 1
    fi

    [ -z "$AUTH_KEY_FILE" ] || rm -f "$AUTH_KEY_FILE"
    verify_config "$CONFIG_DIR" || return 1
    log 'TAILSCALE_GEMINI_OK=true'
    log "SECTION=$SECTION"
    log 'EXIT_NODE_CONFIGURED=true'
    log 'AUTH_KEY_PERSISTED=false'
    log "BACKUP_DIR=$backup_dir"
}

verify_live() {
    EXIT_NODE="$(uci -c "$CONFIG_DIR" -q get "tachyon.$SECTION.tailscale_exit_node" 2>/dev/null || true)"
    [ -n "$EXIT_NODE" ] || fail 'configured exit node is missing' || return 1
    verify_config "$CONFIG_DIR" || return 1
    resource_check || return 1
    runtime_verify || return 1
    log 'TAILSCALE_GEMINI_OK=true'
    log 'AUTH_KEY_PERSISTED=false'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --plan|--apply|--verify)
            [ -z "$MODE" ] || { fail 'choose exactly one mode'; exit 2; }
            MODE="${1#--}"
            ;;
        --exit-node)
            shift; [ "$#" -gt 0 ] || { fail '--exit-node requires a value'; exit 2; }
            EXIT_NODE="$1"
            ;;
        --auth-key-file)
            shift; [ "$#" -gt 0 ] || { fail '--auth-key-file requires a path'; exit 2; }
            AUTH_KEY_FILE="$1"
            ;;
        --confirm)
            shift; [ "$#" -gt 0 ] || { fail '--confirm requires a value'; exit 2; }
            CONFIRM="$1"
            ;;
        --help|-h) usage; exit 0 ;;
        *) fail "unknown argument: $1"; usage >&2; exit 2 ;;
    esac
    shift
done

[ -n "$MODE" ] || { fail 'choose --plan, --apply or --verify'; exit 2; }
if [ "$MODE" != verify ]; then
    safe_exit_node "$EXIT_NODE" || { fail 'this engine requires an exit-node Tailscale IPv4 in 100.64.0.0/10, not a hostname'; exit 2; }
fi
safe_section "$SECTION" || { fail 'unsafe section name'; exit 2; }
safe_hostname "$HOSTNAME" || { fail 'unsafe Tailscale hostname'; exit 2; }
safe_control_url "$CONTROL_URL" || { fail 'unsafe Tailscale control URL'; exit 2; }
compatibility_check || exit 1

case "$MODE" in
    plan) print_plan ;;
    verify) verify_live ;;
    apply)
        [ "$CONFIRM" = "$CONFIRM_TOKEN" ] || { fail "Apply requires --confirm $CONFIRM_TOKEN"; exit 2; }
        apply_change
        ;;
esac
