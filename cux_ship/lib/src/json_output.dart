// SPDX-License-Identifier: Apache-2.0
//
// The documents `--json` prints, specified in docs/design/json-output.md —
// which argues the parts a reader of this file cannot see: why JSON and not
// YAML, why the envelope is the build manifest's rather than a second
// convention, and why a rendering travels inside a data document on purpose.
//
// **Nothing here is exported, and the models do not gain a `toJson`.**
// `read.dart` hands a Dart caller the objects; this hands everybody else the
// same values as a document. A `toJson` on an exported class would have made
// the document shape a semver promise of `read.dart` as well as of its own
// `schema` field, and two version numbers over one shape is one too many.
//
// The models are the field list. What is decided here is only what a model
// cannot say: which keys a document carries, and what each `schema` counts.
import 'dart:convert';
import 'dart:io';

import 'appstore/reads.dart';
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
void writeJsonDocument(Map<String, Object?> document) {
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(document));
}

/// `cux_ship appstore builds --json`.
Map<String, Object?> appStoreBuildsDocument(
  AppStoreBuilds listing, {
  required String bundleId,
}) => <String, Object?>{
  'schema': appStoreBuildsSchema,
  'kind': 'appstore.builds',
  'platform': listing.platform.api,
  'bundleId': bundleId,
  'newestBuildNumber': listing.newestBuildNumber,
  // **The comparison [AppStoreBuilds.newestBuildNumber]'s own doc comment
  // tells a caller to make.** It says to use [AppStoreBuild.buildNumberAsInt]
  // *via* [AppStoreBuilds.newest] — a route only a caller holding these
  // objects has. Carrying the string alone would hand a shell caller exactly
  // the string comparison that comment forbids, and the way back would be
  // re-finding the newest build and re-implementing an ordering this class
  // has already applied.
  'newestBuildNumberAsInt': listing.newest?.buildNumberAsInt,
  'builds': <Map<String, Object?>>[
    for (final build in listing.builds) ...[_build(build)],
  ],
  // Not the concatenation of the builds' `display`: this renders twenty at
  // most, which is the listing's limit and not [AppStoreBuilds.builds]'.
  'display': listing.lines,
};

Map<String, Object?> _build(AppStoreBuild build) => <String, Object?>{
  'buildNumber': build.buildNumber,
  'buildNumberAsInt': build.buildNumberAsInt,
  'processingState': build.processingState,
  // Apple's own string, and not [AppStoreBuild.uploadedAt] beside it: they are
  // the same instant and Apple already spells it ISO-8601, so a second key
  // would be a second source for one fact and a second thing to be wrong.
  'uploadedDate': build.uploadedDate,
  'expired': build.expired,
  'usable': build.usable,
  'display': <String>[build.line],
};

/// `cux_ship appstore versions --json`.
Map<String, Object?> appStoreVersionsDocument(
  AppStoreVersions listing, {
  required String bundleId,
}) => <String, Object?>{
  'schema': appStoreVersionsSchema,
  'kind': 'appstore.versions',
  'platform': listing.platform.api,
  'bundleId': bundleId,
  'versions': <Map<String, Object?>>[
    for (final version in listing.versions) ...[_version(version)],
  ],
  'display': listing.lines,
};

Map<String, Object?> _version(AppStoreVersion version) => <String, Object?>{
  'versionString': version.versionString,
  'appStoreState': version.appStoreState,
  'releaseType': version.releaseType,
  'copyright': version.copyright,
  'editable': version.editable,
  // Two entries, not one: a version renders its state and its copyright on
  // separate lines. An item whose rendering collapsed to a string is what
  // makes a caller join and then split, which is parsing `display`.
  'display': version.lines,
};

/// `cux_ship play tracks --json`.
Map<String, Object?> playTracksDocument(PlayTracks tracks) => <String, Object?>{
  'schema': playTracksSchema,
  'kind': 'play.tracks',
  'packageName': tracks.packageName,
  'tracks': <Map<String, Object?>>[
    for (final track in tracks.tracks) ...[_track(track)],
  ],
  'uploadedVersionCodes': tracks.uploadedVersionCodes,
  // Not the concatenation of the tracks' `display`: a trailing line reports
  // the uploaded bundles, which belong to no track.
  'display': tracks.lines,
};

Map<String, Object?> _track(PlayTrack track) => <String, Object?>{
  'name': track.name,
  'newestVersionCode': track.newestVersionCode,
  'releases': <Map<String, Object?>>[
    for (final release in track.releases) ...[_release(release, track.name)],
  ],
  'display': track.lines,
};

Map<String, Object?> _release(PlayTrackRelease release, String track) =>
    <String, Object?>{
      'name': release.name,
      'status': release.status,
      'versionCodes': release.versionCodes,
      'newestVersionCode': release.newestVersionCode,
      // The track name is not a field of a release — Play nests releases under
      // tracks and the rendering says which track it is on, so the line needs
      // an argument the object does not carry.
      'display': <String>[release.lineOn(track)],
    };
