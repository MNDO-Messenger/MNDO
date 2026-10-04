import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties").takeIf { it.exists() }
    ?: project.file("key.properties").takeIf { it.exists() }

if (keystorePropertiesFile != null) {
    keystorePropertiesFile.inputStream().use { stream ->
        keystoreProperties.load(stream)
    }
}

val storeFilePath: String? = keystoreProperties.getProperty("storeFile")
    ?: System.getenv("ANDROID_KEYSTORE_PATH")
val storePasswordProp: String? = keystoreProperties.getProperty("storePassword")
    ?: System.getenv("ANDROID_KEYSTORE_PASSWORD")
val keyAliasProp: String? = keystoreProperties.getProperty("keyAlias")
    ?: System.getenv("ANDROID_KEY_ALIAS")
val keyPasswordProp: String? = keystoreProperties.getProperty("keyPassword")
    ?: System.getenv("ANDROID_KEY_PASSWORD")

val resolvedStoreFile: File? = storeFilePath?.let { path ->
    val f = file(path)
    if (f.exists()) {
        f
    } else {
        val rootF = rootProject.file(path)
        if (rootF.exists()) rootF else f
    }
}

val hasReleaseSigning = resolvedStoreFile != null &&
    resolvedStoreFile.exists() &&
    !storePasswordProp.isNullOrBlank() &&
    !keyAliasProp.isNullOrBlank() &&
    !keyPasswordProp.isNullOrBlank()

android {
    namespace = "com.aisatconnect.aisat_connect"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.aisatconnect.aisat_connect"
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
        create("release") {
            if (hasReleaseSigning) {
                storeFile = resolvedStoreFile
                storePassword = storePasswordProp
                keyAlias = keyAliasProp
                keyPassword = keyPasswordProp
            }
        }
    }

    buildTypes {
        release {
            // AND-REL-01: Production release build ALWAYS uses the release signing configuration.
            // Under NO circumstances does release fall back to the Android debug signing configuration.
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

// AND-REL-01: Strict Fail-Closed Enforcement for Release Artifacts
gradle.taskGraph.whenReady {
    val isReleaseBuildRequested = allTasks.any { task ->
        val name = task.name
        name.contains("Release", ignoreCase = false) &&
            (name.startsWith("assemble") ||
             name.startsWith("bundle") ||
             name.startsWith("package") ||
             name.startsWith("validateSigning") ||
             name.startsWith("sign"))
    }

    if (isReleaseBuildRequested && !hasReleaseSigning) {
        val missingRequirements = mutableListOf<String>()
        if (storeFilePath.isNullOrBlank()) {
            missingRequirements.add("storeFile is missing (define 'storeFile' in key.properties or set ANDROID_KEYSTORE_PATH)")
        } else if (resolvedStoreFile == null || !resolvedStoreFile.exists()) {
            missingRequirements.add("Keystore file not found at: '$storeFilePath'")
        }
        if (storePasswordProp.isNullOrBlank()) {
            missingRequirements.add("storePassword is missing (define in key.properties or set ANDROID_KEYSTORE_PASSWORD)")
        }
        if (keyAliasProp.isNullOrBlank()) {
            missingRequirements.add("keyAlias is missing (define in key.properties or set ANDROID_KEY_ALIAS)")
        }
        if (keyPasswordProp.isNullOrBlank()) {
            missingRequirements.add("keyPassword is missing (define in key.properties or set ANDROID_KEY_PASSWORD)")
        }

        throw GradleException(
            """
            ================================================================================
            [MNDO SECURITY ERROR: AND-REL-01] Production Release Signing Required
            ================================================================================
            A release build was requested ('${gradle.startParameter.taskNames.joinToString(", ")}'),
            but valid production signing credentials were not found.

            MNDO enforces a strict fail-closed release policy:
            Release artifacts (APK/AAB) must never be generated using debug signing keys.
            Falling back to the Android debug key is strictly prohibited.

            Missing or incomplete signing requirements:
            ${missingRequirements.joinToString("\n") { "  - $it" }}

            To build a release artifact:
              1. Copy 'android/key.properties.example' to 'android/key.properties'.
              2. Configure valid keystore parameters in 'android/key.properties', or set
                 environment variables (ANDROID_KEYSTORE_PATH, ANDROID_KEYSTORE_PASSWORD,
                 ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD).

            For local development and testing, use debug builds:
              flutter run
              flutter build apk --debug
            ================================================================================
            """.trimIndent()
        )
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
