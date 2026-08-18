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
    this.developmentTeam,
    this.iosBundleIdProblem,
    this.macosBundleIdProblem,
    this.developmentTeamProblem,
    this.targetedDeviceFamily,
    this.targetedDeviceFamilyProblem,
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

    const iosProject = 'ios/Runner.xcodeproj/project.pbxproj';
    const macosProject = 'macos/Runner.xcodeproj/project.pbxproj';
    final ios = _bundleId(text(appPath, iosProject), iosProject);
    final macos = _bundleId(text(appPath, macosProject), macosProject);

    // iOS first, macOS only when iOS said nothing at all. A problem on the iOS
    // side is *something*: an ambiguous iOS project must not be answered by
    // quietly reading the macOS one, which is the same substitution this whole
    // change exists to stop.
    final iosTeam = _developmentTeam(text(appPath, iosProject), iosProject);
    final team = iosTeam.value == null && iosTeam.problem == null
        ? _developmentTeam(text(appPath, macosProject), macosProject)
        : iosTeam;

    final deviceFamily = _targetedDeviceFamily(
      text(appPath, iosProject),
      iosProject,
    );

    return ProjectContext(
      root: rootPath,
      appDir: appPath,
      appDirRelative: relative,
      androidPackage: _firstGroup(
        text(appPath, 'android/app/build.gradle.kts') ??
            text(appPath, 'android/app/build.gradle'),
        RegExp(r'applicationId\s*=?\s*"([^"]+)"'),
      ),
      iosBundleId: ios.value,
      macosBundleId: macos.value,
      developmentTeam: team.value,
      iosBundleIdProblem: ios.problem,
      macosBundleIdProblem: macos.problem,
      developmentTeamProblem: team.problem,
      targetedDeviceFamily: deviceFamily.value,
      targetedDeviceFamilyProblem: deviceFamily.problem,
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

  /// `DEVELOPMENT_TEAM` from whichever Xcode project has one.
  ///
  /// The team a signing certificate must belong to, which is what makes
  /// "imported a certificate" and "imported the *right* certificate" different
  /// checks. A certificate from another developer account imports perfectly and
  /// then fails much later with a profile mismatch that never mentions
  /// certificates.
  final String? developmentTeam;

  /// Why [iosBundleId] is null, when the reason is worth saying. See
  /// [bundleIdProblemFor].
  final String? iosBundleIdProblem;

  /// Why [macosBundleId] is null, when the reason is worth saying.
  final String? macosBundleIdProblem;

  /// Why [developmentTeam] is null, when the reason is worth saying.
  final String? developmentTeamProblem;

  /// `TARGETED_DEVICE_FAMILY` from the iOS project, e.g. `1,2`.
  ///
  /// What it buys is [requiredScreenshotTypes]: the App Store refuses a
  /// submission from a universal app that carries no iPad screenshots, and it
  /// refuses it long after the upload. Which types are required follows from
  /// which device families the binary targets, so it can be read rather than
  /// declared — and a value that is read cannot drift out of date the way a
  /// list of display-type names in a config file does.
  final String? targetedDeviceFamily;

  /// Why [targetedDeviceFamily] is null, when the reason is worth saying.
  final String? targetedDeviceFamilyProblem;

  /// The `ScreenshotDisplayType` values a submission must carry, for
  /// [platform], or null when they cannot be derived.
  ///
  /// **Apple's requirement, not the app's**, which is exactly why deriving it
  /// beats declaring it. `{APP_IPHONE_67, APP_IPAD_PRO_3GEN_129}` is what Apple
  /// asks of a universal app *today*; the 6.7" class replaced the 6.5" one and
  /// something will replace it. A project that writes the names into its own
  /// config holds a value that ages into a post-upload rejection, whereas a
  /// mapping kept here is fixed for every consumer by taking a new version.
  ///
  /// macOS has no `TARGETED_DEVICE_FAMILY` — the Mac App Store has one
  /// screenshot type and it is required — so that side is a constant rather
  /// than a lookup. Two mechanisms behind one word, said plainly so the macOS
  /// half is not later built as "no inference available".
  Set<String>? requiredScreenshotTypes(String platform) {
    if (platform == 'macos') {
      return const {'APP_DESKTOP'};
    }
    final families = targetedDeviceFamily;
    if (families == null) {
      return null;
    }
    final parts = families
        .split(',')
        .map((f) => f.trim())
        .where((f) => f.isNotEmpty)
        .toSet();
    return {
      if (parts.contains('1')) 'APP_IPHONE_67',
      if (parts.contains('2')) 'APP_IPAD_PRO_3GEN_129',
    };
  }

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

  /// Why [bundleIdFor] gave nothing, when there is more to say than "nothing".
  ///
  /// Null when the project simply has no identifier to read, because the
  /// caller's own message already covers that. A sentence when the project has
  /// several, or one it cannot read — those are not missing flags and should
  /// not be reported as though they were.
  String? bundleIdProblemFor(String platform) =>
      platform == 'macos' ? macosBundleIdProblem : iosBundleIdProblem;

  /// The app's bundle identifier, or why there is not one.
  ///
  /// The RunnerTests target carries its own and is skipped. Everything left has
  /// to agree. This used to return the first match, which is right only when
  /// the project has a single identifier to give, and two real projects showed
  /// that it does not always: one puts an app extension's target first, so the
  /// first match was the appex rather than the app, and another interpolates
  /// `design.codeux.howitwent$(BUNDLE_ID_SUFFIX)`, which Xcode expands at build
  /// time and this can only read as text. Each would have talked to Apple about
  /// an identifier nobody chose.
  ///
  /// A refusal carries its own sentence rather than returning a bare null,
  /// because a bare null reaches the caller as "pass --bundle-id" — which reads
  /// as *you forgot a flag* when the truth is *your project cannot be read as
  /// one*. Absent is the exception and stays null: a project with no iOS target
  /// is ordinary, and "none could be read" is already what the caller says.
  static ({String? value, String? problem}) _bundleId(
    String? pbxproj,
    String where,
  ) {
    if (pbxproj == null) {
      return (value: null, problem: null);
    }
    final found = _distinct(
      pbxproj,
      RegExp(r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;]+);'),
      skip: (value) =>
          value.contains('RunnerTests') || value.endsWith('.RunnerTests'),
    );
    if (found.isEmpty) {
      return (value: null, problem: null);
    }
    if (found.length > 1) {
      return (
        value: null,
        problem:
            '$where names ${found.length} bundle identifiers '
            '(${found.join(', ')}), so none of them can be assumed to be the '
            "app's — pass --bundle-id to choose",
      );
    }
    final only = found.single;
    if (only.contains(r'$(')) {
      return (
        value: null,
        problem:
            "PRODUCT_BUNDLE_IDENTIFIER in $where is '$only', which Xcode "
            'expands at build time and this can only read as text — pass '
            '--bundle-id',
      );
    }
    return (value: only, problem: null);
  }

  /// The team id, or why there is not one.
  ///
  /// Ignores the empty assignment Xcode writes for a target that has none —
  /// `DEVELOPMENT_TEAM = "";` is how a project says *unset*, and reading it as
  /// a team would make every certificate belong to the wrong one.
  ///
  /// Disagreement is refused for the same reason as [_bundleId], and the case
  /// is real rather than theoretical: manual signing configurations can carry a
  /// different team per build configuration. A wrong team exports somebody
  /// else's identity, or nothing, and the failure surfaces much later as a
  /// profile mismatch that never mentions the team.
  static ({String? value, String? problem}) _developmentTeam(
    String? pbxproj,
    String where,
  ) {
    if (pbxproj == null) {
      return (value: null, problem: null);
    }
    final found = _distinct(
      pbxproj,
      RegExp(r'DEVELOPMENT_TEAM\s*=\s*([^;]+);'),
      skip: (value) => value.isEmpty,
    );
    if (found.isEmpty) {
      return (value: null, problem: null);
    }
    if (found.length > 1) {
      return (
        value: null,
        problem:
            '$where names ${found.length} development teams '
            '(${found.join(', ')}) — pass --team to choose',
      );
    }
    return (value: found.single, problem: null);
  }

  /// `TARGETED_DEVICE_FAMILY`, or why there is not one.
  ///
  /// Refuses disagreement for the same reason [_bundleId] and
  /// [_developmentTeam] do, and the multi-target shape is the same one: a test
  /// target or an app extension carries its own, and taking the first match
  /// would answer a question about the app with a value belonging to something
  /// else. Here the consequence is a screenshot set required or not required
  /// wrongly, and the App Store says so at submission rather than at upload.
  ///
  /// Test targets are skipped by name, as they are for the bundle identifier.
  /// Anything left has to agree.
  static ({String? value, String? problem}) _targetedDeviceFamily(
    String? pbxproj,
    String where,
  ) {
    if (pbxproj == null) {
      return (value: null, problem: null);
    }
    final found = _distinct(
      pbxproj,
      RegExp(r'TARGETED_DEVICE_FAMILY\s*=\s*([^;]+);'),
      // A device family is digits and commas. Anything else is an Xcode
      // variable this can only read as text, and reading `$(INHERITED)` as a
      // family would silently require the wrong screenshots.
      skip: (value) => value.isEmpty || !RegExp(r'^[\d,\s]+$').hasMatch(value),
    );
    if (found.isEmpty) {
      return (value: null, problem: null);
    }
    if (found.length > 1) {
      return (
        value: null,
        problem:
            '$where names ${found.length} device families '
            '(${found.join(', ')}), so which screenshots are required cannot '
            'be derived — declare appstore.screenshots.ios instead',
      );
    }
    return (value: found.single, problem: null);
  }

  /// Distinct captures of [pattern], in the order the file gives them.
  static List<String> _distinct(
    String text,
    RegExp pattern, {
    required bool Function(String) skip,
  }) {
    final found = <String>[];
    for (final match in pattern.allMatches(text)) {
      final value = match.group(1)!.trim().replaceAll('"', '');
      if (skip(value) || found.contains(value)) {
        continue;
      }
      found.add(value);
    }
    return found;
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
