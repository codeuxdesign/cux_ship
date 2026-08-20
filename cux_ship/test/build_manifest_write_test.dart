// SPDX-License-Identifier: Apache-2.0
//
// One implementation writes what one implementation reads — which is the whole
// argument for the writer existing, so the tests that matter are the ones that
// prove the round trip and the ones that prove a bad manifest cannot be
// written in the first place.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cux_ship/src/build_manifest.dart';
import 'package:cux_ship/src/release.dart' show ReleaseException;
import 'package:test/test.dart';

late Directory _dist;

String _artifact([String bytes = 'a signed bundle, pretend']) {
  final path = '${_dist.path}/how-it-went-1.1.0-53.aab';
  File(path).writeAsStringSync(bytes);
  return path;
}

const _sha = 'd9c394bd9c394bd9c394bd9c394bd9c394bd9c39';

String _write(String artifactPath, {bool dirty = false, String? flavor}) =>
    writeBuildManifest(
      artifactPath: artifactPath,
      versionName: '1.1.0',
      buildNumber: '53',
      gitSha: _sha,
      dirty: dirty,
      platform: 'android',
      producerName: 'cux_ship',
      producerVersion: '3.4.0-dev.1',
      builtAt: '2026-08-19T14:22:00Z',
      format: 'aab',
      flavor: flavor,
    );

void main() {
  setUp(() => _dist = Directory.systemTemp.createTempSync('cux_ship_write'));
  tearDown(() => _dist.deleteSync(recursive: true));

  test('what it writes is what the reader reads', () {
    // The round trip is the point. Two hand-maintained producers is what this
    // exists to end, and a writer whose output its own reader rejects would be
    // a third.
    final path = _write(_artifact(), flavor: 'playstore');
    final read = BuildManifest.read(path);

    expect(read.versionName, '1.1.0');
    expect(read.buildNumber, '53');
    expect(read.gitSha, _sha);
    expect(read.platform, 'android');
    expect(read.format, 'aab');
    expect(read.flavor, 'playstore');
    expect(read.producer?['name'], 'cux_ship');
    expect(read.buildNumberAssigned, isTrue);
    expect(() => read.verify(), returnsNormally);
  });

  test('the sidecar sits beside the artifact and names it', () {
    final artifact = _artifact();
    final path = _write(artifact);

    expect(path, '$artifact.manifest.json');
    expect(BuildManifest.read(path).artifactPath, artifact);
  });

  test('the digest is of the artifact as it stands, not something passed in', () {
    // A digest recorded before signing fails on every real release rather than
    // never. Computing it here rather than accepting it makes that unwritable.
    const bytes = 'signed, finally';
    final path = _write(_artifact(bytes));

    final written = jsonDecode(File(path).readAsStringSync()) as Map;
    expect(written['sha256'], sha256.convert(utf8.encode(bytes)).toString());
  });

  test('a short sha is refused, because the reader would accept it', () {
    // `resolveCommit` normalizes whatever it is given, so a short sha *works* —
    // which is exactly what lets a sloppy producer survive long enough to break
    // a tool that does not normalize.
    expect(
      () => writeBuildManifest(
        artifactPath: _artifact(),
        versionName: '1.1.0',
        buildNumber: '53',
        gitSha: 'd9c394b',
        dirty: false,
        platform: 'android',
        producerName: 'cux_ship',
        producerVersion: '3.4.0-dev.1',
        builtAt: '2026-08-19T14:22:00Z',
      ),
      throwsA(
        isA<ReleaseException>().having(
          (e) => e.toString(),
          'message',
          contains('40-character'),
        ),
      ),
    );
  });

  test('refuses to describe an artifact that is not there', () {
    expect(
      () => _write('${_dist.path}/never-built.aab'),
      throwsA(
        isA<ReleaseException>().having(
          (e) => e.toString(),
          'message',
          contains('no artifact'),
        ),
      ),
    );
  });

  test('a dirty build is written honestly and refused on read', () {
    final path = _write(_artifact(), dirty: true);
    final read = BuildManifest.read(path);

    expect(read.dirty, isTrue);
    expect(() => read.verify(), throwsA(isA<ReleaseException>()));
    expect(() => read.verify(allowDirty: true), returnsNormally);
  });

  test('a schema 1 manifest still reads, and its variant becomes format', () {
    // Two producers write schema 1 today. Refusing it the day 2 lands would
    // strand every dist/ already on disk.
    final artifact = _artifact();
    final path = '${_dist.path}/manifest.json';
    File(path).writeAsStringSync(
      jsonEncode({
        'schema': 1,
        'platform': 'android',
        'versionName': '1.1.0',
        'buildNumber': 53,
        'gitSha': 'd9c394b',
        'dirty': false,
        'variant': 'aab',
        'artifact': 'how-it-went-1.1.0-53.aab',
        'sha256': sha256.convert(File(artifact).readAsBytesSync()).toString(),
      }),
    );

    final read = BuildManifest.read(path);
    expect(read.format, 'aab', reason: 'variant is schema 1\'s spelling');
    expect(read.buildNumberAssigned, isTrue, reason: 'absent is not a claim');
    expect(() => read.verify(), returnsNormally);
  });

  test('--out renames within the directory, and stays readable', () {
    // One artifact per directory wants a fixed name the uploader can state
    // rather than glob for, which is a better shape than the sidecar default.
    final artifact = _artifact();
    final path = writeBuildManifest(
      artifactPath: artifact,
      outPath: '${_dist.path}/manifest.json',
      versionName: '1.1.0',
      buildNumber: '53',
      gitSha: _sha,
      dirty: false,
      platform: 'android',
      producerName: 'cux_ship',
      producerVersion: '3.4.0-dev.1',
      builtAt: '2026-08-19T14:22:00Z',
    );

    expect(path, '${_dist.path}/manifest.json');
    expect(BuildManifest.read(path).artifactPath, artifact);
    expect(() => BuildManifest.read(path).verify(), returnsNormally);
  });

  test('--out into another directory is refused', () {
    // The artifact is stored as a basename, resolved against the manifest's
    // own directory — that is what keeps a dist/ tree movable between
    // machines. A manifest written somewhere else parses fine and then cannot
    // find the file it describes, which is a failure at upload rather than
    // here.
    final elsewhere = Directory('${_dist.path}/elsewhere')..createSync();
    expect(
      () => writeBuildManifest(
        artifactPath: _artifact(),
        outPath: '${elsewhere.path}/manifest.json',
        versionName: '1.1.0',
        buildNumber: '53',
        gitSha: _sha,
        dirty: false,
        platform: 'android',
        producerName: 'cux_ship',
        producerVersion: '3.4.0-dev.1',
        builtAt: '2026-08-19T14:22:00Z',
      ),
      throwsA(
        isA<ReleaseException>().having(
          (e) => e.toString(),
          'message',
          contains('same directory'),
        ),
      ),
    );
  });

  test('repo-local keys go under x, where no shared tool reads them', () {
    final path = writeBuildManifest(
      artifactPath: _artifact(),
      versionName: '1.1.0',
      buildNumber: '53',
      gitSha: _sha,
      dirty: false,
      platform: 'web',
      producerName: 'cux_ship',
      producerVersion: '3.4.0-dev.1',
      builtAt: '2026-08-19T14:22:00Z',
      extra: const {'target': 'wasm'},
    );
    final written = jsonDecode(File(path).readAsStringSync()) as Map;

    expect(written['x'], {'target': 'wasm'});
    expect(
      written.containsKey('target'),
      isFalse,
      reason: 'unnamespaced would collide with a future schema field',
    );
  });
}
