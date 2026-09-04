// SPDX-License-Identifier: Apache-2.0
//
// The build listing became a value a caller reads rather than lines a caller
// greps, and the two claims that carries are both about *ordering*.
//
// Apple's `sort=-version` is lexical: build 9 comes back above build 10. This
// package has always known that — `appstore build-number` sorts numerically
// before answering — and the listing beside it did not, so the two commands
// could name different builds from the same account. One comparator now,
// tested here.
//
// The second claim is that "newest" and "newest usable" are different
// questions. A build uploaded four minutes ago is the newest and cannot be
// released, and a consumer asking "which build does the store hold" wants the
// first while a promote wants the second.
import 'dart:io';

import 'package:cux_ship/read.dart';
import 'package:cux_ship/src/appstore/app_store.dart';
import 'package:cux_ship/src/appstore/asc_client.dart';
import 'package:cux_ship/src/appstore/reads.dart';
import 'package:test/test.dart';

/// A build resource as Apple sends one.
///
/// [platform] is not part of the real payload — Apple filters on
/// `preReleaseVersion.platform` server-side and does not echo it back. The
/// fake carries it so it can filter the way the real endpoint does; the model
/// never reads it.
Map<String, dynamic> _build(
  String version, {
  String? state = 'VALID',
  bool expired = false,
  String? uploaded = '2026-09-04T09:12:33-07:00',
  String platform = 'IOS',
}) => {
  'type': 'builds',
  'id': 'build-$platform-$version',
  '_platform': platform,
  'attributes': {
    'version': version,
    'processingState': ?state,
    'expired': expired,
    'uploadedDate': ?uploaded,
  },
};

/// Canned App Store Connect, narrowed to `/v1/builds`.
///
/// **It filters by platform, because the branch under test depends on that.**
/// iOS and macOS builds of the same commit carry the same build number, so a
/// fake that returned both would make a dropped platform filter — which this
/// package has shipped once — invisible to every test here.
class _FakeClient implements AscClient {
  _FakeClient(this.builds);

  final List<Map<String, dynamic>> builds;
  final List<Map<String, String>> queries = <Map<String, String>>[];

  @override
  Future<List<Map<String, dynamic>>> getAll(
    String path, {
    Map<String, String>? query,
  }) async {
    expect(path, '/v1/builds');
    queries.add(query ?? const {});
    final platform = query?['filter[preReleaseVersion.platform]'];
    return builds
        .where((b) => platform == null || b['_platform'] == platform)
        .toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Captures what a command printed. `beta_groups_test.dart`'s shape.
class _MemoryStdout implements Stdout {
  final buffer = StringBuffer();

  @override
  void writeln([Object? object = '']) => buffer.writeln(object);

  @override
  void write(Object? object) => buffer.write(object);

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<String> _printed(Future<void> Function() body) async {
  final captured = _MemoryStdout();
  await IOOverrides.runZoned(body, stdout: () => captured);
  await captured.close();
  return captured.buffer.toString();
}

void main() {
  final app = App('app-1', 'Example', 'design.codeux.example');

  AppStore storeOf(_FakeClient client) =>
      AppStore(client, Writer(client, dryRun: true), platform: AscPlatform.ios);

  AppStoreBuilds listingOf(List<Map<String, dynamic>> payload) =>
      appStoreBuildsFrom(payload, AscPlatform.ios);

  group('ordering', () {
    test('is numeric, so 10 is newer than 9', () {
      // Apple's own sort puts "9" first. Answering "which build does the store
      // hold" off that is wrong for every account that has crossed a power of
      // ten, which is all of them.
      final listing = listingOf([_build('9'), _build('100'), _build('10')]);

      expect(listing.builds.map((b) => b.buildNumber), ['100', '10', '9']);
      expect(listing.newestBuildNumber, '100');
    });

    test('and the printed listing is in that order too', () {
      // The listing and `appstore build-number` used to be able to disagree,
      // because only one of them sorted.
      final listing = listingOf([_build('9'), _build('10')]);

      expect(listing.lines.first, contains('build 10'));
      expect(listing.lines.last, contains('build 9'));
    });
  });

  group('the number a caller compares with', () {
    test('is an int, because comparing the strings is the same mistake one '
        'layer up', () {
      // Found live in the first consumer: `status` took the newest build by
      // comparing what this package printed against an integer out of a git
      // tag. Correct only while every build number has the same width — that
      // account was on 148 through 153 — and wrong at 1000.
      final listing = listingOf([_build('999'), _build('1000')]);

      expect(listing.newest?.buildNumberAsInt, 1000);
      // The mistake the accessor exists to prevent, stated so it cannot be
      // read as a stylistic preference.
      expect('999'.compareTo('1000'), greaterThan(0));
    });

    test('is null for a build number that is not one', () {
      // Apple accepts `1.2.3` as a CFBundleVersion. Null rather than zero, so
      // the caller answers the case instead of silently ordering it first.
      final build = listingOf([_build('1.2.3')]).builds.single;

      expect(build.buildNumberAsInt, isNull);
      expect(build.buildNumber, '1.2.3');
    });

    test('and such a build sorts last rather than displacing a real one', () {
      final listing = listingOf([_build('1.2.3'), _build('2131')]);

      expect(listing.newestBuildNumber, '2131');
      expect(listing.builds.last.buildNumber, '1.2.3');
    });
  });

  group('newest against newest usable', () {
    test('the newest build is the newest build, still processing or not', () {
      final listing = listingOf([
        _build('2132', state: 'PROCESSING'),
        _build('2131'),
      ]);

      expect(listing.newestBuildNumber, '2132');
      expect(listing.newest?.processingState, 'PROCESSING');
    });

    test('and the two accessors are a pair, not the same thing twice', () {
      // `newest` answers "which build does the store hold" and `newestUsable`
      // answers "which could I promote now". A consumer wants the first for a
      // status line and the second before a release.
      final listing = listingOf([
        _build('2132', state: 'PROCESSING'),
        _build('2131'),
      ]);

      expect(listing.newest?.buildNumber, '2132');
      expect(listing.newestUsable?.buildNumber, '2131');
      expect(listing.newest?.buildNumber, listing.newestBuildNumber);
    });

    test('while the newest usable one is the newest Apple has processed', () {
      final listing = listingOf([
        _build('2132', state: 'PROCESSING'),
        _build('2131'),
      ]);

      expect(listing.newestUsable?.buildNumber, '2131');
    });

    test('an expired build is processed and still not usable', () {
      // TestFlight builds last 90 days. An expired one is VALID for as long as
      // it is listed and can no longer be given to anybody.
      final listing = listingOf([
        _build('2132', expired: true),
        _build('2131'),
      ]);

      expect(listing.newestBuildNumber, '2132');
      expect(listing.newestUsable?.buildNumber, '2131');
    });

    test('with nothing usable it is null rather than the newest', () {
      final listing = listingOf([_build('2132', state: 'PROCESSING')]);

      expect(listing.newestUsable, isNull);
      expect(listing.newestBuildNumber, '2132');
    });
  });

  group('fields', () {
    test('the upload timestamp is parsed and also kept as Apple sent it', () {
      // Both, because [lines] renders the raw one: Apple's offset spelling and
      // `DateTime.toIso8601String` are not the same string, and the printed
      // output is something a consumer shows verbatim.
      final build = listingOf([
        _build('7', uploaded: '2026-09-04T09:12:33-07:00'),
      ]).builds.single;

      expect(build.uploadedDate, '2026-09-04T09:12:33-07:00');
      expect(build.uploadedAt, DateTime.utc(2026, 9, 4, 16, 12, 33));
    });

    test('an absent processing state is null rather than a guess', () {
      final build = listingOf([_build('7', state: null)]).builds.single;

      expect(build.processingState, isNull);
      expect(build.usable, isFalse);
    });

    test('a build can be looked up by number', () {
      final listing = listingOf([_build('2132'), _build('2131')]);

      expect(listing.build('2131')?.processingState, 'VALID');
      expect(listing.build('9999'), isNull);
    });
  });

  group('lines', () {
    test('are what `appstore builds` has always printed', () {
      final listing = listingOf([
        _build('2132', uploaded: '2026-09-04T09:12:33-07:00'),
      ]);

      expect(listing.lines, [
        '  build 2132  VALID  uploaded 2026-09-04T09:12:33-07:00',
      ]);
    });

    test('say so when a build has expired', () {
      final listing = listingOf([_build('2132', expired: true)]);

      expect(listing.lines.single, endsWith('  (expired)'));
    });

    test('with no builds say nothing has ever been uploaded', () {
      // "none" on its own reads as something to fix with a flag.
      expect(listingOf(const []).lines, [
        '  no builds at all — nothing has ever been uploaded',
      ]);
    });

    test('stop at twenty while the list answers over all of them', () {
      // The printed form is for reading; the list is for answering questions.
      final listing = listingOf([
        for (var i = 0; i < 25; i++) ...[_build('${2100 + i}')],
      ]);

      expect(listing.lines, hasLength(20));
      expect(listing.builds, hasLength(25));
      expect(listing.newestBuildNumber, '2124');
    });
  });

  group('the command', () {
    test('prints exactly the model lines', () async {
      final client = _FakeClient([_build('9'), _build('10')]);
      final out = await _printed(() => printBuilds(storeOf(client), app));

      expect(
        out,
        '${listingOf([_build('9'), _build('10')]).lines.join('\n')}\n',
      );
    });

    test('and asks Apple only for this platform', () async {
      // The listing that showed a build which had never been uploaded is what
      // made the missing filter visible.
      final client = _FakeClient([
        _build('2132', platform: 'MAC_OS'),
        _build('2131', platform: 'IOS'),
      ]);
      final out = await _printed(() => printBuilds(storeOf(client), app));

      expect(out, contains('build 2131'));
      expect(out, isNot(contains('build 2132')));
      expect(
        client.queries.single['filter[preReleaseVersion.platform]'],
        'IOS',
      );
    });
  });

  test('the listing names the platform it answered for', () {
    // iOS and macOS builds of one commit share a build number, so a listing
    // that does not say which platform it is about is ambiguous exactly when
    // it matters.
    expect(listingOf(const []).platform, AscPlatform.ios);
  });
}
