// SPDX-License-Identifier: Apache-2.0

// Re-encodes a PNG without its alpha channel.
//
// In lib/ rather than beside the CLI because it decides something: whether an
// alpha channel is dead weight or is carrying real transparency, and therefore
// whether dropping it is lossless or would reveal whatever RGB sits underneath.
// Getting that wrong corrupts a store screenshot in a way nobody notices until
// it is public, which is the same reason lib/metadata.dart is tested.
//
// Why this exists at all: Apple rejects any transparency, and **every screen
// capture has an alpha channel** whether or not it uses one. `sips` cannot
// remove it while staying PNG — it writes RGBA whatever flags it is given — so
// the alternatives were a lossy JPEG conversion or a Homebrew install of
// ImageMagick. Verified equivalent to `magick mogrify -alpha off`: pixel for
// pixel identical on a real capture.
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// What flattening did, or would do.
enum FlattenOutcome {
  /// Already had no alpha channel. Nothing to write.
  alreadyOpaque,

  /// Had an alpha channel in which every pixel was opaque, so dropping it
  /// changes no visible pixel.
  droppedAlpha,

  /// Had genuinely transparent pixels, so the image was composited onto a
  /// background rather than having the channel discarded.
  compositedOntoBackground,
}

class FlattenResult {
  const FlattenResult(this.outcome, this.bytes);

  final FlattenOutcome outcome;

  /// The re-encoded PNG, or null when [outcome] is
  /// [FlattenOutcome.alreadyOpaque] and there is nothing to write.
  final Uint8List? bytes;

  bool get changed => bytes != null;
}

/// Thrown for input that is not a PNG this can work with.
class FlattenException implements Exception {
  FlattenException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// White, because this app's UI is light and white is the background any
/// transparency in a capture of it was meant to sit on.
///
/// A parameter rather than a constant so the choice is visible at the call
/// site: compositing onto the wrong colour is the one way this can produce a
/// wrong image rather than an identical one.
const defaultBackground = 0xFFFFFF;

/// Returns [bytes] re-encoded with no alpha channel.
FlattenResult flattenPng(
  Uint8List bytes, {
  int background = defaultBackground,
}) {
  final image = img.decodePng(bytes);
  if (image == null) {
    throw FlattenException('not a readable PNG');
  }

  if (image.numChannels < 4) {
    return const FlattenResult(FlattenOutcome.alreadyOpaque, null);
  }

  // Whether the channel actually carries anything. A capture is normally fully
  // opaque and the channel is dead weight, in which case dropping it is exact.
  final opaque = image.maxChannelValue;
  var transparent = false;
  for (final pixel in image) {
    if (pixel.a < opaque) {
      transparent = true;
      break;
    }
  }

  if (!transparent) {
    return FlattenResult(
      FlattenOutcome.droppedAlpha,
      _smallestPng(image.convert(numChannels: 3)),
    );
  }

  final flat = img.Image(
    width: image.width,
    height: image.height,
    numChannels: 3,
  );
  img.fill(
    flat,
    color: img.ColorRgb8(
      (background >> 16) & 0xFF,
      (background >> 8) & 0xFF,
      background & 0xFF,
    ),
  );
  img.compositeImage(flat, image);
  return FlattenResult(
    FlattenOutcome.compositedOntoBackground,
    _smallestPng(flat),
  );
}

/// The same image, encoded with whichever PNG filter comes out smallest.
///
/// **Measured rather than assumed, because the usual assumption is wrong for
/// screenshots.** `encodePng` defaults to `PngFilter.paeth`, which is the right
/// guess for photographs and a poor one for a screen capture: a store
/// screenshot is mostly flat panels of a single colour with one photographic
/// region, and a per-scanline predictor that helps the photograph hurts
/// everything around it. On a 2880x1800 macOS capture of this app, paeth
/// produced 3,953,681 bytes and no filtering at all produced 2,685,629 — 32%
/// smaller, and smaller than the RGBA original the flatten was handed.
///
/// So the filter is chosen by trying them rather than by picking one. Which one
/// wins is a property of the picture, not of the format: a listing of dense
/// photographs may well still choose paeth, and this returns that when it does.
///
/// **The compression level is left alone deliberately.** The same measurement
/// puts level 9 within 0.8% of level 6 on every filter, so raising it buys
/// noise and costs time on files that can be tens of megabytes.
///
/// The cost is one encode per filter, which is seconds for a handful of store
/// screenshots and is paid once per upload rather than per run.
Uint8List _smallestPng(img.Image image) {
  Uint8List? best;
  for (final filter in img.PngFilter.values) {
    final encoded = img.encodePng(image, filter: filter);
    if (best == null || encoded.length < best.length) {
      best = encoded;
    }
  }
  return best!;
}
