#!/usr/bin/env python3
"""Verify that the compiled geosite category preserves source-domain semantics."""

from __future__ import annotations

import json
import sys
from pathlib import Path


def load_source(path: Path) -> list[str]:
    result = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line:
            if not line.startswith("domain:"):
                raise ValueError(f"unsupported source entry: {line}")
            result.append(line.removeprefix("domain:"))
    return result


def load_export(path: Path) -> list[str]:
    result = []
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped.startswith("- "):
            continue
        value = json.loads(stripped[2:])
        if not value.startswith("domain:"):
            raise ValueError(f"unsupported compiled entry: {value}")
        result.append(value.removeprefix("domain:"))
    return result


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: verify_geosite.py SOURCE EXPORTED_YML")
    source = load_source(Path(sys.argv[1]))
    exported = load_export(Path(sys.argv[2]))
    if len(source) != 724 or len(set(source)) != 724:
        raise ValueError("source must contain exactly 724 unique domains")
    if not exported:
        raise ValueError("compiled category is empty")
    if any(item not in source for item in exported):
        raise ValueError("compiled category contains an unexpected domain")

    uncovered = [
        domain
        for domain in source
        if not any(domain == parent or domain.endswith("." + parent) for parent in exported)
    ]
    if uncovered:
        raise ValueError(f"compiled category does not cover {len(uncovered)} source domains")
    print(f"SOURCE_DOMAINS={len(source)}")
    print(f"COMPILED_DOMAINS={len(exported)}")
    print("GEOSITE_SEMANTIC_COVERAGE=true")


if __name__ == "__main__":
    main()
