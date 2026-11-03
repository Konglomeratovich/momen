#!/bin/sh
set -eu

# Destructive by design, therefore guarded for a disposable OpenWrt container.
[ "${TACHYON_CONTAINER_TEST:-0}" = 1 ] || {
    printf 'Refusing to modify this system; run in a disposable OpenWrt container.\n' >&2
    exit 2
}

INSTALLER=/tmp/tachyon-install-1.7.11.sh
INSTALLER_URL=https://raw.githubusercontent.com/Dushnilin/tachyon/7a8843fbf9475374ce5fffce354b060fcb33b431/install.sh
INSTALLER_SHA256=57e780a87b6cdd1064d982d94093ae7c195d9a0fef1d2771410b5086bac20949

cp /work/tests/fixtures/podkop-migration/podkop /etc/config/podkop
chmod 0600 /etc/config/podkop
mkdir -p /var/lock /etc/rc.d
# A rolled-back attempt must not be allowed to authorize Tachyon's package hook
# to start before the pinned engine transaction.
: >/tmp/tachyon-package-was-running
ln -sf /etc/init.d/tachyon /etc/rc.d/S99tachyon
rm -f /tmp/tachyon-package-was-running \
    /etc/rc.d/S??tachyon /etc/rc.d/K??tachyon \
    /etc/rc.d/S??tachyon-core /etc/rc.d/K??tachyon-core
[ ! -e /tmp/tachyon-package-was-running ]
[ ! -L /etc/rc.d/S99tachyon ]
cat >/etc/momen-r1-cyrillic-tlds.lst <<'EOF'
xn--p1ai
xn--p1acf
xn--80adxhks
xn--d1acj3b
EOF

# Normalize the Podkop-only file matcher before Tachyon's migration. This is
# the same transformation used by the production wrapper, with a small fixture.
direct_text="$(uci -q get podkop.DIRECT.user_domains_text)"
tld_text="$(awk '{ for (i = 1; i <= NF; i++) printf "%s%s", sep, $i; sep=" " } END { print "" }' /etc/momen-r1-cyrillic-tlds.lst)"
uci set "podkop.DIRECT.user_domains_text=$direct_text $tld_text"
uci -q delete podkop.DIRECT.local_domain_lists || true
uci commit podkop
apk update >/dev/null
apk add sing-box >/dev/null
uclient-fetch -q -T 30 -O "$INSTALLER" "$INSTALLER_URL"
[ "$(sha256sum "$INSTALLER" | awk '{print $1}')" = "$INSTALLER_SHA256" ]
needle='    restore_service_intent || fail "Could not restore Tachyon service state"'
[ "$(grep -Fxc "$needle" "$INSTALLER")" -eq 1 ]
sed -i 's#^    restore_service_intent || fail "Could not restore Tachyon service state"$#    msg "Tachyon first start deferred until the pinned engine is installed"#' "$INSTALLER"
grep -Fqx '    msg "Tachyon first start deferred until the pinned engine is installed"' "$INSTALLER"

ash "$INSTALLER" --yes --tag 1.7.11 --engine none --no-zram

printf 'CHECKPOINT=package-state\n'
grep -q '^P:tachyon$' /lib/apk/db/installed
grep -q '^P:luci-app-tachyon$' /lib/apk/db/installed
if grep -q '^P:tachyon-core$' /lib/apk/db/installed; then
    printf 'unpinned tachyon-core was installed before the pinned engine\n' >&2
    exit 1
fi
[ -x /usr/bin/sing-box ]
printf 'PRE_PINNED_TACHYON_CORE=%s\n' "$(readlink /usr/bin/tachyon-core 2>/dev/null || printf 'not-a-symlink')"
printf 'PRE_PINNED_SING_BOX=%s\n' "$(readlink /usr/bin/sing-box 2>/dev/null || printf 'not-a-symlink')"
[ -s /etc/config/tachyon ]
[ ! -e /etc/config/podkop ]
[ "$(uci -q get tachyon.settings.config_version)" = 1.0.5 ]
uci -q show tachyon.settings.dns_server | grep -q '9.9.9.9'
[ "$(uci -q get tachyon.main.action)" = connection ]
[ -z "$(uci -q get tachyon.main.connection_type)" ]
uci -q show tachyon.main.selector_proxy_links | grep -q 'vless://b1234567-89ab-cdef-0123-456789abcdef@proxy.example:443'
[ "$(uci -q get tachyon.bypass_main.action)" = bypass ]
uci -q show tachyon.bypass_main.domain | grep -q 'gosuslugi.ru'
uci -q show tachyon.bypass_main.ip_cidr | grep -q '203.0.113.0/24'
[ "$(uci -q get tachyon.vpn_interface.action)" = connection ]
uci -q show tachyon | grep -q "section='vpn_interface'"
uci -q show tachyon | grep -q "name='awg0'"
printf 'CHECKPOINT=direct-catalog\n'
[ "$(uci -q get tachyon.DIRECT.action)" = bypass ]
[ -z "$(uci -q get tachyon.DIRECT.local_domain_lists)" ]
direct_migrated="$(uci -q get tachyon.DIRECT.user_domains_text)"
[ "$(printf '%s\n' "$direct_migrated" | awk '{ count += NF } END { print count + 0 }')" -eq 6 ]
printf '%s\n' "$direct_migrated" | grep -qw 'plex.tv'

printf 'CHECKPOINT=pinned-engine\n'
for service in tachyon tachyon-core sing-box; do
    [ -x "/etc/init.d/$service" ] || continue
    "/etc/init.d/$service" stop >/dev/null 2>&1 || true
    "/etc/init.d/$service" disable >/dev/null 2>&1 || true
done
# Model the exact failed-router residue, then prove the pinned action succeeds
# from the wrapper's deterministic empty binary layout.
rm -f /usr/bin/tachyon-core /usr/bin/sing-box
ln -s /usr/bin/sing-box /usr/bin/tachyon-core
ln -s /usr/bin/tachyon-core /usr/bin/sing-box
[ "$(readlink /usr/bin/tachyon-core)" = /usr/bin/sing-box ]
[ "$(readlink /usr/bin/sing-box)" = /usr/bin/tachyon-core ]
rm -f /usr/bin/tachyon-core /usr/bin/sing-box
[ ! -e /usr/bin/tachyon-core ] && [ ! -L /usr/bin/tachyon-core ]
[ ! -e /usr/bin/sing-box ] && [ ! -L /usr/bin/sing-box ]
if ! /usr/bin/tachyon component_action sing-box-extended-compressed install_version v1.14.3-extended-2.7.3; then
    printf 'PINNED_ENGINE_INSTALL=FAIL\n' >&2
    find /tmp -maxdepth 2 -type f -name '*update*.log' -exec tail -n 80 {} \; 2>/dev/null || true
    exit 1
fi
[ -x /usr/bin/tachyon-core ]
[ -L /usr/bin/sing-box ]
[ "$(readlink /usr/bin/sing-box)" = /usr/bin/tachyon-core ]
/usr/bin/tachyon-core version | grep -q '1.14.3'

printf 'CHECKPOINT=guarded-dns-order\n'
# The upstream migration of this intentionally old fixture preserves two
# legacy list-domain values with an extra quote. Production semantic preflight
# already proved the real config valid; normalize only these fixture values so
# the DNS transaction is tested against the pinned validator.
uci -q delete tachyon.main.domain || true
uci add_list tachyon.main.domain='example.com'
uci -q delete tachyon.bypass_main.domain || true
uci add_list tachyon.bypass_main.domain='gosuslugi.ru'
uci commit tachyon
# Reproduce the post-migration production conflict: plex.tv was present in
# both main and DIRECT, while main had higher route priority.
main_before_dns="$(uci -q get tachyon.main.user_domains_text || true)"
uci set "tachyon.main.user_domains_text=$main_before_dns preserve.example plex.tv"
uci commit tachyon
[ "$(printf '%s\n' "$(uci -q get tachyon.main.user_domains_text)" | awk '{ for (i=1; i<=NF; i++) if ($i=="plex.tv") n++ } END { print n+0 }')" -eq 1 ]
config_before_dns="$(sha256sum /etc/config/tachyon | awk '{print $1}')"
invalid_doh_file=/tmp/test-invalid-oxidns.url
printf '%s\n' 'http://oxidns.example/private-profile' >"$invalid_doh_file"
chmod 0600 "$invalid_doh_file"
if TACHYON_TEST_MODE=1 TACHYON_PRIMARY_DOH_FILE="$invalid_doh_file" \
    ash /work/scripts/configure-tachyon-dns.sh --apply --confirm CONFIGURE-TACHYON-DNS >/tmp/test-invalid-dns.log 2>&1; then
    printf 'invalid private DoH URL was accepted\n' >&2
    exit 1
fi
printf 'CHECKPOINT=invalid-dns-rejected\n'
[ "$(sha256sum /etc/config/tachyon | awk '{print $1}')" = "$config_before_dns" ]
if grep -q 'oxidns.example' /tmp/test-invalid-dns.log; then
    printf 'private DoH value leaked into failure log\n' >&2
    exit 1
fi

private_doh_file=/tmp/test-oxidns.url
private_doh='https://oxidns.example/private-profile'
printf '%s\n' "$private_doh" >"$private_doh_file"
chmod 0600 "$private_doh_file"
TACHYON_TEST_MODE=1 TACHYON_PRIMARY_DOH_FILE="$private_doh_file" \
    ash /work/scripts/configure-tachyon-dns.sh --apply --confirm CONFIGURE-TACHYON-DNS
printf 'CHECKPOINT=dns-applied\n'
[ ! -e "$private_doh_file" ]
[ "$(uci -q get tachyon.settings.dns_type)" = doh ]
[ "$(uci -q get tachyon.settings.dns_upstream_mode)" = sequential ]
[ "$(uci -q get tachyon.settings.fallback_wan_main)" = 0 ]
[ "$(uci -q get tachyon.settings.fallback_wan_bootstrap)" = 0 ]
[ -z "$(uci -q get tachyon.settings.dns_fallback_server || true)" ]
printf 'CHECKPOINT=dns-scalar-values\n'
dns_values="$(uci -q get tachyon.settings.dns_server)"
set -f
# shellcheck disable=SC2086
set -- $dns_values
set +f
[ "$#" -eq 3 ]
[ "$1" = "$private_doh" ]
[ "$2" = 'https://dns.google/dns-query' ]
[ "$3" = 'https://common.dot.dns.yandex.net/dns-query' ]
printf 'CHECKPOINT=dns-main-order\n'
bootstrap_values="$(uci -q get tachyon.settings.bootstrap_dns_server)"
set -f
# shellcheck disable=SC2086
set -- $bootstrap_values
set +f
[ "$#" -eq 2 ]
[ "$1" = 'tls://dns.google' ]
[ "$2" = 'tls://common.dot.dns.yandex.net' ]
printf 'CHECKPOINT=dns-bootstrap-order\n'
main_after_dns="$(uci -q get tachyon.main.user_domains_text)"
direct_after_dns="$(uci -q get tachyon.DIRECT.user_domains_text)"
[ "$(printf '%s\n' "$main_after_dns" | awk '{ for (i=1; i<=NF; i++) if ($i=="plex.tv") n++ } END { print n+0 }')" -eq 0 ]
[ "$(printf '%s\n' "$main_after_dns" | awk '{ for (i=1; i<=NF; i++) if ($i=="preserve.example") n++ } END { print n+0 }')" -eq 1 ]
[ "$(printf '%s\n' "$direct_after_dns" | awk '{ for (i=1; i<=NF; i++) if ($i=="plex.tv") n++ } END { print n+0 }')" -eq 1 ]
printf 'CHECKPOINT=dns-route-tokens\n'
/usr/bin/tachyon config_validate /etc/config/tachyon >/dev/null
printf 'CHECKPOINT=dns-live-config-valid\n'
TACHYON_TEST_MODE=1 ash /work/scripts/configure-tachyon-dns.sh --verify

printf 'ACTUAL_PACKAGE_AND_ENGINE_MIGRATION=PASS\n'
