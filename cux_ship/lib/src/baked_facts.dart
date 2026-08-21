// SPDX-License-Identifier: Apache-2.0
//
// What an artifact says about itself, read back out of its own bytes.
//
// **The manifest claims a version name and a build number, and until now
// nothing checked either against the artifact.** The digest proves the bytes are
// the ones the manifest was written for; it cannot notice that the *build*
// disagreed with what the script asked for — an export step rewriting
// `CFBundleVersion`, a Gradle override, a variable that evaluated empty, a
// stale artifact copied over a fresh manifest's neighbour. In every one of
// those the manifest honestly describes the wrong artifact.
//
// The check existed, in the wrong place: Play parses an uploaded bundle and
// reports its versionCode, and `play upload` compares afterwards. Correct, and
// it costs a 69 MB upload to learn. This holds the artifact and the claimed
// values at the same instant.
//
// **A format with no reader is trusted loudly, never silently.** `readFor`
// returns null and the caller says so — absence of verification is a visible
// state rather than the same line as success. That is the consuming project's
// rule: print effective configuration, never intended.
//
// See docs/design/build-lifecycle.md.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'release.dart' show ReleaseException;

/// The version name and build number an artifact carries internally.
class BakedFacts {
  const BakedFacts({
    required this.versionName,
    required this.buildNumber,
    required this.source,
  });

  /// `versionName` / `CFBundleShortVersionString`.
  final String? versionName;

  /// `versionCode` / `CFBundleVersion`.
  final String? buildNumber;

  /// Where these were read from, for a message that names its evidence.
  final String source;
}

/// One protobuf field: its number, wire type, and payload.
///
/// A general decoder would have to model aapt2's whole schema. This models
/// none of it — the walk is element → attributes → three strings, so every
/// other field is skipped by length without being understood.
class _Field {
  const _Field(this.number, this.wire, this.bytes, this.end);

  final int number;
  final int wire;
  final Uint8List bytes;

  /// Where the next field starts, so the reader never recomputes its own
  /// advance — an earlier draft did, in two places, which is two chances to
  /// disagree about how far a varint ran.
  final int end;
}

/// Reads a varint at [offset], returning its value and where it ended.
(int value, int end) _varint(Uint8List data, int offset) {
  var value = 0, shift = 0, pos = offset;
  while (true) {
    if (pos >= data.length) {
      throw const FormatException('truncated varint');
    }
    final b = data[pos++];
    value |= (b & 0x7f) << shift;
    if (b & 0x80 == 0) {
      return (value, pos);
    }
    shift += 7;
    if (shift > 63) {
      throw const FormatException('varint too long');
    }
  }
}

/// Every field in [data], skipping what it does not need to understand.
Iterable<_Field> _fields(Uint8List data) sync* {
  var offset = 0;
  while (offset < data.length) {
    final (key, afterKey) = _varint(data, offset);
    final number = key >> 3, wire = key & 7;
    switch (wire) {
      case 0:
        final (_, end) = _varint(data, afterKey);
        yield _Field(number, wire, Uint8List(0), end);
        offset = end;
      case 2:
        final (len, afterLen) = _varint(data, afterKey);
        final end = afterLen + len;
        if (end > data.length) {
          throw const FormatException('length-delimited field runs past end');
        }
        yield _Field(
          number,
          wire,
          Uint8List.sublistView(data, afterLen, end),
          end,
        );
        offset = end;
      case 1:
        offset = afterKey + 8;
      case 5:
        offset = afterKey + 4;
      default:
        throw FormatException('unhandled wire type $wire');
    }
  }
}

const _androidNs = 'http://schemas.android.com/apk/res/android';

/// The named attributes of the root `<manifest>` element of an aapt2 proto
/// `AndroidManifest.xml`.
///
/// **The walk is two levels, not five.** `XmlNode.element` is field 1;
/// `XmlElement.attribute` is repeated field 4; `XmlAttribute` is
/// `namespace_uri` 1, `name` 2, `value` 3. The value arrives already rendered
/// as a string — `versionCode` carries `"65"` in field 3 *as well as* the
/// compiled integer in `compiled_item → prim → int_decimal_value` — so nothing
/// here decodes `Item` or `Primitive`. Verified against `protoc --decode_raw`
/// on a real signed bundle.
///
/// An attribute with no namespace matches too, because `package` carries none.
Map<String, String> readProtoManifestAttributes(
  Uint8List proto,
  Set<String> wanted,
) {
  final found = <String, String>{};
  for (final node in _fields(proto)) {
    if (node.number != 1 || node.wire != 2) {
      continue;
    }
    for (final attribute in _fields(node.bytes)) {
      if (attribute.number != 4 || attribute.wire != 2) {
        continue;
      }
      String? namespace, name, value;
      for (final part in _fields(attribute.bytes)) {
        if (part.wire != 2) {
          continue;
        }
        final text = utf8.decode(part.bytes, allowMalformed: true);
        switch (part.number) {
          case 1:
            namespace = text;
          case 2:
            name = text;
          case 3:
            value = text;
        }
      }
      if (name != null &&
          wanted.contains(name) &&
          (namespace == null || namespace == _androidNs)) {
        found[name] = value ?? '';
      }
    }
  }
  return found;
}

/// The named attributes of the root element of an Android *binary* XML
/// (`axml`) `AndroidManifest.xml`, as found inside an `.apk`.
///
/// **A different encoding from the `.aab`'s, not a variant of it.** A bundle
/// carries aapt2's protobuf; an apk carries this — a chunked format with a
/// string pool that every name and string value indexes into. Nothing is shared
/// between the two readers but the question they answer.
///
/// Only what is needed is modelled: the string pool, and the first
/// START_ELEMENT's attributes. Every other chunk is skipped by its own declared
/// size without being understood, which is what keeps this short and is also
/// why an unknown chunk cannot break it.
Map<String, String> readBinaryXmlAttributes(
  Uint8List axml,
  Set<String> wanted,
) {
  final data = ByteData.sublistView(axml);
  int u16(int at) => data.getUint16(at, Endian.little);
  int u32(int at) => data.getUint32(at, Endian.little);

  if (axml.length < 8 || u16(0) != 0x0003) {
    throw const FormatException('not a binary XML chunk');
  }

  var strings = <String>[];
  var offset = 8;
  while (offset + 8 <= axml.length) {
    final type = u16(offset);
    final headerSize = u16(offset + 2);
    final size = u32(offset + 4);
    if (size < 8 || offset + size > axml.length) {
      throw const FormatException('chunk runs past the end');
    }

    if (type == 0x0001) {
      strings = _stringPool(data, axml, offset, headerSize);
    } else if (type == 0x0102) {
      // START_ELEMENT. Attributes follow the element header at an offset the
      // chunk states rather than one this assumes, because the header has grown
      // between platform versions.
      final attributeStart = u16(offset + headerSize + 8);
      final attributeSize = u16(offset + headerSize + 10);
      final attributeCount = u16(offset + headerSize + 12);
      final found = <String, String>{};
      for (var i = 0; i < attributeCount; i++) {
        final at = offset + headerSize + attributeStart + i * attributeSize;
        if (at + 20 > axml.length) {
          throw const FormatException('attribute runs past the end');
        }
        final namespace = _pooled(strings, u32(at));
        final name = _pooled(strings, u32(at + 4));
        if (name == null || !wanted.contains(name)) {
          continue;
        }
        if (namespace != null && namespace != _androidNs) {
          continue;
        }
        // A typed value where the type decides where the value lives: a string
        // indexes the pool, an integer is the datum itself. Reading `data` for
        // a string attribute yields a pool index printed as a number, which is
        // a plausible-looking wrong answer rather than a failure.
        final rawValue = u32(at + 8);
        final dataType = data.getUint8(at + 15);
        final datum = u32(at + 16);
        final value = switch (dataType) {
          0x03 => _pooled(strings, datum) ?? _pooled(strings, rawValue),
          0x10 => '$datum',
          0x11 => '0x${datum.toRadixString(16)}',
          0x12 => datum == 0 ? 'false' : 'true',
          _ => _pooled(strings, rawValue),
        };
        if (value != null) {
          found[name] = value;
        }
      }
      // The root element is the one that answers; nested ones are not the
      // manifest's own attributes.
      return found;
    }
    offset += size;
  }
  return const {};
}

/// [index] as a pool string, or null for the `-1` that means absent.
String? _pooled(List<String> pool, int index) =>
    index == 0xFFFFFFFF || index >= pool.length ? null : pool[index];

/// The strings of a RES_STRING_POOL chunk at [offset].
List<String> _stringPool(
  ByteData data,
  Uint8List bytes,
  int offset,
  int headerSize,
) {
  final count = data.getUint32(offset + 8, Endian.little);
  final flags = data.getUint32(offset + 16, Endian.little);
  final stringsStart = data.getUint32(offset + 20, Endian.little);
  final utf8Pool = flags & 0x0100 != 0;

  final out = <String>[];
  for (var i = 0; i < count; i++) {
    final at =
        offset +
        stringsStart +
        data.getUint32(offset + headerSize + i * 4, Endian.little);
    if (at >= bytes.length) {
      throw const FormatException('string offset runs past the end');
    }
    if (utf8Pool) {
      // Two lengths, each one or two bytes: the UTF-16 length then the UTF-8
      // byte length. The first is skipped and the second is the one that
      // measures these bytes — taking the first would truncate every string
      // containing a character outside the BMP.
      var p = at;
      p += bytes[p] & 0x80 != 0 ? 2 : 1;
      final byteLength = bytes[p] & 0x80 != 0
          ? ((bytes[p] & 0x7f) << 8) | bytes[p + 1]
          : bytes[p];
      p += bytes[p] & 0x80 != 0 ? 2 : 1;
      out.add(
        utf8.decode(bytes.sublist(p, p + byteLength), allowMalformed: true),
      );
    } else {
      var p = at;
      var length = data.getUint16(p, Endian.little);
      p += 2;
      if (length & 0x8000 != 0) {
        length = ((length & 0x7fff) << 16) | data.getUint16(p, Endian.little);
        p += 2;
      }
      final units = <int>[];
      for (var c = 0; c < length; c++) {
        units.add(data.getUint16(p + c * 2, Endian.little));
      }
      out.add(String.fromCharCodes(units));
    }
  }
  return out;
}

/// One entry out of a zip, as bytes.
///
/// Shells to `unzip` rather than taking an archive dependency, which is this
/// package's existing precedent — `deps.dart` shells to `tar` for the same
/// reason. An `.aab` is tens of megabytes and only one small member is wanted,
/// so nothing is expanded.
Uint8List? _zipEntry(String archive, String entry) {
  final result = Process.runSync('unzip', [
    '-p',
    archive,
    entry,
  ], stdoutEncoding: null);
  if (result.exitCode != 0) {
    return null;
  }
  final bytes = result.stdout as List<int>;
  return bytes.isEmpty ? null : Uint8List.fromList(bytes);
}

/// What an `.aab` says about itself, or null if it cannot be read.
BakedFacts? readAabFacts(String path) {
  const entry = 'base/manifest/AndroidManifest.xml';
  final proto = _zipEntry(path, entry);
  if (proto == null) {
    return null;
  }
  final Map<String, String> attributes;
  try {
    attributes = readProtoManifestAttributes(proto, {
      'versionCode',
      'versionName',
    });
  } on FormatException catch (e) {
    // Refuse to guess rather than report nothing. A layout this cannot walk is
    // news — the format is expected to be stable because bundletool depends on
    // it — and reporting "no reader" would file that under the trusted-loudly
    // case, which is a different and much quieter thing.
    throw ReleaseException(
      'could not read $entry out of ${path.split('/').last}: ${e.message}. '
      'The bundle may be from an AGP whose manifest layout this does not know.',
    );
  }
  if (attributes.isEmpty) {
    return null;
  }
  return BakedFacts(
    versionName: attributes['versionName'],
    buildNumber: attributes['versionCode'],
    source: entry,
  );
}

/// What an `.ipa` says about itself, or null if it cannot be read.
///
/// The `Info.plist` inside is a *binary* plist, so this asks `plutil` rather
/// than parsing one. Apple artifacts are only ever produced on macOS, which is
/// the only place `plutil` exists and the only place an `.ipa` is built — so
/// the tool is present wherever the question can be asked.
BakedFacts? readIpaFacts(String path) {
  final listing = Process.runSync('unzip', [
    '-Z1',
    path,
    'Payload/*.app/Info.plist',
  ]);
  if (listing.exitCode != 0) {
    return null;
  }
  final entry = const LineSplitter()
      .convert(listing.stdout as String)
      .map((l) => l.trim())
      .where((l) => l.endsWith('.app/Info.plist'))
      .firstOrNull;
  if (entry == null) {
    return null;
  }
  final plist = _zipEntry(path, entry);
  if (plist == null) {
    return null;
  }

  // `plutil` can read stdin with `-`, but Process.runSync cannot write to a
  // child, so the member is spilled to a temp file and removed however this
  // ends.
  final temporary = Directory.systemTemp.createTempSync('cux_ship_ipa');
  try {
    final file = File('${temporary.path}/Info.plist')..writeAsBytesSync(plist);
    String? extract(String key) {
      final result = Process.runSync('plutil', [
        '-extract',
        key,
        'raw',
        '-o',
        '-',
        file.path,
      ]);
      return result.exitCode == 0 ? (result.stdout as String).trim() : null;
    }

    final version = extract('CFBundleShortVersionString');
    final build = extract('CFBundleVersion');
    if (version == null && build == null) {
      return null;
    }
    return BakedFacts(versionName: version, buildNumber: build, source: entry);
  } finally {
    temporary.deleteSync(recursive: true);
  }
}

/// What [artifactPath] says about itself, or null when its format has no
/// reader.
///
/// Null is a real answer and the caller must report it: `pkg`, `dmg`, `msix`,
/// `snap`, `deb` and plain archives are trusted, and saying so is what keeps
/// "not checked" from reading like "checked and fine". `apk` is deliberately
/// absent — its manifest is binary XML, a different encoding from the `.aab`'s
/// protobuf, and no producer here ships one yet.
/// What an `.apk` says about itself, or null if it cannot be read.
BakedFacts? readApkFacts(String path) {
  const entry = 'AndroidManifest.xml';
  final axml = _zipEntry(path, entry);
  if (axml == null) {
    return null;
  }
  final Map<String, String> attributes;
  try {
    attributes = readBinaryXmlAttributes(axml, {'versionCode', 'versionName'});
  } on FormatException catch (e) {
    throw ReleaseException(
      'could not read $entry out of ${path.split('/').last}: ${e.message}',
    );
  }
  if (attributes.isEmpty) {
    return null;
  }
  return BakedFacts(
    versionName: attributes['versionName'],
    buildNumber: attributes['versionCode'],
    source: entry,
  );
}

BakedFacts? readBakedFacts(String artifactPath, String? format) =>
    switch (format) {
      'aab' => readAabFacts(artifactPath),
      'apk' => readApkFacts(artifactPath),
      'ipa' => readIpaFacts(artifactPath),
      _ => null,
    };
