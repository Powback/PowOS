import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
}

// Version from android-app-dev's build (app/version.properties, gitignored).
val versionProps = Properties().also { props ->
    val f = rootProject.file("app/version.properties")
    if (f.exists()) f.inputStream().use { props.load(it) }
}

android {
    namespace = "powos.oplushook"
    compileSdk = 36
    buildToolsVersion = "35.0.0"

    defaultConfig {
        applicationId = "com.powos.oplushook"
        minSdk = 33
        targetSdk = 34
        versionCode = versionProps.getProperty("versionCode", "1").toInt()
        versionName = versionProps.getProperty("versionName", "dev")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    compileOnly("de.robv.android.xposed:api:82")
}
