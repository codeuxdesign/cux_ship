// SPDX-License-Identifier: Apache-2.0
//
// What the Play uploader refuses about an image before it opens an edit.
//
// **Driven through the binary because the check is not reachable any other
// way.** `_loadImages` and the `_loadMetadata` above it are private to
// `src/play/cli.dart`, and `_fail` calls `exit()`, which an in-process test
// cannot observe. The same reasoning as exit_codes_test.dart, and the snapshot
// makes it cheap.
//
// **And these run against a repository with no `.cux-ship.yaml` on purpose.**
// `runPlay` also calls `checkPlayTree`, which checks exactly this — but only
// when the repository declares listing requirements, because that is what the
// call is guarded on. A fixture with a `play:` block would pass whether or not
// the uploader checks anything itself, and the project most likely to have no
// block is the one least likely to have run `cux_ship verify` first.
import 'dart:io';

import 'package:test/test.dart';

import 'cli_snapshot.dart';

/// A bare repository carrying a Play listing tree at `store/play`.
///
/// Two phone screenshots because the loader wants at least two, and no config
/// file at all — see the header.
Directory _repo({
  int colourType = 2, // truecolour, no alpha
  int depth = 8,
  bool trns = false,
}) {
  final dir = Directory.systemTemp.createTempSync('cux_ship_play_images');
  addTearDown(() => dir.deleteSync(recursive: true));
  // ProjectContext looks for the repository root via git.
  Process.runSync('git', ['init', '-q'], workingDirectory: dir.path);

  final shots = Directory(
    '${dir.path}/store/play/listings/en-US/images/'
    'phoneScreenshots',
  )..createSync(recursive: true);
  for (final name in ['00.png', '01.png']) {
    File('${shots.path}/$name').writeAsBytesSync(
      _png(1080, 2400, colourType: colourType, depth: depth, trns: trns),
    );
  }
  return dir;
}

/// A PNG header, hand-built so the fixture is the genuinely broken state — a
/// real colour type 6, a real tRNS chunk, a real bit depth of 16 — rather than
/// a stub standing in for one.
List<int> _png(
  int width,
  int height, {
  required int colourType,
  required int depth,
  required bool trns,
}) {
  List<int> be32(int value) => [
    (value >> 24) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 8) & 0xFF,
    value & 0xFF,
  ];
  return <int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // signature
    ...be32(13), ...'IHDR'.codeUnits,
    ...be32(width), ...be32(height),
    depth, colourType, 0, 0, 0,
    ...be32(0), // CRC, unchecked
    if (trns) ...[...be32(2), ...'tRNS'.codeUnits, 0, 0, ...be32(0)],
    ...be32(0), ...'IEND'.codeUnits, ...be32(0),
  ];
}

ProcessResult _upload(Directory repo) =>
    Process.runSync(Platform.resolvedExecutable, [
      '--enable-asserts',
      cliSnapshot,
      'play',
      'upload',
      '--package',
      'design.codeux.consumer',
      '--metadata',
      'store/play',
    ], workingDirectory: repo.path);

void main() {
  test('an alpha channel is refused before any credential is read', () {
    final result = _upload(_repo(colourType: 6));

    expect(result.exitCode, 1, reason: '${result.stdout}${result.stderr}');
    expect('${result.stderr}', contains('alpha channel'));
    expect('${result.stderr}', contains('Play refuses transparency'));
    expect(
      '${result.stderr}',
      contains('screenshots flatten'),
      reason: 'the remedy this package already ships',
    );
    // Proof it stopped here rather than later: the unattended-release gate is
    // the next thing that would refuse this run, and it has not been reached.
    expect('${result.stderr}', isNot(contains('unattended')));
  });

  test('a tRNS chunk counts as transparency too', () {
    // Colour type 2 says opaque and the chunk says otherwise. The case a check
    // written off the colour type alone lets through.
    final result = _upload(_repo(trns: true));

    expect(result.exitCode, 1, reason: '${result.stdout}${result.stderr}');
    expect('${result.stderr}', contains('alpha channel'));
  });

  test('16 bits per channel is refused', () {
    final result = _upload(_repo(depth: 16));

    expect(result.exitCode, 1, reason: '${result.stdout}${result.stderr}');
    expect('${result.stderr}', contains('16 bits per channel'));
    expect('${result.stderr}', contains('24-bit PNG'));
  });

  test('a 24-bit opaque PNG gets past the listing', () {
    // The control. Without it every case above would also pass against a
    // loader that refused every image it was handed.
    final result = _upload(_repo());

    expect('${result.stderr}', isNot(contains('alpha channel')));
    expect('${result.stderr}', isNot(contains('bits per channel')));
    expect(
      '${result.stderr}',
      contains('unattended'),
      reason:
          'the listing loaded, and the run stopped at the confirmation gate '
          'beyond it — which is as far as a test with no terminal can go',
    );
  });
}
