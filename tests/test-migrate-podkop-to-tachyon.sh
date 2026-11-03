#!/bin/sh
set -eu

# Run only inside a disposable OpenWrt container:
#   docker run --rm -e TACHYON_CONTAINER_TEST=1 -e TEST_CASE=success \
#     -v "$PWD:/work:ro" openwrt/rootfs:x86_64-25.12.2 \
#     ash /work/tests/test-migrate-podkop-to-tachyon.sh

[ "${TACHYON_CONTAINER_TEST:-0}" = 1 ] || {
    printf 'Refusing to modify this system; use the documented disposable container.\n' >&2
    exit 2
}

case "${TEST_CASE:-}" in success|rollback) ;; *) printf 'TEST_CASE must be success or rollback\n' >&2; exit 2 ;; esac

SCRIPT=/work/scripts/migrate-podkop-to-tachyon.sh
AUDIT=/work/scripts/audit-tachyon-readiness.sh
ROOT=/tmp/migration-test
ROLLBACK="$ROOT/rollback"
MOCKBIN="$ROOT/bin"
FIXTURE="$ROOT/fake-installer.sh"
SEMANTIC_FIXTURE="$ROOT/fake-semantic-preflight.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
not_ok() { fail=$((fail + 1)); printf 'not ok - %s\n' "$1" >&2; }
assert() { label="$1"; shift; if "$@"; then ok "$label"; else not_ok "$label"; fi; }

generator_binding_present() {
    grep -Fq "SB_PREFLIGHT_BINARY=\"\$stage/sing-box\"" "$SCRIPT" &&
        grep -Fq "SB_VERSION_STATE_FILE=\"\$stage/sing-box-version\"" "$SCRIPT" &&
        grep -Fq "SB_VARIANT_STATE_FILE=\"\$stage/sing-box-variant\"" "$SCRIPT" &&
        grep -Fq "extended-compressed >\"\$stage/sing-box-variant\"" "$SCRIPT"
}

assert 'semantic generator is bound to pinned binary and private version/variant state' \
    generator_binding_present

mkdir -p "$ROLLBACK" "$MOCKBIN" /etc/init.d /etc/config /etc/apk /lib/apk/db /usr/bin
cat >/etc/openwrt_release <<'EOF'
DISTRIB_RELEASE='25.12.2'
DISTRIB_TARGET='mediatek/filogic'
DISTRIB_ARCH='aarch64_cortex-a53'
EOF

cat >/lib/apk/db/installed <<'EOF'
P:podkop
V:0.7.22-r1
I:186368

P:luci-app-podkop
V:0.7.22-r1
I:168960

P:luci-i18n-podkop-ru
V:0.7.22
I:21504

P:sing-box
V:1.12.17-r1
I:40513536
EOF
cat >/etc/apk/world <<'EOF'
podkop
luci-app-podkop
luci-i18n-podkop-ru
sing-box
EOF
cat >/etc/config/podkop <<'EOF'
config settings 'settings'
	option enabled '1'
	option dns_type 'doh'
	option dns_server 'https://common.dot.dns.yandex.net/dns-query'

config section 'main'
	option connection_type 'proxy'
	list domain 'example.invalid'
EOF

for svc in podkop sing-box AdGuardHome; do
    cat >"/etc/init.d/$svc" <<'EOF'
#!/bin/sh
case "$1" in enabled|status|start|stop|restart|enable|disable) exit 0 ;; *) exit 0 ;; esac
EOF
    chmod 0755 "/etc/init.d/$svc"
done

printf 'podkop apk\n' >"$ROLLBACK/podkop-0.7.22-r1.apk"
printf 'luci apk\n' >"$ROLLBACK/luci-app-podkop-0.7.22-r1.apk"
printf 'i18n apk\n' >"$ROLLBACK/luci-i18n-podkop-ru-0.7.22.apk"
printf 'sing-box apk\n' >"$ROLLBACK/sing-box-1.12.17-r1.apk"
tar -C / -czf "$ROLLBACK/config-backup.tar.gz" etc/config/podkop etc/apk/world
(
    cd "$ROLLBACK"
    sha256sum config-backup.tar.gz podkop-0.7.22-r1.apk luci-app-podkop-0.7.22-r1.apk \
        luci-i18n-podkop-ru-0.7.22.apk sing-box-1.12.17-r1.apk >SHA256SUMS
)

cat >"$MOCKBIN/apk" <<'EOF'
#!/bin/sh
case "$1" in
    del) exit 0 ;;
    add)
        cat >/lib/apk/db/installed <<'DB'
P:podkop
V:0.7.22-r1
I:186368

P:luci-app-podkop
V:0.7.22-r1
I:168960

P:luci-i18n-podkop-ru
V:0.7.22
I:21504

P:sing-box
V:1.12.17-r1
I:40513536
DB
        cat >/usr/bin/sing-box <<'BIN'
#!/bin/sh
exit 0
BIN
        chmod 0755 /usr/bin/sing-box
        exit 0
        ;;
esac
exit 0
EOF
chmod 0755 "$MOCKBIN/apk"

cat >"$FIXTURE" <<'EOF'
#!/bin/sh
unused_upstream_first_start() {
    restore_service_intent || fail "Could not restore Tachyon service state"
}
mv /etc/config/podkop /etc/config/tachyon
cat >/lib/apk/db/installed <<'DB'
P:tachyon
V:1.7.11
I:5242880

P:luci-app-tachyon
V:1.7.11
I:4194304

P:luci-i18n-tachyon-ru
V:1.7.11
I:225280
DB
cat >/usr/bin/tachyon <<'TACHYON'
#!/bin/sh
case "$1" in
    component_action)
        if [ "${TACHYON_FAKE_FAIL_ENGINE:-0}" = 1 ]; then exit 1; fi
        cat >/usr/bin/tachyon-core <<'CORE'
#!/bin/sh
case "$1" in version) echo 'sing-box version 1.14.3-extended-2.7.3' ;; esac
exit 0
CORE
        chmod 0755 /usr/bin/tachyon-core
        ln -sf /usr/bin/tachyon-core /usr/bin/sing-box
        exit 0
        ;;
    get_status) printf '{"running":true}\n'; exit 0 ;;
    start|stop) exit 0 ;;
esac
exit 0
TACHYON
chmod 0755 /usr/bin/tachyon
cat >/etc/init.d/tachyon <<'INIT'
#!/bin/sh
exit 0
INIT
chmod 0755 /etc/init.d/tachyon
# Reproduce the router failure: a package-hook/autoinstall race left the two
# binary names pointing at each other. The wrapper must quiesce services and
# clear both ends before invoking the pinned component action.
rm -f /usr/bin/tachyon-core /usr/bin/sing-box
ln -s /usr/bin/sing-box /usr/bin/tachyon-core
ln -s /usr/bin/tachyon-core /usr/bin/sing-box
exit 0
EOF
chmod 0755 "$FIXTURE"

cat >"$SEMANTIC_FIXTURE" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 0755 "$SEMANTIC_FIXTURE"

before="$(sha256sum /etc/config/podkop /etc/apk/world /lib/apk/db/installed)"
fixture_sha="$(sha256sum "$FIXTURE" | awk '{print $1}')"
audit_sha="$(sha256sum "$AUDIT" | awk '{print $1}')"
common_env="PATH=$MOCKBIN:/usr/sbin:/usr/bin:/sbin:/bin TACHYON_AUDIT_SCRIPT=$AUDIT TACHYON_AUDIT_SHA256=$audit_sha TACHYON_ROLLBACK_DIR=$ROLLBACK TACHYON_WORK_ROOT=$ROOT TACHYON_TEST_MODE=1 TACHYON_INSTALLER_FIXTURE=$FIXTURE TACHYON_INSTALLER_SHA256=$fixture_sha TACHYON_SEMANTIC_PREFLIGHT_FIXTURE=$SEMANTIC_FIXTURE"

# The plan must neither migrate the config nor alter package state.
# shellcheck disable=SC2086
if env $common_env ash "$SCRIPT" --plan >"$ROOT/plan.out" 2>&1; then
    after="$(sha256sum /etc/config/podkop /etc/apk/world /lib/apk/db/installed)"
    assert 'plan reports readiness' grep -q '^PLAN_OK=true$' "$ROOT/plan.out"
    if [ "$before" = "$after" ]; then
        ok 'plan leaves config, world and package DB unchanged'
    else
        not_ok 'plan leaves config, world and package DB unchanged'
    fi
else
    cat "$ROOT/plan.out" >&2
    not_ok 'plan succeeds'
fi

# The semantic preflight may use tmpfs but must leave config and package state
# untouched. The exact production model is covered by the separate real-config
# container run; this fixture verifies the wrapper's no-mutation contract.
before_preflight="$(sha256sum /etc/config/podkop /etc/apk/world /lib/apk/db/installed)"
# shellcheck disable=SC2086
if env $common_env ash "$SCRIPT" --preflight >"$ROOT/preflight.out" 2>&1; then
    after_preflight="$(sha256sum /etc/config/podkop /etc/apk/world /lib/apk/db/installed)"
    assert 'semantic preflight reports success' grep -q '^PREFLIGHT_OK=true$' "$ROOT/preflight.out"
    if [ "$before_preflight" = "$after_preflight" ]; then
        ok 'semantic preflight leaves config, world and package DB unchanged'
    else
        not_ok 'semantic preflight leaves config, world and package DB unchanged'
    fi
else
    cat "$ROOT/preflight.out" >&2
    not_ok 'semantic preflight succeeds'
fi

if [ "$TEST_CASE" = success ]; then
    mkdir -p /etc/rc.d
    : >/tmp/tachyon-package-was-running
    ln -sf /etc/init.d/tachyon /etc/rc.d/S99tachyon
    # shellcheck disable=SC2086
    if env $common_env ash "$SCRIPT" --apply --confirm MIGRATE-PODKOP-TO-TACHYON >"$ROOT/apply.out" 2>&1; then
        assert 'successful transaction reports success' grep -q '^MIGRATION_OK=true$' "$ROOT/apply.out"
        assert 'Podkop config was migrated' test -s /etc/config/tachyon
        assert 'Podkop config path is gone' test ! -e /etc/config/podkop
        assert 'pinned core was installed' /usr/bin/tachyon-core version
        assert 'legacy name is a one-way compatibility link' test "$(readlink /usr/bin/sing-box)" = /usr/bin/tachyon-core
        assert 'stale package restart marker was removed' test ! -e /tmp/tachyon-package-was-running
        assert 'Tachyon package state is active' grep -q '^P:tachyon$' /lib/apk/db/installed
    else
        cat "$ROOT/apply.out" >&2
        not_ok 'successful transaction completes'
    fi
else
    mkdir -p /etc/rc.d
    : >/tmp/tachyon-package-was-running
    ln -sf /etc/init.d/tachyon /etc/rc.d/S99tachyon
    # shellcheck disable=SC2086
    if env $common_env TACHYON_FAKE_FAIL_ENGINE=1 ash "$SCRIPT" --apply --confirm MIGRATE-PODKOP-TO-TACHYON >"$ROOT/apply.out" 2>&1; then
        not_ok 'failed engine causes a non-zero Apply result'
    else
        assert 'automatic rollback reports success' grep -q '^ROLLBACK_OK=true$' "$ROOT/apply.out"
        assert 'Podkop package state was restored' grep -q '^P:podkop$' /lib/apk/db/installed
        assert 'Podkop config was restored' test -s /etc/config/podkop
        assert 'Tachyon config was removed' test ! -e /etc/config/tachyon
        assert 'old sing-box executable was restored' test -x /usr/bin/sing-box
        assert 'rollback removes stale Tachyon restart marker' test ! -e /tmp/tachyon-package-was-running
    fi
fi

printf 'PASS=%s FAIL=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
