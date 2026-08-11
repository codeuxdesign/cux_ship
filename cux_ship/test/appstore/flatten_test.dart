// SPDX-License-Identifier: Apache-2.0

// Flattening is the one thing in this package that rewrites a file the
// repository commits, so getting it wrong ships a corrupted screenshot that
// nobody notices until it is on a store page. The distinction that matters is
// between an alpha channel that carries nothing — which every screen capture
// has, and which can be dropped exactly — and one that carries real
// transparency, where dropping it would reveal whatever RGB sits underneath.
import 'dart:typed_data';

import 'package:cux_ship/src/appstore/flatten.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

/// A PNG with an alpha channel in which every pixel is opaque — what
/// `xcrun simctl io screenshot` and the Android emulator both produce.
Uint8List opaqueRgba({int width = 8, int height = 6}) {
  final image = img.Image(width: width, height: height, numChannels: 4);
  for (final pixel in image) {
    pixel.setRgba(pixel.x * 30 % 256, pixel.y * 40 % 256, 128, 255);
  }
  return img.encodePng(image);
}

Uint8List rgbNoAlpha({int width = 8, int height = 6}) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  for (final pixel in image) {
    pixel.setRgb(pixel.x * 30 % 256, pixel.y * 40 % 256, 128);
  }
  return img.encodePng(image);
}

/// Fully transparent black, which is the case where naively dropping the
/// channel turns a "blank" image into a solid black rectangle.
Uint8List transparentBlack({int width = 8, int height = 6}) {
  final image = img.Image(width: width, height: height, numChannels: 4);
  for (final pixel in image) {
    pixel.setRgba(0, 0, 0, 0);
  }
  return img.encodePng(image);
}

img.Image decode(Uint8List bytes) => img.decodePng(bytes)!;

void main() {
  group('flattenPng', () {
    test('an RGB image is left alone', () {
      final result = flattenPng(rgbNoAlpha());
      expect(result.outcome, FlattenOutcome.alreadyOpaque);
      expect(result.changed, isFalse);
      expect(result.bytes, isNull);
    });

    test('an opaque alpha channel is dropped', () {
      final result = flattenPng(opaqueRgba());
      expect(result.outcome, FlattenOutcome.droppedAlpha);
      expect(decode(result.bytes!).numChannels, 3);
    });

    test('dropping an opaque alpha channel changes no pixel', () {
      // The property that makes this safe to run over committed screenshots:
      // it is a re-encode, not an edit.
      final before = decode(opaqueRgba());
      final after = decode(flattenPng(opaqueRgba()).bytes!);

      expect(after.width, before.width);
      expect(after.height, before.height);
      for (final pixel in before) {
        final other = after.getPixel(pixel.x, pixel.y);
        expect(
          [other.r, other.g, other.b],
          [pixel.r, pixel.g, pixel.b],
          reason: 'pixel ${pixel.x},${pixel.y} moved',
        );
      }
    });

    test('real transparency is composited rather than discarded', () {
      // Discarding it would leave the underlying RGB — black here — and turn a
      // blank image into a solid black rectangle.
      final result = flattenPng(transparentBlack());
      expect(result.outcome, FlattenOutcome.compositedOntoBackground);

      final flat = decode(result.bytes!);
      expect(flat.numChannels, 3);
      final pixel = flat.getPixel(0, 0);
      expect([pixel.r, pixel.g, pixel.b], [255, 255, 255]);
    });

    test('the background colour is honoured', () {
      final result = flattenPng(transparentBlack(), background: 0xFF0000);
      final pixel = decode(result.bytes!).getPixel(3, 3);
      expect([pixel.r, pixel.g, pixel.b], [255, 0, 0]);
    });

    test('is idempotent', () {
      // The tool runs over a whole directory, most of which is usually already
      // flat, and re-running it must be free rather than lossy.
      final once = flattenPng(opaqueRgba()).bytes!;
      final twice = flattenPng(once);
      expect(twice.outcome, FlattenOutcome.alreadyOpaque);
      expect(twice.changed, isFalse);
    });

    test('a non-PNG is refused rather than silently skipped', () {
      expect(
        () => flattenPng(Uint8List.fromList([1, 2, 3, 4])),
        throwsA(isA<FlattenException>()),
      );
    });
  });
}
