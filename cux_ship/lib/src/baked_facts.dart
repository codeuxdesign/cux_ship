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

import 'package:xml/xml.dart';

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
///
/// **Only `0xFFFFFFFF` means absent.** Any other index past the end of the pool
/// means the walk is reading something that is not an index — a desync — and
/// treating that as "this attribute has no value" turns a lost parser into a
/// quiet, plausible answer: the attribute vanishes, the cross-check reports on
/// whatever else it found, and nothing says the read went wrong.
String? _pooled(List<String> pool, int index) {
  if (index == 0xFFFFFFFF) {
    return null;
  }
  if (index >= pool.length) {
    throw FormatException(
      'string index $index is past the end of a ${pool.length}-entry pool, so '
      'this is not being read as the structure it is',
    );
  }
  return pool[index];
}

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
/// Throws rather than returning null on failure, because the caller's null
/// means "this format has no reader" — a much quieter thing than "the reader
/// for this format could not read this file".
Uint8List _zipEntry(String archive, String entry) {
  final name = archive.split('/').last;
  final ProcessResult result;
  try {
    result = Process.runSync('unzip', [
      '-p',
      archive,
      entry,
    ], stdoutEncoding: null);
  } on ProcessException catch (e) {
    throw ReleaseException(
      'cannot cross-check $name: unzip is not available (${e.message}), and '
      'without it the values baked into an archive cannot be read at all. '
      'Install it — there is deliberately no flag to proceed on trust, '
      'because a host that silently stopped checking is the state this exists '
      'to make impossible.',
    );
  }
  // 11 is unzip's "no matching files", which is a different fact about the
  // file from "this is not a zip" and deserves a different sentence — the
  // whole point of this function throwing rather than returning null is that
  // an operator can tell these apart from a build log.
  if (result.exitCode == 11) {
    throw ReleaseException(
      'cannot cross-check $name: it is an archive but carries no $entry, so '
      'it is not the format it is named as',
    );
  }
  // **1 is "warnings, and the extraction succeeded"**, which Info-ZIP returns
  // for things like an offset-shifted archive — the bytes on stdout are the
  // entry's, and refusing them would call a readable artifact unreadable.
  // Distinguished from 2/3/9, which mean it could not be read.
  if (result.exitCode != 0 && result.exitCode != 1) {
    throw ReleaseException(
      'cannot cross-check $name: $entry could not be extracted from it '
      '(unzip exit ${result.exitCode}). Either the file is not the archive its '
      'extension claims, or it is truncated.',
    );
  }
  final bytes = result.stdout as List<int>;
  if (bytes.isEmpty) {
    throw ReleaseException(
      'cannot cross-check $name: $entry is present but empty',
    );
  }
  return Uint8List.fromList(bytes);
}

/// What an `.aab` says about itself, or null if it cannot be read.
BakedFacts readAabFacts(String path) {
  const entry = 'base/manifest/AndroidManifest.xml';
  final proto = _zipEntry(path, entry);
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
  } on RangeError catch (e) {
    // As in [readApkFacts]: a length read out of the file's own bytes can send
    // a read past the end, and that arrives as RangeError rather than as a
    // FormatException.
    throw ReleaseException(
      'could not read $entry out of ${path.split('/').last}: it declares '
      'sizes that run past its own bytes ($e)',
    );
  }
  // Neither value present is "the manifest carried neither", not "no reader" —
  // see [readBakedFacts] for why those must not render alike.
  return BakedFacts(
    versionName: attributes['versionName'],
    buildNumber: attributes['versionCode'],
    source: entry,
  );
}

/// What an `.ipa` says about itself.
///
/// The `Info.plist` inside is a *binary* plist, so this asks `plutil` rather
/// than parsing one. Apple artifacts are only ever produced on macOS, which is
/// the only place `plutil` exists and the only place an `.ipa` is built — so
/// the tool is present wherever the question can be asked.
BakedFacts readIpaFacts(String path) {
  final name = path.split('/').last;
  final ProcessResult listing;
  try {
    listing = Process.runSync('unzip', [
      '-Z1',
      path,
      'Payload/*.app/Info.plist',
    ]);
  } on ProcessException catch (e) {
    throw ReleaseException(
      'cannot cross-check $name: unzip is not available (${e.message})',
    );
  }
  // 11 is "no matching files" — the archive listed fine and holds no such
  // entry, which the `entry == null` branch below says precisely. Anything
  // else means it could not be read as an archive at all.
  // 1 is warnings with the listing still produced; 11 is "no matching files",
  // which the `entry == null` branch below reports precisely.
  if (listing.exitCode != 0 &&
      listing.exitCode != 1 &&
      listing.exitCode != 11) {
    throw ReleaseException(
      'cannot cross-check $name: it could not be read as an archive '
      '(unzip exit ${listing.exitCode})',
    );
  }
  final entry = const LineSplitter()
      .convert(listing.stdout as String)
      .map((l) => l.trim())
      .where((l) => l.endsWith('.app/Info.plist'))
      .firstOrNull;
  if (entry == null) {
    throw ReleaseException(
      'cannot cross-check $name: it carries no Payload/*.app/Info.plist, so '
      'it is not an ipa whatever it is named',
    );
  }
  final plist = _zipEntry(path, entry);

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

    // Neither key present is "the plist carried neither" — reported as taken on
    // trust, naming this plist — and not "no reader for ipa".
    final version = extract('CFBundleShortVersionString');
    final build = extract('CFBundleVersion');
    return BakedFacts(versionName: version, buildNumber: build, source: entry);
  } finally {
    temporary.deleteSync(recursive: true);
  }
}

/// The bundle a `.pkg` component names as the one it is versioned by, and the
/// two values the installer recorded for it.
class PkgRootBundle {
  const PkgRootBundle({
    required this.path,
    required this.versionName,
    required this.buildNumber,
  });

  /// Where the bundle sits in the payload, e.g. `./Runner.app`.
  ///
  /// Carried into [BakedFacts.source] rather than dropped, because a package
  /// describes *every* bundle it installs and the cross-check line has to say
  /// which one answered — see [readPackageInfoRootBundle] for what goes wrong
  /// when it does not.
  final String path;

  /// `CFBundleShortVersionString`, as the installer recorded it.
  final String? versionName;

  /// `CFBundleVersion`, as the installer recorded it.
  final String? buildNumber;
}

/// The root bundle a component package's `PackageInfo` designates, or null when
/// it designates none — a component carrying only scripts, which is a real
/// thing for a package to hold and not an error.
///
/// **A package describes every bundle it installs, and only one of them is the
/// app.** Measured on a package built from a Flutter-shaped `.app` — an
/// embedded `FlutterMacOS.framework` and a login-item helper — `pkgbuild`
/// wrote three `<bundle>` elements, and the app's was neither the first nor the
/// last:
///
/// ```xml
/// <bundle path="./Runner.app/Contents/Library/LoginItems/Helper.app"
///         id="…helper" CFBundleShortVersionString="9.9.9" CFBundleVersion="777"/>
/// <bundle path="./Runner.app/Contents/Frameworks/FlutterMacOS.framework"
///         id="io.flutter.flutter.macos" CFBundleShortVersionString="3.24.0" CFBundleVersion="1"/>
/// <bundle path="./Runner.app" id="…" CFBundleShortVersionString="1.1.0" CFBundleVersion="65"/>
/// ```
///
/// So "the first bundle with both attributes" is a framework's version number
/// reported as the build's — a plausible wrong answer of exactly the kind this
/// file exists to prevent, and one that would have compared unequal and refused
/// a correct release.
///
/// **`<bundle-version>` is the answer, because it is the installer's own.** It
/// names the identifier whose version the package is versioned by; the
/// installer reads it to decide whether what is on disk is older. Selecting by
/// it is therefore not a heuristic over the file — it is the file's own
/// designation, and a package that names none is one that claims no app.
///
/// The top-level `Distribution` of a product archive carries the same three
/// `<bundle>` elements with the same attributes, and *without* the
/// `<bundle-version>` marker to pick between them — so it is the worse source
/// despite being the easier one to find, and it is also absent from a flat
/// component package. This reads `PackageInfo` for both reasons.
PkgRootBundle? readPackageInfoRootBundle(String packageInfo) {
  final root = XmlDocument.parse(packageInfo).rootElement;
  if (root.name.local != 'pkg-info') {
    throw FormatException(
      'its root element is <${root.name.local}> rather than <pkg-info>',
    );
  }
  final designated = root
      .getElement('bundle-version')
      ?.findElements('bundle')
      .map((bundle) => bundle.getAttribute('id'))
      .nonNulls
      .toSet();
  if (designated == null || designated.isEmpty) {
    return null;
  }
  if (designated.length > 1) {
    throw FormatException(
      'it names ${designated.length} bundles as the ones it is versioned by '
      '(${designated.join(', ')}), and choosing between them would be a guess',
    );
  }
  final id = designated.single;
  // Direct children only. The identifier appears again inside `<relocate>`,
  // `<upgrade-bundle>` and `<strict-identifier>`, none of which carry the two
  // attributes — a descendant search would find those empty elements and
  // report an app that carries no version at all.
  final described = root
      .findElements('bundle')
      .where((bundle) => bundle.getAttribute('id') == id)
      .toList();
  if (described.length != 1) {
    throw FormatException(
      'it is versioned by the bundle $id and then describes '
      '${described.length} bundles with that identifier, so this is not being '
      'read as the structure it is',
    );
  }
  final bundle = described.single;
  return PkgRootBundle(
    path: bundle.getAttribute('path') ?? id,
    versionName: bundle.getAttribute('CFBundleShortVersionString'),
    buildNumber: bundle.getAttribute('CFBundleVersion'),
  );
}

/// What a `.pkg` says about itself.
///
/// **Nothing here decompresses a payload, and that is what makes the reader
/// small.** The app's `Info.plist` really is several layers down — a xar
/// holding a gzipped cpio holding the bundle — and reaching it is the work this
/// format was priced as and deferred for. It does not have to be reached:
/// `pkgbuild` and `productbuild` copy `CFBundleShortVersionString` and
/// `CFBundleVersion` out of the app and into each component's `PackageInfo`,
/// because the installer compares them against what is already on disk before
/// it will replace it. That file sits in the archive's table of contents,
/// beside the payload rather than inside it.
///
/// Those are therefore the *installer's* record of the app's two values rather
/// than the app's own bytes, which is a weaker reading than the `.ipa`'s and is
/// still the right one: they are written by the packaging step, so the defect
/// class this exists for — a build that did not honor the values it was given —
/// is upstream of them and shows through.
///
/// `xar` is asked rather than a xar decoder written, on [readIpaFacts]'s
/// argument for `plutil`: a `.pkg` is only ever produced on macOS, which is the
/// only place `/usr/bin/xar` exists and the only place one is built.
BakedFacts readPkgFacts(String path) {
  final name = path.split('/').last;
  final ProcessResult listing;
  try {
    listing = Process.runSync('xar', ['-tf', path]);
  } on ProcessException catch (e) {
    throw ReleaseException(
      'cannot cross-check $name: xar is not available (${e.message}), and '
      'without it a package cannot be read at all. There is deliberately no '
      'flag to proceed on trust, because a host that silently stopped checking '
      'is the state this exists to make impossible.',
    );
  }
  if (listing.exitCode != 0) {
    throw ReleaseException(
      'cannot cross-check $name: it could not be read as a xar archive '
      '(xar exit ${listing.exitCode}). Either the file is not the installer '
      'package its extension claims, or it is truncated.',
    );
  }
  // `PackageInfo` at the top of a flat component package, and
  // `<component>.pkg/PackageInfo` in a product archive, which is what an
  // App Store upload is. Both spellings, because the component's name is the
  // packager's choice and cannot be assumed.
  final entries = const LineSplitter()
      .convert(listing.stdout as String)
      .map((line) => line.trim())
      .where((line) => line == 'PackageInfo' || line.endsWith('/PackageInfo'))
      .toList();
  if (entries.isEmpty) {
    throw ReleaseException(
      'cannot cross-check $name: it is a xar archive and carries no '
      'PackageInfo, so it is not an installer package whatever it is named',
    );
  }
  // An entry name comes out of the file under examination and is handed back
  // to xar and joined onto a directory, so a `..` in one would read outside the
  // temporary directory — and there is deliberately no check for it here. xar
  // strips `..` from a path rather than storing it ("Skipping .. in path", on
  // create), so no fixture can be built that reaches such a check, and a guard
  // no test can fail is one that rots into a claim nobody has verified.
  //
  // Only the metadata is extracted — `xar` takes exact member paths, so the
  // payloads stay where they are. As in [readIpaFacts], the members are spilled
  // to a temp directory and removed however this ends, because `xar` has no
  // extract-to-stdout.
  final temporary = Directory.systemTemp.createTempSync('cux_ship_pkg');
  try {
    final extraction = Process.runSync('xar', [
      '-x',
      '-f',
      path,
      '-C',
      temporary.path,
      ...entries,
    ]);
    if (extraction.exitCode != 0) {
      throw ReleaseException(
        'cannot cross-check $name: it lists ${entries.join(', ')} and xar '
        'could not extract them from it (xar exit ${extraction.exitCode})',
      );
    }

    final found = <(String entry, PkgRootBundle bundle)>[];
    for (final entry in entries) {
      final file = File('${temporary.path}/$entry');
      // Reached when the archive holds a *directory* by that name, which reads
      // back as an unhandled FileSystemException rather than as a sentence if
      // the read is simply attempted — the shape the apk reader's RangeError
      // catch exists for, one format over.
      if (!file.existsSync()) {
        throw ReleaseException(
          'cannot cross-check $name: xar listed $entry and produced no file to '
          'read for it — it is a directory in the archive, or the extraction '
          'wrote nothing',
        );
      }
      final PkgRootBundle? bundle;
      try {
        bundle = readPackageInfoRootBundle(file.readAsStringSync());
      } on FormatException catch (e) {
        // As in [readAabFacts]: a component this cannot walk is news, and
        // reporting "no reader for pkg" would file it under the trusted-loudly
        // case, which is a much quieter thing.
        throw ReleaseException(
          'could not read $entry out of $name: ${e.message}',
        );
      }
      if (bundle != null) {
        found.add((entry, bundle));
      }
    }

    if (found.isEmpty) {
      throw ReleaseException(
        'cannot cross-check $name: none of its ${entries.length} component'
        '${entries.length == 1 ? '' : 's'} names a bundle it is versioned by, '
        'so nothing in it claims to be the app this manifest describes',
      );
    }
    if (found.length > 1) {
      throw ReleaseException(
        'cannot cross-check $name: it installs '
        '${found.map((f) => f.$2.path).join(' and ')}, and which of them the '
        'manifest describes is not something this can decide. An App Store '
        'package installs one app; check what built this one.',
      );
    }
    final (entry, bundle) = found.single;
    // Neither attribute present is "the installer recorded neither" — reported
    // as taken on trust, naming this component — and not "no reader for pkg".
    // Unlike the two Android walks there is no place to lose: the element was
    // located by the identifier the file itself designates, so an absent
    // attribute is absent rather than missed.
    return BakedFacts(
      versionName: bundle.versionName,
      buildNumber: bundle.buildNumber,
      source: '$entry (${bundle.path})',
    );
  } finally {
    temporary.deleteSync(recursive: true);
  }
}

/// What an `.apk` says about itself.
BakedFacts readApkFacts(String path) {
  const entry = 'AndroidManifest.xml';
  final axml = _zipEntry(path, entry);
  final Map<String, String> attributes;
  try {
    attributes = readBinaryXmlAttributes(axml, {'versionCode', 'versionName'});
  } on FormatException catch (e) {
    throw ReleaseException(
      'could not read $entry out of ${path.split('/').last}: ${e.message}',
    );
  } on RangeError catch (e) {
    // **`ByteData` throws `RangeError`, not `FormatException`.** Catching only
    // the latter meant a manifest whose declared header size ran past the
    // chunk escaped as an unhandled Dart error — forty frames where the
    // product is one sentence, out of a binary whose exit codes are a
    // documented interface. Every read in the walk is a candidate, so the
    // catch belongs here rather than at each one.
    throw ReleaseException(
      'could not read $entry out of ${path.split('/').last}: it declares '
      'sizes that run past its own bytes ($e). The file is truncated, or it '
      'is not the binary XML it is positioned as.',
    );
  }
  // Both values absent is a different answer from a reader that failed: the
  // manifest parsed and simply carried neither, which `describeCrossCheck`
  // renders as "carried neither value — taken on trust". Returning null here
  // would file it as "no reader for apk" instead, which is a claim about the
  // *format* rather than about this file.
  return BakedFacts(
    versionName: attributes['versionName'],
    buildNumber: attributes['versionCode'],
    source: entry,
  );
}

/// What [artifactPath] says about itself, or null when its format has no
/// reader.
///
/// **Null means "no reader exists for this format", and nothing else.** It is a
/// real answer the caller must report: `dmg`, `msix`, `snap`, `deb` and plain
/// archives are trusted, and saying so is what keeps "not checked" from reading
/// like "checked and fine".
///
/// A reader that *exists and fails* throws instead, and that distinction is the
/// point. Both rendered as null once — so a missing `unzip`, a truncated
/// download or an entry that is not where it should be all printed "no reader
/// for apk" on a build host where the reader was present and working
/// everywhere else. The cross-check would then be skipped for the rest of that
/// machine's life, in a sentence that reads like ordinary operation.
BakedFacts? readBakedFacts(String artifactPath, String? format) =>
    switch (format) {
      'aab' => readAabFacts(artifactPath),
      'apk' => readApkFacts(artifactPath),
      'ipa' => readIpaFacts(artifactPath),
      'pkg' => readPkgFacts(artifactPath),
      _ => null,
    };
