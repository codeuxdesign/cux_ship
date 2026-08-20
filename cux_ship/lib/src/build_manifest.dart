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

import 'baked_facts.dart';
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

/// A full git commit id — 40 lowercase hex characters in a sha1 repository, 64
/// in a sha256 one.
///
/// Hoisted and named because an inline `RegExp(...)` inside a function is
/// recompiled on every call and reads as a magic string; the name is what says
/// which of several 64-hex-character things this is.
///
/// **Deliberately not shared with `deps.dart`'s sha256 pin pattern.** That one
/// is the same shape and a different fact: a content digest of a binary this
/// tool is about to download and run, where this is an identifier for a commit.
/// Unifying them would mean that relaxing the commit check — for a shorter form,
/// a new hash, an uppercase tolerance — silently relaxes the one guarding what
/// gets executed on the machine. Two facts that share a regex today will not
/// share one for the reasons they change.
final _fullCommitId = RegExp(r'^([0-9a-f]{40}|[0-9a-f]{64})$');

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
    // **The refusal this field was added for, which it did not have.**
    //
    // `buildNumberAssigned: false` says allocation failed and the number is a
    // placeholder — build-manifest.md introduced it saying in as many words
    // that "an upload must be able to refuse a placeholder". It was read,
    // written, and printed as UNASSIGNED, and then nothing refused on it: the
    // only guard anywhere was a shell `if` in one consuming repository's upload
    // script, so any other `--manifest` caller would have shipped build 0.
    //
    // A specified refusal that exists everywhere except in the code is the
    // worst version of this: the field's presence reads as the check being
    // handled. No override, deliberately — `--allow-dirty` exists because a
    // dirty tree still produces a real artifact, while an unnumbered one cannot
    // be told apart from any other unnumbered build by any store.
    if (!buildNumberAssigned) {
      throw ReleaseException(
        'build number $buildNumber is a placeholder — allocation failed when '
        'this was built, so nothing distinguishes it from any other unnumbered '
        'build. Rebuild with the allocator reachable.',
      );
    }

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

    crossCheck();
  }

  /// Compares what this manifest claims against what the artifact says about
  /// itself, and returns what was actually checked.
  ///
  /// **The digest cannot catch this class at all.** It proves the bytes are the
  /// ones the manifest was written for; it says nothing about whether the build
  /// honored the values the script passed it. An export step that rewrote
  /// `CFBundleVersion`, a Gradle override, a variable that evaluated empty —
  /// in each of those the manifest honestly describes the wrong artifact, and
  /// every flag in the upload is correct.
  ///
  /// Until now the check happened at the store: Play parses an uploaded bundle
  /// and reports its versionCode, and `play upload` compares afterwards. Right
  /// answer, learned after transferring the whole artifact.
  ///
  /// Returns a sentence naming what was compared, or what was not and why —
  /// never silence. A format with no reader is trusted, and the caller prints
  /// that it was, because "not checked" and "checked and fine" must not look
  /// the same.
  String crossCheck() {
    final BakedFacts? baked;
    try {
      baked = readBakedFacts(artifactPath, format);
    } on ReleaseException catch (e) {
      throw ReleaseException('$path: ${e.message}');
    }
    return describeCrossCheck(
      versionName: versionName,
      buildNumber: buildNumber,
      format: format,
      baked: baked,
    );
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
  // **A JSON integer, because that is what the schema says**, and the first
  // writer wrote a string — harmless to a reader that stringifies whatever it
  // finds, which is exactly how a spec and its only implementation drift apart
  // while every test passes. The second producer writes against the prose.
  //
  // Refused rather than coerced when it is not a number: both stores this
  // targets count in integers (Play's versionCode is one by definition), and a
  // value that is not one means the caller passed something else entirely.
  // Apple's CFBundleVersion does permit a dotted form; nothing here produces
  // one, and if something ever does this is the line that will say so rather
  // than a manifest that quietly changes type.
  final buildNumberValue = int.tryParse(buildNumber);
  if (buildNumberValue == null) {
    throw ReleaseException(
      'buildNumber must be an integer and is "$buildNumber". The schema says '
      'JSON integer, and a reader that stringifies whatever it finds would '
      'accept this and hand the next tool something it cannot count with.',
    );
  }
  // **40 for SHA-1, 64 for SHA-256, and both because git has two object
  // formats.** SHA-256 repositories have existed since git 2.29; a check that
  // only knew 40 would refuse a perfectly good commit id and insist, wrongly,
  // that it was the wrong length. That is the same defect as accepting a short
  // sha, from the other side: encoding "what our repositories happen to use" as
  // "what is correct".
  //
  // What is actually being enforced is *full* rather than abbreviated, because
  // a reader that resolves whatever it is given makes an abbreviation work
  // right up until something reads the file without a repository to resolve
  // against. Any length between the two is an abbreviation of one of them.
  //
  // **A regex rather than a decoder, and specifically never base64.** Decoding
  // reads like the cleaner idea, so here is why it is not. A git sha *is* valid
  // base64 — hex characters are a subset of the base64 alphabet and 40 is a
  // multiple of 4 — so `base64.decode` returns 30 bytes of noise and never
  // throws. It would accept every sha, accept plenty of non-shas, and look like
  // it was working. `hex.decode` is honest by comparison and says 20 bytes, but
  // it also accepts UPPERCASE, which git never emits and which would then fail
  // every string comparison against `git rev-parse` output — so it needs a
  // lowercase guard and a FormatException catch beside it. Three checks and two
  // throw sites to say what one pattern says: lowercase, hex only, full length.
  if (!_fullCommitId.hasMatch(gitSha)) {
    throw ReleaseException(
      'gitSha must be a full lowercase commit id — 40 hex characters for a '
      'sha1 repository, 64 for sha256 — and is "$gitSha" (${gitSha.length}). '
      'A reader normalizes whatever it is given, which is exactly what lets an '
      'abbreviated sha survive here and break a tool that does not.',
    );
  }

  final document = <String, dynamic>{
    'schema': supportedManifestSchema,
    'artifact': p.basename(artifactPath),
    'sha256': sha256.convert(artifact.readAsBytesSync()).toString(),
    'versionName': versionName,
    'buildNumber': buildNumberValue,
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

/// Compares what a manifest claims against what its artifact says, and returns
/// the sentence describing what was checked.
///
/// **Pure, and separate from the reading, because this is where the decision
/// is.** Getting bytes out of a zip needs a zip; deciding what a disagreement
/// means does not, and a test that has to build an `.aab` to assert on a
/// comparison is a test nobody writes the third case for.
///
/// A null [baked] means the format has no reader. That is a real answer and it
/// is returned rather than swallowed — "not checked" must not render the same
/// as "checked and fine".
///
/// A null field *within* [baked] means the artifact did not carry that one, and
/// is skipped rather than treated as a mismatch: absent is not disagreement.
String describeCrossCheck({
  required String versionName,
  required String buildNumber,
  required String? format,
  required BakedFacts? baked,
}) {
  if (baked == null) {
    return 'cross-check: no reader for ${format ?? 'this format'} — '
        'build number and version name taken on trust';
  }

  final mismatches = <String>[
    if (baked.buildNumber != null && baked.buildNumber != buildNumber)
      '  build number  manifest $buildNumber, artifact ${baked.buildNumber}',
    if (baked.versionName != null && baked.versionName != versionName)
      '  version name  manifest $versionName, artifact ${baked.versionName}',
  ];
  if (mismatches.isNotEmpty) {
    throw ReleaseException(
      'the artifact disagrees with the manifest that describes it, so this is '
      'not the build this manifest was written for:\n'
      '${mismatches.join('\n')}\n'
      '  read from     ${baked.source}\n'
      'dist/ is stale, or the build did not use the values it was given.',
    );
  }

  final checked = <String>[
    if (baked.buildNumber != null) 'build number',
    if (baked.versionName != null) 'version name',
  ];
  if (checked.isEmpty) {
    return 'cross-check: ${baked.source} carried neither value — taken on trust';
  }
  return 'cross-check: ${checked.join(' and ')} agree with ${baked.source}';
}
