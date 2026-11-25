group = "dev.qjsdot.qjs_dot"
version = "0.1.0"

plugins {
    id("com.android.library")
}

android {
    namespace = "dev.qjsdot.qjs_dot"
    compileSdk = 35
    ndkVersion = android.ndkVersion

    externalNativeBuild {
        cmake {
            path = file("../src/CMakeLists.txt")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        minSdk = 24
    }
}
