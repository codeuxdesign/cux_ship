// SPDX-License-Identifier: Apache-2.0
//
// The documents `--json` prints, specified in docs/design/json-output.md —
// which argues the parts a reader of this file cannot see: why JSON and not
// YAML, why the envelope is the build manifest's rather than a second
// convention, and why a rendering travels inside a data document on purpose.
//
// **This builds the classes in documents.dart and calls `toJson`.** It used to
// build map literals with string keys, and what changed is that there is now
// one definition of the format rather than an encoder here and a decoder in
// every consumer's tree. `documents.dart` is exported, so a caller decodes
// with `fromJson` against the same classes this writes — and the classes'
// dartdoc, which pub.dev renders per version, is the published statement of
// the format.
//
// **What stays hand-written is the mapping, and it is the whole of this
// file.** Between the models and the documents it renames `line` and `lines`
// to `display`, drops `uploadedAt`, computes `newestBuildNumberAsInt` through
// `newest`, adds a `bundleId` that is on no model, and hands a parent's
// `track.name` to `release.lineOn`. Each is deliberate and each is argued
// beside the field it produces. Codegen writes `toJson`; none of it writes
// these.
import 'dart:convert';
import 'dart:io';

import 'appstore/reads.dart';
import 'documents.dart';
import 'play/reads.dart';

/// The schema `appstore builds` declares.
///
/// **One counter per kind, which is the whole reason a document carries
/// `kind`.** A single number shared by three shapes would bump this one when
/// `play.tracks` changed, and a reader that refuses an unrecognized `schema`
/// would then refuse a document that had not changed.
const appStoreBuildsSchema = 1;

/// The schema `appstore versions` declares. See [appStoreBuildsSchema].
const appStoreVersionsSchema = 1;

/// The schema `play tracks` declares. See [appStoreBuildsSchema].
const playTracksSchema = 1;

/// Writes [document] to stdout, whole, once.
///
/// **Once and at the end, because `fail()` calls `exit()`.** A document
/// assembled onto stdout as it is built leaves half of one there when a read
/// partway through refuses — under an exit code that says to trust it. This is
/// the build manifest writer's "before the file is written, not after",
/// applied to a stream that cannot be truncated afterwards.
///
/// Indented rather than compact for the same reason the manifest is: these are
/// small, and the reader is as often a person as a program.
///
/// [document] is one of the classes in documents.dart. Typed as [Object]
/// because there are three of them with no common supertype — and giving them
/// one would put a name in `documents.dart` that exists for this function's
/// convenience rather than for a caller's use. `JsonEncoder`'s default
/// `toEncodable` calls `toJson()`, so this needs nothing else.
void writeJsonDocument(Object document) {
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(document));
}

/// `cux_ship appstore builds --json`.
AppStoreBuildsDocument appStoreBuildsDocument(
  AppStoreBuilds listing, {
  required String bundleId,
}) => AppStoreBuildsDocument(
  schema: appStoreBuildsSchema,
  kind: DocumentKind.appStoreBuilds,
  platform: listing.platform,
  bundleId: bundleId,
  newestBuildNumber: listing.newestBuildNumber,
  // **The comparison [AppStoreBuilds.newestBuildNumber]'s own doc comment
  // tells a caller to make.** It says to use [AppStoreBuild.buildNumberAsInt]
  // *via* [AppStoreBuilds.newest] — a route only a caller holding these
  // objects has. Carrying the string alone would hand a shell caller exactly
  // the string comparison that comment forbids, and the way back would be
  // re-finding the newest build and re-implementing an ordering this class
  // has already applied.
  newestBuildNumberAsInt: listing.newest?.buildNumberAsInt,
  builds: <AppStoreBuildEntry>[
    for (final build in listing.builds) ...[_build(build)],
  ],
  // Not the concatenation of the builds' `display`: this renders twenty at
  // most, which is the listing's limit and not [AppStoreBuilds.builds]', and
  // it answers an empty listing with a sentence rather than with nothing.
  display: listing.lines,
);

AppStoreBuildEntry _build(AppStoreBuild build) => AppStoreBuildEntry(
  buildNumber: build.buildNumber,
  buildNumberAsInt: build.buildNumberAsInt,
  processingState: build.processingState,
  // Apple's own string, and not [AppStoreBuild.uploadedAt] beside it: they are
  // the same instant and Apple already spells it ISO-8601, so a second key
  // would be a second source for one fact and a second thing to be wrong.
  uploadedDate: build.uploadedDate,
  expired: build.expired,
  usable: build.usable,
  // **The axis `usable` hides, and the one an operator's next action turns
  // on.** A consumer built its Apple advice on `usable == false` and told the
  // operator to wait for `VALID` in every case — right for `PROCESSING`, wrong
  // for `FAILED` and `INVALID`, which are Apple refusing the binary and never
  // change again. "Wait forever" was the advice for exactly the two states
  // where the answer is "upload a different build".
  //
  // Null rather than false for a state nobody here names, because whether
  // waiting helps is the question an unrecognized state most plainly cannot
  // answer. An expired build is settled whatever its processing said.
  mayBecomeUsable: _mayBecomeUsable(build),
  display: <String>[build.line],
);

bool? _mayBecomeUsable(AppStoreBuild build) {
  if (build.expired) {
    return false;
  }
  return switch (build.processingState) {
    'PROCESSING' => true,
    'VALID' || 'FAILED' || 'INVALID' => false,
    _ => null,
  };
}

/// `cux_ship appstore versions --json`.
AppStoreVersionsDocument appStoreVersionsDocument(
  AppStoreVersions listing, {
  required String bundleId,
}) => AppStoreVersionsDocument(
  schema: appStoreVersionsSchema,
  kind: DocumentKind.appStoreVersions,
  platform: listing.platform,
  bundleId: bundleId,
  versions: <AppStoreVersionEntry>[
    for (final version in listing.versions) ...[_version(version)],
  ],
  // **This one looks like the concatenation of the versions' `display`, and
  // that is the trap.** [AppStoreVersions.lines] has no cap and no trailing
  // line, so for every non-empty listing the two are byte-identical — and for
  // an empty one, `lines` answers with "no App Store versions for …" while a
  // concatenation answers with nothing. An account with no versions and a
  // reader that forgot to render would then look the same. The empty case is
  // the only input that can tell these apart, which is why the test uses one.
  display: listing.lines,
);

AppStoreVersionEntry _version(AppStoreVersion version) => AppStoreVersionEntry(
  versionString: version.versionString,
  appStoreState: version.appStoreState,
  releaseType: version.releaseType,
  copyright: version.copyright,
  editable: version.editable,
  // Two entries, not one: a version renders its state and its copyright on
  // separate lines. An item whose rendering collapsed to a string is what
  // makes a caller join and then split, which is parsing `display`.
  display: version.lines,
);

/// `cux_ship play tracks --json`.
PlayTracksDocument playTracksDocument(PlayTracks tracks) => PlayTracksDocument(
  schema: playTracksSchema,
  kind: DocumentKind.playTracks,
  packageName: tracks.packageName,
  tracks: <PlayTrackEntry>[
    for (final track in tracks.tracks) ...[_track(track)],
  ],
  uploadedVersionCodes: tracks.uploadedVersionCodes,
  // Not the concatenation of the tracks' `display`: a trailing line reports
  // the uploaded bundles, which belong to no track.
  display: tracks.lines,
);

PlayTrackEntry _track(PlayTrack track) => PlayTrackEntry(
  name: track.name,
  newestVersionCode: track.newestVersionCode,
  releases: <PlayReleaseEntry>[
    for (final release in track.releases) ...[_release(release, track.name)],
  ],
  display: track.lines,
);

PlayReleaseEntry _release(PlayTrackRelease release, String track) =>
    PlayReleaseEntry(
      name: release.name,
      status: release.status,
      versionCodes: release.versionCodes,
      newestVersionCode: release.newestVersionCode,
      // **Computed here rather than left to the caller**, for the reason the
      // App Store side's `usable` and `editable` already are: the question a
      // caller has is "is this in front of anyone", and answering it by
      // comparing Play's status strings is the deferral to Google's
      // documentation this document exists to end. A shell caller gets it too,
      // which a Dart getter could not give them.
      //
      // **Three-valued, because the vocabulary it reads is open.** A `bool`
      // would have to answer a status nobody here names, and both answers are
      // wrong: `false` reports a possibly-healthy rollout as reaching nobody,
      // `true` calls an unrecognized state healthy. Null is the same honesty
      // the enum's `unknown` carries, and a derived field that threw it away
      // would be a worse answer than the field it is derived from.
      //
      // `statusUnspecified` is null too. Play saying "unspecified" and Play
      // saying nothing are the same amount of information.
      //
      // **Deliberately not a fraction.** `inProgress` means some of the
      // audience has it; how much is not in this document, and belongs to the
      // release-and-rollout task rather than here.
      serving: _serving(release.status),
      // The track name is not a field of a release — Play nests releases under
      // tracks and the rendering says which track it is on, so the line needs
      // an argument the object does not carry.
      display: <String>[release.lineOn(track)],
    );

bool? _serving(String? status) => switch (status) {
  'completed' || 'inProgress' => true,
  'halted' || 'draft' => false,
  // `statusUnspecified`, a value nobody here names, and an absent field all
  // land together: three ways of not being told.
  _ => null,
};
