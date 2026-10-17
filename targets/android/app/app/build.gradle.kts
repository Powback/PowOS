import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

// The Play upload key, from the gitignored keystore.properties at the repo root.
val uploadKey = rootProject.file("keystore.properties").takeIf { it.exists() }
    ?.let { f -> Properties().apply { f.inputStream().use(::load) } }

// Version stamped by android-app-dev's build (scripts/build-gradle.sh writes app/version.properties, gitignored):
// PowApps compares versionCode with the store's <project>.ver sidecar to offer updates.
val versionProps = Properties().also { props ->
    val f = rootProject.file("app/version.properties")
    if (f.exists()) f.inputStream().use { props.load(it) }
}

android {
    namespace = "dev.omalauncher"
    compileSdk = 37

    defaultConfig {
        // PowOS: our own app id, so it installs next to Omalauncher from the Play Store.
        applicationId = "com.powos.app"
        // minSdk 30: the engine's native code needs API 30 (memfd_create).
        minSdk = 30
        // targetSdk 28: Android lets only apps targeting <= 28 execute files from their own data dir (W^X),
        // which running the PowOS rootfs without proot needs (the engine's lotfix-run). Consequence:
        // side-loaded, not on the Play Store. (Omalauncher targets 37 and runs proot from its APK instead.)
        targetSdk = 28
        versionCode = versionProps.getProperty("versionCode")?.toInt() ?: 1
        versionName = versionProps.getProperty("versionName") ?: "0.1.0-dev"
        ndk { abiFilters += "arm64-v8a" }
    }

    buildFeatures { buildConfig = true }

    externalNativeBuild {
        cmake { path = file("src/main/cpp/CMakeLists.txt") }
    }

    packaging {
        jniLibs {
            // Extract .so files to nativeLibraryDir: proot is exec'd from there.
            useLegacyPackaging = true
            keepDebugSymbols += listOf("**/libproot.so", "**/libproot-loader.so")
        }
    }

    // android.util.Log and friends are no-ops in JVM tests instead of throwing.
    testOptions { unitTests.isReturnDefaultValues = true }

    signingConfigs {
        create("release") {
            uploadKey?.let {
                storeFile = rootProject.file(it.getProperty("storeFile"))
                storePassword = it.getProperty("storePassword")
                keyAlias = it.getProperty("keyAlias")
                keyPassword = it.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Shrinks the APK and drops what the app doesn't use, like the owl module's unused parts.
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.getByName(if (uploadKey != null) "release" else "debug")
        }
    }
}

composeCompiler {
    stabilityConfigurationFiles.add(rootProject.layout.projectDirectory.file("app/compose-stability.conf"))
}

dependencies {
    implementation(libs.androidx.activity.compose)
    implementation(libs.compose.runtime)
    implementation(libs.compose.foundation)
    implementation(libs.compose.ui)
    implementation(libs.commons.compress)
    implementation(libs.androidsvg)
    implementation(libs.zxing.core)
    implementation(libs.termux.terminal.view)
    implementation(project(":owl"))
    // PowOS: Andromarchy's engine (display, session, rootfs install), GPL-3.0; the app is GPL-3.0 as a whole.
    implementation(project(":engine"))
    testImplementation(libs.junit)
    // android.jar only has stubs of org.json.
    testImplementation(libs.org.json)
}
