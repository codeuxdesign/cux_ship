// SPDX-License-Identifier: Apache-2.0

// Re-encodes a PNG without its alpha channel and at 8 bits per channel.
//
// In lib/ rather than beside the CLI because it decides something: whether an
// alpha channel is dead weight or is carrying real transparency, and therefore
// whether dropping it is lossless or would reveal whatever RGB sits underneath.
// Getting that wrong corrupts a store screenshot in a way nobody notices until
// it is public, which is the same reason lib/metadata.dart is tested.
//
// Why this exists at all: both stores reject any transparency, and **every
// screen capture has an alpha channel** whether or not it uses one. `sips`
// cannot remove it while staying PNG — it writes RGBA whatever flags it is
// given — so the alternatives were a lossy JPEG conversion or a Homebrew
// install of ImageMagick. Verified equivalent to `magick mogrify -alpha off`:
// pixel for pixel identical on a real capture.
//
// **Bit depth arrived later, and the reason it had to is worth keeping.** The
// checks in cux_ship_verify refuse more than 8 bits per channel on both store
// paths, and this — the remedy those messages name — preserved the depth it
// was handed. A macOS `--no-chrome` capture writes 16, so the documented fix
// for one refusal produced a set carrying the other one. A remedy that cannot
// reach the state the checker refuses is not a remedy.
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// What flattening did, or would do, **to the alpha channel**.
///
/// Deliberately about the alpha channel alone, rather than about the file. Bit
/// depth is the other thing a store refuses and it is independent — a capture
/// can carry either, or both — so it is [FlattenResult.reducedBitDepth] beside
/// this rather than more values in here. An enum answering two questions at
/// once has to invent a precedence between them, and the caller then cannot
/// see the answer that lost.
enum FlattenOutcome {
  /// Already had no alpha channel.
  ///
  /// Not "nothing to write": a 16-bit PNG with no alpha channel lands here and
  /// is still re-encoded. [FlattenResult.changed] is the question about the
  /// file.
  alreadyOpaque,

  /// Had an alpha channel in which every pixel was opaque, so dropping it
  /// changes no visible pixel.
  droppedAlpha,

  /// Had genuinely transparent pixels, so the image was composited onto a
  /// background rather than having the channel discarded.
  compositedOntoBackground,
}

class FlattenResult {
  const FlattenResult(this.outcome, this.bytes, {this.reducedBitDepth = false});

  final FlattenOutcome outcome;

  /// Whether the image was re-encoded from more than 8 bits per channel down
  /// to 8 — a 48-bit PNG where both stores ask for 24.
  ///
  /// Independent of [outcome], and true on any of its values: a 16-bit capture
  /// may or may not also carry an alpha channel.
  final bool reducedBitDepth;

  /// The re-encoded PNG, or null when there was nothing to write.
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

/// Returns [bytes] re-encoded with no alpha channel and at 8 bits per channel.
FlattenResult flattenPng(
  Uint8List bytes, {
  int background = defaultBackground,
}) {
  final image = img.decodePng(bytes);
  if (image == null) {
    throw FlattenException('not a readable PNG');
  }

  // **More than 8 bits per channel is the second thing a store refuses, and
  // this used to preserve it.** A 16-bit PNG is 48-bit where Play asks for
  // 24-bit and Apple refuses one at ingestion; `convert(numChannels: 3)` keeps
  // the source format, so the one path here that did rewrite handed back a
  // 48-bit file, and the path for an image with no alpha channel returned
  // "nothing to write" and left it alone entirely. Both were reachable from
  // the same capture: a macOS `--no-chrome` fallback writes depth 16.
  //
  // `> 8` rather than `!= 8`, matching cux_ship_verify: fewer than 8 bits is a
  // greyscale or palettised PNG whose palette entries are 8-bit, no store has
  // been seen to refuse one, and widening it here would rewrite a committed
  // screenshot to fix nothing.
  final tooDeep = image.bitsPerChannel > 8;

  if (image.numChannels < 4) {
    if (!tooDeep) {
      return const FlattenResult(FlattenOutcome.alreadyOpaque, null);
    }
    // Depth alone. Nothing to say about the alpha channel, and every channel
    // rescaled rather than truncated — `convert` maps 65535 to 255 and 256
    // to 1, which is the difference between a re-encode and a corrupted image.
    return FlattenResult(
      FlattenOutcome.alreadyOpaque,
      _smallestPng(image.convert(format: img.Format.uint8)),
      reducedBitDepth: true,
    );
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
      // `format:` alongside `numChannels:`, and the whole of this fix is that
      // word. `convert(numChannels: 3)` on its own preserves the source
      // format, so a 16-bit RGBA capture came out of here as a 48-bit RGB PNG
      // — the alpha channel removed and the depth the store also refuses left
      // exactly where it was found.
      _smallestPng(image.convert(numChannels: 3, format: img.Format.uint8)),
      reducedBitDepth: tooDeep,
    );
  }

  // 8 bits per channel by default, so compositing a 16-bit source already
  // lands at the depth the stores want. Reported all the same: the file did
  // change depth, and a `--check` run that did not say so would leave the
  // reader thinking only the transparency moved.
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
    reducedBitDepth: tooDeep,
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
