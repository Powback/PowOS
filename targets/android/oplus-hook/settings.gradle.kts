pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // The Xposed API (compile-only; LSPosed provides it at runtime).
        maven("https://api.xposed.info/")
    }
}

rootProject.name = "powos-oplus-hook"
include(":app")
