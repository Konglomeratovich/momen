#!/bin/sh
set -eu

[ "${TACHYON_CONTAINER_TEST:-0}" = 1 ] || {
    printf 'Refusing to modify this system; use a disposable OpenWrt container.\n' >&2
    exit 2
}

SCRIPT=/work/scripts/bootstrap-podkop-to-tachyon.sh
ROOT=/tmp/bootstrap-test
SOURCE="$ROOT/source"
ASSETS="$ROOT/assets"
ROLLBACK="$ROOT/rollback"
MOCKBIN="$ROOT/bin"
LOG="$ROOT/migrator.log"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
not_ok() { fail=$((fail + 1)); printf 'not ok - %s\n' "$1" >&2; }
assert() { label="$1"; shift; if "$@"; then ok "$label"; else not_ok "$label"; fi; }

rm -rf "$ROOT"
mkdir -p "$SOURCE" "$ASSETS" "$MOCKBIN" /etc/config /etc/apk /lib/apk/db /etc/sing-box

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
EOF
printf '{"inbounds":[]}\n' >/etc/sing-box/config.json
printf 'xn--p1ai\n' >/etc/momen-r1-cyrillic-tlds.lst

cat >"$SOURCE/audit-tachyon-readiness.sh" <<'EOF'
#!/bin/sh
printf 'APPLY_ALLOWED=true\n'
EOF

cat >"$SOURCE/migrate-podkop-to-tachyon.sh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TACHYON_TEST_LOG"
case "$1" in
    --plan) printf 'PLAN_OK=true\n' ;;
    --preflight) printf 'PREFLIGHT_OK=true\n' ;;
    --apply) printf 'MIGRATION_OK=true\n' ;;
    *) exit 2 ;;
esac
EOF
chmod 0700 "$SOURCE"/*.sh

for name in \
    podkop-0.7.22-r1.apk \
    luci-app-podkop-0.7.22-r1.apk \
    luci-i18n-podkop-ru-0.7.22.apk \
    sing-box-1.12.17-r1.apk
do
    printf 'fixture:%s\n' "$name" >"$ASSETS/$name"
done

cat >"$MOCKBIN/nft" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$MOCKBIN/ip" <<'EOF'
#!/bin/sh
[ "$1" = rule ] && printf '105: from all lookup tachyon\n'
exit 0
EOF
chmod 0700 "$MOCKBIN/nft" "$MOCKBIN/ip"

hash() { sha256sum "$1" | awk '{ print $1 }'; }

export PATH="$MOCKBIN:$PATH"
export TACHYON_TEST_LOG="$LOG"
export TACHYON_BOOTSTRAP_SOURCE_DIR="$SOURCE"
export TACHYON_ROLLBACK_ASSET_DIR="$ASSETS"
export TACHYON_ROLLBACK_DIR="$ROLLBACK"
export TACHYON_BOOTSTRAP_WORK_DIR="$ROOT/work"
TACHYON_TEST_AUDIT_SHA256="$(hash "$SOURCE/audit-tachyon-readiness.sh")"
TACHYON_TEST_MIGRATOR_SHA256="$(hash "$SOURCE/migrate-podkop-to-tachyon.sh")"
TACHYON_TEST_PODKOP_APK_SHA256="$(hash "$ASSETS/podkop-0.7.22-r1.apk")"
TACHYON_TEST_LUCI_APK_SHA256="$(hash "$ASSETS/luci-app-podkop-0.7.22-r1.apk")"
TACHYON_TEST_I18N_APK_SHA256="$(hash "$ASSETS/luci-i18n-podkop-ru-0.7.22.apk")"
TACHYON_TEST_SING_BOX_APK_SHA256="$(hash "$ASSETS/sing-box-1.12.17-r1.apk")"
export TACHYON_TEST_AUDIT_SHA256 TACHYON_TEST_MIGRATOR_SHA256
export TACHYON_TEST_PODKOP_APK_SHA256 TACHYON_TEST_LUCI_APK_SHA256
export TACHYON_TEST_I18N_APK_SHA256 TACHYON_TEST_SING_BOX_APK_SHA256

plan_output="$ROOT/plan.out"
if ! ash "$SCRIPT" --plan >"$plan_output" 2>"$ROOT/plan.err"; then
    cat "$ROOT/plan.out" "$ROOT/plan.err" >&2
    exit 1
fi
manifest_sha="$(sed -n 's/^ROLLBACK_MANIFEST_SHA256=//p' "$plan_output")"

assert 'plan produced a valid manifest hash' test "${#manifest_sha}" -eq 64
assert 'rollback manifest verifies' sh -c "cd '$ROLLBACK' && sha256sum -c SHA256SUMS >/dev/null"
assert 'backup contains Podkop UCI' tar -tzf "$ROLLBACK/config-backup.tar.gz" etc/config/podkop
assert 'backup contains external DIRECT list' tar -tzf "$ROLLBACK/config-backup.tar.gz" etc/momen-r1-cyrillic-tlds.lst
assert 'plan did not call a mutating mode' sh -c "[ \"$(cat "$LOG")\" = '--plan' ]"

: >"$LOG"
if ash "$SCRIPT" --preflight \
    --rollback-manifest-sha256 0000000000000000000000000000000000000000000000000000000000000000 \
    --confirm-backup COPIED-OFF-ROUTER >/dev/null 2>&1; then
    not_ok 'wrong manifest hash fails closed'
else
    ok 'wrong manifest hash fails closed'
fi
assert 'wrong manifest failed before migration helper' test ! -s "$LOG"

ash "$SCRIPT" --preflight \
    --rollback-manifest-sha256 "$manifest_sha" \
    --confirm-backup COPIED-OFF-ROUTER >"$ROOT/preflight.out"
assert 'preflight runs plan then semantic preflight' sh -c "printf '%s\n' '--plan' '--preflight' | cmp -s - '$LOG'"
assert 'preflight reports success' grep -q '^BOOTSTRAP_PREFLIGHT_OK=true$' "$ROOT/preflight.out"

: >"$LOG"
if ash "$SCRIPT" --apply \
    --rollback-manifest-sha256 "$manifest_sha" \
    --confirm-backup COPIED-OFF-ROUTER >/dev/null 2>&1; then
    not_ok 'apply without transaction confirmation fails closed'
else
    ok 'apply without transaction confirmation fails closed'
fi
assert 'missing apply confirmation fails before helper' test ! -s "$LOG"

ash "$SCRIPT" --apply \
    --rollback-manifest-sha256 "$manifest_sha" \
    --confirm-backup COPIED-OFF-ROUTER \
    --confirm MIGRATE-PODKOP-TO-TACHYON >"$ROOT/apply.out"
assert 'apply reruns both gates before transaction' sh -c "printf '%s\n' '--plan' '--preflight' '--apply --confirm MIGRATE-PODKOP-TO-TACHYON' | cmp -s - '$LOG'"
assert 'apply reports bootstrap success' grep -q '^BOOTSTRAP_MIGRATION_OK=true$' "$ROOT/apply.out"

cat >/lib/apk/db/installed <<'EOF'
P:tachyon
V:1.7.11
I:1000
EOF
mkdir -p /etc/init.d /usr/bin
cat >/usr/bin/tachyon-core <<'EOF'
#!/bin/sh
printf 'sing-box version 1.14.3-extended-2.7.3\n'
EOF
for svc in tachyon tachyon-core; do
    cat >"/etc/init.d/$svc" <<'EOF'
#!/bin/sh
[ "$1" = status ]
EOF
    chmod 0700 "/etc/init.d/$svc"
done
chmod 0700 /usr/bin/tachyon-core

ash "$SCRIPT" --apply >"$ROOT/idempotent.out"
assert 'rerun recognizes the completed migration' grep -q '^ALREADY_MIGRATED=true$' "$ROOT/idempotent.out"
assert 'rerun performs an idempotent healthcheck' grep -q '^IDEMPOTENT_HEALTHCHECK_OK=true$' "$ROOT/idempotent.out"

printf 'PASS=%s FAIL=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
