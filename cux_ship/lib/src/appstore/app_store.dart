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

/// The states in which the *app-level* half of a listing can still be written.
///
/// **`appInfos` and `appStoreVersions` are two resources with two rules, and
/// this package used one constant for both.** A version in
/// `WAITING_FOR_REVIEW` is with Apple and a push against it is rightly refused
/// — that is [editableVersionStates] and it is unchanged. The `appInfos`
/// record beside it still accepts a `PATCH`, measured against a live account;
/// it is also what fastlane's `fetch_edit_app_info` has selected for years.
///
/// The gate was this package's own invention, and it cost more than an
/// unnecessary refusal: `promote --platform macos` failed with 409 while the
/// *iOS* side sat in review, and because the listing publish opens the
/// promotion it failed before anything else — no version created, no build
/// attached, no submission made.
/// **Enumerated, not spread from [editableVersionStates].** Deriving it would
/// undercut the argument for splitting them: a list that takes five of its six
/// states from the other resource by reference is not independent of it, and a
/// reader cannot see what it contains without going to look.
///
/// The provenance differs per state and is worth keeping visible.
/// `WAITING_FOR_REVIEW` is measured — Apple accepted a `PATCH` against a record
/// in it — and is what fastlane's `fetch_edit_app_info` selects. The first three
/// are fastlane's list too. `METADATA_REJECTED` and `INVALID_BINARY` are
/// neither measured nor fastlane's; they are here because this package has
/// accepted them on an `appInfos` record for as long as it has had one code
/// path for both resources, and dropping them now would newly refuse a metadata
/// push against a metadata-rejected app — which is exactly when somebody is
/// pushing metadata. Removing an accepted state needs the same evidence as
/// adding one, and nothing here has it.
const editableAppInfoStates = {
  'PREPARE_FOR_SUBMISSION',
  'DEVELOPER_REJECTED',
  'REJECTED',
  'METADATA_REJECTED',
  'INVALID_BINARY',
  'WAITING_FOR_REVIEW',
};

/// The `appInfos` states that mean the record *is* the App Store page — the
/// one shoppers are reading now, or the one Apple has already approved to
/// become it.
///
/// Never a write target. An app that has ever shipped has at least two
/// `appInfos` records, and writing to this one edits what is already
/// published without any review seeing the change.
const publishedAppInfoStates = {
  'READY_FOR_SALE',
  'PENDING_DEVELOPER_RELEASE',
  'PREORDER_READY_FOR_SALE',
  'REPLACED_WITH_NEW_VERSION',
  'REMOVED_FROM_SALE',
  'DEVELOPER_REMOVED_FROM_SALE',
};

/// Whether an `appInfos` record is being picked to read from or to write to.
enum AppInfoUse {
  /// Comparing against what is already there. Reading changes nothing, so any
  /// record can answer it and the published one is an acceptable last resort.
  read,

  /// Publishing. Only a state known to be writable will do.
  write,
}

/// Which of [infos] to use, or null when there is none to use.
///
/// **The two uses have opposite defaults, and that is the whole point.**
///
///     read  : writable, else anything not published, else the published one
///     write : writable, else nothing
///
/// The write side enumerates what may be written and refuses everything else,
/// rather than enumerating what may not and permitting the rest. Apple has
/// changed this enum before — fastlane shrank its own list in 2024 for exactly
/// that reason — so "a state this package has not seen" is a live case, not a
/// hypothetical, and the two directions fail very differently: an unrecognised
/// state that refuses costs somebody thirty seconds reading the message, and
/// an unrecognised state that writes lands a change somewhere nobody examined
/// and says nothing. That is [AppLevelChanges.unverifiable]'s argument applied
/// to states instead of values.
///
/// So `IN_REVIEW` is not a write target: it is not in [editableAppInfoStates],
/// and nothing else makes a record writable. The line between it and
/// `WAITING_FOR_REVIEW` is the one fastlane draws — `fetch_live_app_info`
/// takes `IN_REVIEW`, `fetch_edit_app_info` takes `WAITING_FOR_REVIEW` — and
/// it is the same line the measurement behind [editableAppInfoStates] was
/// taken on. Queued for review and actively under review are plausibly
/// different to Apple, and this package has evidence about only one of them.
///
/// A record whose `appStoreState` Apple did not report is likewise not a write
/// target: absence is a fact about the response, not about the record, the
/// same reading as [betaGroupKind]. It is still preferred over the published
/// record for *reading*, because the one thing an unreported state is not is
/// `READY_FOR_SALE` — that state gets reported.
///
/// The read side keeps its fallbacks because a comparison against any record
/// is worth having: a run that finds nothing to change never demands a write
/// target at all, which is what lets a promote through while the only records
/// are ones nothing may be written to.
///
/// Both uses return the same record whenever the write returns one, because
/// [use] is read only after the writable branch has already failed.
Map<String, dynamic>? selectAppInfo(
  List<Map<String, dynamic>> infos,
  AppInfoUse use,
) {
  Map<String, dynamic>? firstWhere(bool Function(String? state) matches) {
    for (final info in infos) {
      if (matches(_attributes(info)['appStoreState'] as String?)) {
        return info;
      }
    }
    return null;
  }

  final writable = firstWhere(
    (state) => state != null && editableAppInfoStates.contains(state),
  );
  if (writable != null) {
    return writable;
  }
  if (use == AppInfoUse.write) {
    return null;
  }

  final unpublished = firstWhere(
    (state) => state == null || !publishedAppInfoStates.contains(state),
  );
  if (unpublished != null) {
    return unpublished;
  }

  return infos.isEmpty ? null : infos.first;
}

/// The `appInfos` record to write to, or a refusal that says why there is
/// none and what would have gone into it.
///
/// **Reached only once something actually needs writing**, so a run that would
/// change nothing does not fail for want of a record it was never going to
/// touch. And reached before the first write, so the failure stays atomic.
///
/// [fields] names what the write would have carried. Naming it is the
/// difference between "something could not be published" and a sentence
/// somebody can act on.
Map<String, dynamic> requireWritableAppInfo(
  List<Map<String, dynamic>> infos, {
  List<String> fields = const [],
}) {
  final target = selectAppInfo(infos, AppInfoUse.write);
  if (target != null) {
    return target;
  }
  if (infos.isEmpty) {
    throw AscApiException(404, [
      'the app has no appInfos record at all',
    ], request: 'GET /v1/appInfos');
  }
  final states = infos
      .map(
        (info) => _attributes(info)['appStoreState'] as String? ?? '(unstated)',
      )
      .join(', ');
  // Deliberately unlike the 409 Apple returns when it rejects a *value*: that
  // one names a field and is answered by changing the metadata, this one is
  // answered by waiting or by making a version in App Store Connect. Two
  // errors with the same status that call for opposite actions should not
  // read alike.
  //
  // It does not claim the blocker is the published page. It often is, but
  // `IN_REVIEW` and any state this package does not recognise land here too,
  // and naming the states is what lets the reader tell which.
  throw AscApiException(409, [
    if (fields.isEmpty) ...[
      'no appInfos record is in a state that can be written to ($states).',
    ] else ...[
      'no appInfos record is in a state that can be written to ($states), and '
          '${fields.join(", ")} would have to be written.',
    ],
    'Writable states are ${editableAppInfoStates.join(", ")}. A record under '
        'review becomes writable when that review finishes, or if the '
        'submission is cancelled in App Store Connect. The published record '
        'never becomes writable, because editing it would change what is '
        'already on sale without a review seeing it.',
    // **Apple's own hint here is wrong, and it was measured wrong.** Its 409
    // says "Create the next version first", which sounds authoritative and
    // does not work: `appInfos` records belong to the *app* and versions are
    // per-platform, so creating a macOS version produced no new record on an
    // app whose two records were READY_FOR_SALE and WAITING_FOR_REVIEW. Said
    // here because following that advice costs a release cycle to disprove.
    'Creating a version does not necessarily help: appInfos records are '
        'app-level while versions are per-platform, so a new version for one '
        'platform need not produce a record to write to. Apple\'s own error '
        'suggests otherwise; it was measured not to.',
  ], request: 'GET /v1/appInfos');
}

/// Every `appCategories` relationship an `appInfos` record carries.
///
/// **cux_ship manages the first two and has never touched the other four.**
/// They are listed because the *check* has to cover what the write does not:
/// a category PATCH names only the relationships the tree declares, so it
/// always omits these four, and the open question is whether omitting a
/// relationship disturbs it.
///
/// Three things say it does not, and none of them is a measurement:
///
///   - JSON:API specifies that a relationship missing from a PATCH keeps its
///     current value.
///   - spaceship carries a separate explicit `data: nil` path for *clearing*
///     one, which would be redundant if omitting already cleared it. Two
///     distinct behaviours only make sense if they differ.
///   - fastlane omits any relationship its configuration does not name, so
///     anyone who set subcategories in App Store Connect and did not repeat
///     them in a Deliverfile would lose them on every deploy. That is not a
///     known bug, and it is a large population.
///
/// **An attempt to settle it by reading a live account came back inconclusive,
/// and is recorded here so nobody repeats it.** The idea was sound — if
/// omission cleared, an app whose categories this tool has written would have
/// lost its subcategories already. But all four slots on both records of the
/// app in question were null and always had been, so there was nothing there
/// to survive, and "omission is safe" and "omission clears and there was
/// nothing to clear" produce identical readings. Settling it needs an account
/// holding a subcategory the metadata tree does not name.
///
/// So the argument above is inference, which is what
/// [unrequestedCategoryChanges] exists to convert into a reading — on real
/// writes, as they happen.
const categoryRelationshipNames = [
  'primaryCategory',
  'primarySubcategoryOne',
  'primarySubcategoryTwo',
  'secondaryCategory',
  'secondarySubcategoryOne',
  'secondarySubcategoryTwo',
];

/// The category relationships [appInfo] reports, by relationship name.
///
/// A name maps to the `appCategories` id, or to null when Apple reported the
/// relationship as explicitly unset. A name is **absent** when the response
/// carried no `data` for it at all — which is a third thing, meaning "not
/// reported", and is why a comparison must not treat it as either value.
Map<String, String?> readCategoryRelationships(Map<String, dynamic> appInfo) {
  final relationships = appInfo['relationships'];
  if (relationships is! Map<String, dynamic>) {
    return const {};
  }
  final reported = <String, String?>{};
  for (final name in categoryRelationshipNames) {
    final link = relationships[name];
    if (link is! Map<String, dynamic> || !link.containsKey('data')) {
      continue;
    }
    final data = link['data'];
    reported[name] = data is Map<String, dynamic>
        ? data['id'] as String?
        : null;
  }
  return reported;
}

/// Category relationships that moved without the tree asking them to.
///
/// **The point is the ones nobody named.** A PATCH that sets `primaryCategory`
/// omits the other five, and if Apple treated an omitted relationship as a
/// clear, this is where that would show up — as a `secondarySubcategoryOne`
/// that held a value before the write and holds none after it, on a run that
/// reported success.
///
/// Only names present in **both** readings are compared. One that is absent
/// from either was never reported, and absence cannot be evidence of a change
/// any more than it can be evidence of a match.
List<String> unrequestedCategoryChanges({
  required Map<String, String?> before,
  required Map<String, String?> after,
  required Set<String> declared,
}) {
  final changed = <String>[];
  for (final name in categoryRelationshipNames) {
    if (declared.contains(name) ||
        !before.containsKey(name) ||
        !after.containsKey(name)) {
      continue;
    }
    if (before[name] != after[name]) {
      changed.add(name);
    }
  }
  return changed;
}

/// How a refusal names the age-rating answers.
const ageRatingField = 'age rating';

String _localeField(String locale, Iterable<String> attributes) =>
    '$locale ${attributes.join(", ")}';

/// What an app-level listing publish would change, and nothing it would not.
///
/// **Decided before anything is written, and consumed by the writes rather
/// than recomputed beside them.** A flat "does something need writing?" bool
/// beside a set of writers lets the check and the action disagree — the check
/// says a record is needed, the writers then write something else, or nothing.
/// Here the writers can only write what this says.
class AppLevelChanges {
  AppLevelChanges({
    required this.categories,
    required this.ageRating,
    required this.localizations,
    required this.contentRights,
    required this.unverifiable,
  });

  /// `primaryCategory` / `secondaryCategory` -> the `appCategories` id to set.
  ///
  /// **Every declared category, or none — because the tree is the unit of
  /// ownership.** The comparison is per field, which is the part a wrong
  /// answer hides; the payload is not narrowed below what the tree declares,
  /// because what the tree declares is what this repository claims to own.
  ///
  /// It is deliberately *not* justified by "we never send partial
  /// relationships documents", which would be false: a tree declaring only
  /// `primaryCategory` has always sent exactly that one relationship, and
  /// still does. Whether Apple leaves an unmentioned relationship alone is
  /// therefore a question this package's existing behaviour already depends
  /// on, and narrowing further would neither raise nor settle it — it would
  /// only trade a known payload for a smaller one, saving one relationship in
  /// a PATCH that is happening anyway.
  ///
  /// Note this is the opposite granularity from [ageRating], which is also
  /// sent whole but for an unrelated reason — see there. Two deliberate
  /// decisions, not one inconsistency.
  final Map<String, String> categories;

  /// The answers to push and the declaration to push them to.
  ///
  /// One field rather than an id and a map that must agree: an id with no
  /// answers and answers with no id are both meaningless, and a pair cannot
  /// drift apart.
  ///
  /// **[values] is always the whole declared set, never the differing keys**,
  /// and here the reason is Apple's validation rather than ownership: it
  /// checks these answers against each other — `socialMediaAgeRestricted` is
  /// accepted only when `ageAssurance` and `socialMedia` are both true — so a
  /// payload narrowed to one flipped answer would arrive without the two it
  /// depends on and be rejected with a 409. Measured against a live account.
  final ({String declarationId, Map<String, Object?> values})? ageRating;

  /// locale -> the `appInfoLocalizations` attributes that differ.
  final Map<String, Map<String, String>> localizations;

  /// `apps.contentRightsDeclaration`, when it differs; null when it does not.
  ///
  /// **Two independent properties, and it has both.** It is an attribute of
  /// the *app*, so writing it needs no `appInfos` record and it is not gated
  /// on acquiring one — which is why it is not counted by [needsAppInfo]. And
  /// it is still a write, so it belongs in the diff and is skipped when it
  /// would change nothing.
  final String? contentRights;

  /// Fields whose current value could not be read, named the way a refusal
  /// should name them.
  ///
  /// Each is also queued for writing where there is somewhere to write it: a
  /// value that cannot be shown to match is treated as differing, because the
  /// alternative is skipping a write on the strength of not knowing.
  ///
  /// Never holds [contentRights] — that one needs no record, so failing to
  /// read it must not drag the publish into demanding one.
  final List<String> unverifiable;

  /// Whether any of this needs an `appInfos` record to write to.
  bool get needsAppInfo =>
      categories.isNotEmpty ||
      ageRating != null ||
      localizations.isNotEmpty ||
      unverifiable.isNotEmpty;

  /// Whether the whole app-level half would write nothing at all.
  bool get isEmpty => !needsAppInfo && contentRights == null;

  /// The app-level fields a write would touch, deduplicated and named for a
  /// refusal or a progress line.
  List<String> get appInfoFields => <String>{
    ...categories.keys,
    if (ageRating != null) ...{ageRatingField},
    for (final entry in localizations.entries) ...{
      _localeField(entry.key, entry.value.keys),
    },
    ...unverifiable,
  }.toList();
}

/// Whether [metadata] carries anything Apple scopes to a version rather than
/// to the app — copyright, review notes, listing text, screenshots.
///
/// One function because two places ask it: the offline argument check, which
/// is where a missing `--version-name` should be caught, and the publish
/// itself, which must not discover it after writing the app-level half.
/// **Every field the version-scoped half writes, and the count is the check.**
/// That half writes four things — copyright, review notes, per-locale listing
/// text, screenshots — and this predicate named three. A tree carrying only
/// `info/copyright.txt` therefore reported that it needed no version, so no
/// version was created, the copyright was never written, and nothing said so.
/// Long-standing, and exactly the silent skip the rest of this file argues
/// against; it survived because the predicate was written inline beside the
/// three fields somebody was thinking about at the time.
bool listingNeedsVersion(AppStoreMetadata metadata) =>
    metadata.copyright != null ||
    metadata.reviewNotes != null ||
    metadata.locales.any(
      (locale) => locale.version.isNotEmpty || locale.screenshots.isNotEmpty,
    );

/// Whether [metadata] declares anything that lives on the app rather than on
/// a version.
///
/// A tree carrying only descriptions and screenshots declares none of it, and
/// a run over one should not report that the app-level half "already matches":
/// that would announce a comparison nobody asked for.
bool declaresAppLevelFields(AppStoreMetadata metadata) =>
    metadata.categories.isNotEmpty ||
    metadata.ageRating != null ||
    metadata.contentRights != null ||
    metadata.locales.any((locale) => locale.appInfo.isNotEmpty);

/// Compares [metadata] against what App Store Connect already holds.
///
/// Pure: every input is a value a caller has already read, so the comparison
/// itself is testable with literals. That matters more here than anywhere
/// else in this file — fastlane shipped a version of exactly this diff that
/// compared the wrong attribute name (#21657), so privacy-URL changes were
/// silently decided to be no-ops and never uploaded. A comparison that is
/// wrong in one field fails silently by construction.
///
/// [appInfo] is the record [selectAppInfo] chose to read, or null when the app
/// has none. [appInfoLocalizations] is null when there was no record to read
/// them from, which is not the same as an empty list: empty means the locale
/// genuinely does not exist yet and the write creates it.
AppLevelChanges appLevelChanges({
  required AppStoreMetadata metadata,
  required String? currentContentRights,
  required Map<String, dynamic>? appInfo,
  required Map<String, dynamic>? ageRatingDeclaration,
  required List<Map<String, dynamic>>? appInfoLocalizations,
}) {
  final differingCategories = <String>[];
  final localizations = <String, Map<String, String>>{};
  final unverifiable = <String>[];

  final relationships = appInfo?['relationships'];
  for (final entry in metadata.categories.entries) {
    final link = relationships is Map<String, dynamic>
        ? relationships[entry.key]
        : null;
    // A relationship carrying `data` is authoritative even when that data is
    // null — "no secondary category" is spelled exactly that way. A
    // relationship *without* `data` is the un-included read, which says
    // nothing about what is set, so it cannot be evidence of a match.
    if (link is Map<String, dynamic> && link.containsKey('data')) {
      final data = link['data'];
      final current = data is Map<String, dynamic> ? data['id'] : null;
      if (current != entry.value) {
        differingCategories.add(entry.key);
      }
      continue;
    }
    differingCategories.add(entry.key);
    unverifiable.add(entry.key);
  }
  // Compared field by field, sent whole. See [AppLevelChanges.categories].
  final categories = differingCategories.isEmpty
      ? const <String, String>{}
      : Map<String, String>.of(metadata.categories);

  ({String declarationId, Map<String, Object?> values})? ageRating;
  final wantedAgeRating = metadata.ageRating;
  final declaration = ageRatingDeclaration;
  if (wantedAgeRating != null) {
    final declarationId = declaration == null ? null : _id(declaration);
    if (declaration == null || declarationId == null) {
      // Nothing to write to. Recorded rather than dropped, so it still makes
      // this a run that needs a record and the caller reports it instead of
      // quietly publishing everything else.
      unverifiable.add(ageRatingField);
    } else {
      final current = declaration['attributes'];
      if (current is! Map<String, dynamic>) {
        ageRating = (declarationId: declarationId, values: wantedAgeRating);
        unverifiable.add(ageRatingField);
      } else if (wantedAgeRating.entries.any(
        // `!containsKey` first, and it is not redundant. `age-rating.json` is
        // arbitrary JSON, so a declared answer may itself be null — and then
        // an attribute Apple did not report at all reads `null == null` and
        // counts as matching, skipping the write on the strength of a
        // non-reading. The same three-state collapse the category comparison
        // above refuses, and it hides in the one comparison where both sides
        // can legitimately be null.
        (answer) =>
            !current.containsKey(answer.key) ||
            current[answer.key] != answer.value,
      )) {
        // The PATCH carries exactly the keys the repository declares and
        // overwrites rather than merges, so it changes nothing precisely when
        // every one of those keys already matches. Apple's own extra keys are
        // not this repository's to have an opinion about.
        ageRating = (declarationId: declarationId, values: wantedAgeRating);
      }
    }
  }

  for (final localeMetadata in metadata.locales) {
    final wantedText = localeMetadata.appInfo;
    if (wantedText.isEmpty) {
      continue;
    }
    if (appInfoLocalizations == null) {
      localizations[localeMetadata.locale] = Map.of(wantedText);
      unverifiable.add(_localeField(localeMetadata.locale, wantedText.keys));
      continue;
    }
    final existing = appInfoLocalizations
        .where(
          (localization) =>
              _attributes(localization)['locale'] == localeMetadata.locale,
        )
        .toList();
    if (existing.isEmpty) {
      // The locale has no record yet, so every field differs and the write
      // creates one. Not unverifiable: absence was read, not assumed.
      localizations[localeMetadata.locale] = Map.of(wantedText);
      continue;
    }
    final current = _attributes(existing.first);
    final differing = <String, String>{
      for (final entry in wantedText.entries) ...{
        if (current[entry.key] != entry.value) ...{entry.key: entry.value},
      },
    };
    if (differing.isNotEmpty) {
      localizations[localeMetadata.locale] = differing;
    }
  }

  final wantedRights = metadata.contentRights;
  return AppLevelChanges(
    categories: categories,
    ageRating: ageRating,
    localizations: localizations,
    contentRights: wantedRights == currentContentRights ? null : wantedRights,
    unverifiable: unverifiable,
  );
}

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

/// What kind of group a `betaGroups` resource says it is — or that it did
/// not say.
///
/// Three states, deliberately. This used to be a bool read `== true`, which
/// collapsed "false" and "absent": a resource not carrying the attribute
/// reported *external*, silently, on the one field the reading exists for.
/// Absent is a fact about the response — a sparse `fields[betaGroups]`
/// query, an API change — not a fact about the group, and the sites acting
/// on the kind need to decide for themselves what not knowing means there.
/// The same shape as 3.4.1's readApkFacts fix: a reader that cannot read
/// must not report a reading.
enum BetaGroupKind { internal, external, unknown }

/// The kind of [group], read from the resource rather than guessed from the
/// name, because the two kinds part ways completely: an internal group
/// receives an assigned build within minutes, an external one receives
/// nothing until beta review.
BetaGroupKind betaGroupKind(Map<String, dynamic> group) =>
    switch (_attributes(group)['isInternalGroup']) {
      true => BetaGroupKind.internal,
      false => BetaGroupKind.external,
      _ => BetaGroupKind.unknown,
    };

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

/// What a run did to an App Store version record, when it did something that
/// outlives the run.
///
/// **Both of these change what the *next* run finds.** `ensureVersion` adopts
/// an existing editable version rather than making a second one, so a promote
/// that fails after this point has already moved the state its rerun starts
/// from. A failure that does not say so invites the one response that is
/// wrong — run it again — and the second run behaves differently from the
/// first for a reason nothing printed.
enum VersionChange {
  /// A version record that did not exist before this run.
  created,

  /// An existing editable version, renamed to the requested version string.
  /// The name it had before is gone.
  renamed,
}

/// An app record, which is the one thing in this whole pipeline that a human
/// had to create by hand — `POST /v1/apps` does not exist.
class App {
  App(this.id, this.name, this.bundleId, {this.contentRights});

  final String id;
  final String name;
  final String bundleId;

  /// `contentRightsDeclaration` as the app record reported it, or null.
  ///
  /// Carried on the record this was already read from rather than fetched
  /// again, and nullable for two reasons that happen to want the same thing:
  /// Apple returns null until somebody answers the question, and a response
  /// that did not carry the attribute at all cannot be evidence either. Both
  /// mean "cannot be shown to match", and both are answered by writing it.
  final String? contentRights;
}

class AppStore {
  AppStore(this.client, this.writer, {required this.platform});

  final AscClient client;
  final Writer writer;
  final AscPlatform platform;

  /// What this run did to a version record, or null if it did nothing to one.
  ///
  /// Set by [ensureVersion] only when a write actually happened — never on a
  /// dry run, which leaves nothing behind to report. Read by the failure path,
  /// so a run that exits non-zero still names what it left.
  ({VersionChange change, String versionString, String? previousVersionString})?
  versionChange;

  /// The `reviewSubmissions` container this run created, if it created one.
  ///
  /// The sibling of [versionChange], and found the same way — by a run that
  /// failed at `POST /v1/reviewSubmissionItems`, leaving a submission in
  /// READY_FOR_REVIEW with no version in it and nothing in the output saying
  /// so. Unlike the version, a rerun *adopts* this one where it still exists:
  /// [submitForReview] looks for an open container first, because an
  /// unsubmitted one from an earlier attempt blocks a new one and Apple's
  /// error does not say so.
  ///
  /// "Where it still exists" is deliberate. An empty container was seen to
  /// disappear once its version was removed from it in the console, so it is
  /// not something to rely on finding — which is why the failure says to leave
  /// it rather than that it will be there. Leaving it is right either way: if
  /// it survives the next run reuses it, and if it does not the next run makes
  /// one. Deleting it is the only move that can make the rerun worse.
  String? createdReviewSubmission;

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
      contentRights: _attributes(app)['contentRightsDeclaration'] as String?,
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
    // Sorted, because the API promises no order and stable output is
    // diffable output. `unknown` prints as itself rather than throwing: this
    // is the command reached for while diagnosing a failed release, so one
    // group whose kind Apple withheld must not blank the listing at the
    // moment it is needed — and "unknown" is the truer diagnostic anyway, a
    // fact about the response where a guessed kind points nowhere.
    final sorted = [...groups]
      ..sort(
        (a, b) =>
            '${_attributes(a)['name']}'.compareTo('${_attributes(b)['name']}'),
      );
    for (final group in sorted) {
      final attributes = _attributes(group);
      stdout.writeln(
        '  ${attributes['name']}  '
        '${betaGroupKind(group).name}'
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
        ] else ...<String>['This app has: ${_namedKinds(existing)}.'],
      ], request: 'GET /v1/betaGroups');
    }
    return groups.first;
  }

  /// `"name" (kind), …` sorted by name — the listing's order, and the
  /// listing's treatment of `unknown`: this text exists to help a refusal,
  /// so a kind Apple withheld prints as the fact it is rather than throwing
  /// and costing the refusal, the way 4123a20 stopped the second network
  /// call from doing.
  String _namedKinds(List<Map<String, dynamic>> groups) {
    final sorted = [...groups]
      ..sort(
        (a, b) =>
            '${_attributes(a)['name']}'.compareTo('${_attributes(b)['name']}'),
      );
    return sorted
        .map((g) => '"${_attributes(g)['name']}" (${betaGroupKind(g).name})')
        .join(', ');
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
        // would have edited, so later steps describe the right thing. Nothing
        // was written, so there is nothing for a failure to report.
        return existing;
      }
      versionChange = (
        change: VersionChange.renamed,
        versionString: versionString,
        // Carried because putting it back is the remedy, and a message that
        // says "renamed something to 1.1.3" without saying what it was called
        // cannot be acted on.
        previousVersionString: was is String ? was : null,
      );
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
    if (data is! Map<String, dynamic>) {
      return null;
    }
    versionChange = (
      change: VersionChange.created,
      versionString: versionString,
      previousVersionString: null,
    );
    return data;
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

  /// Every `appInfos` record of [app] — where the name, subtitle, category
  /// and age rating live.
  ///
  /// An app always has at least one, and once a version is live it has two:
  /// the public one and the one being prepared. Which of them to use is
  /// [selectAppInfo]'s decision, taken over this whole list rather than by
  /// returning the first acceptable record, because deciding *what to write*
  /// comes before demanding something to write to.
  ///
  /// **The `include` is load-bearing, not an optimisation.** Without it the
  /// category relationships come back as links only — no `data` key at all,
  /// verified against a live account — so the record cannot answer which
  /// category is set, and every comparison against it would have to assume a
  /// difference and write.
  Future<List<Map<String, dynamic>>> appInfos(App app) => client.getAll(
    '/v1/apps/${app.id}/appInfos',
    query: {'include': 'primaryCategory,secondaryCategory'},
  );

  /// The `ageRatingDeclarations` record hanging off [appInfo], or null when
  /// Apple reported none.
  Future<Map<String, dynamic>?> ageRatingDeclaration(
    Map<String, dynamic> appInfo,
  ) async {
    final info = await client.get(
      '/v1/appInfos/${_id(appInfo)}',
      query: {'include': 'ageRatingDeclaration'},
    );
    final included = info['included'];
    if (included is List) {
      for (final resource in included.whereType<Map<String, dynamic>>()) {
        if (resource['type'] == 'ageRatingDeclarations') {
          return resource;
        }
      }
    }
    return null;
  }

  /// Every category relationship [appInfo] reports, or null if they could not
  /// be read.
  ///
  /// **Null rather than an exception, and null rather than empty.** This is
  /// only ever called to check a write that has already happened, so throwing
  /// would turn a successful publish into a failure over a diagnostic. And
  /// the caller has to be able to say "could not check" rather than printing
  /// nothing, which an empty map would invite.
  ///
  /// The `include` names four relationships this package otherwise never
  /// mentions. If Apple does not accept one, the read fails and this returns
  /// null — the check goes unmade and says so, rather than taking the whole
  /// publish down with it.
  Future<Map<String, String?>?> categoryRelationships(
    Map<String, dynamic> appInfo,
  ) async {
    try {
      final info = await client.get(
        '/v1/appInfos/${_id(appInfo)}',
        query: {'include': categoryRelationshipNames.join(',')},
      );
      final data = info['data'];
      return data is Map<String, dynamic>
          ? readCategoryRelationships(data)
          : null;
    } on AscApiException {
      return null;
    }
  }

  /// Every `appInfoLocalizations` record of [appInfo].
  ///
  /// Read once and passed to both the comparison and the write, so the two
  /// cannot disagree about whether a locale already exists.
  Future<List<Map<String, dynamic>>> appInfoLocalizations(
    Map<String, dynamic> appInfo,
  ) => client.getAll('/v1/appInfos/${_id(appInfo)}/appInfoLocalizations');

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

  /// Sets [categories], which [AppLevelChanges] has already decided is either
  /// the whole declared set or empty.
  ///
  /// **Do not narrow this to the fields that differ.** It is tempting — the
  /// comparison upstream is per field, so the differing ones are known — and
  /// the saving is one relationship in a request that is happening anyway.
  /// The declared set is the unit because the tree is what this repository
  /// owns; a category the tree does not name is not in [categories] at all,
  /// and is left to whatever App Store Connect holds.
  ///
  /// Which is worth stating precisely, because the obvious defence of this is
  /// wrong: the document sent here **is** partial whenever the tree declares
  /// one category and Apple holds two. That has always been true of this
  /// method. So "never send a partial relationships document" is not a rule
  /// this package follows and must not be offered as the reason.
  Future<void> writeCategories(
    Map<String, dynamic> appInfo,
    Map<String, String> categories,
  ) async {
    if (categories.isEmpty) {
      return;
    }
    final relationships = <String, dynamic>{
      for (final entry in categories.entries) ...{
        entry.key: relation('appCategories', entry.value),
      },
    };
    await writer.patch('/v1/appInfos/${_id(appInfo)}', {
      'data': {
        'type': 'appInfos',
        'id': _id(appInfo),
        'relationships': relationships,
      },
    }, describe: 'categories: ${categories.values.join(", ")}');
  }

  /// Writes [attributes] for [locale], creating the localization if [existing]
  /// — the records [appInfoLocalizations] already returned — has none.
  ///
  /// The list is passed in rather than read again so that the comparison which
  /// produced [attributes] and the choice between POST and PATCH are made from
  /// the same reading.
  Future<void> writeAppInfoLocalization(
    Map<String, dynamic> appInfo,
    String locale,
    Map<String, String> attributes, {
    required List<Map<String, dynamic>> existing,
  }) async {
    if (attributes.isEmpty) {
      return;
    }
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
  ///
  /// Takes the declaration id and the answers as one value from
  /// [AppLevelChanges], because the id it writes to has to be the id the
  /// answers were compared against.
  Future<void> writeAgeRating(
    ({String declarationId, Map<String, Object?> values}) ageRating,
  ) async {
    await writer.patch('/v1/ageRatingDeclarations/${ageRating.declarationId}', {
      'data': {
        'type': 'ageRatingDeclarations',
        'id': ageRating.declarationId,
        'attributes': ageRating.values,
      },
    }, describe: 'age rating (${ageRating.values.length} answers)');
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
      // Only when one was really made. A dry run creates nothing, so it has
      // nothing to leave behind and nothing to report.
      createdReviewSubmission = submissionId;
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
