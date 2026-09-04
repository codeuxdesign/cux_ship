// SPDX-License-Identifier: Apache-2.0
//
// The Play reads as objects, for a Dart caller that would otherwise be
// matching regular expressions against this command's stdout.
//
// **The printed lines are derived from these objects, not the other way
// round.** `play tracks` renders [PlayTracks.lines]; there is one description
// of what a track listing looks like and both the CLI and a library caller get
// it. That matters more than it sounds: a consumer that prints a store's own
// output verbatim — because a `status` that re-renders the table misreports the
// day the format changes, silently — needs those lines to be the same lines,
// and a second formatter beside the first is a second thing to drift.
//
// Reads only, and on the Play side that is worth spelling out: reading tracks
// opens an *edit*, because Play has no way to list them otherwise. The edit is
// deleted rather than committed, so nothing it saw becomes anything. Nothing
// here calls `commit`.
import 'package:googleapis/androidpublisher/v3.dart';
import 'package:googleapis_auth/auth_io.dart';

import 'credentials.dart';

/// One release Play holds on a track.
class PlayTrackRelease {
  const PlayTrackRelease({
    required this.name,
    required this.versionCodes,
    required this.status,
  });

  /// The release name, which Play generates from the version name when it was
  /// not set. Null when the response did not carry one.
  final String? name;

  /// Every versionCode this release serves.
  ///
  /// More than one when an app ships separate bundles per ABI. Play sends
  /// these as strings — an int64 convention, not a hint that they might not be
  /// numbers — and they are parsed here so "newest" is an ordering rather than
  /// a string comparison.
  final List<int> versionCodes;

  /// `completed`, `inProgress`, `halted`, `draft` or `statusUnspecified`, or
  /// null when the response did not carry it.
  final String? status;

  /// The highest versionCode in this release, or null when it serves none.
  int? get newestVersionCode {
    int? newest;
    for (final code in versionCodes) {
      if (newest == null || code > newest) {
        newest = code;
      }
    }
    return newest;
  }

  /// The line `cux_ship play tracks` prints for this release.
  String lineOn(String track) =>
      '  $track: "$name" codes=$versionCodes $status';
}

/// One Play track — `production`, `beta`, `alpha`, `internal`, or a custom
/// closed-testing track.
class PlayTrack {
  const PlayTrack({required this.name, required this.releases});

  final String name;

  /// **A track can carry more than one release at a time** — a halted rollout
  /// sits alongside the one that replaced it — and Play promises no order.
  final List<PlayTrackRelease> releases;

  /// The highest versionCode any release on this track serves, or null when
  /// the track is empty.
  ///
  /// Highest rather than first, for the reason above: "the first release
  /// listed" is not a fact about which build is on the track.
  int? get newestVersionCode {
    int? newest;
    for (final release in releases) {
      final code = release.newestVersionCode;
      if (code != null && (newest == null || code > newest)) {
        newest = code;
      }
    }
    return newest;
  }

  /// The lines `cux_ship play tracks` prints for this track.
  List<String> get lines {
    if (releases.isEmpty) {
      return <String>['  $name: (empty)'];
    }
    return <String>[
      for (final release in releases) ...[release.lineOn(name)],
    ];
  }
}

/// What Google Play holds for one package.
class PlayTracks {
  const PlayTracks({
    required this.packageName,
    required this.tracks,
    required this.uploadedVersionCodes,
  });

  final String packageName;

  /// In the order Play listed them.
  final List<PlayTrack> tracks;

  /// Every bundle Play has ever accepted for this package, by versionCode.
  ///
  /// A bundle can be uploaded and assigned to no track, so this is a longer
  /// list than the tracks account for and is the evidence that an upload
  /// arrived at all.
  final List<int> uploadedVersionCodes;

  /// The track called [name], or null when Play holds no such track.
  PlayTrack? track(String name) {
    for (final track in tracks) {
      if (track.name == name) {
        return track;
      }
    }
    return null;
  }

  /// The newest versionCode on [name], or null when the track is empty or
  /// absent.
  ///
  /// `newestVersionCodeOn('internal')` is the one number a release train needs
  /// from this: `internal` is the track an upload lands on, so it answers
  /// "which build does Play actually hold".
  int? newestVersionCodeOn(String name) => track(name)?.newestVersionCode;

  /// Exactly what `cux_ship play tracks` prints, for a caller that shows the
  /// store's own output rather than re-rendering it.
  List<String> get lines => <String>[
    for (final track in tracks) ...track.lines,
    '  uploaded bundles: $uploadedVersionCodes',
  ];
}

/// Play's `Track` and `Bundle` resources, as a [PlayTracks].
PlayTracks playTracksFrom(
  String packageName,
  List<Track> tracks,
  List<Bundle> bundles,
) => PlayTracks(
  packageName: packageName,
  tracks: <PlayTrack>[
    for (final track in tracks) ...[playTrackFrom(track)],
  ],
  uploadedVersionCodes: <int>[
    for (final bundle in bundles) ...[?bundle.versionCode],
  ],
);

/// One `Track` resource, as sent.
PlayTrack playTrackFrom(Track track) => PlayTrack(
  name: track.track ?? '(unnamed)',
  releases: <PlayTrackRelease>[
    for (final release in track.releases ?? const <TrackRelease>[]) ...[
      PlayTrackRelease(
        name: release.name,
        versionCodes: <int>[
          for (final code in release.versionCodes ?? const <String>[]) ...[
            ?int.tryParse(code),
          ],
        ],
        status: release.status,
      ),
    ],
  ],
);

/// Reads back what Play actually has, rather than what a previous run reported
/// having sent.
///
/// **Reading tracks needs an edit even though nothing is modified**, so the
/// edit is discarded immediately afterwards — in a `finally`, because an edit
/// left open is a stale draft somebody finds in the console later.
///
/// **The discard is best-effort, and that is load-bearing.** Awaiting a
/// throwing call inside a `finally` discards the exception already in flight,
/// so a failed cleanup would replace the failure being reported — and the
/// failure being reported is usually the 403 that says the service account was
/// never granted this app, which is the only actionable message in the whole
/// exchange. The upload path abandons its own edit the same way and for the
/// same reason, in cli.dart.
///
/// This used to be safe here by accident rather than by design: the deletion
/// sat in the same function as the `catch`, and a `catch` runs before its
/// `finally`, so the real error had already been printed by the time a
/// cleanup could fail. Splitting the read out for [PlayReads] moved the
/// `catch` to the caller and took that ordering away with it.
Future<PlayTracks> readTracks(
  AndroidPublisherApi api,
  String packageName,
) async {
  String? editId;
  try {
    editId = (await api.edits.insert(AppEdit(), packageName)).id;
    if (editId == null) {
      throw StateError('Play did not return an edit id');
    }
    final tracks =
        (await api.edits.tracks.list(packageName, editId)).tracks ??
        const <Track>[];
    final bundles =
        (await api.edits.bundles.list(packageName, editId)).bundles ??
        const <Bundle>[];
    return playTracksFrom(packageName, tracks, bundles);
  } finally {
    if (editId != null) {
      try {
        await api.edits.delete(packageName, editId);
      } catch (_) {
        // Losing the cleanup is not worth masking the original failure, and
        // Play expires an abandoned edit on its own. Deliberately silent even
        // when the read succeeded: a read that answered correctly must not
        // fail because Play would not take its edit back.
      }
    }
  }
}

/// A read-only Google Play session for one package.
///
///     final reads = await PlayReads.open(
///       packageName: 'design.codeux.example',
///     );
///     try {
///       final tracks = await reads.tracks();
///       for (final line in tracks.lines) {
///         log.writeln(line);
///       }
///       print(tracks.newestVersionCodeOn('internal'));
///     } finally {
///       reads.close();
///     }
///
/// Credentials come from the environment `cux_ship secrets exec` sets up —
/// [playServiceAccountVar]. In-process reads therefore need that variable in
/// the *calling* process, which is the one thing a caller switching from a
/// spawned `cux_ship` to this has to arrange.
class PlayReads {
  PlayReads._(this._client, this._api, this.packageName);

  /// Authenticates and holds the session open.
  ///
  /// Throws [StateError] when no service account is configured.
  static Future<PlayReads> open({required String packageName}) async {
    final client = await clientViaServiceAccount(loadPlayServiceAccount(), [
      AndroidPublisherApi.androidpublisherScope,
    ]);
    return PlayReads._(client, AndroidPublisherApi(client), packageName);
  }

  final AutoRefreshingAuthClient _client;
  final AndroidPublisherApi _api;

  /// The Android package this session was opened for.
  final String packageName;

  /// What `cux_ship play tracks` reads.
  ///
  /// Throws [DetailedApiRequestError] when Play refuses — most often because
  /// the service account has not been granted access to this app.
  Future<PlayTracks> tracks() => readTracks(_api, packageName);

  /// Releases the HTTP client. A session that is not closed keeps a connection
  /// pool alive, which is what stops a long-running process from exiting.
  void close() => _client.close();
}
