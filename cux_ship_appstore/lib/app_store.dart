// SPDX-License-Identifier: Apache-2.0

// What the App Store Connect API can be asked to do, expressed once.
//
// Sits between lib/asc_client.dart, which knows about JWTs and JSON:API but
// nothing about apps, and bin/asc_upload.dart, which decides what a run should
// do but should not be assembling relationship documents inline.
//
// Every write goes through [Writer], which is the only thing that knows about
// --dry-run. That indirection exists because App Store Connect has no edit
// transaction: there is nothing to open and discard, so "rehearse it" can only
// mean "do every read, print every write, perform none of them". Routing all
// writes through one place is what makes that claim checkable rather than a
// promise spread across twenty call sites.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'asc_client.dart';
import 'metadata.dart';

/// The `platform` App Store Connect wants, which is not spelled the way the
/// rest of this repository spells platforms.
enum AscPlatform {
  ios('IOS', 'ios'),
  macos('MAC_OS', 'macos');

  const AscPlatform(this.api, this.changelog);

  /// `IOS` / `MAC_OS`, as the API spells it.
  final String api;

  /// `ios` / `macos`, as CHANGELOG.md prefixes spell it.
  final String changelog;

  /// `--type` for `xcrun altool`.
  String get altoolType => this == AscPlatform.ios ? 'ios' : 'macos';

  static AscPlatform byName(String name) => switch (name) {
    'ios' => AscPlatform.ios,
    'macos' => AscPlatform.macos,
    _ => throw ArgumentError('unknown platform: $name'),
  };
}

/// The states in which App Store Connect will still let a version be edited.
///
/// Anything else means the version is with Apple or already public, and a push
/// against it is rejected field by field with no indication that the *version*
/// was the problem. Checking up front turns that into one clear sentence.
const editableVersionStates = {
  'PREPARE_FOR_SUBMISSION',
  'DEVELOPER_REJECTED',
  'REJECTED',
  'METADATA_REJECTED',
  'INVALID_BINARY',
};

/// Performs writes, or describes them and does nothing.
class Writer {
  Writer(this.client, {required this.dryRun});

  final AscClient client;
  final bool dryRun;

  /// Set when a dry run skipped a write whose result later runs would need —
  /// creating a version, say. Callers use it to explain why a subsequent step
  /// is being skipped rather than reporting a confusing absence.
  bool skippedACreate = false;

  Future<Map<String, dynamic>?> post(
    String path,
    Map<String, dynamic> body, {
    required String describe,
  }) async {
    if (dryRun) {
      stdout.writeln('    would create: $describe');
      skippedACreate = true;
      return null;
    }
    stdout.writeln('    $describe');
    return client.post(path, body);
  }

  Future<Map<String, dynamic>?> patch(
    String path,
    Map<String, dynamic> body, {
    required String describe,
  }) async {
    if (dryRun) {
      stdout.writeln('    would update: $describe');
      return null;
    }
    stdout.writeln('    $describe');
    return client.patch(path, body);
  }

  Future<void> delete(String path, {required String describe}) async {
    if (dryRun) {
      stdout.writeln('    would delete: $describe');
      return;
    }
    stdout.writeln('    $describe');
    await client.delete(path);
  }
}

/// Builds a JSON:API `relationships` entry.
Map<String, dynamic> relation(String type, String id) => {
  'data': {'type': type, 'id': id},
};

String? _id(Map<String, dynamic> resource) {
  final id = resource['id'];
  return id is String ? id : null;
}

Map<String, dynamic> _attributes(Map<String, dynamic> resource) {
  final attributes = resource['attributes'];
  return attributes is Map<String, dynamic> ? attributes : const {};
}

/// An app record, which is the one thing in this whole pipeline that a human
/// had to create by hand — `POST /v1/apps` does not exist.
class App {
  App(this.id, this.name, this.bundleId);

  final String id;
  final String name;
  final String bundleId;
}

class AppStore {
  AppStore(this.client, this.writer, {required this.platform});

  final AscClient client;
  final Writer writer;
  final AscPlatform platform;

  Future<App> resolveApp(String bundleId) async {
    final apps = await client.getAll(
      '/v1/apps',
      query: {'filter[bundleId]': bundleId},
    );
    if (apps.isEmpty) {
      throw AscApiException(404, [
        'no app with bundle id "$bundleId".',
        'Either the app record has not been created yet — it cannot be created '
            'over the API, see docs/RELEASING-APPLE.md §1.3 — or this API key '
            'cannot see it.',
      ], request: 'GET /v1/apps');
    }
    // filter[bundleId] is a prefix match on Apple's side, so an app called
    // ...holdthewheel.beta would come back alongside the real one.
    final exact = apps.where((a) => _attributes(a)['bundleId'] == bundleId);
    if (exact.isEmpty) {
      throw AscApiException(404, [
        'no app exactly matching "$bundleId"; the API returned '
            '${apps.map((a) => _attributes(a)['bundleId']).join(", ")}',
      ], request: 'GET /v1/apps');
    }
    final app = exact.first;
    return App(
      _id(app)!,
      _attributes(app)['name'] as String? ?? '(unnamed)',
      bundleId,
    );
  }

  // ------------------------------------------------------------------ builds

  /// Every build App Store Connect holds for [app] on this platform, newest
  /// first.
  Future<List<Map<String, dynamic>>> builds(App app) async {
    final builds = await client.getAll(
      '/v1/builds',
      query: {'filter[app]': app.id, 'sort': '-version', 'limit': '200'},
    );
    return builds;
  }

  /// The build carrying [buildNumber] as its `CFBundleVersion`, or null.
  ///
  /// Apple's `filter[version]` on builds is the build number rather than the
  /// marketing version, which reads backwards and is the single easiest thing
  /// to get wrong here.
  Future<Map<String, dynamic>?> findBuild(App app, String buildNumber) async {
    final found = await client.getAll(
      '/v1/builds',
      query: {'filter[app]': app.id, 'filter[version]': buildNumber},
    );
    return found.isEmpty ? null : found.first;
  }

  /// Waits until Apple has finished processing [buildNumber] and returns it.
  ///
  /// Processing takes 5–15 minutes and a build cannot be attached to anything
  /// until it finishes, so a tool that uploaded and exited would report success
  /// for something testers cannot yet install. `FAILED` and `INVALID` are
  /// terminal and are raised rather than waited out.
  Future<Map<String, dynamic>> awaitProcessing(
    App app,
    String buildNumber, {
    Duration timeout = const Duration(minutes: 45),
    Duration poll = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    var announced = false;
    while (true) {
      final build = await findBuild(app, buildNumber);
      final state = build == null
          ? null
          : _attributes(build)['processingState'] as String?;

      if (state == 'VALID') {
        stdout.writeln('==> build $buildNumber has finished processing');
        return build!;
      }
      if (state == 'FAILED' || state == 'INVALID') {
        throw AscApiException(422, [
          'build $buildNumber came back $state from Apple\'s processing.',
          'The reason is only in the e-mail Apple sends and in the Activity '
              'tab; the API does not carry it.',
        ], request: 'GET /v1/builds');
      }
      if (DateTime.now().isAfter(deadline)) {
        throw AscApiException(504, [
          'build $buildNumber was still ${state ?? "not visible"} after '
              '${timeout.inMinutes} minutes.',
          'It is not lost — re-run the upload step, which will find it rather '
              'than sending the .ipa again.',
        ], request: 'GET /v1/builds');
      }
      if (!announced) {
        stdout.writeln(
          '==> waiting for Apple to process build $buildNumber '
          '(usually 5–15 minutes)',
        );
        announced = true;
      }
      await Future<void>.delayed(poll);
    }
  }

  /// Sets the TestFlight "What to Test" note for a build.
  Future<void> setWhatToTest(
    Map<String, dynamic> build,
    String locale,
    String text,
  ) async {
    final buildId = _id(build)!;
    final existing = await client.getAll(
      '/v1/betaBuildLocalizations',
      query: {'filter[build]': buildId, 'filter[locale]': locale},
    );
    if (existing.isEmpty) {
      await writer.post('/v1/betaBuildLocalizations', {
        'data': {
          'type': 'betaBuildLocalizations',
          'attributes': {'locale': locale, 'whatsNew': text},
          'relationships': {'build': relation('builds', buildId)},
        },
      }, describe: 'what to test ($locale)');
    } else {
      await writer.patch(
        '/v1/betaBuildLocalizations/${_id(existing.first)}',
        {
          'data': {
            'type': 'betaBuildLocalizations',
            'id': _id(existing.first),
            'attributes': {'whatsNew': text},
          },
        },
        describe: 'what to test ($locale)',
      );
    }
  }

  /// Adds a build to a named beta group, so testers actually receive it.
  ///
  /// An internal group needs no review and is available within minutes, which
  /// is the closest thing the App Store has to Play's internal track.
  Future<void> addToBetaGroup(
    App app,
    Map<String, dynamic> build,
    String groupName,
  ) async {
    final groups = await client.getAll(
      '/v1/betaGroups',
      query: {'filter[app]': app.id, 'filter[name]': groupName},
    );
    if (groups.isEmpty) {
      throw AscApiException(404, [
        'no beta group called "$groupName".',
        'Create it once in App Store Connect > TestFlight > Groups, or pass '
            '--beta-group with a name that exists. Groups cannot be created '
            'over the API.',
      ], request: 'GET /v1/betaGroups');
    }
    await writer.post(
      '/v1/betaGroups/${_id(groups.first)}/relationships/builds',
      {
        'data': [
          {'type': 'builds', 'id': _id(build)},
        ],
      },
      describe: 'added to beta group "$groupName"',
    );
  }

  // ---------------------------------------------------------------- versions

  /// The App Store version record for [versionString], created if absent.
  ///
  /// Returns null only on a dry run that would have had to create one.
  Future<Map<String, dynamic>?> ensureVersion(
    App app,
    String versionString, {
    required bool create,
  }) async {
    final versions = await client.getAll(
      '/v1/apps/${app.id}/appStoreVersions',
      query: {
        'filter[platform]': platform.api,
        'filter[versionString]': versionString,
      },
    );
    if (versions.isNotEmpty) {
      final version = versions.first;
      final state = _attributes(version)['appStoreState'] as String?;
      if (state != null && !editableVersionStates.contains(state)) {
        throw AscApiException(409, [
          'version $versionString is $state, which cannot be edited.',
          if (state == 'READY_FOR_SALE')
            'It is already on the App Store. Release a new version instead.'
          else
            'It is with Apple. Cancel the submission in App Store Connect to '
                'edit it again.',
        ], request: 'GET /v1/appStoreVersions');
      }
      return version;
    }

    if (!create) {
      throw AscApiException(404, [
        'no App Store version $versionString for ${platform.api}',
      ], request: 'GET /v1/appStoreVersions');
    }

    // Apple allows exactly one editable version at a time, and it creates a
    // "1.0" the moment the app record exists. So the first release almost
    // always finds an editable version under the wrong name, and creating a
    // second one is rejected — the console renames instead, and so does this.
    //
    // Only the version string is touched. releaseType and anything else set in
    // the console is left alone, because adopting a version is not a licence to
    // overwrite decisions made about it.
    final all = await client.getAll(
      '/v1/apps/${app.id}/appStoreVersions',
      query: {'filter[platform]': platform.api},
    );
    final editable = all.where((v) {
      final state = _attributes(v)['appStoreState'] as String?;
      return state != null && editableVersionStates.contains(state);
    }).toList();

    if (editable.isNotEmpty) {
      final existing = editable.first;
      final was = _attributes(existing)['versionString'];
      final renamed = await writer.patch(
        '/v1/appStoreVersions/${_id(existing)}',
        {
          'data': {
            'type': 'appStoreVersions',
            'id': _id(existing),
            'attributes': {'versionString': versionString},
          },
        },
        describe: 'renamed the editable version $was to $versionString',
      );
      if (renamed == null) {
        // Dry run: report the existing record, which is the one a real run
        // would have edited, so later steps describe the right thing.
        return existing;
      }
      final data = renamed['data'];
      return data is Map<String, dynamic> ? data : existing;
    }

    final created = await writer.post('/v1/appStoreVersions', {
      'data': {
        'type': 'appStoreVersions',
        'attributes': {
          'platform': platform.api,
          'versionString': versionString,
          // Manual: a release that goes live the instant Apple approves it
          // takes the decision away from whoever is watching. Play's
          // production track is equally a deliberate act.
          'releaseType': 'MANUAL',
        },
        'relationships': {'app': relation('apps', app.id)},
      },
    }, describe: 'App Store version $versionString');
    final data = created?['data'];
    return data is Map<String, dynamic> ? data : null;
  }

  /// Points an App Store version at a build App Store Connect already holds.
  ///
  /// This is the whole promotion mechanism, and the reason it is trustworthy:
  /// nothing is compiled or uploaded, so what goes to review is byte for byte
  /// the binary testers have been running.
  Future<void> attachBuild(
    Map<String, dynamic> version,
    Map<String, dynamic> build,
  ) async {
    await writer.patch(
      '/v1/appStoreVersions/${_id(version)}',
      {
        'data': {
          'type': 'appStoreVersions',
          'id': _id(version),
          'relationships': {'build': relation('builds', _id(build)!)},
        },
      },
      describe: 'attached build ${_attributes(build)['version']}',
    );
  }

  /// Writes the version's own attributes, as opposed to a locale's.
  ///
  /// `copyright` is required before Apple will review a version, and is null
  /// on a version it created itself — another of the fields whose absence is
  /// reported only as "this resource cannot be reviewed".
  Future<void> writeVersionAttributes(
    Map<String, dynamic> version,
    Map<String, String> attributes,
  ) async {
    if (attributes.isEmpty) {
      return;
    }
    await writer.patch('/v1/appStoreVersions/${_id(version)}', {
      'data': {
        'type': 'appStoreVersions',
        'id': _id(version),
        'attributes': attributes,
      },
    }, describe: attributes.keys.join(', '));
  }

  /// Writes one locale's version-scoped fields, including the release notes.
  Future<void> writeVersionLocalization(
    Map<String, dynamic> version,
    String locale,
    Map<String, String> attributes,
  ) async {
    if (attributes.isEmpty) {
      return;
    }
    final existing = await client.getAll(
      '/v1/appStoreVersions/${_id(version)}/appStoreVersionLocalizations',
    );
    final match = existing
        .where((l) => _attributes(l)['locale'] == locale)
        .toList();
    if (match.isEmpty) {
      await writer.post(
        '/v1/appStoreVersionLocalizations',
        {
          'data': {
            'type': 'appStoreVersionLocalizations',
            'attributes': {'locale': locale, ...attributes},
            'relationships': {
              'appStoreVersion': relation('appStoreVersions', _id(version)!),
            },
          },
        },
        describe: '$locale: ${attributes.keys.join(", ")}',
      );
    } else {
      await writer.patch(
        '/v1/appStoreVersionLocalizations/${_id(match.first)}',
        {
          'data': {
            'type': 'appStoreVersionLocalizations',
            'id': _id(match.first),
            'attributes': attributes,
          },
        },
        describe: '$locale: ${attributes.keys.join(", ")}',
      );
    }
  }

  /// Whether [version] is the first this app has ever had on this platform.
  ///
  /// Apple has no "What's New in This Version" for a first release — there is
  /// no previous version for it to be new against — and refuses a write to
  /// `whatsNew` with `Attribute 'whatsNew' cannot be edited at this time`,
  /// which does not say why. Checking first turns that into a skip with a
  /// reason.
  Future<bool> isFirstVersion(App app, Map<String, dynamic> version) async {
    final all = await client.getAll(
      '/v1/apps/${app.id}/appStoreVersions',
      query: {'filter[platform]': platform.api},
    );
    return all.every((v) => _id(v) == _id(version));
  }

  /// The `appStoreVersionLocalizations` record for [locale], or null.
  Future<Map<String, dynamic>?> versionLocalization(
    Map<String, dynamic> version,
    String locale,
  ) async {
    final all = await client.getAll(
      '/v1/appStoreVersions/${_id(version)}/appStoreVersionLocalizations',
    );
    for (final localization in all) {
      if (_attributes(localization)['locale'] == locale) {
        return localization;
      }
    }
    return null;
  }

  // ---------------------------------------------------------------- app info

  /// The editable `appInfos` record, which is where the name, subtitle,
  /// category and age rating live.
  ///
  /// An app always has at least one, and once a version is live it has two —
  /// the public one and the one being prepared. Writing to the wrong one
  /// silently edits what is already on the App Store.
  Future<Map<String, dynamic>> editableAppInfo(App app) async {
    final infos = await client.getAll('/v1/apps/${app.id}/appInfos');
    for (final info in infos) {
      final state = _attributes(info)['appStoreState'] as String?;
      if (state == null || editableVersionStates.contains(state)) {
        return info;
      }
    }
    if (infos.isEmpty) {
      throw AscApiException(404, [
        'the app has no appInfos record at all',
      ], request: 'GET /v1/appInfos');
    }
    throw AscApiException(409, [
      'every appInfos record is in a state that cannot be edited '
          '(${infos.map((i) => _attributes(i)['appStoreState']).join(", ")}).',
      'Create the next version first, or cancel the submission in App Store '
          'Connect.',
    ], request: 'GET /v1/appInfos');
  }

  /// Declares whether the app carries third-party content.
  ///
  /// An attribute of the app rather than of a version, so it is written once
  /// and outlives every release. Apple will not review a version while it is
  /// null, and says so only as "this resource cannot be reviewed".
  Future<void> writeContentRights(App app, String declaration) async {
    await writer.patch('/v1/apps/${app.id}', {
      'data': {
        'type': 'apps',
        'id': app.id,
        'attributes': {'contentRightsDeclaration': declaration},
      },
    }, describe: 'content rights: $declaration');
  }

  Future<void> writeCategories(
    Map<String, dynamic> appInfo,
    Map<String, String> categories,
  ) async {
    if (categories.isEmpty) {
      return;
    }
    final relationships = <String, dynamic>{
      for (final entry in categories.entries)
        entry.key: relation('appCategories', entry.value),
    };
    await writer.patch(
      '/v1/appInfos/${_id(appInfo)}',
      {
        'data': {
          'type': 'appInfos',
          'id': _id(appInfo),
          'relationships': relationships,
        },
      },
      describe: 'categories: ${categories.values.join(", ")}',
    );
  }

  Future<void> writeAppInfoLocalization(
    Map<String, dynamic> appInfo,
    String locale,
    Map<String, String> attributes,
  ) async {
    if (attributes.isEmpty) {
      return;
    }
    final existing = await client.getAll(
      '/v1/appInfos/${_id(appInfo)}/appInfoLocalizations',
    );
    final match = existing
        .where((l) => _attributes(l)['locale'] == locale)
        .toList();
    if (match.isEmpty) {
      await writer.post(
        '/v1/appInfoLocalizations',
        {
          'data': {
            'type': 'appInfoLocalizations',
            'attributes': {'locale': locale, ...attributes},
            'relationships': {'appInfo': relation('appInfos', _id(appInfo)!)},
          },
        },
        describe: '$locale: ${attributes.keys.join(", ")}',
      );
    } else {
      await writer.patch(
        '/v1/appInfoLocalizations/${_id(match.first)}',
        {
          'data': {
            'type': 'appInfoLocalizations',
            'id': _id(match.first),
            'attributes': attributes,
          },
        },
        describe: '$locale: ${attributes.keys.join(", ")}',
      );
    }
  }

  /// Pushes the age rating answers, which are a sub-resource of appInfos.
  ///
  /// The App Store analogue of `store/play/data-safety.csv`: owned by the
  /// repository, re-asserted on every push, and overwritten rather than merged.
  Future<void> writeAgeRating(
    Map<String, dynamic> appInfo,
    Map<String, Object?> declaration,
  ) async {
    final info = await client.get(
      '/v1/appInfos/${_id(appInfo)}',
      query: {'include': 'ageRatingDeclaration'},
    );
    final included = info['included'];
    String? declarationId;
    if (included is List) {
      for (final resource in included.whereType<Map<String, dynamic>>()) {
        if (resource['type'] == 'ageRatingDeclarations') {
          declarationId = _id(resource);
        }
      }
    }
    if (declarationId == null) {
      throw AscApiException(404, [
        'the app has no ageRatingDeclaration to write to',
      ], request: 'GET /v1/appInfos');
    }
    await writer.patch(
      '/v1/ageRatingDeclarations/$declarationId',
      {
        'data': {
          'type': 'ageRatingDeclarations',
          'id': declarationId,
          'attributes': declaration,
        },
      },
      describe: 'age rating (${declaration.length} answers)',
    );
  }

  // ------------------------------------------------------------- screenshots

  /// Replaces one display type's screenshots with the files in [files].
  ///
  /// Replaces rather than adds, for the same reason cux_ship_play clears an
  /// image type before re-uploading it: reserving a screenshot *appends*, so
  /// without this every release would leave the listing carrying another copy
  /// of the same images, and the repository would stop being the source of
  /// truth.
  Future<void> replaceScreenshots(
    Map<String, dynamic> localization,
    String displayType,
    List<File> files,
  ) async {
    final sets = await client.getAll(
      '/v1/appStoreVersionLocalizations/${_id(localization)}'
      '/appScreenshotSets',
    );
    final existing = sets
        .where((s) => _attributes(s)['screenshotDisplayType'] == displayType)
        .toList();

    String? setId;
    if (existing.isNotEmpty) {
      setId = _id(existing.first);
      await writer.delete(
        '/v1/appScreenshotSets/$setId',
        describe: 'cleared $displayType',
      );
      setId = null;
    }

    final created = await writer.post(
      '/v1/appScreenshotSets',
      {
        'data': {
          'type': 'appScreenshotSets',
          'attributes': {'screenshotDisplayType': displayType},
          'relationships': {
            'appStoreVersionLocalization': relation(
              'appStoreVersionLocalizations',
              _id(localization)!,
            ),
          },
        },
      },
      describe: '$displayType: ${files.length} screenshot(s)',
    );

    final data = created?['data'];
    if (data is! Map<String, dynamic>) {
      // Dry run, or a create that returned nothing useful. Either way there is
      // no set to upload into, and saying so beats a null dereference.
      return;
    }
    setId = _id(data);

    for (final file in files) {
      await _uploadScreenshot(setId!, file);
    }
  }

  /// Apple's three-step asset upload: reserve, PUT, commit.
  ///
  /// The commit is not a formality — a reserved-but-uncommitted screenshot
  /// occupies the slot and is never shown, so a run that uploaded bytes and
  /// stopped would leave a listing that looks empty and cannot be re-uploaded
  /// into cleanly.
  Future<void> _uploadScreenshot(String setId, File file) async {
    final bytes = file.readAsBytesSync();
    final name = file.uri.pathSegments.last;

    final reserved = await client.post('/v1/appScreenshots', {
      'data': {
        'type': 'appScreenshots',
        'attributes': {'fileSize': bytes.length, 'fileName': name},
        'relationships': {
          'appScreenshotSet': relation('appScreenshotSets', setId),
        },
      },
    });

    final data = reserved['data'];
    if (data is! Map<String, dynamic>) {
      throw StateError('reserving $name returned no resource');
    }
    final screenshotId = _id(data)!;
    final operations = _attributes(data)['uploadOperations'];
    if (operations is! List) {
      throw StateError('reserving $name returned no uploadOperations');
    }

    for (final operation in operations.whereType<Map<String, dynamic>>()) {
      final offset = operation['offset'];
      final length = operation['length'];
      if (offset is! int || length is! int) {
        throw StateError('upload operation for $name has no offset/length');
      }
      await client.uploadOperation(
        operation,
        bytes.sublist(offset, offset + length),
      );
    }

    // MD5 of the whole file, which is what Apple compares against what it
    // received. Not a security property — Apple picked the algorithm.
    await client.patch('/v1/appScreenshots/$screenshotId', {
      'data': {
        'type': 'appScreenshots',
        'id': screenshotId,
        'attributes': {
          'uploaded': true,
          'sourceFileChecksum': md5.convert(bytes).toString(),
        },
      },
    });
    stdout.writeln('      uploaded $name');
  }

  // -------------------------------------------------------------- submission

  /// Enables Apple's phased release for a version.
  ///
  /// Not a fraction, unlike Play's staged rollout: Apple's phased release is a
  /// fixed seven-day schedule it runs on its own, so there is nothing to
  /// choose beyond on or off.
  Future<void> enablePhasedRelease(Map<String, dynamic> version) async {
    await writer.post(
      '/v1/appStoreVersionPhasedReleases',
      {
        'data': {
          'type': 'appStoreVersionPhasedReleases',
          'attributes': {'phasedReleaseState': 'INACTIVE'},
          'relationships': {
            'appStoreVersion': relation('appStoreVersions', _id(version)!),
          },
        },
      },
      describe: 'phased release over seven days',
    );
  }

  /// Sends a version to review, in the three steps Apple now requires.
  ///
  /// `appStoreVersionSubmissions` did this in one call and is deprecated. The
  /// replacement is a container: create it, add each item, then flip
  /// `submitted`. The order is not negotiable — flipping it before adding an
  /// item answers 422.
  Future<void> submitForReview(App app, Map<String, dynamic> version) async {
    // An unsubmitted container from an earlier failed attempt blocks a new one,
    // and the error does not say so.
    final open = await client.getAll(
      '/v1/reviewSubmissions',
      query: {
        'filter[app]': app.id,
        'filter[platform]': platform.api,
        'filter[state]': 'READY_FOR_REVIEW',
      },
    );

    String? submissionId;
    if (open.isNotEmpty) {
      submissionId = _id(open.first);
      stdout.writeln('==> reusing the open review submission $submissionId');
    } else {
      final created = await writer.post('/v1/reviewSubmissions', {
        'data': {
          'type': 'reviewSubmissions',
          'attributes': {'platform': platform.api},
          'relationships': {'app': relation('apps', app.id)},
        },
      }, describe: 'review submission');
      final data = created?['data'];
      submissionId = data is Map<String, dynamic> ? _id(data) : null;
    }

    if (submissionId == null) {
      stdout.writeln(
        '    would then add version ${_attributes(version)['versionString']} '
        'and submit',
      );
      return;
    }

    await writer.post('/v1/reviewSubmissionItems', {
      'data': {
        'type': 'reviewSubmissionItems',
        'relationships': {
          'reviewSubmission': relation('reviewSubmissions', submissionId),
          'appStoreVersion': relation('appStoreVersions', _id(version)!),
        },
      },
    }, describe: 'added the version to the submission');

    await writer.patch('/v1/reviewSubmissions/$submissionId', {
      'data': {
        'type': 'reviewSubmissions',
        'id': submissionId,
        'attributes': {'submitted': true},
      },
    }, describe: 'submitted for review');
  }

  // ------------------------------------------------------------------- reads

  /// What App Store Connect actually holds, as opposed to what a previous run
  /// reported having sent.
  ///
  /// Worth having for the same reason `play_upload --list-tracks` is: a push
  /// reports what it sent, which is not evidence of what arrived.
  Future<void> listBuilds(App app) async {
    final all = await builds(app);
    if (all.isEmpty) {
      stdout.writeln('  no builds at all — nothing has ever been uploaded');
      return;
    }
    for (final build in all.take(20)) {
      final attributes = _attributes(build);
      stdout.writeln(
        '  build ${attributes['version']}  '
        '${attributes['processingState']}  '
        'uploaded ${attributes['uploadedDate']}'
        '${attributes['expired'] == true ? '  (expired)' : ''}',
      );
    }
  }

  Future<void> listVersions(App app) async {
    final versions = await client.getAll(
      '/v1/apps/${app.id}/appStoreVersions',
      query: {'filter[platform]': platform.api},
    );
    if (versions.isEmpty) {
      stdout.writeln('  no App Store versions for ${platform.api}');
      return;
    }
    for (final version in versions) {
      final attributes = _attributes(version);
      stdout.writeln(
        '  ${attributes['versionString']}  ${attributes['appStoreState']}  '
        '${attributes['releaseType']}',
      );
      // Printed because it is required before review and null by default, and
      // because a run that reports having written it is not evidence Apple
      // kept it.
      stdout.writeln('    copyright: ${attributes['copyright'] ?? "(unset)"}');
    }
  }

  /// The display types this app's current localizations already carry.
  ///
  /// The way to check a `ScreenshotDisplayType` name rather than guessing at
  /// it — Apple's published enum lags the console by months.
  Future<void> listScreenshotTypes(App app) async {
    final versions = await client.getAll(
      '/v1/apps/${app.id}/appStoreVersions',
      query: {'filter[platform]': platform.api},
    );
    if (versions.isEmpty) {
      stdout.writeln('  no versions yet, so no screenshot sets exist');
      return;
    }
    for (final version in versions.take(3)) {
      stdout.writeln('  ${_attributes(version)['versionString']}:');
      final localizations = await client.getAll(
        '/v1/appStoreVersions/${_id(version)}/appStoreVersionLocalizations',
      );
      for (final localization in localizations) {
        final sets = await client.getAll(
          '/v1/appStoreVersionLocalizations/${_id(localization)}'
          '/appScreenshotSets',
        );
        final types = sets
            .map((s) => _attributes(s)['screenshotDisplayType'])
            .join(', ');
        stdout.writeln(
          '    ${_attributes(localization)['locale']}: '
          '${types.isEmpty ? "(none)" : types}',
        );
      }
    }
    stdout.writeln(
      '  names this tool validates against: '
      '${screenshotSpecs.keys.join(", ")}',
    );
  }

  /// Prints the newest usable build number and nothing else, for tool/promote.sh.
  ///
  /// Bare stdout rather than the `==>` lines everything else uses, because the
  /// only caller is a shell script capturing it — the same arrangement
  /// `play_upload --print-version-code` has, and for the same reason: the
  /// release, the console and the git tag written afterwards must not end up
  /// describing three different builds.
  Future<void> printBuildNumber(App app) async {
    final all = await builds(app);
    final usable = all.where((b) {
      final attributes = _attributes(b);
      return attributes['processingState'] == 'VALID' &&
          attributes['expired'] != true;
    }).toList();
    if (usable.isEmpty) {
      throw AscApiException(404, [
        'no processed, unexpired build to promote',
      ], request: 'GET /v1/builds');
    }
    // Sorted numerically here rather than trusting the API's `-version` sort,
    // which is lexical: "9" sorts above "10".
    usable.sort((a, b) {
      final left = int.tryParse('${_attributes(a)['version']}') ?? -1;
      final right = int.tryParse('${_attributes(b)['version']}') ?? -1;
      return right.compareTo(left);
    });
    stdout.writeln(_attributes(usable.first)['version']);
  }
}

/// Hands the .ipa to Apple.
///
/// `xcrun altool` rather than a direct upload: the App Store Connect API has no
/// endpoint that accepts a binary, and the transport altool speaks is not
/// documented anywhere Apple publishes. This is the supported path, and it is
/// what Transporter and Xcode both use underneath.
///
/// `--upload-package` rather than `--upload-app`, which is deprecated. It wants
/// the app's numeric id and the version fields spelled out, all of which the
/// caller already knows.
Future<void> uploadPackage({
  required File ipa,
  required App app,
  required AscPlatform platform,
  required String versionName,
  required String buildNumber,
  required AscCredentials credentials,
  required bool dryRun,
}) async {
  final arguments = [
    'altool',
    '--upload-package',
    ipa.path,
    '--type',
    platform.altoolType,
    '--apple-id',
    app.id,
    '--bundle-id',
    app.bundleId,
    '--bundle-version',
    buildNumber,
    '--bundle-short-version-string',
    versionName,
    '--apiKey',
    credentials.keyId,
    // altool is not the REST API and does not follow its rules. Its own help
    // says "--api-issuer <id>  Issuer ID (required with --api-key)" — required
    // for an individual key too, even though that key's REST JWT must not name
    // an issuer. Omitting it fails with "Either JWT (--api-issuer and
    // --api-key) or username and app password ... is required".
    //
    // --api-key-subject is the other half of the trap: altool documents it as
    // "Set to 'user' when using non-ApiKey_ prefixed auth files", so it must
    // NOT be passed for the ApiKey_ file Apple hands out for an individual
    // key — altool reads that prefix itself.
    //
    // altool finds the .p8 by key id under ~/.appstoreconnect/private_keys and
    // the other locations it documents.
    if (credentials.issuerId case final issuer?) ...[
      '--apiIssuer',
      issuer,
    ],
    if (credentials.keyFileName case final name?
        when !name.startsWith('ApiKey_')) ...[
      '--api-key-subject',
      'user',
    ],
  ];

  if (dryRun) {
    stdout.writeln('    would upload: xcrun ${arguments.join(" ")}');
    return;
  }

  stdout.writeln('==> uploading ${ipa.lengthSync()} bytes with altool');
  final result = await Process.run('xcrun', arguments);
  stdout.write(result.stdout);
  if (result.exitCode != 0) {
    stderr.write(result.stderr);
    throw AscApiException(result.exitCode, [
      'altool refused the upload.',
      // altool reports a duplicate as ITMS-90189, which is not an error worth
      // failing a release for: the build number is allocated once per commit,
      // so Apple already holding it means Apple already holds this commit.
      if ('${result.stdout}${result.stderr}'.contains('ITMS-90189'))
        'Apple already holds this build number, which means this commit was '
            'already uploaded. Nothing to do.',
    ], request: 'xcrun altool --upload-package');
  }
}

/// Whether altool's output says Apple already has this build.
bool isDuplicateUpload(Object error) =>
    error is AscApiException &&
    error.details.any((d) => d.contains('already holds this build number'));

/// A stable JSON rendering, for the dry-run log.
String describeJson(Object? value) =>
    const JsonEncoder.withIndent('  ').convert(value);
