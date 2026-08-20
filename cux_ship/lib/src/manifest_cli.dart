// SPDX-License-Identifier: Apache-2.0
//
// Writes the sidecar manifest a build produces, so that the file every upload
// is named by has one producer instead of one per repository.
//
//   cux_ship manifest write --artifact dist/app-1.1.0-53.aab \
//     --platform android --format aab \
//     --version-name 1.1.0 --build-number 53 \
//     --git-sha "$SHA" --no-dirty
//
// **Why a command rather than a documented shape.** Two repositories write this
// file today and both do it with a shell heredoc, which means the schema exists
// twice in prose and zero times in code. One of them omits a field the other
// carries; neither notices, because nothing reads a manifest until an upload
// weeks later, and the failure mode is publishing an artifact described by the
// wrong numbers rather than a refusal. A writer beside the reader makes the
// round trip a test instead of a convention.
//
// What it will not do is derive anything about the tree. `--git-sha` and the
// dirty flag are inputs, always, because this runs *after* the build and a
// commit that moved in between would be invisible here and wrong in the file.
// The build knows both at the moment it starts; it passes them down.
import 'dart:io';

import 'package:args/args.dart';
import 'package:crypto/crypto.dart';

import 'build_manifest.dart';
import 'release.dart';
import 'version.dart';

/// The arguments `manifest write` accepts.
ArgParser buildManifestWriteParser() => ArgParser()
  ..addOption(
    'artifact',
    help:
        'The file being described. The manifest is written beside it as '
        '<artifact>.manifest.json, and its digest is computed from these '
        'bytes — so run this after signing, never before.',
    valueHelp: 'path',
  )
  ..addOption(
    'out',
    valueHelp: 'path',
    help:
        'Write the manifest here instead of <artifact>.manifest.json. Must be '
        "in the artifact's own directory — a build with one artifact per "
        'directory wants a fixed manifest.json its uploader can name without '
        'globbing.',
  )
  ..addOption(
    'derived-from',
    valueHelp: 'parent manifest',
    help:
        "The manifest of the artifact this was repackaged from — a tarball's, "
        'when building a .deb from it. Supplies the build facts (git sha, '
        'dirty, version name, build number) so they are inherited rather than '
        'retyped, and builds the derivedFrom chain including the parent\'s own. '
        'Explicit flags still win. The parent artifact is digest-checked when '
        'it sits beside its manifest.',
  )
  ..addOption('platform', help: 'android, ios, macos, web, linux, windows.')
  ..addOption('version-name', help: 'The marketing version, e.g. 1.1.0.')
  ..addOption('build-number', help: 'The allocated build number.')
  ..addOption(
    'git-sha',
    help:
        'The full 40-character commit the artifact was built from. Not '
        'derived here: this runs after the build, so a tree that moved in '
        'between would be invisible.',
    valueHelp: 'sha',
  )
  ..addFlag(
    'dirty',
    // No default, and the run function requires it to have been parsed. A
    // default of false would let a build script that forgot the flag record
    // every dirty build as clean — silence meaning two things, which is the
    // one shape of defect this whole file exists to remove.
    help:
        'The working tree held uncommitted or untracked files. Required '
        'explicitly, as --dirty or --no-dirty: there is no default, because a '
        'forgotten flag would quietly certify a dirty build as clean.',
  )
  ..addOption(
    'format',
    help: 'The container kind — aab, apk, ipa, pkg, msix, deb.',
  )
  ..addOption(
    'flavor',
    help:
        'Which of several artifacts from one commit this is. A filename is '
        'not a discriminator when six flavors share a version and a number.',
  )
  ..addOption(
    'git-tag',
    help: 'The release tag, when the build was made at one.',
  )
  ..addOption(
    'built-at',
    help:
        'ISO 8601 UTC. Defaults to now, which is close enough unless the '
        'build script knows when it actually started, in which case pass it.',
    valueHelp: 'timestamp',
  )
  ..addFlag(
    'build-number-assigned',
    defaultsTo: true,
    help:
        'Pass --no-build-number-assigned when allocation failed and the '
        'number is a placeholder, so an upload can refuse it rather than '
        'ship under a number that means nothing.',
  )
  ..addMultiOption(
    'toolchain',
    help: 'key=value, repeatable. e.g. --toolchain flutter=3.47.0',
    valueHelp: 'key=value',
  )
  ..addMultiOption(
    'packaging',
    help:
        'key=value, repeatable. The tree the packaging files came from, when '
        'this artifact was repackaged from another.',
    valueHelp: 'key=value',
  )
  ..addMultiOption(
    'x',
    help:
        'key=value, repeatable. Repo-local fields, namespaced under "x" where '
        'no shared tool reads them and no future schema field can collide.',
    valueHelp: 'key=value',
  );

/// Writes one manifest, or exits non-zero saying which argument is missing.
void runManifestWrite(ArgResults args) {
  // **The parent supplies what a repackaged artifact inherits.**
  //
  // build-manifest.md's derivation rules say two things a producer would
  // otherwise implement itself, once each, differently: the parent's build
  // facts are hoisted to top level *always*, and the chain is
  // `[parent] + parent's own derivedFrom` so multi-step chains survive. Both
  // are done here, because "the repackager writes" is the shape that gets one
  // producer's version of it subtly wrong.
  //
  // Explicit flags still win, so a repackager that genuinely knows better can
  // say so — but it has to say so.
  final parentPath = args.option('derived-from');
  final BuildManifest? parent;
  if (parentPath == null) {
    parent = null;
  } else {
    parent = BuildManifest.read(parentPath);
    // The digest of the bytes actually consumed is the whole value of a
    // derivation record. Checked here when the artifact is beside its manifest
    // — which is the normal case after downloading both — so a truncated or
    // skewed fetch is a loud failure rather than a chain that records a lie.
    if (File(parent.artifactPath).existsSync()) {
      final actual = sha256
          .convert(File(parent.artifactPath).readAsBytesSync())
          .toString();
      if (actual != parent.sha256Digest) {
        throw ReleaseException(
          'the parent artifact does not match the manifest that describes it, '
          'so this would record a derivation from bytes nobody has:\n'
          '  ${parent.artifactPath}\n'
          '  manifest  ${parent.sha256Digest}\n'
          '  actual    $actual',
        );
      }
    }
  }

  String need(String option, [String? inherited]) {
    final value = args.option(option) ?? inherited;
    if (value == null || value.isEmpty) {
      throw ReleaseException(
        'manifest write needs --$option'
        '${parent == null ? '' : ', and --derived-from did not supply one'}',
      );
    }
    return value;
  }

  if (!args.wasParsed('dirty') && parent == null) {
    throw ReleaseException(
      'manifest write needs --dirty or --no-dirty. It has no default on '
      'purpose: a build script that forgot it would record every dirty build '
      'as clean, and nothing downstream could tell.',
    );
  }

  final path = writeBuildManifest(
    artifactPath: need('artifact'),
    outPath: args.option('out'),
    versionName: need('version-name', parent?.versionName),
    buildNumber: need('build-number', parent?.buildNumber),
    gitSha: need('git-sha', parent?.gitSha),
    dirty: args.wasParsed('dirty') ? args.flag('dirty') : parent!.dirty,
    platform: need('platform'),
    producerName: 'cux_ship',
    producerVersion: cuxShipVersion,
    builtAt:
        args.option('built-at') ?? DateTime.now().toUtc().toIso8601String(),
    format: args.option('format'),
    flavor: args.option('flavor'),
    gitTag: args.option('git-tag'),
    buildNumberAssigned: args.wasParsed('build-number-assigned')
        ? args.flag('build-number-assigned')
        : parent?.buildNumberAssigned ?? true,
    toolchain: _pairs(args, 'toolchain'),
    packaging: _pairs(args, 'packaging'),
    extra: _pairs(args, 'x') ?? const {},
    // `[parent] + parent's own derivedFrom`, so a chain of repackagings
    // stays flat and nearest-first however many steps it took.
    derivedFrom: parent == null
        ? const []
        : [
            {
              'artifact': parent.artifact,
              'sha256': parent.sha256Digest,
              'builtAt': ?parent.builtAt,
              'producer': ?parent.producer?['name'],
            },
            ...parent.derivedFrom,
          ],
  );

  // Effective, not intended. A build log that says "wrote the manifest" is
  // worth nothing three weeks later, when the question is which commit and
  // which bytes it described — so say them, and say them from the file that
  // was written rather than from the arguments that were passed.
  final written = BuildManifest.read(path);
  stdout.writeln(
    'wrote $path\n'
    '  ${written.platform}'
    '${written.format == null ? '' : '/${written.format}'}'
    '${written.flavor == null ? '' : ' ${written.flavor}'}'
    '  ${written.versionName} (${written.buildNumber})'
    '${written.buildNumberAssigned ? '' : ' UNASSIGNED'}'
    '  ${written.gitSha.substring(0, 7)}${written.dirty ? '-dirty' : ''}'
    '  sha256:${written.sha256Digest.substring(0, 12)}',
  );
}

/// Parses repeated `key=value` options, or null when none were given.
///
/// Null rather than an empty map because the writer omits an absent block
/// entirely, and `"toolchain": {}` would claim we looked and found nothing.
Map<String, String>? _pairs(ArgResults args, String option) {
  final values = args.multiOption(option);
  if (values.isEmpty) {
    return null;
  }
  final pairs = <String, String>{};
  for (final value in values) {
    final split = value.indexOf('=');
    if (split <= 0) {
      throw ReleaseException('--$option takes key=value and got "$value"');
    }
    pairs[value.substring(0, split)] = value.substring(split + 1);
  }
  return pairs;
}
