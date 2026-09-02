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

/// What a store screenshot actually looks like to a compressor: broad flat
/// panels, hard edges between them, and one photographic region.
///
/// Small enough to stay a unit test and structured enough that the filters
/// disagree, which is the whole property under test.
Uint8List flatPanels({int width = 512, int height = 320}) {
  final image = img.Image(width: width, height: height, numChannels: 4);
  for (final pixel in image) {
    if (pixel.x < width ~/ 2) {
      // The chrome: one colour over a wide area, where predicting from a
      // neighbour buys nothing and costs a byte a pixel.
      pixel.setRgba(240, 238, 230, 255);
    } else {
      // The map: a gradient with noise, which is where a predictor earns its
      // keep.
      final shade = (pixel.x * 7 + pixel.y * 3) % 256;
      pixel.setRgba(shade, (shade * 2) % 256, 128 + (pixel.y % 64), 255);
    }
  }
  return img.encodePng(image);
}

/// A genuinely 16-bit PNG — `Format.uint16`, encoded and decoded, so its IHDR
/// really does say depth 16 rather than a stub claiming to.
///
/// This is what a macOS `--no-chrome` capture produces, and what made the
/// remedy for the alpha channel produce a set carrying the other refusal.
/// [numChannels] 3 is the case the old code returned "nothing to write" for.
Uint8List deepPng({int numChannels = 3, int width = 8, int height = 6}) {
  final image = img.Image(
    width: width,
    height: height,
    numChannels: numChannels,
    format: img.Format.uint16,
  );
  for (final pixel in image) {
    // 65535 and 256 are chosen to tell rescaling from truncation: rescaled
    // they are 255 and 1, and truncated to the low byte they would be 255
    // and 0.
    pixel.setRgba(65535, 256, 32768, 65535);
  }
  return img.encodePng(image);
}

/// Greyscale with an alpha channel — PNG colour type 4, which decodes to two
/// channels. `readImageInfo` counts colour type 4 as alpha and both stores'
/// messages name this command as the remedy, so a gate written as
/// `numChannels < 4` called opaque exactly a state the checker refuses.
Uint8List greyAlpha({int alpha = 255, int width = 8, int height = 6}) {
  final image = img.Image(width: width, height: height, numChannels: 2);
  for (final pixel in image) {
    pixel
      ..r = pixel.x * 30 % 256
      ..a = alpha;
  }
  return img.encodePng(image);
}

img.Image decode(Uint8List bytes) => img.decodePng(bytes)!;

/// The bit depth as the file itself carries it, out of the IHDR rather than
/// out of the decoder — the byte a store reads.
int depthOf(Uint8List png) => png[24];

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

    test('a greyscale-with-alpha PNG has its channel dropped too', () {
      // PNG colour type 4 decodes to *two* channels, so the question has to be
      // whether the image has an alpha channel, not whether it has four — the
      // check refuses this file and points here, and "already opaque" would
      // send the user in a circle.
      final bytes = greyAlpha();
      expect(bytes[25], 4, reason: 'the fixture must really be colour type 4');

      final result = flattenPng(bytes);
      expect(result.outcome, FlattenOutcome.droppedAlpha);
      final after = decode(result.bytes!);
      expect(after.hasAlpha, isFalse);
      // The luminance survives — replicated into RGB, not zeroed or shuffled.
      expect(after.getPixel(3, 0).r, 90);
    });

    test('transparent greyscale is composited rather than discarded', () {
      final result = flattenPng(greyAlpha(alpha: 0));
      expect(result.outcome, FlattenOutcome.compositedOntoBackground);
      final pixel = decode(result.bytes!).getPixel(0, 0);
      expect([pixel.r, pixel.g, pixel.b], [255, 255, 255]);
    });

    test('never encodes larger than the default filter would', () {
      // **A screenshot is not a photograph, and the default filter assumes it
      // is.** `encodePng` defaults to `PngFilter.paeth`, which predicts well
      // across a photographic gradient and badly across the flat panels a store
      // screenshot is mostly made of. Measured on a 2880x1800 macOS capture:
      // paeth 3,953,681 bytes, no filtering 2,685,629 — 32% smaller, and
      // smaller than the RGBA original.
      //
      // Asserted as "no worse than paeth" rather than "equals none", because
      // which filter wins is a property of the picture: a listing of dense
      // photographs may still choose paeth, and that is the right answer when
      // it does.
      //
      // Red before the change, which is the point: the old code called
      // `encodePng` with its defaults, so this compared a value against itself.
      final flattened = flattenPng(flatPanels()).bytes!;
      final asPaeth = img.encodePng(
        decode(flattened).convert(numChannels: 3),
        filter: img.PngFilter.paeth,
      );
      expect(flattened.length, lessThanOrEqualTo(asPaeth.length));
      expect(
        flattened.length,
        lessThan(asPaeth.length),
        reason: 'on this picture some other filter is strictly smaller',
      );
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

    test('a 16-bit PNG with no alpha channel is still re-encoded', () {
      // The case that used to return "nothing to write" and leave a 48-bit
      // file in place: `numChannels < 4` returned before anything looked at
      // the depth, so `verify` refused a file the remedy said it had fixed.
      expect(depthOf(deepPng()), 16, reason: 'the fixture must be the defect');

      final result = flattenPng(deepPng());
      expect(result.outcome, FlattenOutcome.alreadyOpaque);
      expect(result.reducedBitDepth, isTrue);
      expect(result.changed, isTrue);
      expect(depthOf(result.bytes!), 8);
    });

    test('a 16-bit RGBA PNG loses both the channel and the depth', () {
      // `convert(numChannels: 3)` preserves the source format, so this path
      // did rewrite the file and handed back a 48-bit RGB PNG — the alpha
      // removed and the depth the stores also refuse left where it was.
      final result = flattenPng(deepPng(numChannels: 4));

      expect(result.outcome, FlattenOutcome.droppedAlpha);
      expect(result.reducedBitDepth, isTrue);
      expect(depthOf(result.bytes!), 8);
      expect(decode(result.bytes!).numChannels, 3);
    });

    test('a 16-bit image with real transparency reports both', () {
      // The compositing path builds an 8-bit canvas, so the depth was already
      // being fixed here by accident — and reported as nothing, which is the
      // half that was wrong. A `--check` run that named only the transparency
      // would leave a reader thinking the depth survived.
      final deep = img.Image(
        width: 8,
        height: 6,
        numChannels: 4,
        format: img.Format.uint16,
      );
      for (final pixel in deep) {
        pixel.setRgba(0, 0, 0, 0);
      }
      final result = flattenPng(img.encodePng(deep));

      expect(result.outcome, FlattenOutcome.compositedOntoBackground);
      expect(result.reducedBitDepth, isTrue);
      expect(depthOf(result.bytes!), 8);
    });

    test('reducing the depth rescales rather than truncates', () {
      // The difference between a re-encode and a corrupted image. Channel
      // values 65535 and 256 rescale to 255 and 1; taking the low byte of
      // each would give 255 and 0, which passes a "depth is 8 now" assertion
      // while having thrown the picture away.
      final pixel = decode(flattenPng(deepPng()).bytes!).getPixel(0, 0);

      expect([pixel.r, pixel.g, pixel.b], [255, 1, 128]);
    });

    test('an 8-bit image is not widened', () {
      final result = flattenPng(rgbNoAlpha());

      expect(result.reducedBitDepth, isFalse);
      expect(result.changed, isFalse);
    });

    test('a 4-bit greyscale PNG is left alone', () {
      // The other half of `> 8` rather than `!= 8`, and a real 4-bit file
      // rather than an argument about one: below 8 bits is a greyscale or
      // palettised PNG whose samples no store has been seen to refuse, and
      // rewriting a committed screenshot to fix nothing is not free.
      final shallow = img.encodePng(
        img.Image(
          width: 8,
          height: 6,
          numChannels: 1,
          format: img.Format.uint4,
        ),
      );
      expect(depthOf(shallow), 4, reason: 'the fixture must really be 4-bit');

      final result = flattenPng(shallow);

      expect(result.reducedBitDepth, isFalse);
      expect(result.changed, isFalse);
    });

    test('is idempotent over the depth too', () {
      final once = flattenPng(deepPng()).bytes!;
      final twice = flattenPng(once);

      expect(twice.reducedBitDepth, isFalse);
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
