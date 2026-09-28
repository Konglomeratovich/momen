import base64
import json
import unittest
from pathlib import Path

from happ import build


class HappRoutingBuildTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        build.main()
        cls.profile = json.loads((build.ARTIFACTS / "happ-routing.json").read_text(encoding="utf-8"))
        cls.link = (build.ARTIFACTS / "happ-routing-link.txt").read_text(encoding="utf-8").strip()

    def test_policy_has_expected_shape(self):
        self.assertEqual(self.profile["GlobalProxy"], "false")
        self.assertIn("geosite:momen-direct", self.profile["DirectSites"])
        self.assertIn("geoip:ru", self.profile["DirectIp"])
        self.assertEqual(len(self.profile["ProxySites"]), 16)
        self.assertEqual(len(self.profile["ProxyIp"]), 61)

    def test_deeplink_decodes_to_the_profile(self):
        prefix = "happ://routing/onadd/"
        self.assertTrue(self.link.startswith(prefix))
        decoded = json.loads(base64.b64decode(self.link[len(prefix):]).decode("utf-8"))
        self.assertEqual(decoded, self.profile)

    def test_artifacts_contain_no_proxy_credentials(self):
        payload = json.dumps(self.profile) + self.link
        for marker in ("vless://", "mierus://", "naive+https://", "password"):
            self.assertNotIn(marker, payload.lower())


if __name__ == "__main__":
    unittest.main()
