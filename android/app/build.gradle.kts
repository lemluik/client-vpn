import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.clientvpn.client_vpn"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.clientvpn.client_vpn"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Ядро Xray собирается только под 64-битный ARM: других бинарников
        // официальный релиз Xray-core для Android не содержит.
        ndk {
            abiFilters += "arm64-v8a"
        }
    }

    packaging {
        jniLibs {
            // Ядро обязано распаковываться в nativeLibraryDir — это единственное
            // место, откуда Android 10+ разрешает исполнять файлы.
            useLegacyPackaging = true
        }
    }

    // Релизная подпись Android (позиция ТД-2). Ключ и пароли лежат в
    // android/key.properties, которого нет в репозитории: без него сборка
    // подписывается отладочным ключом — ровно как до этой правки, поэтому CI и
    // локальная сборка не ломаются. Как только владелец решит публиковаться и
    // создаст keyring, файл появляется локально и в CI-секретах, а следующий
    // релиз получает настоящую подпись.
    val releaseKeystore = rootProject.file("key.properties")
    if (releaseKeystore.exists()) {
        val props = Properties().apply { FileInputStream(releaseKeystore).use { load(it) } }
        signingConfigs {
            create("release") {
                keyAlias = props.getProperty("keyAlias")
                keyPassword = props.getProperty("keyPassword")
                storeFile = file(props.getProperty("storeFile"))
                storePassword = props.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (releaseKeystore.exists()) {
                signingConfigs.getByName("release")
            } else {
                // отладочный ключ: `flutter run --release` и тестовые сборки работают
                signingConfigs.getByName("debug")
            }
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
