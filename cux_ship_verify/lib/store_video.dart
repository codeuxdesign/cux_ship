// SPDX-License-Identifier: Apache-2.0
//
// What a store preview video is, and what a store path has to check about one.
//
// **The same shape as store_image.dart, for the same reason and one more.** A
// screenshot Apple refuses costs a re-upload; a preview Apple refuses costs a
// round trip through an ingestion queue Apple documents as taking up to
// twenty-four hours, and the version cannot be submitted while it is in
// flight. So the four properties Apple validates after the upload —
// dimensions, duration, frame rate and codec — are read out of the file here,
// where the answer is instant and names which one is wrong.
//
// **Hand-rolled, because this package has no dependencies and that is the
// design.** It is the same trade store_image.dart made: what is needed is a
// dozen integers out of a header, and the alternative is a demuxer for a
// hundred formats in the lockfile of everyone who only wanted to know whether
// a release note is too long. An ISO base media file is a tree of
// length-prefixed boxes and the ones that matter are four levels down a
// documented path, so walking to them is arithmetic rather than decoding — no
// frame is ever touched.
//
// **Encoding and geometry only, and no rule about which device.** Which pixel
// sizes a `PreviewType` accepts is per slot and per store, exactly as it is
// for screenshots, so it stays with the caller in metadata.dart. What is here
// is what is true of a video whatever it is a video of.

/// Which container a header came out of.
///
/// Carried for the message rather than for a rule: Apple accepts `.mp4`,
/// `.m4v` and `.mov`, and the two brands are the same box tree underneath. A
/// reader who has just been told their codec is wrong is helped by being told
/// which kind of file it was read from.
enum VideoContainer { mp4, quickTime }

/// What a preview has to satisfy, read straight out of the container.
class VideoInfo {
  const VideoInfo({
    required this.width,
    required this.height,
    required this.duration,
    required this.frameRate,
    required this.codec,
    required this.container,
    required this.fileSize,
  });

  /// Display dimensions, after any rotation the track matrix asks for.
  ///
  /// **Display rather than encoded, because that is what Apple measures.** A
  /// portrait capture is routinely stored as a landscape frame with a
  /// ninety-degree rotation matrix beside it, and reading the encoded size
  /// would report 1920x886 for a file every player and the App Store agree is
  /// 886x1920. Reporting the encoded size would refuse a valid preview, which
  /// is the one direction an offline check must not fail in — it would send
  /// somebody re-encoding a file that was already right.
  final int width;
  final int height;

  /// Whole-movie duration, from `mvhd`.
  final Duration duration;

  /// Frames per second, derived from the video track's sample table.
  ///
  /// A real average rather than a declared value: an ISO base media file has
  /// no fps field at all, so this is the video track's sample count over its
  /// own duration. Variable frame rate therefore reports its mean, which is
  /// the honest answer — and is fine for the only question asked of it, since
  /// Apple's rule is a ceiling.
  final double frameRate;

  /// The video track's sample-description format, as the four characters the
  /// file carries: `avc1` for H.264, `apch` for ProRes 422 HQ, `hvc1` for the
  /// HEVC Apple does not take.
  final String codec;

  final VideoContainer container;

  /// Length of the whole file in bytes, which is also a limit Apple enforces
  /// and one nothing else here would carry.
  final int fileSize;
}

/// What a store accepts in a preview video, named after whose rules they are.
///
/// A class rather than four constants for the reason store_image.dart's rules
/// are: the second store to grow a preview uploader names whose rules it
/// publishes under and cannot omit a check it never had to write out.
class VideoRules {
  const VideoRules({
    required this.store,
    required this.codecs,
    required this.maxFrameRate,
    required this.minDuration,
    required this.maxDuration,
    required this.maxFileSize,
  });

  /// For the message: "the App Store", not this object's name.
  final String store;

  /// Accepted sample-description formats, mapped to how the store names them,
  /// so a refusal can say `hvc1 (HEVC)` and then say what is accepted in the
  /// words the specification page uses.
  final Map<String, String> codecs;

  final double maxFrameRate;
  final Duration minDuration;
  final Duration maxDuration;
  final int maxFileSize;
}

/// Apple's app preview rules, from the App Store Connect help's preview
/// specifications page.
///
/// https://developer.apple.com/help/app-store-connect/reference/app-preview-specifications/
///
/// **Apple is the authority, not this table** — the same caveat metadata.dart's
/// screenshot sizes carry. The four values here are the ones Apple states as
/// numbers and enforces at ingestion, so they are worth asserting; anything
/// softer is left to Apple.
///
/// ProRes 422 HQ is listed because Apple lists it, not because anything here
/// has uploaded one. `apch` is 422 HQ specifically — `apcn`, `apcs` and `apco`
/// are the lower 422 variants and `ap4h` is 4444, and Apple's page says "HQ
/// only", so naming the one is the accurate reading of it rather than an
/// oversight.
///
/// **The file size is the decimal reading of an ambiguous number, on purpose.**
/// Apple's page says "500MB" and states no units, so 500,000,000 and
/// 524,288,000 are both defensible. Decimal is taken for two reasons: Apple has
/// written user-facing storage sizes in decimal MB since 2009, so it is the
/// likelier reading; and the two errors are not symmetric. Refusing a file in
/// the 24 MB band between the readings costs a re-encode of something that
/// would probably have been accepted. Accepting one Apple then refuses costs a
/// day in the ingestion queue and a resubmission, which is the whole thing this
/// check exists to avoid. See [_megabytes], which has to use the same base or
/// the message compares two numbers in different units.
const appStorePreviewRules = VideoRules(
  store: 'the App Store',
  codecs: {'avc1': 'H.264', 'avc3': 'H.264', 'apch': 'ProRes 422 HQ'},
  maxFrameRate: 30,
  minDuration: Duration(seconds: 15),
  maxDuration: Duration(seconds: 30),
  maxFileSize: 500 * 1000 * 1000,
);

/// Why [video] is not something [rules] accepts, or null when it is.
///
/// One string naming one property, in the order Apple validates them, because
/// the whole value of asking offline is that the answer says *which* rule was
/// broken. Returning "invalid preview" would cost the same round trip it is
/// here to save.
String? videoEncodingProblem(VideoInfo video, VideoRules rules) {
  if (!rules.codecs.containsKey(video.codec)) {
    final accepted = <String>{...rules.codecs.values}.join(' or ');
    return 'is ${_codecName(video.codec)}; ${rules.store} takes $accepted';
  }
  if (video.duration < rules.minDuration ||
      video.duration > rules.maxDuration) {
    return 'runs ${_seconds(video.duration)}; ${rules.store} takes '
        '${_seconds(rules.minDuration)} to ${_seconds(rules.maxDuration)}, '
        'enforced at upload';
  }
  // Rounded before comparing, because the derived average of a nominal 30 fps
  // file lands a hair either side of 30 depending on how the last sample's
  // duration was written, and refusing 30.0004 would be this check inventing a
  // rule Apple does not have.
  if (double.parse(video.frameRate.toStringAsFixed(2)) > rules.maxFrameRate) {
    return 'is ${_rate(video.frameRate)} fps; ${rules.store} takes at most '
        '${_rate(rules.maxFrameRate)}';
  }
  if (video.fileSize > rules.maxFileSize) {
    // The band between the two readings of "500MB" is named rather than
    // silently refused, because in it this is *our* rule and not Apple's — and
    // somebody staring at a 505 MB file that Apple might well have taken
    // deserves to know that shrinking it is a precaution rather than a
    // requirement.
    // The same nominal number read as MiB: 500 decimal MB -> 500 MiB.
    final binary = rules.maxFileSize / 1000000 * 1024 * 1024;
    final ambiguous = video.fileSize <= binary;
    return 'is ${_megabytes(video.fileSize)}; ${rules.store} takes at most '
        '${_megabytes(rules.maxFileSize)}'
        '${ambiguous ? ' — Apple writes "500MB" without units, and this is '
                  'the decimal reading. Your file is under the other one, so it '
                  'may well be accepted; refusing it here is the cheap error and '
                  'a 24-hour rejection is not.' : ''}';
  }
  return null;
}

String _codecName(String codec) {
  const known = {
    'avc1': 'H.264',
    'avc3': 'H.264',
    'hvc1': 'HEVC',
    'hev1': 'HEVC',
    'apch': 'ProRes 422 HQ',
    'apcn': 'ProRes 422',
    'apcs': 'ProRes 422 LT',
    'apco': 'ProRes 422 Proxy',
    'ap4h': 'ProRes 4444',
    'vp09': 'VP9',
    'av01': 'AV1',
  };
  final name = known[codec];
  return name == null ? codec : '$codec ($name)';
}

String _seconds(Duration duration) {
  final value = duration.inMilliseconds / 1000;
  final text = value == value.roundToDouble()
      ? value.round().toString()
      : value.toStringAsFixed(1);
  return '${text}s';
}

String _rate(double rate) => rate == rate.roundToDouble()
    ? rate.round().toString()
    : rate.toStringAsFixed(2);

/// **Decimal, to match [appStorePreviewRules]'s reading of Apple's "500MB".**
/// The two have to share a base: dividing by 1024*1024 beside a decimal limit
/// renders the cap as "476.8 MB", so the message would refuse a file for
/// exceeding a number that is not the one anybody was told.
String _megabytes(num bytes) =>
    '${(bytes / (1000 * 1000)).toStringAsFixed(1)} MB';

/// Dimensions, duration, frame rate and codec of an MP4 or QuickTime file, or
/// null if [bytes] is neither.
///
/// Null means "not a container this can read", which is a fact about the file
/// and not a verdict on it — the caller turns it into a message naming the
/// path, exactly as it does for [readImageInfo]'s null.
VideoInfo? readVideoInfo(List<int> bytes) {
  final container = _container(bytes);
  if (container == null) {
    return null;
  }

  final moov = _findBox(bytes, 0, bytes.length, 'moov');
  if (moov == null) {
    // A file whose `moov` sits after the media data and was truncated, or one
    // that is not really an ISO base media file behind an `ftyp` this
    // recognised. Either way there is nothing to read.
    return null;
  }

  final movie = _readMvhd(bytes, moov);
  final track = _findVideoTrack(bytes, moov);
  if (movie == null || track == null) {
    return null;
  }

  return VideoInfo(
    width: track.width,
    height: track.height,
    duration: movie,
    frameRate: track.frameRate,
    codec: track.codec,
    container: container,
    fileSize: bytes.length,
  );
}

VideoContainer? _container(List<int> bytes) {
  // `ftyp` is required to be first in an MP4 and is present in every
  // QuickTime file current enough to matter, so the brand is at a fixed
  // offset: 4 length, 4 type, 4 major brand.
  if (bytes.length < 12 || !_isType(bytes, 4, 'ftyp')) {
    return null;
  }
  final brand = _type(bytes, 8);
  if (brand == 'qt  ') {
    return VideoContainer.quickTime;
  }
  // isom, iso2, mp41, mp42, M4V , avc1 and the rest of the MP4 family. Listed
  // by exclusion rather than enumerated: the brand registry is long and the
  // only distinction that changes anything downstream is QuickTime.
  return VideoContainer.mp4;
}

String _type(List<int> bytes, int offset) =>
    String.fromCharCodes(bytes.sublist(offset, offset + 4));

bool _isType(List<int> bytes, int offset, String type) =>
    offset + 4 <= bytes.length && _type(bytes, offset) == type;

int _be32(List<int> bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

int _be64(List<int> bytes, int offset) =>
    (_be32(bytes, offset) << 32) | _be32(bytes, offset + 4);

/// A box's payload range, as `(start, end)` offsets into the whole file.
typedef _Box = ({int start, int end});

/// The payload of the first [type] box directly inside `[from, to)`.
///
/// Direct children only. That is deliberate rather than a limitation: every
/// path walked here is a documented one — `moov/trak/mdia/minf/stbl/stsd` — and
/// a search that descended would find a `stsd` under some other track and
/// report it as this one's.
_Box? _findBox(List<int> bytes, int from, int to, String type) {
  var offset = from;
  while (offset + 8 <= to) {
    var size = _be32(bytes, offset);
    var header = 8;
    if (size == 1) {
      if (offset + 16 > to) {
        return null;
      }
      size = _be64(bytes, offset + 8);
      header = 16;
    } else if (size == 0) {
      // "To the end of the enclosing box", which is legal for the last one.
      size = to - offset;
    }
    if (size < header || offset + size > to) {
      // A length that runs past its parent means the tree is not what it
      // claims. Stop rather than guess: reading on from a bad offset produces
      // plausible integers out of arbitrary bytes, which is worse than
      // reporting nothing.
      return null;
    }
    if (_isType(bytes, offset + 4, type)) {
      return (start: offset + header, end: offset + size);
    }
    offset += size;
  }
  return null;
}

/// Every direct child of `[from, to)` with the given type.
List<_Box> _findBoxes(List<int> bytes, int from, int to, String type) {
  final found = <_Box>[];
  var offset = from;
  while (offset + 8 <= to) {
    var size = _be32(bytes, offset);
    var header = 8;
    if (size == 1) {
      if (offset + 16 > to) {
        return found;
      }
      size = _be64(bytes, offset + 8);
      header = 16;
    } else if (size == 0) {
      size = to - offset;
    }
    if (size < header || offset + size > to) {
      return found;
    }
    if (_isType(bytes, offset + 4, type)) {
      found.add((start: offset + header, end: offset + size));
    }
    offset += size;
  }
  return found;
}

/// The whole movie's duration, from `moov/mvhd`.
Duration? _readMvhd(List<int> bytes, _Box moov) {
  final mvhd = _findBox(bytes, moov.start, moov.end, 'mvhd');
  if (mvhd == null || mvhd.start + 4 > bytes.length) {
    return null;
  }
  final version = bytes[mvhd.start];
  // version + flags, then two timestamps whose width the version decides.
  final timescaleAt = mvhd.start + 4 + (version == 1 ? 16 : 8);
  final durationAt = timescaleAt + 4;
  final end = durationAt + (version == 1 ? 8 : 4);
  if (end > mvhd.end || end > bytes.length) {
    return null;
  }
  final timescale = _be32(bytes, timescaleAt);
  final duration = version == 1
      ? _be64(bytes, durationAt)
      : _be32(bytes, durationAt);
  if (timescale == 0) {
    return null;
  }
  return Duration(microseconds: (duration * 1000000 / timescale).round());
}

typedef _Track = ({int width, int height, double frameRate, String codec});

/// The first `trak` under [moov] whose handler is `vide`, read out.
///
/// The handler is checked rather than the track order because a file with an
/// audio track first is ordinary, and reading `trak[0]` would report a sound
/// track's zero dimensions as the video's.
_Track? _findVideoTrack(List<int> bytes, _Box moov) {
  for (final trak in _findBoxes(bytes, moov.start, moov.end, 'trak')) {
    final mdia = _findBox(bytes, trak.start, trak.end, 'mdia');
    if (mdia == null) {
      continue;
    }
    final hdlr = _findBox(bytes, mdia.start, mdia.end, 'hdlr');
    // version + flags (4), pre_defined (4), then the handler type.
    if (hdlr == null || !_isType(bytes, hdlr.start + 8, 'vide')) {
      continue;
    }

    final size = _readTkhd(bytes, trak);
    final codec = _readCodec(bytes, mdia);
    final rate = _readFrameRate(bytes, mdia);
    if (size == null || codec == null || rate == null) {
      return null;
    }
    return (
      width: size.width,
      height: size.height,
      frameRate: rate,
      codec: codec,
    );
  }
  return null;
}

/// Display width and height from `trak/tkhd`, rotated as its matrix says.
({int width, int height})? _readTkhd(List<int> bytes, _Box trak) {
  final tkhd = _findBox(bytes, trak.start, trak.end, 'tkhd');
  if (tkhd == null || tkhd.start + 4 > bytes.length) {
    return null;
  }
  final version = bytes[tkhd.start];
  // version + flags (4), two timestamps, track id (4), reserved (4), duration.
  final afterDuration =
      tkhd.start +
      4 +
      (version == 1 ? 8 + 8 : 4 + 4) +
      4 +
      4 +
      (version == 1 ? 8 : 4);
  // reserved (8), layer (2), alternate group (2), volume (2), reserved (2).
  final matrixAt = afterDuration + 16;
  final widthAt = matrixAt + 36;
  if (widthAt + 8 > tkhd.end || widthAt + 8 > bytes.length) {
    return null;
  }

  // 16.16 fixed point. The fractional half is discarded rather than rounded:
  // these are whole pixels in every file that has ever been a store preview,
  // and a size that is genuinely fractional is not a size any spec accepts.
  final width = _be32(bytes, widthAt) >> 16;
  final height = _be32(bytes, widthAt + 4) >> 16;

  // **The rotation matrix, which is the whole reason this is not two reads.**
  // The first three values are a, b, u; the next three c, d, v. A quarter turn
  // puts zero in a and d and non-zero in b and c, and the stored frame is then
  // the transpose of what anybody sees.
  final a = _be32(bytes, matrixAt);
  final b = _be32(bytes, matrixAt + 4);
  final c = _be32(bytes, matrixAt + 12);
  final d = _be32(bytes, matrixAt + 16);
  if (a == 0 && d == 0 && b != 0 && c != 0) {
    return (width: height, height: width);
  }
  return (width: width, height: height);
}

/// The four-character format of the first sample description under [mdia].
String? _readCodec(List<int> bytes, _Box mdia) {
  final minf = _findBox(bytes, mdia.start, mdia.end, 'minf');
  if (minf == null) {
    return null;
  }
  final stbl = _findBox(bytes, minf.start, minf.end, 'stbl');
  if (stbl == null) {
    return null;
  }
  final stsd = _findBox(bytes, stbl.start, stbl.end, 'stsd');
  // version + flags (4), entry count (4), then the first entry: size (4) and
  // the format that names the codec.
  if (stsd == null || stsd.start + 16 > bytes.length) {
    return null;
  }
  return _type(bytes, stsd.start + 12);
}

/// Frames per second, from the video track's time-to-sample table.
///
/// **There is no frame rate field to read**, which is the fact that decides
/// the shape of this: `stts` is a run-length list of `(count, delta)` pairs in
/// the media timescale, so the sample count over the media duration is the
/// only honest answer. Both halves come from `stts` rather than from `mdhd`,
/// so a file whose media duration includes an edit list or trailing silence
/// still reports the rate its frames were written at.
double? _readFrameRate(List<int> bytes, _Box mdia) {
  final mdhd = _findBox(bytes, mdia.start, mdia.end, 'mdhd');
  if (mdhd == null || mdhd.start + 4 > bytes.length) {
    return null;
  }
  final version = bytes[mdhd.start];
  final timescaleAt = mdhd.start + 4 + (version == 1 ? 16 : 8);
  if (timescaleAt + 4 > bytes.length) {
    return null;
  }
  final timescale = _be32(bytes, timescaleAt);
  if (timescale == 0) {
    return null;
  }

  final minf = _findBox(bytes, mdia.start, mdia.end, 'minf');
  final stbl = minf == null
      ? null
      : _findBox(bytes, minf.start, minf.end, 'stbl');
  final stts = stbl == null
      ? null
      : _findBox(bytes, stbl.start, stbl.end, 'stts');
  if (stts == null || stts.start + 8 > bytes.length) {
    return null;
  }
  final entries = _be32(bytes, stts.start + 4);
  var samples = 0;
  var ticks = 0;
  for (var i = 0; i < entries; i++) {
    final at = stts.start + 8 + i * 8;
    if (at + 8 > stts.end || at + 8 > bytes.length) {
      return null;
    }
    final count = _be32(bytes, at);
    final delta = _be32(bytes, at + 4);
    samples += count;
    ticks += count * delta;
  }
  if (samples == 0 || ticks == 0) {
    return null;
  }
  return samples / (ticks / timescale);
}
