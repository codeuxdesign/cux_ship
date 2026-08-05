// Loads and fully validates the store/appstore/ tree, with no network access
// and no credentials in scope.
//
// That property is the point, and it is the same one tool/play_upload has: a
// 4001-character description costs nothing to catch here and a full upload to
// catch at the store, so `--metadata --dry-run` is usable as an offline lint
// that anybody can run on a laptop with no secrets at all.
//
// The standing rule is **present means owned**: a file or directory that exists
// replaces what App Store Connect holds, and one that does not is left alone.
// That is what makes a partial tree safe to keep in the repository — a locale
// nobody has translated, or a device size with no screenshots yet, is not
// silently wiped from the live listing on the next release.
import 'dart:convert';
import 'dart:io';

/// Thrown for anything wrong with the tree. Always actionable: it names the
/// file and says what would have to be true instead.
class MetadataException implements Exception {
  MetadataException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// App Store Connect's limits on the listing text, in UTF-16 code units.
///
/// Over-counts anything outside the BMP, which is wrong in the safe direction:
/// it rejects here, where the fix is free, rather than at Apple after the
/// screenshots have already gone up. Emoji are the case that makes this
/// non-theoretical, and CHANGELOG.md is full of them.
const appInfoLimits = <String, int>{'name': 30, 'subtitle': 30};

const versionLimits = <String, int>{
  'description': 4000,
  'keywords': 100,
  'promotionalText': 170,
};

/// URLs are capped too, and Apple rejects the whole localization rather than
/// the offending field.
const urlLimit = 255;

/// The pixel sizes Apple accepts for one `ScreenshotDisplayType`.
///
/// Several display types take more than one size because Apple folded newer
/// devices into an existing slot rather than adding one — the 6.9" iPhone
/// publishes through `APP_IPHONE_67`, and the 13" iPad through
/// `APP_IPAD_PRO_3GEN_129`. That is also why hardcoding a single "correct"
/// size would be wrong.
///
/// Landscape is accepted as the transpose of each entry, so it is not listed
/// twice.
///
/// **Apple is the authority, not this table.** It is a convenience check drawn
/// from Apple's screenshot specifications, and if a size is missing the error
/// says so plainly rather than claiming the file is invalid:
/// https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications/
class ScreenshotSpec {
  const ScreenshotSpec(this.label, this.portraitSizes);

  /// How Apple names this slot in the console, for error messages — the API
  /// enum on its own tells nobody which device they need.
  final String label;

  final List<({int width, int height})> portraitSizes;

  bool accepts(int width, int height) => portraitSizes.any(
    (s) =>
        (width == s.width && height == s.height) ||
        (width == s.height && height == s.width),
  );

  String get sizesDescription =>
      portraitSizes.map((s) => '${s.width}x${s.height}').join(' or ');
}

/// Keyed by `ScreenshotDisplayType` as the API spells it, because these names
/// are also the directory names in the tree — so a typo fails this lookup
/// rather than being uploaded into the wrong slot, or silently ignored.
///
/// Only the types this app could plausibly use are listed. Add one when it is
/// needed; `asc_upload --list-screenshot-types` reads back what App Store
/// Connect actually holds for the app, which is the way to check a name rather
/// than guessing at it.
const screenshotSpecs = <String, ScreenshotSpec>{
  'APP_IPHONE_67': ScreenshotSpec('iPhone 6.9" / 6.7"', [
    (width: 1320, height: 2868),
    (width: 1290, height: 2796),
  ]),
  'APP_IPHONE_65': ScreenshotSpec('iPhone 6.5"', [
    (width: 1284, height: 2778),
    (width: 1242, height: 2688),
  ]),
  'APP_IPHONE_61': ScreenshotSpec('iPhone 6.1"', [
    (width: 1206, height: 2622),
    (width: 1179, height: 2556),
  ]),
  'APP_IPAD_PRO_3GEN_129': ScreenshotSpec('iPad 13" / 12.9"', [
    (width: 2064, height: 2752),
    (width: 2048, height: 2732),
  ]),
  'APP_IPAD_PRO_129': ScreenshotSpec('iPad Pro 12.9" (2nd gen)', [
    (width: 2048, height: 2732),
  ]),
  // For the Mac App Store build, which is coming. Apple takes any of four
  // sizes here, all 16:10.
  'APP_DESKTOP': ScreenshotSpec('Mac', [
    (width: 2880, height: 1800),
    (width: 2560, height: 1600),
    (width: 1440, height: 900),
    (width: 1280, height: 800),
  ]),
};

/// Apple takes 1 to 10 screenshots per display type.
const minScreenshots = 1;
const maxScreenshots = 10;

/// One locale's listing.
///
/// Apple splits it across two resources that are updated separately and have
/// different lifetimes, and the split is not cosmetic: [appInfo] fields belong
/// to the app and can only be edited while a version is editable, whereas
/// [version] fields belong to the version being prepared. Keeping them apart
/// here means the uploader never has to guess which endpoint a field goes to.
class LocaleMetadata {
  LocaleMetadata(this.locale);

  final String locale;

  /// `appInfoLocalizations` attributes: name, subtitle, privacyPolicyUrl.
  final Map<String, String> appInfo = {};

  /// `appStoreVersionLocalizations` attributes: description, keywords,
  /// promotionalText, supportUrl, marketingUrl.
  ///
  /// `whatsNew` is deliberately absent — release notes come from CHANGELOG.md
  /// and are per-release rather than part of the listing, exactly as on the
  /// Play side.
  final Map<String, String> version = {};

  /// `ScreenshotDisplayType` -> the files to publish, in the order Apple should
  /// show them. Only types with a directory present appear at all.
  final Map<String, List<File>> screenshots = {};

  bool get isEmpty => appInfo.isEmpty && version.isEmpty && screenshots.isEmpty;
}

class AppStoreMetadata {
  /// `appInfos` relationships: primaryCategory, secondaryCategory. Values are
  /// `appCategories` ids such as `HEALTH_AND_FITNESS`.
  final Map<String, String> categories = {};

  final List<LocaleMetadata> locales = [];

  /// `ageRatingDeclarations` attributes, straight from age-rating.json.
  Map<String, Object?>? ageRating;
}

String _basename(String path) => path.split(Platform.pathSeparator).last;

/// Reads `<name>.txt` from [dir], trimmed. Null when the file is absent, which
/// is how a single field opts out of being managed from the repository.
String? _readField(Directory dir, String name) {
  final file = File('${dir.path}${Platform.pathSeparator}$name.txt');
  return file.existsSync() ? file.readAsStringSync().trim() : null;
}

void _checkLength(String locale, String fileName, String value, int limit) {
  if (value.length > limit) {
    throw MetadataException(
      '$locale/$fileName is ${value.length} characters; the App Store allows '
      '$limit',
    );
  }
}

/// Loads and fully validates the tree rooted at [path].
AppStoreMetadata loadMetadata(String path) {
  final root = Directory(path);
  if (!root.existsSync()) {
    throw MetadataException('no such metadata directory: $path');
  }

  final metadata = AppStoreMetadata();
  final separator = Platform.pathSeparator;

  final info = Directory('${root.path}${separator}info');
  if (info.existsSync()) {
    const categoryFields = {
      'primary_category': 'primaryCategory',
      'secondary_category': 'secondaryCategory',
    };
    for (final field in categoryFields.entries) {
      final value = _readField(info, field.key);
      if (value != null && value.isNotEmpty) {
        // Apple's ids are SCREAMING_SNAKE_CASE and a lowercase one is silently
        // ignored rather than rejected, which is the worst of both.
        if (value != value.toUpperCase()) {
          throw MetadataException(
            'info/${field.key}.txt is "$value"; App Store category ids are '
            'upper case, e.g. HEALTH_AND_FITNESS',
          );
        }
        metadata.categories[field.value] = value;
      }
    }
  }

  final ageRating = File('${root.path}${separator}age-rating.json');
  if (ageRating.existsSync()) {
    metadata.ageRating = _loadAgeRating(ageRating);
  }

  final listings = Directory('${root.path}${separator}listings');
  if (listings.existsSync()) {
    final localeDirs = listings.listSync().whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final dir in localeDirs) {
      final locale = _loadLocale(dir);
      if (!locale.isEmpty) {
        metadata.locales.add(locale);
      }
    }
  }

  if (metadata.categories.isEmpty &&
      metadata.locales.isEmpty &&
      metadata.ageRating == null) {
    throw MetadataException(
      '$path holds no info/, no listings/ and no age-rating.json — nothing to '
      'publish',
    );
  }
  return metadata;
}

LocaleMetadata _loadLocale(Directory dir) {
  final locale = _basename(dir.path);
  final metadata = LocaleMetadata(locale);

  const appInfoFields = {'name': 'name', 'subtitle': 'subtitle'};
  for (final field in appInfoFields.entries) {
    final value = _readField(dir, field.key);
    if (value == null) {
      continue;
    }
    if (value.isEmpty) {
      throw MetadataException(
        '$locale/${field.key}.txt is empty — delete the file rather than '
        'publishing a blank field',
      );
    }
    _checkLength(
      locale,
      '${field.key}.txt',
      value,
      appInfoLimits[field.value]!,
    );
    metadata.appInfo[field.value] = value;
  }

  const versionFields = {
    'description': 'description',
    'keywords': 'keywords',
    'promotional_text': 'promotionalText',
  };
  for (final field in versionFields.entries) {
    final value = _readField(dir, field.key);
    if (value == null) {
      continue;
    }
    if (value.isEmpty) {
      throw MetadataException(
        '$locale/${field.key}.txt is empty — delete the file rather than '
        'publishing a blank field',
      );
    }
    _checkLength(
      locale,
      '${field.key}.txt',
      value,
      versionLimits[field.value]!,
    );
    metadata.version[field.value] = value;
  }

  const urlFields = {
    'privacy_policy_url': ('privacyPolicyUrl', true),
    'support_url': ('supportUrl', false),
    'marketing_url': ('marketingUrl', false),
  };
  for (final field in urlFields.entries) {
    final value = _readField(dir, field.key);
    if (value == null) {
      continue;
    }
    final parsed = Uri.tryParse(value);
    if (parsed == null || !parsed.isScheme('https')) {
      // http is accepted by Apple and then flagged in review, which is a slow
      // way to learn about a typo.
      throw MetadataException(
        '$locale/${field.key}.txt is "$value"; it has to be an https URL',
      );
    }
    _checkLength(locale, '${field.key}.txt', value, urlLimit);
    final (attribute, isAppInfo) = field.value;
    if (isAppInfo) {
      metadata.appInfo[attribute] = value;
    } else {
      metadata.version[attribute] = value;
    }
  }

  // Apple requires a name before a version can be submitted, and a listing
  // carrying a subtitle but no name is a half-written tree rather than a
  // deliberate partial one.
  if (metadata.appInfo.containsKey('subtitle') &&
      !metadata.appInfo.containsKey('name')) {
    throw MetadataException(
      '$locale has subtitle.txt but no name.txt — a listing carries its name '
      'first',
    );
  }

  final screenshots = Directory(
    '${dir.path}${Platform.pathSeparator}screenshots',
  );
  if (screenshots.existsSync()) {
    final typeDirs = screenshots.listSync().whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final typeDir in typeDirs) {
      final type = _basename(typeDir.path);
      final spec = screenshotSpecs[type];
      if (spec == null) {
        throw MetadataException(
          '$locale/screenshots/$type is not a ScreenshotDisplayType this tool '
          'knows.\n'
          '  Known names: ${screenshotSpecs.keys.join(", ")}\n'
          '  Run `asc_upload --list-screenshot-types` to see what App Store '
          'Connect holds.',
        );
      }
      metadata.screenshots[type] = _loadScreenshots(
        locale,
        type,
        typeDir,
        spec,
      );
    }
  }

  return metadata;
}

List<File> _loadScreenshots(
  String locale,
  String type,
  Directory dir,
  ScreenshotSpec spec,
) {
  // Apple shows screenshots in the order they were uploaded, so the sort order
  // of the filenames is the order on the listing. That is the whole reason the
  // convention is a numeric prefix — it is load bearing, not decoration.
  final files = dir.listSync().whereType<File>().where((f) {
    final name = f.path.toLowerCase();
    return name.endsWith('.png') ||
        name.endsWith('.jpg') ||
        name.endsWith('.jpeg');
  }).toList()..sort((a, b) => a.path.compareTo(b.path));

  if (files.length < minScreenshots || files.length > maxScreenshots) {
    throw MetadataException(
      '$locale/screenshots/$type holds ${files.length} image(s); Apple takes '
      '$minScreenshots to $maxScreenshots',
    );
  }

  for (final file in files) {
    final name = '$locale/screenshots/$type/${_basename(file.path)}';
    final image = readImageInfo(file.readAsBytesSync());
    if (image == null) {
      throw MetadataException('$name is not a readable PNG or JPEG');
    }

    // Apple rejects any transparency outright — "Images can't contain alpha
    // channels or transparencies" — and every screen capture carries an alpha
    // channel as a matter of course, even when every pixel in it is opaque.
    // `xcrun simctl io screenshot` and the Android emulator both write RGBA.
    // So this is the check most likely to fire and the least visible from
    // looking at the image, and it is worth catching here because Apple
    // catches it only after the file has been uploaded.
    //
    // The remedies are worth spelling out because the obvious one does not
    // work: `sips` re-adds an alpha channel whenever it writes a PNG, whatever
    // flags it is given, so a PNG round trip through it changes nothing.
    if (image.hasAlpha) {
      throw MetadataException(
        '$name has an alpha channel; Apple rejects screenshots with '
        'transparency.\n'
        '  Any of these work:\n'
        '    sips -s format jpeg -s formatOptions best "$name" --out '
        '"${name.replaceAll(RegExp(r'\.png$'), '.jpg')}"\n'
        '        — Apple takes JPEG, which cannot carry alpha at all. No '
        'extra tools.\n'
        '    magick mogrify -alpha off "$name"      (brew install imagemagick)\n'
        '    Preview.app > File > Export, with "Alpha" unticked\n'
        '  Note that `sips` cannot do this while staying PNG: it writes RGBA '
        'regardless.',
      );
    }

    if (!spec.accepts(image.width, image.height)) {
      throw MetadataException(
        '$name is ${image.width}x${image.height}; $type (${spec.label}) takes '
        '${spec.sizesDescription}, in either orientation.\n'
        '  If Apple has added a size, add it to screenshotSpecs in '
        'lib/metadata.dart.',
      );
    }
  }
  return files;
}

/// What a screenshot has to satisfy, read straight out of the file header.
class ImageInfo {
  const ImageInfo({
    required this.width,
    required this.height,
    required this.hasAlpha,
  });

  final int width;
  final int height;
  final bool hasAlpha;
}

int _be16(List<int> bytes, int offset) =>
    (bytes[offset] << 8) | bytes[offset + 1];

int _be32(List<int> bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

/// Dimensions and transparency of a PNG or JPEG, or null if [bytes] is neither.
///
/// Hand-rolled rather than a dependency, on the same reasoning as the copy in
/// tool/play_upload: this reads a handful of integers out of a header, and
/// `package:image` is a decoder for a dozen formats. The check it enables is
/// worth having because Apple validates screenshots at submission — after they
/// have already been uploaded one at a time.
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

Map<String, Object?> _loadAgeRating(File file) {
  final text = file.readAsStringSync().trim();
  if (text.isEmpty) {
    throw MetadataException('${file.path} is empty');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (e) {
    throw MetadataException('${file.path} is not valid JSON: ${e.message}');
  }
  if (decoded is! Map<String, Object?>) {
    throw MetadataException(
      '${file.path} must be a JSON object of ageRatingDeclarations attributes',
    );
  }
  if (decoded.isEmpty) {
    throw MetadataException(
      '${file.path} is an empty object — delete the file rather than '
      'publishing nothing',
    );
  }
  return decoded;
}
