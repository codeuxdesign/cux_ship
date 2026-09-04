// SPDX-License-Identifier: Apache-2.0
//
// The App Store reads as objects, for a Dart caller that would otherwise be
// matching regular expressions against this command's stdout.
//
// **The printed lines are derived from these objects, not the other way
// round.** [printBuilds] and [printVersions] render [AppStoreBuilds.lines] and
// [AppStoreVersions.lines]; there is one
// description of what a build listing looks like and both the CLI and a
// library caller get it. That matters more than it sounds: a consumer that
// prints a store's own output verbatim — because a `status` that re-renders
// the table misreports the day the format changes, silently — needs those
// lines to be the same lines, and a second formatter beside the first is a
// second thing to drift.
//
// Reads only. Nothing here can write, and that is structural rather than a
// promise: the [Writer] an [AppStoreReads] session builds is a dry-run writer,
// so the write path is refused at the one place every write goes through.
import 'dart:io';

import 'app_store.dart';
import 'asc_client.dart';

/// `attributes` off a JSON:API resource, empty when a sparse fieldset left it
/// out. The same shape as the private helper in app_store.dart; duplicated
/// rather than exported, because a public `attributes()` on the package
/// surface is a promise about Apple's wire format.
Map<String, dynamic> _attributes(Map<String, dynamic> resource) =>
    (resource['attributes'] as Map<String, dynamic>?) ?? const {};

/// One build App Store Connect holds.
class AppStoreBuild {
  const AppStoreBuild({
    required this.buildNumber,
    required this.processingState,
    required this.uploadedDate,
    required this.uploadedAt,
    required this.expired,
  });

  /// `CFBundleVersion` — Apple calls this attribute `version`, which reads
  /// backwards and is the single easiest thing to get wrong here. It is the
  /// build number, not the marketing version.
  final String buildNumber;

  /// `PROCESSING`, `VALID`, `FAILED` or `INVALID`, or null when the response
  /// did not carry it.
  final String? processingState;

  /// Apple's `uploadedDate` exactly as sent.
  ///
  /// Kept beside [uploadedAt] because [lines] renders this one: Apple's
  /// offset-bearing spelling and `DateTime.toIso8601String` are not the same
  /// string, and the printed output is something a consumer shows verbatim.
  final String? uploadedDate;

  /// [uploadedDate] parsed, or null when it was absent or unparseable.
  final DateTime? uploadedAt;

  /// TestFlight builds expire after 90 days. An expired build is still listed
  /// and can no longer be given to a group.
  final bool expired;

  /// [buildNumber] read as an integer, or null when it is not one.
  ///
  /// **The form to compare and to order by.** A build number is a string here
  /// because `CFBundleVersion` is one and Apple will accept `1.2.3`, but
  /// comparing two of them as strings is wrong the moment they differ in
  /// width: `"9"` sorts above `"10"`. That mistake has now been made twice
  /// against this data — once inside this package, where the build listing
  /// trusted Apple's lexical `sort=-version` while `build-number` sorted
  /// numerically beside it, and once in a consumer comparing
  /// [AppStoreBuilds.newestBuildNumber] against an integer out of a git tag.
  /// Both were invisible while every build number had the same number of
  /// digits, and both would have surfaced at 1000.
  ///
  /// Null rather than a fallback, so a version string that is not a single
  /// integer is a case the caller has to answer rather than one silently
  /// ordered as zero.
  int? get buildNumberAsInt => int.tryParse(buildNumber);

  /// Whether this build could be promoted or released now.
  ///
  /// The same rule `appstore build-number` applies, in one place so the two
  /// cannot disagree: processed, and not yet expired.
  bool get usable => processingState == 'VALID' && !expired;

  /// The line `cux_ship appstore builds` prints for this build.
  String get line =>
      '  build $buildNumber  '
      '$processingState  '
      'uploaded $uploadedDate'
      '${expired ? '  (expired)' : ''}';
}

/// Every build App Store Connect holds for one app on one platform.
class AppStoreBuilds {
  const AppStoreBuilds({required this.platform, required this.builds});

  /// Which platform was asked. iOS and macOS builds of the same commit carry
  /// the *same* build number, so a listing that does not name its platform is
  /// ambiguous in exactly the case that matters.
  final AscPlatform platform;

  /// Newest first, by build number read as an integer.
  ///
  /// **Not the order Apple returned.** Apple's `sort=-version` is lexical, so
  /// build 9 comes back above build 10, and this package has always sorted
  /// numerically before answering "the newest" — it just did it in
  /// `build-number` and not in the listing beside it, which is how the two
  /// could name different builds.
  final List<AppStoreBuild> builds;

  /// The newest build Apple holds, whatever state it is in.
  ///
  /// This is the answer to "which build does the store have", and it is not
  /// the same question as [newestUsable]: a build uploaded four minutes ago is
  /// the newest and is not yet releasable.
  AppStoreBuild? get newest => builds.isEmpty ? null : builds.first;

  /// [newest]'s build number.
  ///
  /// **Do not compare this against another build number as a string** — use
  /// [AppStoreBuild.buildNumberAsInt], via [newest], which says why. Kept as a
  /// string because that is what the listing prints and what a caller
  /// reporting "the store holds 2132" wants; the comparison is a different
  /// job with a different type.
  String? get newestBuildNumber => newest?.buildNumber;

  /// The newest build that could be promoted or released now, or null.
  AppStoreBuild? get newestUsable {
    for (final build in builds) {
      if (build.usable) {
        return build;
      }
    }
    return null;
  }

  /// [buildNumber]'s build, or null when Apple does not hold it.
  AppStoreBuild? build(String buildNumber) {
    for (final build in builds) {
      if (build.buildNumber == buildNumber) {
        return build;
      }
    }
    return null;
  }

  /// Exactly what `cux_ship appstore builds` prints, for a caller that shows
  /// the store's own output rather than re-rendering it.
  ///
  /// Twenty at most, which is the listing's limit and not [builds]': the
  /// printed form is for reading and the list is for answering questions.
  List<String> get lines {
    if (builds.isEmpty) {
      return const ['  no builds at all — nothing has ever been uploaded'];
    }
    return <String>[
      for (final build in builds.take(20)) ...[build.line],
    ];
  }
}

/// The comparator `appstore build-number` has always used, extracted so the
/// listing sorts the same way.
///
/// Reads through [AppStoreBuild.buildNumberAsInt] rather than parsing again,
/// so the rule this package orders by and the rule it hands a caller are the
/// same rule. `-1` for anything that is not an integer: a sort that throws on
/// a surprise is a read that fails rather than one that answers, and sorting
/// such a build last is the only ordering that says nothing false about it.
int _byBuildNumberDescending(AppStoreBuild a, AppStoreBuild b) =>
    (b.buildNumberAsInt ?? -1).compareTo(a.buildNumberAsInt ?? -1);

/// One `builds` resource, as sent.
AppStoreBuild appStoreBuildFrom(Map<String, dynamic> resource) {
  final attributes = _attributes(resource);
  final uploadedDate = attributes['uploadedDate'] as String?;
  return AppStoreBuild(
    buildNumber: '${attributes['version']}',
    processingState: attributes['processingState'] as String?,
    uploadedDate: uploadedDate,
    uploadedAt: uploadedDate == null ? null : DateTime.tryParse(uploadedDate),
    expired: attributes['expired'] == true,
  );
}

/// A `GET /v1/builds` payload, sorted newest first.
AppStoreBuilds appStoreBuildsFrom(
  List<Map<String, dynamic>> payload,
  AscPlatform platform,
) {
  final builds = payload.map(appStoreBuildFrom).toList()
    ..sort(_byBuildNumberDescending);
  return AppStoreBuilds(platform: platform, builds: builds);
}

/// One App Store version record.
class AppStoreVersion {
  const AppStoreVersion({
    required this.versionString,
    required this.appStoreState,
    required this.releaseType,
    required this.copyright,
  });

  /// The marketing version — `1.4.0`, not a build number.
  final String versionString;

  /// `PREPARE_FOR_SUBMISSION`, `WAITING_FOR_REVIEW`, `READY_FOR_SALE` and the
  /// rest, or null when the response did not carry it.
  final String? appStoreState;

  /// `MANUAL`, `AFTER_APPROVAL` or `SCHEDULED`, or null.
  final String? releaseType;

  /// Required before review and null by default.
  final String? copyright;

  /// Whether a push against this version would be accepted, by the rule
  /// [editableVersionStates] states.
  bool get editable =>
      appStoreState != null && editableVersionStates.contains(appStoreState);

  /// The two lines `cux_ship appstore versions` prints for this version.
  List<String> get lines => <String>[
    '  $versionString  $appStoreState  $releaseType',
    // Printed because it is required before review and null by default, and
    // because a run that reports having written it is not evidence Apple
    // kept it.
    '    copyright: ${copyright ?? "(unset)"}',
  ];
}

/// The App Store version records for one app on one platform.
class AppStoreVersions {
  const AppStoreVersions({required this.platform, required this.versions});

  final AscPlatform platform;

  /// In the order Apple returned them, which is newest first in practice and
  /// is not promised by the API.
  final List<AppStoreVersion> versions;

  /// The version record for [versionString], or null.
  AppStoreVersion? version(String versionString) {
    for (final version in versions) {
      if (version.versionString == versionString) {
        return version;
      }
    }
    return null;
  }

  /// Exactly what `cux_ship appstore versions` prints.
  List<String> get lines {
    if (versions.isEmpty) {
      return <String>['  no App Store versions for ${platform.api}'];
    }
    return <String>[for (final version in versions) ...version.lines];
  }
}

/// One `appStoreVersions` resource, as sent.
AppStoreVersion appStoreVersionFrom(Map<String, dynamic> resource) {
  final attributes = _attributes(resource);
  return AppStoreVersion(
    versionString: '${attributes['versionString']}',
    appStoreState: attributes['appStoreState'] as String?,
    releaseType: attributes['releaseType'] as String?,
    copyright: attributes['copyright'] as String?,
  );
}

/// An `appStoreVersions` payload.
AppStoreVersions appStoreVersionsFrom(
  List<Map<String, dynamic>> payload,
  AscPlatform platform,
) => AppStoreVersions(
  platform: platform,
  versions: payload.map(appStoreVersionFrom).toList(),
);

/// `cux_ship appstore builds`.
///
/// A free function rather than a method on [AppStore], and deliberately: the
/// arrow points one way, from what the API can be asked to do towards how a
/// listing is rendered, and [AppStore] therefore does not import this file.
Future<void> printBuilds(AppStore store, App app) async {
  final listing = appStoreBuildsFrom(await store.builds(app), store.platform);
  for (final line in listing.lines) {
    stdout.writeln(line);
  }
}

/// `cux_ship appstore versions`.
Future<void> printVersions(AppStore store, App app) async {
  final listing = appStoreVersionsFrom(
    await store.appStoreVersions(app),
    store.platform,
  );
  for (final line in listing.lines) {
    stdout.writeln(line);
  }
}

/// A read-only App Store Connect session for one app on one platform.
///
/// One session per platform, because that is how App Store Connect answers:
/// builds and versions are per-platform, and an iOS and a macOS build of the
/// same commit carry the same build number, so a query that does not name the
/// platform cannot tell them apart.
///
///     final reads = await AppStoreReads.open(
///       bundleId: 'design.codeux.example',
///       platform: AscPlatform.ios,
///     );
///     try {
///       final builds = await reads.builds();
///       for (final line in builds.lines) {
///         log.writeln(line);
///       }
///       print(builds.newestBuildNumber);
///     } finally {
///       reads.close();
///     }
///
/// Credentials come from the environment `cux_ship secrets exec` sets up —
/// `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID` and
/// `APPLE_API_PRIVATE_KEY_PATH`. In-process reads therefore need those
/// variables in the *calling* process, which is the one thing a caller
/// switching from a spawned `cux_ship` to this has to arrange.
class AppStoreReads {
  AppStoreReads._(this._client, this._store, this._app, this.platform);

  /// Resolves [bundleId] and holds the session open.
  ///
  /// Throws [StateError] when no credentials are configured, and
  /// [AscApiException] when Apple has no app with that exact bundle id.
  static Future<AppStoreReads> open({
    required String bundleId,
    required AscPlatform platform,
  }) async {
    final credentials = AscCredentials.fromEnvironment();
    if (credentials == null) {
      throw StateError(
        'no App Store Connect credentials. APPLE_API_KEY_ID, '
        'APPLE_API_ISSUER_ID and APPLE_API_PRIVATE_KEY_PATH are not set in '
        'this process. Run it through `cux_ship secrets exec`, which writes '
        'the key file and sets all three, or export them yourself.',
      );
    }
    final client = AscClient(credentials);
    // **dryRun is not a mode here, it is the guarantee.** Every write in this
    // package goes through a [Writer], so a session whose writer refuses
    // cannot write however it is later extended.
    final store = AppStore(
      client,
      Writer(client, dryRun: true),
      platform: platform,
    );
    try {
      final app = await store.resolveApp(bundleId);
      return AppStoreReads._(client, store, app, platform);
    } on Object {
      client.close();
      rethrow;
    }
  }

  final AscClient _client;
  final AppStore _store;
  final App _app;

  /// The platform this session was opened for.
  final AscPlatform platform;

  /// App Store Connect's own id for the app, as `appstore` prints it.
  String get appId => _app.id;

  /// The app's name in App Store Connect.
  String get appName => _app.name;

  /// The bundle id this session resolved.
  String get bundleId => _app.bundleId;

  /// What `cux_ship appstore builds` reads.
  Future<AppStoreBuilds> builds() async =>
      appStoreBuildsFrom(await _store.builds(_app), platform);

  /// What `cux_ship appstore versions` reads.
  Future<AppStoreVersions> versions() async =>
      appStoreVersionsFrom(await _store.appStoreVersions(_app), platform);

  /// Waits until Apple has finished processing [buildNumber].
  ///
  /// What `cux_ship appstore wait` does, without the printing: [onProgress] is
  /// called once per poll — including the poll that ends the wait — so a
  /// caller streaming to a log can write its own heartbeat rather than
  /// scraping one. Passing no [onProgress] waits silently.
  ///
  /// Throws [ProcessingTimeout] when [timeout] runs out, and
  /// [AscApiException] when Apple reports `FAILED` or `INVALID`.
  Future<AppStoreBuild> awaitBuild(
    String buildNumber, {
    Duration timeout = const Duration(minutes: 45),
    Duration poll = const Duration(seconds: 30),
    void Function(BuildProcessingProgress progress)? onProgress,
  }) async {
    final build = await _store.awaitProcessing(
      _app,
      buildNumber,
      timeout: timeout,
      poll: poll,
      onProgress: onProgress ?? (_) {},
    );
    return appStoreBuildFrom(build);
  }

  /// Releases the HTTP client. A session that is not closed keeps a connection
  /// pool alive, which is what stops a long-running process from exiting.
  void close() => _client.close();
}
