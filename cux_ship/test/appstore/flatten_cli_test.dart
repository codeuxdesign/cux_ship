// SPDX-License-Identifier: Apache-2.0
//
// What `screenshots flatten --check` gates CI on, driven through the binary.
//
// **The depth case is the one that needs this rather than a unit test.** A
// 16-bit PNG with no alpha channel used to reach `--check` as "nothing to
// write", so the run printed "already opaque" and exited 0 — a green CI step
// standing over a set the stores refuse. `flattenPng` now returns bytes for
// it, and what a caller acts on is the exit code and the line above it, which
// only the real command produces: `runFlatten` calls `exit()`.
import 'dart:io';
import 'dart:typed_data';

import 'package:cux_ship/src/appstore/flatten_cli.dart'
    show needsFlatteningExit;
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

import '../cli_snapshot.dart';

/// A directory holding one PNG, written from real encoder output so the file
/// on disk is the genuine state rather than a stub.
Directory _treeWith(Uint8List png) {
  final dir = Directory.systemTemp.createTempSync('cux_ship_flatten_cli');
  addTearDown(() => dir.deleteSync(recursive: true));
  File('${dir.path}/01-ride.png').writeAsBytesSync(png);
  return dir;
}

Uint8List _png({
  required int numChannels,
  required img.Format format,
  int alpha = 65535,
}) {
  final image = img.Image(
    width: 8,
    height: 6,
    numChannels: numChannels,
    format: format,
  );
  for (final pixel in image) {
    pixel.setRgba(65535, 256, 32768, alpha);
  }
  return img.encodePng(image);
}

ProcessResult _check(Directory dir) =>
    Process.runSync(Platform.resolvedExecutable, [
      '--enable-asserts',
      cliSnapshot,
      'screenshots',
      'flatten',
      '--check',
      dir.path,
    ]);

void main() {
  test('a 16-bit PNG with no alpha channel fails --check', () {
    final dir = _treeWith(_png(numChannels: 3, format: img.Format.uint16));

    final result = _check(dir);

    expect(
      result.exitCode,
      needsFlatteningExit,
      reason: '${result.stdout}${result.stderr}',
    );
    expect('${result.stdout}', contains('would flatten'));
    expect(
      '${result.stdout}',
      contains('16 bits per channel'),
      reason: 'a file with no alpha channel needs to say why it is listed',
    );
    // --check reports and does not rewrite, which is what makes it safe to run
    // over a committed tree in CI.
    expect(
      img
          .decodePng(File('${dir.path}/01-ride.png').readAsBytesSync())!
          .bitsPerChannel,
      16,
    );
  });

  test('an 8-bit opaque PNG passes --check', () {
    // The control: without it the case above would also pass against a command
    // that failed every file it was handed.
    final dir = _treeWith(_png(numChannels: 3, format: img.Format.uint8));

    final result = _check(dir);

    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect('${result.stdout}', contains('already 8-bit and opaque'));
  });

  test('flattening writes the reduced file back', () {
    final dir = _treeWith(_png(numChannels: 4, format: img.Format.uint16));

    final result = Process.runSync(Platform.resolvedExecutable, [
      '--enable-asserts',
      cliSnapshot,
      'screenshots',
      'flatten',
      dir.path,
    ]);

    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    final written = img.decodePng(
      File('${dir.path}/01-ride.png').readAsBytesSync(),
    )!;
    expect(written.bitsPerChannel, 8);
    expect(written.numChannels, 3);
    // Re-running is free rather than lossy, over the depth as well.
    expect(_check(dir).exitCode, 0);
  });
}
