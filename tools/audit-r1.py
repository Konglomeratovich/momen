#!/usr/bin/env python3
"""Validate the momen DIRECT catalog and optionally audit public DNS state.

DNS is deliberately treated as review evidence, not as an automatic deletion
signal. A domain-suffix rule can remain useful when the zone apex has no
address records, and CDN or defensive domains may intentionally behave that
way.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import gzip
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from dataclasses import asdict, dataclass
from pathlib import Path


DOMAIN_RE = re.compile(
    r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*"
    r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"
)
DEFAULT_DOH_URL = "https://dns.google/resolve"


@dataclass(frozen=True)
class DnsResult:
    domain: str
    state: str
    rcode: int | None
    attempts: int
    detail: str = ""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=Path, default=Path("assets/r1.gz"))
    parser.add_argument(
        "--community-source",
        type=Path,
        default=Path("happ/data/momen-direct"),
    )
    parser.add_argument("--write-lst", type=Path)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--no-dns", action="store_true")
    parser.add_argument("--doh-url", default=DEFAULT_DOH_URL)
    parser.add_argument("--workers", type=int, default=12)
    parser.add_argument("--timeout", type=float, default=8.0)
    parser.add_argument("--retries", type=int, default=2)
    return parser.parse_args()


def read_archive(path: Path) -> list[str]:
    with gzip.open(path, "rt", encoding="utf-8", newline=None) as stream:
        return [line.strip() for line in stream if line.strip()]


def read_community_source(path: Path) -> list[str]:
    result: list[str] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if not line.startswith("domain:"):
            raise ValueError(f"unsupported community entry: {line}")
        result.append(line.removeprefix("domain:"))
    return result


def structural_findings(domains: list[str]) -> dict[str, object]:
    invalid = [domain for domain in domains if not DOMAIN_RE.fullmatch(domain)]
    uppercase = [domain for domain in domains if domain != domain.lower()]
    duplicates = sorted(
        domain for domain, count in Counter(domains).items() if count > 1
    )
    return {
        "count": len(domains),
        "unique_count": len(set(domains)),
        "sorted": domains == sorted(domains),
        "invalid": invalid,
        "uppercase": uppercase,
        "duplicates": duplicates,
    }


def doh_query(
    domain: str,
    *,
    doh_url: str,
    timeout: float,
    retries: int,
) -> DnsResult:
    query_types = ("A", "AAAA", "MX", "NS")
    last_error = ""
    total_attempts = 0
    saw_noerror = False
    saw_nxdomain = False

    for query_type in query_types:
        for attempt in range(1, retries + 1):
            total_attempts += 1
            url = doh_url + "?" + urllib.parse.urlencode(
                {"name": domain, "type": query_type, "cd": "0", "do": "0"}
            )
            request = urllib.request.Request(
                url,
                headers={"Accept": "application/dns-json", "User-Agent": "momen-audit/1"},
            )
            try:
                with urllib.request.urlopen(request, timeout=timeout) as response:
                    payload = json.load(response)
                status = int(payload.get("Status", -1))
                answers = payload.get("Answer") or []
                if status == 0:
                    saw_noerror = True
                    if answers:
                        return DnsResult(domain, "answer", status, total_attempts)
                    break
                if status == 3:
                    saw_nxdomain = True
                    break
                last_error = f"rcode={status} type={query_type}"
                break
            except (OSError, ValueError, urllib.error.URLError) as exc:
                last_error = f"{type(exc).__name__}: {exc}"
                if attempt < retries:
                    time.sleep(0.2 * attempt)

        if saw_nxdomain:
            return DnsResult(domain, "nxdomain", 3, total_attempts)

    if saw_noerror:
        return DnsResult(domain, "no_answer", 0, total_attempts)
    return DnsResult(domain, "transport_error", None, total_attempts, last_error)


def audit_dns(domains: list[str], args: argparse.Namespace) -> list[DnsResult]:
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {
            pool.submit(
                doh_query,
                domain,
                doh_url=args.doh_url,
                timeout=args.timeout,
                retries=args.retries,
            ): domain
            for domain in domains
        }
        results = [future.result() for future in concurrent.futures.as_completed(futures)]
    return sorted(results, key=lambda item: item.domain)


def main() -> int:
    args = parse_args()
    domains = read_archive(args.archive)
    community_domains = read_community_source(args.community_source)
    structure = structural_findings(domains)
    sources_equal = domains == community_domains

    fatal = (
        structure["count"] != 724
        or structure["unique_count"] != 724
        or not structure["sorted"]
        or bool(structure["invalid"])
        or bool(structure["uppercase"])
        or bool(structure["duplicates"])
        or not sources_equal
    )

    dns_results: list[DnsResult] = []
    if not args.no_dns and not fatal:
        dns_results = audit_dns(domains, args)

    states = Counter(result.state for result in dns_results)
    report = {
        "schema": 1,
        "archive": str(args.archive),
        "community_source": str(args.community_source),
        "sources_equal": sources_equal,
        "structure": structure,
        "dns": {
            "performed": not args.no_dns and not fatal,
            "provider": args.doh_url,
            "counts": dict(sorted(states.items())),
            "review": [
                asdict(result)
                for result in dns_results
                if result.state != "answer"
            ],
        },
    }

    if args.write_lst and not fatal:
        args.write_lst.parent.mkdir(parents=True, exist_ok=True)
        args.write_lst.write_text("\n".join(domains) + "\n", encoding="utf-8", newline="\n")

    rendered = json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(rendered, encoding="utf-8", newline="\n")
    print(rendered, end="")
    return 1 if fatal else 0


if __name__ == "__main__":
    sys.exit(main())
