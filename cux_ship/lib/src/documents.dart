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
/// `unknown` member, because these are this package's own names rather than a
/// store's — an unrecognized one means the document came from a version that
/// knows a kind this one does not, and refusing is the answer.
///
/// The word here used to be "these three", which was wrong from the moment a
/// fourth arrived and wrong again at the fifth. A count in prose is a fact that
/// goes stale without anybody editing it.
@JsonEnum(valueField: 'wire')
enum DocumentKind {
  appStoreBuilds('appstore.builds'),
  appStoreVersions('appstore.versions'),
  appStorePreviews('appstore.previews'),
  playTracks('play.tracks'),

  /// **Named for what it describes, not for the flag that produced it.**
  /// `appstore.dry-run` was the first name and named the *mode*, which would
  /// have spent the word on this document and left the next command to grow a
  /// dry run without it.
  appStoreListingDiff('appstore.listing-diff'),

  /// **The one kind that describes no store.** `verify` is offline and reads
  /// the repository, so there is no platform and no bundle id — which is why
  /// it is not `appstore.verify`.
  verify('verify'),

  /// **Its own kind rather than a field on [appStoreVersions], and the
  /// separation is the point.** This comes from the public storefront, which
  /// is a different Apple product from App Store Connect: undocumented,
  /// rate-limited, unauthenticated, with no published schema and known cases
  /// of the date being wrong. Behind one `schema` promise with the
  /// authenticated read, the day it drifts it would take that read down too.
  /// Its own kind fails in its own lane.
  ///
  /// **It describes an app, not a platform's release**, which is why
  /// [StorefrontReleasedDocument] is the one App Store document with no
  /// `platform` — measured, in docs/design/storefront-release-date.md.
  storefrontReleased('storefront.released'),

  /// One line of `play upload --json`, which is a **stream** rather than a
  /// document — see [PlayUploadEvent].
  playUpload('play.upload'),

  /// One line of `appstore upload --json`, which is a **stream** rather than a
  /// document — see [AppStoreUploadEvent].
  ///
  /// **Not what `upload --dry-run --json` prints**, which is
  /// [appStoreListingDiff] and is one whole document. A dry run transfers
  /// nothing, so it has no upload to report on; the two modes of one flag
  /// therefore carry two kinds, and a consumer that reads `kind` first — as
  /// this enum's own doc comment says to — can never confuse them.
  appStoreUpload('appstore.upload');

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
  // **The four below were Apple's all along, and this enum simply never named
  // them.** That is a different thing from the case [unknown] is for, and the
  // difference decides whether adding them is allowed: the rule above forbids
  // growing this enum *because a store added a value*, since that breaks a
  // consumer's exhaustive switch on Apple's release schedule rather than on
  // this package's. None of these is new. `IN_REVIEW` appears twice in
  // `app_store.dart`'s comments, once in `cli.dart` and seven times in
  // `app_info_states_test.dart`; `REPLACED_WITH_NEW_VERSION` is a string
  // constant in `publishedAppInfoStates` in that same file.
  //
  // What that cost while they were absent: a version Apple is looking at right
  // now decoded as `unknown`, whose own doc comment tells the reader Apple
  // sent something this version does not name — so the single most ordinary
  // state in a release read as a state nobody had ever seen.
  //
  // **And no derived `withApple` beside them, deliberately.** `IN_REVIEW` and
  // `PENDING_APPLE_RELEASE` are both "wait" and are not the same sentence —
  // one may still be rejected, the other cannot — so a boolean answering
  // "waiting on Apple" for both would hide the difference an operator's report
  // turns on. That is `usable` hiding `needsNewUpload`, one resource over.
  // docs/design/rollout-state.md argues it.
  inReview('inReview', 'IN_REVIEW'),
  pendingAppleRelease('pendingAppleRelease', 'PENDING_APPLE_RELEASE'),
  processingForAppStore('processingForAppStore', 'PROCESSING_FOR_APP_STORE'),
  replacedWithNewVersion('replacedWithNewVersion', 'REPLACED_WITH_NEW_VERSION'),
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
  /// The rollout is finished — no staged fraction is still climbing.
  ///
  /// **Not "everybody has it", and Google's own sentence is where that
  /// misreading comes from.** The Android Publisher documentation says a
  /// `completed` release's *"APKs are being served to all users"*, which is
  /// false while Google still has the release in review: the Play Console shows
  /// **In review** and no user on that track can install it. The status field
  /// describes the *rollout* the developer configured, and Play's API carries
  /// no app-review state anywhere — [serving] says the rest.
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

  /// Whether a release in [status] is *configured* to reach the track's
  /// audience.
  ///
  /// **It says nothing about whether Google has approved it.** The Play
  /// Developer API carries no app-review state on any of its resources, so a
  /// `completed` production release can sit **In review** for days with this
  /// answering true and nobody able to install it. See [completed].
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

  /// The fraction of the track's audience a release in [status] has been given.
  ///
  /// **Play omits its own `userFraction` exactly when it means one**, and that
  /// is the hole this fills. Google sets the field only for [inProgress] and
  /// [halted], so a [completed] rollout carries no fraction at all, and a
  /// caller reading Play's number alone gets `null` for the release that
  /// reached everybody, then has to learn from Google's documentation that
  /// null-beside-`completed` is what 100% looks like. That is the deferral
  /// [serving] exists to end, one field down.
  ///
  /// **Where the range comes from, because the values below lean on it.**
  /// Google's own words for `userFraction`, reaching this package through
  /// `googleapis` 16.0.0's dartdoc, which `discoveryapis_generator` writes from
  /// the Android Publisher v3 discovery document:
  ///
  /// > Fraction of users who are eligible for a staged release. 0 \< fraction
  /// > \< 1. Can only be set when status is "inProgress" or "halted".
  ///
  /// **Two honest caveats about that sentence.** It is phrased as a constraint
  /// on what may be *set*, so it binds a write directly and a read only by
  /// inference. And nothing in this repository has measured it — there is no
  /// observation of a live account here, unlike the App Store states next door.
  ///
  /// **So the values below do not depend on it for correctness, and that is
  /// the second reason [PlayReleaseEntry.userFraction] is carried rather than
  /// folded away.** If Play ever answered `1.0` for an [inProgress] release,
  /// this would return `1.0` — the same number it infers for [completed] — and
  /// the two would still be distinguishable, because **this is a function of
  /// [PlayReleaseEntry.status] and [PlayReleaseEntry.userFraction] and the
  /// document carries both of its inputs.** A caller reading `status` sees
  /// which branch produced the number: `completed` means the `1.0` is ours,
  /// `inProgress` means it is Play's.
  ///
  /// **The status is the discriminator, and not the raw field's nullness** —
  /// which is the tempting answer and is only true while the quoted sentence
  /// holds in its *second* half. Were Play to set `userFraction` on a
  /// [completed] release, ours and a full rollout would both read `1.0` beside
  /// `1.0`, and nullness would have stopped separating them. Nullness is a
  /// convenience for the common case; `status` is the guarantee.
  ///
  /// Reading [PlayReleaseEntry.audienceFraction] alone is what the range
  /// buys. Reading it beside `status` needs nothing documented about the
  /// value.
  ///
  /// `1.0` for [completed] and `0.0` for [draft] — both stated by Play's
  /// status rather than measured by it. [PlayReleaseEntry.userFraction] for
  /// [inProgress] and for [halted]: a halted release's fraction is the one it
  /// stopped at, and the users who already took it keep it.
  ///
  /// Null for [statusUnspecified], for [unknown] and for an absent status, on
  /// the same terms as every other derived answer here — **and null for an
  /// [inProgress] or [halted] release Play sent no fraction for**, which is
  /// Play contradicting its own documentation and not a case to guess at.
  ///
  /// **It measures who has it, not what the rollout is doing**, which is why
  /// it is safe to read beside [serving] in either order: a [halted] release
  /// is `serving: false` with a non-zero fraction, and both are true at once.
  static double? audienceFraction(
    PlayReleaseStatus? status, {
    required double? userFraction,
  }) => switch (status) {
    completed => 1.0,
    draft => 0.0,
    inProgress || halted => userFraction,
    statusUnspecified || unknown || null => null,
  };
}

/// Which of an upload stream's three shapes one line is.
///
/// **The discriminator, and it is read after [DocumentKind] rather than
/// instead of it.** `kind` says which store's stream this is and therefore
/// which `schema` counter applies; this says what the line carries. Both are
/// on every line, because a line is the unit a reader gets — there is no
/// enclosing document to have said it once.
///
/// Closed, with no `unknown` member, on the same argument as [DocumentKind]:
/// these are this package's own names, so one a reader does not recognize
/// means a stream from a version that knows more than the reader does. **Skip
/// the line rather than refusing the stream**, which is the one place an
/// upload stream departs from a document: a document is refused whole because
/// it is read whole, and a stream that stops being read on its first unknown
/// line throws away the [UploadEvent.result] that says the run finished.
@JsonEnum(valueField: 'wire')
enum UploadEvent {
  /// The upload moved into a new [UploadState], carried in `state`.
  state('state'),

  /// Bytes the store has taken, carried in `bytesSent` beside `bytesTotal`.
  ///
  /// **`play.upload` only.** `appstore.upload` emits none, and
  /// [AppStoreUploadEvent] says why — the reason is a property of the
  /// transport rather than something this member can carry.
  progress('progress'),

  /// The run finished, carrying what it did in `result`.
  ///
  /// **Exactly once, as the last line, and only on success.** A failure ends
  /// the stream where it happened and reports on stderr with a non-zero exit,
  /// which is `json-output.md`'s "errors stay prose on stderr" applied to a
  /// stream: **a stream with no `result` line did not finish.** So a reader
  /// has a positive completion marker rather than having to prove a negative
  /// from an exit code and a last line.
  result('result');

  const UploadEvent(this.wire);

  /// The value carried in the line's `event` field.
  final String wire;
}

/// What an upload is doing, for the stretches when it is doing one thing for
/// minutes at a time.
///
/// **This is the half a percentage cannot carry.** `45%` cannot say that the
/// transfer finished four minutes ago and the wait is now the store's, so a
/// reader watching a quiet minute cannot tell a healthy one from a wedged one.
/// A consumer renders a bar while [transferring] and this name otherwise.
///
/// **Not every member is reached by both stores, and that is the stores
/// rather than an omission here.** Play has an edit transaction and commits
/// atomically; App Store Connect has none and every write lands as it is made.
/// Each member below says which store reaches it, because a sentence about
/// "the upload" is written in whichever store its author had in mind and is
/// false about the other — `docs/CONTRIBUTING.md` has that as a rule.
///
/// Closed, with no `unknown` member, for [UploadEvent]'s reason: these are
/// this package's names, not a store's.
@JsonEnum(valueField: 'wire')
enum UploadState {
  /// Getting ready to send, before any byte moves.
  ///
  /// **Both stores, and it is a different piece of work in each.** Play
  /// inserts an edit and lists the bundles the app already has; the App Store
  /// resolves the bundle id to an app record and asks whether Apple already
  /// holds this build number.
  preparing('preparing'),

  /// Bytes are moving to the store.
  ///
  /// **Both stores**, and the event carrying it carries `bytesTotal` on both —
  /// so a consumer can say *how big* even where it cannot say *how far*.
  transferring('transferring'),

  /// The store already holds this artifact, so nothing is transferred.
  ///
  /// **Both stores.** Play answers a re-uploaded `versionCode` with a bare
  /// 403 and the App Store answers a re-uploaded `CFBundleVersion` with
  /// ITMS-90189, so both uploaders look first and reuse what is there — which
  /// is what makes a re-run after a partial release the same command typed
  /// again. Reached *instead of* [transferring], never after it.
  reusing('reusing'),

  /// Every byte is with the store and it has not yet answered.
  ///
  /// **Play only.** The last chunk of a resumable upload is the one Play
  /// answers with the `Bundle` — the versionCode it read out of the artifact —
  /// and it validates the bundle before doing so. That is a wait with no bytes
  /// left to count, which is precisely the stretch a percentage misreports as
  /// finished.
  ///
  /// The App Store has no equivalent: `xcrun altool` transfers and validates
  /// inside one opaque run, so there is no point at which this package knows
  /// the transfer is over and the wait has begun.
  accepting('accepting'),

  /// The store is processing the artifact, and this is the long one.
  ///
  /// **App Store only.** Apple takes 5–15 minutes to process a build and
  /// nothing can be attached to it until that finishes, so `upload` polls.
  /// This is the state a run spends most of its wall clock in and the one a
  /// reader most needs named — an upload that has been quiet for six minutes
  /// here is behaving exactly as designed.
  ///
  /// Play has no equivalent: a committed edit is live.
  processing('processing'),

  /// The transaction is being applied.
  ///
  /// **Play only**, and this is the moment the release becomes real: an edit
  /// holds the bundle, the track assignment and any listing writes, and
  /// `commit` applies all of it or none of it. The App Store has no edit to
  /// commit — every write there has already landed as it was made.
  committing('committing');

  const UploadState(this.wire);

  /// The value carried in the line's `state` field.
  final String wire;
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

/// Which kind of TestFlight audience a group carries.
///
/// **The distinction is the whole reason this vocabulary exists**, because the
/// two kinds are not two flavors of the same thing. Apple hands every
/// processed build to every *internal* group automatically and within minutes
/// — an explicit assignment to one is refused, `422 Builds cannot be assigned
/// to this internal group`. An *external* group receives nothing at all until
/// the build has been submitted for beta review and Apple has passed it. So a
/// build attached to both is available to one audience and not the other, and
/// a reader that counts groups without reading their kind reports the wrong
/// one.
@JsonEnum(valueField: 'wire')
enum BetaGroupKindEntry {
  /// Apple's testers-on-the-team group. Has the build as soon as it processes.
  internal('internal'),

  /// A group that receives the build only after beta review passes. See
  /// [AppStoreBuildEntry.externalBuildState], which is what says whether it
  /// has.
  external('external'),

  /// **Apple did not say which kind this group is.**
  ///
  /// A value rather than a hole, on [ProcessingState.unknown]'s terms — but
  /// unlike that one it is not a vocabulary gap: `isInternalGroup` is a
  /// boolean with no room for a state this package has not met, so this means
  /// the attribute was *absent*. A sparse `fields[betaGroups]` query or an API
  /// change, not a new kind of group.
  ///
  /// **Never resolved to a default, in either direction.** The two guesses are
  /// not symmetric and `beta_release.dart` refuses for that reason: guessing
  /// external submits an internal group for beta review, which is wrong and
  /// fails where somebody sees it; guessing internal reports an external group
  /// as already delivered, which is wrong and looks exactly like success. A
  /// consumer meeting this should say it does not know.
  unknown('unknown');

  const BetaGroupKindEntry(this.wire);

  /// The value carried in the document's `kind` field.
  final String wire;
}

/// One TestFlight group a build is attached to.
@JsonSerializable(explicitToJson: true)
class BetaGroupEntry {
  const BetaGroupEntry({required this.name, required this.kind});

  factory BetaGroupEntry.fromJson(Map<String, dynamic> json) =>
      _$BetaGroupEntryFromJson(json);

  /// Apple's name for the group, or `(unnamed)` when it carried none.
  ///
  /// **For showing, never for deciding.** A group called "External Testers"
  /// may be internal; the name is whatever somebody typed into App Store
  /// Connect. [kind] is the answer.
  final String name;

  /// Internal, external, or that Apple did not say. See [BetaGroupKindEntry].
  @JsonKey(unknownEnumValue: BetaGroupKindEntry.unknown)
  final BetaGroupKindEntry kind;

  Map<String, dynamic> toJson() => _$BetaGroupEntryToJson(this);
}

/// This package's vocabulary for Apple's `externalBuildState`.
///
/// **A build's processing state and its external state answer different
/// questions**, and conflating them is the defect this vocabulary was added
/// for: a consumer showed one TestFlight number per platform, so a build that
/// had merely finished processing rendered identically to one external testers
/// actually had. [ProcessingState.valid] means Apple finished ingesting the
/// binary. This says who can install it.
///
/// The members are what this package names, not what Apple has — see
/// [ProcessingState], whose argument this follows exactly.
/// [AppStoreBuildEntry.externalBuildStateRaw] carries Apple's own word.
@JsonEnum(valueField: 'wire')
enum ExternalBuildState {
  /// Apple is still processing the upload, so no audience has it yet.
  processing('processing', 'PROCESSING'),

  /// Processing ended in an error. Terminal.
  processingException('processingException', 'PROCESSING_EXCEPTION'),

  /// The build cannot be submitted until export compliance is answered.
  missingExportCompliance(
    'missingExportCompliance',
    'MISSING_EXPORT_COMPLIANCE',
  ),

  /// Apple is reviewing the export compliance answer.
  inExportComplianceReview(
    'inExportComplianceReview',
    'IN_EXPORT_COMPLIANCE_REVIEW',
  ),

  /// **Processed, and never submitted for beta review.** The state a build
  /// sits in after an upload that was not followed by a beta release — which
  /// is the ordinary state of the newest build most of the time, and the one
  /// most easily mistaken for "the testers have it".
  readyForBetaSubmission('readyForBetaSubmission', 'READY_FOR_BETA_SUBMISSION'),

  /// Submitted, and Apple has not started the review.
  waitingForBetaReview('waitingForBetaReview', 'WAITING_FOR_BETA_REVIEW'),

  /// Apple is reviewing it now.
  inBetaReview('inBetaReview', 'IN_BETA_REVIEW'),

  /// **Apple refused the build for external testing.** Terminal: the API never
  /// carries the reason, which arrives by e-mail and in App Store Connect.
  betaRejected('betaRejected', 'BETA_REJECTED'),

  /// Review passed. Not the same as [inBetaTesting] — approval is Apple's
  /// verdict, delivery is the group assignment.
  betaApproved('betaApproved', 'BETA_APPROVED'),

  /// Apple reports the build ready to give to external testers.
  readyForBetaTesting('readyForBetaTesting', 'READY_FOR_BETA_TESTING'),

  /// **Beta review has cleared and Apple describes the build as in testing.**
  ///
  /// **Not sufficient on its own, and this used to say it was.** It read *the
  /// one state that answers yes*, which contradicted
  /// [AppStoreBuildEntry.inExternalTesting] once that moved to two facts:
  /// delivery is this state *or* [betaApproved] *or* [readyForBetaTesting],
  /// **and** an attached external group. A state says Apple would allow it; an
  /// attachment says somebody asked for it. Read that field rather than
  /// comparing against this member.
  ///
  /// It is also the state Apple did not once use across 123 builds measured
  /// 2026-09-14 — [betaApproved] is the terminal one after review — so a
  /// predicate written against this member alone is a constant `false`, which
  /// is the defect `inExternalTesting` was changed to fix.
  inBetaTesting('inBetaTesting', 'IN_BETA_TESTING'),

  /// The build's ninety days are up.
  expired('expired', 'EXPIRED'),

  /// Apple sent a state this version does not name. What Apple said is in
  /// [AppStoreBuildEntry.externalBuildStateRaw]. See [ProcessingState.unknown].
  unknown('unknown', null);

  const ExternalBuildState(this.wire, this.appleValue);

  /// This package's spelling, and what the document carries.
  final String wire;

  /// Apple's spelling, or null for [unknown], which Apple has no word for.
  final String? appleValue;

  /// Apple's [appleValue] read as a member: [unknown] for a value this version
  /// does not name, null when Apple sent nothing. See [ProcessingState.read],
  /// which says why reading to a member first is what makes the branches
  /// exhaustive.
  static ExternalBuildState? read(String? appleValue) => appleValue == null
      ? null
      : values.firstWhere(
          (s) => s.appleValue == appleValue,
          orElse: () => unknown,
        );
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
    required this.betaGroups,
    required this.unresolvedBetaGroups,
    required this.externalBuildState,
    required this.externalBuildStateRaw,
    required this.inExternalTesting,
    required this.unresolvedBuildBetaDetail,
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
  /// the safe direction. [PlayReleaseEntry.serving] is nullable rather than
  /// false-by-default precisely because it gates a *report*, where false is a
  /// claim rather than a refusal. Two booleans, two consequences, two shapes.
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

  /// The TestFlight groups this build is attached to, **or null when the read
  /// did not ask**.
  ///
  /// **Null and `[]` are different answers, and a consumer that treats them
  /// alike reports the wrong one confidently.** `[]` is Apple saying the build
  /// is attached to no group; null is this package not having sent
  /// `include=betaGroups`, which every read before schema 2 did. The second
  /// renders as *no external testers have this* — true most of the time, which
  /// is exactly why it goes unnoticed when it is not.
  ///
  /// Internal and external groups are both here and are told apart by
  /// [BetaGroupEntry.kind], never by counting or by name.
  ///
  /// **A lower bound rather than the list when [unresolvedBetaGroups] is not
  /// zero.** Every group here is one Apple named *and* sent; read that field
  /// before treating `[]` as *attached to nothing*.
  final List<BetaGroupEntry>? betaGroups;

  /// How many attached groups Apple named and did not send, normally `0`.
  ///
  /// **A third reading of an empty [betaGroups], and the one that is about the
  /// response rather than the build.** `null` is *this read did not ask*, `[]`
  /// with this at `0` is *Apple says the build is attached to nothing*, and
  /// `[]` with this above `0` is *Apple named attachments and this listing did
  /// not receive them*. Only the middle one is a fact about the build, and a
  /// consumer that renders the third as the second reports *no external
  /// testers have this* out of a shortfall.
  ///
  /// [inExternalTesting] is null rather than false in that case for exactly
  /// this reason, so a consumer reading only that flag is already safe. This
  /// field is for one that wants to say *why*.
  ///
  /// **Required by [AppStoreBuildEntry.fromJson], and that is a fact about
  /// timing rather than a general rule.** It and [unresolvedBuildBetaDetail]
  /// are non-nullable with no default, so a document lacking them is refused:
  /// a default of `0` would read a document's silence as *nothing was
  /// missing*, which is the reading these two exist to prevent, turned on
  /// themselves. That is only safe because schema 2 had not shipped when they
  /// were added, so no document outside this repository was ever written
  /// without them. **Adding a required field to a schema that has shipped is a
  /// new schema number**, not a stricter decoder — a reader would be refusing
  /// documents this package told it to accept.
  final int unresolvedBetaGroups;

  /// **This package's reading of [externalBuildStateRaw]**, or null when Apple
  /// sent nothing. See [ExternalBuildState], and see [processingState], whose
  /// relationship to its own raw field this mirrors exactly.
  @JsonKey(unknownEnumValue: ExternalBuildState.unknown)
  final ExternalBuildState? externalBuildState;

  /// **Apple's `externalBuildState`, exactly as sent — the authoritative
  /// value.** Null when Apple sent none, which includes a read that did not
  /// ask for `include=buildBetaDetail`.
  final String? externalBuildStateRaw;

  /// Whether external testers can install this build now, or null when that
  /// cannot be said.
  ///
  /// **Nullable rather than false-by-default, and the choice is the one
  /// [usable] argues in the other direction.** That flag gates an *action* —
  /// releasing a build whose state is not understood — so failing closed to
  /// `false` is a refusal and is safe. This one gates a *report*: `false`
  /// here is the claim *external testers do not have this build*, and making
  /// an unread relationship or an unnamed state say it out loud is the defect
  /// this field was added to fix rather than a safe default. Null says the
  /// question was not answered, which is what a consumer should show.
  ///
  /// **False for an expired build whatever else is true of it.** TestFlight
  /// withdraws a build after ninety days, so a build that cleared review and
  /// is attached to an external group is still one nobody can install — and
  /// this answered `true` for exactly that combination until review caught it.
  /// The `false` is a refusal like [usable]'s rather than a claim, and it is
  /// the one reading here that does not need [betaGroups] to have been read.
  ///
  /// **Two facts and not one**, once it is not expired: true when the build
  /// has cleared beta review —
  /// [ExternalBuildState.betaApproved], [ExternalBuildState.readyForBetaTesting]
  /// or [ExternalBuildState.inBetaTesting] — *and* [betaGroups] holds at least
  /// one group whose kind is [BetaGroupKindEntry.external]. Apple's verdict is
  /// not delivery, and an attachment made while review is still pending is not
  /// delivery either, so neither half answers on its own.
  ///
  /// Reading the state alone was this field's first shape, and it was a
  /// constant `false` against a real account: over 51 iOS builds measured
  /// 2026-09-14, Apple's terminal external state after review is
  /// `BETA_APPROVED` and `IN_BETA_TESTING` did not occur once, so fourteen
  /// builds external testers demonstrably had reported that they did not.
  ///
  /// **Null when this listing was answered short *and* the missing part could
  /// have changed the answer** — see [unresolvedBetaGroups] and
  /// [unresolvedBuildBetaDetail], which say which of the two inputs went
  /// missing and are `0` and `false` on a complete read.
  ///
  /// The qualifier is load-bearing and this said *null when answered short*
  /// without it, which is wrong in the one case a reader would hit first: a
  /// build with a resolved external group and a shortfall beside it answers
  /// `true`, because the groups that did not arrive could only have added
  /// attachments. A shortfall makes an *empty* external list uninformative,
  /// not a non-empty one.
  final bool? inExternalTesting;

  /// Whether Apple named a build beta detail for this build and did not send
  /// it, normally `false`.
  ///
  /// **True means [externalBuildStateRaw]'s null is about the response, not
  /// about the build.** Apple caps sideloaded resources per response, and at
  /// the wrong page size a listing runs off the end of that cap while the
  /// relationship still names every resource — so the state came back null for
  /// a fifth of a 72-build account with nothing saying so. That is fixed at
  /// the request: `cux_ship` now reads a page no larger than the cap.
  ///
  /// **So this should always be `false`, and it is published anyway.** It is
  /// what tells a consumer that the fix has stopped working — Apple lowering
  /// the ceiling, or this package adding a third sideloaded resource — instead
  /// of the same silent nulls returning. A consumer can reasonably treat
  /// `true` as *this row is not trustworthy, re-read*; what it must not do is
  /// treat it as a fact about the build.
  final bool unresolvedBuildBetaDetail;

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
    required this.buildNumber,
    required this.buildNumberAsInt,
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
  ///
  /// **And the only derived answer this entry carries**, which is deliberate
  /// and was decided against a draft that added a second.
  ///
  /// "Is it still in review" looks like the next one to add, and
  /// [appStoreState] answers it directly now that [AppStoreState.inReview]
  /// exists. A boolean over the states was designed, argued to three drafts
  /// and dropped: the one consumer that would read it renders **five** distinct
  /// outcomes across the review and release states, so any boolean is a
  /// coarsening of what it already prints rather than an answer it lacks.
  /// docs/design/rollout-state.md records the drafts and the evidence.
  final bool editable;

  /// The `CFBundleVersion` of the build attached to this version, or null when
  /// Apple named none.
  ///
  /// **The question [versionString] cannot answer**: two builds of `1.4.0` are
  /// the same version and different binaries, so *"is what is live the thing I
  /// think is live"* needs this one. It arrives in the same request — Apple's
  /// version record carries the build as a relationship rather than an
  /// attribute, and this package asks for it to be included.
  ///
  /// A `String` on the same terms as [AppStoreBuildEntry.buildNumber], because
  /// Apple accepts a dotted `CFBundleVersion`; [buildNumberAsInt] is the form
  /// to compare.
  ///
  /// **Null is one answer over two causes and does not diagnose which.** Apple
  /// names no build for a version in `PREPARE_FOR_SUBMISSION`; a request that
  /// did not carry the include would answer null here too. The second was
  /// measured not to happen — without it the relationship has no `data` key at
  /// all — and the first has never been observed, because the account this was
  /// measured against held six versions and all of them were `READY_FOR_SALE`.
  /// So this reports a null rather than an explanation.
  final String? buildNumber;

  /// [buildNumber] as an integer, null on the same terms as
  /// [AppStoreBuildEntry.buildNumberAsInt] — and null again whenever
  /// [buildNumber] is.
  ///
  /// **This is the field to compare against a build number out of a git tag**,
  /// and the reason it is emitted rather than left to the caller is the one
  /// [AppStoreBuildsDocument.newestBuildNumberAsInt] gives: `"9"` sorts above
  /// `"10"`, and a shell caller has no second hop to reach the parsed form.
  final int? buildNumberAsInt;

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

/// One preview video Apple holds on a version.
///
/// **Apple's field names, deliberately.** The consumer asked for this and it
/// is right: `videoDeliveryState`, `previewFrameImage` and
/// `previewFrameTimeCode` are what Apple's own documentation calls these, so a
/// reader can put this document beside the App Store Connect API reference
/// without a translation table. Where this package has an opinion it says so
/// in a separate field rather than renaming Apple's.
///
/// **Two states, not one, because Apple ingests two assets.** The video is
/// processed and the poster frame is cut out of it afterwards; a preview is
/// finished only when both say `COMPLETE`, and a caller that watched one would
/// call a half-finished preview ready. Both are Apple's strings rather than a
/// closed vocabulary of ours: nothing here has seen enough of them to name a
/// stable set, and inventing one would be this package claiming knowledge it
/// does not have.
@JsonSerializable(explicitToJson: true)
class AppStorePreviewEntry {
  const AppStorePreviewEntry({
    required this.id,
    required this.locale,
    required this.previewType,
    required this.fileName,
    required this.videoDeliveryState,
    required this.previewFrameImageState,
    required this.previewFrameTimeCode,
    required this.done,
  });

  factory AppStorePreviewEntry.fromJson(Map<String, dynamic> json) =>
      _$AppStorePreviewEntryFromJson(json);

  /// Apple's `appPreviews` id, which is the only thing that addresses it.
  final String? id;

  /// The `appStoreVersionLocalizations` locale this preview hangs off, such as
  /// `en-US`. Two collections up from the preview itself, and the half of what
  /// names it to a person.
  final String? locale;

  /// Apple's `PreviewType` — `IPHONE_67` and so on.
  ///
  /// **Not a `ScreenshotDisplayType`.** Apple keeps two enumerations and the
  /// preview one has no prefix; a reader comparing this against a screenshot
  /// document is comparing different vocabularies.
  final String? previewType;

  final String? fileName;

  /// Apple's `videoDeliveryState.state`, verbatim, or null when it reported
  /// none.
  ///
  /// Null is a fact about the response rather than a stage. Apple deprecated
  /// `assetDeliveryState` on this resource; a reader consulting that instead
  /// gets null for every preview.
  final String? videoDeliveryState;

  /// Apple's `previewFrameImage.state.state`, verbatim, or null.
  ///
  /// Null is ordinary early on — Apple cuts the frame after ingesting the
  /// video — and on at least one real upload stayed null for minutes while the
  /// video was already `COMPLETE`.
  final String? previewFrameImageState;

  /// The frame the product page poses on, as `HH:MM:SS:FF`, or null.
  ///
  /// **The one input nobody can correct after approval**, and the reason this
  /// document exists at all for the consumer that asked: it is invisible in
  /// every other output, and a preview posed at Apple's default looks exactly
  /// like one posed deliberately.
  final String? previewFrameTimeCode;

  /// Whether Apple has finished with *both* assets.
  ///
  /// This package's reading rather than Apple's word, kept beside the two raw
  /// states rather than instead of them — the same split the build documents
  /// make between `processingState` and `processingStateRaw`.
  final bool done;

  Map<String, dynamic> toJson() => _$AppStorePreviewEntryToJson(this);
}

/// What `appstore previews --json` prints.
@JsonSerializable(explicitToJson: true)
class AppStorePreviewsDocument {
  const AppStorePreviewsDocument({
    required this.schema,
    required this.kind,
    required this.platform,
    required this.bundleId,
    required this.versionName,
    required this.previews,
    required this.display,
  });

  factory AppStorePreviewsDocument.fromJson(Map<String, dynamic> json) =>
      _$AppStorePreviewsDocumentFromJson(json);

  /// This kind's schema number. Refuse one you do not recognize.
  final int schema;

  final DocumentKind kind;

  @JsonKey(toJson: _platformToJson, fromJson: _platformFromJson)
  final AscPlatform platform;

  final String bundleId;

  /// The version these previews hang off. Previews are version-scoped, so a
  /// document without it names assets nobody can locate.
  final String versionName;

  /// Every preview on the version, across locales and preview types. Empty is
  /// a real answer: a version may carry none.
  final List<AppStorePreviewEntry> previews;

  /// What `cux_ship appstore previews` prints. Display text.
  final List<String> display;

  Map<String, dynamic> toJson() => _$AppStorePreviewsDocumentToJson(this);
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
    required this.userFraction,
    required this.audienceFraction,
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

  /// Whether the rollout is still configured to hand this release to new
  /// users, or null when that cannot be said.
  ///
  /// **The question, rather than the vocabulary**: true for a completed
  /// rollout and for one still in progress, false for a halted one and for an
  /// unsent draft. A caller asking this never has to learn Play's status
  /// strings.
  ///
  /// **It is not "the release is live", and the gap is Google's review.** The
  /// Play Developer API carries no app-review state on any resource, so a
  /// `completed` production release that Google has not yet approved answers
  /// `true` here while the Play Console says **In review** and no user can
  /// install it. A caller rendering a store-status column must not print this
  /// as *live*; print the rollout, and say nothing the API did not.
  ///
  /// This is the second correction to this sentence of the same shape as the
  /// paragraph below, and the two together are the argument for the wording:
  /// **the field is about the rollout the developer configured, and every
  /// reading of it as availability has so far been wrong.** The first was found
  /// by a field arriving beside it; the second by a person opening the Play
  /// Console after this package's own consumer reported a release live that was
  /// not. See [PlayReleaseStatus.completed].
  ///
  /// **"Still being handed out" and not "in front of anybody", and the
  /// difference is [PlayReleaseStatus.halted].** This field said the second
  /// thing until
  /// [userFraction] arrived beside it and made the two visibly disagree:
  /// Google's own wording for a halted release is *"Users who already have
  /// these APKs are unaffected"*, so a halted rollout **is** in front of the
  /// fraction that installed it, while this answers `false`. The `false` is
  /// right — what an operator asking "is this rollout stopped" means is
  /// whether anyone new is still getting it — and the sentence describing it
  /// was the part that was wrong. Read [audienceFraction] for who has it.
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
  /// **It does not say how much.** `inProgress` means "some of the audience"
  /// rather than "all of it", so `serving == true` cannot tell a 1% rollout
  /// from a finished one. [audienceFraction] is the field that can, and it is
  /// a separate one on purpose: a three-valued boolean that also carried a
  /// magnitude would be two answers under one key.
  ///
  /// **And it is not sufficient alone.** [PlayReleaseStatus.halted] and
  /// [PlayReleaseStatus.draft] are both `false` and call for different advice:
  /// one was stopped by a person, the other never started. Read [status] when
  /// the next action differs.
  final bool? serving;

  /// **Play's `userFraction`, exactly as sent — the authoritative value.**
  /// Null when Play sent none.
  ///
  /// Google sets it only for [PlayReleaseStatus.inProgress] and
  /// [PlayReleaseStatus.halted], and documents it as `0 < fraction < 1` —
  /// cited, and caveated, on [PlayReleaseStatus.audienceFraction]. So **null
  /// here is not "no rollout"**: a [PlayReleaseStatus.completed] release
  /// carries no fraction precisely because it reached everybody, which is the
  /// one case where reading this field instead of [audienceFraction] gives the
  /// opposite of the right answer.
  ///
  /// **And it is load-bearing even for a caller that never reads it.** It is
  /// the second input to [audienceFraction], so carrying it is what lets a
  /// caller recompute that field rather than trust it — and
  /// [PlayReleaseStatus.audienceFraction] states why the recomputation, not
  /// this field's nullness, is what survives Google's documented range being
  /// wrong.
  ///
  /// **Unread and load-bearing are compatible**, which is worth saying because
  /// the two get filed together. A field nobody reads can usually be deleted
  /// at no cost to anyone; deleting this one would leave [audienceFraction]
  /// checkable only against a sentence in a dependency's generated dartdoc.
  /// Unread is a fact about callers, load-bearing is a fact about the
  /// document, and only the first is an argument about whether a field earns
  /// its place.
  ///
  /// Spelled with Play's own key rather than as a `*Raw` sibling, which the
  /// enums beside it need because ours and theirs share a name. Here they do
  /// not, so there is one name per fact instead of three names for two.
  final double? userFraction;

  /// **This package's answer: the fraction of the track's audience that has
  /// been given this release.** Null when that cannot be said.
  ///
  /// [PlayReleaseStatus.audienceFraction] is the rule, so it has one
  /// definition rather than a copy here and another in a consumer's fixtures —
  /// the asymmetry that cost [PlayReleaseStatus.serving] a round trip through
  /// a consumer's tree before it was made public.
  ///
  /// **Named for what it measures rather than for the process**, and that is
  /// the whole of why it is not `rolloutFraction`. On a
  /// [PlayReleaseStatus.halted] release `rolloutFraction: 0.2` reads as *"the
  /// rollout is at 20%"*, which sounds live, with [serving]`: false` beside it
  /// saying otherwise — a pair correct in only one reading order, which is
  /// exactly the mechanism [AppStoreBuildEntry.needsNewUpload] was renamed to
  /// escape. *Who has it* is true in every state on its own.
  ///
  /// **Three things it is not**, because a bare number is read as more than it
  /// is:
  ///
  /// - Not a fraction of the app's users. It is a fraction of the **track's**
  ///   audience, and an `internal` track's audience is a list of addresses.
  /// - Not adjusted for country targeting. Play can restrict a release to a
  ///   set of countries; this document carries neither that field nor its
  ///   `includeRestOfWorld` flag, so a targeted rollout's fraction is a
  ///   fraction of the targeted set.
  /// - Not a statement about *which* devices. Play chooses who is eligible.
  final double? audienceFraction;

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

/// One artifact `verify` looked at, or declined to.
///
/// **`what` is a kind rather than a sentence**, so a caller can branch on it —
/// `changelog`, `section`, `appstore`, `play`, `data-safety`. [where] says
/// which one, absent when there was nothing to find.
@JsonSerializable(explicitToJson: true)
class VerifyCheck {
  const VerifyCheck({required this.what, this.where, this.why});

  factory VerifyCheck.fromJson(Map<String, dynamic> json) =>
      _$VerifyCheckFromJson(json);

  /// What kind of artifact this is.
  final String what;

  /// Which one, for a check that ran. Null in [VerifyDocument.skipped].
  ///
  /// **Not called `path`, which is what it was first**, because two of the
  /// five are not paths: `section` carries `1.0.1 (pubspec.yaml)` — a version
  /// and where it was declared — and `appstore` carries the tree with the
  /// platform it was checked against, since one path cannot say which of the
  /// two rule sets applied. A field named `path` holding those would be a name
  /// a consumer could reasonably `File()` and be wrong about.
  ///
  /// It is exactly the string the report prints after the artifact's name, so
  /// the document and the prose cannot drift.
  final String? where;

  /// Why it did not run. Null in [VerifyDocument.checked].
  ///
  /// A sentence, because the reason is for a person: the caller has already
  /// branched on [what] by the time it reads this.
  final String? why;

  Map<String, dynamic> toJson() => _$VerifyCheckToJson(this);
}

/// `cux_ship verify --json`.
///
/// **[checked] and [skipped] are the point, not [ok].** A caller reading `ok:
/// true` alone has learned nothing about *coverage* — which is the defect the
/// prose version was changed to close, when a clean run printed one line and a
/// reader could not tell whether the data safety declaration had been
/// validated or silently passed over.
///
/// [checked] alone was not enough either, and the consumer said why: a reader
/// notices an omission only by already holding the expected set in their head,
/// so a check that silently did not run is invisible unless somebody is
/// keeping the list. [skipped] makes it impossible to miss rather than merely
/// possible to catch — **absence stops being inferred from what is not in a
/// list**, which is a thing nobody does reliably.
@JsonSerializable(explicitToJson: true)
class VerifyDocument {
  const VerifyDocument({
    required this.schema,
    required this.kind,
    required this.ok,
    required this.checked,
    required this.skipped,
    required this.problems,
    required this.display,
  });

  factory VerifyDocument.fromJson(Map<String, dynamic> json) =>
      _$VerifyDocumentFromJson(json);

  /// This kind's schema number. Refuse one you do not recognize.
  final int schema;

  final DocumentKind kind;

  /// Whether every check that ran found nothing.
  ///
  /// **Not "the release is publishable" on its own** — read it beside
  /// [skipped], because a run that checked one artifact and skipped three is
  /// `ok: true` and says almost nothing.
  final bool ok;

  /// Every artifact that was inspected, with where it was found.
  final List<VerifyCheck> checked;

  /// Every artifact that was not, with why.
  final List<VerifyCheck> skipped;

  /// What was wrong, each written for a person to read and fix.
  ///
  /// **Strings rather than structure, deliberately.** Nobody has asked to
  /// branch on a problem's identity — the consumer prints them and counts
  /// them — and starting with strings makes a structured version an addition
  /// rather than a replacement. See `dry-run-json.md`.
  final List<String> problems;

  /// What `cux_ship verify` prints. Display text.
  final List<String> display;

  Map<String, dynamic> toJson() => _$VerifyDocumentToJson(this);
}

/// What one scope of a listing would have written.
///
/// **Field names, not values.** A document carrying both copies of every
/// string is one nobody reads, and the tree is on disk while the store is one
/// read away — so naming `en-US` and `description, keywords` is enough for a
/// reader to act, which means opening the command. Values are an addition
/// later rather than a removal.
@JsonSerializable(explicitToJson: true)
class ListingChangeSet {
  const ListingChangeSet({required this.fields, required this.localizations});

  factory ListingChangeSet.fromJson(Map<String, dynamic> json) =>
      _$ListingChangeSetFromJson(json);

  /// Scope-wide fields that differ, e.g. `copyright`, `contentRights`,
  /// `ageRating`, `categories`, `reviewDetails`.
  final List<String> fields;

  /// Locale to the attribute names that differ in it.
  final Map<String, List<String>> localizations;

  Map<String, dynamic> toJson() => _$ListingChangeSetToJson(this);
}

/// `cux_ship appstore upload --metadata … --dry-run --json`.
///
/// **[matches] is the answer and the reason this exists.** A readiness check
/// asking *"is the store still showing the repository's listing?"* had to run
/// the dry run and match its prose with a regular expression, which is the
/// thing this package exists to stop people doing.
///
/// **It is not a claim that the store page is correct**, and the difference is
/// load-bearing. It means every field this repository *declares* agrees with
/// Apple. A field the tree does not name is not compared, because "present
/// means owned" is the tree's rule everywhere — so a description edited in App
/// Store Connect, in a locale the tree does not carry, is invisible to it.
///
/// [appleOnlyLocales] is that exclusion made visible rather than merely
/// unclaimed. Without it, `matches: true` beside a `de-DE` nobody here declares
/// is a true statement whose reader draws a stronger conclusion — the same
/// shape as a rollout status reading as "live" when the store had not approved
/// it.
@JsonSerializable(explicitToJson: true)
class AppStoreListingDiffDocument {
  const AppStoreListingDiffDocument({
    required this.schema,
    required this.kind,
    required this.platform,
    required this.bundleId,
    required this.versionName,
    required this.matches,
    required this.version,
    required this.app,
    required this.assets,
    required this.appleOnlyLocales,
    required this.display,
  });

  factory AppStoreListingDiffDocument.fromJson(Map<String, dynamic> json) =>
      _$AppStoreListingDiffDocumentFromJson(json);

  /// This kind's schema number. Refuse one you do not recognize.
  final int schema;

  final DocumentKind kind;

  @JsonKey(toJson: _platformToJson, fromJson: _platformFromJson)
  final AscPlatform platform;

  final String bundleId;

  /// The version the listing was compared against, or null when the tree
  /// declares nothing Apple scopes to a version.
  final String? versionName;

  /// **The answer**: true when nothing this repository declares would change.
  ///
  /// Covers all three scopes — [version], [app] and [assets]. It shipped
  /// covering the first two, so a replaced screenshot reported `true`.
  ///
  /// **False whenever the comparison could not be made**, which is not the
  /// same statement as "something differs" and is deliberately reported the
  /// same way. A dry run creates no version, so a tree whose version Apple
  /// does not hold yet has nothing to compare against — and in that state
  /// every version-scoped field would in fact be written, so `false` is also
  /// the truthful answer. It returned `true` there, reading absence as
  /// agreement, on every dry run before a release is prepared.
  ///
  /// Read [appleOnlyLocales] beside it before saying the listing matches.
  final bool matches;

  /// Version-scoped differences — the listing text, copyright, review details.
  final ListingChangeSet version;

  /// App-scoped differences — categories, age rating, content rights, and the
  /// app-info localizations.
  final ListingChangeSet app;

  /// Screenshot and preview sets that differ, as `<type> <kind>`.
  ///
  /// **Not a [ListingChangeSet], because an asset set has no field names.**
  /// What differs is the set itself — its files, or a preview's poster frame —
  /// and naming the type and kind is what a reader acts on.
  final List<String> assets;

  /// Locales Apple holds that the tree never mentions.
  ///
  /// Empty is the ordinary answer. Non-empty does **not** make [matches]
  /// false: these are locales this repository makes no claim about, and
  /// treating them as differences would report a permanent mismatch for every
  /// project whose tree is deliberately partial.
  final List<String> appleOnlyLocales;

  /// What the command prints. Display text.
  final List<String> display;

  Map<String, dynamic> toJson() => _$AppStoreListingDiffDocumentToJson(this);
}

/// One line of `cux_ship play upload --json`.
///
/// **A stream, not a document, and the difference is a promise this format
/// makes rather than a shortcut it takes.** Every other kind here is written
/// whole and once at the end, because a `fail()` partway through would leave
/// half a document on stdout under an exit code saying to trust it. A line is
/// not half of anything: it is complete when its newline arrives, it carries
/// its own `schema` and `kind`, and a stream that stops early is a stream that
/// stopped — which is the only shape that can report an upload *while it is
/// running*, which is the whole point.
///
/// The three shapes are [UploadEvent]:
///
/// ```json
/// {"schema":1,"kind":"play.upload","event":"state","state":"transferring","bytesTotal":68123456}
/// {"schema":1,"kind":"play.upload","event":"progress","bytesSent":1048576,"bytesTotal":68123456}
/// {"schema":1,"kind":"play.upload","event":"result","result":{"packageName":"design.codeux.example","track":"internal","versionName":"1.4.0","versionCode":152,"committed":true}}
/// ```
///
/// **A field that does not apply to a line is absent rather than null.** Null
/// would say the field applies and had no value, which is the distinction the
/// store vocabularies above are built on; here it is the difference between a
/// progress line and a state line that lost its state.
///
/// **No `display`, and that is deliberate rather than forgotten.** The other
/// kinds carry one because `--json` *suppresses* their rendering — a consumer
/// with no `display` would have to re-render, and two renderings of one model
/// drift. An upload suppresses nothing: every human-facing line it has always
/// printed still goes to stderr, in full and in order, because that stream is
/// a log somebody reads after a failure. Carrying those lines here as well
/// would deliver each of them twice on two streams, and a consumer joining the
/// two would print them twice.
@JsonSerializable(explicitToJson: true, includeIfNull: false)
class PlayUploadEvent {
  const PlayUploadEvent({
    required this.schema,
    required this.kind,
    required this.event,
    this.state,
    this.bytesSent,
    this.bytesTotal,
    this.result,
  });

  factory PlayUploadEvent.fromJson(Map<String, dynamic> json) =>
      _$PlayUploadEventFromJson(json);

  /// This kind's schema number. Refuse one you do not recognize.
  ///
  /// On every line rather than on a header line, because a stream has no
  /// header: a reader that joined late, or one reading the tail of a captured
  /// log, still holds a line that says what it is.
  final int schema;

  final DocumentKind kind;

  /// Which shape this line is. Dispatch on this.
  final UploadEvent event;

  /// The state the upload just moved into. Present on [UploadEvent.state].
  final UploadState? state;

  /// Bytes the store has acknowledged. Present on [UploadEvent.progress].
  ///
  /// **Google's own count, not this package's.** A resumable upload PUTs one
  /// chunk at a time and answers each with the range it now holds, and this is
  /// that range — so the number is what Play says it has, arriving when Play
  /// says it. It cannot run ahead of the socket, and **it stops arriving when
  /// the transfer stops**, which is the property the whole signal exists for:
  /// a tick driven by a timer turns at the same rate whether the connection is
  /// moving or dead, and that is exactly the failure this is meant to make
  /// visible.
  ///
  /// **Absolute, never a count from the start of this run.** A resumable
  /// upload that resumes picks up at the offset the store already holds, and
  /// reading the number off the wire is what makes the first line after a
  /// resume report that offset instead of a jump from zero.
  ///
  /// One line per chunk, and a chunk is 1 MiB — so a 68 MB bundle produces
  /// about sixty-eight of these, which is tens and not thousands.
  final int? bytesSent;

  /// The artifact's size. Present on [UploadEvent.progress] and on the
  /// [UploadState.transferring] line.
  ///
  /// Beside [bytesSent] rather than instead of a percentage, so the fraction
  /// is derivable rather than asserted — a consumer that wants two decimal
  /// places is not held to whatever this package rounded to.
  ///
  /// **Floor that fraction; do not round it.** A chunk is 1 MiB and an
  /// artifact is not a whole number of them, so the last-but-one line is a
  /// few kibibytes short of the total and `(sent * 100 / total).round()` is
  /// **100 with bytes still in flight**. A finished cell and an
  /// almost-finished one then look identical, which is the confusion this
  /// stream exists to remove. Measured on a 2 101 248-byte artifact: the
  /// second progress line is 2 097 152, which is 99.805%.
  ///
  /// **And do not read 100% as finished, however it is computed.** `bytesSent
  /// == bytesTotal` means the store has the bytes and nothing more: on Play
  /// the run is still to reach [UploadState.committing], and on the App Store
  /// it is still to reach [UploadState.processing], which is five to fifteen
  /// minutes long. [UploadEvent.result] is the line that says the run
  /// finished, and it is the only one that does.
  ///
  /// **And stop showing it once [state] leaves [UploadState.transferring].**
  /// The bytes have landed by then and the store is working on what it already
  /// holds, so a percentage beside [UploadState.accepting],
  /// [UploadState.committing] or [UploadState.processing] describes something
  /// that has finished — `committing 99%` reads as a transfer one percent
  /// short of done, and a reader waits for a number that will never move. Those
  /// states are not fractions of anything; let the state name stand alone.
  ///
  /// **The ordering makes the obvious version of that wrong**, and nothing
  /// about the ordering looks like a hazard until it is hit: a `progress` line
  /// arrives *after* [UploadState.accepting], because the final chunk is
  /// acknowledged by the response that announcement was written ahead of. So a
  /// consumer that hides the number on a non-transferring state and re-shows it
  /// on any progress line flickers it back on for exactly one line. **Let the
  /// last `state` line own that judgment and let `progress` say only how far** —
  /// a progress line is silent about what kind of work is going on.
  ///
  /// All three are the same rule [AppStoreUploadEvent] follows by having no
  /// `bytesSent` at all: a display must not imply a state the data does not
  /// support. Each was reported by the first consumer, from real runs against
  /// these events — the first two from the arithmetic, the third from reading
  /// a rendered frame.
  final int? bytesTotal;

  /// What the run did. Present on [UploadEvent.result], which is the last
  /// line of a run that finished.
  final PlayUploadResult? result;

  Map<String, dynamic> toJson() => _$PlayUploadEventToJson(this);
}

/// What a finished `play upload` did, on the stream's last line.
///
/// Carried so a caller has the outcome without parsing prose off stderr or
/// inferring it from an exit code — the two things a run's last line used to
/// be the only source of.
@JsonSerializable(explicitToJson: true, includeIfNull: false)
class PlayUploadResult {
  const PlayUploadResult({
    required this.packageName,
    required this.track,
    required this.versionName,
    required this.versionCode,
    required this.committed,
  });

  factory PlayUploadResult.fromJson(Map<String, dynamic> json) =>
      _$PlayUploadResultFromJson(json);

  /// The Play package this went to.
  final String packageName;

  /// The track the release was assigned to.
  final String track;

  /// The version name the release is shown under in the console.
  final String versionName;

  /// The versionCode Play holds, or null for a push that carried no artifact.
  ///
  /// **Play's number rather than the one asked for.** It is what Play read out
  /// of the bundle, which is the only copy that is a fact about the artifact
  /// rather than about the command line.
  final int? versionCode;

  /// Whether the edit was committed, and therefore whether any of this is
  /// real.
  ///
  /// **False on `--dry-run`, which on Play still transfers the bundle.** Play
  /// has an edit transaction, so a dry run does every step into a real edit
  /// and discards it — the bytes move, the progress lines are genuine, and
  /// nothing is published. This is the field that tells those two runs apart,
  /// and there is nothing else in the stream that can.
  final bool committed;

  Map<String, dynamic> toJson() => _$PlayUploadResultToJson(this);
}

/// One line of `cux_ship appstore upload --json`.
///
/// See [PlayUploadEvent] for the stream's shape, the absent-rather-than-null
/// rule and why no line carries `display`; all three hold here. What is
/// different is what this stream can say, and there is one difference:
///
/// **There are no [UploadEvent.progress] lines, and no `bytesSent` field to
/// carry one.** App Store Connect has no endpoint that accepts a binary, so
/// the transfer is `xcrun altool --upload-package` — a subprocess speaking a
/// transport Apple documents nowhere, whose output this package captures
/// whole. There is no per-chunk signal to report. The alternative would be a
/// tick on a timer, and a timer turns at the same rate whether the socket is
/// moving or dead: it would report a wedged upload as a healthy one, which is
/// the failure this stream exists to make visible. A field that is null on
/// every line ever emitted is a format lying about itself, so there is none.
///
/// **What this stream has instead is [UploadState.processing]**, which is
/// where an Apple upload spends most of its wall clock: Apple takes 5–15
/// minutes to process a build, and naming that is worth more than a bar would
/// have been — a percentage stuck at 100 for six minutes says nothing about
/// whose wait it is.
///
/// ```json
/// {"schema":1,"kind":"appstore.upload","event":"state","state":"transferring","bytesTotal":29360128}
/// {"schema":1,"kind":"appstore.upload","event":"state","state":"processing"}
/// {"schema":1,"kind":"appstore.upload","event":"result","result":{"bundleId":"design.codeux.example","platform":"IOS","versionName":"1.4.0","buildNumber":"169","waitedForProcessing":true}}
/// ```
@JsonSerializable(explicitToJson: true, includeIfNull: false)
class AppStoreUploadEvent {
  const AppStoreUploadEvent({
    required this.schema,
    required this.kind,
    required this.event,
    this.state,
    this.bytesTotal,
    this.result,
  });

  factory AppStoreUploadEvent.fromJson(Map<String, dynamic> json) =>
      _$AppStoreUploadEventFromJson(json);

  /// This kind's schema number. Refuse one you do not recognize.
  final int schema;

  final DocumentKind kind;

  /// Which shape this line is. Dispatch on this.
  final UploadEvent event;

  /// The state the upload just moved into. Present on [UploadEvent.state].
  final UploadState? state;

  /// The artifact's size, on the [UploadState.transferring] line.
  ///
  /// **The one number this stream can give about the transfer**, and it is
  /// worth giving on its own: a consumer showing "sending 28 MB" beside a
  /// spinner is telling a reader something, where a bar it cannot fill would
  /// be telling them something false.
  final int? bytesTotal;

  /// What the run did. Present on [UploadEvent.result], which is the last
  /// line of a run that finished.
  final AppStoreUploadResult? result;

  Map<String, dynamic> toJson() => _$AppStoreUploadEventToJson(this);
}

/// What a finished `appstore upload` did, on the stream's last line.
@JsonSerializable(explicitToJson: true, includeIfNull: false)
class AppStoreUploadResult {
  const AppStoreUploadResult({
    required this.bundleId,
    required this.platform,
    required this.versionName,
    required this.buildNumber,
    required this.waitedForProcessing,
  });

  factory AppStoreUploadResult.fromJson(Map<String, dynamic> json) =>
      _$AppStoreUploadResultFromJson(json);

  /// The app this went to.
  final String bundleId;

  /// **On the result rather than inferred from the command line**, for the
  /// reason `finishAfterSkippedWait` carries it on every suggested line: iOS
  /// and macOS are given the same build number from one commit by design, so a
  /// number without a platform beside it names two different binaries.
  @JsonKey(toJson: _platformToJson, fromJson: _platformFromJson)
  final AscPlatform platform;

  /// The marketing version this build was uploaded under, or null for a run
  /// that named none.
  ///
  /// **Nullable here and not on [PlayUploadResult], which is the stores
  /// again.** `play upload` resolves a version name from the pubspec when no
  /// flag gives one, because Play needs something to call the release in the
  /// console; an App Store upload carrying no artifact and no `--metadata`
  /// version has nothing to resolve one *for*, and inventing one would put a
  /// number on this line that no Apple record carries.
  final String? versionName;

  /// The `CFBundleVersion` Apple now holds, or null for a push that carried no
  /// artifact.
  ///
  /// A string, because `CFBundleVersion` is one and Apple accepts `1.2.3` —
  /// the same reason [AppStoreBuildEntry.buildNumber] is.
  final String? buildNumber;

  /// Whether this run waited for Apple to finish processing the build.
  ///
  /// **False under `--skip-waiting`, and then the build is not usable yet.**
  /// The flag exists so the transfer and the wait can run in different places,
  /// so a caller reading `true` knows the build is `VALID` — `awaitProcessing`
  /// raises rather than returning on any other terminal state — and a caller
  /// reading `false` knows only that Apple has the bytes.
  final bool waitedForProcessing;

  Map<String, dynamic> toJson() => _$AppStoreUploadResultToJson(this);
}

/// One app, as the public App Store storefront holds it.
///
/// **Apple's key names are not kept here, which is the opposite of
/// [AppStorePreviewEntry] and is argued rather than inconsistent.** That class
/// keeps Apple's names so a reader can put the document beside Apple's API
/// reference; this endpoint is undocumented and has no reference page to put
/// it beside. What it has instead is legacy iTunes Store vocabulary — an app
/// is a "track" — and in `releaseDate` a name that reads as the answer and is
/// not. Each field below names Apple's own key.
@JsonSerializable(explicitToJson: true)
class StorefrontAppEntry {
  const StorefrontAppEntry({
    required this.appleId,
    required this.appName,
    required this.productKind,
    required this.version,
    required this.versionReleasedDate,
    required this.firstReleasedDate,
    required this.storeUrl,
    required this.display,
  });

  factory StorefrontAppEntry.fromJson(Map<String, dynamic> json) =>
      _$StorefrontAppEntryFromJson(json);

  /// Apple's `trackId` — the numeric app id App Store Connect calls the Apple
  /// ID.
  final int? appleId;

  /// Apple's `trackName`.
  final String? appName;

  /// Apple's `kind`: `software` or `mac-software`, exactly as sent.
  ///
  /// **It names the record's product type, not a platform.** A universal
  /// purchase that runs on iOS *and* macOS answers `software`; a Mac-only
  /// listing answers `mac-software`. Reading this as "the iOS release" is
  /// wrong for precisely the case it looks right for, which is why this
  /// document has no `platform` field for it to appear to qualify.
  ///
  /// **Raw, with no closed vocabulary of ours beside it**, and that is the one
  /// deliberate exception in these classes to *a store's vocabulary arrives
  /// twice*. An enum of ours over this field would be an enum of platforms,
  /// and there is no platform here to name — so the honest shape is Apple's
  /// word and a doc comment, rather than a vocabulary that would be read as an
  /// answer to a question the storefront does not take.
  final String? productKind;

  /// The version string the storefront is showing, such as `1.1.6`.
  ///
  /// **Compare it against the version you are asking about.**
  /// [versionReleasedDate] is the date of *this* version, so a caller asking
  /// "when did 1.1.7 go out" while the storefront still shows 1.1.6 has been
  /// handed 1.1.6's date — and this field is the only thing that says so.
  final String? version;

  /// Apple's `currentVersionReleaseDate`: when the public got [version].
  ///
  /// **The answer.** ISO-8601 as Apple spells it, and a string rather than a
  /// `DateTime` for the reason `uploadedDate` is one.
  final String? versionReleasedDate;

  /// Apple's `releaseDate`: when the app was **first ever** released.
  ///
  /// Renamed because Apple's name is a trap — "the release date" reads as the
  /// date of the release in front of you, and this is the app's launch day.
  /// A consumer rendering it per version would show a plausible wrong answer
  /// with nothing looking broken.
  final String? firstReleasedDate;

  /// Apple's `trackViewUrl`: the public page, `uo=4` and all, unchanged.
  final String? storeUrl;

  /// What the app's two lines of `cux_ship storefront released` say. Display
  /// text.
  final List<String> display;

  Map<String, dynamic> toJson() => _$StorefrontAppEntryToJson(this);
}

/// What `storefront released --json` prints.
///
/// **No `platform`, and its absence is the specification.** The storefront
/// answers per app: `/lookup` ignores `entity`, a universal purchase returns
/// one record covering iOS and macOS, and a `/search` restricted to
/// `macSoftware` returns that same record. A consumer therefore cannot fill
/// two per-platform columns from one of these, because there is nothing here
/// to key them on. docs/design/storefront-release-date.md carries the
/// measurement.
///
/// **This is the storefront, not App Store Connect.** Undocumented,
/// rate-limited, and with reported cases of the date disagreeing with the
/// console. Put it beside an [AppStoreVersionsDocument] rather than instead of
/// one: that says which version is `READY_FOR_SALE`, and this says when the
/// public got it.
@JsonSerializable(explicitToJson: true)
class StorefrontReleasedDocument {
  const StorefrontReleasedDocument({
    required this.schema,
    required this.kind,
    required this.bundleId,
    required this.country,
    required this.app,
    required this.display,
  });

  factory StorefrontReleasedDocument.fromJson(Map<String, dynamic> json) =>
      _$StorefrontReleasedDocumentFromJson(json);

  /// This kind's schema number. Refuse one you do not recognize.
  final int schema;

  final DocumentKind kind;

  /// The bundle identifier that was looked up.
  final String bundleId;

  /// The two-letter storefront that answered, as asked for — `us` unless
  /// `--country` said otherwise. The storefront is per region and this is
  /// which region's answer this is.
  final String country;

  /// Null when the storefront knows no such app.
  ///
  /// **Absence is an answer, not a failure**, and the command still exits
  /// non-zero to say which answer it was — `notOnStorefrontExit`, 6. A caller
  /// reading this document therefore has both halves: the status to branch on,
  /// and [display] to print.
  ///
  /// **A nullable object rather than a `found` flag beside flat fields**, so a
  /// release date cannot be read without the null having been dealt with.
  ///
  /// **Two facts arrive here as one, and that is the endpoint's doing**: an
  /// app that has never been released and an app that is not sold on
  /// [country]'s storefront both answer with no results. It is why `--country`
  /// is a flag rather than a constant.
  final StorefrontAppEntry? app;

  /// What `cux_ship storefront released` prints, and never empty — the absent
  /// case is a sentence rather than nothing. Display text.
  final List<String> display;

  Map<String, dynamic> toJson() => _$StorefrontReleasedDocumentToJson(this);
}
