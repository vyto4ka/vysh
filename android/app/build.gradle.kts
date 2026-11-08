import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release-подпись: android/key.properties (в .gitignore) + keystore.
// Без key.properties (например, в CI) сборка подписывается debug-ключом.
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) load(FileInputStream(f))
}

android {
    namespace = "uwu.vyto4ka.vysh"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    signingConfigs {
        create("release") {
            if (keystoreProperties.isNotEmpty()) {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
            // Все три схемы подписи. При minSdk >= 24 Gradle по умолчанию не ставит
            // v1 (JAR), а часть сторонних установщиков читает сертификат только
            // из неё и при обновлении пишет «отсутствующие сертификаты».
            enableV1Signing = true
            enableV2Signing = true
            enableV3Signing = true
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "uwu.vyto4ka.vysh"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Android 8.0+, как обещано в README: на 7.x приложение не проверялось.
        // (Flutter по умолчанию даёт 24, то есть 7.0.)
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Release-ключ, если есть key.properties; иначе debug -
            // чтобы `flutter run --release` работал без keystore.
            signingConfig = if (keystoreProperties.isNotEmpty()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    // Имя APK: vysh.<версия>.<abi>.apk вместо app-<abi>-release.apk.
    applicationVariants.all {
        outputs.all {
            val output = this as com.android.build.gradle.internal.api.BaseVariantOutputImpl
            val abi = output.filters.firstOrNull { it.filterType == "ABI" }?.identifier
            output.outputFileName = if (abi != null) {
                "vysh.${defaultConfig.versionName}.${abi}.apk"
            } else {
                "vysh.${defaultConfig.versionName}.apk"
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // FileProvider: content:// URI для APK обновления системному установщику.
    implementation("androidx.core:core-ktx:1.13.1")
}

flutter {
    source = "../.."
}
