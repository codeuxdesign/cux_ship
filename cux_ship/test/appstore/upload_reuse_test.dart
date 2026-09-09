// SPDX-License-Identifier: Apache-2.0
//
// Re-running an upload for a build Apple already holds is a no-op, not a
// failure.
//
// **The behaviour is old; being able to see it is not.** `runAsc` built its
// `AscClient` at the point of use from the environment, so this branch was
// reachable only by uploading to Apple — the guard has been correct and
// unexercised since it was written. `ascClient` is the seam that closes that.
//
// The branch matters more than it reads. A build number is allocated once per
// commit and a release build refuses a dirty tree, so "Apple holds this build
// number" means "Apple holds this commit's binary"; without the check, altool
// answers a second attempt with ITMS-90189 and a release that has already
// half-happened dies on an artifact the store is already serving. A consumer
// pipelining its release train so builds overlap uploads makes that the
// ordinary case rather than the exotic one: a failed run leaves one store
// published and one not *by design*, and the retry has to be the same command
// typed again.
//
// **Everything here runs under `--dry-run`**, which is what keeps altool out
// of it: `uploadPackage` prints the command line it would run and returns
// before reaching `Process.run`. So the two branches are distinguished by
// whether that line appears, which is the honest signal — it is the exact
// point at which a re-upload would have been attempted.
import 'dart:io';

import 'package:cux_ship/src/appstore/asc_client.dart';
import 'package:cux_ship/src/appstore/cli.dart';
import 'package:test/test.dart';

/// A build resource as Apple sends one, plus the platform the fake filters on.
///
/// Apple does not echo `preReleaseVersion.platform` back; it filters on it
/// server-side. The fake carries it for the same reason build_listing_test's
/// does — see the filtering note on [_FakeClient].
Map<String, dynamic> _build(String version, {String platform = 'IOS'}) => {
  'type': 'builds',
  'id': 'build-$platform-$version',
  '_platform': platform,
  'attributes': {
    'version': version,
    'processingState': 'VALID',
    'expired': false,
  },
};

/// Canned App Store Connect, narrowed to the two reads an upload makes.
///
/// **It filters by build number *and* by platform, because the branch under
/// test selects on both.** `findBuild` asks for `filter[version]` — which is
/// the build number, not the marketing version — and for the platform, and a
/// fake that returned its whole list regardless would report every build as
/// already held: the reuse branch would be taken unconditionally and the
/// upload branch would be unreachable, so the pair of cases below would
/// collapse into one that cannot fail. The platform half is the same trap
/// `AppStore._platformFilter` exists for: iOS and macOS builds of one commit
/// carry the same build number, so a dropped platform filter makes an iOS
/// upload reuse a macOS binary.
class _FakeClient implements AscClient {
  _FakeClient(this.builds);

  final List<Map<String, dynamic>> builds;

  /// Every path asked for, in order — so a test can say what was *not* called
  /// as well as what was.
  final List<String> reads = <String>[];

  /// Whether `runAsc` closed a client it did not open.
  bool closed = false;

  @override
  void close() => closed = true;

  @override
  AscCredentials get credentials => AscCredentials(
    keyId: 'FAKEKEYID',
    issuerId: 'fake-issuer',
    privateKeyPem:
        '-- not a key, and never signed: nothing here calls '
        'bearerToken --',
  );

  @override
  Future<List<Map<String, dynamic>>> getAll(
    String path, {
    Map<String, String>? query,
  }) async {
    reads.add(path);
    if (path == '/v1/apps') {
      return [
        {
          'type': 'apps',
          'id': 'app-1',
          'attributes': {
            'name': 'Example',
            'bundleId': query?['filter[bundleId]'],
          },
        },
      ];
    }
    expect(path, '/v1/builds');
    final version = query?['filter[version]'];
    final platform = query?['filter[preReleaseVersion.platform]'];
    return builds
        .where(
          (b) =>
              (version == null ||
                  (b['attributes'] as Map)['version'] == version) &&
              (platform == null || b['_platform'] == platform),
        )
        .toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Captures what a command printed. `build_listing_test.dart`'s shape.
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
  late File artifact;

  setUp(() {
    final dir = Directory.systemTemp.createTempSync('cux_ship_reuse');
    addTearDown(() => dir.deleteSync(recursive: true));
    artifact = File('${dir.path}/app.ipa')
      ..writeAsStringSync('not really an ipa');
  });

  /// One `appstore upload --artifact --dry-run`, against [client].
  Future<String> upload(_FakeClient client, {String platform = 'ios'}) {
    final args = buildAscParser(AscCommand.upload).parse([
      '--platform',
      platform,
      '--bundle-id',
      'design.codeux.example',
      '--artifact',
      artifact.path,
      '--build-number',
      '52',
      '--version-name',
      '1.0.0',
      '--no-metadata',
      '--dry-run',
    ]);
    return _printed(() => runAsc(AscCommand.upload, args, ascClient: client));
  }

  test('a build Apple already holds is reused rather than uploaded', () async {
    final client = _FakeClient([_build('52')]);

    final output = await upload(client);

    expect(
      output,
      contains(
        '==> Apple already holds build 52 — using it rather than re-uploading',
      ),
    );
    // The load-bearing half. Without it this passes on a run that printed the
    // line *and* uploaded anyway, which is the failure the line exists to
    // prevent rather than to describe.
    expect(output, isNot(contains('would upload')));
  });

  test('a build Apple does not hold is uploaded', () async {
    // The negative case, and the reason the fake filters. Apple holding *some*
    // build is not Apple holding *this* one, and a check that answered the
    // first question would skip every upload after the first.
    final client = _FakeClient([_build('51')]);

    final output = await upload(client);

    expect(output, contains('would upload'));
    expect(output, isNot(contains('already holds build')));
  });

  test('a build held on the other platform is not this build', () async {
    // **Not a rare interleaving — it would fire on every release a consumer
    // does.** A build number is allocated once per commit, so a repository
    // shipping both Apple platforms from one commit uploads them as build N of
    // the same version minutes apart, distinguished by `--platform` and
    // nothing else. Without the filter the macOS upload finds the iOS binary,
    // reports it as already held, and skips: the release ships one platform
    // and reports two, with the reassuring line in the log either way.
    final client = _FakeClient([_build('52')]);

    final output = await upload(client, platform: 'macos');

    expect(output, contains('would upload'));
    expect(output, isNot(contains('already holds build')));
  });

  test('the reuse decision is a read, not a caught ITMS-90189', () async {
    // The ordering is the whole design. Apple is *asked* whether it holds the
    // build, so a duplicate never has to arrive as an altool failure that a
    // wrapper recognises by its error text and swallows — which is what
    // release scripts did before this, under `|| exitCode=$?`, and which
    // swallowed real collisions along with the harmless ones.
    //
    // Three reads, and the third is the point: resolve the app, ask for the
    // build, and then *carry on into the processing wait*, which polls the
    // same endpoint. A run that had treated the held build as somebody else's
    // would have gone to altool between the second and the third.
    final client = _FakeClient([_build('52')]);

    await upload(client);

    expect(client.reads, ['/v1/apps', '/v1/builds', '/v1/builds']);
  });

  test(
    'a supplied client is left open, because it is not this one to close',
    () async {
      // The `finally` closes what `runAsc` opened and nothing else. Written as a
      // comment first and tested here, because the failure it prevents is a
      // caller — a test, today; a library caller if writes ever move in-process
      // — whose client stops working after the first command and whose second
      // command fails somewhere unrelated to the close.
      final client = _FakeClient([_build('52')]);

      await upload(client);

      expect(client.closed, isFalse);
    },
  );
}
