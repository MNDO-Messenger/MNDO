import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Android Release Signing Security (AND-REL-01)', () {
    final rootDir = Directory.current;
    final gradleFile = File('${rootDir.path}/android/app/build.gradle.kts');
    final gitignoreFile = File('${rootDir.path}/.gitignore');

    test('build.gradle.kts strictly binds release build to production signing config', () {
      expect(gradleFile.existsSync(), isTrue,
          reason: 'android/app/build.gradle.kts must exist');

      final content = gradleFile.readAsStringSync();

      // Verify release build type always references the release signing configuration
      expect(content, contains('signingConfig = signingConfigs.getByName("release")'),
          reason: 'Release buildType must unconditionally use release signing config');

      // Verify release build type never falls back to debug signing config
      final releaseBlockMatch = RegExp(r'buildTypes\s*\{[\s\S]*?release\s*\{([\s\S]*?)\}');
      final match = releaseBlockMatch.firstMatch(content);
      expect(match, isNotNull, reason: 'release buildType block must exist');

      final releaseBody = match!.group(1)!;
      expect(releaseBody, isNot(contains('getByName("debug")')),
          reason: 'Release buildType block must NEVER fall back to debug signing');
    });

    test('build.gradle.kts implements fail-closed release artifact gate in taskGraph', () {
      final content = gradleFile.readAsStringSync();

      expect(content, contains('gradle.taskGraph.whenReady'),
          reason: 'taskGraph.whenReady hook must be registered');
      expect(content, contains('[MNDO SECURITY ERROR: AND-REL-01] Production Release Signing Required'),
          reason: 'Must emit explicit MNDO security error when release signing is missing');

      // Verify targeted tasks
      expect(content, contains('name.startsWith("assemble")'));
      expect(content, contains('name.startsWith("bundle")'));
      expect(content, contains('name.startsWith("package")'));
      expect(content, contains('name.startsWith("validateSigning")'));
      expect(content, contains('name.startsWith("sign")'));
    });

    test('build.gradle.kts enforces keystore opening, password, alias, and key pre-validation', () {
      final content = gradleFile.readAsStringSync();

      expect(content, contains('KeyStore.getInstance'),
          reason: 'Must attempt to open and load the KeyStore instance');
      expect(content, contains('ks.containsAlias(keyAlias)'),
          reason: 'Must verify that the specified keyAlias exists in the keystore');
      expect(content, contains('ks.getKey(keyAlias'),
          reason: 'Must verify that the private key can be retrieved with keyPassword');
      expect(content, contains('[MNDO SECURITY ERROR: AND-REL-01] Invalid Keystore or Password'),
          reason: 'Must report explicit error if keystore cannot be opened');
      expect(content, contains('[MNDO SECURITY ERROR: AND-REL-01] Keystore Alias Not Found'),
          reason: 'Must report explicit error if alias is not found in keystore');
    });

    test('build.gradle.kts supports certificate SHA-256 fingerprint pinning', () {
      final content = gradleFile.readAsStringSync();

      expect(content, contains('expectedSha256Prop'),
          reason: 'Must support expectedSha256 property or environment variable');
      expect(content, contains('MessageDigest.getInstance("SHA-256")'),
          reason: 'Must compute SHA-256 certificate fingerprint when expectedSha256 is set');
      expect(content, contains('[MNDO SECURITY ERROR: AND-REL-01] Certificate Fingerprint Mismatch!'),
          reason: 'Must fail closed if the certificate fingerprint does not match');
    });

    test('.gitignore strictly ignores keystores and key.properties', () {
      expect(gitignoreFile.existsSync(), isTrue,
          reason: '.gitignore must exist');

      final content = gitignoreFile.readAsStringSync();
      expect(content, contains('key.properties'),
          reason: 'key.properties must be in .gitignore');
      expect(content, contains('*.keystore'),
          reason: '*.keystore must be in .gitignore');
      expect(content, contains('*.jks'),
          reason: '*.jks must be in .gitignore');
    });

    test('End-to-End: assembleRelease dry-run fails closed without credentials', () async {
      final gradlewName = Platform.isWindows ? 'gradlew.bat' : 'gradlew';
      final gradlewFile = File('${rootDir.path}/android/$gradlewName');

      if (!gradlewFile.existsSync()) {
        markTestSkipped('Gradle wrapper not found in android directory');
        return;
      }

      // Ensure no key.properties exists prior to this test
      final keyProps = File('${rootDir.path}/android/key.properties');
      expect(keyProps.existsSync(), isFalse,
          reason: 'android/key.properties must not exist in a clean checkout');

      final environment = Map<String, String>.from(Platform.environment);
      // Remove any signing environment variables that might be set on host
      environment.remove('ANDROID_KEYSTORE_PATH');
      environment.remove('ANDROID_KEYSTORE_PASSWORD');
      environment.remove('ANDROID_KEY_ALIAS');
      environment.remove('ANDROID_KEY_PASSWORD');
      environment.remove('ANDROID_KEYSTORE_SHA256');
      environment.remove('EXPECTED_SIGNING_SHA256');

      // Set JAVA_HOME if Android Studio JBR exists and JAVA_HOME is not set
      if (!environment.containsKey('JAVA_HOME') || environment['JAVA_HOME']!.isEmpty) {
        const jbrPath = r'C:\Program Files\Android\Android Studio\jbr';
        if (Directory(jbrPath).existsSync()) {
          environment['JAVA_HOME'] = jbrPath;
        }
      }

      // Clean any pre-existing release artifacts prior to running the test
      final releaseApk = File('${rootDir.path}/build/app/outputs/flutter-apk/app-release.apk');
      final releaseAab = File('${rootDir.path}/build/app/outputs/bundle/release/app-release.aab');
      if (releaseApk.existsSync()) {
        try {
          releaseApk.deleteSync();
        } catch (_) {}
      }
      if (releaseAab.existsSync()) {
        try {
          releaseAab.deleteSync();
        } catch (_) {}
      }

      final result = await Process.run(
        gradlewFile.absolute.path,
        [':app:assembleRelease', '--dry-run'],
        workingDirectory: '${rootDir.path}/android',
        environment: environment,
        runInShell: true,
      );

      final combinedOutput = '${result.stdout}\n${result.stderr}';

      // 1. Must exit with failure
      expect(result.exitCode, isNot(equals(0)),
          reason: 'assembleRelease must fail closed when production keystore is missing');

      // 2. Must emit MNDO security error
      expect(
        combinedOutput,
        contains('[MNDO SECURITY ERROR: AND-REL-01] Production Release Signing Required'),
        reason: 'Error message must state production release signing is required',
      );

      // 3. No release APK or AAB should exist
      expect(releaseApk.existsSync(), isFalse,
          reason: 'No release APK must be generated');
      expect(releaseAab.existsSync(), isFalse,
          reason: 'No release AAB must be generated');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('End-to-End: assembleDebug dry-run succeeds without credentials', () async {
      final gradlewName = Platform.isWindows ? 'gradlew.bat' : 'gradlew';
      final gradlewFile = File('${rootDir.path}/android/$gradlewName');

      if (!gradlewFile.existsSync()) {
        markTestSkipped('Gradle wrapper not found in android directory');
        return;
      }

      final environment = Map<String, String>.from(Platform.environment);
      environment.remove('ANDROID_KEYSTORE_PATH');
      environment.remove('ANDROID_KEYSTORE_PASSWORD');
      environment.remove('ANDROID_KEY_ALIAS');
      environment.remove('ANDROID_KEY_PASSWORD');

      if (!environment.containsKey('JAVA_HOME') || environment['JAVA_HOME']!.isEmpty) {
        const jbrPath = r'C:\Program Files\Android\Android Studio\jbr';
        if (Directory(jbrPath).existsSync()) {
          environment['JAVA_HOME'] = jbrPath;
        }
      }

      final result = await Process.run(
        gradlewFile.absolute.path,
        [':app:assembleDebug', '--dry-run'],
        workingDirectory: '${rootDir.path}/android',
        environment: environment,
        runInShell: true,
      );

      final combinedOutput = '${result.stdout}\n${result.stderr}';

      // assembleDebug should succeed with exit code 0
      expect(result.exitCode, equals(0),
          reason: 'assembleDebug must succeed for developers without production credentials. Output: $combinedOutput');
      expect(combinedOutput, contains('BUILD SUCCESSFUL'),
          reason: 'assembleDebug dry-run must report BUILD SUCCESSFUL');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
