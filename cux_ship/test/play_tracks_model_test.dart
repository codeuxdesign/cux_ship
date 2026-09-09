// SPDX-License-Identifier: Apache-2.0
//
// `play tracks` became a value a caller reads rather than lines a caller
// greps, and the one number a release train takes from it is the newest
// versionCode on `internal` — the track an upload lands on, so the answer to
// "which build does Play actually hold".
//
// **"Newest" is the highest versionCode, not the first release listed.** Play
// promises no order and a track carries more than one release at a time: a
// halted rollout sits beside the one that replaced it. Reading the first entry
// is right most days and wrong on the day somebody halts a rollout, which is
// the day the number is being read for.
import 'package:cux_ship/src/play/reads.dart';
import 'package:googleapis/androidpublisher/v3.dart';
import 'package:test/test.dart';

TrackRelease _release(
  String? name,
  List<String>? versionCodes, {
  String? status = 'completed',
}) => TrackRelease(name: name, versionCodes: versionCodes, status: status);

Track _track(String name, List<TrackRelease> releases) =>
    Track(track: name, releases: releases);

Bundle _bundle(int versionCode) => Bundle(versionCode: versionCode);

PlayTracks _tracksOf(List<Track> tracks, {List<Bundle> bundles = const []}) =>
    playTracksFrom('design.codeux.example', tracks, bundles);

void main() {
  group('the newest versionCode on a track', () {
    test('is the highest one, not the first release listed', () {
      // The halted-rollout shape: Play lists both, in no promised order.
      final tracks = _tracksOf([
        _track('internal', [
          _release('1.3.0', ['2130'], status: 'halted'),
          _release('1.4.0', ['2132']),
        ]),
      ]);

      expect(tracks.newestVersionCodeOn('internal'), 2132);
    });

    test('and still the highest when Play lists them the other way round', () {
      final tracks = _tracksOf([
        _track('internal', [
          _release('1.4.0', ['2132']),
          _release('1.3.0', ['2130'], status: 'halted'),
        ]),
      ]);

      expect(tracks.newestVersionCodeOn('internal'), 2132);
    });

    test('is the highest across a release serving several bundles', () {
      // An app shipping separate bundles per ABI puts them all in one release.
      final tracks = _tracksOf([
        _track('internal', [
          _release('1.4.0', ['2130', '2132', '2131']),
        ]),
      ]);

      expect(tracks.newestVersionCodeOn('internal'), 2132);
    });

    test('is numeric, so 2140 beats 999', () {
      // Play sends version codes as strings. Compared as strings, "999" wins.
      final tracks = _tracksOf([
        _track('internal', [
          _release('old', ['999']),
          _release('new', ['2140']),
        ]),
      ]);

      expect(tracks.newestVersionCodeOn('internal'), 2140);
    });

    test('is null for an empty track rather than zero', () {
      final tracks = _tracksOf([_track('internal', const [])]);

      expect(tracks.newestVersionCodeOn('internal'), isNull);
    });

    test('is null for a track Play does not hold at all', () {
      // Distinguishable from an empty track through [PlayTracks.track], which
      // is null in one case and not the other.
      final tracks = _tracksOf([_track('production', const [])]);

      expect(tracks.newestVersionCodeOn('internal'), isNull);
      expect(tracks.track('internal'), isNull);
      expect(tracks.track('production'), isNotNull);
    });

    test('does not read a neighbouring track', () {
      final tracks = _tracksOf([
        _track('production', [
          _release('1.4.0', ['2132']),
        ]),
        _track('internal', [
          _release('1.3.0', ['2130']),
        ]),
      ]);

      expect(tracks.newestVersionCodeOn('internal'), 2130);
      expect(tracks.newestVersionCodeOn('production'), 2132);
    });
  });

  group('fields', () {
    test('a release carries its name, its codes and its status', () {
      final release = _tracksOf([
        _track('beta', [
          _release('1.4.0', ['2132'], status: 'inProgress'),
        ]),
      ]).track('beta')!.releases.single;

      expect(release.name, '1.4.0');
      expect(release.versionCodes, [2132]);
      expect(release.status, 'inProgress');
    });

    test('uploaded bundles are every versionCode Play has accepted', () {
      // Longer than the tracks account for: a bundle can be uploaded and
      // assigned to nothing, and that is the evidence an upload arrived.
      final tracks = _tracksOf(
        [
          _track('internal', [
            _release('1.4.0', ['2132']),
          ]),
        ],
        bundles: [_bundle(2130), _bundle(2131), _bundle(2132)],
      );

      expect(tracks.uploadedVersionCodes, [2130, 2131, 2132]);
    });

    test('an unnamed track is named rather than left as "null"', () {
      expect(
        _tracksOf([Track(releases: const [])]).tracks.single.name,
        '(unnamed)',
      );
    });
  });

  group('lines', () {
    test('are what `play tracks` has always printed', () {
      final tracks = _tracksOf(
        [
          _track('production', [
            _release('1.3.0', ['2130']),
          ]),
          _track('internal', [
            _release('1.4.0', ['2132'], status: 'draft'),
          ]),
        ],
        bundles: [_bundle(2130), _bundle(2132)],
      );

      expect(tracks.lines, [
        '  production: "1.3.0" codes=[2130] completed',
        '  internal: "1.4.0" codes=[2132] draft',
        '  uploaded bundles: [2130, 2132]',
      ]);
    });

    test('say a track is empty rather than omitting it', () {
      // A track with nothing on it is a fact worth printing; a missing line
      // reads as a track that does not exist.
      final tracks = _tracksOf([_track('alpha', const [])]);

      expect(tracks.lines.first, '  alpha: (empty)');
    });

    test('report every release on a track, not just the newest', () {
      final tracks = _tracksOf([
        _track('production', [
          _release('1.3.0', ['2130'], status: 'halted'),
          _release('1.4.0', ['2132'], status: 'inProgress'),
        ]),
      ]);

      expect(tracks.lines, [
        '  production: "1.3.0" codes=[2130] halted',
        '  production: "1.4.0" codes=[2132] inProgress',
        '  uploaded bundles: []',
      ]);
    });
  });
}
