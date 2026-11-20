plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Internal test signing is supplied only by the test-branch CI job.
val testKeystorePath = System.getenv("MOTIF_TEST_KEYSTORE_PATH")
val testStorePassword = System.getenv("MOTIF_TEST_STORE_PASSWORD")
val testKeyAlias = System.getenv("MOTIF_TEST_KEY_ALIAS")
val testKeyPassword = System.getenv("MOTIF_TEST_KEY_PASSWORD")
val testSigningAvailable = listOf(
    testKeystorePath, testStorePassword, testKeyAlias, testKeyPassword,
).all { !it.isNullOrBlank() }
val requireTestSigning = System.getenv("MOTIF_REQUIRE_TEST_SIGNING") == "true"
check(!requireTestSigning || testSigningAvailable) {
    "Stable test signing is required; configure the MOTIF_TEST_* Actions secrets."
}

android {
    namespace = "com.alizesa.motif"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.alizesa.motif"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (testSigningAvailable) {
            create("internalTest") {
                storeFile = file(testKeystorePath!!)
                storePassword = testStorePassword
                keyAlias = testKeyAlias
                keyPassword = testKeyPassword
            }
        }
    }

    buildTypes {
        release {
            // Production signing remains a separate, unconfigured release task.
            signingConfig = signingConfigs.getByName(
                if (testSigningAvailable) "internalTest" else "debug",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
