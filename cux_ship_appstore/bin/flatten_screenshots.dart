// Removes the alpha channel from store screenshots, in place.
//
//   dart run bin/flatten_screenshots.dart ../../store/appstore/listings
//   dart run bin/flatten_screenshots.dart --check ../../store/appstore/listings
//
// Driven by tool/flatten-screenshots.sh, which is the command to run.
//
// The decision this makes lives in lib/flatten.dart and is tested there; this
// file is the file walking and the writing. Run it after capturing screenshots
// and before committing them.
//
// Deliberately a separate step from publishing: tool/asc_upload *refuses* an
// alpha channel rather than stripping one, because the bytes Apple receives
// have to be the bytes committed in the repository. So the fix belongs at
// capture time and the uploader's check stays strict.
import 'dart:io';

import 'package:cux_ship_appstore/flatten.dart';

/// Exit code when --check finds work to do, so CI can gate on it.
const _needsFlatteningExit = 2;

void main(List<String> argv) {
  final paths = <String>[];
  var check = false;
  for (final arg in argv) {
    switch (arg) {
      case '--check':
        check = true;
      case '-h' || '--help':
        stdout.writeln(
          'usage: flatten_screenshots [--check] <file-or-directory>...\n'
          '\n'
          '  Re-encodes PNGs without their alpha channel, in place.\n'
          '  --check reports what would change and exits '
          '$_needsFlatteningExit if anything would.',
        );
        return;
      default:
        if (arg.startsWith('-')) {
          stderr.writeln('flatten_screenshots: unknown option $arg');
          exit(1);
        }
        paths.add(arg);
    }
  }

  if (paths.isEmpty) {
    stderr.writeln('flatten_screenshots: nothing to do — pass a path');
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
      stderr.writeln('flatten_screenshots: no such file or directory: $path');
      exit(1);
    }
    files.add(file);
  }
  files.sort((a, b) => a.path.compareTo(b.path));

  var changed = 0;
  var opaque = 0;
  for (final file in files) {
    final FlattenResult result;
    try {
      result = flattenPng(file.readAsBytesSync());
    } on FlattenException catch (e) {
      stderr.writeln('flatten_screenshots: ${file.path}: ${e.message}');
      exit(1);
    }

    if (!result.changed) {
      opaque++;
      continue;
    }
    changed++;

    // Said out loud, because compositing is the one outcome that changes
    // pixels rather than just the encoding.
    final note = result.outcome == FlattenOutcome.compositedOntoBackground
        ? ' (had real transparency — composited onto white)'
        : '';
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
    '${files.length} PNG(s): $opaque already opaque, '
    '$changed ${check ? "would be flattened" : "flattened"}',
  );
  if (check && changed > 0) {
    exit(_needsFlatteningExit);
  }
}
