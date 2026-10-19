import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The Play upload key, named by android/key.properties (never committed):
// storeFile, storePassword, keyAlias, keyPassword. Without that file a release
// build is signed with the debug key, so `flutter run --release` still works,
// but Google Play refuses it.
val uploadKey = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) FileInputStream(file).use { load(it) }
}

android {
    namespace = "com.zuniawallet.zunia_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications uses java.time, which needs desugaring
        // below API 26.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // The Play listing's package name: it can never change once published.
        applicationId = "com.zuniawallet.zunia_mobile"
        // local_auth / flutter_secure_storage / reown_walletkit require API 23+
        minSdk = maxOf(23, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        // From pubspec.yaml's version (name+code).
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (uploadKey.isNotEmpty()) {
            create("upload") {
                storeFile = file(uploadKey.getProperty("storeFile"))
                storePassword = uploadKey.getProperty("storePassword")
                keyAlias = uploadKey.getProperty("keyAlias")
                keyPassword = uploadKey.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("upload") ?: signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // BiometricPrompt with a CryptoObject for the hardware-bound biometric
    // unlock (ZuniaSecurity.kt).
    implementation("androidx.biometric:biometric:1.1.0")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
