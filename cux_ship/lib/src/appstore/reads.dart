// SPDX-License-Identifier: Apache-2.0
//
// The App Store reads as objects — the model `appstore builds` and `appstore
// versions` print from, and that `--json` is encoded from.
//
// **No longer a public API.** This was reached through
// `package:cux_ship/read.dart`, for a Dart caller that would otherwise match
// regular expressions against this command's stdout. That library is gone:
// `--json` answers the same question without moving credentials into the
// calling process, and read-api.md records why the library did not survive it.
// Nothing here is exported now.
//
// **The printed lines are derived from these objects, not the other way
// round.** [printBuilds] and [printVersions] render [AppStoreBuilds.lines] and
// [AppStoreVersions.lines], and `json_output.dart` builds the documents from
// the same objects — so there is one description of what a build listing looks
// like and every renderer gets it. That matters more than it sounds: a
// consumer that prints this command's output verbatim — because a `status`
// that renders the same model its own way reports something different from
// what this command reports, silently — needs those lines to be the same
// lines, and a second formatter beside the first is a second thing to drift.
//
// **Reads only, and that is now a convention rather than a structure.** It
// used to be structural: an `AppStoreReads` session built a dry-run [Writer],
// so the write path was refused at the one place every write goes through.
// That session is deleted, and nothing in this file constructs a [Writer] any
// more — [printBuilds] and [printVersions] take an [AppStore] from their
// caller and can only do with it what that caller could. Said plainly because
// the sentence it replaces claimed a guarantee, and somebody reading
// "structural" would go looking for a refusal that is no longer anywhere.
import 'dart:io';

import '../json_output.dart';
import 'app_store.dart';

/// `attributes` off a JSON:API resource, empty when a sparse fieldset left it
/// out. The same shape as the private helper in app_store.dart; duplicated
/// rather than exported, because a public `attributes()` on the package
/// surface is a promise about Apple's wire format.
Map<String, dynamic> _attributes(Map<String, dynamic> resource) =>
    (resource['attributes'] as Map<String, dynamic>?) ?? const {};

/// One TestFlight group a build is attached to.
///
/// **A name and a kind, because the name alone is not the answer.** Whether a
/// group's testers already have the build depends entirely on which kind it
/// is: Apple hands every processed build to every internal group within
/// minutes, and an external group receives nothing until beta review passes.
/// A group called "External Testers" is evidence of somebody's naming habit
/// rather than of Apple's answer, which is [BetaGroupKind]'s whole argument.
class AppStoreBetaGroup {
  const AppStoreBetaGroup({required this.name, required this.kind});

  /// Apple's `name` attribute, or `(unnamed)` when the resource carried none —
  /// the same fallback the app lookup takes, so a group Apple did not name is
  /// still counted rather than dropped on the way in.
  final String name;

  /// Internal, external, or that the response did not say. See [betaGroupKind],
  /// which refuses to guess and says why the two defaults are not symmetric.
  final BetaGroupKind kind;
}

/// One build App Store Connect holds.
class AppStoreBuild {
  const AppStoreBuild({
    required this.buildNumber,
    required this.processingState,
    required this.uploadedDate,
    required this.uploadedAt,
    required this.expired,
    required this.betaGroups,
    required this.externalBuildState,
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
  /// Kept beside [uploadedAt] because [line] renders this one: Apple's
  /// offset-bearing spelling and `DateTime.toIso8601String` are not the same
  /// string, and the printed output is something a consumer shows verbatim.
  final String? uploadedDate;

  /// [uploadedDate] parsed, or null when it was absent or unparseable.
  final DateTime? uploadedAt;

  /// TestFlight builds expire after 90 days. An expired build is still listed
  /// and can no longer be given to a group.
  final bool expired;

  /// The TestFlight groups this build is attached to, or null when the
  /// response did not say.
  ///
  /// **Null and empty are different answers and the difference is the whole
  /// point of the field.** Empty is Apple saying *this build is attached to
  /// nothing*; null is this package not having asked — a read that did not
  /// send `include=betaGroups`. Collapsing them would report *no external
  /// testers have this build* for a request that never enquired, which is the
  /// one wrong answer a caller cannot detect: it is also the true answer most
  /// of the time, so it reads as correct until the day it is not.
  ///
  /// That is [BetaGroupKind.unknown]'s rule one level up — a reader that
  /// cannot read must not report a reading — applied to the list rather than
  /// to a group's kind.
  final List<AppStoreBetaGroup>? betaGroups;

  /// `buildBetaDetail.externalBuildState`, or null when the response did not
  /// carry it.
  ///
  /// **The only field that separates *external testers have this* from *this
  /// is sitting in beta review*.** [processingState] answers a different
  /// question — whether Apple finished ingesting the binary — and a build can
  /// be `VALID` for a week without one external tester being able to install
  /// it. Apple's values include `READY_FOR_BETA_SUBMISSION`,
  /// `WAITING_FOR_BETA_REVIEW`, `IN_BETA_REVIEW`, `BETA_REJECTED`,
  /// `BETA_APPROVED` and `IN_BETA_TESTING`.
  ///
  /// **Carried raw rather than as an enum, on purpose.** The list above is
  /// Apple's published one and this package has been surprised by that list
  /// before; a member per state would make an unrecognized value either a
  /// parse failure or a silent fallback, and both are worse than handing the
  /// caller the word Apple used. [inExternalTesting] is the one reading this
  /// package commits to, and it deliberately reads this field *and*
  /// [externalGroups] rather than this one alone.
  ///
  /// **Observed 2026-09-14** on `design.codeux.howitwent`: 36 builds
  /// `READY_FOR_BETA_SUBMISSION`, 14 `BETA_APPROVED`, and one build whose
  /// `buildBetaDetail` resolved to nothing at all — which is this field's null
  /// arriving from a live account rather than from a fixture.
  final String? externalBuildState;

  /// The attached groups Apple said were internal, or null when [betaGroups]
  /// is null.
  ///
  /// A group whose kind Apple did not report appears in neither this nor
  /// [externalGroups] — see [hasUnknownGroupKind], which is how a caller
  /// notices rather than being quietly told there are none.
  List<AppStoreBetaGroup>? get internalGroups => betaGroups
      ?.where((group) => group.kind == BetaGroupKind.internal)
      .toList();

  /// The attached groups Apple said were external, or null when [betaGroups]
  /// is null. See [internalGroups].
  List<AppStoreBetaGroup>? get externalGroups => betaGroups
      ?.where((group) => group.kind == BetaGroupKind.external)
      .toList();

  /// Whether any attached group came back without [BetaGroupKind].
  ///
  /// **False for a build whose groups were never read**, which is the one
  /// reading this getter deliberately does not offer: null [betaGroups] is not
  /// an unknown *kind*, it is an unread relationship, and a caller conflating
  /// the two would report a refusal as a quirk of one group. Check [betaGroups]
  /// for null first — the two questions have two answers because they have two
  /// remedies.
  bool get hasUnknownGroupKind =>
      betaGroups?.any((group) => group.kind == BetaGroupKind.unknown) ?? false;

  /// Apple's external states in which a build has cleared beta review and is
  /// deliverable. Approval, not delivery — see [inExternalTesting].
  static const _clearedBetaReview = <String>{
    'BETA_APPROVED',
    'READY_FOR_BETA_TESTING',
    'IN_BETA_TESTING',
  };

  /// Whether external testers can install this build now.
  ///
  /// **Two facts, because Apple splits the answer across two of them and
  /// neither one is sufficient.** A build is installable by an external tester
  /// only when it has cleared beta review *and* is attached to an external
  /// group. The state alone says Apple would allow it; the attachment alone
  /// says somebody asked for it while review may still be pending.
  ///
  /// **This read as `externalBuildState == 'IN_BETA_TESTING'` and that is a
  /// constant `false` against a real account.** Measured 2026-09-14 over 51
  /// iOS builds of `design.codeux.howitwent`: Apple's terminal external state
  /// after review is `BETA_APPROVED` (14 builds, every one of them attached to
  /// the external group `Beta Testers`), `READY_FOR_BETA_SUBMISSION` for the
  /// 36 nobody submitted, and `IN_BETA_TESTING` never once. Builds 178–180
  /// were demonstrably installable by external testers and this getter said
  /// they were not — the same defect one layer inside the fix for it, and the
  /// reason `false` here is held to the standard [AppStoreBuildEntry.usable]
  /// is not: it is a claim rather than a refusal.
  ///
  /// `IN_BETA_TESTING` and `READY_FOR_BETA_TESTING` stay in
  /// [_clearedBetaReview] because Apple publishes them and this account is one
  /// account — an unobserved state is not an impossible one.
  ///
  /// **Null wherever an input is missing rather than false**, which is three
  /// cases: Apple sent no [externalBuildState], the read did not ask for
  /// [betaGroups], or the only attached group came back with a kind Apple
  /// withheld — that last one is [hasUnknownGroupKind]'s stake, because
  /// counting it out of [externalGroups] and then answering `false` would
  /// report the refusal as a delivery answer.
  ///
  /// **The hole this cannot close on its own**: [_relatedMany] resolves a
  /// named group through `included` and *skips* one that did not arrive, so a
  /// build whose groups Apple named and truncated reads as `[]` — attached to
  /// nothing — and this answers a confident `false`. `betaGroups` does not
  /// reach Apple's 50-resource cap on any account measured, because `included`
  /// holds distinct resources and an account has a handful of groups, while
  /// the build detail reaches it immediately. See [AppStore.buildsWithIncluded],
  /// which records the cap and the remedy: until a named-but-unresolved
  /// resource is representable, this getter is only as truthful as its inputs.
  bool? get inExternalTesting {
    final state = externalBuildState;
    if (state == null) {
      return null;
    }
    if (!_clearedBetaReview.contains(state)) {
      // Not cleared is knowable from the state alone: no group assignment
      // makes a build in review installable, so the groups need not be read.
      return false;
    }
    final external = externalGroups;
    if (external == null) {
      return null;
    }
    if (external.isEmpty && hasUnknownGroupKind) {
      return null;
    }
    return external.isNotEmpty;
  }

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
  ///
  /// The audience half is appended only when [betaGroups] was read, so a
  /// listing from a request that did not ask prints exactly what it always
  /// printed rather than a row of confident `none`s.
  String get line =>
      '  build $buildNumber  '
      '$processingState  '
      'uploaded $uploadedDate'
      '${expired ? '  (expired)' : ''}'
      '$_audienceSuffix';

  /// `  internal: Team  external: Public Beta (IN_BETA_TESTING)`, or empty.
  ///
  /// **Both halves are always named once either is**, including the empty
  /// ones. A line that omits `external:` when no external group is attached
  /// makes the commonest state — a build processed and given to nobody
  /// outside — look like a line that forgot to mention it, which is the
  /// reading this whole field exists to prevent.
  String get _audienceSuffix {
    final groups = betaGroups;
    if (groups == null) {
      return '';
    }
    final unknown = groups
        .where((group) => group.kind == BetaGroupKind.unknown)
        .map((group) => group.name);
    return <String>[
      '  internal: ${_names(internalGroups!)}',
      '  external: ${_names(externalGroups!)}'
          // The state is printed beside the external groups whether or not
          // there are any: `none (WAITING_FOR_BETA_REVIEW)` is a real and
          // confusing moment — submitted for review, not yet attached — and
          // hiding the state behind a group being present is how it would go
          // unexplained.
          '${externalBuildState == null ? '' : ' ($externalBuildState)'}',
      if (unknown.isNotEmpty) '  kind not reported: ${unknown.join(', ')}',
    ].join();
  }

  static String _names(List<AppStoreBetaGroup> groups) =>
      groups.isEmpty ? 'none' : groups.map((group) => group.name).join(', ');
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
  /// this command's output rather than rendering the model itself.
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

/// The resources a to-many relationship names, resolved through [included].
///
/// Null when the relationship carries no `data` key — which is what a request
/// that did not send the matching `include=` gets back, measured on
/// `relationships.build` and recorded at `_buildNumberOf`. That is a different
/// fact from an empty `data` list, which is Apple saying the relationship is
/// genuinely empty, and this returns `[]` for it.
///
/// A named resource that is missing from [included] is skipped rather than
/// faked: it cannot be described, and a placeholder would be a group with no
/// kind, which is the one thing [BetaGroupKind] refuses to invent.
List<Map<String, dynamic>>? _relatedMany(
  Map<String, dynamic> resource,
  String relationship,
  Map<String, Map<String, dynamic>> included,
) {
  final relationships = resource['relationships'];
  if (relationships is! Map<String, dynamic>) {
    return null;
  }
  final named = relationships[relationship];
  if (named is! Map<String, dynamic>) {
    return null;
  }
  final data = named['data'];
  if (data is! List) {
    return null;
  }
  return <Map<String, dynamic>>[
    for (final entry in data.whereType<Map<String, dynamic>>())
      if (entry['type'] case final String type)
        if (entry['id'] case final String id)
          if (included['$type:$id'] case final Map<String, dynamic> found)
            found,
  ];
}

/// The single resource a to-one relationship names, resolved through
/// [included]. Null for every way of not knowing — see [_relatedMany], which
/// draws the same distinctions on the many side.
Map<String, dynamic>? _relatedOne(
  Map<String, dynamic> resource,
  String relationship,
  Map<String, Map<String, dynamic>> included,
) {
  final relationships = resource['relationships'];
  if (relationships is! Map<String, dynamic>) {
    return null;
  }
  final named = relationships[relationship];
  if (named is! Map<String, dynamic>) {
    return null;
  }
  final data = named['data'];
  if (data is! Map<String, dynamic>) {
    return null;
  }
  if (data['type'] case final String type) {
    if (data['id'] case final String id) {
      return included['$type:$id'];
    }
  }
  return null;
}

/// One `builds` resource, as sent, with the groups and beta detail that came
/// beside it.
AppStoreBuild appStoreBuildFrom(
  Map<String, dynamic> resource, [
  Map<String, Map<String, dynamic>> included = const {},
]) {
  final attributes = _attributes(resource);
  final uploadedDate = attributes['uploadedDate'] as String?;
  final groups = _relatedMany(resource, 'betaGroups', included);
  final detail = _relatedOne(resource, 'buildBetaDetail', included);
  return AppStoreBuild(
    buildNumber: '${attributes['version']}',
    processingState: attributes['processingState'] as String?,
    uploadedDate: uploadedDate,
    uploadedAt: uploadedDate == null ? null : DateTime.tryParse(uploadedDate),
    expired: attributes['expired'] == true,
    betaGroups: groups == null
        ? null
        : <AppStoreBetaGroup>[
            for (final group in groups)
              AppStoreBetaGroup(
                name: '${_attributes(group)['name'] ?? '(unnamed)'}',
                kind: betaGroupKind(group),
              ),
          ],
    externalBuildState: detail == null
        ? null
        : _attributes(detail)['externalBuildState'] as String?,
  );
}

/// A `GET /v1/builds` payload, sorted newest first, and the `included`
/// resources beside it.
AppStoreBuilds appStoreBuildsFrom(
  List<Map<String, dynamic>> payload,
  AscPlatform platform, {
  Map<String, Map<String, dynamic>> included = const {},
}) {
  final builds =
      payload.map((resource) => appStoreBuildFrom(resource, included)).toList()
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
    required this.buildNumber,
  });

  /// The marketing version — `1.4.0`, not a build number.
  final String versionString;

  /// The `CFBundleVersion` of the build attached to this version, or null when
  /// Apple named none.
  ///
  /// **This answers "is what is live the thing I think is live"**, which
  /// [versionString] cannot: two builds of `1.4.0` are the same version and
  /// different binaries.
  ///
  /// A string for the reason [AppStoreBuild.buildNumber] is one — Apple accepts
  /// a dotted `CFBundleVersion` — and [buildNumberAsInt] is the form to compare.
  ///
  /// **Null is one answer covering two causes, and this package cannot tell
  /// them apart.** Apple names no build for a version in
  /// `PREPARE_FOR_SUBMISSION`, which is honest; and a request that failed to
  /// carry `include=build` would also produce null here, which is not. The
  /// second was measured *not* to happen against a live account — without the
  /// include, `relationships.build` has no `data` key at all — but the first
  /// has never been observed, because the account it was measured against held
  /// six versions and every one was `READY_FOR_SALE`. So a null is reported as
  /// a null rather than as a diagnosis, and docs/design/rollout-state.md
  /// records what would settle it: one `PREPARE_FOR_SUBMISSION` version, at
  /// this repository's next release.
  final String? buildNumber;

  /// `PREPARE_FOR_SUBMISSION`, `WAITING_FOR_REVIEW`, `READY_FOR_SALE` and the
  /// rest, or null when the response did not carry it.
  final String? appStoreState;

  /// `MANUAL`, `AFTER_APPROVAL` or `SCHEDULED`, or null.
  final String? releaseType;

  /// Required before review and null by default.
  final String? copyright;

  /// [buildNumber] read as an integer, or null when it is absent or not one.
  ///
  /// The form to compare, for the reason [AppStoreBuild.buildNumberAsInt] gives
  /// at length: `"9"` sorts above `"10"`, and that mistake has been made twice
  /// against this data already.
  int? get buildNumberAsInt {
    final number = buildNumber;
    return number == null ? null : int.tryParse(number);
  }

  /// Whether a push against this version would be accepted, by the rule
  /// [editableVersionStates] states.
  bool get editable =>
      appStoreState != null && editableVersionStates.contains(appStoreState);

  /// The two lines `cux_ship appstore versions` prints for this version.
  ///
  /// **The build is appended only when Apple named one**, so a version with
  /// none reads exactly as it did before this field existed rather than
  /// carrying `build null`.
  List<String> get lines => <String>[
    '  $versionString  $appStoreState  $releaseType'
        '${buildNumber == null ? '' : '  build $buildNumber'}',
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

/// The `CFBundleVersion` of the build [resource] names, resolved through
/// [included].
///
/// **Two hops, and both can legitimately come up empty.** A version names its
/// build under `relationships.build.data`, and the build's own `version`
/// attribute is the number — Apple calls it `version` on a build and means the
/// build number, which is the single easiest thing to get wrong here.
///
/// Null when the relationship has no `data` (no `include=build` was sent, or
/// Apple named no build), when `included` does not carry the resource it names,
/// or when that resource has no `version`. Three ways of not knowing, one
/// answer, because none of them is a fact about the build.
String? _buildNumberOf(
  Map<String, dynamic> resource,
  Map<String, Map<String, dynamic>> included,
) {
  final relationships = resource['relationships'];
  if (relationships is! Map<String, dynamic>) {
    return null;
  }
  final build = relationships['build'];
  if (build is! Map<String, dynamic>) {
    return null;
  }
  // **The wire distinguishes two cases here and this code does not, on
  // purpose.** Measured against a live account: without `include=build` the
  // relationship carries `links` and no `data` key at all, and with it `data`
  // names the build. So an absent key is this package not having asked, which
  // is a different fact from Apple having no build to name.
  //
  // A `containsKey` branch to tell them apart was written and removed: both
  // arms produced null, so the mutation that deleted it passed every test.
  // Acting on the difference needs a caller that wants a diagnosis rather than
  // an answer, and `AppStoreVersion.buildNumber` says in as many words that it
  // does not offer one. The distinction is recorded here rather than
  // half-implemented above.
  final data = build['data'];
  if (data is! Map<String, dynamic>) {
    return null;
  }
  final id = data['id'];
  if (id is! String) {
    return null;
  }
  final version = _attributes(included['builds:$id'] ?? const {})['version'];
  return version == null ? null : '$version';
}

/// One `appStoreVersions` resource, as sent, with the builds that came beside
/// it.
AppStoreVersion appStoreVersionFrom(
  Map<String, dynamic> resource, [
  Map<String, Map<String, dynamic>> included = const {},
]) {
  final attributes = _attributes(resource);
  return AppStoreVersion(
    versionString: '${attributes['versionString']}',
    appStoreState: attributes['appStoreState'] as String?,
    releaseType: attributes['releaseType'] as String?,
    copyright: attributes['copyright'] as String?,
    buildNumber: _buildNumberOf(resource, included),
  );
}

/// An `appStoreVersions` payload, and the `included` resources beside it.
AppStoreVersions appStoreVersionsFrom(
  List<Map<String, dynamic>> payload,
  AscPlatform platform, {
  Map<String, Map<String, dynamic>> included = const {},
}) => AppStoreVersions(
  platform: platform,
  versions: <AppStoreVersion>[
    for (final resource in payload) ...[
      appStoreVersionFrom(resource, included),
    ],
  ],
);

/// `cux_ship appstore builds`.
///
/// A free function rather than a method on [AppStore], and deliberately: the
/// arrow points one way, from what the API can be asked to do towards how a
/// listing is rendered, and [AppStore] therefore does not import this file.
Future<void> printBuilds(AppStore store, App app, {bool json = false}) async {
  final payload = await store.buildsWithIncluded(app);
  final listing = appStoreBuildsFrom(
    payload.data,
    store.platform,
    included: payload.included,
  );
  if (json) {
    writeJsonDocument(appStoreBuildsDocument(listing, bundleId: app.bundleId));
    return;
  }
  for (final line in listing.lines) {
    stdout.writeln(line);
  }
}

/// `cux_ship appstore versions`.
Future<void> printVersions(AppStore store, App app, {bool json = false}) async {
  final payload = await store.appStoreVersions(app);
  final listing = appStoreVersionsFrom(
    payload.data,
    store.platform,
    included: payload.included,
  );
  if (json) {
    writeJsonDocument(
      appStoreVersionsDocument(listing, bundleId: app.bundleId),
    );
    return;
  }
  for (final line in listing.lines) {
    stdout.writeln(line);
  }
}
