// Uploads a signed .aab, a store listing, or both, to Google Play.
//
//   dart run play_upload --aab dist/android/x.aab --package design.codeux.holdthewheel \
//     --build-number 12 --version-name 1.0.0 --track internal [--dry-run]
//
// Invoked by tool/upload.sh, which has already checked the manifest, the
// artifact digest and the provenance rules. This program does the API work and
// nothing else — everything it needs arrives as an argument or, for the service
// account, as an environment variable. It knows nothing about SOPS or manifests.
//
// The Play edit is a transaction: open one, attach a bundle, point a track at
// it, commit. Nothing is visible to anyone until the commit, which is what
// makes --dry-run genuinely safe — it does every step and then deletes the edit
// instead of committing it.
//
// --metadata publishes the store listing from a directory tree, described in
// store/play/README.md. It rides the same transaction as the bundle, so a
// release and the listing that describes it go live together or not at all.
// Every argument is independent, so listing-only pushes need no artifact:
//
//   dart run play_upload --package design.codeux.holdthewheel \
//     --metadata ../../store/play --dry-run
//
// --list-tracks is the read side, and the only way to confirm a publish
// independently of the run that claims to have done it. It needs nothing but
// --package, and touches none of the above:
//
//   dart run play_upload --list-tracks --package design.codeux.holdthewheel
//
// What is *not* here is everything Play has no API for: the privacy policy URL,
// the IARC content rating questionnaire, the app category, target audience, and
// the rest of "App content". Those are set once in the console by hand. The
// dividing line is not arbitrary — none of them are per-release state, so
// nothing in a normal release touches them.
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:googleapis/androidpublisher/v3.dart';
import 'package:googleapis_auth/auth_io.dart';

const _serviceAccountVar = 'GOOGLE_PLAY_SERVICE_ACCOUNT_JSON';

Never _fail(String message) {
  stderr.writeln('play_upload: $message');
  exit(1);
}

/// Aborts something discovered *inside* the edit transaction.
///
/// Not [_fail], which calls `exit()` and so unwinds nothing: the `finally` that
/// abandons a half-built edit would never run, and the failure would leave a
/// stale draft in the console. Everything reachable before the edit is opened
/// can still use [_fail].
class _Abort implements Exception {
  _Abort(this.message);

  final String message;
}

/// Passed as JSON in the environment rather than a path, because that is what
/// tool/with-secrets.sh can supply without writing a credential to disk.
ServiceAccountCredentials _loadCredentials() {
  final raw = Platform.environment[_serviceAccountVar];
  if (raw == null || raw.trim().isEmpty) {
    _fail(
      '$_serviceAccountVar is not set.\n'
      '  It holds the Google Play service account JSON. Run this through\n'
      '  tool/with-secrets.sh, or export it yourself.',
    );
  }
  try {
    return ServiceAccountCredentials.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
  } on FormatException catch (e) {
    _fail('$_serviceAccountVar is not valid JSON: ${e.message}');
  }
}

/// Sent with a plain POST rather than through `api.applications.dataSafety`,
/// which cannot handle this endpoint: Play answers a successful declaration with
/// `204 No Content`, and the generated wrapper casts the body to a Map — so a
/// success arrives as `type 'Null' is not a subtype of type Map<String, dynamic>`
/// and an accepted declaration looks exactly like a crash.
///
/// Going direct also surfaces Play's rejection text in full. Its validation
/// gates questions on other answers, undocumented, one complaint at a time, and
/// that text is the only way to find out which cell it objects to.
Future<void> _publishDataSafety(
  AuthClient client,
  String packageName,
  String csv,
) async {
  final response = await client.post(
    Uri.parse(
      'https://androidpublisher.googleapis.com/androidpublisher/v3/'
      'applications/$packageName/dataSafety',
    ),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({'safetyLabels': csv}),
  );
  if (response.statusCode != 200 && response.statusCode != 204) {
    throw _Abort(
      'data safety declaration rejected (${response.statusCode}):\n'
      '${response.body}',
    );
  }
}

/// Reads back what Play actually has, rather than what a previous run reported
/// having sent. Reading tracks needs an edit even though nothing is modified,
/// so the edit is discarded immediately afterwards.
Future<void> _listTracks(AndroidPublisherApi api, String packageName) async {
  String? editId;
  try {
    editId = (await api.edits.insert(AppEdit(), packageName)).id;
    if (editId == null) {
      _fail('Play did not return an edit id');
    }
    for (final t
        in (await api.edits.tracks.list(packageName, editId)).tracks ??
            <Track>[]) {
      final releases = t.releases ?? <TrackRelease>[];
      if (releases.isEmpty) {
        stdout.writeln('  ${t.track}: (empty)');
      }
      for (final r in releases) {
        stdout.writeln(
          '  ${t.track}: "${r.name}" codes=${r.versionCodes} ${r.status}',
        );
      }
    }
    final bundles =
        (await api.edits.bundles.list(packageName, editId)).bundles ??
        <Bundle>[];
    stdout.writeln(
      '  uploaded bundles: ${bundles.map((b) => b.versionCode).toList()}',
    );
  } on DetailedApiRequestError catch (e) {
    stderr.writeln('play_upload: Play API error ${e.status}: ${e.message}');
    exitCode = 1;
  } finally {
    if (editId != null) {
      await api.edits.delete(packageName, editId);
    }
  }
}

// ------------------------------------------------------------------ metadata

/// Play's limits on the listing text, which it enforces only *after* the
/// bundle has been uploaded.
///
/// Counted in UTF-16 code units rather than characters, which over-counts
/// anything outside the BMP. Wrong in the safe direction: it rejects here,
/// where the fix is free, rather than at Play after a 45 MB upload.
const _textLimits = {
  'title': 30,
  'shortDescription': 80,
  'fullDescription': 4000,
};

/// What Play accepts for one `AppImageType`.
class _ImageSpec {
  const _ImageSpec(
    this.minCount,
    this.maxCount, {
    this.exactWidth,
    this.exactHeight,
    this.minSide,
    this.maxSide,
  });

  final int minCount;
  final int maxCount;

  /// Set for the fixed-size slots, where Play takes one exact resolution and
  /// rejects everything else.
  final int? exactWidth;
  final int? exactHeight;

  /// Set for screenshots, where any size within the band is allowed.
  final int? minSide;
  final int? maxSide;
}

/// Keyed by `AppImageType` as the API spells it, because these names are also
/// the directory names in the metadata tree — so a typo is caught by the map
/// lookup rather than by Play.
const _imageSpecs = <String, _ImageSpec>{
  'icon': _ImageSpec(1, 1, exactWidth: 512, exactHeight: 512),
  'featureGraphic': _ImageSpec(1, 1, exactWidth: 1024, exactHeight: 500),
  'tvBanner': _ImageSpec(1, 1, exactWidth: 1280, exactHeight: 720),
  'phoneScreenshots': _ImageSpec(2, 8, minSide: 320, maxSide: 3840),
  'sevenInchScreenshots': _ImageSpec(2, 8, minSide: 320, maxSide: 3840),
  'tenInchScreenshots': _ImageSpec(2, 8, minSide: 320, maxSide: 3840),
  'wearScreenshots': _ImageSpec(2, 8, minSide: 320, maxSide: 3840),
  'tvScreenshots': _ImageSpec(2, 8, minSide: 320, maxSide: 3840),
};

/// One locale's store listing: its text, and the images that belong to it.
class _LocaleMetadata {
  _LocaleMetadata(this.locale);

  final String locale;

  /// Keyed by [Listing] field name. Empty when the locale carries images only.
  final Map<String, String> text = {};
  String? video;

  /// `AppImageType` -> the files to publish, in the order Play should show
  /// them. Only types with a directory present appear at all.
  final Map<String, List<File>> images = {};
}

class _Metadata {
  /// Keyed by [AppDetails] field name.
  final Map<String, String> details = {};
  final List<_LocaleMetadata> locales = [];
}

String _basename(String path) => path.split(Platform.pathSeparator).last;

/// Reads `<name>.txt` from [dir], trimmed. Null when the file is absent, which
/// is how a single field opts out of being managed from the repository.
String? _readField(Directory dir, String name) {
  final f = File('${dir.path}${Platform.pathSeparator}$name.txt');
  return f.existsSync() ? f.readAsStringSync().trim() : null;
}

/// Loads and fully validates the metadata tree, before any network call.
///
/// The rule throughout is **present means owned**: a file or directory that
/// exists in the tree replaces what Play holds, and one that does not is left
/// alone. That is what makes it safe to keep a partial tree in the repository —
/// a locale nobody has translated, or a form factor with no screenshots yet, is
/// not silently deleted from the live listing on the next release.
_Metadata _loadMetadata(String path) {
  final root = Directory(path);
  if (!root.existsSync()) {
    _fail('no such metadata directory: $path');
  }

  final meta = _Metadata();

  const detailFields = {
    'default_language': 'defaultLanguage',
    'contact_email': 'contactEmail',
    'contact_phone': 'contactPhone',
    'contact_website': 'contactWebsite',
  };
  final details = Directory('${root.path}${Platform.pathSeparator}details');
  if (details.existsSync()) {
    for (final field in detailFields.entries) {
      final value = _readField(details, field.key);
      if (value != null && value.isNotEmpty) {
        meta.details[field.value] = value;
      }
    }
  }

  final listings = Directory('${root.path}${Platform.pathSeparator}listings');
  if (listings.existsSync()) {
    final localeDirs = listings.listSync().whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final dir in localeDirs) {
      meta.locales.add(_loadLocale(dir));
    }
  }

  if (meta.details.isEmpty && meta.locales.isEmpty) {
    _fail('$path holds no details/ and no listings/ — nothing to publish');
  }
  return meta;
}

_LocaleMetadata _loadLocale(Directory dir) {
  final locale = _basename(dir.path);
  final meta = _LocaleMetadata(locale);

  const textFields = {
    'title': 'title',
    'short_description': 'shortDescription',
    'full_description': 'fullDescription',
  };
  for (final field in textFields.entries) {
    final value = _readField(dir, field.key);
    if (value == null) {
      continue;
    }
    if (value.isEmpty) {
      _fail(
        '$locale/${field.key}.txt is empty — delete the file rather than '
        'publishing a blank field',
      );
    }
    final limit = _textLimits[field.value]!;
    if (value.length > limit) {
      _fail(
        '$locale/${field.key}.txt is ${value.length} characters; '
        'Play allows $limit',
      );
    }
    meta.text[field.value] = value;
  }

  // listings.update replaces the whole resource, so a tree carrying only a
  // title would blank both descriptions. Caught here rather than mid-edit.
  if (meta.text.isNotEmpty && meta.text.length != textFields.length) {
    final missing = textFields.entries
        .where((e) => !meta.text.containsKey(e.value))
        .map((e) => '${e.key}.txt');
    _fail(
      '$locale is missing ${missing.join(", ")} — a listing carries its title '
      'and both descriptions together, or not at all',
    );
  }

  meta.video = _readField(dir, 'video');

  final images = Directory('${dir.path}${Platform.pathSeparator}images');
  if (images.existsSync()) {
    final typeDirs = images.listSync().whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final typeDir in typeDirs) {
      final type = _basename(typeDir.path);
      final spec = _imageSpecs[type];
      if (spec == null) {
        _fail(
          '$locale/images/$type is not an AppImageType.\n'
          '  Valid names: ${_imageSpecs.keys.join(", ")}',
        );
      }
      meta.images[type] = _loadImages(locale, type, typeDir, spec);
    }
  }

  return meta;
}

List<File> _loadImages(
  String locale,
  String type,
  Directory dir,
  _ImageSpec spec,
) {
  // Play shows screenshots in the order they were uploaded, so the sort order
  // of the filenames is the order on the listing. That is the whole reason the
  // convention is a numeric prefix.
  final files = dir.listSync().whereType<File>().where((f) {
    final name = f.path.toLowerCase();
    return name.endsWith('.png') ||
        name.endsWith('.jpg') ||
        name.endsWith('.jpeg');
  }).toList()..sort((a, b) => a.path.compareTo(b.path));

  if (files.length < spec.minCount || files.length > spec.maxCount) {
    final wanted = spec.minCount == spec.maxCount
        ? 'exactly ${spec.minCount}'
        : '${spec.minCount} to ${spec.maxCount}';
    _fail(
      '$locale/images/$type holds ${files.length} image(s); Play wants $wanted',
    );
  }

  for (final f in files) {
    final name = '$locale/images/$type/${_basename(f.path)}';
    // Only the header is needed, but a screenshot is a few MB at most and
    // reading it whole saves the parser from having to handle a short buffer.
    final size = _imageSize(f.readAsBytesSync());
    if (size == null) {
      _fail('$name is not a readable PNG or JPEG');
    }

    final exactWidth = spec.exactWidth;
    final exactHeight = spec.exactHeight;
    if (exactWidth != null && exactHeight != null) {
      if (size.width != exactWidth || size.height != exactHeight) {
        _fail(
          '$name is ${size.width}x${size.height}; Play requires exactly '
          '${exactWidth}x$exactHeight for $type',
        );
      }
    }

    final minSide = spec.minSide;
    final maxSide = spec.maxSide;
    if (minSide != null && maxSide != null) {
      final shortest = size.width < size.height ? size.width : size.height;
      final longest = size.width < size.height ? size.height : size.width;
      if (shortest < minSide || longest > maxSide) {
        _fail(
          '$name is ${size.width}x${size.height}; Play requires every side of '
          'a screenshot between $minSide and $maxSide pixels',
        );
      }
    }
  }
  return files;
}

int _be16(List<int> b, int o) => (b[o] << 8) | b[o + 1];

int _be32(List<int> b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

/// Dimensions of a PNG or JPEG, or null if [bytes] is neither.
///
/// Hand-rolled rather than a dependency: this reads two integers out of a
/// header, and `package:image` is a decoder for a dozen formats. The check it
/// enables is worth having because Play validates image sizes at commit —
/// after the bundle has already gone up.
({int width, int height})? _imageSize(List<int> bytes) {
  // PNG: IHDR is required to be the first chunk, so the dimensions sit at a
  // fixed offset — 8 signature, 4 length, 4 type, then width and height.
  if (bytes.length >= 24 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return (width: _be32(bytes, 16), height: _be32(bytes, 20));
  }

  // JPEG: walk the marker segments to the start-of-frame, the only one that
  // carries the dimensions.
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
        return (width: _be16(bytes, i + 7), height: _be16(bytes, i + 5));
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

/// Writes the metadata into an already-open edit.
///
/// Everything here rides the same transaction as the bundle, so a listing that
/// Play rejects halfway through leaves the live one untouched rather than
/// half-updated.
Future<void> _publishMetadata(
  AndroidPublisherApi api,
  String packageName,
  String editId,
  _Metadata metadata,
) async {
  if (metadata.details.isNotEmpty) {
    // patch, not update: update replaces the whole resource, so a tree holding
    // only contact_email.txt would blank the website and the phone number.
    await api.edits.details.patch(
      AppDetails(
        defaultLanguage: metadata.details['defaultLanguage'],
        contactEmail: metadata.details['contactEmail'],
        contactPhone: metadata.details['contactPhone'],
        contactWebsite: metadata.details['contactWebsite'],
      ),
      packageName,
      editId,
    );
    stdout.writeln('==> details: ${metadata.details.keys.join(", ")}');
  }

  for (final locale in metadata.locales) {
    if (locale.text.isNotEmpty) {
      await api.edits.listings.update(
        Listing(
          language: locale.locale,
          title: locale.text['title'],
          shortDescription: locale.text['shortDescription'],
          fullDescription: locale.text['fullDescription'],
          video: locale.video,
        ),
        packageName,
        editId,
        locale.locale,
      );
      stdout.writeln('==> ${locale.locale}: listing text');
    }

    for (final entry in locale.images.entries) {
      // upload *adds*. Without clearing first, every run appends, and the
      // listing ends up carrying eight copies of the same three screenshots —
      // at which point the repository is no longer the source of truth.
      await api.edits.images.deleteall(
        packageName,
        editId,
        locale.locale,
        entry.key,
      );
      for (final file in entry.value) {
        await api.edits.images.upload(
          packageName,
          editId,
          locale.locale,
          entry.key,
          uploadMedia: Media(
            file.openRead(),
            file.lengthSync(),
            contentType: file.path.toLowerCase().endsWith('.png')
                ? 'image/png'
                : 'image/jpeg',
          ),
        );
      }
      stdout.writeln(
        '==> ${locale.locale}: ${entry.value.length} ${entry.key}',
      );
    }
  }
}

Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('aab', help: 'Path to the signed app bundle.')
    ..addOption(
      'package',
      help: 'applicationId, e.g. design.codeux.holdthewheel.',
    )
    ..addOption(
      'build-number',
      help: 'Expected versionCode; verified against the bundle.',
    )
    ..addOption(
      'version-name',
      help: 'Used only to name the release in the console.',
    )
    ..addOption('track', defaultsTo: 'internal')
    ..addOption(
      'status',
      defaultsTo: 'completed',
      help: 'completed | draft | inProgress',
    )
    ..addOption(
      'release-notes',
      help: 'Optional file whose contents become the en-GB notes.',
    )
    ..addOption(
      'metadata',
      help: 'Directory of store listing text and images to publish.',
    )
    ..addOption(
      'data-safety',
      help: 'CSV of Data Safety answers, exported from the console.',
    )
    ..addFlag('dry-run', negatable: false, help: 'Do everything except commit.')
    ..addFlag(
      'list-tracks',
      negatable: false,
      help:
          'Print what Play currently has on each track, and exit. '
          'Needs only --package.',
    )
    ..addFlag('help', abbr: 'h', negatable: false);

  final args = parser.parse(argv);
  if (args.flag('help')) {
    stdout.writeln(parser.usage);
    return;
  }

  // --package is the one argument both modes need, so it is checked before the
  // split; the upload-only arguments are checked after, where they apply.
  final packageName = args.option('package');
  if (packageName == null) {
    _fail('--package is required\n${parser.usage}');
  }

  // Reading needs nothing else, so it goes before the upload path's checks and
  // builds its own client.
  if (args.flag('list-tracks')) {
    final client = await clientViaServiceAccount(_loadCredentials(), [
      AndroidPublisherApi.androidpublisherScope,
    ]);
    await _listTracks(AndroidPublisherApi(client), packageName);
    client.close();
    return;
  }

  final aabPath = args.option('aab');
  final buildNumber = args.option('build-number');
  final metadataPath = args.option('metadata');
  final dataSafetyPath = args.option('data-safety');

  // The three jobs are independent, so any one of them alone is a valid run —
  // a listing typo should not need an artifact to fix. Requiring at least one
  // stops a no-argument invocation from opening and committing an empty edit,
  // which succeeds and does nothing.
  if (aabPath == null && metadataPath == null && dataSafetyPath == null) {
    _fail(
      'nothing to do — pass --aab, --metadata or --data-safety\n${parser.usage}',
    );
  }

  int? expectedVersionCode;
  File? aab;
  if (aabPath != null) {
    if (buildNumber == null) {
      _fail('--aab also needs --build-number\n${parser.usage}');
    }
    expectedVersionCode = int.tryParse(buildNumber);
    if (expectedVersionCode == null) {
      _fail('--build-number must be an integer, got "$buildNumber"');
    }
    aab = File(aabPath);
    if (!aab.existsSync()) {
      _fail('no such file: $aabPath');
    }
  }

  // Read and validated before the credentials are even parsed. A 4001-character
  // description costs nothing to catch here and a full bundle upload to catch
  // at Play, so everything that can be checked locally is checked first.
  final metadata = metadataPath == null ? null : _loadMetadata(metadataPath);

  String? dataSafetyCsv;
  if (dataSafetyPath != null) {
    final f = File(dataSafetyPath);
    if (!f.existsSync()) {
      _fail('no such data safety CSV: $dataSafetyPath');
    }
    dataSafetyCsv = f.readAsStringSync();
    if (dataSafetyCsv.trim().isEmpty) {
      _fail('$dataSafetyPath is empty');
    }
  }

  final dryRun = args.flag('dry-run');
  final track = args.option('track')!;
  final versionName = args.option('version-name') ?? buildNumber ?? '';

  String? releaseNotes;
  final notesPath = args.option('release-notes');
  if (notesPath != null) {
    final f = File(notesPath);
    if (!f.existsSync()) {
      _fail('no such release notes file: $notesPath');
    }
    releaseNotes = f.readAsStringSync().trim();
    // Play rejects notes over 500 characters for a release, and does so after
    // the bundle has already been uploaded.
    if (releaseNotes.length > 500) {
      _fail(
        'release notes are ${releaseNotes.length} characters; Play allows 500',
      );
    }
  }

  // Built only once every local check has passed, so a 4001-character
  // description or a missing screenshot fails with no credential in scope at
  // all — which is what makes `--metadata` usable as an offline lint.
  final client = await clientViaServiceAccount(_loadCredentials(), [
    AndroidPublisherApi.androidpublisherScope,
  ]);
  final api = AndroidPublisherApi(client);

  String? editId;

  try {
    final edit = await api.edits.insert(AppEdit(), packageName);
    editId = edit.id;
    if (editId == null) {
      _fail('Play did not return an edit id');
    }
    stdout.writeln('==> opened edit $editId');

    // What the commit line will say it did. Empty when this run carries no
    // artifact, which is a listing-only push.
    var released = '';

    if (aab != null) {
      // Resumable rather than a single PUT: this is tens of megabytes, and a
      // simple upload that fails at 90% has to start over. Resumable also
      // retries with exponential backoff on its own.
      final media = Media(
        aab.openRead(),
        aab.lengthSync(),
        contentType: 'application/octet-stream',
      );
      stdout.writeln('==> uploading ${aab.lengthSync()} bytes');
      final bundle = await api.edits.bundles.upload(
        packageName,
        editId,
        uploadMedia: media,
        uploadOptions: UploadOptions.resumable,
      );

      final versionCode = bundle.versionCode;
      stdout.writeln('==> Play accepted versionCode $versionCode');

      // The versionCode is baked into the bundle at build time from
      // --build-number. If Play reports a different one, the artifact is not
      // the one that was just built, and assigning it to a track would publish
      // something nobody verified.
      if (versionCode != expectedVersionCode) {
        throw _Abort(
          'versionCode mismatch: the bundle contains $versionCode but the build '
          'says $expectedVersionCode.\n'
          '  dist/ is stale, or the .aab was built from a different commit.',
        );
      }

      await api.edits.tracks.update(
        Track(
          track: track,
          releases: [
            TrackRelease(
              name: '$versionName ($versionCode)',
              versionCodes: ['$versionCode'],
              status: args.option('status'),
              releaseNotes: releaseNotes == null
                  ? null
                  : [LocalizedText(language: 'en-GB', text: releaseNotes)],
            ),
          ],
        ),
        packageName,
        editId,
        track,
      );
      stdout.writeln(
        '==> assigned to track "$track" (${args.option('status')})',
      );
      released = '$versionName ($versionCode) is on "$track"';
    }

    if (metadata != null) {
      await _publishMetadata(api, packageName, editId, metadata);
    }

    if (dryRun) {
      await api.edits.delete(packageName, editId);
      editId = null;
      stdout.writeln('==> dry run — edit discarded, nothing published');
      if (dataSafetyCsv != null) {
        stdout.writeln('==> dry run — data safety declaration not sent');
      }
      return;
    }

    await api.edits.commit(packageName, editId);
    editId = null;
    stdout.writeln(
      '==> committed — ${released.isEmpty ? "store listing updated" : released}',
    );

    // A different API from the edit, and deliberately after the commit. The
    // declaration is not versioned with a release and applies to the app as a
    // whole, so sending it first would change what Play shows users even if the
    // edit then failed to commit and the release never happened.
    if (dataSafetyCsv != null) {
      await _publishDataSafety(client, packageName, dataSafetyCsv);
      stdout.writeln('==> data safety declaration updated');
    }
  } on _Abort catch (e) {
    stderr.writeln('play_upload: ${e.message}');
    exitCode = 1;
  } on DetailedApiRequestError catch (e) {
    // Deliberately not _fail: that calls exit(), which terminates the process
    // without unwinding, so the finally below would never run and every failed
    // upload would leave an open edit behind. Record the failure, let cleanup
    // happen, and exit with the code once main returns.
    stderr.writeln('play_upload: Play API error ${e.status}: ${e.message}');

    // The resumable uploader reports only the transport status and discards
    // Play's response body, so a 403 arrives with no reason attached. Listed
    // most-likely first. Opening the edit succeeded in every case here, so the
    // account can at least see the app — it is a per-permission problem, not a
    // wrong service account.
    if (e.status == 403 && aab != null) {
      // The first is easy to hit: a build number is allocated per commit, so
      // rebuilding without committing re-sends a versionCode Play already has.
      stderr.writeln(
        '  A 403 with a bundle in the edit, in order of likelihood:\n'
        '  - versionCode $expectedVersionCode already exists for this app. Play\n'
        '    never accepts one twice, including one uploaded by hand. Commit and\n'
        '    rebuild to allocate the next number.\n'
        '  - the service account lacks "Release to testing tracks" for this app\n'
        '    (Play Console > Users and permissions > App permissions).\n'
        '  - the app has never had a release; Play requires the first bundle for\n'
        '    a package to be uploaded by hand in the console.',
      );
    } else if (e.status == 403) {
      stderr.writeln(
        '  A 403 on a listing-only push is almost always the service account\n'
        '  lacking "Manage store presence" for this app (Play Console > Users\n'
        '  and permissions > App permissions). It is a separate grant from the\n'
        '  release permission, so an account that can ship a build can still be\n'
        '  unable to edit the listing.',
      );
    }
    exitCode = 1;
  } finally {
    // An edit left open is harmless — Play expires them — but leaving one
    // behind means the next run sees a stale draft in the console for no
    // reason. Only reached when something threw before commit or delete.
    if (editId != null) {
      try {
        await api.edits.delete(packageName, editId);
        stdout.writeln('==> abandoned edit $editId');
      } catch (_) {
        // Losing the cleanup is not worth masking the original failure.
      }
    }
    client.close();
  }
}
