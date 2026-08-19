// SPDX-License-Identifier: Apache-2.0
//
// What a build produced, read rather than retyped.
//
// **This is the file a build script writes beside its artifact**, and the whole
// reason to read it here is that every value an upload needs is already in it:
// the artifact's name, the build number, the version, the commit it was built
// from, and the digest. Typed out as flags instead, those are five chances to
// name the wrong build — and the failure is not a refusal, it is uploading one
// artifact while telling the store it is another.
//
// That is not hypothetical. The Android path in one consuming repository has a
// wrapper script that reads this file; the Apple path had none, so every Apple
// upload was eight flags typed by hand. In one afternoon that produced three
// consecutive failed uploads, and a fourth where iOS went up as build 51 while
// macOS — rebuilt minutes later from a commit that had moved — was 52. Nothing
// checked that the numbers agreed, because nothing was in a position to.
//
// **A deliberate reversal of an earlier decision, so it is worth saying why.**
// `runAsc` and `runPlay` were written to know nothing about manifests: "invoked
// by a project's upload script, which has already checked the manifest, the
// artifact digest and the provenance rules". That layering held while every
// project had such a script. It stopped holding when provenance moved into
// `cux_ship` — a record of *which commit shipped* cannot be written by a
// command that is forbidden to know the commit — and it never held at all for
// the Apple side, where the script it delegates to does not exist.
//
// It stays optional. Nothing requires a manifest, and an explicit flag still
// wins over one, so a project with no build script is unaffected.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'release.dart' show ReleaseException;

/// The schema this understands. A manifest declaring anything else is refused
/// rather than read optimistically: the fields below are what an upload is
/// named by, and guessing at an unknown layout would mean publishing an
/// artifact described by whatever happened to parse.
const supportedManifestSchema = 1;

/// A build manifest, as written beside the artifact it describes.
class BuildManifest {
  const BuildManifest({
    required this.path,
    required this.artifact,
    required this.versionName,
    required this.buildNumber,
    required this.gitSha,
    required this.dirty,
    required this.sha256Digest,
    required this.platform,
  });

  /// Reads and validates, or throws [ReleaseException] saying which field.
  factory BuildManifest.read(String manifestPath) {
    final file = File(manifestPath);
    if (!file.existsSync()) {
      throw ReleaseException('no build manifest at $manifestPath');
    }

    final Map<String, dynamic> document;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, dynamic>) {
        throw ReleaseException('$manifestPath is not a JSON object');
      }
      document = decoded;
    } on FormatException catch (e) {
      throw ReleaseException('$manifestPath is not valid JSON: ${e.message}');
    }

    final schema = document['schema'];
    if (schema != supportedManifestSchema) {
      throw ReleaseException(
        '$manifestPath declares schema $schema and this understands '
        '$supportedManifestSchema. Refusing rather than guessing: every value '
        'an upload is named by comes from this file.',
      );
    }

    String need(String key) {
      final value = document[key];
      if (value == null || '$value'.isEmpty) {
        throw ReleaseException('$manifestPath has no $key');
      }
      return '$value';
    }

    return BuildManifest(
      path: manifestPath,
      artifact: need('artifact'),
      versionName: need('versionName'),
      buildNumber: need('buildNumber'),
      gitSha: need('gitSha'),
      dirty: document['dirty'] == true,
      sha256Digest: need('sha256'),
      platform: need('platform'),
    );
  }

  final String path;

  /// The artifact's name, relative to the manifest's own directory — which is
  /// how a `dist/` tree stays movable between machines.
  final String artifact;

  final String versionName;
  final String buildNumber;

  /// The commit the artifact was **built from**, which is the one thing here
  /// that cannot be recovered from the artifact itself.
  final String gitSha;

  /// The working tree held uncommitted or untracked files when this was built,
  /// so [gitSha] does not describe what is inside the artifact.
  final bool dirty;

  final String sha256Digest;
  final String platform;

  /// The artifact, resolved against the manifest's directory.
  String get artifactPath => p.join(p.dirname(p.absolute(path)), artifact);

  /// Refuses a manifest that must not be uploaded from, and verifies that the
  /// artifact beside it is the one it describes.
  ///
  /// **The digest check is the one that earns its keep.** It catches a `dist/`
  /// that was edited, half-written, or left from an earlier build whose
  /// manifest was replaced without its artifact being rewritten — a state in
  /// which every flag is correct and the bytes are not.
  void verify({bool allowDirty = false}) {
    if (dirty && !allowDirty) {
      throw ReleaseException(
        'built from a dirty tree ($gitSha), so the commit this records does '
        'not describe what is in the artifact — commit first, or pass '
        '--allow-dirty',
      );
    }

    final file = File(artifactPath);
    if (!file.existsSync()) {
      throw ReleaseException(
        '$path names $artifact, which is not beside it at $artifactPath',
      );
    }
    final actual = sha256.convert(file.readAsBytesSync()).toString();
    if (actual != sha256Digest) {
      throw ReleaseException(
        'the artifact does not match the manifest — rebuild\n'
        '  manifest  $sha256Digest\n'
        '  actual    $actual',
      );
    }
  }
}
