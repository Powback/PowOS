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
        self.assertIn('lifecycle.requestClose(() -> worker.postAtFrontOfQueue(() -> {', receiver)
        self.assertIn('lifecycle.closingOnWorker(() -> report(State.CLOSING,', receiver)
        self.assertIn('if (!lifecycle.finishOnWorker()) return;', receiver)
        self.assertIn('worker.removeCallbacksAndMessages(null)', receiver)
        self.assertIn('source != codec || lifecycle.isClosing()', receiver)
        self.assertIn('stopped.await(timeoutMs, TimeUnit.MILLISECONDS)', receiver)
        self.assertNotIn('surface.release()', receiver)

    def test_canonical_staging_is_carried_to_apk(self):
        build = (ROOT / 'sources/powstream/build-android.sh').read_text()
        self.assertIn('--android-client-core', build)
        self.assertIn('ANDROID_CLIENT_REV', build)
        self.assertIn('libpowstream_client_core.so', build)
        self.assertIn('sources/powstream/build-android.sh',
                      (ROOT / 'targets/android/prep-app.sh').read_text())
        # Every APK build path stages it (the emulator lane's skipped it and failed at CMake, 11-23).
        self.assertIn('prep-app.sh', (ROOT / 'targets/android/build-app.sh').read_text())
        self.assertIn('prep-app.sh', (ROOT / 'tools/emu/emu.sh').read_text())
        self.assertIn('-- targets/android/app/engine/powstream-native',
                      (ROOT / 'targets/android/tools/apk-job.sh').read_text())

    def test_jvm_job_requires_and_carries_pinned_native_staging(self):
        job = (ROOT / 'tools/agents/jvm-offload.sh').read_text()
        self.assertIn('-- targets/android/app/engine/powstream-native', job)
        self.assertIn('. "$TOP/sources/powstream/source.conf"', job)
        for name in ('arm64-v8a/libpowstream_client_core.so',
                     'include/powstream_client_core.h', 'include/powstream-source-revision'):
            self.assertIn(name, job)
        self.assertIn('[ -s "$native/$input" ]', job)
        self.assertIn('"$(cat "$native/include/powstream-source-revision")" = "$ANDROID_CLIENT_REV"', job)
        self.assertLess(job.index('missing PowStream native input'), job.index('job_init jvm'))
        self.assertLess(job.index('stale PowStream native staging'), job.index('job_init jvm'))
        # Build instruction is diagnostic text only; no implicit source/network build in tests.
        self.assertNotIn('\n    bash ', job)
        self.assertNotIn('\nbash ', job)
        self.assertNotIn('--android-client-core', job)


if __name__ == '__main__':
    unittest.main()
