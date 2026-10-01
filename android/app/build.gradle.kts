plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.bili_tracker"
    compileSdk = flutter.compileSdkVersion
    // 插件(workmanager/flutter_inappwebview等)要求 NDK 27.0.12077973，取各插件要求的最高版本
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        // flutter_local_notifications 的 AAR 元数据要求开启 core library desugaring，
        // 否则构建在 :app:checkReleaseAarMetadata 一步直接失败：
        //   "Dependency ':flutter_local_notifications' requires core library
        //    desugaring to be enabled for :app."
        // 开启后还需在文件底部的 dependencies 中补上 desugar_jdk_libs 依赖。
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.bili_tracker"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // 与上方 isCoreLibraryDesugaringEnabled = true 配套，缺一不可。
    // 2.1.4 适配 AGP 8.1+（本项目 AGP 8.7.3），官方推荐版本。
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
