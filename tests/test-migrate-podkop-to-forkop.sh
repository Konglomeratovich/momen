#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$PROJECT_DIR/migrate-podkop-to-forkop.sh"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/momen-forkop-tests.XXXXXX")"
PASS=0
FAIL=0

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

pass() {
    PASS=$((PASS + 1))
    printf 'ok %s - %s\n' "$PASS" "$1"
}

fail_test() {
    FAIL=$((FAIL + 1))
    printf 'not ok %s - %s\n' "$((PASS + FAIL))" "$1" >&2
}

assert_contains() {
    file="$1"
    value="$2"
    grep -Fq -- "$value" "$file" || {
        printf 'missing output: %s\n' "$value" >&2
        return 1
    }
}

assert_not_contains() {
    file="$1"
    value="$2"
    ! grep -Fq -- "$value" "$file" || {
        printf 'unexpected output: %s\n' "$value" >&2
        return 1
    }
}

write_service_mock() {
    destination="$1"
    service_name="$2"
    cat > "$destination" <<'EOF'
#!/bin/sh
state="${MOMEN_TEST_STATE:?}/SERVICE_NAME"
enabled="$state.enabled"
running="$state.running"
case "${1:-}" in
enabled) [ -e "$enabled" ] ;;
running) [ -e "$running" ] ;;
status) [ -e "$running" ] && printf 'running\n' || printf 'stopped\n' ;;
enable) : > "$enabled" ;;
disable) rm -f "$enabled" ;;
start|restart) : > "$running" ;;
stop) rm -f "$running" ;;
*) exit 0 ;;
esac
EOF
    sed -i "s/SERVICE_NAME/$service_name/g" "$destination"
    chmod 0755 "$destination"
}

write_podkop_binary() {
    destination="$1"
    cat > "$destination" <<'EOF'
#!/bin/sh
case "${1:-}" in
restore_dnsmasq|dnsmasq_restore|reload) exit 0 ;;
get_status) printf '{"running":1}\n' ;;
*) exit 0 ;;
esac
EOF
    chmod 0755 "$destination"
}

write_mock_uci() {
    destination="$1"
    cat > "$destination" <<'EOF'
#!/bin/sh
quiet=0
if [ "${1:-}" = '-q' ]; then
    quiet=1
    shift
fi
[ "${1:-}" = 'get' ] || exit 2
query="$2"
package="${query%%.*}"
rest="${query#*.}"
section="${rest%%.*}"
option=''
[ "$rest" = "$section" ] || option="${rest#*.}"
file="${MOMEN_ROOT:?}/etc/config/$package"
[ -r "$file" ] || exit 1
awk -v wanted_section="$section" -v wanted_option="$option" '
function unquote(value) {
    sub(/^[[:space:]]+/, "", value)
    if (value ~ /^\047/) {
        sub(/^\047/, "", value)
        sub(/\047[[:space:]]*$/, "", value)
    }
    return value
}
/^[[:space:]]*config[[:space:]]+/ {
    type=$2
    name=$3
    gsub(/\047/, "", type)
    gsub(/\047/, "", name)
    active=(name == wanted_section)
    if (active && wanted_option == "") {
        print type
        found=1
        exit
    }
    next
}
active && /^[[:space:]]*(option|list)[[:space:]]+/ {
    kind=$1
    key=$2
    if (key != wanted_option)
        next
    value=$0
    sub(/^[[:space:]]*(option|list)[[:space:]]+[^[:space:]]+[[:space:]]+/, "", value)
    value=unquote(value)
    if (kind == "list") {
        if (output != "") output=output " "
        output=output value
    } else {
        output=value
    }
    found=1
}
END {
    if (wanted_option != "" && found) print output
    if (!found) exit 1
}
' "$file"
EOF
    chmod 0755 "$destination"
}

write_mock_ucode() {
    destination="$1"
    cat > "$destination" <<'EOF'
#!/bin/sh
[ "${MOCK_UCODE_FAIL:-0}" != '1' ] || exit 41
file="${MOMEN_ROOT:?}/etc/config/forkop"
tmp="$file.tmp"
awk '
function quoted_value(line, value) {
    value=line
    sub(/^[^\047]*\047/, "", value)
    sub(/\047.*$/, "", value)
    return value
}
{
    line=$0
    if (line ~ /^[[:space:]]*option dns_server /) {
        sub(/option dns_server/, "list dns_server", line)
    } else if (line ~ /^[[:space:]]*option bootstrap_dns_server /) {
        sub(/option bootstrap_dns_server/, "list bootstrap_dns_server", line)
    } else if (line ~ /^[[:space:]]*option connection_type \047proxy\047/) {
        sub(/option connection_type \047proxy\047/, "option action \047connection\047", line)
    } else if (line ~ /^[[:space:]]*option connection_type \047vpn\047/) {
        sub(/option connection_type \047vpn\047/, "option action \047connection\047", line)
    } else if (line ~ /^[[:space:]]*option connection_type \047exclusion\047/) {
        sub(/option connection_type \047exclusion\047/, "option action \047bypass\047", line)
    } else if (line ~ /^[[:space:]]*option proxy_string /) {
        sub(/option proxy_string/, "list selector_proxy_links", line)
    }
    print line
}
' "$file" > "$tmp" || exit 1
mv "$tmp" "$file"
exit 0
EOF
    chmod 0755 "$destination"
}

write_mock_apk() {
    destination="$1"
    cat > "$destination" <<'EOF'
#!/bin/sh
set -eu
state="${MOMEN_TEST_STATE:?}"
root="${MOMEN_ROOT:?}"
log="$state/apk.log"
printf '%s\n' "$*" >> "$log"
command="${1:-}"
shift || true

installed() {
    [ -e "$state/packages/$1" ]
}

install_forkop_files() {
    mkdir -p "$root/etc/config" "$root/etc/init.d" "$root/usr/bin" "$root/usr/lib/forkop/config"
    if [ ! -e "$root/etc/config/forkop" ]; then
        printf "config settings 'settings'\n" > "$root/etc/config/forkop"
    fi
    cat > "$root/usr/bin/forkop" <<'EOS'
#!/bin/sh
case "${1:-}" in
reload|restore_dnsmasq|dnsmasq_restore) exit 0 ;;
get_status) printf '{"running":1}\n' ;;
*) exit 0 ;;
esac
EOS
    chmod 0755 "$root/usr/bin/forkop"
    cat > "$root/etc/init.d/forkop" <<'EOS'
#!/bin/sh
state="${MOMEN_TEST_STATE:?}/forkop"
case "${1:-}" in
enabled) [ -e "$state.enabled" ] ;;
running) [ -e "$state.running" ] ;;
status) [ -e "$state.running" ] && printf 'running\n' || printf 'stopped\n' ;;
enable) : > "$state.enabled" ;;
disable) rm -f "$state.enabled" ;;
start|restart) : > "$state.running" ;;
stop) rm -f "$state.running" ;;
*) exit 0 ;;
esac
EOS
    chmod 0755 "$root/etc/init.d/forkop"
    : > "$root/usr/lib/forkop/config/migration.uc"
}

case "$command" in
list)
    [ "${1:-}" = '--installed' ] || exit 2
    shift
    if [ "$#" -gt 0 ]; then
        [ -r "$state/packages/$1" ] && cat "$state/packages/$1" && exit 0
        exit 1
    fi
    for file in "$state"/packages/*; do
        [ -f "$file" ] && cat "$file"
    done
    ;;
info)
    if [ "${1:-}" = '-e' ]; then
        installed "$2"
        exit $?
    fi
    if [ "${1:-}" = '-v' ]; then
        if [ "$#" -gt 1 ]; then
            [ -r "$state/packages/$2" ] && cat "$state/packages/$2" && exit 0
            exit 1
        fi
        for file in "$state"/packages/*; do
            [ -f "$file" ] && cat "$file"
        done
        exit 0
    fi
    exit 2
    ;;
add)
    simulate=0
    for arg in "$@"; do
        [ "$arg" != '--simulate' ] || simulate=1
    done
    [ "${MOCK_APK_ADD_FAIL:-0}" != '1' ] || exit 42
    [ "$simulate" -eq 0 ] || exit 0
    for arg in "$@"; do
        case "$(basename "$arg")" in
        forkop_*.apk) printf 'forkop-1.0.5\n' > "$state/packages/forkop"; install_forkop_files ;;
        luci-app-forkop_*.apk) printf 'luci-app-forkop-1.0.5\n' > "$state/packages/luci-app-forkop" ;;
        luci-i18n-forkop-ru_*.apk) printf 'luci-i18n-forkop-ru-1.0.5\n' > "$state/packages/luci-i18n-forkop-ru" ;;
        podkop-*.apk) printf 'podkop-0.7.22-r1\n' > "$state/packages/podkop" ;;
        luci-app-podkop-*.apk) printf 'luci-app-podkop-0.7.22-r1\n' > "$state/packages/luci-app-podkop" ;;
        luci-i18n-podkop-ru-*.apk) printf 'luci-i18n-podkop-ru-0.7.22\n' > "$state/packages/luci-i18n-podkop-ru" ;;
        kmod-gre|kmod-pptp|ppp-mod-pptp|kmod-nf-nathelper|kmod-nf-nathelper-extra|tcpdump)
            printf '%s-1.0\n' "$arg" > "$state/packages/$arg"
            ;;
        esac
    done
    ;;
del)
    simulate=0
    for arg in "$@"; do
        [ "$arg" != '--simulate' ] || simulate=1
    done
    [ "${MOCK_APK_DEL_FAIL:-0}" != '1' ] || exit 43
    [ "$simulate" -eq 0 ] || exit 0
    for arg in "$@"; do
        case "$arg" in
        --simulate) ;;
        forkop)
            rm -f "$state/packages/forkop" "$root/usr/bin/forkop" "$root/etc/init.d/forkop"
            rm -rf "$root/usr/lib/forkop"
            ;;
        luci-app-forkop|luci-i18n-forkop-ru) rm -f "$state/packages/$arg" ;;
        podkop)
            rm -f "$state/packages/podkop" "$root/usr/bin/podkop" "$root/etc/init.d/podkop"
            rm -rf "$root/usr/lib/podkop"
            ;;
        luci-app-podkop|luci-i18n-podkop-ru|kmod-gre|kmod-pptp|ppp-mod-pptp|kmod-nf-nathelper|kmod-nf-nathelper-extra|tcpdump)
            rm -f "$state/packages/$arg"
            ;;
        esac
    done
    ;;
*) exit 2 ;;
esac
EOF
    chmod 0755 "$destination"
}

make_fixture() {
    name="$1"
    fixture="$TEST_TMP/$name"
    root="$fixture/root"
    state="$fixture/state"
    mocks="$fixture/mocks"
    assets="$fixture/assets"
    mkdir -p "$root/etc/config" "$root/etc/init.d" "$root/etc" \
        "$root/usr/bin" "$root/usr/lib/podkop" "$root/overlay" "$root/root" \
        "$state/packages" "$mocks" "$assets"

    cat > "$root/etc/openwrt_release" <<'EOF'
DISTRIB_ID='OpenWrt'
DISTRIB_RELEASE='25.12.2'
EOF
    cat > "$root/etc/os-release" <<'EOF'
ID='openwrt'
NAME='OpenWrt'
EOF
    cat > "$root/usr/lib/podkop/constants.sh" <<'EOF'
PODKOP_VERSION="0.7.22"
EOF
    write_service_mock "$root/etc/init.d/podkop" podkop
    write_podkop_binary "$root/usr/bin/podkop"
    : > "$state/podkop.enabled"
    : > "$state/podkop.running"
    printf 'podkop-0.7.22-r1\n' > "$state/packages/podkop"
    printf 'luci-app-podkop-0.7.22-r1\n' > "$state/packages/luci-app-podkop"
    printf 'luci-i18n-podkop-ru-0.7.22\n' > "$state/packages/luci-i18n-podkop-ru"

    domains=''
    i=1
    while [ "$i" -le 720 ]; do
        domains="$domains d$i.example"
        i=$((i + 1))
    done
    domains="${domains# }"
    cat > "$root/etc/config/podkop" <<EOF
config settings 'settings'
        option dns_type 'doh'
        option dns_server 'common.dot.dns.yandex.net'
        option bootstrap_dns_server '77.88.8.8'
        option download_lists_via_proxy '1'
        option download_lists_via_proxy_section 'main'

config section 'main'
        option connection_type 'proxy'
        option proxy_config_type 'url'
        option proxy_string 'vless://SECRET-MUST-NOT-LEAK@example.test'

config section 'DIRECT'
        option connection_type 'exclusion'
        option managed_by 'vless-podkop-v3'
        option user_domain_list_type 'text'
        option user_domains_text '$domains'
        list local_domain_lists '/etc/momen-r1-cyrillic-tlds.lst'
EOF
    cat > "$root/etc/config/dhcp" <<'EOF'
config dnsmasq
        option domainneeded '1'
EOF
    cat > "$root/etc/momen-r1-cyrillic-tlds.lst" <<'EOF'
xn--p1ai
xn--p1acf
xn--80adxhks
xn--d1acj3b
EOF

    for asset in \
        forkop_1.0.5.apk \
        luci-app-forkop_1.0.5.apk \
        luci-i18n-forkop-ru_1.0.5.apk \
        podkop-0.7.22-r1.apk \
        luci-app-podkop-0.7.22-r1.apk \
        luci-i18n-podkop-ru-0.7.22.apk; do
        printf 'offline-test-asset\n' > "$assets/$asset"
    done

    write_mock_apk "$mocks/apk"
    write_mock_uci "$mocks/uci"
    write_mock_ucode "$mocks/ucode"
    cat > "$mocks/nslookup" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod 0755 "$mocks/nslookup"
    cat > "$mocks/modprobe" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >> "${MOMEN_TEST_STATE:?}/loaded-modules"
EOF
    cat > "$mocks/lsmod" <<'EOF'
#!/bin/sh
awk '!seen[$0]++ { print $0, 1, 0 }' "${MOMEN_TEST_STATE:?}/loaded-modules"
EOF
    chmod 0755 "$mocks/modprobe" "$mocks/lsmod"

    printf '%s\n' "$fixture"
}

fixture_env() {
    fixture="$1"
    hash="$(sha256sum "$fixture/assets/forkop_1.0.5.apk" | awk '{ print $1 }')"
    export MOMEN_ROOT="$fixture/root"
    export MOMEN_BACKUP_PARENT="$fixture/root/root"
    export MOMEN_ASSET_SOURCE_DIR="$fixture/assets"
    export MOMEN_TEST_MODE=1
    export MOMEN_TEST_EXPECTED_SHA256="$hash"
    export MOMEN_TEST_STATE="$fixture/state"
    export MOMEN_SKIP_RUNTIME_CHECKS=0
    export PATH="$fixture/mocks:$ORIGINAL_PATH"
    unset MOCK_UCODE_FAIL MOCK_APK_ADD_FAIL MOCK_APK_DEL_FAIL
}

run_case() {
    name="$1"
    shift
    if "$@"; then
        pass "$name"
    else
        fail_test "$name"
    fi
}

case_help() {
    output="$TEST_TMP/help.out"
    ash "$SCRIPT" --help > "$output"
    assert_contains "$output" '--audit'
    assert_contains "$output" '--rollback BACKUP_DIR'
}

case_audit() {
    fixture="$(make_fixture audit)"
    fixture_env "$fixture"
    before="$(sha256sum "$fixture/root/etc/config/podkop" | awk '{ print $1 }')"
    output="$fixture/audit.out"
    ash "$SCRIPT" --audit > "$output" 2>&1
    after="$(sha256sum "$fixture/root/etc/config/podkop" | awk '{ print $1 }')"
    [ "$before" = "$after" ]
    assert_contains "$output" 'AUDIT_RESULT=compatible'
    assert_not_contains "$output" 'SECRET-MUST-NOT-LEAK'
}

case_plan() {
    fixture="$(make_fixture plan)"
    fixture_env "$fixture"
    before="$(find "$fixture/root/etc" "$fixture/state/packages" -type f -exec sha256sum {} \; | sort | sha256sum | awk '{ print $1 }')"
    output="$fixture/plan.out"
    ash "$SCRIPT" --plan > "$output" 2>&1
    after="$(find "$fixture/root/etc" "$fixture/state/packages" -type f -exec sha256sum {} \; | sort | sha256sum | awk '{ print $1 }')"
    [ "$before" = "$after" ]
    assert_contains "$output" 'FORKOP_INSTALL_SIMULATION=passed'
    assert_contains "$output" 'PODKOP_REMOVE_SIMULATION=passed'
    assert_contains "$output" 'PLAN_RESULT=ready'
    assert_not_contains "$output" 'SECRET-MUST-NOT-LEAK'
}

case_apply_and_repeat() {
    fixture="$(make_fixture apply)"
    fixture_env "$fixture"
    output="$fixture/apply.out"
    ash "$SCRIPT" --apply > "$output" 2>&1
    [ -e "$fixture/state/packages/forkop" ]
    [ -e "$fixture/state/packages/luci-app-forkop" ]
    [ -e "$fixture/state/packages/kmod-gre" ]
    [ -e "$fixture/state/packages/kmod-pptp" ]
    [ -e "$fixture/state/packages/ppp-mod-pptp" ]
    [ -e "$fixture/state/packages/kmod-nf-nathelper" ]
    [ -e "$fixture/state/packages/kmod-nf-nathelper-extra" ]
    [ -e "$fixture/state/packages/tcpdump" ]
    [ ! -e "$fixture/state/packages/podkop" ]
    [ ! -e "$fixture/state/packages/luci-app-podkop" ]
    [ -e "$fixture/state/forkop.enabled" ]
    [ -e "$fixture/state/forkop.running" ]
    assert_contains "$output" 'FORKOP_CONFIG_VALID=true'
    assert_contains "$output" 'PODKOP_PACKAGES_REMOVED=true'
    assert_contains "$output" 'PPTP_KERNEL_MODULES_VALID=true'
    assert_contains "$output" 'APPLY_RESULT=migrated'
    assert_not_contains "$output" 'SECRET-MUST-NOT-LEAK'
    backup_dir="$(sed -n 's/^BACKUP_DIR=//p' "$output" | tail -n 1)"
    [ -r "$backup_dir/podkop-snapshot.tar.gz" ]
    [ -r "$backup_dir/packages/podkop-0.7.22-r1.apk" ]

    repeat="$fixture/repeat.out"
    ash "$SCRIPT" --apply > "$repeat" 2>&1
    assert_contains "$repeat" 'APPLY_RESULT=already-migrated'
    assert_not_contains "$repeat" 'SECRET-MUST-NOT-LEAK'
}

case_stopped_service_is_tested_and_preserved() {
    fixture="$(make_fixture stopped-service)"
    fixture_env "$fixture"
    rm -f "$fixture/state/podkop.enabled" "$fixture/state/podkop.running"
    output="$fixture/apply.out"
    ash "$SCRIPT" --apply > "$output" 2>&1
    [ ! -e "$fixture/state/forkop.enabled" ]
    [ ! -e "$fixture/state/forkop.running" ]
    assert_contains "$output" 'FORKOP_RUNTIME_VALID=true'
    assert_contains "$output" 'FORKOP_SERVICE_RUNNING=false'
}

case_explicit_rollback() {
    fixture="$(make_fixture rollback)"
    fixture_env "$fixture"
    output="$fixture/apply.out"
    ash "$SCRIPT" --apply > "$output" 2>&1
    backup_dir="$(sed -n 's/^BACKUP_DIR=//p' "$output" | tail -n 1)"
    rollback_output="$fixture/rollback.out"
    ash "$SCRIPT" --rollback "$backup_dir" > "$rollback_output" 2>&1
    [ -e "$fixture/state/packages/podkop" ]
    [ -e "$fixture/state/packages/luci-app-podkop" ]
    [ ! -e "$fixture/state/packages/forkop" ]
    [ ! -e "$fixture/state/packages/kmod-gre" ]
    [ ! -e "$fixture/state/packages/tcpdump" ]
    [ -e "$fixture/state/podkop.enabled" ]
    [ -e "$fixture/state/podkop.running" ]
    grep -Fq 'SECRET-MUST-NOT-LEAK' "$fixture/root/etc/config/podkop"
    assert_contains "$rollback_output" 'ROLLBACK_RESULT=restored'
    assert_not_contains "$rollback_output" 'SECRET-MUST-NOT-LEAK'
}

case_preexisting_pptp_packages_survive_rollback() {
    fixture="$(make_fixture preexisting-pptp)"
    fixture_env "$fixture"
    for package_name in kmod-gre kmod-pptp ppp-mod-pptp kmod-nf-nathelper kmod-nf-nathelper-extra tcpdump; do
        printf '%s-1.0\n' "$package_name" > "$fixture/state/packages/$package_name"
    done
    output="$fixture/apply.out"
    ash "$SCRIPT" --apply > "$output" 2>&1
    backup_dir="$(sed -n 's/^BACKUP_DIR=//p' "$output" | tail -n 1)"
    ash "$SCRIPT" --rollback "$backup_dir" > "$fixture/rollback.out" 2>&1
    for package_name in kmod-gre kmod-pptp ppp-mod-pptp kmod-nf-nathelper kmod-nf-nathelper-extra tcpdump; do
        [ -e "$fixture/state/packages/$package_name" ]
    done
}

case_automatic_rollback() {
    fixture="$(make_fixture auto-rollback)"
    fixture_env "$fixture"
    export MOCK_UCODE_FAIL=1
    output="$fixture/apply.out"
    if ash "$SCRIPT" --apply > "$output" 2>&1; then
        return 1
    fi
    [ -e "$fixture/state/packages/podkop" ]
    [ -e "$fixture/state/packages/luci-app-podkop" ]
    [ ! -e "$fixture/state/packages/forkop" ]
    [ -e "$fixture/state/podkop.enabled" ]
    [ -e "$fixture/state/podkop.running" ]
    assert_contains "$output" 'automatic rollback completed'
    assert_not_contains "$output" 'SECRET-MUST-NOT-LEAK'
}

case_bad_hash() {
    fixture="$(make_fixture bad-hash)"
    fixture_env "$fixture"
    export MOMEN_TEST_EXPECTED_SHA256='0000000000000000000000000000000000000000000000000000000000000000'
    output="$fixture/plan.out"
    if ash "$SCRIPT" --plan > "$output" 2>&1; then
        return 1
    fi
    [ -e "$fixture/state/packages/podkop" ]
    [ ! -e "$fixture/state/packages/forkop" ]
    assert_contains "$output" 'SHA-256 mismatch'
}

case_unsupported_openwrt() {
    fixture="$(make_fixture unsupported-openwrt)"
    fixture_env "$fixture"
    sed -i "s/25\.12\.2/24.10.5/" "$fixture/root/etc/openwrt_release"
    output="$fixture/audit.out"
    if ash "$SCRIPT" --audit > "$output" 2>&1; then
        return 1
    fi
    assert_contains "$output" 'OpenWrt 25.12.2 is required'
}

case_unverified_openwrt_patch() {
    fixture="$(make_fixture unverified-openwrt-patch)"
    fixture_env "$fixture"
    sed -i "s/25\.12\.2/25.12.1/" "$fixture/root/etc/openwrt_release"
    output="$fixture/audit.out"
    if ash "$SCRIPT" --audit > "$output" 2>&1; then
        return 1
    fi
    assert_contains "$output" 'OpenWrt 25.12.2 is required'
}

case_wrong_podkop_version() {
    fixture="$(make_fixture wrong-podkop)"
    fixture_env "$fixture"
    sed -i 's/0\.7\.22/0.7.24/' "$fixture/root/usr/lib/podkop/constants.sh"
    output="$fixture/audit.out"
    if ash "$SCRIPT" --audit > "$output" 2>&1; then
        return 1
    fi
    assert_contains "$output" 'Podkop 0.7.22 is required'
}

case_missing_direct_catalog() {
    fixture="$(make_fixture missing-direct)"
    fixture_env "$fixture"
    sed -i "s/option managed_by 'vless-podkop-v3'/option managed_by 'someone-else'/" "$fixture/root/etc/config/podkop"
    output="$fixture/audit.out"
    if ash "$SCRIPT" --audit > "$output" 2>&1; then
        return 1
    fi
    assert_contains "$output" 'not managed by the audited momen installer'
}

ORIGINAL_PATH="$PATH"
run_case 'help documents safe modes' case_help
run_case 'audit is read-only and redacts proxy data' case_audit
run_case 'plan simulates both transactions without mutation' case_plan
run_case 'apply migrates, verifies, removes Podkop, and is repeat-safe' case_apply_and_repeat
run_case 'stopped and disabled service state is tested and preserved' case_stopped_service_is_tested_and_preserved
run_case 'explicit rollback restores Podkop and service state' case_explicit_rollback
run_case 'rollback preserves pre-existing PPTP support packages' case_preexisting_pptp_packages_survive_rollback
run_case 'failed migration triggers automatic rollback' case_automatic_rollback
run_case 'asset hash mismatch stops before mutation' case_bad_hash
run_case 'unsupported OpenWrt release is rejected' case_unsupported_openwrt
run_case 'unverified OpenWrt patch release is rejected' case_unverified_openwrt_patch
run_case 'unsupported Podkop version is rejected' case_wrong_podkop_version
run_case 'unmanaged DIRECT catalog is rejected' case_missing_direct_catalog

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
