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
import 'dart:io';
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

List<int> u16(int v) => [v & 0xff, (v >> 8) & 0xff];
List<int> u32(int v) => [
  v & 0xff,
  (v >> 8) & 0xff,
  (v >> 16) & 0xff,
  (v >> 24) & 0xff,
];

/// A string pool, in either of the two encodings the format allows.
///
/// **Both exist in the wild and they share no layout.** A UTF-8 pool stores two
/// lengths per string — the UTF-16 code-unit count and then the byte count —
/// while a UTF-16 pool stores one, counted in 16-bit units, with a wider
/// continuation bit (`0x8000` on a uint16, against `0x80` on a byte). Which one
/// an apk carries is decided by the toolchain that built it, so a reader that
/// handles one handles roughly half of Android.
List<int> stringPool(List<String> items, {bool asUtf8 = true}) {
  final blob = <int>[];
  final offsets = <int>[];
  for (final item in items) {
    offsets.add(blob.length);
    if (asUtf8) {
      final bytes = utf8.encode(item);
      blob
        // The UTF-16 length first, then the byte length. They differ for
        // anything outside ASCII, which is what makes reading the first one a
        // bug that ASCII fixtures cannot see.
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
List<int> startElement(List<(int, int, int, int)> attributes) {
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

Uint8List axmlFixture(
  List<String> strings,
  List<(int, int, int, int)> attrs, {
  bool asUtf8 = true,
}) {
  final p = stringPool(strings, asUtf8: asUtf8);
  final e = startElement(attrs);
  final body = [...p, ...e];
  return Uint8List.fromList([
    ...u16(0x0003),
    ...u16(8),
    ...u32(8 + body.length),
    ...body,
  ]);
}

/// One `<bundle>` element of a `PackageInfo`, as the packager writes it.
typedef Described = ({String id, String path, String? short, String? version});

/// The three bundles a Flutter-shaped `.app` produces, in the order `pkgbuild`
/// emitted them — the app neither first nor last, and two decoys carrying
/// version numbers that are not the build's.
const _helper = (
  id: 'design.codeux.howitwent.helper',
  path: './Runner.app/Contents/Library/LoginItems/Helper.app',
  short: '9.9.9',
  version: '777',
);
const _framework = (
  id: 'io.flutter.flutter.macos',
  path: './Runner.app/Contents/Frameworks/FlutterMacOS.framework',
  short: '3.24.0',
  version: '1',
);
const _app = (
  id: 'design.codeux.howitwent',
  path: './Runner.app',
  short: '1.1.0',
  version: '65',
);

String _describe(Described b) =>
    '    <bundle path="${b.path}" id="${b.id}"'
    '${b.short == null ? '' : ' CFBundleShortVersionString="${b.short}"'}'
    '${b.version == null ? '' : ' CFBundleVersion="${b.version}"'}/>';

/// A component package's `PackageInfo`.
///
/// **Kept at the shape `pkgbuild` writes rather than reduced to what the reader
/// looks at.** The elements below that carry no versions — `<upgrade-bundle>`,
/// `<strict-identifier>`, `<relocate>` — repeat the same identifiers on empty
/// `<bundle>` elements, and they are the reason the reader searches direct
/// children instead of descendants: a descendant search matches those too. A
/// fixture that dropped them would make that rule unreachable from every case,
/// and the reader would pass while returning an app with no version at all.
///
/// Measured on `pkgbuild --root … --identifier design.codeux.howitwent
/// --version 1.1.0` over an app carrying an embedded framework and a login-item
/// helper, 9 September 2026.
String packageInfo({
  required List<Described> bundles,
  required List<String> versionedBy,
}) {
  String ids(List<String> of) =>
      of.map((id) => '        <bundle id="$id"/>').join('\n');
  return '''
<?xml version="1.0" encoding="utf-8"?>
<pkg-info overwrite-permissions="true" relocatable="false" identifier="design.codeux.howitwent" postinstall-action="none" version="1.1.0" format-version="2" install-location="/Applications" auth="root">
    <payload numberOfFiles="35" installKBytes="9"/>
${bundles.map(_describe).join('\n')}
    <bundle-version>
${ids(versionedBy)}
    </bundle-version>
    <upgrade-bundle>
${ids(versionedBy)}
    </upgrade-bundle>
    <update-bundle/>
    <atomic-update-bundle/>
    <strict-identifier>
${ids(bundles.map((b) => b.id).toList())}
    </strict-identifier>
    <relocate>
${ids(versionedBy)}
    </relocate>
</pkg-info>
''';
}

/// The `Distribution` a product archive carries beside its components.
///
/// **A fixture goes to the trouble of carrying this because it is the trap.**
/// It lists the same three bundles with the same two attributes, in the same
/// order, and *without* the `<bundle-version>` marker that says which of them
/// the package is versioned by — so a reader that took the easier top-level
/// file would answer with the login item's 777. Nothing in production reads it;
/// it is here so that a reader which started to would be caught.
String distribution(List<Described> bundles) =>
    '''
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
    <pkg-ref id="design.codeux.howitwent">
        <bundle-version>
${bundles.map((b) => '            <bundle CFBundleShortVersionString="${b.short}" CFBundleVersion="${b.version}" id="${b.id}" path="${b.path.substring(2)}"/>').join('\n')}
        </bundle-version>
    </pkg-ref>
    <options customize="never" require-scripts="false" hostArchitectures="x86_64,arm64"/>
    <pkg-ref id="design.codeux.howitwent" version="1.1.0" onConclusion="none">#Component.pkg</pkg-ref>
</installer-gui-script>
''';

/// CRC-32, because a real `unzip` checks it and refuses an entry that fails.
int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// A zip with stored (uncompressed) entries.
///
/// **Hand-built rather than shelled out to `zip`.** The readers shell to
/// `unzip`, which is on every host that builds a Flutter app; `zip` is a
/// separate binary and is not, so depending on it would make these cases pass
/// or skip by accident of the machine. Stored entries need no compressor, and
/// the point here is the archive seam rather than the compression.
Uint8List storedZip(Map<String, List<int>> entries) {
  final out = <int>[];
  final central = <int>[];
  for (final MapEntry(key: name, value: data) in entries.entries) {
    final nameBytes = utf8.encode(name);
    final crc = _crc32(data);
    final offset = out.length;
    out.addAll([
      ...u32(0x04034b50),
      ...u16(20), ...u16(0), ...u16(0), // version, flags, stored
      ...u16(0), ...u16(0x21), // time, date (1 Jan 1980)
      ...u32(crc), ...u32(data.length), ...u32(data.length),
      ...u16(nameBytes.length), ...u16(0),
      ...nameBytes,
      ...data,
    ]);
    central.addAll([
      ...u32(0x02014b50),
      ...u16(20),
      ...u16(20),
      ...u16(0),
      ...u16(0),
      ...u16(0),
      ...u16(0x21),
      ...u32(crc),
      ...u32(data.length),
      ...u32(data.length),
      ...u16(nameBytes.length),
      ...u16(0),
      ...u16(0),
      ...u16(0),
      ...u16(0),
      ...u32(0),
      ...u32(offset),
      ...nameBytes,
    ]);
  }
  final centralAt = out.length;
  return Uint8List.fromList([
    ...out,
    ...central,
    ...u32(0x06054b50),
    ...u16(0),
    ...u16(0),
    ...u16(entries.length),
    ...u16(entries.length),
    ...u32(central.length),
    ...u32(centralAt),
    ...u16(0),
  ]);
}

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
    //
    // The builders are top-level, so the real-zip group below reaches the same
    // ones rather than keeping a second copy that can drift.
    const axml = axmlFixture;

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

  group('the PackageInfo walk', () {
    // A macOS installer package answers out of its own metadata rather than out
    // of the app: `pkgbuild` copies the two values into every component's
    // `PackageInfo`, because the installer compares them against what is on
    // disk. That file sits in the archive's table of contents, so nothing has
    // to decompress a payload — which is what made this format cheap enough to
    // read after all, having been priced as expensive and deferred.

    test('the app is read, and not the framework or helper beside it', () {
      // The defect this reader could most easily have shipped. A package
      // describes every bundle it installs, and taking the first one carrying
      // both attributes reports the login item's 777 as the build number —
      // which compares unequal and refuses a correct release, loudly and
      // wrongly.
      final bundle = readPackageInfoRootBundle(
        packageInfo(
          bundles: [_helper, _framework, _app],
          versionedBy: [_app.id],
        ),
      )!;

      expect(bundle.buildNumber, '65');
      expect(bundle.versionName, '1.1.0');
      expect(
        bundle.path,
        './Runner.app',
        reason: 'the path is what lets a build log say which bundle answered',
      );
    });

    test('the designation decides, not the order or the shallowest path', () {
      // The same file with the app described first and the helper designated.
      // Nothing real is shaped this way; the point is to separate two rules
      // that agree on every real package — "the bundle the file says it is
      // versioned by" and "whichever bundle happens to sit outermost". Only
      // the first is the installer's own answer, and only this case can tell
      // a reader implementing it from one implementing the other.
      final bundle = readPackageInfoRootBundle(
        packageInfo(
          bundles: [_app, _framework, _helper],
          versionedBy: [_helper.id],
        ),
      )!;

      expect(bundle.buildNumber, '777');
      expect(bundle.path, _helper.path);
    });

    test('a component that is versioned by nothing is not an app', () {
      // A scripts-only component is a real thing for a package to hold, and it
      // is not a reader failure — it contributes nothing and the app's own
      // component answers.
      expect(
        readPackageInfoRootBundle(
          packageInfo(bundles: const [], versionedBy: const []),
        ),
        isNull,
      );
    });

    test('a designated bundle that is not described is a refusal', () {
      // Not "this package carries no version". The file named an identifier and
      // then did not describe it, which means this is not being read as the
      // structure it is — and answering "taken on trust" there is the collapse
      // the whole cross-check exists to prevent.
      expect(
        () => readPackageInfoRootBundle(
          packageInfo(
            bundles: [_helper, _framework, _app],
            versionedBy: const ['design.codeux.absent'],
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('two designated bundles are refused rather than picked between', () {
      expect(
        () => readPackageInfoRootBundle(
          packageInfo(
            bundles: [_helper, _app],
            versionedBy: [_app.id, _helper.id],
          ),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('guess'),
          ),
        ),
      );
    });

    test('a Distribution handed to this is refused, not half-read', () {
      // It is XML, it holds `<bundle>` elements with both attributes, and it is
      // the wrong file — so a reader pointed at it must say so rather than
      // return whichever bundle it met first.
      expect(
        () => readPackageInfoRootBundle(distribution([_helper, _app])),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('pkg-info'),
          ),
        ),
      );
    });

    test('a DOCTYPE entity is not expanded, so a DOCTYPE is inert', () {
      // **Pinning a dependency's behaviour, because a comment rests on it.**
      // The input is an artifact's own bytes, and the reader's answer to the
      // usual XML question is that `package:xml` expands no DTD-declared
      // entity — which makes a hostile `PackageInfo` unable to leak a file or
      // detonate an expansion bomb. That is measured rather than argued, and
      // if a future `xml` starts expanding, this goes red and the comment
      // stops being true at the same moment.
      final bundle = readPackageInfoRootBundle('''
<?xml version="1.0"?>
<!DOCTYPE pkg-info [
<!ENTITY leak SYSTEM "file:///etc/passwd">
<!ENTITY a "aaaaaaaaaa">
<!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">
]>
<pkg-info>
    <bundle path="./Runner.app" id="x" CFBundleShortVersionString="&leak;" CFBundleVersion="&b;"/>
    <bundle-version><bundle id="x"/></bundle-version>
</pkg-info>
''')!;

      expect(bundle.versionName, '&leak;', reason: 'not fetched');
      expect(bundle.buildNumber, '&b;', reason: 'not expanded');
    });

    test('bytes that are not XML are a FormatException', () {
      expect(
        () => readPackageInfoRootBundle('a signed installer, pretend'),
        throwsA(isA<FormatException>()),
      );
    });

    test('a version the installer did not record comes back absent', () {
      // Absent is not empty and not zero: an empty string would compare unequal
      // and read as a mismatch rather than as a value nobody wrote down.
      final bundle = readPackageInfoRootBundle(
        packageInfo(
          bundles: [(id: _app.id, path: _app.path, short: null, version: null)],
          versionedBy: [_app.id],
        ),
      )!;

      expect(bundle.versionName, isNull);
      expect(bundle.buildNumber, isNull);
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
      // The whole point of returning a sentence. A dmg that printed nothing
      // would render identically to one that had been verified.
      //
      // `dmg` rather than `pkg`, which used to stand here: pkg has a reader
      // now, and a case whose format quietly acquires one is a case that stops
      // testing what it is named for.
      expect(
        describeCrossCheck(
          versionName: '1.1.0',
          buildNumber: '65',
          format: 'dmg',
          baked: null,
        ),
        allOf(contains('no reader for dmg'), contains('taken on trust')),
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
        contains('build number agrees'),
      );
    });

    test('a partial check names the half it did not check', () {
      // The collapsed state: "checked one of two" used to differ from "checked
      // both" only by which nouns appeared, which is legible to somebody who
      // already knows there are two and to nobody else. What went unverified
      // is said out loud everywhere else here; this was the exception.
      final sentence = describeCrossCheck(
        versionName: '1.1.0',
        buildNumber: '65',
        format: 'aab',
        baked: _baked(buildNumber: '65'),
      );

      expect(sentence, contains('version name taken on trust'));
      expect(
        describeCrossCheck(
          versionName: '1.1.0',
          buildNumber: '65',
          format: 'aab',
          baked: _baked(buildNumber: '65', versionName: '1.1.0'),
        ),
        isNot(contains('taken on trust')),
        reason: 'a full check must not claim anything was trusted',
      );
    });

    test('an Android manifest carrying neither value is a refusal', () {
      // Every valid apk and aab declares versionCode and versionName — it is
      // where Android itself reads them. Finding neither means the walk lost
      // its place, and calling that "taken on trust" is the same collapse this
      // function exists to prevent, one level in.
      for (final format in ['apk', 'aab']) {
        expect(
          () => describeCrossCheck(
            versionName: '1.1.0',
            buildNumber: '65',
            format: format,
            baked: _baked(),
          ),
          throwsA(
            isA<ReleaseException>().having(
              (e) => e.toString(),
              'message',
              contains('found neither'),
            ),
          ),
          reason: format,
        );
      }
    });

    test('an Apple artifact carrying neither value is still only trusted', () {
      // The counterpart, and why the refusal above is keyed to the format.
      // Neither Apple reader has a walk to desync: `plutil` either extracts a
      // key or reports it missing, and the pkg reader locates its element by
      // the identifier the file itself designates — so an attribute that is not
      // there was not written, rather than missed. Adding either format to the
      // refusal above would turn that into a failed release.
      for (final format in ['ipa', 'pkg']) {
        expect(
          describeCrossCheck(
            versionName: '1.1.0',
            buildNumber: '65',
            format: format,
            baked: _baked(),
          ),
          contains('carried neither value'),
          reason: format,
        );
      }
    });
  });

  group('through a real zip', () {
    // **Every case above hands bytes straight to a walker.** Nothing exercised
    // the seam where the last defect lived: `_zipEntry`, its reading of unzip's
    // exit code, and the readers' interpretation of what comes back. So these
    // build an actual archive and go in through `readApkFacts` — which means a
    // real `unzip` subprocess, as production has.
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('cux_ship_zip'));
    tearDown(() => dir.deleteSync(recursive: true));

    String apk(String name, Uint8List manifest) {
      final path = '${dir.path}/$name';
      File(path).writeAsBytesSync(storedZip({'AndroidManifest.xml': manifest}));
      return path;
    }

    test('a well-formed apk reads, through unzip and all', () {
      final path = apk(
        'app.apk',
        axmlFixture(
          ['versionCode', _ns, 'versionName', '1.4.2'],
          [(1, 0, 0x10, 92), (1, 2, 0x03, 3)],
        ),
      );

      final facts = readApkFacts(path);

      expect(facts.buildNumber, '92');
      expect(facts.versionName, '1.4.2');
      expect(facts.source, 'AndroidManifest.xml');
    });

    test('a manifest declaring sizes past its own end is a refusal', () {
      // Found by review: the walk's reads are `ByteData`, which raises
      // `RangeError` and not `FormatException` — so a header size running past
      // the chunk escaped every catch and reached the operator as
      // `Unhandled exception:` plus forty frames, out of a binary whose exit
      // codes are a documented interface.
      const strings = ['versionCode', _ns];
      final bytes = axmlFixture(strings, [(1, 0, 0x10, 66)]);
      // The START_ELEMENT's headerSize, made absurd while the chunk size stays
      // honest — so the chunk-bounds check passes and the read past the end
      // happens anyway. Computed rather than counted back from the end: an
      // offset that silently misses would leave this test green against the
      // very bug it exists for.
      final elementAt = 8 + stringPool(strings).length;
      expect(
        bytes[elementAt] | (bytes[elementAt + 1] << 8),
        0x0102,
        reason: 'the patch must land on the START_ELEMENT chunk header',
      );
      bytes[elementAt + 2] = 0xFF;
      bytes[elementAt + 3] = 0x7F;

      expect(
        () => readApkFacts(apk('broken.apk', bytes)),
        throwsA(
          isA<ReleaseException>().having(
            (e) => e.toString(),
            'message',
            contains('could not read'),
          ),
        ),
      );
    });

    test('an archive carrying no manifest is refused, not trusted', () {
      final path = '${dir.path}/empty.apk';
      File(
        path,
      ).writeAsBytesSync(storedZip({'res/values.xml': utf8.encode('')}));

      expect(
        () => readApkFacts(path),
        throwsA(
          isA<ReleaseException>().having(
            (e) => e.toString(),
            'message',
            contains('carries no AndroidManifest.xml'),
          ),
        ),
      );
    });
  });

  group(
    'through a real xar',
    () {
      // **The cases above hand a string to the selector.** These go in through
      // `readPkgFacts`, so a real `xar` lists a real archive and extracts out
      // of it — the seam where this file's last defect lived, one format over.
      late Directory dir;
      setUp(() => dir = Directory.systemTemp.createTempSync('cux_ship_xar'));
      tearDown(() => dir.deleteSync(recursive: true));

      /// A xar archive of [members], each keyed by its path inside it.
      String pkg(String name, Map<String, String> members) {
        final staging = Directory('${dir.path}/staging')..createSync();
        for (final MapEntry(key: path, value: content) in members.entries) {
          File('${staging.path}/$path')
            ..parent.createSync(recursive: true)
            ..writeAsStringSync(content);
        }
        final out = '${dir.path}/$name';
        final result = Process.runSync('xar', [
          '-cf',
          out,
          // Top-level names only: xar takes the tree under each.
          ...members.keys.map((path) => path.split('/').first).toSet(),
        ], workingDirectory: staging.path);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        staging.deleteSync(recursive: true);
        return out;
      }

      test('a product archive reads, through xar and all', () {
        // The shape an App Store upload has: one component, and a Distribution
        // listing every bundle with no marker for which is the app. The source
        // names both the component and the bundle, because a package describes
        // several and a log that says only "PackageInfo" cannot be checked by
        // the person reading it.
        final path = pkg('how-it-went-1.1.0-65.pkg', {
          'Component.pkg/PackageInfo': packageInfo(
            bundles: [_helper, _framework, _app],
            versionedBy: [_app.id],
          ),
          'Component.pkg/Payload': 'a gzipped cpio, pretend',
          'Component.pkg/Bom': 'a bill of materials, pretend',
          'Distribution': distribution([_helper, _framework, _app]),
        });

        final facts = readPkgFacts(path);

        expect(facts.buildNumber, '65');
        expect(facts.versionName, '1.1.0');
        expect(facts.source, 'Component.pkg/PackageInfo (./Runner.app)');
      });

      test('the shape an App Store upload actually has reads', () {
        // **The three-bundle fixtures above are a `pkgbuild --root` shape.**
        // `xcodebuild -exportArchive` drives `productbuild --component`, which
        // describes the *installed* bundle and nothing else — one element, from
        // a payload of 124 files. Taken from the real `how-it-went` 1.1.6 (169)
        // package that produced the "no reader for pkg" line this exists for,
        // so the values and the path are that file's rather than invented.
        //
        // The path carries spaces, which no other fixture here does.
        const Described shipped = (
          id: 'design.codeux.howitwent',
          path: './How It Went.app',
          short: '1.1.6',
          version: '169',
        );
        final path = pkg('how-it-went-1.1.6-169.pkg', {
          'design.codeux.howitwent.pkg/PackageInfo': packageInfo(
            bundles: const [shipped],
            versionedBy: [shipped.id],
          ),
          'design.codeux.howitwent.pkg/Payload': 'a gzipped cpio, pretend',
          'Distribution': distribution(const [shipped]),
        });

        final facts = readPkgFacts(path);

        expect(facts.buildNumber, '169');
        expect(facts.versionName, '1.1.6');
        expect(
          facts.source,
          'design.codeux.howitwent.pkg/PackageInfo (./How It Went.app)',
        );
      });

      test('a flat component package reads, with PackageInfo at the top', () {
        // `pkgbuild` alone produces one of these, and it carries no
        // Distribution at all — which is the second reason the reader does not
        // read one.
        final path = pkg('component.pkg', {
          'PackageInfo': packageInfo(bundles: [_app], versionedBy: [_app.id]),
          'Payload': 'a gzipped cpio, pretend',
        });

        expect(readPkgFacts(path).source, 'PackageInfo (./Runner.app)');
        expect(readPkgFacts(path).buildNumber, '65');
      });

      test('a scripts-only component beside the app is stepped over', () {
        final path = pkg('with-scripts.pkg', {
          'Scripts.pkg/PackageInfo': packageInfo(
            bundles: const [],
            versionedBy: const [],
          ),
          'App.pkg/PackageInfo': packageInfo(
            bundles: [_app],
            versionedBy: [_app.id],
          ),
        });

        expect(readPkgFacts(path).source, 'App.pkg/PackageInfo (./Runner.app)');
      });

      test('a package that is only scripts is refused, not trusted', () {
        // The failure path the case above cannot reach: there, a second
        // component answered. Here nothing in the archive claims to be an app,
        // and reporting that as trust would put a macOS release back exactly
        // where it started while printing a sentence that reads like success.
        final path = pkg('scripts.pkg', {
          'Scripts.pkg/PackageInfo': packageInfo(
            bundles: const [],
            versionedBy: const [],
          ),
        });

        expect(
          () => readPkgFacts(path),
          throwsA(
            isA<ReleaseException>().having(
              (e) => e.toString(),
              'message',
              contains('names a bundle it is versioned by'),
            ),
          ),
        );
      });

      test('the dispatch routes pkg here, so macOS is checked at all', () {
        // Everything else in this group calls the reader directly, and the
        // reader is reached only through the format switch. A missing arm
        // there is the whole defect coming back: every value trusted, one
        // sentence saying so, and no test noticing.
        final path = pkg('how-it-went-1.1.0-65.pkg', {
          'Component.pkg/PackageInfo': packageInfo(
            bundles: [_helper, _framework, _app],
            versionedBy: [_app.id],
          ),
        });

        expect(readBakedFacts(path, 'pkg')?.buildNumber, '65');
      });

      test('a package that disagrees with its manifest is refused', () {
        // What the reader is for, end to end: a macOS manifest claiming 99
        // against a package carrying 65 used to be a line saying nothing had
        // been checked.
        final path = pkg('how-it-went-1.1.0-99.pkg', {
          'Component.pkg/PackageInfo': packageInfo(
            bundles: [_helper, _framework, _app],
            versionedBy: [_app.id],
          ),
        });

        expect(
          () => describeCrossCheck(
            versionName: '1.1.0',
            buildNumber: '99',
            format: 'pkg',
            baked: readBakedFacts(path, 'pkg'),
          ),
          throwsA(
            isA<ReleaseException>().having(
              (e) => e.message,
              'message',
              contains('manifest 99, artifact 65'),
            ),
          ),
        );
      });

      test('two components that each name an app are refused, not picked', () {
        final path = pkg('two.pkg', {
          'One.pkg/PackageInfo': packageInfo(
            bundles: [_app],
            versionedBy: [_app.id],
          ),
          'Two.pkg/PackageInfo': packageInfo(
            bundles: [_helper],
            versionedBy: [_helper.id],
          ),
        });

        expect(
          () => readPkgFacts(path),
          throwsA(
            isA<ReleaseException>().having(
              (e) => e.toString(),
              'message',
              contains('installs'),
            ),
          ),
        );
      });

      test('a file that is not a xar is refused, not trusted', () {
        // The distinction the null return exists for: "no reader for pkg" is a
        // claim about the format, and this is a claim about the file.
        final path = '${dir.path}/how-it-went-1.1.0-65.pkg';
        File(path).writeAsStringSync('a signed installer, pretend');

        expect(
          () => readPkgFacts(path),
          throwsA(
            isA<ReleaseException>().having(
              (e) => e.toString(),
              'message',
              allOf(contains('cannot cross-check'), contains('truncated')),
            ),
          ),
        );
      });

      test('xar normalises an entry name that would escape', () {
        // **The reader has no traversal guard, and this is why.** An entry name
        // comes out of the archive and is joined onto the temp directory, so a
        // name that climbed out of it would be read from somewhere else — but
        // xar strips both spellings on create, so no fixture can reach such a
        // check and a guard no test can fail would rot.
        //
        // That argument is only as good as xar's behaviour, so the behaviour is
        // pinned here rather than asserted in a comment. Both spellings: `..`,
        // and the absolute path that normalises to the same escape.
        final staging = Directory('${dir.path}/escape')..createSync();
        File('${staging.path}/PackageInfo').writeAsStringSync('<pkg-info/>');
        final out = '${dir.path}/escape.pkg';

        for (final spelling in [
          '${staging.path}/PackageInfo', // absolute
          '../escape/PackageInfo', // parent-relative
        ]) {
          final created = Process.runSync('xar', [
            '-cf',
            out,
            spelling,
          ], workingDirectory: staging.path);
          expect(created.exitCode, 0, reason: '${created.stderr}');

          final listed = const LineSplitter()
              .convert(
                Process.runSync('xar', ['-tf', out]).stdout as String,
              )
              .map((line) => line.trim())
              .where((line) => line.isNotEmpty)
              .toList();

          // Before the claim: `everyElement` is vacuously true on an empty
          // listing, so without this a xar that stored nothing would prove the
          // escape is normalised.
          expect(
            listed,
            isNotEmpty,
            reason: 'the member has to be in the archive for this to mean any',
          );
          expect(
            listed,
            everyElement(
              allOf(
                isNot(startsWith('/')),
                isNot(contains('..')),
              ),
            ),
            reason:
                'xar stored $spelling verbatim, so the absent traversal guard '
                'is no longer covered by the reasoning that removed it',
          );
        }
      });

      test('a PackageInfo that is a directory is a sentence, not a crash', () {
        // The listing says the member is there and the extraction succeeds, so
        // both exit codes are 0 and the reader is one `readAsStringSync` away
        // from an unhandled FileSystemException — forty frames out of a binary
        // whose exit codes are a documented interface, which is the failure the
        // apk reader's RangeError catch was added for.
        final path = pkg('dir.pkg', {
          'PackageInfo/inner': 'a directory wearing the name of a file',
        });

        expect(
          () => readPkgFacts(path),
          throwsA(
            isA<ReleaseException>().having(
              (e) => e.toString(),
              'message',
              contains('produced no file to read'),
            ),
          ),
        );
      });

      test('an archive carrying no PackageInfo is refused', () {
        final path = pkg('empty.pkg', {
          'Distribution': distribution([_app]),
        });

        expect(
          () => readPkgFacts(path),
          throwsA(
            isA<ReleaseException>().having(
              (e) => e.toString(),
              'message',
              contains('carries no PackageInfo'),
            ),
          ),
        );
      });
    },
    // A `.pkg` is only ever produced on macOS, which is the only place
    // `/usr/bin/xar` ships — so this is the condition production runs under
    // rather than a convenience. Gated on the platform and not on whether the
    // tool happens to be installed, because a gate on the tool lets a machine
    // skip silently, which is what `storedZip` above exists to avoid.
    skip: Platform.isMacOS
        ? null
        : 'xar builds and reads these fixtures, and both it and the format are '
              'macOS-only',
  );
}
