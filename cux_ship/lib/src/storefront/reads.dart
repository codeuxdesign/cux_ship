// SPDX-License-Identifier: Apache-2.0

// `storefront released` — what the public App Store shows for an app, and when
// it got there. The question App Store Connect cannot answer at all:
// `createdDate` is when somebody typed a version number into the console, and
// `earliestReleaseDate` is null for every manual release.
// docs/design/storefront-release-date.md is the argument.
//
// **The printed lines are derived from these objects, not the other way
// round** — the same rule `play/reads.dart` states at the top, and the reason
// `json_output.dart` can carry a rendering inside a data document without
// there being two formatters.
//
// **This describes an app, not a platform's release.** There is no `platform`
// anywhere in this file, and that is measured rather than an omission: the
// storefront returns one record for a universal purchase, `/lookup` ignores
// `entity`, and a `/search` with `entity=macSoftware` finds the same record
// with the same id, version and date. See the design document, §"It answers
// per app, not per platform".
import 'dart:io';

import '../json_output.dart';
import 'itunes_client.dart';

/// One app, as the public storefront holds it.
///
/// **Apple's key names do not survive into this class**, which is the opposite
/// of what `AppStorePreviewEntry` does and is argued in the design document:
/// that class keeps Apple's names so a reader can hold the document beside
/// Apple's reference page, and this endpoint has no reference page to hold it
/// beside. What it has instead is legacy iTunes vocabulary — an app is a
/// "track" — and one name that is actively dangerous. Every field below names
/// Apple's key in its own doc comment.
class StorefrontApp {
  const StorefrontApp({
    required this.appleId,
    required this.appName,
    required this.productKind,
    required this.version,
    required this.versionReleasedDate,
    required this.firstReleasedDate,
    required this.storeUrl,
  });

  /// Apple's `trackId`: the numeric app id App Store Connect calls the Apple
  /// ID. Null when the storefront sent none, which has not been observed.
  final int? appleId;

  /// Apple's `trackName`.
  final String? appName;

  /// Apple's `kind` — `software` or `mac-software`, unchanged.
  ///
  /// **It names the record's product type, not a platform**, and the
  /// difference is the whole of why this document has no `platform` field. A
  /// universal purchase that runs on iOS and macOS answers `software`; a
  /// Mac-only listing answers `mac-software`. Reading this as "the iOS
  /// release" is wrong for exactly the case it looks right for.
  ///
  /// Carried raw, with no closed vocabulary of ours beside it — the deliberate
  /// exception to the rule `documents.dart` states for every store-owned
  /// value. Our own vocabulary over this field would be a vocabulary of
  /// platforms, and there is no platform here to name.
  final String? productKind;

  /// The version string the storefront is showing, such as `1.1.6`.
  ///
  /// **A caller comparing this against what it believes is live is the point.**
  /// [versionReleasedDate] is the date of *this* version, so a caller asking
  /// about 1.1.7 while the storefront still shows 1.1.6 has been handed 1.1.6's
  /// date, and the version string is the only thing that says so.
  final String? version;

  /// Apple's `currentVersionReleaseDate`: when the public got [version].
  ///
  /// **The answer this whole command exists for.** ISO-8601 as Apple spells
  /// it, kept as a string for the reason `uploadedDate` is one — a Dart
  /// `DateTime` re-spelled is not the string Apple sent.
  final String? versionReleasedDate;

  /// Apple's `releaseDate`: when the app was **first ever** released.
  ///
  /// Renamed because Apple's name is a trap. "The release date" reads as the
  /// date of the release in front of you, and this is the app's launch day —
  /// a consumer rendering it in a per-version column would show a plausible,
  /// wrong answer with nothing looking broken.
  final String? firstReleasedDate;

  /// Apple's `trackViewUrl`: the public page, including its `uo=4` tracking
  /// parameter, unchanged.
  final String? storeUrl;

  /// Exactly what `cux_ship storefront released` prints for the app itself.
  ///
  /// Two lines rather than one, for the reason an `appstore.versions` item has
  /// two: the first release is a different fact from this release, and joining
  /// them into one string is what makes a caller split on a newline — which is
  /// parsing `display`.
  List<String> get lines => <String>[
    '  ${version ?? '(no version)'}  '
        'released ${versionReleasedDate ?? '(no date)'}',
    '  first released ${firstReleasedDate ?? '(no date)'}',
  ];
}

/// The storefront's whole answer for one bundle id on one storefront.
class StorefrontRelease {
  const StorefrontRelease({
    required this.bundleId,
    required this.country,
    required this.app,
  });

  final String bundleId;

  /// The two-letter storefront that answered, as asked for.
  final String country;

  /// Null when the storefront knows no such app.
  ///
  /// **Absence is an answer rather than a failure**, and a nullable object
  /// rather than a `found` boolean beside flat fields: a caller cannot read a
  /// release date without having dealt with the null, where a boolean can be
  /// ignored and the fields read anyway.
  ///
  /// **Two facts arrive here as one**, which is a property of the endpoint: an
  /// app that has never been released and an app that is not sold on
  /// [country]'s storefront both answer `resultCount: 0`. That is why
  /// `--country` is a flag rather than a constant.
  final StorefrontApp? app;

  /// Exactly what `cux_ship storefront released` prints.
  ///
  /// **Not the concatenation of [app]'s lines**, and never empty: there is a
  /// heading naming what was asked, and the absent case renders a sentence.
  /// A consumer iterating an empty list prints nothing, and an app the output
  /// said nothing about reads as an app with nothing wrong.
  List<String> get lines {
    final found = app;
    if (found == null) {
      return <String>[
        '$bundleId is not on the $country App Store — nothing has been '
            'released there, or it is not sold on that storefront',
      ];
    }
    return <String>[
      '$bundleId on the $country App Store'
          '${found.appName == null ? '' : ' — ${found.appName}'}'
          '${found.appleId == null ? '' : ' (id ${found.appleId})'}',
      ...found.lines,
    ];
  }
}

/// One `/lookup` result as sent, read into [StorefrontApp].
///
/// **Every field is read defensively and every one can be null.** This is an
/// undocumented endpoint: a key that disappears should cost a null in one
/// field rather than an exception that takes the whole read down, because the
/// field a caller needs is very likely still there.
StorefrontApp storefrontAppFrom(Map<String, dynamic> result) => StorefrontApp(
  // `as int?` and not a cast on `num`: Apple sends this unquoted and JSON
  // integers decode as `int` in Dart. A double here would mean Apple changed
  // the shape, and null is the honest answer to that rather than a truncation.
  appleId: result['trackId'] is int ? result['trackId'] as int : null,
  appName: result['trackName'] as String?,
  productKind: result['kind'] as String?,
  version: result['version'] as String?,
  versionReleasedDate: result['currentVersionReleaseDate'] as String?,
  firstReleasedDate: result['releaseDate'] as String?,
  storeUrl: result['trackViewUrl'] as String?,
);

/// The storefront's answer for [bundleId], read into a value.
///
/// **More than one result is not a case this handles, and Apple has not
/// produced one**: a bundle id addresses one product. The first is taken, so a
/// second would be ignored rather than crash the read.
Future<StorefrontRelease> readStorefrontRelease(
  StorefrontClient client, {
  required String bundleId,
  required String country,
}) async {
  final results = await client.lookup(bundleId: bundleId, country: country);
  return StorefrontRelease(
    bundleId: bundleId,
    country: country,
    app: results.isEmpty ? null : storefrontAppFrom(results.first),
  );
}

/// `cux_ship storefront released`.
///
/// A free function beside the model rather than a method on it, for the reason
/// `printBuilds` is one: the arrow points from what the endpoint can be asked
/// towards how an answer is rendered, and the model does not import the
/// encoder's world.
void printStorefrontRelease(StorefrontRelease release, {bool json = false}) {
  if (json) {
    writeJsonDocument(storefrontReleasedDocument(release));
    return;
  }
  for (final line in release.lines) {
    stdout.writeln(line);
  }
}
