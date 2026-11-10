import java.util.Properties
plugins { id("com.android.application") }
val versionProps = Properties().also { p ->
    val f = file("version.properties")
    if (f.exists()) f.inputStream().use { p.load(it) }
}
android {
    namespace = "com.powos.verifybackground"
    compileSdk = 35
    defaultConfig {
        applicationId = "com.powos.verifybackground"
        minSdk = 26
        targetSdk = 35
        versionCode = versionProps.getProperty("versionCode", "1").toInt()
        versionName = versionProps.getProperty("versionName", "dev")
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
