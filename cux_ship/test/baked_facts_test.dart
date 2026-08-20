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
