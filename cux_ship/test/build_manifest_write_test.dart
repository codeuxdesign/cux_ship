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

/// A stand-in artifact in a format that has no baked-facts reader.
///
/// **`pkg` rather than `aab`, and that is load-bearing.** These tests are about
/// digests, shas and where the sidecar lands, not about cross-checking — but
/// the writer cross-checks every artifact whose format has a reader, and a text
/// file named `.aab` is not a bundle. It used to pass anyway, because a reader
/// that could not open its input reported "no reader for aab" and the check
/// quietly did not happen. Naming these what they actually are keeps that
/// crutch from coming back.
String _artifact([String bytes = 'a signed installer, pretend']) {
  final path = '${_dist.path}/how-it-went-1.1.0-53.pkg';
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
      platform: 'macos',
      producerName: 'cux_ship',
      producerVersion: '3.4.0-dev.1',
      builtAt: '2026-08-19T14:22:00Z',
      format: 'pkg',
      flavor: flavor,
    ).path;

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
    expect(read.platform, 'macos');
    expect(read.format, 'pkg');
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
          contains('full lowercase commit id'),
        ),
      ),
    );
  });

  test('a sha256 repository commit id is accepted', () {
    // git has had a sha256 object format since 2.29, where a commit id is 64
    // hex characters. A check that knew only 40 would refuse a valid id and
    // insist it was the wrong length — the short-sha defect from the other
    // side, encoding "what our repositories use" as "what is correct".
    final written = writeBuildManifest(
      artifactPath: _artifact(),
      versionName: '1.1.0',
      buildNumber: '53',
      gitSha: 'd' * 64,
      dirty: false,
      platform: 'android',
      producerName: 'cux_ship',
      producerVersion: '3.4.0-dev.1',
      builtAt: '2026-08-19T14:22:00Z',
    );

    expect(BuildManifest.read(written.path).gitSha, 'd' * 64);
  });

  test('a length between the two formats is still an abbreviation', () {
    // 48 characters is not a shorter sha256 — it is a truncated one, and the
    // point of the check is full rather than any particular length.
    expect(
      () => writeBuildManifest(
        artifactPath: _artifact(),
        versionName: '1.1.0',
        buildNumber: '53',
        gitSha: 'd' * 48,
        dirty: false,
        platform: 'android',
        producerName: 'cux_ship',
        producerVersion: '3.4.0-dev.1',
        builtAt: '2026-08-19T14:22:00Z',
      ),
      throwsA(isA<ReleaseException>()),
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

  test('a placeholder build number is refused on verify', () {
    // The refusal the field was specified for. It was read, written and shown
    // as UNASSIGNED for a whole release cycle while nothing acted on it — the
    // only guard was a shell `if` in one consuming repository, so every other
    // --manifest caller would have shipped build 0.
    final artifact = _artifact();
    final written = writeBuildManifest(
      artifactPath: artifact,
      versionName: '1.1.0',
      buildNumber: '0',
      buildNumberAssigned: false,
      gitSha: _sha,
      dirty: false,
      platform: 'android',
      producerName: 'cux_ship',
      producerVersion: '3.4.0-dev.1',
      builtAt: '2026-08-19T14:22:00Z',
    );

    expect(
      () => BuildManifest.read(written.path).verify(),
      throwsA(
        isA<ReleaseException>().having(
          (e) => e.toString(),
          'message',
          contains('placeholder'),
        ),
      ),
    );
    expect(
      () => BuildManifest.read(written.path).verify(allowDirty: true),
      throwsA(isA<ReleaseException>()),
      reason: '--allow-dirty must not wave through an unnumbered build',
    );
  });

  test('a schema 1 manifest still reads, and its variant becomes format', () {
    // Two producers write schema 1 today. Refusing it the day 2 lands would
    // strand every dist/ already on disk.
    final artifact = _artifact();
    final path = '${_dist.path}/manifest.json';
    File(path).writeAsStringSync(
      jsonEncode({
        'schema': 1,
        'platform': 'macos',
        'versionName': '1.1.0',
        'buildNumber': 53,
        'gitSha': 'd9c394b',
        'dirty': false,
        'variant': 'pkg',
        'artifact': 'how-it-went-1.1.0-53.pkg',
        'sha256': sha256.convert(File(artifact).readAsBytesSync()).toString(),
      }),
    );

    final read = BuildManifest.read(path);
    expect(read.format, 'pkg', reason: 'variant is schema 1\'s spelling');
    expect(read.buildNumberAssigned, isTrue, reason: 'absent is not a claim');
    expect(() => read.verify(), returnsNormally);
  });

  test('--out renames within the directory, and stays readable', () {
    // One artifact per directory wants a fixed name the uploader can state
    // rather than glob for, which is a better shape than the sidecar default.
    final artifact = _artifact();
    final written = writeBuildManifest(
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

    expect(written.path, '${_dist.path}/manifest.json');
    expect(BuildManifest.read(written.path).artifactPath, artifact);
    expect(() => BuildManifest.read(written.path).verify(), returnsNormally);
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

  test('buildNumber is a JSON integer, as the schema says', () {
    // The first writer emitted a string. Nothing failed: the reader stringifies
    // whatever it finds, so the spec and its only implementation drifted apart
    // with every test green. A second producer writes against the prose.
    final path = _write(_artifact());
    final written = jsonDecode(File(path).readAsStringSync()) as Map;

    expect(written['buildNumber'], 53);
    expect(written['buildNumber'], isA<int>());
  });

  test('a non-integer buildNumber is refused, not coerced', () {
    expect(
      () => writeBuildManifest(
        artifactPath: _artifact(),
        versionName: '1.1.0',
        buildNumber: '1.2.3',
        gitSha: _sha,
        dirty: false,
        platform: 'ios',
        producerName: 'cux_ship',
        producerVersion: '3.4.0-dev.1',
        builtAt: '2026-08-19T14:22:00Z',
      ),
      throwsA(
        isA<ReleaseException>().having(
          (e) => e.toString(),
          'message',
          contains('must be an integer'),
        ),
      ),
    );
  });

  test('a format with a reader that cannot read the file is refused', () {
    // The distinction this locks in: "no reader for this format" is a fact
    // about the format, and "the reader could not open this file" is a fact
    // about the file. Both used to print the first sentence, so a truncated
    // download, a missing `unzip`, or a text file with the wrong extension all
    // rendered as ordinary trusted-loudly output — and the check silently
    // stopped running. Every fixture in this file was standing on that.
    final path = '${_dist.path}/how-it-went-1.1.0-53.aab';
    File(path).writeAsStringSync('not a zip, whatever it is called');

    expect(
      () => writeBuildManifest(
        artifactPath: path,
        versionName: '1.1.0',
        buildNumber: '53',
        gitSha: _sha,
        dirty: false,
        platform: 'android',
        producerName: 'cux_ship',
        producerVersion: '3.4.0-dev.1',
        builtAt: '2026-08-19T14:22:00Z',
        format: 'aab',
      ),
      throwsA(
        isA<ReleaseException>().having(
          (e) => e.toString(),
          'message',
          allOf(contains('cannot cross-check'), contains('truncated')),
        ),
      ),
    );
    expect(
      File('$path.manifest.json').existsSync(),
      isFalse,
      reason: 'a refusal must not leave a manifest behind',
    );
  });

  test('a format with no reader is trusted, and says so', () {
    // The other side of the same coin, and the reason the refusal above cannot
    // simply be "always refuse": pkg has no reader and never will have one
    // here, so it must pass — while saying out loud that nothing was checked.
    final written = writeBuildManifest(
      artifactPath: _artifact(),
      versionName: '1.1.0',
      buildNumber: '53',
      gitSha: _sha,
      dirty: false,
      platform: 'macos',
      producerName: 'cux_ship',
      producerVersion: '3.4.0-dev.1',
      builtAt: '2026-08-19T14:22:00Z',
      format: 'pkg',
    );

    expect(written.crossCheck, contains('no reader for pkg'));
    expect(written.crossCheck, contains('taken on trust'));
  });

  test('repo-local keys go under x, where no shared tool reads them', () {
    final written = writeBuildManifest(
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
    final document = jsonDecode(File(written.path).readAsStringSync()) as Map;

    expect(document['x'], {'target': 'wasm'});
    expect(
      document.containsKey('target'),
      isFalse,
      reason: 'unnamespaced would collide with a future schema field',
    );
  });
}
