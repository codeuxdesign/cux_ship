// SPDX-License-Identifier: Apache-2.0
//
// What a listing image is, and what every store path has to check about one.
//
// **A file of its own because one of two callers forgot.** `readImageInfo` has
// computed `hasAlpha` since the App Store tree was first checked, and the Play
// tree called the same function and used only `width` and `height` — so a Play
// listing whose screenshots carried an alpha channel passed every offline check
// and was refused by Play during ingestion, on a property this package had
// already measured and thrown away. That is not a missing capability. It is a
// capability enforced at one of the two places that needed it.
//
// So the rules live beside the parser rather than at the call sites. A third
// store path gets [imageEncodingProblem] by naming whose rules it publishes
// under, and cannot omit a check it never had to write out. The two that exist
// today read the same way, which is the point: `metadata.dart` passes
// [appStoreImageRules] and `play_metadata.dart` passes [playImageRules], and
// neither spells out what alpha or bit depth mean.
//
// **Encoding only.** Dimensions stay with the caller: they are per slot, per
// device and per store, and there are dozens of them. What is here is what is
// true of an image whatever it is a picture of.

/// Which container a header came out of.
///
/// Carried because one of the rules below applies to a PNG and not to a JPEG,
/// and because a check that cannot tell them apart cannot say so. See
/// `docs/design/store-image-rules.md`.
enum ImageFormat { png, jpeg }

/// What a screenshot has to satisfy, read straight out of the file header.
class ImageInfo {
  const ImageInfo({
    required this.width,
    required this.height,
    required this.hasAlpha,
    required this.bitDepth,
    required this.format,
  });

  final int width;
  final int height;
  final bool hasAlpha;

  /// Bits per **channel**, which is what PNG's IHDR and JPEG's frame header
  /// both carry — 8 in the 24-bit RGB PNG Play asks for by name, and 16 in the
  /// 48-bit one a macOS capture can produce.
  ///
  /// Per channel rather than per pixel deliberately, because the stores state
  /// it the other way round — "24-bit PNG", "32-bit PNG" — and converting at
  /// the call site would mean knowing the channel count, which the header of a
  /// palettised PNG does not give directly. The messages do the arithmetic in
  /// prose instead.
  ///
  /// Read for a JPEG too, and *not* checked for one — see
  /// [imageEncodingProblem]. Reported rather than suppressed because the field
  /// is what the file says, and a parser that returned 8 for a 12-bit JPEG
  /// would be lying to whatever asks next.
  final int bitDepth;

  final ImageFormat format;
}

int _be16(List<int> bytes, int offset) =>
    (bytes[offset] << 8) | bytes[offset + 1];

int _be32(List<int> bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

/// Dimensions, transparency and bit depth of a PNG or JPEG, or null if [bytes]
/// is neither.
///
/// Hand-rolled rather than a dependency: this reads a handful of integers out
/// of a header, and `package:image` is a decoder for a dozen formats — which
/// this package, with no dependencies at all, cannot have. The checks it
/// enables are worth having because both stores validate images *after* they
/// have been uploaded, one at a time.
ImageInfo? readImageInfo(List<int> bytes) {
  // PNG: IHDR is required to be the first chunk, so everything needed sits at
  // a fixed offset — 8 signature, 4 length, 4 type, width, height, bit depth,
  // colour type.
  if (bytes.length >= 26 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    final colourType = bytes[25];
    // 4 is greyscale+alpha and 6 is RGBA. A tRNS chunk makes types 0 and 2
    // transparent too, so it counts as alpha even though the colour type
    // alone does not say so.
    final hasAlphaChannel = colourType == 4 || colourType == 6;
    return ImageInfo(
      width: _be32(bytes, 16),
      height: _be32(bytes, 20),
      hasAlpha: hasAlphaChannel || _hasTrnsChunk(bytes),
      bitDepth: bytes[24],
      format: ImageFormat.png,
    );
  }

  // JPEG: walk the marker segments to the start-of-frame, the only one that
  // carries the dimensions. JPEG has no alpha channel at all.
  if (bytes.length >= 4 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
    var i = 2;
    while (i + 9 < bytes.length) {
      if (bytes[i] != 0xFF) {
        i++;
        continue;
      }
      final marker = bytes[i + 1];
      // Padding, and the standalone markers that carry no length field.
      if (marker == 0xFF ||
          marker == 0x01 ||
          (marker >= 0xD0 && marker <= 0xD9)) {
        i += 2;
        continue;
      }
      // Every SOFn except the three that are not frame headers at all: DHT
      // (C4), JPG (C8) and DAC (CC).
      final isFrameHeader =
          marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (isFrameHeader) {
        return ImageInfo(
          width: _be16(bytes, i + 7),
          height: _be16(bytes, i + 5),
          hasAlpha: false,
          // The frame header's sample precision, which sits between the
          // segment length and the height — the same byte the dimensions are
          // read relative to, so this needs no extra bounds check. 8 for the
          // baseline SOF0 every capture and export writes; 12 is legal under
          // the extended sequential and progressive frames (SOF1, SOF2 and
          // their arithmetic and hierarchical variants), and 2 to 16 under
          // the lossless ones.
          bitDepth: bytes[i + 4],
          format: ImageFormat.jpeg,
        );
      }
      final length = _be16(bytes, i + 2);
      // A segment shorter than its own length field means the file is corrupt;
      // stop rather than loop forever on it.
      if (length < 2) {
        return null;
      }
      i += 2 + length;
    }
  }
  return null;
}

/// Whether a PNG carries a tRNS chunk, which makes a palette or truecolour
/// image transparent without changing its colour type.
///
/// Walks the chunk list rather than scanning for the bytes anywhere in the
/// file, because "tRNS" can occur inside compressed image data by chance.
bool _hasTrnsChunk(List<int> bytes) {
  var offset = 8;
  while (offset + 8 <= bytes.length) {
    final length = _be32(bytes, offset);
    if (length < 0) {
      return false;
    }
    final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
    if (type == 'tRNS') {
      return true;
    }
    if (type == 'IDAT' || type == 'IEND') {
      // tRNS is required to appear before the image data, so there is no point
      // walking the rest of a multi-megabyte file.
      return false;
    }
    offset += 12 + length;
  }
  return false;
}

/// What one store accepts in the *encoding* of a listing image.
///
/// **The quoted rules are fields rather than prose baked into the messages**,
/// because the two kinds of rule here must not read alike. Play publishes a
/// format string per slot and this package repeats it; Apple publishes nothing
/// about bit depth and the check is this package's, held to the evidence bar
/// the rest of this repository uses. A reader who cannot tell those apart
/// cannot argue with the second one, and the second one is the one worth being
/// able to argue with.
class StoreImageRules {
  const StoreImageRules({
    required this.store,
    required this.alphaRule,
    required this.depthRule,
    this.allowsAlpha = false,
  });

  /// Who does the refusing, named in every message. "Refused" on its own sends
  /// a reader to the wrong documentation, and these two stores disagree: Play
  /// wants an alpha channel in exactly the slot Apple has no equivalent of.
  final String store;

  /// The store's own words about transparency, quoted, so a reader can go and
  /// check the claim instead of taking this package's word for it.
  final String alphaRule;

  /// The same for bit depth — or, where the store publishes none, this package
  /// saying so and saying what the check is standing on instead.
  final String depthRule;

  /// True only for Play's app icon, the one slot in either store that *asks*
  /// for an alpha channel.
  final bool allowsAlpha;
}

/// Apple, for every screenshot.
///
/// **The two rules here have different provenance and the strings say which.**
/// The alpha rule is Apple's, from the screenshot specifications. The depth
/// rule is not: Apple publishes format, dimensions and transparency for
/// screenshots, and no bit depth at all. It is checked anyway because a 16-bit
/// PNG is refused at ingestion — a consuming project's macOS capture fallback
/// writes depth 16, the flatten preserves it, and Apple refuses the set after
/// the upload.
///
/// That is deliberately the same evidence bar the aspect-ratio rule fails and
/// is left unchecked for in `play_metadata.dart`: a real set that a store
/// actually refused, rather than a sentence somebody read.
const appStoreImageRules = StoreImageRules(
  store: 'Apple',
  alphaRule: '"Images can\'t include alpha channels or transparencies"',
  depthRule:
      'Apple publishes no bit depth for screenshots, and refuses a 16-bit PNG '
      'at ingestion — so this one is this tool\'s, from a set Apple refused',
);

/// Play, for screenshots, the feature graphic and the TV banner — every slot
/// this package checks but the icon. (Play's Android XR slot says only "PNG or
/// JPEG"; nothing here uploads to it.)
const playImageRules = StoreImageRules(
  store: 'Play',
  alphaRule: '"JPEG or 24-bit PNG (no alpha)"',
  depthRule: '"JPEG or 24-bit PNG (no alpha)", which is 8 bits per channel',
);

/// Play's app icon, the exception in both directions: it is the one slot that
/// asks for an alpha channel, and it is still 8 bits per channel.
const playIconImageRules = StoreImageRules(
  store: 'Play',
  alphaRule: '"32-bit PNG (with alpha)"',
  depthRule: '"32-bit PNG (with alpha)", which is 8 bits per channel',
  allowsAlpha: true,
);

/// What [rules] refuse about [image]'s encoding, as a sentence to follow the
/// file's name, or null when nothing does.
///
/// Returned rather than thrown because the two callers report differently —
/// the App Store loader throws on the first problem, the Play checker collects
/// them — and a check that picked one could only be used by that one.
String? imageEncodingProblem(ImageInfo image, StoreImageRules rules) {
  if (image.hasAlpha && !rules.allowsAlpha) {
    return 'has an alpha channel; ${rules.store} refuses transparency — '
        '${rules.alphaRule}.\n'
        '  Remove it, and change nothing else about the image:\n'
        '    cux_ship screenshots flatten <path>\n'
        '  `sips` cannot do this while staying PNG — it writes RGBA whatever '
        'flags it\n'
        '  is given, so a round trip through it changes nothing.';
  }

  // **`> 8` rather than `!= 8`, and the difference is whether this is checking
  // a rule or inventing one.** Play asks for eight bits per channel by name —
  // "24-bit PNG" — and Apple, publishing no depth at all, has been observed
  // refusing sixteen at ingestion. Fewer than eight is
  // a greyscale or palettised PNG, whose palette entries are eight bits each —
  // so "24-bit" is arguably what it already is, no store has been seen to
  // refuse one, and failing it would be this package enforcing a rule with no
  // failure under it. That is the mistake the aspect-ratio note in
  // play_metadata.dart exists to refuse to make.
  //
  // **PNG only, and for the same reason.** Every justification under this
  // check is PNG's: Play states a depth for PNG and none for JPEG — "24-bit"
  // in "JPEG or 24-bit PNG (no alpha)" modifies the PNG, not the JPEG beside
  // it — the set Apple was observed refusing was a PNG, and `screenshots
  // flatten` decodes PNG and nothing else. Applied to a JPEG this quoted Play
  // for a rule Play does not state, offered a PNG refusal as evidence about a
  // JPEG, and named a remedy that throws (the CLI walks `.png`, so it would
  // skip the file, exit 0, and leave verify still refusing it) — a loop, and
  // the same shape as the greyscale-with-alpha gate found in review.
  //
  // A >8-bit JPEG is legal and essentially unproducible: baseline SOF0 is
  // 8-bit by definition, 12 needs an extended sequential or progressive frame,
  // and reading one needs the 12-bit decoder entry points, which Blink and
  // everything else on libjpeg's 8-bit API do not call. So it is a rule with
  // no observed failure and no working remedy. Measured and argued in
  // docs/design/store-image-rules.md.
  if (image.format == ImageFormat.png && image.bitDepth > 8) {
    return 'is ${image.bitDepth} bits per channel; ${rules.store} takes 8 — '
        '${rules.depthRule}.\n'
        '  Reduce it, and change nothing else about the image:\n'
        '    cux_ship screenshots flatten <path>\n'
        '  It rescales rather than truncating, so the picture survives. A '
        'macOS\n'
        '  `--no-chrome` capture is the usual source of a 16-bit screenshot.';
  }
  return null;
}
