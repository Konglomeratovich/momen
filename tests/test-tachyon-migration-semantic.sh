#!/bin/sh
set -eu

# Real backend migration + generator + core check, in a disposable container.
[ "${TACHYON_CONTAINER_TEST:-0}" = 1 ] && [ -f /.dockerenv ] || exit 2
[ -r /backend.apk ] && [ -r /engine.tar.gz ] || exit 2
root=/tmp/semantic-test
mkdir -p "$root/bin" "$root/rollback" /etc/config /etc/apk /lib/apk/db
cp /work/tests/fixtures/podkop-migration/podkop /etc/config/podkop
# Keep the DIRECT fixture and a valid proxy; legacy domain-list normalization
# and interface sections are exercised by the separate real package test.
for option in domain rule_set rule_set_with_subnets; do
    uci -q delete "podkop.main.$option" || true
done
uci -q delete podkop.bypass_main
uci -q delete podkop.vpn_interface
uci set podkop.main.user_domains_text=example.com
expected_total=6
if [ "${TEST_FULL_CATALOG:-0}" = 1 ]; then
    catalog_text="$(tr -d '\r' </catalog.lst | awk 'index($0,".") > 0 {print}')"
    uci set "podkop.DIRECT.user_domains_text=$catalog_text
custom-direct.example"
    expected_total=725
fi
if [ "${TEST_NO_PLEX:-0}" = 1 ]; then
    if [ "${TEST_FULL_CATALOG:-0}" != 1 ]; then
        uci set podkop.DIRECT.user_domains_text=example.ru
    fi
fi
uci commit podkop
printf '%s\n' xn--p1ai xn--p1acf xn--80adxhks xn--d1acj3b >/etc/momen-r1-cyrillic-tlds.lst
cat >/etc/openwrt_release <<'EOF'
DISTRIB_RELEASE='25.12.2'
DISTRIB_ARCH='aarch64_cortex-a53'
DISTRIB_TARGET='fixture/arm64'
EOF
# Package DB and architecture are fixtures; backend APK and x86 core are real.
cat >/lib/apk/db/installed <<'EOF'
P:podkop
V:0.7.22-r1

P:luci-app-podkop
V:0.7.22-r1

P:sing-box
V:1.12.17-r1
EOF
printf '%s\n' podkop luci-app-podkop sing-box >/etc/apk/world
for p in podkop-0.7.22-r1.apk luci-app-podkop-0.7.22-r1.apk luci-i18n-podkop-ru-0.7.22.apk sing-box-1.12.17-r1.apk; do
    printf '%s\n' fixture >"$root/rollback/$p"
done
tar -C / -czf "$root/rollback/config-backup.tar.gz" etc/config/podkop
(cd "$root/rollback" && sha256sum ./*.apk config-backup.tar.gz >SHA256SUMS)
cat >"$root/audit.sh" <<'EOF'
#!/bin/sh
printf '%s\n' SPACE_OK=true ROLLBACK_READY=true APPLY_ALLOWED=true
EOF
cat >"$root/bin/uclient-fetch" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    case "$1" in
        -O) shift; target="$1" ;;
        -T) shift ;;
        backend) cp /backend.apk "$target" ;;
        engine) cp /engine.tar.gz "$target" ;;
        */r1.lst) tr -d '\r' </catalog.lst >"$target" ;;
    esac
    shift
done
EOF
chmod +x "$root/audit.sh" "$root/bin/uclient-fetch"
before="$(sha256sum /etc/config/podkop /etc/apk/world /lib/apk/db/installed)"
PATH="$root/bin:$PATH" TACHYON_TEST_MODE=1 \
TACHYON_TEST_BACKEND_URL=backend \
TACHYON_TEST_BACKEND_SHA256="$(sha256sum /backend.apk | awk '{print $1}')" \
TACHYON_TEST_ENGINE_URL=engine \
TACHYON_TEST_ENGINE_SHA256="$(sha256sum /engine.tar.gz | awk '{print $1}')" \
TACHYON_TEST_DIRECT_TOTAL="$expected_total" TACHYON_TEST_DIRECT_EXTRA=plex.tv \
TACHYON_AUDIT_SCRIPT="$root/audit.sh" \
TACHYON_AUDIT_SHA256="$(sha256sum "$root/audit.sh" | awk '{print $1}')" \
TACHYON_ROLLBACK_DIR="$root/rollback" \
ash /work/scripts/migrate-podkop-to-tachyon.sh --preflight
[ "$before" = "$(sha256sum /etc/config/podkop /etc/apk/world /lib/apk/db/installed)" ]
printf '%s\n' REAL_SEMANTIC_PREFLIGHT=PASS PREFLIGHT_SOURCE_UNCHANGED=true
