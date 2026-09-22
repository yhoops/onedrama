import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 第一版 release 的签名。密钥与密码都在 `android/key.properties`（不进版本控制，
// 见 .gitignore），文件缺失就退回 debug 签名——这样没拿到密钥的人也跑得动
// `flutter run --release`，不会因为缺文件而构建失败。
//
// storeFile 相对 `android/` 解析（这里用 rootProject.file），所以值是 `app/xxx.p12`。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKey = keystorePropertiesFile.exists()
if (hasReleaseKey) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.example.onedrama"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.onedrama"
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
        if (hasReleaseKey) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    // **两个 buildType 用同一把签名。** 不这么做的话 debug 与 release 是两个签名，互相
    // 覆盖安装会 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`，只能先卸载——而卸载会把收藏 /
    // 观看进度一起清掉。这条已经踩过一次（`docs/plan.md` 风险 7）。
    val appSigning =
        if (hasReleaseKey) {
            signingConfigs.getByName("release")
        } else {
            signingConfigs.getByName("debug")
        }

    buildTypes {
        release {
            signingConfig = appSigning
        }
        debug {
            signingConfig = appSigning
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // 播放器内核。CENC 解密要 MediaCodec + MediaCrypto，只能走 ExoPlayer/MediaDrm，
    // 官方 video_player 接不到那把 16 字节裸密钥（见 docs/adr/0002）。
    implementation("androidx.media3:media3-exoplayer:1.11.1")
    implementation("androidx.media3:media3-datasource:1.11.1")
    implementation("androidx.media3:media3-common:1.11.1")
}

flutter {
    source = "../.."
}
