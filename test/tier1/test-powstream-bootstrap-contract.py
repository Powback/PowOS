#!/usr/bin/env python3
"""PowStream bootstrap client: trust/secret invariants that a JVM test cannot see (source-level)."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / 'targets/android/app/engine/src/main/java/andro/marchy/stream/PowStreamBootstrap.java'


class BootstrapContract(unittest.TestCase):
    def setUp(self):
        self.src = SRC.read_text()
        # Code only: comments may name what is forbidden.
        self.code = re.sub(r'(?m)(^|\s)//[^\n]*', '', re.sub(r'/\*.*?\*/', '', self.src, flags=re.S))

    def test_platform_trust_only(self):
        for banned in ('TrustManager', 'HostnameVerifier', 'setSSLSocketFactory', 'setDefaultSSLSocketFactory',
                       'SSLContext', 'X509', 'ALLOW_ALL', 'NO_AUTH', 'http://'):
            self.assertNotIn(banned, self.code, banned)
        self.assertIn('setInstanceFollowRedirects(false)', self.code)
        self.assertIn('setUseCaches(false)', self.code)
        self.assertIn('"https".equals(u.getScheme())', self.code)

    def test_endpoint_host_is_the_verified_origin(self):
        self.assertIn('parse(body, origin.getHost(),', self.code)
        self.assertIn('"https://" + host + ":" + port + "/b0"', self.code)

    def test_secrets_never_logged_or_stored(self):
        for banned in ('android.util.Log', 'Log.', 'System.out', 'System.err', 'printStackTrace',
                       'SharedPreferences', 'FileOutputStream', 'getMessage()'):
            self.assertNotIn(banned, self.code, banned)
        self.assertIn('token redacted', self.code)
        self.assertIn('Arrays.fill(certSha256, (byte) 0)', self.code)

    def test_no_fake_mode(self):
        lowered = self.code.lower()
        for banned in ('mock', 'fake', 'demo', 'debug'):
            self.assertNotIn(banned, lowered, banned)

    def test_contract_is_documented(self):
        doc = (ROOT / 'docs/REMOTE-WINDOWS.md').read_text()
        self.assertIn('### Bootstrap contract', doc)
        self.assertIn('PowStreamBootstrap', doc)


if __name__ == '__main__':
    unittest.main()
