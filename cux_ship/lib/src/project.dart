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
//
// **Two roots, and which owns what is the whole of it.** In a monorepo the
// Flutter app is a subdirectory — `app/` — and the release is still a property
// of the repository. So:
//
//   the repository owns   CHANGELOG.md, store/
//   the app directory owns pubspec.yaml, android/, ios/, macos/
//
// That is not a compromise between two conventions. A version lives in
// pubspec.yaml because Flutter puts it there, and platform identifiers live
// under android/ and ios/ for the same reason; the changelog and the store
// listing describe what shipped, which is the repository's business — most of
// what a user notices usually changed in some other package entirely.
//
// [appDir] is empty for the ordinary case where the app *is* the repository,
// and everything below then reads from one place exactly as it always did.
import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';

/// Something wrong with how the project was described, rather than a bug.
class ProjectException implements Exception {
  ProjectException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Where a project keeps the things a release needs.
class ProjectContext {
  ProjectContext({
    required this.root,
    String? appDir,
    this.appDirRelative = '',
    this.androidPackage,
    this.iosBundleId,
    this.macosBundleId,
    this.versionName,
    this.buildNumber,
    this.changelog,
    this.appStoreMetadata,
    this.playMetadata,
    this.dataSafety,
  }) : appDir = appDir ?? root;

  /// Reads what it can from [repoRoot], defaulting to the repository root.
  ///
  /// The *repository* root, not the working directory. A consumer runs this
  /// from the package that pins it — `tool/cux_ship` — so a working-directory
  /// default finds nothing at all, and quietly turns every inferred value back
  /// into a required flag. Falls back to the working directory outside a git
  /// repository, where there is nothing better to guess.
  ///
  /// [appDir] names the Flutter app when it is not the repository root, and is
  /// resolved against [repoRoot] when relative. Null means "whatever
  /// `.cux-ship.yaml` says", which is usually nothing. It must exist and it
  /// must be inside the repository; both are refused loudly rather than
  /// inferred past, for the reason given on [relativeAppDir].
  ///
  /// Absent files are not an error: a project with no iOS target simply has no
  /// [iosBundleId], and only a command that needs one will complain.
  factory ProjectContext.read({String? repoRoot, String? appDir}) {
    final rootPath = repoRoot ?? _repositoryRoot();
    final relative = relativeAppDir(
      rootPath,
      effectiveAppDir(rootPath, appDir),
    );
    final appPath = relative.isEmpty ? rootPath : p.join(rootPath, relative);

    String? text(String base, String relative) {
      final file = File(p.join(base, relative));
      return file.existsSync() ? file.readAsStringSync() : null;
    }

    String? path(String base, String relative) {
      final full = p.join(base, relative);
      return File(full).existsSync() || Directory(full).existsSync()
          ? full
          : null;
    }

    final pubspec = text(appPath, 'pubspec.yaml');
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
      root: rootPath,
      appDir: appPath,
      appDirRelative: relative,
      androidPackage: _firstGroup(
        text(appPath, 'android/app/build.gradle.kts') ??
            text(appPath, 'android/app/build.gradle'),
        RegExp(r'applicationId\s*=?\s*"([^"]+)"'),
      ),
      iosBundleId: _bundleId(
        text(appPath, 'ios/Runner.xcodeproj/project.pbxproj'),
      ),
      macosBundleId: _bundleId(
        text(appPath, 'macos/Runner.xcodeproj/project.pbxproj'),
      ),
      versionName: versionName,
      buildNumber: buildNumber,
      changelog: path(rootPath, 'CHANGELOG.md'),
      appStoreMetadata: path(rootPath, 'store/appstore'),
      playMetadata: path(rootPath, 'store/play'),
      dataSafety: path(rootPath, 'store/play/data-safety.csv'),
    );
  }

  /// The app directory to use: [explicit] when something said one, and
  /// otherwise whatever `.cux-ship.yaml` says.
  ///
  /// The single place precedence is decided, so a command that resolves the
  /// app directory for itself — `release finish` does, because it needs the
  /// repository root before a context exists — cannot end up honoring the flag
  /// but not the file.
  static String? effectiveAppDir(String repoRoot, String? explicit) =>
      explicit ?? ProjectConfig.read(repoRoot).appDir;

  /// [appDir] resolved against [repoRoot] and returned relative to it.
  ///
  /// Null, the empty string, `.` and the repository root itself all give the
  /// empty string — the ordinary case where the app *is* the repository.
  ///
  /// Throws rather than falling back, and that is the point of it. A mistyped
  /// `--app-dir` would otherwise infer nothing at all: every value that should
  /// have come from the project turns silently back into a required flag, and
  /// the first symptom is a command asking for a `--package` it has always
  /// worked out for itself. An app directory outside the repository is refused
  /// on the same grounds — git commands take repository-relative paths, so
  /// there is nothing sensible to return.
  static String relativeAppDir(String repoRoot, String? appDir) {
    if (appDir == null || appDir.isEmpty) {
      return '';
    }
    final absolute = p.isAbsolute(appDir)
        ? p.normalize(appDir)
        : p.normalize(p.join(repoRoot, appDir));
    if (!Directory(absolute).existsSync()) {
      throw ProjectException('no such directory: $appDir');
    }

    // Compared after resolving symlinks on both sides. git reports a real path
    // from `rev-parse --show-toplevel`, and a temp directory on macOS is
    // reached through one — so comparing the paths as written calls a directory
    // that is plainly inside the repository outside it.
    final root = Directory(repoRoot).resolveSymbolicLinksSync();
    final resolved = Directory(absolute).resolveSymbolicLinksSync();
    if (p.equals(root, resolved)) {
      return '';
    }
    if (!p.isWithin(root, resolved)) {
      throw ProjectException(
        'the app directory is outside the repository:\n'
        '    app dir     $resolved\n'
        '    repository  $root',
      );
    }
    return p.relative(resolved, from: root);
  }

  /// Absolute path to the repository root, which owns `CHANGELOG.md` and
  /// `store/`.
  final String root;

  /// Absolute path to the Flutter app, which owns `pubspec.yaml`, `android/`
  /// and `ios/`. Equal to [root] unless `--app-dir` said otherwise.
  final String appDir;

  /// [appDir] relative to [root], and empty when they are the same.
  ///
  /// This is the form git wants: `git commit` and `git show <rev>:<path>` both
  /// take repository-relative paths, and neither accepts an absolute one that
  /// happens to point inside the tree.
  final String appDirRelative;

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
