plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// The native core (../../desktop/crates/android): BenchKit, speed/disk tests, ping/traceroute,
// GeoIP and the export, shared with Windows and Linux. Built with cargo-ndk before every build.
// `-PblipAbis=arm64-v8a` builds one ABI for a quick device run; `-PskipRust` reuses the
// libraries from the last build.
val abis = providers.gradleProperty("blipAbis").orNull?.split(',')
    ?: listOf("arm64-v8a", "armeabi-v7a", "x86_64")
val rustLibs = layout.buildDirectory.dir("rustJniLibs").get().asFile
val cargoNdk = tasks.register<Exec>("cargoNdk") {
    group = "build"
    description = "Builds libblip_android.so for ${abis.joinToString()}."
    val desktop = rootProject.layout.projectDirectory.dir("../desktop").asFile
    workingDir = desktop
    commandLine(
        listOf("cargo", "ndk") + abis.flatMap { listOf("-t", it) } +
            listOf("-P", "29", "-o", rustLibs.absolutePath, "build", "--release", "--locked", "-p", "blip-android"),
    )
    inputs.dir(File(desktop, "crates"))
    inputs.file(File(desktop, "Cargo.lock"))
    outputs.dir(rustLibs)
}
if (!providers.gradleProperty("skipRust").isPresent) {
    tasks.named("preBuild") { dependsOn(cargoNdk) }
}

android {
    namespace = "com.blainemiller.blip"
    compileSdk = 36

    sourceSets.getByName("main").jniLibs.srcDir(rustLibs)

    defaultConfig {
        applicationId = "com.blainemiller.blip"
        minSdk = 29
        targetSdk = 36
        // CI passes -PblipVersionCode / -PblipVersionName from the android-v* tag.
        versionCode = providers.gradleProperty("blipVersionCode").orNull?.toInt() ?: 1
        versionName = providers.gradleProperty("blipVersionName").orNull ?: "2.1.0"
        ndk { abiFilters += abis }
    }

    // Release signing comes from the environment (CI secrets) — never from the repository. Without
    // it, `-PdebugSignedRelease` signs with the debug key for local installs.
    val ks = System.getenv("BLIP_ANDROID_KEYSTORE")
    if (!ks.isNullOrEmpty() && File(ks).exists()) {
        signingConfigs.create("release") {
            storeFile = File(ks)
            storePassword = System.getenv("BLIP_ANDROID_KEYSTORE_PASSWORD")
            keyAlias = System.getenv("BLIP_ANDROID_KEY_ALIAS")
            keyPassword = System.getenv("BLIP_ANDROID_KEY_PASSWORD")
        }
        buildTypes.getByName("release").signingConfig = signingConfigs.getByName("release")
    } else if (providers.gradleProperty("debugSignedRelease").isPresent) {
        buildTypes.getByName("release").signingConfig = signingConfigs.getByName("debug")
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
        allWarningsAsErrors = true
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    packaging {
        jniLibs.useLegacyPackaging = false
    }
    testOptions {
        unitTests.isReturnDefaultValues = true
    }
    lint {
        warningsAsErrors = true
        // Library versions are pinned on purpose, to match the other Android apps.
        disable += setOf("GradleDependency", "NewerVersionAvailable", "AndroidGradlePluginVersion")
        // Lint can't read the computed ABI list; CI checks that the APK has x86_64 (and the rest).
        disable += "ChromeOsAbiSupport"
        abortOnError = true
        checkReleaseBuilds = false
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.10.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.navigation:navigation-compose:2.8.4")
    implementation("androidx.glance:glance-appwidget:1.1.1")
    implementation("androidx.glance:glance-material3:1.1.1")
    implementation("androidx.core:core-ktx:1.15.0")
    debugImplementation("androidx.compose.ui:ui-tooling")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
