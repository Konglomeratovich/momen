#!/bin/ash
set -eu

target="${PODKOP_TARGET:-/usr/bin/podkop}"
constants="${PODKOP_CONSTANTS:-/usr/lib/podkop/constants.sh}"
backup_dir="${PODKOP_BACKUP_DIR:-/root}"
podkop_config="${PODKOP_CONFIG_FILE:-/etc/config/podkop}"
openwrt_release_file="${PODKOP_OPENWRT_RELEASE_FILE:-/etc/openwrt_release}"
os_release_file="${PODKOP_OS_RELEASE_FILE:-/etc/os-release}"
direct_section="${PODKOP_DIRECT_SECTION:-DIRECT}"
tld_list_file="${PODKOP_TLD_LIST_FILE:-/etc/momen-r1-cyrillic-tlds.lst}"
needle='config=$(sing_box_cm_patch_dns_route_rule "$config" "$SB_FAKEIP_DNS_RULE_TAG" "rule_set" "$ruleset_tag")'
guard='if [ "$route_rule_tag" != "$SB_EXCLUSION_RULE_TAG" ]; then'
configure_yandex_doh=0
configure_direct=0
configure_download_proxy=0
download_proxy_section="${PODKOP_DOWNLOAD_PROXY_SECTION:-main}"
config_backup=''
catalog_url='https://raw.githubusercontent.com/Konglomeratovich/momen/main/assets/r1.gz'
catalog_sha256='026e1b9f7bcdfb2f86ff6b1e61df360a19fa63f079c544d38ee7c55f8091b27c'
catalog_expected_count='724'
catalog_archive=''
catalog_plain=''
direct_domains=''
direct_text_domains=''
tld_domains=''
temporary=''
runtime_config=''
binary_backup=''
tld_list_backup=''
tld_list_created=0
live_catalog=False

cleanup() {
    [ -z "$temporary" ] || rm -f "$temporary"
    [ -z "$catalog_archive" ] || rm -f "$catalog_archive"
    [ -z "$catalog_plain" ] || rm -f "$catalog_plain"
    [ -z "$runtime_config" ] || rm -f "$runtime_config"
}
trap cleanup EXIT

usage() {
    echo "Usage: $0 [--configure-yandex-doh] [--configure-direct] [--configure-download-proxy] [--download-proxy-section NAME] [--configure-all]"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
    --configure-yandex-doh) configure_yandex_doh=1 ;;
    --configure-direct) configure_direct=1 ;;
    --configure-download-proxy) configure_download_proxy=1 ;;
    --download-proxy-section)
        if [ "$#" -lt 2 ]; then
            echo "ERROR: --download-proxy-section requires NAME" >&2
            exit 1
        fi
        configure_download_proxy=1
        download_proxy_section="$2"
        shift
        ;;
    --configure-all)
        configure_yandex_doh=1
        configure_direct=1
        configure_download_proxy=1
        ;;
    --help)
        usage
        exit 0
        ;;
    *)
        echo "ERROR: unsupported argument: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
    shift
done

test -f "$target"
test -f "$constants"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: required command is unavailable: $1" >&2
        exit 1
    fi
}

for required_command in ash awk cp date df grep gzip head mktemp sed sha256sum wc; do
    require_command "$required_command"
done
if [ "$configure_yandex_doh" -eq 1 ] || [ "$configure_direct" -eq 1 ] || [ "$configure_download_proxy" -eq 1 ]; then
    require_command uci
fi
if [ "${PODKOP_SKIP_RELOAD:-0}" != '1' ]; then
    require_command jq
    require_command nslookup
    test -x /etc/init.d/podkop || {
        echo "ERROR: /etc/init.d/podkop is unavailable or not executable" >&2
        exit 1
    }
    test -x /etc/init.d/sing-box || {
        echo "ERROR: /etc/init.d/sing-box is unavailable or not executable" >&2
        exit 1
    }
fi

if [ "${PODKOP_SKIP_PLATFORM_CHECK:-0}" != "1" ]; then
    if [ ! -f "$openwrt_release_file" ]; then
        echo "ERROR: OpenWrt release metadata is unavailable: $openwrt_release_file" >&2
        exit 1
    fi
    # shellcheck disable=SC1091
    . "$openwrt_release_file"
    os_release_id=''
    os_release_name=''
    if [ -f "$os_release_file" ]; then
        os_release_id="$(. "$os_release_file"; printf '%s' "${ID:-}")"
        os_release_name="$(. "$os_release_file"; printf '%s' "${NAME:-}")"
    fi
    if [ "${DISTRIB_ID:-}" != 'OpenWrt' ] && [ "$os_release_id" != 'openwrt' ]; then
        echo "ERROR: this installer requires OpenWrt-compatible firmware (DISTRIB_ID=${DISTRIB_ID:-unknown}, ID=${os_release_id:-unknown})" >&2
        exit 1
    fi
    openwrt_major="${DISTRIB_RELEASE%%.*}"
    openwrt_minor="${DISTRIB_RELEASE#*.}"
    openwrt_minor="${openwrt_minor%%[^0-9]*}"
    case "$openwrt_major:$openwrt_minor" in
    *[!0-9:]* | :* | *:)
        echo "ERROR: cannot parse OpenWrt release: ${DISTRIB_RELEASE:-unknown}" >&2
        exit 1
        ;;
    esac
    if [ "$openwrt_major" -lt 24 ] || { [ "$openwrt_major" -eq 24 ] && [ "$openwrt_minor" -lt 10 ]; }; then
        echo "ERROR: OpenWrt 24.10 or newer is required (found ${DISTRIB_RELEASE:-unknown})" >&2
        exit 1
    fi
    filesystem_path='/'
    [ ! -d /overlay ] || filesystem_path='/overlay'
    available_kb="$(df -Pk "$filesystem_path" | awk 'NR == 2 { print $4 }')"
    target_size_bytes="$(wc -c < "$target" | tr -d '[:space:]')"
    target_size_kb=$(((target_size_bytes + 1023) / 1024))
    config_size_kb=0
    if [ -f "$podkop_config" ]; then
        config_size_bytes="$(wc -c < "$podkop_config" | tr -d '[:space:]')"
        config_size_kb=$(((config_size_bytes + 1023) / 1024))
    fi
    estimated_write_kb=$((target_size_kb * 4 + config_size_kb * 6 + 2048))
    retained_reserve_kb=12288
    required_free_kb=$((estimated_write_kb + retained_reserve_kb))
    if [ -z "$available_kb" ] || [ "$available_kb" -lt "$required_free_kb" ]; then
        echo "ERROR: insufficient free space (required_kb=$required_free_kb, available_kb=${available_kb:-unknown}, retained_reserve_kb=$retained_reserve_kb)" >&2
        exit 1
    fi
    echo "OPENWRT_DISTRIBUTION=${DISTRIB_ID:-${os_release_name:-OpenWrt}}"
    echo "OPENWRT_COMPATIBILITY_ID=${os_release_id:-openwrt}"
    echo "OPENWRT_VERSION=${DISTRIB_RELEASE}"
    echo "INSTALL_ESTIMATED_WRITE_KB=$estimated_write_kb"
    echo "RETAINED_FREE_RESERVE_KB=$retained_reserve_kb"
    echo "REQUIRED_FREE_SPACE_KB=$required_free_kb"
    echo "FREE_SPACE_KB=$available_kb"
fi

podkop_version_raw="${PODKOP_TEST_VERSION:-$(sed -n 's/^PODKOP_VERSION="\([^"]*\)".*/\1/p' "$constants" | head -n 1)}"
if [ "$podkop_version_raw" = '__COMPILED_VERSION_VARIABLE__' ]; then
    if [ "${PODKOP_ALLOW_UNCOMPILED:-0}" != '1' ]; then
        echo "ERROR: cannot determine installed Podkop version" >&2
        exit 1
    fi
    podkop_version_raw="${PODKOP_TEST_VERSION:-0.7.22}"
fi
case "$podkop_version_raw" in
v0.7.*) podkop_version="${podkop_version_raw#v}" ;;
*) podkop_version="$podkop_version_raw" ;;
esac
case "$podkop_version" in
0.7.*)
    podkop_patch="${podkop_version#0.7.}"
    podkop_patch="${podkop_patch%%[^0-9]*}"
    case "$podkop_patch" in
    '' | *[!0-9]*)
        echo "ERROR: cannot parse Podkop version: $podkop_version" >&2
        exit 1
        ;;
    esac
    if [ "$podkop_patch" -gt 22 ]; then
        echo "ERROR: supported Podkop versions are 0.7.0 through 0.7.22 (found $podkop_version)" >&2
        exit 1
    fi
    ;;
*)
    echo "ERROR: supported Podkop versions are 0.7.0 through 0.7.22 (found $podkop_version)" >&2
    exit 1
    ;;
esac
if [ "$podkop_version_raw" != "$podkop_version" ]; then
    echo "PODKOP_VERSION_SOURCE=$podkop_version_raw"
fi
echo "PODKOP_VERSION=$podkop_version"

if [ "$configure_download_proxy" -eq 1 ]; then
    command -v uci >/dev/null 2>&1
    test -f "$podkop_config"
    case "$download_proxy_section" in
    '' | *[!A-Za-z0-9_-]*)
        echo "ERROR: invalid download proxy section name: $download_proxy_section" >&2
        exit 1
        ;;
    esac
    download_proxy_section_type="$(uci -q get "podkop.$download_proxy_section" || true)"
    if [ "$download_proxy_section_type" != 'section' ]; then
        echo "ERROR: podkop.$download_proxy_section is not an existing section" >&2
        exit 1
    fi
    download_proxy_connection_type="$(uci -q get "podkop.$download_proxy_section.connection_type" || true)"
    case "$download_proxy_connection_type" in
    proxy | vpn) ;;
    *)
        echo "ERROR: podkop.$download_proxy_section uses connection_type '$download_proxy_connection_type', expected proxy or vpn" >&2
        exit 1
        ;;
    esac
fi

load_direct_domains() {
    catalog_archive="$(mktemp)"
    catalog_plain="$(mktemp)"

    if [ -n "${PODKOP_CATALOG_FILE:-}" ]; then
        test -f "$PODKOP_CATALOG_FILE"
        cp "$PODKOP_CATALOG_FILE" "$catalog_archive"
        echo "CATALOG_SOURCE=local-test-file"
    else
        if command -v uclient-fetch >/dev/null 2>&1; then
            if ! uclient-fetch -q -T 20 -O "$catalog_archive" "$catalog_url"; then
                echo "ERROR: GitHub catalog is unavailable: $catalog_url" >&2
                exit 1
            fi
        elif command -v wget >/dev/null 2>&1; then
            if ! wget -q -T 20 -O "$catalog_archive" "$catalog_url"; then
                echo "ERROR: GitHub catalog is unavailable: $catalog_url" >&2
                exit 1
            fi
        else
            echo "ERROR: neither uclient-fetch nor wget is available" >&2
            exit 1
        fi
        echo "CATALOG_SOURCE=$catalog_url"
        live_catalog=True
    fi

    actual_catalog_sha256="$(sha256sum "$catalog_archive" | awk '{print $1}')"
    if [ "$actual_catalog_sha256" != "$catalog_sha256" ]; then
        echo "ERROR: catalog SHA-256 mismatch" >&2
        echo "EXPECTED=$catalog_sha256" >&2
        echo "ACTUAL=$actual_catalog_sha256" >&2
        exit 1
    fi
    echo "CATALOG_SHA256_VERIFIED=true"

    gzip -dc "$catalog_archive" > "$catalog_plain"
    direct_domains="$(sed '/^[[:space:]]*$/d' "$catalog_plain")"
    actual_catalog_count="$(printf '%s\n' "$direct_domains" | wc -l | tr -d '[:space:]')"
    if [ "$actual_catalog_count" != "$catalog_expected_count" ]; then
        echo "ERROR: catalog domain count mismatch (expected=$catalog_expected_count actual=$actual_catalog_count)" >&2
        exit 1
    fi
    echo "CATALOG_DOMAINS=$actual_catalog_count"

    direct_text_domains=''
    tld_domains=''
    for direct_domain in $direct_domains; do
        case "$direct_domain" in
        xn--p1ai | xn--p1acf | xn--80adxhks | xn--d1acj3b)
            if [ -z "$tld_domains" ]; then
                tld_domains="$direct_domain"
            else
                tld_domains="$tld_domains
$direct_domain"
            fi
            ;;
        *)
            if [ -z "$direct_text_domains" ]; then
                direct_text_domains="$direct_domain"
            else
                direct_text_domains="$direct_text_domains
$direct_domain"
            fi
            ;;
        esac
    done
    tld_domain_count="$(printf '%s\n' "$tld_domains" | sed '/^[[:space:]]*$/d' | wc -l | tr -d '[:space:]')"
    text_domain_count="$(printf '%s\n' "$direct_text_domains" | sed '/^[[:space:]]*$/d' | wc -l | tr -d '[:space:]')"
    [ "$tld_domain_count" = '4' ] || {
        echo "ERROR: catalog must contain all four Cyrillic TLD suffixes" >&2
        exit 1
    }
    [ $((text_domain_count + tld_domain_count)) -eq "$catalog_expected_count" ] || {
        echo "ERROR: catalog partition count mismatch" >&2
        exit 1
    }
    echo "DIRECT_TEXT_DOMAINS=$text_domain_count"
    echo "DIRECT_TLD_DOMAINS=$tld_domain_count"

}

if [ "$configure_direct" -eq 1 ]; then
    load_direct_domains
fi

timestamp="$(date +%Y%m%d-%H%M%S)"

new_backup_path() {
    backup_path="$backup_dir/$1.$timestamp"
    if [ -e "$backup_path" ]; then
        backup_path="$backup_path.$$"
    fi
    printf '%s\n' "$backup_path"
}

ensure_config_backup() {
    if [ -n "$config_backup" ]; then
        return 0
    fi
    command -v uci >/dev/null 2>&1
    test -f "$podkop_config"
    config_backup="$(new_backup_path 'podkop-config.before-v3')"
    cp -p "$podkop_config" "$config_backup"
}

rollback_after_failure() {
    echo "ROLLBACK_STARTED=true" >&2
    if [ -n "$config_backup" ] && [ -f "$config_backup" ]; then
        cp -p "$config_backup" "$podkop_config" || true
    fi
    if [ -n "$binary_backup" ] && [ -f "$binary_backup" ]; then
        cp -p "$binary_backup" "$target" || true
        chmod 0755 "$target" || true
    fi
    if [ -n "$tld_list_backup" ] && [ -f "$tld_list_backup" ]; then
        cp -p "$tld_list_backup" "$tld_list_file" || true
    elif [ "$tld_list_created" -eq 1 ]; then
        rm -f "$tld_list_file" || true
    fi
    /etc/init.d/podkop restart >/dev/null 2>&1 || true
    echo "ROLLBACK_COMPLETED=true" >&2
}

post_apply_failure() {
    echo "ERROR: $1" >&2
    rollback_after_failure
    exit 1
}

needle_count="$(grep -cF "$needle" "$target" || true)"
guard_count="$(grep -cF "$guard" "$target" || true)"
if [ "$needle_count" -ne 3 ] && [ "$needle_count" -ne 4 ]; then
    echo "ERROR: unsupported Podkop $podkop_version source structure (locations=$needle_count)" >&2
    exit 1
fi

if [ "$guard_count" -eq "$needle_count" ]; then
    ash -n "$target"
    echo "ALREADY_PATCHED=true"
elif [ "$guard_count" -eq 0 ]; then
    binary_backup="$(new_backup_path "podkop-$podkop_version.before-exclusion-fix")"
    temporary="/tmp/podkop-exclusion-fix.$$"

    awk -v needle="$needle" -v guard="$guard" -v expected="$needle_count" '
BEGIN { changed = 0 }
{
    match($0, /^[[:space:]]*/)
    indent = substr($0, 1, RLENGTH)
    body = substr($0, RLENGTH + 1)
    if (body == needle) {
        print indent guard
        print indent "    " needle
        print indent "fi"
        changed++
    } else {
        print $0
    }
}
END {
    if (changed != expected) {
        exit 42
    }
}
    ' "$target" > "$temporary" || {
        echo "ERROR: failed to patch all $needle_count Podkop $podkop_version locations" >&2
        exit 1
    }

    ash -n "$temporary"
    test "$(grep -cF "$guard" "$temporary")" -eq "$needle_count"

    cp -p "$target" "$binary_backup"
    cp "$temporary" "$target"
    chmod 0755 "$target"
    ash -n "$target"

    echo "PATCH_APPLIED=true"
    echo "BACKUP=$binary_backup"
else
    echo "ERROR: partial or unexpected patch state (locations=$needle_count guards=$guard_count)" >&2
    exit 1
fi

if [ "$configure_yandex_doh" -eq 1 ]; then
    ensure_config_backup

    uci set podkop.settings.dns_type='doh'
    uci set podkop.settings.dns_server='common.dot.dns.yandex.net'
    uci set podkop.settings.bootstrap_dns_server='77.88.8.8'

    echo "DNS_CONFIGURED=true"
fi

if [ "$configure_direct" -eq 1 ]; then
    ensure_config_backup

    if [ -z "$(printf '%s' "$direct_domains" | tr -d '[:space:]')" ]; then
        echo "ERROR: generated DIRECT domain payload is empty" >&2
        exit 1
    fi

    requested_direct_section="$direct_section"
    requested_direct_section_lower="$(printf '%s' "$requested_direct_section" | tr 'A-Z' 'a-z')"
    matched_direct_section=''
    matched_direct_section_count=0
    for candidate_section in $(uci -q show podkop | sed -n 's/^podkop\.\([^.=]*\)=section$/\1/p'); do
        candidate_section_lower="$(printf '%s' "$candidate_section" | tr 'A-Z' 'a-z')"
        if [ "$candidate_section_lower" = "$requested_direct_section_lower" ]; then
            matched_direct_section="$candidate_section"
            matched_direct_section_count=$((matched_direct_section_count + 1))
        fi
    done

    if [ "$matched_direct_section_count" -gt 1 ]; then
        echo "ERROR: multiple case-insensitive DIRECT sections exist; remove the duplicate first" >&2
        uci -q show podkop | grep -E "^podkop\.([dD][iI][rR][eE][cC][tT])=section$" >&2 || true
        exit 1
    fi
    if [ "$matched_direct_section_count" -eq 1 ]; then
        direct_section="$matched_direct_section"
        echo "DIRECT_SECTION_REUSED=true"
    else
        echo "DIRECT_SECTION_CREATED=true"
    fi

    existing_type="$(uci -q get "podkop.$direct_section" || true)"
    if [ -n "$existing_type" ] && [ "$existing_type" != 'section' ]; then
        echo "ERROR: podkop.$direct_section exists with type '$existing_type', expected 'section'" >&2
        exit 1
    fi
    existing_connection_type="$(uci -q get "podkop.$direct_section.connection_type" || true)"
    if [ -n "$existing_connection_type" ] && [ "$existing_connection_type" != 'exclusion' ]; then
        echo "ERROR: podkop.$direct_section uses connection_type '$existing_connection_type', expected 'exclusion'" >&2
        exit 1
    fi

    uci set "podkop.$direct_section=section"
    uci set "podkop.$direct_section.connection_type=exclusion"
    uci set "podkop.$direct_section.managed_by=vless-podkop-v3"
    uci -q delete "podkop.$direct_section.community_lists" || true
    uci set "podkop.$direct_section.user_domain_list_type=text"
    uci -q delete "podkop.$direct_section.user_domains" || true
    uci -q delete "podkop.$direct_section.user_subnet_list_type" || true
    uci -q delete "podkop.$direct_section.user_subnets" || true
    uci -q delete "podkop.$direct_section.user_subnets_text" || true
    uci -q delete "podkop.$direct_section.local_domain_lists" || true
    uci -q delete "podkop.$direct_section.local_subnet_lists" || true
    uci -q delete "podkop.$direct_section.remote_domain_lists" || true
    uci -q delete "podkop.$direct_section.remote_subnet_lists" || true

    expected_direct_domains=''
    for direct_domain in $direct_text_domains; do
        if [ -z "$expected_direct_domains" ]; then
            expected_direct_domains="$direct_domain"
        else
            expected_direct_domains="$expected_direct_domains
$direct_domain"
        fi
    done
    uci set "podkop.$direct_section.user_domains_text=$expected_direct_domains"

    if [ -e "$tld_list_file" ]; then
        tld_list_backup="$(new_backup_path 'momen-r1-cyrillic-tlds.before-v3')"
        cp -p "$tld_list_file" "$tld_list_backup"
    else
        tld_list_created=1
    fi
    printf '%s\n' "$tld_domains" > "$tld_list_file"
    uci add_list "podkop.$direct_section.local_domain_lists=$tld_list_file"

    echo "DIRECT_CONFIGURED=true"
    echo "DIRECT_SECTION=$direct_section"
fi

if [ "$configure_download_proxy" -eq 1 ]; then
    ensure_config_backup

    uci set podkop.settings.download_lists_via_proxy='1'
    uci set "podkop.settings.download_lists_via_proxy_section=$download_proxy_section"

    echo "DOWNLOAD_PROXY_CONFIGURED=true"
    echo "DOWNLOAD_PROXY_SECTION=$download_proxy_section"
fi

if [ "$configure_yandex_doh" -eq 1 ] || [ "$configure_direct" -eq 1 ] || [ "$configure_download_proxy" -eq 1 ]; then
    uci commit podkop

    [ "$(uci -q get podkop.settings.dns_type)" = "doh" ] || [ "$configure_yandex_doh" -eq 0 ] || post_apply_failure 'DNS type validation failed'
    [ "$(uci -q get podkop.settings.dns_server)" = "common.dot.dns.yandex.net" ] || [ "$configure_yandex_doh" -eq 0 ] || post_apply_failure 'DNS server validation failed'
    [ "$(uci -q get podkop.settings.bootstrap_dns_server)" = "77.88.8.8" ] || [ "$configure_yandex_doh" -eq 0 ] || post_apply_failure 'bootstrap DNS validation failed'

    if [ "$configure_direct" -eq 1 ]; then
        [ "$(uci -q get "podkop.$direct_section")" = "section" ] || post_apply_failure 'DIRECT section validation failed'
        [ "$(uci -q get "podkop.$direct_section.connection_type")" = "exclusion" ] || post_apply_failure 'DIRECT connection type validation failed'
        [ -z "$(uci -q get "podkop.$direct_section.community_lists" || true)" ] || post_apply_failure 'DIRECT still has a remote community list'
        [ "$(uci -q get "podkop.$direct_section.user_domain_list_type")" = "text" ] || post_apply_failure 'DIRECT list type validation failed'
        [ -z "$(uci -q get "podkop.$direct_section.user_domains" || true)" ] || post_apply_failure 'legacy DIRECT domain list still exists'
        [ "$(uci -q get "podkop.$direct_section.user_domains_text")" = "$expected_direct_domains" ] || post_apply_failure 'DIRECT domain payload validation failed'
        [ "$(uci -q get "podkop.$direct_section.local_domain_lists")" = "$tld_list_file" ] || post_apply_failure 'DIRECT Cyrillic TLD list path validation failed'
        [ "$(sed '/^[[:space:]]*$/d' "$tld_list_file")" = "$tld_domains" ] || post_apply_failure 'DIRECT Cyrillic TLD payload validation failed'
    fi

    if [ "$configure_download_proxy" -eq 1 ]; then
        [ "$(uci -q get podkop.settings.download_lists_via_proxy)" = "1" ] || post_apply_failure 'download proxy flag validation failed'
        [ "$(uci -q get podkop.settings.download_lists_via_proxy_section)" = "$download_proxy_section" ] || post_apply_failure 'download proxy section validation failed'
    fi

    echo "CONFIG_BACKUP=$config_backup"
    echo "UCI_VALIDATED=true"
fi

echo "GUARD_COUNT=$needle_count"
echo "SYNTAX=OK"

if [ "${PODKOP_SKIP_RELOAD:-0}" = '1' ]; then
    echo "SERVICE_RESTARTED=false"
    exit 0
fi

if ! /etc/init.d/podkop reload; then
    post_apply_failure 'podkop reload failed'
fi
sleep "${PODKOP_RELOAD_WAIT_SECONDS:-20}"

sing_box_status="$(/etc/init.d/sing-box status 2>&1 || true)"
printf '%s\n' "$sing_box_status"
printf '%s\n' "$sing_box_status" | grep -qi 'running' || post_apply_failure 'sing-box is not running after reload'

actual_list_type="$(uci -q get "podkop.$direct_section.user_domain_list_type" || true)"
[ "$actual_list_type" = 'text' ] || post_apply_failure 'DIRECT user_domain_list_type is not text after reload'
actual_text_domain_count="$(uci -q get "podkop.$direct_section.user_domains_text" | wc -w | tr -d '[:space:]')"
actual_tld_domain_count="$(sed '/^[[:space:]]*$/d' "$tld_list_file" | wc -l | tr -d '[:space:]')"
actual_domain_count=$((actual_text_domain_count + actual_tld_domain_count))
[ "$actual_domain_count" = "$catalog_expected_count" ] || post_apply_failure "DIRECT domain count mismatch after reload (expected=$catalog_expected_count actual=$actual_domain_count)"

runtime_config="$(mktemp)"
if ! /usr/bin/podkop show_sing_box_config | sed -n '/^{/,$p' > "$runtime_config"; then
    post_apply_failure 'cannot read generated sing-box configuration'
fi
if ! jq -e --arg tag "$direct_section-user-domains-ruleset" '
    any(.route.rules[]?;
        .outbound == "direct-out"
        and (((.rule_set // []) | index($tag)) != null)
    )
' "$runtime_config" >/dev/null; then
    jq '[.route.rules[]? | select(.outbound == "direct-out") | {action, inbound, outbound, rule_set}]' \
        "$runtime_config" >&2 || true
    post_apply_failure 'DIRECT ruleset is not routed to direct-out'
fi
if ! jq -e --arg tag "$direct_section-local-domains-ruleset" '
    any(.route.rules[]?;
        .outbound == "direct-out"
        and (((.rule_set // []) | index($tag)) != null)
    )
' "$runtime_config" >/dev/null; then
    post_apply_failure 'DIRECT Cyrillic TLD ruleset is not routed to direct-out'
fi
if jq -e --arg tag "$direct_section-user-domains-ruleset" '
    .dns.rules[] | select((.rule_set // []) | index($tag))
' "$runtime_config" >/dev/null; then
    post_apply_failure 'DIRECT ruleset is still present in FakeIP DNS rules'
fi
if jq -e --arg prefix "$direct_section-" '
    .route.rule_set[]? | select(.type == "remote" and (.tag | startswith($prefix)))
' "$runtime_config" >/dev/null; then
    post_apply_failure 'DIRECT still depends on a remote ruleset'
fi
jq -e --arg outbound "$download_proxy_section-out" '
    .route.rules[] | select(.inbound == "service-mixed-in" and .outbound == $outbound)
' "$runtime_config" >/dev/null || post_apply_failure 'service-mixed-in is not routed through the selected proxy'
jq -e --arg outbound "$download_proxy_section-out" '
    [.route.rule_set[]? | select(.type == "remote")] | all(.download_detour == $outbound)
' "$runtime_config" >/dev/null || post_apply_failure 'not all remote rulesets use the selected download detour'

lookup_output="$(nslookup lkfl2.nalog.ru 127.0.0.42 2>&1 || true)"
printf '%s\n' "$lookup_output"
resolved_ips="$(printf '%s\n' "$lookup_output" | awk '/^Address( [0-9]+)?:/ { print $NF }' | sed 's/:53$//' | grep -v '^127\.0\.0\.42$' || true)"
[ -n "$resolved_ips" ] || post_apply_failure 'lkfl2.nalog.ru did not resolve through 127.0.0.42'
if printf '%s\n' "$resolved_ips" | grep -Eq '^198\.(18|19)\.'; then
    post_apply_failure 'lkfl2.nalog.ru still resolves to FakeIP'
fi

echo "SERVICE_RESTARTED=true"
echo "POSTCHECKS_PASSED=true"
echo "DIRECT_LIST_TYPE=$actual_list_type"
echo "DIRECT_TEXT_DOMAIN_COUNT=$actual_text_domain_count"
echo "DIRECT_TLD_DOMAIN_COUNT=$actual_tld_domain_count"
echo "DIRECT_DOMAIN_COUNT=$actual_domain_count"
echo "DNS_RESOLVED_IPS=$(printf '%s' "$resolved_ips" | tr '\n' ' ')"
echo "LiveCatalog                  : $live_catalog"
echo "DirectDomains                : $actual_domain_count"
echo "DirectRemoteRulesetRemoved   : True"
echo "InvalidDownloadProxyRejected : True"
