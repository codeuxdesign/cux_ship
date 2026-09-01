// SPDX-License-Identifier: Apache-2.0

// Removes the alpha channel from store screenshots, and reduces them to 8 bits
// per channel, in place.
//
//   cux_ship screenshots flatten store/appstore/listings
//   cux_ship screenshots flatten --check store/appstore/listings
//
// A top-level subcommand rather than one under `appstore`, because both of
// those are operations on an image. Apple and Play are merely the stores that
// refuse the states they produce — Apple's "Images can't include alpha channels
// or transparencies", Play's "JPEG or 24-bit PNG (no alpha)".
//
// The decision this makes lives in flatten.dart and is tested there; this file
// is the file walking and the writing. Run it after capturing screenshots and
// before committing them.
//
// Deliberately a separate step from publishing: both upload paths *refuse* an
// alpha channel rather than stripping one, because the bytes a store receives
// have to be the bytes committed in the repository. So the fix belongs at
// capture time and the uploaders' checks stay strict.
import 'dart:io';

import 'package:args/args.dart';

import 'flatten.dart';

/// Exit code when --check finds work to do, so CI can gate on it.
const needsFlatteningExit = 2;

/// The arguments `screenshots flatten` accepts. Paths arrive as positionals.
ArgParser buildFlattenParser() => ArgParser()
  ..addFlag(
    'check',
    negatable: false,
    help:
        'Report what would change and exit $needsFlatteningExit if anything '
        'would, rather than rewriting. For CI.',
  );

/// Flattens every PNG under [args.rest], in place.
void runFlatten(ArgResults args) {
  final paths = args.rest;
  final check = args.flag('check');

  if (paths.isEmpty) {
    stderr.writeln('cux_ship screenshots flatten: nothing to do — pass a path');
    exit(1);
  }

  final files = <File>[];
  for (final path in paths) {
    final directory = Directory(path);
    if (directory.existsSync()) {
      files.addAll(
        directory
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.toLowerCase().endsWith('.png')),
      );
      continue;
    }
    final file = File(path);
    if (!file.existsSync()) {
      stderr.writeln(
        'cux_ship screenshots flatten: no such file or directory: $path',
      );
      exit(1);
    }
    files.add(file);
  }
  files.sort((a, b) => a.path.compareTo(b.path));

  var changed = 0;
  var unchanged = 0;
  for (final file in files) {
    final FlattenResult result;
    try {
      result = flattenPng(file.readAsBytesSync());
    } on FlattenException catch (e) {
      stderr.writeln(
        'cux_ship screenshots flatten: ${file.path}: ${e.message}',
      );
      exit(1);
    }

    if (!result.changed) {
      unchanged++;
      continue;
    }
    changed++;

    // Both said out loud, and both because a reader who is told only "flattened"
    // cannot tell which of the two refusals this file was under. Compositing is
    // the one outcome that changes pixels rather than just the encoding, and a
    // depth reduction is the one that fires on a file with no alpha channel at
    // all — where "flattened" on its own reads as a no-op that wrote anyway.
    final notes = <String>[
      if (result.outcome == FlattenOutcome.compositedOntoBackground)
        'had real transparency — composited onto white',
      if (result.reducedBitDepth) 'was 16 bits per channel — reduced to 8',
    ];
    final note = notes.isEmpty ? '' : ' (${notes.join('; ')})';
    if (check) {
      stdout.writeln('  would flatten ${file.path}$note');
      continue;
    }

    // Written beside the target and moved, so an interrupted run cannot leave
    // a half-written screenshot where a valid one was.
    final temp = File('${file.path}.tmp');
    temp.writeAsBytesSync(result.bytes!);
    temp.renameSync(file.path);
    stdout.writeln('  flattened ${file.path}$note');
  }

  stdout.writeln(
    '${files.length} PNG(s): $unchanged already 8-bit and opaque, '
    '$changed ${check ? "would be flattened" : "flattened"}',
  );
  if (check && changed > 0) {
    exit(needsFlatteningExit);
  }
}
