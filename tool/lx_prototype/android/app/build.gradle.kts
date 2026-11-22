plugins {
    id("com.android.application") version "9.3.1"
}

android {
    namespace = "com.alizesa.motif.lxprobe"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    defaultConfig {
        applicationId = "com.alizesa.motif.lxprobe"
        minSdk = 24
        targetSdk = 36
        testInstrumentationRunner = "com.alizesa.motif.lxprobe.IsolationInstrumentation"
        ndk {
            abiFilters += listOf("x86_64", "arm64-v8a")
        }
    }
    buildFeatures {
        aidl = true
    }
    providers.gradleProperty("motifLxMediaLibs").orNull?.let { fixtureDir ->
        sourceSets.getByName("debug").jniLibs.srcDir(file(fixtureDir))
    }
    externalNativeBuild {
        cmake {
            path = file("../../CMakeLists.txt")
            version = "3.22.1"
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
