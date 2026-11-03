#!/bin/sh
set -u

# Transactional migration for eligible ARM64 OpenWrt routers. The device model
# and target are informational; compatibility and capacity are decided from
# the actual OpenWrt architecture, package state, storage, tmpfs and RAM. The
# official Tachyon installer is used only for the package/config migration.
# Engine installation is performed separately so the extended-compressed
# release can be pinned instead of silently following "latest".

EXPECTED_RELEASE="25.12.2"
SUPPORTED_ARCH_PREFIX="aarch64"

TACHYON_TAG="1.7.11"
TACHYON_INSTALLER_URL="https://raw.githubusercontent.com/Dushnilin/tachyon/7a8843fbf9475374ce5fffce354b060fcb33b431/install.sh"
TACHYON_INSTALLER_SHA256="${TACHYON_INSTALLER_SHA256:-57e780a87b6cdd1064d982d94093ae7c195d9a0fef1d2771410b5086bac20949}"
INSTALLER_FIXTURE="${TACHYON_INSTALLER_FIXTURE:-}"
TACHYON_BACKEND_URL="https://github.com/Dushnilin/tachyon/releases/download/1.7.11/tachyon_1.7.11.apk"
TACHYON_BACKEND_SHA256="5b0b7a8f873997fc4b1b86a63a20dcc058854ee6abb597e0c83040d75093c9a1"
ENGINE_TAG="v1.14.3-extended-2.7.3"
ENGINE_ARCHIVE_URL="https://github.com/shtorm-7/sing-box-extended/releases/download/${ENGINE_TAG}/sing-box-1.14.3-extended-2.7.3-linux-arm64-compressed.tar.gz"
ENGINE_ARCHIVE_SHA256="21d90e197a2523b74016fda0f770ae874eeb4e1aca99d3956b160f41380306eb"
EXPECTED_DIRECT_TOTAL=725
EXPECTED_DIRECT_EXTRA=plex.tv
CATALOG_URL="https://raw.githubusercontent.com/Konglomeratovich/momen/main/assets/r1.lst"
CATALOG_SHA256=aaa17d6a89fdd62211b10e7b7fd9cefe62e9169c6cf550a92983560bf89bf2ee

AUDIT_SCRIPT="${TACHYON_AUDIT_SCRIPT:-/tmp/audit-tachyon-readiness.sh}"
AUDIT_SHA256="${TACHYON_AUDIT_SHA256:-172249a0b2f7a1fad639c5d2c551cdeca8638bbfd368a79f06a0cccb68ad3d45}"
ROLLBACK_DIR="${TACHYON_ROLLBACK_DIR:-/tmp/podkop-rollback}"
WORK_ROOT="${TACHYON_WORK_ROOT:-/tmp}"
FETCH_CMD=""
MODE=""
WORK_DIR=""
SNAPSHOT_FILE=""
NORMALIZED_CONFIG_FILE=""
FINAL_CONFIG_FILE=""
APPLY_STARTED=0
ROLLBACK_ATTEMPTED=0
SEMANTIC_FIXTURE="${TACHYON_SEMANTIC_PREFLIGHT_FIXTURE:-}"
MEASURED_ENGINE_INSTALLED_KB=""
MEASURED_DOWNLOAD_KB=""
STAGED_DOWNLOAD_KB=""

if [ "${TACHYON_TEST_MODE:-0}" = 1 ]; then
    TACHYON_BACKEND_URL="${TACHYON_TEST_BACKEND_URL:-$TACHYON_BACKEND_URL}"
    TACHYON_BACKEND_SHA256="${TACHYON_TEST_BACKEND_SHA256:-$TACHYON_BACKEND_SHA256}"
    ENGINE_ARCHIVE_URL="${TACHYON_TEST_ENGINE_URL:-$ENGINE_ARCHIVE_URL}"
    ENGINE_ARCHIVE_SHA256="${TACHYON_TEST_ENGINE_SHA256:-$ENGINE_ARCHIVE_SHA256}"
    EXPECTED_DIRECT_TOTAL="${TACHYON_TEST_DIRECT_TOTAL:-$EXPECTED_DIRECT_TOTAL}"
    EXPECTED_DIRECT_EXTRA="${TACHYON_TEST_DIRECT_EXTRA:-$EXPECTED_DIRECT_EXTRA}"
fi

usage() {
    cat <<'EOF'
Usage:
  migrate-podkop-to-tachyon.sh --plan
  migrate-podkop-to-tachyon.sh --preflight
  migrate-podkop-to-tachyon.sh --apply --confirm MIGRATE-PODKOP-TO-TACHYON

--plan is strictly read-only: it validates the router, the audited readiness
result and the staged rollback bundle, then prints the pinned transaction.

--preflight downloads verified assets into tmpfs and runs the full semantic
configuration and pinned-engine check, but does not change packages, UCI or
services. It is the required final gate before --apply.

--apply creates a fresh tmpfs snapshot, downloads and verifies the exact
Tachyon/runtime assets, migrates a private copy of the real UCI configuration,
proves all 725 DIRECT rules and the pinned engine config before package changes,
then installs Tachyon with its first start deferred until extended-compressed is
pinned. Any failure rolls back packages, config, apk world and service state.

Do not reboot during Apply or rollback. /tmp and the rollback bundle are lost
on reboot. Keep a second copy of the bundle outside the router.
EOF
}

log() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
fail() { printf 'ERROR: %s\n' "$*" >&2; return 1; }

is_installed() {
    grep -q "^P:$1$" /lib/apk/db/installed 2>/dev/null
}

release_value() {
    sed -n "s/^$1='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null | head -n 1
}

sha256_value() {
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

find_one() {
    pattern="$1"
    # Intentional glob: exactly one version-pinned rollback asset must match.
    # shellcheck disable=SC2086
    set -- "$ROLLBACK_DIR"/$pattern
    [ "$#" -eq 1 ] && [ -f "$1" ] || return 1
    printf '%s\n' "$1"
}

verify_rollback_bundle() {
    [ -d "$ROLLBACK_DIR" ] || fail "rollback directory is missing: $ROLLBACK_DIR" || return 1
    [ -s "$ROLLBACK_DIR/SHA256SUMS" ] || fail 'rollback SHA256SUMS is missing' || return 1
    (
        cd "$ROLLBACK_DIR" || exit 1
        sha256sum -c SHA256SUMS >/dev/null
    ) || fail 'rollback bundle SHA-256 verification failed' || return 1

    find_one 'podkop-0.7.22-r1.apk' >/dev/null || fail 'exact Podkop rollback APK is missing' || return 1
    find_one 'luci-app-podkop-0.7.22-r1.apk' >/dev/null || fail 'exact Podkop LuCI rollback APK is missing' || return 1
    find_one 'luci-i18n-podkop-ru-0.7.22.apk' >/dev/null || fail 'exact Russian translation rollback APK is missing' || return 1
    find_one 'sing-box-1.12.17-r1.apk' >/dev/null || fail 'exact sing-box rollback APK is missing' || return 1
    [ -s "$ROLLBACK_DIR/config-backup.tar.gz" ] || fail 'off-router configuration backup copy is not staged' || return 1
    tar -tzf "$ROLLBACK_DIR/config-backup.tar.gz" >/dev/null 2>&1 || fail 'configuration backup archive is unreadable' || return 1
}

run_audit() {
    [ -r "$AUDIT_SCRIPT" ] || fail "readiness audit is missing: $AUDIT_SCRIPT" || return 1
    actual="$(sha256_value "$AUDIT_SCRIPT")"
    [ "$actual" = "$AUDIT_SHA256" ] || fail "readiness audit SHA-256 mismatch: $actual" || return 1
    output="$(
        TACHYON_ROLLBACK_DIR="$ROLLBACK_DIR" \
        TACHYON_MEASURED_ENGINE_INSTALLED_KB="${MEASURED_ENGINE_INSTALLED_KB:-}" \
        TACHYON_MEASURED_DOWNLOAD_KB="${MEASURED_DOWNLOAD_KB:-}" \
            ash "$AUDIT_SCRIPT" --variant extended-compressed 2>&1
    )"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        printf '%s\n' "$output" >&2
        fail 'readiness audit rejected Apply'
        return 1
    fi
    printf '%s\n' "$output" | grep -q '^SPACE_OK=true$' || { printf '%s\n' "$output" >&2; fail 'audit did not report SPACE_OK=true'; return 1; }
    printf '%s\n' "$output" | grep -q '^ROLLBACK_READY=true$' || { printf '%s\n' "$output" >&2; fail 'audit did not report ROLLBACK_READY=true'; return 1; }
    printf '%s\n' "$output" | grep -q '^APPLY_ALLOWED=true$' || { printf '%s\n' "$output" >&2; fail 'audit did not report APPLY_ALLOWED=true'; return 1; }
}

preflight() {
    [ "$(id -u)" = 0 ] || fail 'run as root' || return 1
    [ -r /etc/openwrt_release ] || fail 'OpenWrt release file is missing' || return 1
    [ "$(release_value DISTRIB_RELEASE)" = "$EXPECTED_RELEASE" ] || fail "only OpenWrt $EXPECTED_RELEASE is supported" || return 1
    case "$(release_value DISTRIB_ARCH)" in
        "$SUPPORTED_ARCH_PREFIX"*) ;;
        *) fail "this pinned build supports only ${SUPPORTED_ARCH_PREFIX}* OpenWrt architectures"; return 1 ;;
    esac
    command -v apk >/dev/null 2>&1 || fail 'apk is required' || return 1
    command -v sha256sum >/dev/null 2>&1 || fail 'sha256sum is required' || return 1
    command -v tar >/dev/null 2>&1 || fail 'tar is required' || return 1
    command -v uci >/dev/null 2>&1 || fail 'uci is required' || return 1
    command -v ucode >/dev/null 2>&1 || fail 'ucode is required for the semantic preflight' || return 1
    command -v cmp >/dev/null 2>&1 || fail 'cmp is required for exact rollback verification' || return 1

    if is_installed tachyon || is_installed luci-app-tachyon; then
        fail 'Tachyon is already installed; refusing a second migration'
        return 1
    fi
    is_installed podkop || fail 'Podkop is not installed' || return 1
    is_installed luci-app-podkop || fail 'luci-app-podkop is not installed' || return 1
    is_installed sing-box || fail 'the expected packaged sing-box is not installed' || return 1
    [ -s /etc/config/podkop ] || fail '/etc/config/podkop is missing or empty' || return 1
    verify_rollback_bundle || return 1
    run_audit || return 1
}

print_plan() {
    cat <<EOF
PLAN_OK=true
OPENWRT_RELEASE=$EXPECTED_RELEASE
OPENWRT_ARCH=$(release_value DISTRIB_ARCH)
OPENWRT_TARGET=$(release_value DISTRIB_TARGET)
TACHYON_TAG=$TACHYON_TAG
ENGINE_VARIANT=extended-compressed
ENGINE_TAG=$ENGINE_TAG
CAPACITY_PLAN_SOURCE=conservative-release-estimate
CAPACITY_PREFLIGHT_SOURCE=measured-verified-engine
ROLLBACK_DIR=$ROLLBACK_DIR
ACTIONS=tmpfs-snapshot,stage-and-verify-exact-assets,normalize-725-direct-rules-on-private-copy,migrate-and-generate-on-private-copy,pinned-engine-config-check,clear-stale-tachyon-autostart,patch-verified-installer-to-defer-first-start,normalize-live-copy,install-tachyon-without-first-start,quiesce-engine-and-clear-binary-links,install-pinned-engine,first-start,final-healthcheck
AUTO_ROLLBACK=true
REBOOT_ALLOWED=false
SEMANTIC_PREFLIGHT_REQUIRED=true
EXPECTED_DIRECT_RULES=$EXPECTED_DIRECT_TOTAL
REQUIRED_EXTRA_RULE=$EXPECTED_DIRECT_EXTRA
DIRECT_LAYOUT=external-r1-plus-local-exceptions
PLEX_DIRECT_MANDATORY=true
EOF
}

detect_fetcher() {
    if command -v uclient-fetch >/dev/null 2>&1; then FETCH_CMD=uclient-fetch
    elif command -v wget >/dev/null 2>&1; then FETCH_CMD=wget
    else fail 'uclient-fetch or wget is required'; return 1
    fi
}

fetch_file() {
    url="$1"
    target="$2"
    case "$FETCH_CMD" in
        uclient-fetch) uclient-fetch -q -T 30 -O "$target" "$url" ;;
        wget) wget -q -T 30 -O "$target" "$url" ;;
        *) return 1 ;;
    esac
}

write_semantic_helpers() {
    cat >"$WORK_DIR/export-uci-model.uc" <<'EOF_UCODE'
#!/usr/bin/ucode
let uci = require("uci");
let cursor = uci.cursor(ARGV[0]);
let package_name = ARGV[1];
let model = {};
cursor.foreach(package_name, null, function(section) {
    let type_name = section[".type"];
    if (type_name == "settings" && model.settings == null) {
        model.settings = section;
        return;
    }
    if (model[type_name] == null)
        model[type_name] = [];
    push(model[type_name], section);
});
print(sprintf("%J\n", model));
EOF_UCODE

    cat >"$WORK_DIR/extract-migrated-config.uc" <<'EOF_UCODE'
#!/usr/bin/ucode
let fs = require("fs");
let result = json(fs.readfile(ARGV[0]));
if (type(result) != "object" || type(result.config) != "object")
    exit(1);
if (fs.writefile(ARGV[1], sprintf("%J", result.config)) == null)
    exit(1);
EOF_UCODE

    cat >"$WORK_DIR/validate-direct-catalog.uc" <<'EOF_UCODE'
#!/usr/bin/ucode
let fs = require("fs");
let config = json(fs.readfile(ARGV[0]));
let expected_raw = fs.readfile(ARGV[1]);
let required_extra = ARGV[2];
let expected = {};
let actual = {};
let refs = {};
let direct = null;

function add_words(target, value) {
    if (type(value) == "array") {
        for (let item in value) add_words(target, item);
        return;
    }
    for (let item in split(sprintf("%s", value || ""), /[ \t\r\n]+/)) {
        item = trim(item);
        if (item != "") target[item] = true;
    }
}

add_words(expected, expected_raw);
for (let section in config.section || []) {
    if (section[".name"] == "DIRECT") {
        direct = section;
        add_words(refs, section.condition_refs);
    }
}
if (direct == null || direct.action != "bypass") exit(2);

function collect(section) {
    for (let key in [ "domain", "domain_suffix", "user_domains", "user_domains_text" ])
        add_words(actual, section[key]);
}
collect(direct);
for (let condition in config.condition || [])
    if (refs[condition[".name"]]) collect(condition);

for (let item in expected)
    if (!actual[item] || actual["full:" + item]) exit(3);
for (let item in actual)
    if (!expected[item]) exit(4);

let expected_count = length(keys(expected));
let actual_count = length(keys(actual));
if (expected_count != actual_count || !actual[required_extra]) exit(5);
print("DIRECT_EXPECTED_UNIQUE=" + expected_count + "\n");
print("DIRECT_MIGRATED_UNIQUE=" + actual_count + "\n");
print("DIRECT_REQUIRED_EXTRA_PRESERVED=true\n");
EOF_UCODE
    cat >"$WORK_DIR/prepare-direct-ruleset.uc" <<'EOF_UCODE'
let fs = require("fs");
let uci = require("uci");
let cfg = json(fs.readfile(ARGV[0]));
let catalog = {};
for (let line in split(fs.readfile(ARGV[1]), "\n")) {
    line = trim(line);
    if (line != "") catalog[line] = true;
}
if (length(keys(catalog)) != 724) exit(10);
let original = {};
for (let line in split(fs.readfile(ARGV[2]), "\n")) {
    line = trim(line);
    if (line != "") original[line] = true;
}
let extras = [];
for (let item in original) if (!catalog[item]) push(extras, item);
let refs = {};
let direct = null;
for (let sec in (cfg.section || []))
    if (sec[".name"] == "DIRECT") direct = sec;
if (!direct || direct.action != "bypass") exit(11);
for (let key in ["condition_refs", "conditions"]) {
    let v = direct[key] || [];
    if (type(v) != "array") v = split(v, /[ \t\r\n]+/);
    for (let ref in v) refs[ref] = true;
}
function reshape(sec) {
    for (let key in ["domain", "domain_suffix", "user_domains", "user_domains_text"])
        delete sec[key];
    sec.domain_ip_lists = [ARGV[3]];
    if (length(extras)) sec.domain = extras;
}
reshape(direct);
for (let cond in (cfg.condition || [])) if (refs[cond[".name"]]) reshape(cond);
// Prove membership of every original entry in catalog + local exceptions.
let effective = {};
for (let item in catalog) effective[item] = true;
for (let item in extras) effective[item] = true;
for (let item in original) if (!effective[item]) exit(12);
let c = uci.cursor(ARGV[4]);
function save(sec, typ) {
    let name = sec[".name"] || "settings";
    c.set("tachyon", name, typ);
    for (let key, value in sec) {
        if (substr(key, 0, 1) == "." || value == null) continue;
        if (!c.set("tachyon", name, key, value)) exit(13);
    }
}
for (let typ, sections in cfg) {
    if (typ == "settings" && type(sections) == "object") save(sections, typ);
    else if (type(sections) == "array") for (let sec in sections) save(sec, typ);
}
if (!c.commit("tachyon")) exit(14);
if (c.get("tachyon", "DIRECT", "domain_ip_lists")[0] != ARGV[3]) exit(15);
let stored = c.get("tachyon", "DIRECT", "domain") || [];
if (type(stored) != "array") stored = [stored];
for (let item in extras) if (index(stored, item) < 0) exit(16);
fs.writefile(ARGV[0], sprintf("%J", cfg));
print("DIRECT_RULESET_CATALOG_UNIQUE=724\n");
print("DIRECT_LOCAL_EXCEPTIONS=" + length(extras) + "\n");
print("DIRECT_SOURCE_RULES_COVERED=" + length(keys(original)) + "\n");
EOF_UCODE
    chmod 0700 "$WORK_DIR"/*.uc
}

normalize_direct_config() {
    config_dir="$1"
    expected_file="$2"
    text="$(uci -c "$config_dir" -q get podkop.DIRECT.user_domains_text)" || return 1
    list_paths="$(uci -c "$config_dir" -q get podkop.DIRECT.local_domain_lists)" || return 1
    [ -n "$text" ] || { fail 'DIRECT user_domains_text is empty'; return 1; }
    [ -n "$list_paths" ] || { fail 'DIRECT local_domain_lists is missing'; return 1; }

    : >"$expected_file"
    printf '%s\n' "$text" | awk '{ for (i = 1; i <= NF; i++) print $i }' >>"$expected_file"
    for list_path in $list_paths; do
        [ -r "$list_path" ] || { fail "a DIRECT local list is unreadable: $list_path"; return 1; }
        awk '{ for (i = 1; i <= NF; i++) print $i }' "$list_path" >>"$expected_file"
    done

    # Plex is mandatory in the target policy, even if absent from Podkop.
    if ! grep -Fxq "$EXPECTED_DIRECT_EXTRA" "$expected_file"; then
        printf '%s\n' "$EXPECTED_DIRECT_EXTRA" >>"$expected_file"
        log 'PLEX_DIRECT_ADDED=true'
    fi

    total="$(wc -l <"$expected_file" | tr -d '[:space:]')"
    unique="$(sort -u "$expected_file" | wc -l | tr -d '[:space:]')"
    [ "$unique" -ge "$EXPECTED_DIRECT_TOTAL" ] || { fail "DIRECT unique rule count is $unique, expected at least $EXPECTED_DIRECT_TOTAL"; return 1; }
    [ "$total" -eq "$unique" ] || { fail 'duplicate DIRECT source rules require review'; return 1; }
    EXPECTED_DIRECT_TOTAL="$unique"
    grep -Fxq "$EXPECTED_DIRECT_EXTRA" "$expected_file" || { fail 'required manually-added DIRECT rule is missing'; return 1; }

    combined="$(cat "$expected_file")"
    uci -c "$config_dir" set "podkop.DIRECT.user_domains_text=$combined" || return 1
    uci -c "$config_dir" -q delete podkop.DIRECT.local_domain_lists || true
    uci -c "$config_dir" commit podkop || return 1
    if uci -c "$config_dir" -q show podkop | grep -q '\.local_domain_lists='; then
        fail 'local_domain_lists remains after normalization'
        return 1
    fi
}

semantic_preflight() {
    if [ -n "$SEMANTIC_FIXTURE" ]; then
        [ "${TACHYON_TEST_MODE:-0}" = 1 ] || { fail 'semantic fixture is allowed only with TACHYON_TEST_MODE=1'; return 1; }
        "$SEMANTIC_FIXTURE" || return 1
        mkdir -p "$WORK_DIR/preflight-config"
        cp /etc/config/podkop "$WORK_DIR/preflight-config/podkop" || return 1
        NORMALIZED_CONFIG_FILE="$WORK_DIR/preflight-config/podkop"
        log 'SEMANTIC_PREFLIGHT_OK=true'
        return 0
    fi

    backend="$WORK_DIR/tachyon_1.7.11.apk"
    engine_archive="$WORK_DIR/sing-box-extended-compressed-arm64.tar.gz"
    fetch_file "$TACHYON_BACKEND_URL" "$backend" || { fail 'could not download the pinned Tachyon backend'; return 1; }
    [ "$(sha256_value "$backend")" = "$TACHYON_BACKEND_SHA256" ] || { fail 'Tachyon backend SHA-256 mismatch'; return 1; }
    fetch_file "$ENGINE_ARCHIVE_URL" "$engine_archive" || { fail 'could not download the pinned extended-compressed archive'; return 1; }
    [ "$(sha256_value "$engine_archive")" = "$ENGINE_ARCHIVE_SHA256" ] || { fail 'extended-compressed SHA-256 mismatch'; return 1; }

    stage="$WORK_DIR/semantic"
    mkdir -p "$stage/config" "$stage/runtime" "$stage/section-cache" "$stage/rulesets" "$stage/subscriptions" "$stage/subscription-cache" || return 1
    cp /etc/config/podkop "$stage/config/podkop" || return 1
    chmod 0600 "$stage/config/podkop" || return 1
    normalize_direct_config "$stage/config" "$stage/expected-direct" || return 1
    NORMALIZED_CONFIG_FILE="$stage/config/podkop"

    apk --allow-untrusted extract --destination "$stage/runtime" "$backend" >/dev/null 2>&1 || { fail 'could not extract the pinned Tachyon backend'; return 1; }
    lib="$stage/runtime/usr/lib/tachyon"
    if [ ! -r "$lib/config/migration.uc" ] || [ ! -r "$lib/tachyon_core/generator.uc" ]; then
        fail 'staged Tachyon runtime is incomplete'
        return 1
    fi
    write_semantic_helpers || return 1
    ucode "$WORK_DIR/export-uci-model.uc" "$stage/config" podkop >"$stage/source-model.json" 2>"$stage/export.err" || { fail 'could not create the private UCI model'; return 1; }
    ucode -L "$lib" "$lib/config/migration.uc" migrate-fixture "$stage/source-model.json" podkop >"$stage/migration-result.json" 2>"$stage/migration.err" || { fail 'Tachyon rejected the private Podkop migration'; return 1; }
    ucode "$WORK_DIR/extract-migrated-config.uc" "$stage/migration-result.json" "$stage/migrated.json" || { fail 'could not extract the migrated model'; return 1; }
    ucode "$WORK_DIR/validate-direct-catalog.uc" "$stage/migrated.json" "$stage/expected-direct" "$EXPECTED_DIRECT_EXTRA" || { fail 'migrated DIRECT catalog differs from all 725 source rules'; return 1; }
    fetch_file "$CATALOG_URL" "$stage/r1.lst" || { fail 'could not stage the DIRECT catalog'; return 1; }
    [ "$(sha256_value "$stage/r1.lst")" = "$CATALOG_SHA256" ] || { fail 'DIRECT catalog hash mismatch'; return 1; }
    mkdir -p "$stage/final-config" || return 1
    : >"$stage/final-config/tachyon"
    ucode "$WORK_DIR/prepare-direct-ruleset.uc" "$stage/migrated.json" "$stage/r1.lst" \
        "$stage/expected-direct" "$CATALOG_URL" "$stage/final-config" || { fail 'DIRECT ruleset conversion failed'; return 1; }
    FINAL_CONFIG_FILE="$stage/final-config/tachyon"
    chmod 0600 "$FINAL_CONFIG_FILE" || return 1

    member="$(tar -tzf "$engine_archive" 2>/dev/null | awk -F/ '$NF == "sing-box" { print; exit }')"
    [ -n "$member" ] || { fail 'pinned engine archive has no sing-box binary'; return 1; }
    tar -xOzf "$engine_archive" "$member" >"$stage/sing-box" 2>"$stage/engine-extract.err" || return 1
    chmod 0700 "$stage/sing-box" || return 1
    "$stage/sing-box" version 2>/dev/null | grep -q '1.14.3' || { fail 'pinned engine binary version check failed'; return 1; }
    engine_bytes="$(wc -c <"$stage/sing-box" | tr -d '[:space:]')"
    archive_bytes="$(wc -c <"$engine_archive" | tr -d '[:space:]')"
    backend_bytes="$(wc -c <"$backend" | tr -d '[:space:]')"
    case "$engine_bytes:$archive_bytes:$backend_bytes" in
        *[!0-9:]*|:*|*::*|*:) fail 'could not measure the verified staged assets'; return 1 ;;
    esac
    MEASURED_ENGINE_INSTALLED_KB=$(((engine_bytes + 1023) / 1024))
    STAGED_DOWNLOAD_KB=$(((archive_bytes + backend_bytes + 1023) / 1024))
    [ "$MEASURED_ENGINE_INSTALLED_KB" -gt 0 ] || { fail 'measured engine size is zero'; return 1; }
    printf '%s\n' extended-compressed >"$stage/sing-box-variant" || return 1

    # Tachyon's generator has version-gated schemas. Point its official
    # preflight hook at the exact future binary instead of letting it inspect
    # the currently installed Podkop sing-box or stale Tachyon version/variant
    # caches. Keep all detection state inside the private work directory so
    # --preflight remains non-mutating outside /tmp.
    TMP_SUBSCRIPTION_FOLDER="$stage/subscriptions" \
    TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$stage/subscription-cache" \
    SB_PREFLIGHT_BINARY="$stage/sing-box" \
    SB_VERSION_STATE_FILE="$stage/sing-box-version" \
    SB_VARIANT_STATE_FILE="$stage/sing-box-variant" \
    TACHYON_UI_SING_BOX_VERSION_CACHE_FILE="$stage/sing-box-version.ui" \
        ucode -L "$lib" "$lib/tachyon_core/generator.uc" generate-config-fixture \
        "$stage/migrated.json" "$stage/generated.json" 127.0.0.1 0 1 \
        >"$stage/generator.out" 2>"$stage/generator.err" || { fail 'Tachyon generator rejected the migrated private model'; return 1; }

    "$stage/sing-box" -c "$stage/generated.json" check >"$stage/engine-check.out" 2>"$stage/engine-check.err" || { fail 'pinned extended-compressed rejected the generated production model'; return 1; }
    run_audit || return 1
    log 'SEMANTIC_PREFLIGHT_OK=true'
    log "DIRECT_RULES_PRESERVED=$EXPECTED_DIRECT_TOTAL"
    log 'PINNED_ENGINE_CONFIG_CHECK=true'
    log "ENGINE_INSTALLED_KB_MEASURED=$MEASURED_ENGINE_INSTALLED_KB"
    log "STAGED_DOWNLOAD_KB_MEASURED=$STAGED_DOWNLOAD_KB"
    log 'DOWNLOAD_CAPACITY_SOURCE=conservative-release-estimate'
}

patch_installer_first_start() {
    installer="$1"
    needle="    restore_service_intent || fail \"Could not restore Tachyon service state\""
    [ "$(grep -Fxc "$needle" "$installer")" -eq 1 ] || { fail 'verified installer first-start hook has unexpected structure'; return 1; }
    sed -i 's#^    restore_service_intent || fail "Could not restore Tachyon service state"$#    msg "Tachyon first start deferred until the pinned engine is installed"#' "$installer" || return 1
    ! grep -Fqx "$needle" "$installer" || { fail 'could not defer Tachyon first start'; return 1; }
    grep -Fqx '    msg "Tachyon first start deferred until the pinned engine is installed"' "$installer" || return 1
}

service_enabled() {
    [ -x "/etc/init.d/$1" ] && "/etc/init.d/$1" enabled >/dev/null 2>&1
}

service_running() {
    [ -x "/etc/init.d/$1" ] && "/etc/init.d/$1" status >/dev/null 2>&1
}

create_snapshot() {
    WORK_DIR="$WORK_ROOT/tachyon-migration.$$"
    SNAPSHOT_FILE="$WORK_DIR/pre-migration.tar.gz"
    (umask 077 && mkdir "$WORK_DIR") || return 1

    service_enabled podkop && podkop_enabled=1 || podkop_enabled=0
    service_running podkop && podkop_running=1 || podkop_running=0
    service_enabled sing-box && singbox_enabled=1 || singbox_enabled=0
    service_running sing-box && singbox_running=1 || singbox_running=0
    service_running AdGuardHome && adguard_running=1 || adguard_running=0
    cat >"$WORK_DIR/service-state" <<EOF
PODKOP_ENABLED=$podkop_enabled
PODKOP_RUNNING=$podkop_running
SINGBOX_ENABLED=$singbox_enabled
SINGBOX_RUNNING=$singbox_running
ADGUARD_RUNNING=$adguard_running
EOF

    paths="etc/apk/world etc/config/podkop"
    for path in etc/config/sing-box etc/config/dhcp etc/config/firewall etc/config/network etc/AdGuardHome.yaml etc/sing-box; do
        [ -e "/$path" ] && paths="$paths $path"
    done
    # shellcheck disable=SC2086
    tar -C / -czf "$SNAPSHOT_FILE" $paths || return 1
    awk '
        /^P:/ { package = substr($0, 3); next }
        /^V:/ && package != "" { print package "\t" substr($0, 3); package = "" }
    ' /lib/apk/db/installed | sort >"$WORK_DIR/packages.before" || return 1
    chmod 0600 "$SNAPSHOT_FILE" "$WORK_DIR/service-state" 2>/dev/null || true
    tar -tzf "$SNAPSHOT_FILE" >/dev/null 2>&1 || return 1
}

read_state() {
    key="$1"
    sed -n "s/^$key=//p" "$WORK_DIR/service-state" | head -n 1
}

set_service_intent() {
    service="$1"
    enabled="$2"
    running="$3"
    [ -x "/etc/init.d/$service" ] || return 0
    if [ "$enabled" = 1 ]; then "/etc/init.d/$service" enable >/dev/null 2>&1 || true
    else "/etc/init.d/$service" disable >/dev/null 2>&1 || true
    fi
    if [ "$running" = 1 ]; then "/etc/init.d/$service" restart >/dev/null 2>&1 || "/etc/init.d/$service" start >/dev/null 2>&1 || true
    else "/etc/init.d/$service" stop >/dev/null 2>&1 || true
    fi
}

clear_stale_tachyon_autostart() {
    # A previous failed/rolled-back install can leave either the package hook's
    # restart marker or an rc.d link behind even though the Tachyon package is
    # absent. Tachyon 1.7.11 postinst interprets either as authority to start.
    # That start can auto-install tachyon-core while apk is still removing the
    # legacy sing-box package, racing the pinned component transaction.
    ! is_installed tachyon || { fail 'cannot clear pre-install Tachyon state after the package is installed'; return 1; }
    rm -f /tmp/tachyon-package-was-running \
        /etc/rc.d/S??tachyon /etc/rc.d/K??tachyon \
        /etc/rc.d/S??tachyon-core /etc/rc.d/K??tachyon-core 2>/dev/null || return 1
}

quiesce_for_pinned_engine() {
    # The verified upstream installer has returned, but package hooks may have
    # observed stale service intent. Stop every possible core owner before
    # replacing the packaged binary layout.
    for service in tachyon tachyon-core sing-box; do
        [ -x "/etc/init.d/$service" ] || continue
        "/etc/init.d/$service" stop >/dev/null 2>&1 || true
        "/etc/init.d/$service" disable >/dev/null 2>&1 || true
    done

    limit=10
    while [ "$limit" -gt 0 ] && pidof sing-box tachyon-core >/dev/null 2>&1; do
        sleep 1
        limit=$((limit - 1))
    done
    if pidof sing-box tachyon-core >/dev/null 2>&1; then
        fail 'an engine process is still running after services were stopped'
        return 1
    fi

    # Remove both ends, not merely the legacy link. A failed concurrent
    # tachyon-core install can leave tachyon-core -> sing-box together with
    # sing-box -> tachyon-core. The pinned component action then starts from a
    # deterministic empty binary layout and removes the registered package.
    rm -f /usr/bin/tachyon-core /usr/bin/sing-box 2>/dev/null || return 1
    if [ -e /usr/bin/tachyon-core ] || [ -L /usr/bin/tachyon-core ]; then
        fail 'tachyon-core binary path could not be cleared'
        return 1
    fi
    if [ -e /usr/bin/sing-box ] || [ -L /usr/bin/sing-box ]; then
        fail 'sing-box compatibility path could not be cleared'
        return 1
    fi
}

rollback() {
    ROLLBACK_ATTEMPTED=1
    warn 'Apply failed; starting automatic Podkop rollback'
    if [ -x /etc/init.d/tachyon ]; then
        /etc/init.d/tachyon stop >/dev/null 2>&1 || true
    fi

    apk del luci-i18n-tachyon-ru luci-app-tachyon tachyon tachyon-core >/dev/null 2>&1 || true
    rm -f /usr/bin/sing-box /usr/bin/tachyon-core /usr/lib/libcronet.so 2>/dev/null || true
    rm -f /etc/config/tachyon 2>/dev/null || true
    rm -f /tmp/tachyon-package-was-running \
        /etc/rc.d/S??tachyon /etc/rc.d/K??tachyon \
        /etc/rc.d/S??tachyon-core /etc/rc.d/K??tachyon-core \
        /etc/tachyon/tachyon-core-variant /etc/tachyon/tachyon-core-version \
        /etc/tachyon/sing-box-variant /etc/tachyon/sing-box-version 2>/dev/null || true

    old_sing="$(find_one 'sing-box-1.12.17-r1.apk')" || return 1
    old_core="$(find_one 'podkop-0.7.22-r1.apk')" || return 1
    old_luci="$(find_one 'luci-app-podkop-0.7.22-r1.apk')" || return 1
    old_i18n="$(find_one 'luci-i18n-podkop-ru-0.7.22.apk')" || return 1
    apk add --allow-untrusted --force-overwrite "$old_sing" "$old_core" "$old_luci" "$old_i18n" || return 1

    [ -s "$SNAPSHOT_FILE" ] || return 1
    tar -C / -xzf "$SNAPSHOT_FILE" || return 1
    awk '
        /^P:/ { package = substr($0, 3); next }
        /^V:/ && package != "" { print package "\t" substr($0, 3); package = "" }
    ' /lib/apk/db/installed | sort >"$WORK_DIR/packages.rollback-current" || return 1
    extras="$(awk 'NR == FNR { before[$1] = 1; next } !($1 in before) { print $1 }' "$WORK_DIR/packages.before" "$WORK_DIR/packages.rollback-current" | tr '\n' ' ')"
    if [ -n "$extras" ]; then
        # shellcheck disable=SC2086
        apk del $extras >/dev/null 2>&1 || return 1
    fi
    awk '
        /^P:/ { package = substr($0, 3); next }
        /^V:/ && package != "" { print package "\t" substr($0, 3); package = "" }
    ' /lib/apk/db/installed | sort >"$WORK_DIR/packages.after-rollback" || return 1
    cmp -s "$WORK_DIR/packages.before" "$WORK_DIR/packages.after-rollback" || return 1
    set_service_intent sing-box "$(read_state SINGBOX_ENABLED)" "$(read_state SINGBOX_RUNNING)"
    if [ "$(read_state PODKOP_ENABLED)" = 1 ]; then /etc/init.d/podkop enable >/dev/null 2>&1 || true
    else /etc/init.d/podkop disable >/dev/null 2>&1 || true
    fi
    # Podkop's status command can report "not running" while its generated
    # sing-box and nftables state are active.  Rebuild that state explicitly.
    /etc/init.d/podkop restart >/dev/null 2>&1 || /etc/init.d/podkop start >/dev/null 2>&1 || return 1

    is_installed podkop || return 1
    is_installed sing-box || return 1
    [ -s /etc/config/podkop ] || return 1
    log 'ROLLBACK_OK=true'
}

tachyon_running() {
    /usr/bin/tachyon get_status 2>/dev/null | grep -Eq '"running"[[:space:]]*:[[:space:]]*(1|true)'
}

postcheck() {
    is_installed tachyon || fail 'tachyon package is not registered' || return 1
    is_installed luci-app-tachyon || fail 'luci-app-tachyon package is not registered' || return 1
    is_installed luci-i18n-tachyon-ru || fail 'Russian Tachyon translation is not registered' || return 1
    ! is_installed podkop || fail 'legacy Podkop package is still installed' || return 1
    ! is_installed luci-i18n-podkop-ru || fail 'legacy Podkop translation is still installed' || return 1
    [ -s /etc/config/tachyon ] || fail 'migrated /etc/config/tachyon is missing' || return 1
    if [ -n "$FINAL_CONFIG_FILE" ]; then
        uci -q get tachyon.DIRECT.domain_ip_lists | grep -Fxq "$CATALOG_URL" || { fail 'DIRECT catalog reference is missing'; return 1; }
        uci -q get tachyon.DIRECT.domain | tr ' ' '\n' | grep -Fxq plex.tv || { fail 'mandatory Plex DIRECT rule is missing'; return 1; }
    fi
    [ -x /usr/bin/tachyon-core ] || fail 'pinned engine binary is missing' || return 1
    [ -L /usr/bin/sing-box ] || fail 'legacy sing-box compatibility link is missing' || return 1
    [ "$(readlink /usr/bin/sing-box 2>/dev/null)" = /usr/bin/tachyon-core ] || fail 'sing-box link has an unexpected target' || return 1
    /usr/bin/tachyon-core version 2>/dev/null | grep -q '1.14.3' || fail 'engine version is not the pinned 1.14.3 build' || return 1
    /usr/bin/tachyon start >/dev/null 2>&1 || fail 'Tachyon start failed' || return 1
    limit=60
    while [ "$limit" -gt 0 ]; do
        tachyon_running && break
        sleep 2
        limit=$((limit - 2))
    done
    tachyon_running || fail 'Tachyon did not report running state' || return 1
    if [ "$(read_state ADGUARD_RUNNING)" = 1 ]; then
        service_running AdGuardHome || fail 'AdGuardHome was running before migration but is not running now' || return 1
    fi
}

apply_transaction() {
    detect_fetcher || return 1
    create_snapshot || { fail 'could not create and validate the fresh tmpfs snapshot'; return 1; }
    installer="$WORK_DIR/tachyon-install-1.7.11.sh"
    if [ -n "$INSTALLER_FIXTURE" ]; then
        [ "${TACHYON_TEST_MODE:-0}" = 1 ] || { fail 'installer fixture is allowed only with TACHYON_TEST_MODE=1'; return 1; }
        cp "$INSTALLER_FIXTURE" "$installer" || return 1
    else
        fetch_file "$TACHYON_INSTALLER_URL" "$installer" || { fail 'could not download the pinned Tachyon installer'; return 1; }
    fi
    actual="$(sha256_value "$installer")"
    [ "$actual" = "$TACHYON_INSTALLER_SHA256" ] || { fail "installer SHA-256 mismatch: $actual"; return 1; }
    semantic_preflight || return 1
    patch_installer_first_start "$installer" || return 1

    APPLY_STARTED=1
    cp "$NORMALIZED_CONFIG_FILE" /etc/config/podkop || { fail 'could not install the preflighted normalized Podkop config'; return 1; }
    chmod 0600 /etc/config/podkop || return 1

    # Upstream 1.7.11 does not include the predecessor translation in its legacy
    # cleanup list. Removing it first prevents it retaining Podkop through
    # dependencies; rollback has the exact APK required to restore it.
    apk del luci-i18n-podkop-ru >/dev/null 2>&1 || { fail 'could not release the Podkop translation package'; return 1; }
    clear_stale_tachyon_autostart || return 1
    LANG=ru_RU.UTF-8 ash "$installer" --yes --tag "$TACHYON_TAG" --engine none --no-zram || { fail 'Tachyon package/config migration failed'; return 1; }
    ! is_installed tachyon-core || { fail 'unpinned tachyon-core was installed before the pinned engine'; return 1; }
    quiesce_for_pinned_engine || return 1
    if [ -n "$FINAL_CONFIG_FILE" ]; then
        cp "$FINAL_CONFIG_FILE" /etc/config/tachyon || return 1
        chmod 0600 /etc/config/tachyon || return 1
    fi
    /usr/bin/tachyon component_action sing-box-extended-compressed install_version "$ENGINE_TAG" || { fail 'pinned extended-compressed installation failed'; return 1; }
    uci set tachyon.settings.engine='sing-box' || return 1
    uci commit tachyon || return 1
    /etc/init.d/tachyon enable >/dev/null 2>&1 || true
    postcheck || return 1
    rm -rf "$WORK_DIR/semantic" "$WORK_DIR/preflight-config" 2>/dev/null || true
    log 'MIGRATION_OK=true'
    log "RECOVERY_SNAPSHOT=$SNAPSHOT_FILE"
}

run_semantic_preflight_only() {
    detect_fetcher || return 1
    WORK_DIR="$WORK_ROOT/tachyon-preflight.$$"
    (umask 077 && mkdir "$WORK_DIR") || return 1
    if semantic_preflight; then
        rm -rf "$WORK_DIR" 2>/dev/null || true
        log 'PREFLIGHT_OK=true'
        log 'SYSTEM_MUTATED=false'
        return 0
    fi
    warn "Private preflight diagnostics retained in $WORK_DIR"
    return 1
}

confirm=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --plan) [ -z "$MODE" ] || { usage >&2; exit 2; }; MODE=plan ;;
        --preflight) [ -z "$MODE" ] || { usage >&2; exit 2; }; MODE=preflight ;;
        --apply) [ -z "$MODE" ] || { usage >&2; exit 2; }; MODE=apply ;;
        --confirm) shift; [ "$#" -gt 0 ] || { usage >&2; exit 2; }; confirm="$1" ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

[ -n "$MODE" ] || { usage >&2; exit 2; }
if [ "$MODE" = apply ] && [ "$confirm" != MIGRATE-PODKOP-TO-TACHYON ]; then
    printf 'ERROR: Apply requires --confirm MIGRATE-PODKOP-TO-TACHYON\n' >&2
    exit 2
fi

preflight || exit 1
if [ "$MODE" = plan ]; then
    print_plan
    exit 0
fi
if [ "$MODE" = preflight ]; then
    run_semantic_preflight_only
    exit $?
fi

if apply_transaction; then
    exit 0
fi

if [ "$APPLY_STARTED" -eq 1 ] && [ "$ROLLBACK_ATTEMPTED" -eq 0 ]; then
    if rollback; then
        exit 1
    fi
    printf 'ROLLBACK_OK=false\n' >&2
    printf 'EMERGENCY_BUNDLE=%s\n' "$ROLLBACK_DIR" >&2
    exit 2
fi
exit 1
