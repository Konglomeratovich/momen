#!/bin/ash
# shellcheck shell=dash
set -eu

APK_PATH="${1:-}"
[ -r "$APK_PATH" ] || {
    echo "Usage: $0 /path/to/forkop_1.0.5.apk" >&2
    exit 2
}

for command_name in apk grep jsonfilter mktemp uci ucode; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "missing command: $command_name" >&2
        exit 1
    }
done

work_dir="$(mktemp -d /tmp/momen-upstream-migration.XXXXXX)"
runtime_config_name="momen_forkop_test_$$"
cleanup() {
    rm -f "/etc/config/$runtime_config_name"
    rm -rf "$work_dir"
}
trap cleanup EXIT

apk adbdump "$APK_PATH" > "$work_dir/package.adb"
grep -Fq 'name: forkop' "$work_dir/package.adb"
grep -Fq 'version: 1.0.5' "$work_dir/package.adb"

mkdir "$work_dir/root"
apk --allow-untrusted extract --destination "$work_dir/root" "$APK_PATH" >/dev/null
forkop_lib="$work_dir/root/usr/lib/forkop"
migration="$forkop_lib/config/migration.uc"
[ -r "$migration" ]
grep -Fq 'migrate-podkop' "$migration"

cat > "$work_dir/podkop-fixture.json" <<'EOF'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_type": "doh",
    "dns_server": "common.dot.dns.yandex.net",
    "bootstrap_dns_server": "77.88.8.8",
    "download_lists_via_proxy": "1",
    "download_lists_via_proxy_section": "main"
  },
  "section": [
    {
      ".name": "main",
      ".type": "section",
      "connection_type": "proxy",
      "proxy_config_type": "url",
      "proxy_string": "vless://SECRET-MUST-NOT-LEAK@example.test"
    },
    {
      ".name": "DIRECT",
      ".type": "section",
      "connection_type": "exclusion",
      "managed_by": "vless-podkop-v3",
      "user_domain_list_type": "text",
      "user_domains_text": "example.ru ya.ru",
      "local_domain_lists": [ "/etc/momen-r1-cyrillic-tlds.lst" ]
    }
  ]
}
EOF

FORKOP_LIB="$forkop_lib" \
    ucode -L "$forkop_lib" "$migration" migrate-fixture "$work_dir/podkop-fixture.json" podkop \
    > "$work_dir/migrated.json"

[ "$(jsonfilter -i "$work_dir/migrated.json" -e '@.config.settings.dns_type')" = 'doh' ]
[ "$(jsonfilter -i "$work_dir/migrated.json" -e '@.config.settings.dns_server[0]')" = 'common.dot.dns.yandex.net' ]
[ "$(jsonfilter -i "$work_dir/migrated.json" -e '@.config.settings.bootstrap_dns_server[0]')" = '77.88.8.8' ]
[ "$(jsonfilter -i "$work_dir/migrated.json" -e '@.config.settings.download_lists_via_proxy')" = '1' ]
[ "$(jsonfilter -i "$work_dir/migrated.json" -e '@.config.settings.download_lists_via_proxy_section')" = 'main' ]
[ "$(jsonfilter -i "$work_dir/migrated.json" -e '@.config.section[0].action')" = 'connection' ]
[ "$(jsonfilter -i "$work_dir/migrated.json" -e '@.config.section[0].selector_proxy_links[0]')" = 'vless://SECRET-MUST-NOT-LEAK@example.test' ]
[ "$(jsonfilter -i "$work_dir/migrated.json" -e '@.config.section[1].action')" = 'bypass' ]
[ "$(jsonfilter -i "$work_dir/migrated.json" -e '@.config.section[1].managed_by')" = 'vless-podkop-v3' ]
[ "$(jsonfilter -i "$work_dir/migrated.json" -e '@.config.section[1].user_domains_text')" = 'example.ru ya.ru' ]
[ "$(jsonfilter -i "$work_dir/migrated.json" -e '@.config.section[1].local_domain_lists[0]')" = '/etc/momen-r1-cyrillic-tlds.lst' ]

cat > "/etc/config/$runtime_config_name" <<'EOF'
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
        option user_domains_text 'example.ru ya.ru'
        list local_domain_lists '/etc/momen-r1-cyrillic-tlds.lst'
EOF

FORKOP_CONFIG_NAME="$runtime_config_name" FORKOP_LIB="$forkop_lib" \
    ucode -L "$forkop_lib" "$migration" migrate-podkop

[ "$(uci -q get "$runtime_config_name.settings.dns_type")" = 'doh' ]
[ "$(uci -q get "$runtime_config_name.settings.dns_server")" = 'common.dot.dns.yandex.net' ]
[ "$(uci -q get "$runtime_config_name.settings.bootstrap_dns_server")" = '77.88.8.8' ]
[ "$(uci -q get "$runtime_config_name.main.action")" = 'connection' ]
[ "$(uci -q get "$runtime_config_name.DIRECT.action")" = 'bypass' ]
[ "$(uci -q get "$runtime_config_name.DIRECT.local_domain_lists")" = '/etc/momen-r1-cyrillic-tlds.lst' ]

echo 'UPSTREAM_FORKOP_MIGRATION=passed'
