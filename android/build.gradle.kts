// Blip for Android. Versions match Scripture Alone's and Haven's Android builds.
plugins {
    id("com.android.application") version "8.7.3" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.21" apply false
}

// BLIP_ANDROID_BUILD_DIR moves every build output out of the source tree (the owner's checkout
// is synced by iCloud, which makes "name 2" copies of fast-changing files).
System.getenv("BLIP_ANDROID_BUILD_DIR")?.takeIf { it.isNotBlank() }?.let { base ->
    allprojects {
        layout.buildDirectory.set(File(base, if (this == rootProject) "root" else name))
    }
}
