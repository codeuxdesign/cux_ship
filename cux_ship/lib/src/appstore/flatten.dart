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
      img.encodePng(image.convert(numChannels: 3)),
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
    img.encodePng(flat),
  );
}
