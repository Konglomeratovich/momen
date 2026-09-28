#!/usr/bin/env python3
"""Build deterministic HAPP routing artifacts from the reviewed policy."""

from __future__ import annotations

import base64
import hashlib
import ipaddress
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parent
POLICY_PATH = ROOT / "policy.json"
DOMAIN_PATH = ROOT / "data" / "momen-direct"
ARTIFACTS = ROOT / "artifacts"


def load_policy() -> dict:
    policy = json.loads(POLICY_PATH.read_text(encoding="utf-8"))
    required = {
        "name",
        "direct_sites",
        "direct_ip",
        "proxy_sites",
        "proxy_ip",
        "block_sites",
        "block_ip",
        "remote_dns",
        "domestic_dns",
        "geoip_url",
        "geosite_url",
        "domain_strategy",
        "fake_dns",
    }
    missing = sorted(required - policy.keys())
    if missing:
        raise ValueError(f"policy is missing keys: {', '.join(missing)}")
    return policy


def validate(policy: dict) -> int:
    domains = [line.strip() for line in DOMAIN_PATH.read_text(encoding="utf-8").splitlines() if line.strip()]
    if len(domains) != 724 or len(set(domains)) != 724:
        raise ValueError("momen-direct must contain exactly 724 unique domains")
    if any(not item.startswith("domain:") for item in domains):
        raise ValueError("momen-direct accepts domain: entries only")

    for field in ("direct_sites", "proxy_sites", "block_sites"):
        for item in policy[field]:
            if not item.startswith("geosite:"):
                raise ValueError(f"{field} contains a non-geosite entry: {item}")

    for field in ("direct_ip", "proxy_ip", "block_ip"):
        for item in policy[field]:
            if item.startswith("geoip:"):
                continue
            ipaddress.ip_network(item, strict=False)

    if policy["geosite_url"] != "https://github.com/Konglomeratovich/momen/releases/latest/download/momen-geosite.dat":
        raise ValueError("unexpected geosite release URL")
    return len(domains)


def make_profile(policy: dict) -> dict:
    return {
        "Name": policy["name"],
        "GlobalProxy": "false",
        "RemoteDNSType": policy["remote_dns"]["type"],
        "RemoteDNSDomain": policy["remote_dns"]["domain"],
        "RemoteDNSIP": policy["remote_dns"]["ip"],
        "DomesticDNSType": policy["domestic_dns"]["type"],
        "DomesticDNSDomain": policy["domestic_dns"]["domain"],
        "DomesticDNSIP": policy["domestic_dns"]["ip"],
        "Geoipurl": policy["geoip_url"],
        "Geositeurl": policy["geosite_url"],
        "DnsHosts": {
            "common.dot.dns.yandex.net": policy["domestic_dns"]["ip"],
        },
        "DirectSites": policy["direct_sites"],
        "DirectIp": policy["direct_ip"],
        "ProxySites": policy["proxy_sites"],
        "ProxyIp": policy["proxy_ip"],
        "BlockSites": policy["block_sites"],
        "BlockIp": policy["block_ip"],
        "DomainStrategy": policy["domain_strategy"],
        "FakeDNS": "true" if policy["fake_dns"] else "false",
    }


def write_artifacts(profile: dict, domain_count: int) -> None:
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    compact = json.dumps(profile, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    pretty = json.dumps(profile, ensure_ascii=False, indent=2).encode("utf-8") + b"\n"
    link = "happ://routing/onadd/" + base64.b64encode(compact).decode("ascii")

    profile_path = ARTIFACTS / "happ-routing.json"
    link_path = ARTIFACTS / "happ-routing-link.txt"
    profile_path.write_bytes(pretty)
    link_path.write_text(link + "\n", encoding="utf-8", newline="\n")

    manifest = {
        "schema_version": 1,
        "policy": profile["Name"],
        "direct_domain_count": domain_count,
        "direct_site_rule_count": len(profile["DirectSites"]),
        "direct_ip_rule_count": len(profile["DirectIp"]),
        "proxy_site_rule_count": len(profile["ProxySites"]),
        "proxy_ip_rule_count": len(profile["ProxyIp"]),
        "profile_sha256": hashlib.sha256(pretty).hexdigest(),
        "link_sha256": hashlib.sha256((link + "\n").encode("utf-8")).hexdigest(),
    }
    (ARTIFACTS / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )


def main() -> None:
    policy = load_policy()
    count = validate(policy)
    profile = make_profile(policy)
    write_artifacts(profile, count)
    print(f"DIRECT_DOMAINS={count}")
    print(f"DIRECT_SITES={len(profile['DirectSites'])}")
    print(f"PROXY_SITES={len(profile['ProxySites'])}")
    print(f"PROXY_IP={len(profile['ProxyIp'])}")
    print("HAPP_ARTIFACTS_READY=true")


if __name__ == "__main__":
    main()
