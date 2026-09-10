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
// **Enums over store vocabularies carry a permanent [unknown], and the raw
// string travels beside them.** Dart 3 switch expressions must be exhaustive,
// so adding a member is a breaking change for a consumer that switched over
// one — and the trigger would be Apple or Google shipping a state, not this
// package deciding anything. So the enum says what *this package* names, the
// string says what the store actually sent, and a value nobody here has named
// arrives as [unknown] rather than as a parse failure or a silent zero.
//
// Absent and unknown stay different facts: a null field is a store that sent
// nothing, and [unknown] is a store that sent something this version does not
// name.
//
// **The store's fields are typed `String`, and that is what keeps this
// document a passthrough rather than a re-encoding.** Typing them as enums and
// letting `json_serializable` decode them would make the wire format *ours*
// instead of Apple's: identical for every value we name, and lossy for the one
// case that matters. Measured, with `releaseType` as an enum field and
// `unknownEnumValue`:
//
//     decoded   : ReleaseType.unknown
//     re-encoded: null
//
// A `releaseType` Apple ships after this version would arrive, decode to
// `unknown`, and go back out as `null` — the raw value destroyed by a round
// trip, in exactly the situation a reader needs it. So the field carries what
// the store sent and the enum is the typed *reading* of it.
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

/// Apple's `processingState` for a build.
///
/// The members are what this package names, not what Apple has. See the note
/// at the top of this file for why that distinction is deliberate and why
/// [unknown] is permanent.
///
/// **These enums are not what travels.** The document carries the store's
/// string; this is the typed reading of it, and there is no `@JsonEnum` here
/// because nothing serializes it.
enum ProcessingState {
  /// Apple is still processing the upload. Not releasable *yet* — see
  /// [AppStoreBuildEntry.mayBecomeUsable], which is the difference between
  /// this and [failed].
  processing('PROCESSING'),

  /// Processed and usable, subject to expiry — see [AppStoreBuildEntry.usable].
  valid('VALID'),

  /// Apple refused the binary during processing. **Terminal**: it will not
  /// become [valid] by waiting.
  failed('FAILED'),

  /// As [failed], and equally terminal.
  invalid('INVALID'),

  /// A state this version does not name. The raw value is in
  /// [AppStoreBuildEntry.processingState].
  unknown(null);

  const ProcessingState(this.wire);

  /// Apple's spelling, or **null for [unknown]** — which is the one member for
  /// which there is no such thing.
  ///
  /// An earlier draft spelled it `''`, and that was a lie in the single case
  /// where the truth matters: a caller reaching for the raw value of a state
  /// nobody named would have been handed a plausible-looking empty string
  /// instead of being sent to the field that has it.
  final String? wire;

  /// [wire] read as a member: [unknown] for a value this version does not
  /// name, and null when the store sent nothing.
  ///
  /// **This is the only place Apple's spellings are compared to anything.**
  /// A `switch` case pattern must be a compile-time constant and
  /// `processing.wire` is not one, so code branching on the state used to
  /// switch on string literals — putting `'PROCESSING'` in the enum and again
  /// in every branch that cared. Reading to a member first makes the switch an
  /// enum switch, which is one copy of each spelling *and* exhaustive, so
  /// adding a member breaks the branches that have not considered it.
  static ProcessingState? read(String? wire) => wire == null
      ? null
      : values.firstWhere((s) => s.wire == wire, orElse: () => unknown);
}

/// Apple's `appStoreState` for a version record.
///
/// **Incomplete on purpose, and safely so.** These are the states this
/// repository has handled or observed; Apple's vocabulary is longer and moves.
/// Anything else is [unknown] and its raw value is in
/// [AppStoreVersionEntry.appStoreState] — and the question most callers
/// actually have is answered by [AppStoreVersionEntry.editable] instead.
enum AppStoreState {
  prepareForSubmission('PREPARE_FOR_SUBMISSION'),
  readyForReview('READY_FOR_REVIEW'),
  waitingForReview('WAITING_FOR_REVIEW'),
  rejected('REJECTED'),
  developerRejected('DEVELOPER_REJECTED'),
  metadataRejected('METADATA_REJECTED'),
  invalidBinary('INVALID_BINARY'),
  pendingDeveloperRelease('PENDING_DEVELOPER_RELEASE'),
  preorderReadyForSale('PREORDER_READY_FOR_SALE'),
  readyForSale('READY_FOR_SALE'),
  developerRemovedFromSale('DEVELOPER_REMOVED_FROM_SALE'),
  removedFromSale('REMOVED_FROM_SALE'),

  /// A state this version does not name.
  unknown(null);

  const AppStoreState(this.wire);

  /// Apple's spelling, or null for [unknown]. See [ProcessingState.wire].
  final String? wire;

  /// [wire] read as a member. See [ProcessingState.read].
  static AppStoreState? read(String? wire) => wire == null
      ? null
      : values.firstWhere((s) => s.wire == wire, orElse: () => unknown);
}

/// How an approved version reaches the store.
///
/// Not a fraction: Apple runs its own phased schedule, so `AFTER_APPROVAL`
/// and `SCHEDULED` describe *when* rather than *how much*.
enum ReleaseType {
  manual('MANUAL'),
  afterApproval('AFTER_APPROVAL'),
  scheduled('SCHEDULED'),

  /// A value this version does not name.
  unknown(null);

  const ReleaseType(this.wire);

  /// Apple's spelling, or null for [unknown]. See [ProcessingState.wire].
  final String? wire;

  /// [wire] read as a member. See [ProcessingState.read].
  static ReleaseType? read(String? wire) => wire == null
      ? null
      : values.firstWhere((t) => t.wire == wire, orElse: () => unknown);
}

/// Play's `status` for one release on a track.
///
/// The question most callers have is [PlayReleaseEntry.serving], which is
/// derived from this — but **`serving` is not sufficient on its own**, and the
/// consumer this was built for needs both. [halted] and [draft] are both "not
/// serving" and call for different advice: one was stopped by a person, the
/// other never started. Reach for the status when the next action differs.
enum PlayReleaseStatus {
  /// Fully rolled out to the track's audience.
  completed('completed'),

  /// A staged rollout is under way — some of the audience has it. The
  /// *fraction* is not in this document.
  inProgress('inProgress'),

  /// A rollout that was started and stopped. The release still exists and
  /// still names its versionCodes.
  halted('halted'),

  /// Prepared and not sent.
  draft('draft'),

  /// Play's own "no status", which it sends rather than omitting the field.
  ///
  /// Named, and still not an answer: [PlayReleaseEntry.serving] is null here
  /// for the same reason it is null for [unknown]. Play saying "unspecified"
  /// and Play saying nothing are the same amount of information.
  statusUnspecified('statusUnspecified'),

  /// A value this version does not name.
  unknown(null);

  const PlayReleaseStatus(this.wire);

  /// Play's spelling, or null for [unknown]. See [ProcessingState.wire].
  final String? wire;

  /// [wire] read as a member. See [ProcessingState.read].
  static PlayReleaseStatus? read(String? wire) => wire == null
      ? null
      : values.firstWhere((s) => s.wire == wire, orElse: () => unknown);
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
    required this.uploadedDate,
    required this.expired,
    required this.usable,
    required this.mayBecomeUsable,
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

  /// Apple's `processingState`, exactly as sent, or null when it was absent.
  ///
  /// [processingStateKnown] is the same value typed. Most callers want
  /// [usable] instead of either.
  final String? processingState;

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

  /// Whether waiting could still make this build [usable], or null when that
  /// cannot be said.
  ///
  /// **[usable] alone hides the question an operator actually has**, and this
  /// field exists because that cost a consumer a real defect: it built advice
  /// on `usable == false` and told an operator to wait for `VALID` in every
  /// case. That is right for `PROCESSING` and wrong for `FAILED` and
  /// `INVALID`, which are Apple refusing the binary and never change again —
  /// so the advice was "wait forever" for the two states where the answer is
  /// "upload a different build".
  ///
  /// True for a build still processing. False once the answer is settled,
  /// whether it settled well ([usable] is then true) or badly. **Null for a
  /// state this version does not name**, because "will waiting help" is
  /// exactly the question an unrecognized state cannot answer.
  final bool? mayBecomeUsable;

  /// The lines `cux_ship appstore builds` prints for this build.
  ///
  /// **Display text. Its content is not promised** and may change in any
  /// release without a `schema` bump; the array itself, and its being an array
  /// rather than a string, are promised. Print it; read the fields.
  final List<String> display;

  /// [processingState] as a [ProcessingState], or null when Apple sent none.
  ///
  /// [ProcessingState.unknown] when Apple sent a state this version does not
  /// name — which is not the same as null.
  ProcessingState? get processingStateKnown =>
      ProcessingState.read(processingState);

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

  Map<String, dynamic> toJson() => _$AppStoreBuildsDocumentToJson(this);
}

/// One App Store version record, as `appstore versions --json` prints it.
@JsonSerializable(explicitToJson: true)
class AppStoreVersionEntry {
  const AppStoreVersionEntry({
    required this.versionString,
    required this.appStoreState,
    required this.releaseType,
    required this.copyright,
    required this.editable,
    required this.display,
  });

  factory AppStoreVersionEntry.fromJson(Map<String, dynamic> json) =>
      _$AppStoreVersionEntryFromJson(json);

  /// The marketing version — `1.4.0`, not a build number.
  final String versionString;

  /// Apple's `appStoreState`, exactly as sent, or null when absent.
  /// [appStoreStateKnown] is the same value typed.
  final String? appStoreState;

  /// Apple's `releaseType`, exactly as sent, or null.
  /// [releaseTypeKnown] is the same value typed.
  final String? releaseType;

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

  /// [appStoreState] typed, [AppStoreState.unknown] for a state this version
  /// does not name, null when Apple sent none.
  AppStoreState? get appStoreStateKnown => AppStoreState.read(appStoreState);

  /// [releaseType] typed, on the same terms as [appStoreStateKnown].
  ReleaseType? get releaseTypeKnown => ReleaseType.read(releaseType);

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

  /// Play's `status`, exactly as sent, or null. [statusKnown] is it typed, and
  /// [serving] is the question most callers actually have.
  final String? status;

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

  /// [status] typed, [PlayReleaseStatus.unknown] for a value this version does
  /// not name, null when Play sent none.
  PlayReleaseStatus? get statusKnown => PlayReleaseStatus.read(status);

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
