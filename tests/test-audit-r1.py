from __future__ import annotations

import gzip
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools" / "audit-r1.py"


class AuditR1Tests(unittest.TestCase):
    def test_real_catalog_builds_exact_plain_list_offline(self) -> None:
        with tempfile.TemporaryDirectory(dir=ROOT) as temporary:
            output = Path(temporary) / "r1.lst"
            completed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--archive",
                    str(ROOT / "assets" / "r1.gz"),
                    "--community-source",
                    str(ROOT / "happ" / "data" / "momen-direct"),
                    "--write-lst",
                    str(output),
                    "--no-dns",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            report = json.loads(completed.stdout)
            self.assertTrue(report["sources_equal"])
            self.assertEqual(report["structure"]["count"], 724)
            with gzip.open(ROOT / "assets" / "r1.gz", "rt", encoding="utf-8") as stream:
                expected = stream.read().replace("\r\n", "\n")
            self.assertEqual(output.read_text(encoding="utf-8"), expected)

    def test_invalid_or_divergent_catalog_is_rejected_without_output(self) -> None:
        with tempfile.TemporaryDirectory(dir=ROOT) as temporary:
            fixture = Path(temporary)
            archive = fixture / "r1.gz"
            community = fixture / "momen-direct"
            output = fixture / "r1.lst"
            with gzip.open(archive, "wt", encoding="utf-8", newline="\n") as stream:
                stream.write("example.com\nexample.com\n")
            community.write_text("domain:example.com\n", encoding="utf-8", newline="\n")

            completed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--archive",
                    str(archive),
                    "--community-source",
                    str(community),
                    "--write-lst",
                    str(output),
                    "--no-dns",
                ],
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(completed.returncode, 1, completed.stderr)
            report = json.loads(completed.stdout)
            self.assertFalse(report["sources_equal"])
            self.assertEqual(report["structure"]["duplicates"], ["example.com"])
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
