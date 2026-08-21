// SPDX-License-Identifier: Apache-2.0
//
// Reading a build's own values back out of it, and deciding what a
// disagreement means.
//
// The protobuf here is built rather than checked in. A real `.aab` is 69 MB and
// its manifest is a 14 KB blob of somebody's app; either would make these cases
// unreadable, and a fixture nobody can read is a fixture nobody extends. The
// builder below emits exactly the shape aapt2 does — verified against
// `protoc --decode_raw` and against a real signed bundle, which reported
// versionCode 65 and versionName 1.1.0 through this same walk.
import 'dart:convert';
import 'dart:typed_data';

import 'package:cux_ship/src/baked_facts.dart';
import 'package:cux_ship/src/build_manifest.dart';
import 'package:cux_ship/src/release.dart' show ReleaseException;
import 'package:test/test.dart';

/// A protobuf varint.
List<int> _varint(int value) {
  final out = <int>[];
  var v = value;
  while (v >= 0x80) {
    out.add((v & 0x7f) | 0x80);
    v >>= 7;
  }
  return out..add(v);
}

/// One length-delimited field.
List<int> _bytes(int number, List<int> payload) => [
  ..._varint(number << 3 | 2),
  ..._varint(payload.length),
  ...payload,
];

/// One varint field, so the walk is exercised on something it must skip.
List<int> _int(int number, int value) => [
  ..._varint(number << 3),
  ..._varint(value),
];

List<int> _string(int number, String value) =>
    _bytes(number, utf8.encode(value));

const _ns = 'http://schemas.android.com/apk/res/android';

/// An `XmlAttribute`: namespace_uri 1, name 2, value 3.
List<int> _attribute(String? namespace, String name, String value) =>
    _bytes(4, [
      if (namespace != null) ..._string(1, namespace),
      ..._string(2, name),
      ..._string(3, value),
      // A resource id, which the walk must step over without understanding.
      ..._int(5, 16843291),
    ]);

/// An `XmlNode` wrapping an `XmlElement` named `manifest`.
Uint8List _manifestProto(List<List<int>> attributes) => Uint8List.fromList(
  _bytes(1, [..._string(3, 'manifest'), for (final a in attributes) ...a]),
);

BakedFacts _baked({String? versionName, String? buildNumber}) => BakedFacts(
  versionName: versionName,
  buildNumber: buildNumber,
  source: 'base/manifest/AndroidManifest.xml',
);

void main() {
  group('the proto walk', () {
    test('reads the attributes an upload is named by', () {
      final proto = _manifestProto([
        _attribute(null, 'package', 'design.codeux.howitwent'),
        _attribute(_ns, 'versionCode', '65'),
        _attribute(_ns, 'versionName', '1.1.0'),
        _attribute(_ns, 'compileSdkVersion', '36'),
      ]);

      expect(
        readProtoManifestAttributes(proto, {'versionCode', 'versionName'}),
        {'versionCode': '65', 'versionName': '1.1.0'},
      );
    });

    test(
      'an attribute with no namespace is read, because package has none',
      () {
        final proto = _manifestProto([
          _attribute(null, 'package', 'design.codeux.howitwent'),
        ]);

        expect(readProtoManifestAttributes(proto, {'package'}), {
          'package': 'design.codeux.howitwent',
        });
      },
    );

    test('a foreign namespace is not mistaken for the android one', () {
      // Same attribute name, different vocabulary. Matching on name alone would
      // read somebody else's value and call it the build number.
      final proto = _manifestProto([
        _attribute('http://example.invalid/ns', 'versionCode', '999'),
      ]);

      expect(readProtoManifestAttributes(proto, {'versionCode'}), isEmpty);
    });

    test('a name that is not there comes back absent, not empty', () {
      final proto = _manifestProto([_attribute(_ns, 'versionCode', '65')]);

      expect(
        readProtoManifestAttributes(proto, {'versionName'}),
        isEmpty,
        reason:
            'fabricating an empty string would compare unequal and read '
            'as a mismatch rather than as a missing field',
      );
    });

    test('truncated bytes are a FormatException, not a wrong answer', () {
      final full = _manifestProto([_attribute(_ns, 'versionCode', '65')]);
      final truncated = Uint8List.sublistView(full, 0, full.length - 4);

      expect(
        () => readProtoManifestAttributes(truncated, {'versionCode'}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('the binary XML walk', () {
    // An `.apk` carries a chunked format with a string pool that every name and
    // string value indexes into — structurally unlike the `.aab`'s protobuf, so
    // the fixture is built too rather than shared. Verified against a real
    // profile `.apk` and `aapt2 dump xmltree`, which agreed on versionCode 1
    // and versionName "1.1.0-profile".

    List<int> u16(int v) => [v & 0xff, (v >> 8) & 0xff];
    List<int> u32(int v) => [
      v & 0xff,
      (v >> 8) & 0xff,
      (v >> 16) & 0xff,
      (v >> 24) & 0xff,
    ];

    /// A string pool, in either of the two encodings the format allows.
    ///
    /// **Both exist in the wild and they share no layout.** A UTF-8 pool
    /// stores two lengths per string — the UTF-16 code-unit count and then the
    /// byte count — while a UTF-16 pool stores one, counted in 16-bit units,
    /// with a wider continuation bit (`0x8000` on a uint16, against `0x80` on a
    /// byte). Which one an apk carries is decided by the toolchain that built
    /// it, so a reader that handles one handles roughly half of Android.
    List<int> pool(List<String> items, {bool asUtf8 = true}) {
      final blob = <int>[];
      final offsets = <int>[];
      for (final item in items) {
        offsets.add(blob.length);
        if (asUtf8) {
          final bytes = utf8.encode(item);
          blob
            // The UTF-16 length first, then the byte length. They differ for
            // anything outside ASCII, which is what makes reading the first one
            // a bug that ASCII fixtures cannot see.
            ..add(item.length)
            ..add(bytes.length)
            ..addAll(bytes)
            ..add(0);
        } else {
          final units = item.codeUnits;
          blob
            ..addAll(u16(units.length))
            ..addAll(units.expand(u16))
            ..addAll(u16(0));
        }
      }
      const header = 28;
      final body = [
        ...u32(items.length),
        ...u32(0),
        ...u32(asUtf8 ? 0x0100 : 0),
        ...u32(header + items.length * 4),
        ...u32(0),
        for (final o in offsets) ...u32(o),
        ...blob,
      ];
      return [...u16(0x0001), ...u16(header), ...u32(8 + body.length), ...body];
    }

    /// One START_ELEMENT with the given attributes, as (ns, name, type, datum).
    List<int> element(List<(int, int, int, int)> attributes) {
      const header = 16;
      final body = [
        ...u32(0xFFFFFFFF), ...u32(0), // ns, name
        ...u16(20), ...u16(20), ...u16(attributes.length),
        ...u16(0), ...u16(0), ...u16(0),
        for (final (ns, name, type, datum) in attributes) ...[
          ...u32(ns),
          ...u32(name),
          ...u32(type == 0x03 ? datum : 0xFFFFFFFF),
          ...u16(8),
          0,
          type,
          ...u32(datum),
        ],
      ];
      return [
        ...u16(0x0102),
        ...u16(header),
        ...u32(8 + header - 8 + body.length + 8 - 8),
        ...u32(1),
        ...u32(0xFFFFFFFF),
        ...body,
      ];
    }

    Uint8List axml(
      List<String> strings,
      List<(int, int, int, int)> attrs, {
      bool asUtf8 = true,
    }) {
      final p = pool(strings, asUtf8: asUtf8);
      final e = element(attrs);
      final body = [...p, ...e];
      return Uint8List.fromList([
        ...u16(0x0003),
        ...u16(8),
        ...u32(8 + body.length),
        ...body,
      ]);
    }

    test('an integer attribute is its datum, not a pool index', () {
      // The trap this format sets: reading `data` for a *string* attribute
      // yields a pool index printed as a number — a plausible wrong answer
      // rather than a failure. So the type has to decide where to look.
      final bytes = axml(['versionCode', _ns], [(1, 0, 0x10, 66)]);

      expect(readBinaryXmlAttributes(bytes, {'versionCode'}), {
        'versionCode': '66',
      });
    });

    test('a string attribute comes from the pool', () {
      final bytes = axml(['versionName', _ns, '1.1.0'], [(1, 0, 0x03, 2)]);

      expect(readBinaryXmlAttributes(bytes, {'versionName'}), {
        'versionName': '1.1.0',
      });
    });

    test('a UTF-16 string pool reads, and it is a separate layout', () {
      // Nothing exercised this branch — not these fixtures, which build UTF-8
      // pools, and not the three production apks it was validated against,
      // which are all UTF-8. It was shipped on the strength of the spec alone.
      final bytes = axml(
        ['versionName', _ns, '1.1.0'],
        [(1, 0, 0x03, 2)],
        asUtf8: false,
      );

      expect(readBinaryXmlAttributes(bytes, {'versionName'}), {
        'versionName': '1.1.0',
      });
    });

    test('a UTF-16 pool carries non-ASCII whole', () {
      // ASCII is where the two encodings agree, so an ASCII-only fixture
      // cannot tell a working UTF-16 reader from one that is reading bytes and
      // getting away with it. The `é` is two bytes in UTF-8 and one unit in
      // UTF-16; the emoji is a surrogate pair, so it also proves the unit
      // count is units rather than characters.
      final bytes = axml(
        ['versionName', _ns, '1.1.0-café 🚲'],
        [(1, 0, 0x03, 2)],
        asUtf8: false,
      );

      expect(readBinaryXmlAttributes(bytes, {'versionName'}), {
        'versionName': '1.1.0-café 🚲',
      });
    });

    test('a UTF-8 pool carries non-ASCII whole', () {
      // The mirror of the above, and the reason the writer emits *two* lengths:
      // taking the first (the UTF-16 count) as a byte count truncates exactly
      // one byte per non-ASCII character, which an ASCII fixture never sees.
      final bytes = axml(
        ['versionName', _ns, '1.1.0-café 🚲'],
        [(1, 0, 0x03, 2)],
      );

      expect(readBinaryXmlAttributes(bytes, {'versionName'}), {
        'versionName': '1.1.0-café 🚲',
      });
    });

    test('bytes that are not binary XML are refused', () {
      expect(
        () => readBinaryXmlAttributes(
          Uint8List.fromList([0, 0, 0, 0, 0, 0, 0, 0]),
          {'versionCode'},
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('the comparison', () {
    test('agreement names what it compared and where it read it', () {
      expect(
        describeCrossCheck(
          versionName: '1.1.0',
          buildNumber: '65',
          format: 'aab',
          baked: _baked(versionName: '1.1.0', buildNumber: '65'),
        ),
        'cross-check: build number and version name agree with '
        'base/manifest/AndroidManifest.xml',
      );
    });

    test('a build number that disagrees is refused, naming both', () {
      // The defect class the digest cannot see: the manifest honestly describes
      // an artifact that is not the build it was written for.
      expect(
        () => describeCrossCheck(
          versionName: '1.1.0',
          buildNumber: '99',
          format: 'aab',
          baked: _baked(versionName: '1.1.0', buildNumber: '65'),
        ),
        throwsA(
          isA<ReleaseException>().having(
            (e) => e.message,
            'message',
            allOf(contains('manifest 99, artifact 65'), contains('stale')),
          ),
        ),
      );
    });

    test('a version name that disagrees is refused too', () {
      expect(
        () => describeCrossCheck(
          versionName: '9.9.9',
          buildNumber: '65',
          format: 'aab',
          baked: _baked(versionName: '1.1.0', buildNumber: '65'),
        ),
        throwsA(
          isA<ReleaseException>().having(
            (e) => e.message,
            'message',
            contains('manifest 9.9.9, artifact 1.1.0'),
          ),
        ),
      );
    });

    test('a format with no reader is trusted out loud', () {
      // The whole point of returning a sentence. A pkg that printed nothing
      // would render identically to one that had been verified.
      expect(
        describeCrossCheck(
          versionName: '1.1.0',
          buildNumber: '65',
          format: 'pkg',
          baked: null,
        ),
        allOf(contains('no reader for pkg'), contains('taken on trust')),
      );
    });

    test('a value the artifact does not carry is skipped, not failed', () {
      // Absent is not disagreement. An artifact carrying only one of the two
      // should have the other taken on trust rather than refused.
      expect(
        describeCrossCheck(
          versionName: '1.1.0',
          buildNumber: '65',
          format: 'aab',
          baked: _baked(buildNumber: '65'),
        ),
        contains('build number agree'),
      );
    });
  });
}
