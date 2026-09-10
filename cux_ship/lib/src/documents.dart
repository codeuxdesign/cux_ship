// SPDX-License-Identifier: Apache-2.0
//
// The documents `--json` prints, as classes. Specified in
// docs/design/json-output.md; this file is the shape, and its dartdoc is the
// published statement of it — pub.dev renders these classes per version, which
// is the only place a consumer can read the format without reading an encoder.
//
// **The field names are the JSON keys, and no `@JsonKey(name:)` appears here.**
// `documents_test.dart` fails on one, because the moment a key and a field
// name differ this dartdoc stops describing the JSON and starts merely
// resembling it — and a reader has no way to tell which.
//
// **The consequence, so nobody meets it during a tidy-up: a field here cannot
// be renamed for clarity.** A rename is a wire-format change and costs a
// `schema` bump, which is a strange thing to discover halfway through making
// a name nicer. That is the price of the dartdoc being the specification, and
// it is the right one — but it is a price.
//
// **A store's vocabulary reaches a caller twice: as ours, and as theirs.**
// `processingState` is this package's own closed vocabulary — documented here,
// stable, and safe to write against — and `processingStateRaw` is Apple's
// string exactly as sent. Same for `appStoreState`, `releaseType` and Play's
// `status`.
//
// Two fields rather than one, and they are two different facts: what this
// package *understood*, and what the store *said*.
//
// **The store's word is the authoritative one; ours is a reading of it.** That
// ordering matters more than it sounds. A caller writes against ours in the
// ordinary case because it is closed and does not move — but when ours says
// `unknown`, the raw field is not a second-best source, it is the whole of
// what is known. Calling it a "fallback" invites reaching for it last in
// precisely the case where it is all there is.
//
// **`unknown` is a value of our vocabulary rather than a hole in it.** It has
// a `wire` spelling of its own, so it survives a round trip — which the
// obvious alternative does not. Giving the enum Apple's spellings and letting
// `unknown` map to nothing was tried and measured:
//
//     decoded   : ReleaseType.unknown
//     re-encoded: null
//
// A `releaseType` Apple ships after this version would arrive, decode to
// `unknown`, and go back out as `null`. With a vocabulary of our own it goes
// out as `"unknown"`, and `releaseTypeRaw` still says what Apple's word was.
//
// **Members are never added because a store added a value.** Dart 3 switch
// expressions must be exhaustive, so adding one is a breaking change for every
// consumer that switched over it — and the trigger would be Apple's or
// Google's release schedule rather than anything decided here. New store
// values arrive as `unknown` with their spelling in the `*Raw` field.
//
// Absent and unknown stay different facts: a null field is a store that sent
// nothing, and `unknown` is a store that sent something this version does not
// name.
import 'package:json_annotation/json_annotation.dart';

import 'appstore/app_store.dart' show AscPlatform, editableVersionStates;

part 'documents.g.dart';

/// Which document this is, and therefore which `schema` counter applies.
///
/// **Read before `schema`.** The counters are per kind, so a reader that
/// checks the number first has checked it against nothing. Closed, with no
/// `unknown` member, because these three are this package's own names rather
/// than a store's — an unrecognized one means the document came from a version
/// that knows a kind this one does not, and refusing is the answer.
@JsonEnum(valueField: 'wire')
enum DocumentKind {
  appStoreBuilds('appstore.builds'),
  appStoreVersions('appstore.versions'),
  playTracks('play.tracks');

  const DocumentKind(this.wire);

  /// The value carried in the document's `kind` field.
  final String wire;
}

/// This package's vocabulary for Apple's `processingState`.
///
/// **The members are what this package names, not what Apple has**, and that
/// is the point rather than a shortfall: [wire] is what the document carries,
/// so a caller writes against a closed list that does not move when Apple's
/// does. [AppStoreBuildEntry.processingStateRaw] carries Apple's own word for
/// the case [unknown] covers.
@JsonEnum(valueField: 'wire')
enum ProcessingState {
  /// Apple is still processing the upload. Not releasable *yet* — see
  /// [AppStoreBuildEntry.needsNewUpload], which is the difference between this
  /// and [failed].
  processing('processing', 'PROCESSING'),

  /// Processed and usable, subject to expiry — see [AppStoreBuildEntry.usable].
  valid('valid', 'VALID'),

  /// Apple refused the binary during processing. **Terminal**: it will not
  /// become [valid] by waiting.
  failed('failed', 'FAILED'),

  /// As [failed], and equally terminal.
  invalid('invalid', 'INVALID'),

  /// Apple sent a state this version does not name.
  ///
  /// **A value of this vocabulary rather than a hole in it** — it has a [wire]
  /// spelling of its own, so it survives a round trip. What Apple actually
  /// said is in [AppStoreBuildEntry.processingStateRaw], which is the field to
  /// read when this is the answer.
  unknown('unknown', null);

  const ProcessingState(this.wire, this.appleValue);

  /// **This package's spelling, and what the document carries.** Lowercase, so
  /// a reader can tell it from [appleValue] at a glance.
  final String wire;

  /// Apple's spelling, or null for [unknown], which Apple has no word for.
  final String? appleValue;

  /// Apple's [appleValue] read as a member: [unknown] for a value this version
  /// does not name, null when Apple sent nothing.
  ///
  /// **The only place Apple's spellings are compared to anything.** A `switch`
  /// case pattern must be a compile-time constant and `processing.appleValue`
  /// is not one, so code branching on the state used to switch on string
  /// literals — `'PROCESSING'` written in the enum and again in every branch
  /// that cared. Reading to a member first makes those enum switches, which is
  /// one copy of each spelling *and* exhaustive.
  static ProcessingState? read(String? appleValue) => appleValue == null
      ? null
      : values.firstWhere(
          (s) => s.appleValue == appleValue,
          orElse: () => unknown,
        );

  /// Whether a build in [state] can only be fixed by uploading another one.
  ///
  /// **The single definition of terminal-versus-transient**, and the reason it
  /// is here rather than inside the encoder: `'VALID'`, `'FAILED'` and
  /// `'INVALID'` are compared as string literals in about eleven places in
  /// `app_store.dart` and `cli.dart`, and three of those are this same rule
  /// written out again. Putting it on the vocabulary means the next change is
  /// a deletion of those three rather than a reconciliation with a fourth.
  ///
  /// True for [failed] and [invalid], which are Apple refusing the binary, and
  /// for any expired build — **including a [valid] one**, which is the case a
  /// "will waiting help" phrasing flattens: expiry is terminal reached from a
  /// healthy state, and answering it the same way as a healthy build hides it.
  /// Null when the state is [unknown] or absent, on the same terms as every
  /// other derived answer here.
  static bool? needsNewUpload(ProcessingState? state, {required bool expired}) {
    if (expired) {
      return true;
    }
    return switch (state) {
      valid || processing => false,
      failed || invalid => true,
      unknown || null => null,
    };
  }
}

/// This package's vocabulary for a *version's* `appStoreState`.
///
/// **A version's, and not an `appInfos` record's — the same spellings govern
/// two different rules.** A version in `WAITING_FOR_REVIEW` is with Apple and
/// a write against it is rightly refused; the `appInfos` record beside it
/// still accepts a `PATCH`, measured against a live account. This package
/// keeps two sets for that reason (`editableVersionStates` and
/// `editableAppInfoStates`, which differ by exactly that state), and a
/// consumer meeting these words on an app info will reasonably reach for this
/// enum and get the version's rule. It is not the app info's.
///
/// **Incomplete on purpose, and safely so.** These are the states this
/// repository has handled or observed; Apple's vocabulary is longer and moves.
/// Anything else is [unknown], with Apple's word in
/// [AppStoreVersionEntry.appStoreStateRaw] — and the question most callers
/// actually have is answered by [AppStoreVersionEntry.editable] instead.
@JsonEnum(valueField: 'wire')
enum AppStoreState {
  prepareForSubmission('prepareForSubmission', 'PREPARE_FOR_SUBMISSION'),
  readyForReview('readyForReview', 'READY_FOR_REVIEW'),
  waitingForReview('waitingForReview', 'WAITING_FOR_REVIEW'),
  // Named on a consumer's evidence rather than this repository's: their tree
  // has met it, and `app_info_states_test.dart` here carries it too.
  accepted('accepted', 'ACCEPTED'),
  rejected('rejected', 'REJECTED'),
  developerRejected('developerRejected', 'DEVELOPER_REJECTED'),
  metadataRejected('metadataRejected', 'METADATA_REJECTED'),
  invalidBinary('invalidBinary', 'INVALID_BINARY'),
  pendingDeveloperRelease(
    'pendingDeveloperRelease',
    'PENDING_DEVELOPER_RELEASE',
  ),
  preorderReadyForSale('preorderReadyForSale', 'PREORDER_READY_FOR_SALE'),
  readyForSale('readyForSale', 'READY_FOR_SALE'),
  developerRemovedFromSale(
    'developerRemovedFromSale',
    'DEVELOPER_REMOVED_FROM_SALE',
  ),
  removedFromSale('removedFromSale', 'REMOVED_FROM_SALE'),

  /// Apple sent a state this version does not name. See
  /// [AppStoreVersionEntry.appStoreStateRaw].
  unknown('unknown', null);

  const AppStoreState(this.wire, this.appleValue);

  /// This package's spelling. See [ProcessingState.wire].
  final String wire;

  /// Apple's spelling, or null for [unknown].
  final String? appleValue;

  /// See [ProcessingState.read].
  static AppStoreState? read(String? appleValue) => appleValue == null
      ? null
      : values.firstWhere(
          (s) => s.appleValue == appleValue,
          orElse: () => unknown,
        );
}

/// How an approved version reaches the store.
///
/// Not a fraction: Apple runs its own phased schedule, so `AFTER_APPROVAL`
/// and `SCHEDULED` describe *when* rather than *how much*.
@JsonEnum(valueField: 'wire')
enum ReleaseType {
  manual('manual', 'MANUAL'),
  afterApproval('afterApproval', 'AFTER_APPROVAL'),
  scheduled('scheduled', 'SCHEDULED'),

  /// Apple sent a value this version does not name. See
  /// [AppStoreVersionEntry.releaseTypeRaw].
  unknown('unknown', null);

  const ReleaseType(this.wire, this.appleValue);

  /// This package's spelling. See [ProcessingState.wire].
  final String wire;

  /// Apple's spelling, or null for [unknown].
  final String? appleValue;

  /// See [ProcessingState.read].
  static ReleaseType? read(String? appleValue) => appleValue == null
      ? null
      : values.firstWhere(
          (t) => t.appleValue == appleValue,
          orElse: () => unknown,
        );
}

/// Play's `status` for one release on a track.
///
/// The question most callers have is [PlayReleaseEntry.serving], which is
/// derived from this — but **`serving` is not sufficient on its own**, and the
/// consumer this was built for needs both. [halted] and [draft] are both "not
/// serving" and call for different advice: one was stopped by a person, the
/// other never started. Reach for the status when the next action differs.
@JsonEnum(valueField: 'wire')
enum PlayReleaseStatus {
  /// Fully rolled out to the track's audience.
  completed('completed', 'completed'),

  /// A staged rollout is under way — some of the audience has it. The
  /// *fraction* is not in this document.
  inProgress('inProgress', 'inProgress'),

  /// A rollout that was started and stopped. The release still exists and
  /// still names its versionCodes.
  halted('halted', 'halted'),

  /// Prepared and not sent.
  draft('draft', 'draft'),

  /// Play's own "no status", which it sends rather than omitting the field.
  ///
  /// Named, and still not an answer: [PlayReleaseEntry.serving] is null here
  /// for the same reason it is null for [unknown]. Play saying "unspecified"
  /// and Play saying nothing are the same amount of information.
  statusUnspecified('statusUnspecified', 'statusUnspecified'),

  /// Play sent a value this version does not name. See
  /// [PlayReleaseEntry.statusRaw].
  unknown('unknown', null);

  const PlayReleaseStatus(this.wire, this.playValue);

  /// This package's spelling. See [ProcessingState.wire].
  ///
  /// Identical to [playValue] for every named member here, because Play's
  /// spellings already read like Dart names — which makes this the one enum
  /// where the two columns look redundant. They are not: [unknown] has a
  /// [wire] and no [playValue], and the day Play renames one the columns part.
  final String wire;

  /// Play's spelling, or null for [unknown].
  final String? playValue;

  /// See [ProcessingState.read].
  static PlayReleaseStatus? read(String? playValue) => playValue == null
      ? null
      : values.firstWhere(
          (s) => s.playValue == playValue,
          orElse: () => unknown,
        );

  /// Whether a release in [status] is in front of any of the track's audience.
  ///
  /// **The definition of [PlayReleaseEntry.serving], reachable.** It was a
  /// private function in the encoder while its twin,
  /// [ProcessingState.needsNewUpload], was a public static — an asymmetry with
  /// no argument behind it, and the consumer paid for it immediately: its test
  /// fixtures could call one rule and had to *restate* the other, which is a
  /// second copy of a rule this package owns, in a tree this package cannot
  /// see. That is the drift the derived field exists to prevent, reappearing
  /// one level up.
  ///
  /// True for [completed] and [inProgress]. False for [halted] and [draft].
  /// Null for [statusUnspecified], for [unknown], and for an absent status —
  /// three ways of not being told, and one answer.
  static bool? serving(PlayReleaseStatus? status) => switch (status) {
    completed || inProgress => true,
    halted || draft => false,
    statusUnspecified || unknown || null => null,
  };
}

String _platformToJson(AscPlatform platform) => platform.api;

AscPlatform _platformFromJson(String api) {
  for (final platform in AscPlatform.values) {
    if (platform.api == api) {
      return platform;
    }
  }
  // Closed, like [DocumentKind]: `IOS` and `MAC_OS` are the whole of what App
  // Store Connect has, and a third would be a new platform rather than a new
  // spelling — so this throws where a store *vocabulary* would degrade to
  // `unknown`. Two different kinds of open-endedness, two different answers.
  throw ArgumentError.value(api, 'platform', 'not an App Store platform');
}

/// One build App Store Connect holds, as `appstore builds --json` prints it.
@JsonSerializable(explicitToJson: true)
class AppStoreBuildEntry {
  const AppStoreBuildEntry({
    required this.buildNumber,
    required this.buildNumberAsInt,
    required this.processingState,
    required this.processingStateRaw,
    required this.uploadedDate,
    required this.expired,
    required this.usable,
    required this.needsNewUpload,
    required this.display,
  });

  factory AppStoreBuildEntry.fromJson(Map<String, dynamic> json) =>
      _$AppStoreBuildEntryFromJson(json);

  /// `CFBundleVersion`, as a string.
  ///
  /// **A string because Apple accepts a dotted one** — `1.2.3` is a legal
  /// build number. Compare with [buildNumberAsInt]; comparing this one as a
  /// string sorts build 9 above build 10.
  final String buildNumber;

  /// [buildNumber] as an integer, or null when it is not a single integer.
  ///
  /// Null rather than zero: zero would sort a dotted build below every real
  /// one and say something false about it, where null says the question does
  /// not apply.
  final int? buildNumberAsInt;

  /// **This package's reading of [processingStateRaw]**, or null when Apple
  /// sent nothing.
  ///
  /// Convenient rather than authoritative: a documented, closed vocabulary
  /// that does not move when Apple's does, so it is what to write against in
  /// the ordinary case. [ProcessingState.unknown] means this version had no
  /// word for what Apple sent, and [processingStateRaw] is then the only
  /// information there is. Most callers want [usable] or [needsNewUpload]
  /// instead of either.
  @JsonKey(unknownEnumValue: ProcessingState.unknown)
  final ProcessingState? processingState;

  /// **Apple's `processingState`, exactly as sent — the authoritative value.**
  /// Null when Apple sent none.
  ///
  /// [processingState] is this package's *reading* of this field, not the
  /// other way round. Calling this one a fallback would be backwards, and
  /// backwards in a way that costs something: when the reading is
  /// [ProcessingState.unknown] this is not a second-best source, it is the
  /// whole of what is known — so a consumer who has internalised "raw is the
  /// fallback" reaches for it last in the one case where it is all there is.
  final String? processingStateRaw;

  /// Apple's `uploadedDate`, exactly as sent.
  ///
  /// Apple's own offset-bearing spelling, not re-serialized — a `DateTime`
  /// here would render in the API docs as a Dart type a non-Dart reader has to
  /// translate, and `DateTime.toIso8601String` is not the string Apple sends.
  final String? uploadedDate;

  /// TestFlight builds expire after 90 days. An expired build is still listed
  /// and can no longer be given to a group.
  final bool expired;

  /// Whether this build could be released now: processed, and not expired.
  ///
  /// **The question, rather than the vocabulary.** A caller asking this never
  /// has to know what Apple's states are, which is the point.
  ///
  /// **It fails closed, and `false` therefore does not mean "not usable" — it
  /// means "not known to be usable".** A state this version does not name
  /// lands here as `false`, which is the right default for a flag that gates
  /// an *action*: refusing to release a build whose state is not understood is
  /// the safe direction. [serving] is nullable rather than false-by-default
  /// precisely because it gates a *report*, where false is a claim rather than
  /// a refusal. Two booleans, two consequences, two shapes.
  final bool usable;

  /// Whether this build can only be fixed by uploading another one, or null
  /// when that cannot be said.
  ///
  /// **[usable] alone hides the question an operator actually has**, and this
  /// field exists because that cost a consumer a real defect: it built advice
  /// on `usable == false` and told an operator to wait for `VALID` in every
  /// case. That is right for `PROCESSING` and wrong for `FAILED` and
  /// `INVALID`, which are Apple refusing the binary and never change again —
  /// so the advice was "wait forever" for the two states where the answer is
  /// "upload a different build".
  ///
  /// **Phrased as the action, and readable on its own.** An earlier draft
  /// called this `mayBecomeUsable`, which is `false` for a perfectly healthy
  /// `VALID` build — and `false` there reads as "give up" to anyone who has
  /// not also read [usable] first. A pair that is only safe in one reading
  /// order gets read in the other one, which is precisely how the defect above
  /// happened. This one is correct alone in every state.
  ///
  /// False while Apple is still processing and for a usable build, true once
  /// Apple has refused the binary **and for an expired build, including one
  /// that processed cleanly** — expiry is terminal reached from a healthy
  /// state, and the older phrasing gave it the same answer as a healthy build.
  /// Null for a state this version does not name.
  ///
  /// **A refused build and an expired one are the same answer here, and
  /// [expired] is what tells them apart.** Both are `usable: false,
  /// needsNewUpload: true`, because the next action genuinely is the same —
  /// upload another. What differs is what a human should be told: *rejected*
  /// and *expired* are not the same sentence, and this pair alone cannot say
  /// which. Read [expired] when the wording matters.
  final bool? needsNewUpload;

  /// The lines `cux_ship appstore builds` prints for this build.
  ///
  /// **Display text. Its content is not promised** and may change in any
  /// release without a `schema` bump; the array itself, and its being an array
  /// rather than a string, are promised. Print it; read the fields.
  final List<String> display;

  Map<String, dynamic> toJson() => _$AppStoreBuildEntryToJson(this);
}

/// Every build App Store Connect holds for one app on one platform.
@JsonSerializable(explicitToJson: true)
class AppStoreBuildsDocument {
  const AppStoreBuildsDocument({
    required this.schema,
    required this.kind,
    required this.platform,
    required this.bundleId,
    required this.newestBuildNumber,
    required this.newestBuildNumberAsInt,
    required this.builds,
    required this.display,
  });

  factory AppStoreBuildsDocument.fromJson(Map<String, dynamic> json) =>
      _$AppStoreBuildsDocumentFromJson(json);

  /// This kind's schema number. **Refuse one you do not recognize** rather
  /// than reading optimistically — see docs/design/json-output.md.
  final int schema;

  final DocumentKind kind;

  @JsonKey(toJson: _platformToJson, fromJson: _platformFromJson)
  final AscPlatform platform;

  final String bundleId;

  /// The highest build number Apple holds, whatever state it is in.
  ///
  /// Not the newest *usable* one: a build uploaded four minutes ago is the
  /// newest and cannot be released.
  final String? newestBuildNumber;

  /// [newestBuildNumber] as an integer, null on the same terms as
  /// [AppStoreBuildEntry.buildNumberAsInt].
  ///
  /// This is the field to compare against a build number out of a git tag.
  final int? newestBuildNumberAsInt;

  /// Newest first, by [AppStoreBuildEntry.buildNumberAsInt].
  final List<AppStoreBuildEntry> builds;

  /// What `cux_ship appstore builds` prints.
  ///
  /// **Not the concatenation of the builds' `display`, in either direction.**
  /// This renders twenty at most where [builds] carries everything Apple
  /// returned, and it is never empty: an empty listing renders a sentence
  /// saying so, because a caller iterating nothing prints nothing and a store
  /// the output said nothing about reads as a store with nothing wrong.
  final List<String> display;

  /// The newest build Apple holds, whatever state it is in, or null when it
  /// holds none.
  ///
  /// **[newestBuildNumber] answers "which number"; this answers "which
  /// build".** A caller wanting any other field of it — `needsNewUpload`,
  /// `expired`, `processingStateRaw` — had to find the entry itself, and the
  /// consumer that asked for this wrote a loop matching on the build number
  /// rather than take `builds.first`, which is the ordering assumption this
  /// package has been wrong about twice.
  ///
  /// `builds.first` is in fact correct: [builds] is ordered newest-first and
  /// [newestBuildNumber] is derived from that same element, so the two cannot
  /// disagree. But a promise a reader has to go and find is not the same as an
  /// accessor a test can hold, and re-deriving "which one is newest" is
  /// precisely what the model's own `newest` exists to stop a caller doing.
  ///
  /// **A getter rather than a field, deliberately**: emitting the entry would
  /// put one build in the document twice, under two keys, free to disagree —
  /// and a shell caller already has the ordering.
  AppStoreBuildEntry? get newest => builds.isEmpty ? null : builds.first;

  Map<String, dynamic> toJson() => _$AppStoreBuildsDocumentToJson(this);
}

/// One App Store version record, as `appstore versions --json` prints it.
@JsonSerializable(explicitToJson: true)
class AppStoreVersionEntry {
  const AppStoreVersionEntry({
    required this.versionString,
    required this.appStoreState,
    required this.appStoreStateRaw,
    required this.releaseType,
    required this.releaseTypeRaw,
    required this.copyright,
    required this.editable,
    required this.display,
  });

  factory AppStoreVersionEntry.fromJson(Map<String, dynamic> json) =>
      _$AppStoreVersionEntryFromJson(json);

  /// The marketing version — `1.4.0`, not a build number.
  final String versionString;

  /// This package's reading of Apple's `appStoreState`, or null when absent.
  ///
  /// Write against this; [appStoreStateRaw] is the fallback for a state it
  /// does not name. The question most callers have is [editable].
  @JsonKey(unknownEnumValue: AppStoreState.unknown)
  final AppStoreState? appStoreState;

  /// Apple's `appStoreState`, exactly as sent. See
  /// [AppStoreBuildEntry.processingStateRaw].
  final String? appStoreStateRaw;

  /// This package's reading of Apple's `releaseType`, or null when absent.
  @JsonKey(unknownEnumValue: ReleaseType.unknown)
  final ReleaseType? releaseType;

  /// Apple's `releaseType`, exactly as sent.
  final String? releaseTypeRaw;

  /// Required before review, and null by default.
  final String? copyright;

  /// Whether a write against this version would be accepted.
  ///
  /// **The question, rather than the vocabulary** — a caller asking this never
  /// has to learn which of Apple's dozen states are writable.
  final bool editable;

  /// The two lines `cux_ship appstore versions` prints for this version: the
  /// state line and the copyright line. Display text, unpromised content.
  final List<String> display;

  Map<String, dynamic> toJson() => _$AppStoreVersionEntryToJson(this);
}

/// The App Store version records for one app on one platform.
@JsonSerializable(explicitToJson: true)
class AppStoreVersionsDocument {
  const AppStoreVersionsDocument({
    required this.schema,
    required this.kind,
    required this.platform,
    required this.bundleId,
    required this.versions,
    required this.display,
  });

  factory AppStoreVersionsDocument.fromJson(Map<String, dynamic> json) =>
      _$AppStoreVersionsDocumentFromJson(json);

  /// This kind's schema number. Refuse one you do not recognize.
  final int schema;

  final DocumentKind kind;

  @JsonKey(toJson: _platformToJson, fromJson: _platformFromJson)
  final AscPlatform platform;

  final String bundleId;

  /// In the order Apple returned them, which is newest first in practice and
  /// is not promised by the API.
  final List<AppStoreVersionEntry> versions;

  /// What `cux_ship appstore versions` prints, and never empty. Display text.
  final List<String> display;

  Map<String, dynamic> toJson() => _$AppStoreVersionsDocumentToJson(this);
}

/// One release Play holds on a track.
@JsonSerializable(explicitToJson: true)
class PlayReleaseEntry {
  const PlayReleaseEntry({
    required this.name,
    required this.status,
    required this.statusRaw,
    required this.versionCodes,
    required this.newestVersionCode,
    required this.serving,
    required this.display,
  });

  factory PlayReleaseEntry.fromJson(Map<String, dynamic> json) =>
      _$PlayReleaseEntryFromJson(json);

  /// The release name, which Play generates from the version name when it was
  /// not set, or null when the response did not carry one.
  final String? name;

  /// This package's reading of Play's `status`, or null when Play sent none.
  ///
  /// Write against this; [statusRaw] is the fallback for a value it does not
  /// name, and [serving] is the question most callers actually have.
  @JsonKey(unknownEnumValue: PlayReleaseStatus.unknown)
  final PlayReleaseStatus? status;

  /// Play's `status`, exactly as sent. See
  /// [AppStoreBuildEntry.processingStateRaw].
  final String? statusRaw;

  /// Every versionCode this release serves — more than one when an app ships
  /// separate bundles per ABI.
  ///
  /// Integers here, though Play sends them as strings: that is an int64
  /// convention rather than a hint that they might not be numbers, and parsing
  /// once means "newest" is an ordering rather than a string comparison.
  final List<int> versionCodes;

  /// The highest of [versionCodes], or null when the release serves none.
  final int? newestVersionCode;

  /// Whether this release is in front of any of the track's audience, or null
  /// when that cannot be said.
  ///
  /// **The question, rather than the vocabulary**: true for a completed
  /// rollout and for one still in progress, false for a halted one and for an
  /// unsent draft. A caller asking this never has to learn Play's status
  /// strings.
  ///
  /// **Null rather than false for a status this version does not name**, and
  /// for [PlayReleaseStatus.statusUnspecified], which is Play declining to
  /// say. A `bool` cannot carry "I don't know", and both of the answers it
  /// would force are wrong: `false` reports a possibly-healthy rollout as
  /// reaching nobody, and `true` calls an unrecognized state healthy. That is
  /// the same three-valued honesty the raw [status] has one line up — a
  /// derived field that flattened it would be a worse answer than the field it
  /// is derived from.
  ///
  /// A caller wanting the conservative reading writes `serving != true`; one
  /// that wants to say so writes `serving == null`.
  ///
  /// **It does not say how much.** A staged rollout's *fraction* is not in
  /// this document, so `inProgress` means "some of the audience", not "all of
  /// it" — and `serving == true` cannot tell a 1% rollout from a finished one.
  ///
  /// **And it is not sufficient alone.** [PlayReleaseStatus.halted] and
  /// [PlayReleaseStatus.draft] are both `false` and call for different advice:
  /// one was stopped by a person, the other never started. Read [statusKnown]
  /// when the next action differs.
  final bool? serving;

  /// The line `cux_ship play tracks` prints for this release. Display text.
  final List<String> display;

  Map<String, dynamic> toJson() => _$PlayReleaseEntryToJson(this);
}

/// One Play track — `production`, `beta`, `alpha`, `internal`, or a custom
/// closed-testing track.
@JsonSerializable(explicitToJson: true)
class PlayTrackEntry {
  const PlayTrackEntry({
    required this.name,
    required this.newestVersionCode,
    required this.releases,
    required this.display,
  });

  factory PlayTrackEntry.fromJson(Map<String, dynamic> json) =>
      _$PlayTrackEntryFromJson(json);

  final String name;

  /// The highest versionCode any release on this track serves, or null when
  /// the track is empty.
  ///
  /// Highest rather than first: a track can carry more than one release at a
  /// time — a halted rollout sits alongside the one that replaced it — and
  /// Play promises no order, so "the first release listed" is not a fact about
  /// which build is on the track.
  final int? newestVersionCode;

  /// Every release on the track, including halted ones.
  final List<PlayReleaseEntry> releases;

  /// One line per release, or a single `(empty)` line for a track with none.
  /// Display text.
  final List<String> display;

  Map<String, dynamic> toJson() => _$PlayTrackEntryToJson(this);
}

/// What Google Play holds for one package.
@JsonSerializable(explicitToJson: true)
class PlayTracksDocument {
  const PlayTracksDocument({
    required this.schema,
    required this.kind,
    required this.packageName,
    required this.tracks,
    required this.uploadedVersionCodes,
    required this.display,
  });

  factory PlayTracksDocument.fromJson(Map<String, dynamic> json) =>
      _$PlayTracksDocumentFromJson(json);

  /// This kind's schema number. Refuse one you do not recognize.
  final int schema;

  final DocumentKind kind;

  final String packageName;

  /// In the order Play listed them.
  final List<PlayTrackEntry> tracks;

  /// Every bundle Play has ever accepted for this package, by versionCode.
  ///
  /// A bundle can be uploaded and assigned to no track, so this is longer than
  /// the tracks account for and is the evidence that an upload arrived at all.
  final List<int> uploadedVersionCodes;

  /// What `cux_ship play tracks` prints, and never empty.
  ///
  /// **Not the concatenation of the tracks' `display`**: a trailing line
  /// reports the uploaded bundles and belongs to no track. Display text.
  final List<String> display;

  /// The track called [name], or null when Play holds no such track.
  PlayTrackEntry? track(String name) {
    for (final track in tracks) {
      if (track.name == name) {
        return track;
      }
    }
    return null;
  }

  Map<String, dynamic> toJson() => _$PlayTracksDocumentToJson(this);
}

/// Whether [state] is one of the states a version can still be written in.
///
/// Exposed so [AppStoreVersionEntry.editable]'s rule has one definition rather
/// than two — the encoder computes it from the same set.
bool isEditableVersionState(String? state) =>
    state != null && editableVersionStates.contains(state);
