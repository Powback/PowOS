#!/usr/bin/env python3
"""Source-level ownership/build invariants; not a substitute for JNI/device tests."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / 'targets/android/app/engine'


class Contract(unittest.TestCase):
    def test_native_uses_authoritative_abi(self):
        c = (ENGINE / 'src/main/jni/powstream_jni.c').read_text()
        self.assertIn('#include "powstream_client_core.h"', c)
        self.assertIn('offsetof(PsAu, len) == 48', c)
        self.assertIn('GetDirectBufferCapacity', c)
        self.assertIn('rc == PS_OK || rc == PS_BUFFER_SMALL', c)
        self.assertNotIn('NewDirectByteBuffer', c)  # no dangling native-owned storage

    def test_handle_is_worker_owned_and_closed_once(self):
        core = (ENGINE / 'src/main/java/andro/marchy/stream/PowStreamCore.java').read_text()
        receiver = (ENGINE / 'src/main/java/andro/marchy/stream/PowStreamReceiver.java').read_text()
        self.assertIn('Thread.currentThread() != owner', core)
        self.assertLess(core.index('handle = 0;'), core.index('closeNative(old)'))
        self.assertIn('worker.postAtFrontOfQueue(this::finish)', receiver)
        self.assertIn('worker.removeCallbacksAndMessages(null)', receiver)
        self.assertIn('source != codec || closing.get()', receiver)
        self.assertIn('stopped.await(timeoutMs, TimeUnit.MILLISECONDS)', receiver)
        self.assertNotIn('surface.release()', receiver)

    def test_canonical_staging_is_carried_to_apk(self):
        build = (ROOT / 'sources/powstream/build-android.sh').read_text()
        self.assertIn('--android-client-core', build)
        self.assertIn('ANDROID_CLIENT_REV', build)
        self.assertIn('libpowstream_client_core.so', build)
        self.assertIn('sources/powstream/build-android.sh',
                      (ROOT / 'targets/android/build-app.sh').read_text())
        self.assertIn('-- targets/android/app/engine/powstream-native',
                      (ROOT / 'targets/android/tools/apk-job.sh').read_text())


if __name__ == '__main__':
    unittest.main()
