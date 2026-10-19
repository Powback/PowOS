// Compile-time stand-ins for the framework's hidden (@hide) classes the system slots name directly
// (app/src/main/kotlin/dev/omalauncher/system/gesture/): the app compiles against these and runs against the phone's
// own classes. :app depends on this module compileOnly, so none of it ends up in the APK.
//
// HACK: hand-written stubs of the platform's hidden API. Real fix: none for an app - the SDK's android.jar leaves them
// out, only a platform build sees them. Each stub mirrors the device's signature (OnePlus Open, Android 16, checked in
// the decompiled launcher and SystemUI); a mismatch fails at run time with NoSuchMethodError/NoSuchFieldError, which
// the callers catch (they fall back to the plain, non-animated path).
plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "dev.powos.hiddenstubs"
    compileSdk = 37
    defaultConfig { minSdk = 30 }
}
