#!/usr/bin/env python3
"""Ownership/expiry using the real Java Lease; no device or Android build."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
ROOT = pathlib.Path(__file__).resolve().parents[2]
APP = ROOT / 'targets/android/verify-background/app'

class Companion(unittest.TestCase):
    def test_lease(self):
        with tempfile.TemporaryDirectory() as temp:
            p = pathlib.Path(temp)
            (p / 'Lease.java').write_text((APP / 'src/main/java/com/powos/verifybackground/Lease.java').read_text())
            (p / 'Check.java').write_text('''import com.powos.verifybackground.Lease;
public class Check {
 static void check(boolean b) { if (!b) throw new AssertionError(); }
 public static void main(String[] args) {
  Lease l = new Lease(); String n = "0123456789abcdef0123456789abcdef";
  check(!l.start(null, 0)); check(!l.start("bad", 0)); check(l.start(n, 100));
  check(!l.start(n, 101)); check(!l.start("abcdef0123456789abcdef0123456789", 102));
  check(l.nonce().equals(n)); check(l.deadline() == 90100);
  check(!l.expired(90099)); check(l.expired(90100)); check(l.expired(90101));
  check(!l.start(n, 100000));
 }
}''')
            build = 'javac -d . Lease.java Check.java && java Check'
            # A host JDK when there is one (CI's runner has one, but not the image: --pull=never failed there with
            # errors=1, 11-13); else the JDK image, pulled if missing (the tier1 container has docker, no java).
            if shutil.which('javac') and shutil.which('java'):
                subprocess.run(['sh', '-c', build], cwd=temp, check=True)
            else:
                subprocess.run(['docker', 'run', '--rm', '--network=none', '-v', f'{temp}:/work', '-w', '/work',
                                'eclipse-temurin:17-jdk-jammy', 'sh', '-c', build], check=True)

    def test_contract(self):
        root = ET.parse(APP / 'src/main/AndroidManifest.xml').getroot()
        name = '{http://schemas.android.com/apk/res/android}name'
        permissions = {p.attrib[name] for p in root.findall('uses-permission')}
        self.assertEqual(permissions, {'android.permission.FOREGROUND_SERVICE', 'android.permission.FOREGROUND_SERVICE_SPECIAL_USE'})
        service = root.find('application/service')
        self.assertEqual(service.attrib['{http://schemas.android.com/apk/res/android}exported'], 'false')
        script = (ROOT / 'tools/phone/verify/switcher-owned-bg.sh').read_text()
        self.assertIn('$nonce $owned_pid ', script)
        self.assertNotIn('force-stop com.termux', script)
        self.assertNotIn('tasks.remove', script)
        self.assertIn('next_ticks', script)
        self.assertTrue((ROOT / 'units/phone-android/verify-background.json').exists())

if __name__ == '__main__': unittest.main()
