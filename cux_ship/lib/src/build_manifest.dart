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
const supportedManifestSchema = 2;

/// Schemas this can read.
///
/// **Both, for as long as anything writes 1.** Schema 1 has two producers and
/// both are hand-rolled shell in repositories we control, so the window is
/// bounded — but refusing 1 the day 2 lands would strand every `dist/` already
/// on disk, and a reader that cannot read yesterday's build is a reader nobody
/// can adopt incrementally.
const readableManifestSchemas = {1, 2};

Map<String, String>? _stringMap(dynamic value) => value is Map
    ? {for (final e in value.entries) '${e.key}': '${e.value}'}
    : null;

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
    this.format,
    this.flavor,
    this.builtAt,
    this.producer,
    this.toolchain,
    this.gitTag,
    this.buildNumberAssigned = true,
    this.packaging,
    this.derivedFrom = const [],
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
    if (!readableManifestSchemas.contains(schema)) {
      throw ReleaseException(
        '$manifestPath declares schema $schema and this understands '
        '${readableManifestSchemas.join(" and ")}. Refusing rather than '
        'guessing: every value '
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
      // Schema 1 spelled this `variant`; schema 2 renames it because *variant*
      // means flavor-plus-buildType in Gradle, and one consuming repository has
      // six Gradle flavors. Both are read, so a schema-1 `dist/` still resolves.
      format: (document['format'] ?? document['variant'])?.toString(),
      flavor: document['flavor']?.toString(),
      builtAt: document['builtAt']?.toString(),
      producer: _stringMap(document['producer']),
      toolchain: _stringMap(document['toolchain']),
      gitTag: document['gitTag']?.toString(),
      // Absent means assigned. A schema-1 manifest that never carried the field
      // is not claiming a placeholder — but a schema-2 one that says `false`
      // is, and an upload must be able to refuse it.
      buildNumberAssigned: document['buildNumberAssigned'] != false,
      packaging: _stringMap(document['packaging']),
      derivedFrom: [
        for (final entry in (document['derivedFrom'] as List<dynamic>? ?? []))
          if (entry is Map<String, dynamic>) _stringMap(entry)!,
      ],
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

  /// The artifact's container kind — `aab`, `ipa`, `pkg`, `msix`. Schema 1's
  /// `variant` is read into it.
  final String? format;

  /// Which of several artifacts built from one commit this is. Six Android
  /// flavors share a version *and* a build number, so a filename is not a
  /// discriminator.
  final String? flavor;

  final String? builtAt;
  final Map<String, String>? producer;
  final Map<String, String>? toolchain;
  final String? gitTag;

  /// False when allocation failed and [buildNumber] is a placeholder.
  ///
  /// Absent reads as true, because a schema-1 manifest never carried it and is
  /// not claiming otherwise.
  final bool buildNumberAssigned;

  /// The tree the *packaging* files came from, when this artifact was
  /// repackaged from another. A `.deb` is tarball bytes plus a control file and
  /// maintainer scripts from a different checkout, and a packaging defect is a
  /// real shipping defect whose provenance is not the tarball's.
  final Map<String, String>? packaging;

  /// Ancestors, nearest first. Each names an artifact this was derived from and
  /// the digest of the bytes actually consumed.
  final List<Map<String, String>> derivedFrom;

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

/// Writes the sidecar manifest beside [artifactPath], and returns its path.
///
/// **The digest is computed here, from the artifact as it now stands.** That is
/// the one thing a caller must not pass in: a digest recorded before signing
/// fails verification on every real release rather than never, and taking it
/// from the file we are describing makes that impossible to get wrong.
///
/// **`gitSha` and `dirty` are inputs and are never derived.** They describe the
/// tree at *build* time, and this runs afterwards — anything that changed in
/// between would be invisible. Only the build knows both at the moment it
/// starts, so it passes them and a wrong value has to be supplied rather than
/// drift in.
///
/// `builtAt` is likewise a parameter rather than a clock read: a caller that
/// wants a build's real start time can give it, and a test can pin it.
///
/// [outPath] renames the manifest **within the artifact's own directory** — a
/// build that puts one artifact per directory wants a fixed `manifest.json`
/// its uploader can name without globbing, which is a better shape than the
/// sidecar default and the reason this is not hardcoded. A path in any other
/// directory is refused rather than accepted, because [artifact] is stored as
/// a basename resolved against the manifest's directory: a manifest written
/// elsewhere parses fine and then cannot find the file it describes.
String writeBuildManifest({
  required String artifactPath,
  String? outPath,
  required String versionName,
  required String buildNumber,
  required String gitSha,
  required bool dirty,
  required String platform,
  required String producerName,
  required String producerVersion,
  required String builtAt,
  String? format,
  String? flavor,
  String? gitTag,
  bool buildNumberAssigned = true,
  Map<String, String>? toolchain,
  Map<String, String>? packaging,
  List<Map<String, String>> derivedFrom = const [],
  Map<String, dynamic> extra = const {},
}) {
  final artifact = File(artifactPath);
  if (!artifact.existsSync()) {
    throw ReleaseException(
      'no artifact at $artifactPath — a manifest describes something that '
      'exists, and writing one first would record a digest of nothing',
    );
  }
  if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(gitSha)) {
    throw ReleaseException(
      'gitSha must be the full 40-character lowercase sha, and is "$gitSha". '
      'A reader normalizes whatever it is given, which is exactly what lets a '
      'short sha survive here and break a tool that does not.',
    );
  }

  final document = <String, dynamic>{
    'schema': supportedManifestSchema,
    'artifact': p.basename(artifactPath),
    'sha256': sha256.convert(artifact.readAsBytesSync()).toString(),
    'versionName': versionName,
    'buildNumber': buildNumber,
    'buildNumberAssigned': buildNumberAssigned,
    'gitSha': gitSha,
    'dirty': dirty,
    'platform': platform,
    'builtAt': builtAt,
    'producer': {'name': producerName, 'version': producerVersion},
    if (format != null) ...{'format': format},
    if (flavor != null) ...{'flavor': flavor},
    if (gitTag != null) ...{'gitTag': gitTag},
    if (toolchain != null) ...{'toolchain': toolchain},
    if (packaging != null) ...{'packaging': packaging},
    if (derivedFrom.isNotEmpty) ...{'derivedFrom': derivedFrom},
    if (extra.isNotEmpty) ...{'x': extra},
  };

  final path = outPath ?? '$artifactPath.manifest.json';
  final artifactDirectory = p.dirname(p.absolute(artifactPath));
  if (p.dirname(p.absolute(path)) != artifactDirectory) {
    throw ReleaseException(
      'the manifest has to sit in the same directory as the artifact, and '
      '--out names ${p.dirname(path)} while the artifact is in '
      '${p.dirname(artifactPath)}. It records the artifact by basename so a '
      'dist/ tree stays movable between machines, so one written elsewhere '
      'would parse and then not find the file it describes.',
    );
  }
  File(path).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(document)}\n',
  );
  return path;
}
