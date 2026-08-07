// SPDX-License-Identifier: Apache-2.0
//
// What can be worked out about a project without being told.
//
// Every value here is already declared somewhere in the repository — the
// applicationId in Gradle, the bundle identifier in the Xcode project, the
// version in pubspec.yaml. A release command that made you repeat them would be
// asking you to keep three copies in step, and the shell scripts that used to
// drive this did exactly that with `sed`, once per script.
//
// So the flags stay, and become overrides rather than requirements: `cux_ship
// play promote` with no arguments is the normal case, and anything it gets
// wrong can be said explicitly.
//
// Inference is deliberately shallow — a regex over a known file, no build
// system invoked, no analysis. It runs before every command, so it has to be
// instant, and a wrong guess is visible in the confirmation prompt before
// anything happens.
import 'dart:io';

/// Where a project keeps the things a release needs.
class ProjectContext {
  ProjectContext({
    required this.root,
    this.androidPackage,
    this.iosBundleId,
    this.macosBundleId,
    this.versionName,
    this.buildNumber,
    this.changelog,
    this.appStoreMetadata,
    this.playMetadata,
    this.dataSafety,
  });

  /// Reads what it can from [directory], defaulting to the working directory.
  ///
  /// Defaults to the *repository* root, not the working directory. A consumer
  /// runs this from the package that pins it — `tool/cux_ship` — so a
  /// working-directory default finds nothing at all, and quietly turns every
  /// inferred value back into a required flag. Falls back to the working
  /// directory outside a git repository, where there is nothing better to
  /// guess.
  ///
  /// Absent files are not an error: a project with no iOS target simply has no
  /// [iosBundleId], and only a command that needs one will complain.
  factory ProjectContext.read([String? directory]) {
    final root = Directory(directory ?? _repositoryRoot());
    String? text(String relative) {
      final file = File('${root.path}/$relative');
      return file.existsSync() ? file.readAsStringSync() : null;
    }

    String? path(String relative) {
      final full = '${root.path}/$relative';
      return File(full).existsSync() || Directory(full).existsSync()
          ? full
          : null;
    }

    final pubspec = text('pubspec.yaml');
    String? versionName;
    String? buildNumber;
    if (pubspec != null) {
      // `version: 1.0.3+41` — the half before the + is the marketing version
      // and the half after is the build number, which is the same convention
      // both stores use and the same one flutter build reads.
      final match = RegExp(
        r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)(?:\+([0-9]+))?',
        multiLine: true,
      ).firstMatch(pubspec);
      versionName = match?.group(1);
      buildNumber = match?.group(2);
    }

    return ProjectContext(
      root: root.path,
      androidPackage: _firstGroup(
        text('android/app/build.gradle.kts') ??
            text('android/app/build.gradle'),
        RegExp(r'applicationId\s*=?\s*"([^"]+)"'),
      ),
      iosBundleId: _bundleId(text('ios/Runner.xcodeproj/project.pbxproj')),
      macosBundleId: _bundleId(text('macos/Runner.xcodeproj/project.pbxproj')),
      versionName: versionName,
      buildNumber: buildNumber,
      changelog: path('CHANGELOG.md'),
      appStoreMetadata: path('store/appstore'),
      playMetadata: path('store/play'),
      dataSafety: path('store/play/data-safety.csv'),
    );
  }

  /// Absolute path to the project root.
  final String root;

  /// Gradle's `applicationId` — what Play calls the package name.
  final String? androidPackage;

  /// `PRODUCT_BUNDLE_IDENTIFIER` from the iOS Xcode project.
  final String? iosBundleId;

  /// `PRODUCT_BUNDLE_IDENTIFIER` from the macOS Xcode project.
  final String? macosBundleId;

  /// The marketing version from `pubspec.yaml`, e.g. `1.0.3`.
  final String? versionName;

  /// The build number from `pubspec.yaml`, e.g. `41` in `1.0.3+41`.
  final String? buildNumber;

  /// `CHANGELOG.md`, when there is one.
  final String? changelog;

  /// `store/appstore`, when there is one.
  final String? appStoreMetadata;

  /// `store/play`, when there is one.
  final String? playMetadata;

  /// `store/play/data-safety.csv`, when there is one.
  final String? dataSafety;

  /// The bundle identifier for [platform], which is `ios` or `macos`.
  String? bundleIdFor(String platform) =>
      platform == 'macos' ? macosBundleId : iosBundleId;

  /// The RunnerTests target carries its own identifier and must not win, so
  /// the first match that is not a test target is the app's.
  static String? _bundleId(String? pbxproj) {
    if (pbxproj == null) {
      return null;
    }
    for (final match in RegExp(
      r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;]+);',
    ).allMatches(pbxproj)) {
      final value = match.group(1)!.trim().replaceAll('"', '');
      if (value.contains('RunnerTests') || value.endsWith('.RunnerTests')) {
        continue;
      }
      return value;
    }
    return null;
  }

  static String? _firstGroup(String? text, RegExp pattern) =>
      text == null ? null : pattern.firstMatch(text)?.group(1);

  /// The git toplevel above the working directory, or the working directory
  /// when there is no repository above it.
  static String _repositoryRoot() {
    final result = Process.runSync('git', [
      'rev-parse',
      '--show-toplevel',
    ], workingDirectory: Directory.current.path);
    if (result.exitCode != 0) {
      return Directory.current.path;
    }
    final path = (result.stdout as String).trim();
    return path.isEmpty ? Directory.current.path : path;
  }
}
