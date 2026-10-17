rootProject.name = "PowOS"

pluginManagement {
    repositories {
        google {
            mavenContent {
                includeGroupAndSubgroups("androidx")
                includeGroupAndSubgroups("com.android")
                includeGroupAndSubgroups("com.google")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google {
            mavenContent {
                includeGroupAndSubgroups("androidx")
                includeGroupAndSubgroups("com.android")
                includeGroupAndSubgroups("com.google")
            }
        }
        mavenCentral()
        // Termux's terminal emulator and view (the launcher's PowOS terminal tiles), published only on JitPack.
        maven("https://jitpack.io") { mavenContent { includeGroup("com.github.termux.termux-app") } }
    }
}

include(":app")
include(":owl")
include(":engine")
