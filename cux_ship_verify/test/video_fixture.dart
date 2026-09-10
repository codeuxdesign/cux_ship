// SPDX-License-Identifier: Apache-2.0
//
// An MP4 with exactly the integers a preview check reads, and nothing else.
//
// **Built rather than committed.** A real 30-second 886x1920 H.264 file is
// tens of megabytes, and one per rule is not a test suite. What the checks
// read is a dozen integers out of a box tree, so the tree is written out here
// with those integers in it — which also lets each rule be broken *on its
// own*, with everything else valid, a thing a committed fixture cannot do
// without a dozen more committed fixtures.
//
// Its own file because two suites need it: store_video_test.dart asks what the
// parser reads out of a container, metadata_test.dart asks what the tree
// refuses. A second hand-written box tree is a second one that can drift into
// describing a file the first does not.
import 'dart:typed_data';

List<int> _be32(int value) => [
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
];

/// A box: length, four-character type, payload.
List<int> _box(String type, List<int> payload) => [
  ..._be32(payload.length + 8),
  ...type.codeUnits,
  ...payload,
];

/// The identity display matrix, and the quarter turn beside it.
///
/// **The rotated one is not decoration.** A portrait capture is routinely
/// stored as a landscape frame with this matrix beside it, so a check that
/// read `tkhd` and stopped would report a valid 886x1920 preview as 1920x886
/// and refuse it — sending somebody to re-encode a file that was already
/// right.
const _identityMatrix = [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000];
const _quarterTurnMatrix = [
  0,
  0x00010000,
  0,
  -0x00010000 & 0xFFFFFFFF,
  0,
  0,
  0,
  0,
  0x40000000,
];

/// An MP4 carrying exactly the integers a preview check reads.
///
/// [width] and [height] are what `tkhd` stores. With [rotated] they are also
/// transposed by the matrix, so a caller writes the *stored* frame and expects
/// the *displayed* one back — which is the direction the trap runs in.
Uint8List mp4({
  int width = 886,
  int height = 1920,
  double frameRate = 30,
  double seconds = 20,
  String codec = 'avc1',
  bool rotated = false,
  bool soundTrackFirst = false,
}) {
  const timescale = 600;
  final duration = (seconds * timescale).round();
  final frames = (seconds * frameRate).round();
  // stts holds one run: `frames` samples, each this many ticks long. The
  // rate the parser derives is samples over their own duration, so this is
  // what makes [frameRate] observable at all.
  final delta = duration ~/ frames;

  final tkhd = _box('tkhd', [
    ...[0, 0, 0, 3], // version 0, flags: enabled | in movie
    ..._be32(0), ..._be32(0), // creation, modification
    ..._be32(1), // track id
    ..._be32(0), // reserved
    ..._be32(duration),
    ...List<int>.filled(8, 0), // reserved
    ...[0, 0], // layer
    ...[0, 0], // alternate group
    ...[0, 0], // volume
    ...[0, 0], // reserved
    ...[
      for (final value in rotated ? _quarterTurnMatrix : _identityMatrix) ...[
        ..._be32(value),
      ],
    ],
    ..._be32(width << 16), // 16.16 fixed point
    ..._be32(height << 16),
  ]);

  final stsd = _box('stsd', [
    ...[0, 0, 0, 0], // version, flags
    ..._be32(1), // one entry
    // The entry: its own length, then the format that names the codec. The
    // rest of a visual sample entry is not read, so it is not written.
    ..._be32(16),
    ...codec.codeUnits,
    ...List<int>.filled(8, 0),
  ]);

  final stts = _box('stts', [
    ...[0, 0, 0, 0], // version, flags
    ..._be32(1), // one run
    ..._be32(frames),
    ..._be32(delta),
  ]);

  final mdia = _box('mdia', [
    ..._box('mdhd', [
      ...[0, 0, 0, 0], // version 0, flags
      ..._be32(0), ..._be32(0), // creation, modification
      ..._be32(timescale),
      ..._be32(duration),
      ...[0, 0], // language
      ...[0, 0], // quality
    ]),
    ..._box('hdlr', [
      ...[0, 0, 0, 0], // version, flags
      ..._be32(0), // pre-defined
      ...'vide'.codeUnits,
      ...List<int>.filled(12, 0), // reserved
    ]),
    ..._box('minf', [
      ..._box('stbl', [...stsd, ...stts]),
    ]),
  ]);

  // **A sound track carries the semantics the branch selects on**, which is
  // the whole reason it is written out rather than mentioned: it is a `trak`
  // with a `soun` handler, zero `tkhd` dimensions and no `stsd` video format —
  // so a parser that took `trak[0]` reports 0x0 and no codec, which is exactly
  // what the handler check exists to prevent.
  final soundTrack = _box('trak', [
    ..._box('tkhd', [
      ...[0, 0, 0, 3],
      ..._be32(0), ..._be32(0),
      ..._be32(2), // track id
      ..._be32(0),
      ..._be32(duration),
      ...List<int>.filled(8, 0),
      ...[0, 0], ...[0, 0], ...[1, 0], ...[0, 0], // layer, group, volume
      ...[
        for (final value in _identityMatrix) ...[..._be32(value)],
      ],
      ..._be32(0), // no width
      ..._be32(0), // no height
    ]),
    ..._box('mdia', [
      ..._box('mdhd', [
        ...[0, 0, 0, 0],
        ..._be32(0),
        ..._be32(0),
        ..._be32(44100),
        ..._be32(0),
        ...[0, 0],
        ...[0, 0],
      ]),
      ..._box('hdlr', [
        ...[0, 0, 0, 0],
        ..._be32(0),
        ...'soun'.codeUnits,
        ...List<int>.filled(12, 0),
      ]),
    ]),
  ]);

  final moov = _box('moov', [
    ..._box('mvhd', [
      ...[0, 0, 0, 0], // version 0, flags
      ..._be32(0), ..._be32(0), // creation, modification
      ..._be32(timescale),
      ..._be32(duration),
      ...List<int>.filled(80, 0), // rate, volume, matrix, pre-defined, next id
    ]),
    if (soundTrackFirst) ...[...soundTrack],
    ..._box('trak', [...tkhd, ...mdia]),
  ]);

  final ftyp = _box('ftyp', [
    ...'isom'.codeUnits,
    ..._be32(512),
    ...'isomiso2avc1mp41'.codeUnits,
  ]);

  // No `mdat`: not one byte of sample data is read, so a fixture that carried
  // some would only be asserting that it is skipped — which the box lengths
  // already say.
  return Uint8List.fromList([...ftyp, ...moov]);
}
