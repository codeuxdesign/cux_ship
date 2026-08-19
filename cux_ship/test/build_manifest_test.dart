// SPDX-License-Identifier: Apache-2.0
//
// Reading these values instead of retyping them removes a failure that does not
// announce itself: every flag correct, and the bytes belonging to a different
// build. So the cases here are mostly about refusing — a digest that does not
// match, a schema this does not understand, an artifact that is not there.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cux_ship/src/build_manifest.dart';
import 'package:cux_ship/src/release.dart' show ReleaseException;
import 'package:test/test.dart';

late Directory _dist;

/// Writes an artifact and a manifest describing it, honestly unless told not to.
String _manifest({
  String artifactBytes = 'a signed bundle, pretend',
  String? digest,
  int schema = 1,
  bool dirty = false,
  String artifactName = 'how-it-went-1.1.0-51.aab',
  bool writeArtifact = true,
}) {
  if (writeArtifact) {
    File('${_dist.path}/$artifactName').writeAsStringSync(artifactBytes);
  }
  final path = '${_dist.path}/manifest.json';
  File(path).writeAsStringSync(
    jsonEncode({
      'schema': schema,
      'app': 'how-it-went',
      'platform': 'android',
      'versionName': '1.1.0',
      'buildNumber': 51,
      'gitSha': 'fef65ce',
      'dirty': dirty,
      'artifact': artifactName,
      'sha256': digest ?? sha256.convert(utf8.encode(artifactBytes)).toString(),
    }),
  );
  return path;
}

void main() {
  setUp(() => _dist = Directory.systemTemp.createTempSync('cux_ship_manifest'));
  tearDown(() => _dist.deleteSync(recursive: true));

  test('reads every value an upload would otherwise be given by hand', () {
    final m = BuildManifest.read(_manifest());

    expect(m.versionName, '1.1.0');
    expect(m.buildNumber, '51', reason: 'a JSON number still names a build');
    expect(m.gitSha, 'fef65ce');
    expect(m.artifact, 'how-it-went-1.1.0-51.aab');
    expect(m.artifactPath, endsWith('/how-it-went-1.1.0-51.aab'));
  });

  test('the artifact is resolved beside the manifest, not beside the cwd', () {
    // The uploader runs with its own package directory as cwd, so a path
    // relative to anything else does not resolve there.
    final m = BuildManifest.read(_manifest());
    expect(File(m.artifactPath).existsSync(), isTrue);
  });

  test('verifies the artifact against the digest', () {
    expect(() => BuildManifest.read(_manifest()).verify(), returnsNormally);
  });

  test('refuses an artifact that does not match', () {
    // A dist/ edited, half-written, or left from an earlier build whose
    // manifest was replaced without its artifact being rewritten. Every flag
    // is right and the bytes are not.
    final path = _manifest(digest: 'f' * 64);
    expect(
      () => BuildManifest.read(path).verify(),
      throwsA(
        isA<ReleaseException>().having(
          (e) => e.toString(),
          'message',
          allOf(contains('does not match'), contains('rebuild')),
        ),
      ),
    );
  });

  test('refuses a build from a dirty tree unless told otherwise', () {
    final path = _manifest(dirty: true);
    expect(
      () => BuildManifest.read(path).verify(),
      throwsA(
        isA<ReleaseException>().having(
          (e) => e.toString(),
          'message',
          contains('--allow-dirty'),
        ),
      ),
      reason: 'the commit it records does not describe what is in the artifact',
    );
    expect(
      () => BuildManifest.read(path).verify(allowDirty: true),
      returnsNormally,
    );
  });

  test('refuses a schema it does not understand', () {
    // Every value an upload is named by comes from this file, so reading an
    // unknown layout optimistically means publishing an artifact described by
    // whatever happened to parse.
    expect(
      () => BuildManifest.read(_manifest(schema: 2)),
      throwsA(
        isA<ReleaseException>().having(
          (e) => e.toString(),
          'message',
          allOf(contains('schema 2'), contains('Refusing')),
        ),
      ),
    );
  });

  test('refuses a manifest whose artifact is not beside it', () {
    final path = _manifest(writeArtifact: false);
    expect(
      () => BuildManifest.read(path).verify(),
      throwsA(
        isA<ReleaseException>().having(
          (e) => e.toString(),
          'message',
          contains('not beside it'),
        ),
      ),
    );
  });

  test('names the missing field rather than failing vaguely', () {
    final path = '${_dist.path}/manifest.json';
    File(path).writeAsStringSync(jsonEncode({'schema': 1, 'platform': 'ios'}));
    expect(
      () => BuildManifest.read(path),
      throwsA(
        isA<ReleaseException>().having(
          (e) => e.toString(),
          'message',
          contains('artifact'),
        ),
      ),
    );
  });

  test('an absent or unparseable manifest says which', () {
    expect(
      () => BuildManifest.read('${_dist.path}/nope.json'),
      throwsA(
        isA<ReleaseException>().having(
          (e) => e.toString(),
          'message',
          contains('no build manifest'),
        ),
      ),
    );
    final bad = '${_dist.path}/manifest.json';
    File(bad).writeAsStringSync('{not json');
    expect(
      () => BuildManifest.read(bad),
      throwsA(
        isA<ReleaseException>().having(
          (e) => e.toString(),
          'message',
          contains('not valid JSON'),
        ),
      ),
    );
  });
}
