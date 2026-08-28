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
import 'package:cux_ship_verify/metadata.dart';

import '../release.dart' show ReleaseException;
import 'asc_client.dart';

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

/// Whether [group] is one of Apple's internal groups, which need no beta
/// review. Read from the resource rather than guessed from the name, because
/// the two kinds part ways completely: an internal group receives an assigned
/// build within minutes, an external one receives nothing until beta review.
bool isInternalBetaGroup(Map<String, dynamic> group) =>
    _attributes(group)['isInternalGroup'] == true;

Map<String, dynamic> _attributes(Map<String, dynamic> resource) {
  final attributes = resource['attributes'];
  return attributes is Map<String, dynamic> ? attributes : const {};
}

/// Who Apple contacts about a review, read from the environment.
///
/// **From the environment and not from the metadata tree, because one of the
/// projects using this package is a public repository.** Every other listing
/// field is a file beside `info/` and this one deliberately is not: a name, an
/// e-mail address and a mobile number are one person's, they are the same
/// person's across every project here, and a phone number in git history
/// outlives whatever the repository's visibility happened to be on the day it
/// was committed — and unlike a leaked key, cannot be rotated.
///
/// So each project decides where they live. Both of the ones behind this
/// package already hold arbitrary values in their sops file and hand them over
/// through `secrets exec`, which is the same route every credential takes.
class ReviewContact {
  const ReviewContact({
    required this.firstName,
    required this.lastName,
    required this.email,
    required this.phone,
  });

  final String firstName;
  final String lastName;
  final String email;
  final String phone;

  static const firstNameVar = 'APPLE_REVIEW_CONTACT_FIRST_NAME';
  static const lastNameVar = 'APPLE_REVIEW_CONTACT_LAST_NAME';
  static const emailVar = 'APPLE_REVIEW_CONTACT_EMAIL';
  static const phoneVar = 'APPLE_REVIEW_CONTACT_PHONE';

  static const variables = [firstNameVar, lastNameVar, emailVar, phoneVar];

  /// The contact, or null when none of it is set.
  ///
  /// All four or none: a partial set is refused rather than sent, because Apple
  /// demands all four together and a half-filled request fails after the rest
  /// of the listing has already been written.
  static ReviewContact? fromEnvironment([Map<String, String>? env]) {
    final source = env ?? Platform.environment;
    final present = variables
        .where((v) => (source[v] ?? '').trim().isNotEmpty)
        .toList();
    if (present.isEmpty) {
      return null;
    }
    if (present.length != variables.length) {
      final missing = variables.where((v) => !present.contains(v));
      throw AscApiException(400, [
        'the review contact is half set — ${missing.join(', ')} '
            '${missing.length == 1 ? 'is' : 'are'} empty.',
        'Apple wants all four together, so a partial set fails after the rest '
            'of the listing has been written.',
      ], request: 'the environment');
    }

    final phone = source[phoneVar]!.trim();
    // Apple's own words when it refuses one, checked here instead: "Preface the
    // phone number with '+' followed by the country code". Worth catching
    // locally because the rejection arrives mid-push, after several fields have
    // already landed.
    if (!RegExp(r'^\+[0-9][0-9 ()./-]*[0-9]$').hasMatch(phone)) {
      throw AscApiException(400, [
        '$phoneVar is "$phone", which Apple will refuse.',
        "It wants '+' then the country code, as in +44 844 209 0611.",
      ], request: 'the environment');
    }

    return ReviewContact(
      firstName: source[firstNameVar]!.trim(),
      lastName: source[lastNameVar]!.trim(),
      email: source[emailVar]!.trim(),
      phone: phone,
    );
  }

  Map<String, String> get attributes => {
    'contactFirstName': firstName,
    'contactLastName': lastName,
    'contactEmail': email,
    'contactPhone': phone,
  };
}

/// A build that never became visible, which is usually a rejection.
///
/// Separate from [AscApiException] because nothing went wrong with the API: the
/// waiting is this tool's, and every poll was answered.
class ProcessingTimeout implements Exception {
  ProcessingTimeout({
    required this.buildNumber,
    required this.waited,
    this.lastState,
  });

  final String buildNumber;
  final Duration waited;

  /// What Apple last said, or null while the build was not visible at all —
  /// which is the shape a rejected upload takes.
  final String? lastState;

  @override
  String toString() =>
      'build $buildNumber was still ${lastState ?? "not visible"} after '
      '${waited.inMinutes} minutes.\n'
      '  A build that never appears has usually been refused during '
      'processing, and\n'
      '  Apple reports that only by e-mail and in App Store Connect > '
      'Activity —\n'
      '  never through this API. Read the e-mail before uploading again: an '
      'ITMS\n'
      '  error will name the exact key or entitlement, and re-sending the same\n'
      '  artifact fails the same way.\n'
      '  If it was merely slow, re-running the upload step finds it rather '
      'than\n'
      '  transferring the artifact a second time.';
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
      query: {
        'filter[app]': app.id,
        ..._platformFilter,
        'sort': '-version',
        'limit': '200',
      },
    );
    return builds;
  }

  /// Restricts a build query to the platform this instance was built for.
  ///
  /// **Without it every build query answered a question nobody asked.** The doc
  /// comments here have always said "on this platform" and the filter was
  /// simply absent, so `appstore builds --platform ios` listed the macOS builds
  /// too — and a project that ships both from one commit gives them the *same
  /// build number*, so the two are indistinguishable in the output.
  ///
  /// That is worse in [findBuild] than in a listing. [awaitProcessing] polls it
  /// until a build appears, so an iOS upload could have been satisfied by a
  /// macOS build of the same number: waited on, found, declared processed, and
  /// released notes attached to the wrong platform's binary. It was a listing
  /// that showed a build which had never been uploaded that made this visible.
  Map<String, String> get _platformFilter => {
    'filter[preReleaseVersion.platform]': platform.api,
  };

  /// The build carrying [buildNumber] as its `CFBundleVersion`, or null.
  ///
  /// Apple's `filter[version]` on builds is the build number rather than the
  /// marketing version, which reads backwards and is the single easiest thing
  /// to get wrong here.
  Future<Map<String, dynamic>?> findBuild(App app, String buildNumber) async {
    final found = await client.getAll(
      '/v1/builds',
      query: {
        'filter[app]': app.id,
        'filter[version]': buildNumber,
        ..._platformFilter,
      },
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
        // **Not an AscApiException, and not a 504.** Apple answered every one
        // of these polls correctly; the timeout is ours. Reporting it as a
        // gateway error Apple never sent sends the reader looking for a network
        // problem, and "re-run, it is not lost" — which was the only advice
        // here — is exactly wrong in the case that actually happens.
        //
        // A build that never becomes visible has usually been *rejected* during
        // processing, and Apple reports that by e-mail and nowhere else: not in
        // this response, not as a FAILED state, not as anything the API will
        // ever show. So the tool has to name the place the answer is, or the
        // next forty-five minutes go the same way.
        throw ProcessingTimeout(
          buildNumber: buildNumber,
          waited: timeout,
          lastState: state,
        );
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
      await writer.patch('/v1/betaBuildLocalizations/${_id(existing.first)}', {
        'data': {
          'type': 'betaBuildLocalizations',
          'id': _id(existing.first),
          'attributes': {'whatsNew': text},
        },
      }, describe: 'what to test ($locale)');
    }
  }

  /// Every beta group this app has.
  Future<List<Map<String, dynamic>>> betaGroups(App app) =>
      client.getAll('/v1/betaGroups', query: {'filter[app]': app.id});

  /// Prints them, with the kind, because the kind decides what a release costs.
  ///
  /// **A name is the one input `--beta-group` cannot infer or default**, and
  /// until this existed nothing printed one: the only command that touched
  /// groups filtered by exact name and 404'd, so a caller who did not already
  /// know the name had to leave the tool and read the console. That is a
  /// read-only fact about the app, which is what the other `list*` commands
  /// here are for.
  Future<void> listBetaGroups(App app) async {
    final groups = await betaGroups(app);
    if (groups.isEmpty) {
      stdout.writeln(
        '  no beta groups — create one in App Store Connect > TestFlight > '
        'Groups. They cannot be created over the API.',
      );
      return;
    }
    for (final group in groups) {
      final attributes = _attributes(group);
      stdout.writeln(
        '  ${attributes['name']}  '
        '${isInternalBetaGroup(group) ? 'internal' : 'external'}'
        '${attributes['publicLinkEnabled'] == true ? '  (public link)' : ''}',
      );
    }
  }

  /// The named beta group, whole, so the caller can read `isInternalGroup`
  /// before deciding what a release to it has to involve.
  Future<Map<String, dynamic>> findBetaGroup(App app, String groupName) async {
    final groups = await client.getAll(
      '/v1/betaGroups',
      query: {'filter[app]': app.id, 'filter[name]': groupName},
    );
    if (groups.isEmpty) {
      // **Say what does exist, because the caller's next question is always
      // "then what is it called".** A filter by exact name answers only about
      // the name asked for, so a 404 that stops there sends the reader to the
      // console to look up a string this request could have printed.
      //
      // **Best effort, and that is the whole reason for the catch.** This is a
      // second network call *inside a failure path*, so letting it throw would
      // replace a refusal that names the problem — the group does not exist —
      // with an unrelated transport error, and the diagnosis would be lost to
      // the thing added to improve it. The enrichment is worth having and
      // never worth the original message.
      var existing = const <Map<String, dynamic>>[];
      var listed = true;
      try {
        existing = await betaGroups(app);
      } on Object {
        listed = false;
      }
      throw AscApiException(404, [
        'no beta group called "$groupName".',
        if (!listed) ...<String>[
          'Create it once in App Store Connect > TestFlight > Groups, or pass '
              '--beta-group with a name that exists. Groups cannot be created '
              'over the API.',
        ] else if (existing.isEmpty) ...<String>[
          'This app has no beta groups at all. Create one in App Store '
              'Connect > TestFlight > Groups; they cannot be created over the '
              'API.',
        ] else ...<String>[
          'This app has: ${existing.map((g) => '"${_attributes(g)['name']}" '
              '(${isInternalBetaGroup(g) ? 'internal' : 'external'})').join(', ')}.',
        ],
      ], request: 'GET /v1/betaGroups');
    }
    return groups.first;
  }

  /// Adds a build to a beta group, so testers actually receive it.
  ///
  /// An internal group needs no review and is available within minutes, which
  /// is the closest thing the App Store has to Play's internal track. An
  /// external group is different in kind rather than degree: assignment alone
  /// delivers nothing there until the build passes beta review.
  Future<void> addToBetaGroup(
    Map<String, dynamic> group,
    Map<String, dynamic> build,
  ) async {
    await writer.post('/v1/betaGroups/${_id(group)}/relationships/builds', {
      'data': [
        {'type': 'builds', 'id': _id(build)},
      ],
    }, describe: 'added to beta group "${_attributes(group)['name']}"');
  }

  /// Every `betaAppLocalizations` record the app has.
  ///
  /// Where the TestFlight "Beta App Description" lives — Test Information in
  /// the console. Scoped to the app rather than to a build or a version, so it
  /// outlives every release. All of them rather than one locale's, because
  /// "does a description exist anywhere" is a question about the whole set.
  Future<List<Map<String, dynamic>>> betaAppLocalizations(App app) =>
      client.getAll('/v1/apps/${app.id}/betaAppLocalizations');

  /// Writes the Beta App Description for one locale.
  ///
  /// [existing] is the record [betaAppLocalization] found, so the caller's
  /// dedupe read and this write cannot disagree about which record they mean.
  Future<void> writeBetaAppDescription(
    App app,
    String locale,
    String text, {
    required Map<String, dynamic>? existing,
  }) async {
    final describe =
        'beta app description ($locale, ${text.length} characters)';
    if (existing == null) {
      await writer.post('/v1/betaAppLocalizations', {
        'data': {
          'type': 'betaAppLocalizations',
          'attributes': {'locale': locale, 'description': text},
          'relationships': {'app': relation('apps', app.id)},
        },
      }, describe: describe);
    } else {
      await writer.patch('/v1/betaAppLocalizations/${_id(existing)}', {
        'data': {
          'type': 'betaAppLocalizations',
          'id': _id(existing),
          'attributes': {'description': text},
        },
      }, describe: describe);
    }
  }

  /// Submits [build] for beta review, once.
  ///
  /// The same idempotence shape as [submitForReview]: find the submission that
  /// already covers this build, reuse it, and say so. A build is submitted at
  /// most once, so a retried release job finds the first run's submission here
  /// rather than a 409.
  Future<void> submitBetaReview(Map<String, dynamic> build) async {
    final buildId = _id(build)!;
    final existing = await client.getAll(
      '/v1/betaAppReviewSubmissions',
      query: {'filter[build]': buildId},
    );
    if (existing.isNotEmpty) {
      final state = _attributes(existing.first)['betaReviewState'];
      // A rejected submission is not a no-op to report and move past: the
      // release delivered nothing, and a green exit here is how that goes
      // unnoticed until a tester asks where the build is.
      if (state == 'REJECTED') {
        throw ReleaseException(
          'build ${_attributes(build)['version']} was already submitted for '
          'beta review and Apple rejected it — this release delivered '
          'nothing.\n'
          'Apple explains the rejection in App Store Connect > TestFlight and '
          'by e-mail, never through this API. Fix what it names and upload a '
          'new build; a build is submitted at most once.',
        );
      }
      stdout.writeln(
        '    already submitted for beta review — Apple says $state',
      );
      return;
    }
    await writer.post('/v1/betaAppReviewSubmissions', {
      'data': {
        'type': 'betaAppReviewSubmissions',
        'relationships': {'build': relation('builds', buildId)},
      },
    }, describe: 'submitted for beta review');
  }

  /// Prints what TestFlight now says about the build's external availability.
  ///
  /// The same "say which way it ended" convention as [awaitProcessing]: a run
  /// reports what it sent, which is not evidence of what arrived, so the
  /// closing line is read back rather than assumed. WAITING_FOR_BETA_REVIEW is
  /// the state a successful submission lands in.
  Future<void> reportExternalBuildState(Map<String, dynamic> build) async {
    final detail = await client.get('/v1/builds/${_id(build)}/buildBetaDetail');
    final data = detail['data'];
    final state = data is Map<String, dynamic>
        ? _attributes(data)['externalBuildState']
        : null;
    stdout.writeln('==> external build state: ${state ?? '(not reported)'}');
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
    await writer.patch('/v1/appStoreVersions/${_id(version)}', {
      'data': {
        'type': 'appStoreVersions',
        'id': _id(version),
        'relationships': {'build': relation('builds', _id(build)!)},
      },
    }, describe: 'attached build ${_attributes(build)['version']}');
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
      await writer.post('/v1/appStoreVersionLocalizations', {
        'data': {
          'type': 'appStoreVersionLocalizations',
          'attributes': {'locale': locale, ...attributes},
          'relationships': {
            'appStoreVersion': relation('appStoreVersions', _id(version)!),
          },
        },
      }, describe: '$locale: ${attributes.keys.join(", ")}');
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
    await writer.patch('/v1/appInfos/${_id(appInfo)}', {
      'data': {
        'type': 'appInfos',
        'id': _id(appInfo),
        'relationships': relationships,
      },
    }, describe: 'categories: ${categories.values.join(", ")}');
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
      await writer.post('/v1/appInfoLocalizations', {
        'data': {
          'type': 'appInfoLocalizations',
          'attributes': {'locale': locale, ...attributes},
          'relationships': {'appInfo': relation('appInfos', _id(appInfo)!)},
        },
      }, describe: '$locale: ${attributes.keys.join(", ")}');
    } else {
      await writer.patch('/v1/appInfoLocalizations/${_id(match.first)}', {
        'data': {
          'type': 'appInfoLocalizations',
          'id': _id(match.first),
          'attributes': attributes,
        },
      }, describe: '$locale: ${attributes.keys.join(", ")}');
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
    await writer.patch('/v1/ageRatingDeclarations/$declarationId', {
      'data': {
        'type': 'ageRatingDeclarations',
        'id': declarationId,
        'attributes': declaration,
      },
    }, describe: 'age rating (${declaration.length} answers)');
  }

  /// Pushes what the reviewer is told, which hangs off the version.
  ///
  /// **The one piece of the listing whose absence costs a review cycle rather
  /// than a rejection.** An app with no content of its own opens to an empty
  /// screen, and a reviewer with no sample data concludes it does nothing —
  /// which comes back as "we were unable to evaluate your app", days later,
  /// with nothing to fix.
  ///
  /// Created where the version has no review detail yet and patched where it
  /// has. Apple may then demand contact fields on the create; that error is left
  /// to speak for itself rather than pre-empted with invented values, because a
  /// wrong contact is worse than a missing one.
  Future<void> writeReviewDetails(
    Map<String, dynamic> version,
    String notes, {
    ReviewContact? contact,
  }) async {
    final versionId = _id(version);
    final existing = await client.get(
      '/v1/appStoreVersions/$versionId/appStoreReviewDetail',
    );
    final data = existing['data'];

    // **All four contact fields go with every write, not only the first.**
    // Creating a review detail with nothing but notes succeeds; *updating* one
    // is refused unless the whole contact is sent alongside — so the second
    // push of an unchanged file fails where the first one worked. That is the
    // least guessable order to meet these two rules in, and it cost a release
    // upload to find.
    final attributes = <String, String>{
      'notes': notes,
      ...?contact?.attributes,
    };
    final describe =
        'review notes (${notes.length} characters)'
        '${contact == null ? '' : ', contact ${contact.firstName} ${contact.lastName}'}';

    if (data is Map<String, dynamic> && data['id'] != null) {
      await writer.patch('/v1/appStoreReviewDetails/${_id(data)}', {
        'data': {
          'type': 'appStoreReviewDetails',
          'id': _id(data),
          'attributes': attributes,
        },
      }, describe: describe);
      return;
    }

    await writer.post('/v1/appStoreReviewDetails', {
      'data': {
        'type': 'appStoreReviewDetails',
        'attributes': attributes,
        'relationships': {
          'appStoreVersion': {
            'data': {'type': 'appStoreVersions', 'id': versionId},
          },
        },
      },
    }, describe: describe);
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

    final created = await writer.post('/v1/appScreenshotSets', {
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
    }, describe: '$displayType: ${files.length} screenshot(s)');

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
    await writer.post('/v1/appStoreVersionPhasedReleases', {
      'data': {
        'type': 'appStoreVersionPhasedReleases',
        'attributes': {'phasedReleaseState': 'INACTIVE'},
        'relationships': {
          'appStoreVersion': relation('appStoreVersions', _id(version)!),
        },
      },
    }, describe: 'phased release over seven days');
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
    if (credentials.issuerId case final issuer?) ...['--apiIssuer', issuer],
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
