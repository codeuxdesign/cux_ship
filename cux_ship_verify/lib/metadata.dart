// SPDX-License-Identifier: Apache-2.0

// Loads and fully validates the store/appstore/ tree, with no network access
// and no credentials in scope.
//
// That property is the point, and it is the same one cux_ship_play has: a
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

import 'store_image.dart';
import 'store_video.dart';

// [ImageInfo] and [readImageInfo] used to be declared here, and moved out when
// the Play tree turned out to be reading them and consulting only the
// dimensions. Re-exported rather than left behind an import, because that is
// exactly the header this file's callers already reach for them through.
export 'store_image.dart';
// The video header and the preview rules over it, on the same terms: the
// uploader in cux_ship reads a [LocalPreview] out of this file and then has to
// name what Apple refused, and reaching that through a second import would be
// the one difference between the two asset kinds that is not a real one.
export 'store_video.dart';

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

/// The pixel sizes Apple accepts for one `PreviewType`.
///
/// **Not [ScreenshotSpec] with different numbers, and the differences are the
/// reason it is a second class.** Apple's preview sizes are not device
/// resolutions at all — every current iPhone publishes a 886x1920 preview,
/// which is no iPhone's screen — so the "capture it and it fits" intuition
/// that holds for screenshots is false here and the error has to say the
/// number. And the transpose is not always legal: a Mac or Apple TV preview is
/// landscape only, so accepting a 1080x1920 file for a [landscapeOnly] slot
/// would wave through the one video Apple is certain to refuse.
///
/// **The enum values are spelled differently from the screenshot ones**, which
/// is the trap this type exists to make unmissable: a screenshot slot is
/// `APP_IPHONE_67` and the preview slot for the same device is `IPHONE_67`,
/// with no prefix. Verified against Apple's `PreviewType` and
/// `ScreenshotDisplayType`, which are two separate enumerations.
///
/// **Apple is the authority, not this table**, exactly as for [ScreenshotSpec]:
/// https://developer.apple.com/help/app-store-connect/reference/app-preview-specifications/
class PreviewSpec {
  const PreviewSpec(
    this.label,
    this.portraitSizes, {
    this.landscapeOnly = false,
  });

  /// How Apple names this slot in the console, for error messages.
  final String label;

  /// Stated portrait-first even for a [landscapeOnly] slot, so the table reads
  /// one way; [accepts] is what applies the orientation rule.
  final List<({int width, int height})> portraitSizes;

  /// Apple takes this slot in landscape only — Mac and Apple TV.
  final bool landscapeOnly;

  bool accepts(int width, int height) => portraitSizes.any((s) {
    final portrait = width == s.width && height == s.height;
    final landscape = width == s.height && height == s.width;
    return landscapeOnly ? landscape : portrait || landscape;
  });

  String get sizesDescription {
    final sizes = portraitSizes.map(
      (s) =>
          landscapeOnly ? '${s.height}x${s.width}' : '${s.width}x${s.height}',
    );
    return sizes.join(' or ');
  }

  String get orientationDescription =>
      landscapeOnly ? 'landscape only' : 'in either orientation';
}

/// Keyed by `PreviewType` as the API spells it, because these are also the
/// directory names in the tree — so a typo fails this lookup rather than
/// uploading into the wrong slot.
///
/// Only the types this tooling has a caller for are listed, the same rule
/// [screenshotSpecs] follows. Apple's enumeration is longer and includes
/// `IPHONE_58`, `IPHONE_55`, `IPHONE_47`, `IPHONE_40`, `IPHONE_35`,
/// `IPAD_105`, `IPAD_97` and `APPLE_VISION_PRO`; add one when something needs
/// it, with its size read off Apple's page rather than guessed from the slot
/// next to it.
const previewSpecs = <String, PreviewSpec>{
  // One size across every current iPhone slot, which is not a mistake: Apple
  // publishes 886x1920 for 6.9", 6.5", 6.3" and 6.1" alike.
  'IPHONE_67': PreviewSpec('iPhone 6.9" / 6.7"', [(width: 886, height: 1920)]),
  'IPHONE_65': PreviewSpec('iPhone 6.5"', [(width: 886, height: 1920)]),
  'IPHONE_61': PreviewSpec('iPhone 6.1"', [(width: 886, height: 1920)]),
  'IPAD_PRO_3GEN_129': PreviewSpec('iPad 13" / 12.9"', [
    (width: 1200, height: 1600),
  ]),
  'IPAD_PRO_3GEN_11': PreviewSpec('iPad 11"', [(width: 1200, height: 1600)]),
  'IPAD_PRO_129': PreviewSpec('iPad Pro 12.9" (2nd gen)', [
    (width: 1200, height: 1600),
  ]),
  'DESKTOP': PreviewSpec('Mac', [
    (width: 1080, height: 1920),
  ], landscapeOnly: true),
  'APPLE_TV': PreviewSpec('Apple TV', [
    (width: 1080, height: 1920),
  ], landscapeOnly: true),
};

/// Apple takes up to three previews per `PreviewType` per locale.
///
/// Three, where a screenshot slot takes ten — stated in Apple's own sample
/// code for uploading previews ("Each set includes up to three previews") and
/// on the specifications page. A fourth is refused at reservation, after the
/// first three have already been uploaded.
const maxPreviews = 3;

/// The extensions Apple accepts for a preview, lowercased.
const previewExtensions = {'.mp4', '.mov', '.m4v'};

/// What a preview's poster-frame sidecar file is called, appended to the video's
/// own name — `01-ride.mp4` is posed by `01-ride.mp4.timecode`.
///
/// **A sidecar rather than a flag, because the poster frame is per video.** A
/// set holds up to three previews and there is no reason they share a frame,
/// so a single `--preview-frame` would be wrong for two of them. Appended
/// rather than replacing the extension so that it sorts against its own video
/// and cannot collide with a second preview of the same name in another
/// container.
const previewTimeCodeSuffix = '.timecode';

/// Apple's default poster frame when a preview names none.
///
/// **Recorded because it is the failure the tree exists to prevent**, not
/// because anything here sends it: a preview uploaded without a
/// `previewFrameTimeCode` silently poses on whatever is five seconds in, and
/// after approval that cannot be changed without a new version submission. So
/// the uploader prints the effective value either way, and this is what it
/// prints when a video carries no sidecar.
const defaultPreviewFrameTimeCode = '00:00:05:00';

/// `HH:MM:SS:FF` — hours, minutes, seconds, then a frame within that second.
final _timeCode = RegExp(r'^(\d{2}):(\d{2}):(\d{2}):(\d{2})$');

/// Why [value] is not a poster-frame timecode, or null when it is.
///
/// Shape and ranges only. Whether the frame is inside the video is a question
/// about a particular file and is asked where both are in hand, in
/// [_loadPreviews].
///
/// [frameRate] bounds the frames field when the caller knows it. **Optional
/// because the shape check has callers that have no file** — a consumer
/// validating a string before writing it — and absent it the frames field is
/// unbounded, which is the state this shipped in: `00:00:02:99` passed every
/// offline check on a 30 fps video, because minutes and seconds were range
/// checked and the field the format is named for was not.
String? previewFrameTimeCodeProblem(String value, {double? frameRate}) {
  final match = _timeCode.firstMatch(value);
  if (match == null) {
    return 'is "$value"; Apple wants a HH:MM:SS:FF timecode, e.g. '
        '00:00:02:06 for two seconds and six frames in';
  }
  final minutes = int.parse(match.group(2)!);
  final seconds = int.parse(match.group(3)!);
  if (minutes > 59 || seconds > 59) {
    return 'is "$value"; the minutes and seconds fields go up to 59';
  }
  final frames = int.parse(match.group(4)!);
  // Rounded up, so a 29.97 fps file still accepts frame 29. The bound is the
  // count of frames in a second, and the field is zero-based.
  final perSecond = frameRate?.ceil();
  if (perSecond != null && frames >= perSecond) {
    return 'is "$value"; FF is a frame within one second and this video runs '
        'at ${frameRate!.toStringAsFixed(2)} fps, so the last frame of a '
        'second is ${perSecond - 1}';
  }
  return null;
}

/// [value] as a position in the video, given the rate its frames run at.
Duration previewFrameOffset(String value, double frameRate) {
  final match = _timeCode.firstMatch(value)!;
  final frames = int.parse(match.group(4)!);
  return Duration(
        hours: int.parse(match.group(1)!),
        minutes: int.parse(match.group(2)!),
        seconds: int.parse(match.group(3)!),
      ) +
      Duration(microseconds: (frames * 1000000 / frameRate).round());
}

/// One preview video and the poster frame it was told to use.
///
/// `frameTimeCode` is null when the tree named none, and the null is carried
/// rather than resolved to [defaultPreviewFrameTimeCode] here: the uploader
/// prints "defaulting to" for one and the chosen value for the other, and a
/// model that filled it in would make those two cases indistinguishable at the
/// point where the difference is worth saying out loud.
typedef LocalPreview = ({File file, String? frameTimeCode});

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

  /// `PreviewType` -> the preview videos to publish, in the order Apple should
  /// show them. Only types with a directory present appear at all.
  ///
  /// Separate from [screenshots] rather than a fourth kind of entry in it,
  /// because Apple keeps them in separate resources with separate enumerations
  /// — `appPreviewSets` keyed by `PreviewType`, `appScreenshotSets` keyed by
  /// `ScreenshotDisplayType` — and merging them here would mean a caller
  /// deciding which endpoint a directory name belongs to, which is the guess
  /// this whole model exists to remove.
  final Map<String, List<LocalPreview>> previews = {};

  bool get isEmpty =>
      appInfo.isEmpty &&
      version.isEmpty &&
      screenshots.isEmpty &&
      previews.isEmpty;
}

/// The two answers Apple accepts for "does this app contain, show or access
/// third-party content".
///
/// It is an attribute of the *app* rather than of a version, it starts null,
/// and a null one makes the version unreviewable — with an error that says
/// only "this resource cannot be reviewed", which is how it costs an
/// afternoon.
const contentRightsDeclarations = {
  'DOES_NOT_USE_THIRD_PARTY_CONTENT',
  'USES_THIRD_PARTY_CONTENT',
};

class AppStoreMetadata {
  /// `appInfos` relationships: primaryCategory, secondaryCategory. Values are
  /// `appCategories` ids such as `HEALTH_AND_FITNESS`.
  final Map<String, String> categories = {};

  /// `apps.contentRightsDeclaration`, from info/content_rights.txt.
  String? contentRights;

  /// `appStoreVersions.copyright`, from info/copyright.txt.
  ///
  /// Kept in info/ rather than per-locale even though Apple stores it on the
  /// version: it names the rights holder, which does not translate, and a
  /// second locale should not get a second answer.
  String? copyright;

  final List<LocaleMetadata> locales = [];

  /// `ageRatingDeclarations` attributes, straight from age-rating.json.
  Map<String, Object?>? ageRating;

  /// `appStoreReviewDetails.notes`, from review-notes.md.
  ///
  /// What the reviewer is told about testing an app they have no data for.
  /// Everything after [reviewNotesMarker] is repo-internal and never reaches
  /// Apple — see [readReviewNotes].
  String? reviewNotes;
}

/// Where the reviewer-facing half of `review-notes.md` stops.
///
/// **Structural rather than remembered.** A review-notes file collects
/// checklists and reasoning belonging to whoever maintains it, and uploading the
/// file wholesale sends Apple an internal to-do list. A marker means the split
/// cannot be forgotten by the next person to add something under it, and it is
/// an HTML comment so it is invisible wherever the file is rendered.
const reviewNotesMarker = '<!-- not for Apple -->';

/// What Apple accepts in `appStoreReviewDetails.notes`.
const reviewNotesLimit = 4000;

/// The reviewer-facing half of a review-notes file, as plain text.
///
/// **Apple's field is plain text, so the markdown has to go.** A reviewer
/// seeing literal `##` and `**` reads carelessness in the one document whose
/// job is to argue the opposite. The transformation is deliberately small and
/// predictable rather than a markdown renderer: heading hashes, bold markers,
/// and the angle brackets that stop a bare URL being auto-linked.
///
/// Length is checked here rather than at upload, because a note over the limit
/// is refused *after* an archive has been transferred, and this is the package
/// that exists to find that sort of thing without a network.
String readReviewNotes(File file, {String label = 'review-notes.md'}) {
  final whole = file.readAsStringSync();
  final end = whole.indexOf(reviewNotesMarker);
  final facing = end < 0 ? whole : whole.substring(0, end);

  final text = facing
      .replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '')
      .replaceAll('**', '')
      .replaceAllMapped(RegExp(r'<(https?://[^>]+)>'), (m) => m.group(1)!)
      .trim();

  if (text.isEmpty) {
    throw MetadataException(
      '$label has nothing above $reviewNotesMarker — the whole file is marked '
      'as not for Apple',
    );
  }
  _checkLength('info', label, text, reviewNotesLimit);
  return text;
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

    final contentRights = _readField(info, 'content_rights');
    if (contentRights != null && contentRights.isNotEmpty) {
      if (!contentRightsDeclarations.contains(contentRights)) {
        throw MetadataException(
          'info/content_rights.txt is "$contentRights"; Apple accepts '
          '${contentRightsDeclarations.join(" or ")}',
        );
      }
      metadata.contentRights = contentRights;
    }

    final copyright = _readField(info, 'copyright');
    if (copyright != null && copyright.isNotEmpty) {
      // Apple's own guidance is "the year the rights were obtained, then the
      // name of the person or entity" — it renders the © itself, so a string
      // that carries one ends up showing two.
      if (copyright.contains('©')) {
        throw MetadataException(
          'info/copyright.txt contains a © symbol; Apple adds one itself, so '
          'write just "2026 Example Inc."',
        );
      }
      _checkLength('info', 'copyright.txt', copyright, 200);
      metadata.copyright = copyright;
    }
  }

  final ageRating = File('${root.path}${separator}age-rating.json');
  if (ageRating.existsSync()) {
    metadata.ageRating = _loadAgeRating(ageRating);
  }

  final reviewNotes = File('${root.path}${separator}review-notes.md');
  if (reviewNotes.existsSync()) {
    metadata.reviewNotes = readReviewNotes(reviewNotes);
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
      metadata.ageRating == null &&
      metadata.reviewNotes == null &&
      metadata.contentRights == null &&
      metadata.copyright == null) {
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

  final previews = Directory('${dir.path}${Platform.pathSeparator}previews');
  if (previews.existsSync()) {
    final typeDirs = previews.listSync().whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final typeDir in typeDirs) {
      final type = _basename(typeDir.path);
      final spec = previewSpecs[type];
      if (spec == null) {
        throw MetadataException(
          '$locale/previews/$type is not a PreviewType this tool knows.\n'
          '  Known names: ${previewSpecs.keys.join(", ")}\n'
          '  Note these are *not* the screenshot names: a preview slot is '
          'IPHONE_67, not APP_IPHONE_67.',
        );
      }
      metadata.previews[type] = _loadPreviews(locale, type, typeDir, spec);
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

    // Alpha and bit depth, from [appStoreImageRules] rather than written out
    // here — the Play tree asks the same two questions of the same parser, and
    // the version of this that *was* written out here is the reason the Play
    // tree never asked the first of them.
    //
    // Both are worth catching offline for the same reason: Apple validates
    // them after the file has been uploaded, one at a time. Alpha is the check
    // most likely to fire and the least visible from looking at the image —
    // every screen capture carries the channel as a matter of course, opaque
    // or not, and `xcrun simctl io screenshot` and the Android emulator both
    // write RGBA.
    final encoding = imageEncodingProblem(image, appStoreImageRules);
    if (encoding != null) {
      throw MetadataException('$name $encoding');
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

/// Loads and checks one `PreviewType` directory.
///
/// **Every check here is one Apple performs after the upload**, which is the
/// whole reason it is worth doing twice. A screenshot Apple refuses is a
/// re-upload; a preview Apple refuses is a video that went up, sat in an
/// ingestion queue Apple documents as taking up to twenty-four hours, came
/// back FAILED, and blocked the version's submission the entire time.
List<LocalPreview> _loadPreviews(
  String locale,
  String type,
  Directory dir,
  PreviewSpec spec,
) {
  // Same convention as screenshots, and load bearing for the same reason:
  // Apple shows previews in upload order, so filename order is listing order.
  final files = dir.listSync().whereType<File>().where((f) {
    final name = f.path.toLowerCase();
    return previewExtensions.any(name.endsWith);
  }).toList()..sort((a, b) => a.path.compareTo(b.path));

  if (files.isEmpty || files.length > maxPreviews) {
    throw MetadataException(
      '$locale/previews/$type holds ${files.length} video(s); Apple takes 1 '
      'to $maxPreviews per preview type.\n'
      '  Accepted extensions: ${previewExtensions.join(", ")}',
    );
  }

  // **An orphaned sidecar is the silent half of this feature.** A poster frame
  // named for a video that was renamed or removed is not an unused file: it is
  // somebody's deliberate choice of frame, now applying to nothing, and the
  // preview it was meant for goes up posed at Apple's five-second default with
  // nothing said. The tree is asked about it here because this is the only
  // place that knows both which sidecars exist and which videos claimed one.
  // **Matched case-insensitively, because the video filter is.** The videos
  // are selected with `path.toLowerCase().endsWith(...)`, so `RIDE.MP4` is a
  // preview — while this check and the sidecar lookup both compared exactly.
  // On a case-insensitive volume the mismatch is invisible; on Linux CI, a
  // sidecar named `01-ride.mp4.TIMECODE` was neither found nor reported as an
  // orphan, so the preview shipped at Apple's default and the one guard
  // against that said nothing. Absence and failure again, on the filesystem.
  final claimed = {
    for (final file in files) ...{
      '${file.path}$previewTimeCodeSuffix'.toLowerCase(),
    },
  };
  for (final file in dir.listSync().whereType<File>()) {
    if (file.path.toLowerCase().endsWith(previewTimeCodeSuffix) &&
        !claimed.contains(file.path.toLowerCase())) {
      throw MetadataException(
        '$locale/previews/$type/${_basename(file.path)} names no video here.\n'
        '  A poster frame is named after the whole video filename, so '
        '01-ride.mp4\n'
        '  is posed by 01-ride.mp4$previewTimeCodeSuffix.',
      );
    }
  }

  final previews = <LocalPreview>[];
  for (final file in files) {
    final name = '$locale/previews/$type/${_basename(file.path)}';
    final video = readVideoInfo(file.readAsBytesSync());
    if (video == null) {
      throw MetadataException('$name is not a readable MP4 or QuickTime video');
    }

    // Codec, duration, frame rate and file size, from [appStorePreviewRules]
    // rather than written out here — the same split store_image.dart uses, and
    // for the same reason: a second store's preview uploader names whose rules
    // it publishes under instead of re-deriving four numbers.
    final encoding = videoEncodingProblem(video, appStorePreviewRules);
    if (encoding != null) {
      throw MetadataException('$name $encoding');
    }

    if (!spec.accepts(video.width, video.height)) {
      throw MetadataException(
        '$name is ${video.width}x${video.height}; $type (${spec.label}) takes '
        '${spec.sizesDescription}, ${spec.orientationDescription}.\n'
        '  Apple\'s preview sizes are not device resolutions — every current '
        'iPhone\n'
        '  publishes 886x1920 — so a capture at the device\'s own size is the\n'
        '  ordinary way to get this wrong.\n'
        '  If Apple has added a size, add it to previewSpecs in '
        'lib/metadata.dart.',
      );
    }

    previews.add((file: file, frameTimeCode: _loadTimeCode(name, file, video)));
  }
  return previews;
}

/// The poster-frame timecode beside [file], or null when there is none.
String? _loadTimeCode(String name, File file, VideoInfo video) {
  // **Found by matching the directory case-insensitively, not by building the
  // exact path.** The video filter accepts `RIDE.MP4`, so the tree is already
  // case-insensitive about previews, and an `existsSync` on a constructed name
  // is not: on Linux a sidecar written `01-ride.mp4.TIMECODE` simply did not
  // exist, so the preview shipped at Apple's five-second default with nothing
  // said. Consistent with the orphan check above, which compares the same way
  // — the two have to agree, or a sidecar is either missed by both or claimed
  // by one and ignored by the other.
  final wanted = '${file.path}$previewTimeCodeSuffix'.toLowerCase();
  File? sidecar;
  for (final candidate in file.parent.listSync().whereType<File>()) {
    if (candidate.path.toLowerCase() == wanted) {
      sidecar = candidate;
      break;
    }
  }
  if (sidecar == null) {
    return null;
  }
  final value = sidecar.readAsStringSync().trim();
  if (value.isEmpty) {
    throw MetadataException(
      '$name$previewTimeCodeSuffix is empty — delete the file rather than '
      'asking for a blank poster frame, which would silently pose the '
      'preview at $defaultPreviewFrameTimeCode',
    );
  }

  final shape = previewFrameTimeCodeProblem(value, frameRate: video.frameRate);
  if (shape != null) {
    throw MetadataException('$name$previewTimeCodeSuffix $shape');
  }

  // **A frame past the end is the one that reads as working.** Apple takes the
  // string without complaint and the poster silently falls back, so the
  // failure shows up as a product page posing on the wrong frame — after
  // approval, when it can no longer be changed without a new submission.
  final offset = previewFrameOffset(value, video.frameRate);
  if (offset >= video.duration) {
    throw MetadataException(
      '$name$previewTimeCodeSuffix is "$value", which is past the end of a '
      '${(video.duration.inMilliseconds / 1000).toStringAsFixed(1)}s video',
    );
  }
  return value;
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
