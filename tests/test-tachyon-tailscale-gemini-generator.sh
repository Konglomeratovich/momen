#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
FIXTURE="$SCRIPT_DIR/fixtures/tachyon-tailscale-gemini.json"
SOURCE="${TACHYON_1711_SOURCE:?set TACHYON_1711_SOURCE to the exact Tachyon 1.7.11 checkout}"
CORE_BIN="${TACHYON_CORE_CHECK_BIN:?set TACHYON_CORE_CHECK_BIN to a local sing-box extended binary}"
EXPECTED_COMMIT="7a8843fbf9475374ce5fffce354b060fcb33b431"
WORK_DIR="$(mktemp -d)"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT INT TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ -f "$SOURCE/tachyon/files/usr/lib/tachyon_core/generator.uc" ] || fail 'Tachyon generator not found'
[ -x "$CORE_BIN" ] || fail 'local extended core binary is not executable'
if command -v git >/dev/null 2>&1; then
    actual_commit="$(git -C "$SOURCE" rev-parse HEAD)"
else
    actual_commit="${TACHYON_1711_COMMIT:?set TACHYON_1711_COMMIT when git is unavailable in the test container}"
fi
[ "$actual_commit" = "$EXPECTED_COMMIT" ] || fail "expected Tachyon 1.7.11 commit $EXPECTED_COMMIT, found $actual_commit"

TACHYON_LIB="$SOURCE/tachyon/files/usr/lib"
GENERATOR="$TACHYON_LIB/tachyon_core/generator.uc"
OUTPUT="$WORK_DIR/config.json"
export TACHYON_LIB
cat >"$WORK_DIR/tachyon" <<'EOF'
config settings 'settings'
    option engine 'sing-box'
config section 'GEMINI_TAILSCALE'
    option action 'tailscale'
    list community_lists 'google_ai'
EOF
planner="$TACHYON_LIB/service/config_plan.uc"
if ucode -L "$TACHYON_LIB" "$planner" validate "$WORK_DIR/tachyon" >"$WORK_DIR/planner-original.log" 2>&1; then
    fail 'expected the original 1.7.11 planner to reject tailscale'
fi
grep -Fq "unsupported action 'tailscale'" "$WORK_DIR/planner-original.log" || {
    cat "$WORK_DIR/planner-original.log"; fail 'did not reproduce the actual planner defect'
}
sed 's/connection: true, group: true, desync: true, direct: true,/connection: true, group: true, desync: true, direct: true, tailscale: true,/' \
    "$planner" >"$WORK_DIR/config_plan.uc"
ucode -L "$TACHYON_LIB" "$WORK_DIR/config_plan.uc" validate "$WORK_DIR/tachyon"
sed "s/option action 'tailscale'/option action 'unknown_action'/" "$WORK_DIR/tachyon" >"$WORK_DIR/bad"
if ucode -L "$TACHYON_LIB" "$WORK_DIR/config_plan.uc" validate "$WORK_DIR/bad" >"$WORK_DIR/planner-bad.log" 2>&1; then
    fail 'corrected planner accepted an unknown action'
fi
grep -Fq "unsupported action 'unknown_action'" "$WORK_DIR/planner-bad.log" || fail 'wrong rejection reason'
printf '%s\n' 'REAL_PLANNER_DEFECT_REPRODUCED=PASS' 'PRIVATE_PLANNER_POSITIVE_AND_NEGATIVE=PASS'
printf '%s\n' '1.14.3-extended-2.7.3' >"$WORK_DIR/version"
printf '%s\n' 'extended-compressed' >"$WORK_DIR/variant"
mkdir -p "$OUTPUT.section-cache" "$OUTPUT.rulesets" "$WORK_DIR/data"

SB_VERSION_STATE_FILE="$WORK_DIR/version" \
SB_VARIANT_STATE_FILE="$WORK_DIR/variant" \
ucode -L "$TACHYON_LIB" "$GENERATOR" \
    generate-config-fixture "$FIXTURE" "$OUTPUT" 127.0.0.1 0 1

ucode -e '
    let fs = require("fs");
    let cfg = json(fs.readfile(ARGV[0]));
    let endpoint = null;
    for (let item in (cfg.endpoints || []))
        if (item.tag == "GEMINI_TAILSCALE-out") endpoint = item;
    if (endpoint == null || endpoint.type != "tailscale") exit(10);
    if (endpoint.exit_node != "exit-node.example.test") exit(11);
    if (endpoint.exit_node_allow_lan_access != true) exit(12);
    if (endpoint.accept_routes != true) exit(13);
    if (endpoint.auth_key != "tskey-auth-fixture-only-not-secret") exit(14);
    let routed = false;
    for (let rule in ((cfg.route || {}).rules || [])) {
        let rendered = sprintf("%J", rule);
        if (index(rendered, "GEMINI_TAILSCALE-out") >= 0 &&
            index(rendered, "google_ai") >= 0)
            routed = true;
    }
    if (!routed) exit(15);
' "$OUTPUT"

"$CORE_BIN" check -D "$WORK_DIR/data" -c "$OUTPUT"
ucode -e '
    let fs = require("fs");
    let cfg = json(fs.readfile(ARGV[0]));
    for (let item in (cfg.endpoints || []))
        if (item.type == "tailscale") delete item.auth_key;
    fs.writefile(ARGV[1], sprintf("%J", cfg));
' "$OUTPUT" "$WORK_DIR/without-key.json"
"$CORE_BIN" check -D "$WORK_DIR/data" -c "$WORK_DIR/without-key.json"
printf '%s\n' 'AUTH_FREE_CORE_CONFIG_CHECK=PASS'
printf '%s\n' 'EXACT_TACHYON_1_7_11_GENERATOR=PASS' 'EXTENDED_CORE_CONFIG_CHECK=PASS'
