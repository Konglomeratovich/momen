#!/bin/sh
set -u

EXPECTED_RELEASE="25.12.2"
EXPECTED_ARCH="aarch64_cortex-a53"
EXPECTED_TARGET="mediatek/filogic"
PRIMARY_DOH_FILE="${TACHYON_PRIMARY_DOH_FILE:-/tmp/oxidns-doh.url}"
GOOGLE_DOH="https://dns.google/dns-query"
YANDEX_DOH="https://common.dot.dns.yandex.net/dns-query"
GOOGLE_DOT="tls://dns.google"
YANDEX_DOT="tls://common.dot.dns.yandex.net"
CONFIRM_TOKEN="CONFIGURE-TACHYON-DNS"
ROUTE_TEST_SOURCE="${TACHYON_ROUTE_TEST_SOURCE:-127.0.0.1}"
MODE=""

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; return 1; }

release_value() {
    sed -n "s/^$1='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null | head -n 1
}

is_installed() {
    grep -q "^P:$1$" /lib/apk/db/installed 2>/dev/null
}

compatibility_check() {
    [ "$(id -u)" = 0 ] || fail 'run as root' || return 1
    command -v uci >/dev/null 2>&1 || fail 'uci is required' || return 1
    [ -x /usr/bin/tachyon ] || fail 'Tachyon CLI is missing' || return 1
    [ -x /usr/bin/tachyon-core ] || fail 'Tachyon core is missing' || return 1
    is_installed tachyon || fail 'Tachyon package is not installed' || return 1
    ! is_installed podkop || fail 'Podkop is still installed' || return 1

    if [ "${TACHYON_TEST_MODE:-0}" != 1 ]; then
        [ "$(release_value DISTRIB_RELEASE)" = "$EXPECTED_RELEASE" ] || fail "only OpenWrt $EXPECTED_RELEASE is supported" || return 1
        [ "$(release_value DISTRIB_ARCH)" = "$EXPECTED_ARCH" ] || fail "only $EXPECTED_ARCH is supported" || return 1
        [ "$(release_value DISTRIB_TARGET)" = "$EXPECTED_TARGET" ] || fail "only $EXPECTED_TARGET is supported" || return 1
        /usr/bin/tachyon-core version 2>/dev/null | grep -q '1\.14\.3-extended-2\.7\.3' || fail 'unexpected Tachyon core version' || return 1
    fi
}

token_count() {
    printf '%s\n' "$1" | awk '{ count += NF } END { print count + 0 }'
}

exact_token_count() {
    printf '%s\n' "$1" | awk -v wanted="$2" '{ for (i = 1; i <= NF; i++) if ($i == wanted) count++ } END { print count + 0 }'
}

print_plan() {
    main_text="$(uci -q get tachyon.main.user_domains_text)"
    direct_text="$(uci -q get tachyon.DIRECT.user_domains_text)"
    dns_count="$(token_count "$(uci -q get tachyon.settings.dns_server)")"
    bootstrap_count="$(token_count "$(uci -q get tachyon.settings.bootstrap_dns_server)")"
    log 'PLAN_OK=true'
    log "CURRENT_DNS_TYPE=$(uci -q get tachyon.settings.dns_type)"
    log "CURRENT_DNS_SERVER_COUNT=$dns_count"
    log "CURRENT_BOOTSTRAP_SERVER_COUNT=$bootstrap_count"
    log "MAIN_PLEX_OCCURRENCES=$(exact_token_count "$main_text" plex.tv)"
    log "DIRECT_PLEX_OCCURRENCES=$(exact_token_count "$direct_text" plex.tv)"
    log 'TARGET_MAIN_DNS=private-oxidns-doh,google-doh,yandex-doh'
    log 'TARGET_BOOTSTRAP_DNS=google-dot,yandex-dot'
    log 'TARGET_UPSTREAM_MODE=sequential'
    log 'PLAINTEXT_FALLBACKS=false'
    log 'TARGET_PLEX_ROUTE=DIRECT-only'
    log 'SYSTEM_MUTATED=false'
}

read_primary_doh() {
    [ -s "$PRIMARY_DOH_FILE" ] || fail "private OxiDNS URL file is missing: $PRIMARY_DOH_FILE" || return 1
    primary_doh="$(sed -n '1p' "$PRIMARY_DOH_FILE")"
    case "$primary_doh" in
        https://*) ;;
        *) fail 'private OxiDNS value must be a complete https:// DoH URL'; return 1 ;;
    esac
    case "$primary_doh" in
        *[!A-Za-z0-9._~:/?#@%+=,-]*) fail 'private OxiDNS URL contains unsupported characters'; return 1 ;;
    esac
    if [ "$primary_doh" = "$GOOGLE_DOH" ] || [ "$primary_doh" = "$YANDEX_DOH" ]; then
        fail 'private OxiDNS URL duplicates a public fallback'
        return 1
    fi
}

prepare_candidate() {
    candidate_dir="$1"
    mkdir -m 0700 "$candidate_dir" || return 1
    cp -p /etc/config/tachyon "$candidate_dir/tachyon" || return 1

    uci -c "$candidate_dir" -q delete tachyon.settings.dns_server 2>/dev/null || true
    uci -c "$candidate_dir" -q delete tachyon.settings.dns_fallback_server 2>/dev/null || true
    uci -c "$candidate_dir" -q delete tachyon.settings.bootstrap_dns_server 2>/dev/null || true
    {
        printf "add_list tachyon.settings.dns_server='%s'\n" "$primary_doh"
        printf "add_list tachyon.settings.dns_server='%s'\n" "$GOOGLE_DOH"
        printf "add_list tachyon.settings.dns_server='%s'\n" "$YANDEX_DOH"
        printf 'set tachyon.settings.dns_type=doh\n'
        printf 'set tachyon.settings.dns_upstream_mode=sequential\n'
        printf 'set tachyon.settings.fallback_wan_main=0\n'
        printf "add_list tachyon.settings.bootstrap_dns_server='%s'\n" "$GOOGLE_DOT"
        printf "add_list tachyon.settings.bootstrap_dns_server='%s'\n" "$YANDEX_DOT"
        printf 'set tachyon.settings.fallback_wan_bootstrap=0\n'
    } | uci -c "$candidate_dir" -q batch || return 1

    main_text="$(uci -c "$candidate_dir" -q get tachyon.main.user_domains_text)"
    main_count_before="$(token_count "$main_text")"
    main_plex_before="$(exact_token_count "$main_text" plex.tv)"
    [ "$main_plex_before" -gt 0 ] || fail 'plex.tv is not present in main; refusing an unexpected route layout' || return 1
    filtered_main="$(printf '%s\n' "$main_text" | awk '{ for (i = 1; i <= NF; i++) if ($i != "plex.tv") print $i }')"
    [ "$(token_count "$filtered_main")" -eq "$((main_count_before - main_plex_before))" ] || fail 'main rule count changed unexpectedly' || return 1
    uci -c "$candidate_dir" -q set "tachyon.main.user_domains_text=$filtered_main" || return 1
    uci -c "$candidate_dir" -q commit tachyon || return 1
    chmod 0600 "$candidate_dir/tachyon" || return 1
}

verify_config_values() {
    config_dir="$1"
    dns_values="$(uci -c "$config_dir" -q get tachyon.settings.dns_server)"
    set -f
    # shellcheck disable=SC2086
    set -- $dns_values
    set +f
    [ "$#" -eq 3 ] || fail 'main DNS list does not contain exactly three servers' || return 1
    [ "$1" = "$primary_doh" ] || fail 'private OxiDNS is not first' || return 1
    [ "$2" = "$GOOGLE_DOH" ] || fail 'Google DoH is not second' || return 1
    [ "$3" = "$YANDEX_DOH" ] || fail 'Yandex DoH is not third' || return 1
    [ "$(uci -c "$config_dir" -q get tachyon.settings.dns_type)" = doh ] || fail 'DNS type is not DoH' || return 1
    [ "$(uci -c "$config_dir" -q get tachyon.settings.dns_upstream_mode)" = sequential ] || fail 'DNS failover is not sequential' || return 1
    [ -z "$(uci -c "$config_dir" -q get tachyon.settings.dns_fallback_server)" ] || fail 'plaintext explicit fallback remains configured' || return 1
    [ "$(uci -c "$config_dir" -q get tachyon.settings.fallback_wan_main)" = 0 ] || fail 'WAN main fallback is enabled' || return 1
    [ "$(uci -c "$config_dir" -q get tachyon.settings.fallback_wan_bootstrap)" = 0 ] || fail 'WAN bootstrap fallback is enabled' || return 1

    bootstrap_values="$(uci -c "$config_dir" -q get tachyon.settings.bootstrap_dns_server)"
    set -f
    # shellcheck disable=SC2086
    set -- $bootstrap_values
    set +f
    [ "$#" -eq 2 ] && [ "$1" = "$GOOGLE_DOT" ] && [ "$2" = "$YANDEX_DOT" ] || fail 'encrypted bootstrap order is incorrect' || return 1

    main_text="$(uci -c "$config_dir" -q get tachyon.main.user_domains_text)"
    direct_text="$(uci -c "$config_dir" -q get tachyon.DIRECT.user_domains_text)"
    [ "$(exact_token_count "$main_text" plex.tv)" -eq 0 ] || fail 'plex.tv remains in main' || return 1
    [ "$(exact_token_count "$direct_text" plex.tv)" -eq 1 ] || fail 'plex.tv is not present exactly once in DIRECT' || return 1
}

runtime_verify() {
    limit=60
    while [ "$limit" -gt 0 ]; do
        if /etc/init.d/tachyon status 2>/dev/null | grep -q running &&
           /etc/init.d/tachyon-core status 2>/dev/null | grep -q running &&
           dig @127.0.0.42 -p 53 github.com A +time=2 +tries=1 +short 2>/dev/null | grep -q .; then
            break
        fi
        sleep 2
        limit=$((limit - 2))
    done
    [ "$limit" -gt 0 ] || fail 'Tachyon services or DNS did not become ready' || return 1
    /usr/bin/tachyon route_explain "$ROUTE_TEST_SOURCE" plex.tv 443 tcp 2>/dev/null | grep -q 'Verdict: \[DIRECT\]' || fail 'plex.tv does not resolve to DIRECT' || return 1
    /usr/bin/tachyon route_explain "$ROUTE_TEST_SOURCE" discord.com 443 tcp 2>/dev/null | grep -q 'Verdict: \[PROXIED\]' || fail 'discord.com does not resolve to proxy' || return 1
}

apply_change() {
    read_primary_doh || return 1
    stamp="$(date +%Y%m%d-%H%M%S)"
    backup_dir="/tmp/tachyon-dns-backup.$stamp"
    candidate_dir="/tmp/tachyon-dns-candidate.$stamp"
    mkdir -m 0700 "$backup_dir" || return 1
    cp -p /etc/config/tachyon "$backup_dir/tachyon" || return 1
    prepare_candidate "$candidate_dir" || { rm -rf "$candidate_dir"; return 1; }
    verify_config_values "$candidate_dir" || { rm -rf "$candidate_dir"; return 1; }
    validation_log="$candidate_dir/config-validate.log"
    if ! /usr/bin/tachyon config_validate "$candidate_dir/tachyon" >"$validation_log" 2>&1; then
        if [ "${TACHYON_TEST_MODE:-0}" = 1 ]; then
            sed -n '1,80p' "$validation_log" >&2
        fi
        fail 'Tachyon rejected the candidate configuration'
        rm -rf "$candidate_dir"
        return 1
    fi

    if cmp -s /etc/config/tachyon "$candidate_dir/tachyon"; then
        rm -rf "$candidate_dir"
        rm -f "$PRIMARY_DOH_FILE"
        log 'ALREADY_CONFIGURED=true'
        log "BACKUP_DIR=$backup_dir"
        return 0
    fi

    if ! cp "$candidate_dir/tachyon" /etc/config/tachyon || ! chmod 0600 /etc/config/tachyon; then
        rm -rf "$candidate_dir"
        cp "$backup_dir/tachyon" /etc/config/tachyon 2>/dev/null || true
        chmod 0600 /etc/config/tachyon 2>/dev/null || true
        fail "could not install candidate; previous config restored from $backup_dir"
        return 1
    fi
    rm -rf "$candidate_dir"

    if [ "${TACHYON_TEST_MODE:-0}" != 1 ]; then
        if ! /usr/bin/tachyon reload dns-order-change >/dev/null 2>&1 || ! runtime_verify; then
            cp "$backup_dir/tachyon" /etc/config/tachyon
            chmod 0600 /etc/config/tachyon
            /usr/bin/tachyon reload dns-order-rollback >/dev/null 2>&1 || true
            fail "apply failed; previous config restored from $backup_dir"
            return 1
        fi
    fi

    rm -f "$PRIMARY_DOH_FILE"
    log 'DNS_CONFIGURATION_OK=true'
    log 'MAIN_DNS_ORDER=private-oxidns-doh,google-doh,yandex-doh'
    log 'BOOTSTRAP_ORDER=google-dot,yandex-dot'
    log 'PLEX_DIRECT=true'
    log "BACKUP_DIR=$backup_dir"
}

verify_live() {
    primary_doh="$(uci -q get tachyon.settings.dns_server | awk '{ print $1 }')"
    case "$primary_doh" in
        https://*) ;;
        *) fail 'first live DNS server is not a DoH URL'; return 1 ;;
    esac
    verify_config_values /etc/config || return 1
    if [ "${TACHYON_TEST_MODE:-0}" != 1 ]; then
        runtime_verify || return 1
    fi
    log 'DNS_CONFIGURATION_OK=true'
}

confirm=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --plan) [ -z "$MODE" ] || { fail 'choose one mode'; exit 2; }; MODE=plan ;;
        --apply) [ -z "$MODE" ] || { fail 'choose one mode'; exit 2; }; MODE=apply ;;
        --verify) [ -z "$MODE" ] || { fail 'choose one mode'; exit 2; }; MODE=verify ;;
        --confirm) shift; [ "$#" -gt 0 ] || exit 2; confirm="$1" ;;
        *) fail "unknown argument: $1"; exit 2 ;;
    esac
    shift
done

[ -n "$MODE" ] || { fail 'use --plan, --apply or --verify'; exit 2; }
compatibility_check || exit 1

case "$MODE" in
    plan) print_plan ;;
    verify) verify_live ;;
    apply)
        [ "$confirm" = "$CONFIRM_TOKEN" ] || { fail "Apply requires --confirm $CONFIRM_TOKEN"; exit 2; }
        apply_change
        ;;
esac
