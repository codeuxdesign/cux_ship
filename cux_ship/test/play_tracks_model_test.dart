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
  double? userFraction,
}) => TrackRelease(
  name: name,
  versionCodes: versionCodes,
  status: status,
  // **The fake carries Play's own nullability, not a convenience default.**
  // Google sets `userFraction` only for `inProgress` and `halted`, so the
  // `completed` default here sends none — which is the case that makes
  // `audienceFraction` more than a rename, and a default of `1.0` would hide
  // it in every test that did not name one.
  userFraction: userFraction,
);

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

    test('carry the rollout percentage, and only where Play sent one', () {
      // **The line is what a consumer prints verbatim**, so a staged rollout
      // that renders identically to a finished one is the gap read as prose
      // rather than as a field. `completed` keeps its old line exactly:
      // appending `100%` there would print an inference rather than what Play
      // said, and the word `completed` is already on the line.
      final tracks = _tracksOf([
        _track('production', [
          _release('1.4.0', ['2132'], status: 'inProgress', userFraction: 0.2),
          _release('1.3.0', ['2130'], status: 'halted', userFraction: 0.05),
          _release('1.2.0', ['2128']),
        ]),
      ]);

      expect(tracks.lines, [
        '  production: "1.4.0" codes=[2132] inProgress  20%',
        '  production: "1.3.0" codes=[2130] halted  5%',
        '  production: "1.2.0" codes=[2128] completed',
        '  uploaded bundles: []',
      ]);
    });

    test('render a fraction Play allows and a whole percent cannot say', () {
      // Play takes any fraction in `0 < f < 1`. Rounding to whole percent
      // would print 1.5% as 2% and 0.5% as 0% — a number the store never sent,
      // in a line this package promises is derived from its own fields.
      //
      // `0.07` is here because the arithmetic, not the text, is the trap:
      // `0.07 * 100` is `7.000000000000001` as a double, so a renderer that
      // trusted the multiplication would print that.
      final tracks = _tracksOf([
        _track('production', [
          _release('a', ['1'], status: 'inProgress', userFraction: 0.015),
          _release('b', ['2'], status: 'inProgress', userFraction: 0.005),
          _release('c', ['3'], status: 'inProgress', userFraction: 0.07),
          _release('d', ['4'], status: 'inProgress', userFraction: 0.5),
        ]),
      ]);

      expect(tracks.lines.take(4), [
        '  production: "a" codes=[1] inProgress  1.5%',
        '  production: "b" codes=[2] inProgress  0.5%',
        '  production: "c" codes=[3] inProgress  7%',
        '  production: "d" codes=[4] inProgress  50%',
      ]);
    });
  });

  group('the fraction a release carries', () {
    test('is Play\'s own, parsed through unchanged', () {
      final tracks = _tracksOf([
        _track('production', [
          _release('1.4.0', ['2132'], status: 'inProgress', userFraction: 0.2),
        ]),
      ]);

      expect(tracks.track('production')?.releases.single.userFraction, 0.2);
    });

    test('and is null for a completed rollout, which is what Play sends', () {
      // Not zero. Play omits the field for `completed` precisely because the
      // release reached everybody, so a zero here would invert the fact.
      final tracks = _tracksOf([
        _track('production', [
          _release('1.4.0', ['2132']),
        ]),
      ]);

      expect(tracks.track('production')?.releases.single.userFraction, isNull);
    });
  });
}
