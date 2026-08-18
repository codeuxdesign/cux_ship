// SPDX-License-Identifier: Apache-2.0
//
// The Play listing tree, checked offline — the counterpart of metadata.dart.
//
// Play enforces these after the artifact has been transferred: an over-long
// description or a wrongly sized icon fails inside an edit that has already
// carried a bundle up the wire. `play upload --dry-run` does rehearse the
// per-call failures, but it is not a per-push check — it uploads the whole
// artifact before discarding the edit — so the same rules are worth asserting
// where feedback costs a second.
//
// **What is configurable and what is not.** Which screenshot types a listing
// must carry is a property of the app, so a consumer names them. The icon and
// the feature graphic are not: Play requires both, at exact dimensions, of
// every listing. They are Play's rules rather than a project's choice, so they
// are checked unconditionally and cannot be declared away — a config that could
// omit them would let a missing icon pass a file that looks complete.
//
// **On numbers in this file, and where each one comes from.** Two kinds are
// mixed here and they must not be presented alike. Play's own limits are cited
// as Play's. This package's policy floors are labelled as this package's,
// because a hardcoded value nobody can change needs provenance *more* than a
// configured one: the first project that legitimately disagrees will file the
// discrepancy as a bug, and a number with no source cannot be defended or
// dropped.
//
// **The weakest thing here is the fallback-locale rule, and it is weak in a
// specific way worth naming.** Localized graphics are optional per locale and
// inherit the default language's, so only the locale others fall back to is
// held to the required images. That is right — it is Play Console's documented
// behaviour, found independently of the author's reading — but it is the one
// rule in this file with **no real-listing evidence under it**. Every
// repository that reviewed this release publishes a single locale, so nothing
// but the synthetic trees in `play_metadata_test.dart` has ever exercised it.
//
// Said out loud because "reviewed by three projects" would otherwise read as
// covering it, and a rule believed to be covered is the failure this whole
// release is about. The first consumer to ship a second locale is the first
// real test; if it reports something odd about an inheriting locale, start
// here.
//
// **What is deliberately not checked: aspect ratio.** Play's published guidance
// once said a screenshot's longer side may be at most twice its shorter one.
// That rule is not enforced as written and asserting it would fail listings the
// store is serving now — a native 20:9 phone capture is 2.22:1, and real
// listings carry 1080x2424 (2.244:1) today. The reductio needs no counterexample
// at all: Play *mandates* a 1024x500 feature graphic, which is 2.048:1, so a
// max-to-min rule applied to images declares Play's own required size invalid.
// It is left out until somebody produces a listing the store actually refused.
import 'dart:io';

import 'metadata.dart';
import 'release_problem.dart';

// loadPlayMetadata throws it, so a caller reaching this through the umbrella
// library has to be able to name it.
export 'metadata.dart' show MetadataException;

/// Play's limits on the listing text, in UTF-16 code units.
///
/// Counted over the file's bytes as stored — not whitespace-normalised, and not
/// byte length. Both mistakes have been measured on real trees: normalising
/// newlines under-counted a description by 27 characters against what Play
/// reports, and `wc -c` over-counted another by 2 where the text contained
/// multi-byte characters. A checker that reports headroom the store does not
/// agree exists is worse than no checker.
const playListingLimits = <String, int>{
  'title': 30,
  'short_description': 80,
  'full_description': 4000,
};

/// An image Play requires of every listing, at one exact size.
///
/// Both are Play's rules. Neither is configurable, and that is the point: a
/// listing without an icon is not a listing, so letting a config omit it would
/// only ever hide the failure.
class PlayImageSpec {
  const PlayImageSpec(this.label, this.width, this.height);

  final String label;
  final int width;
  final int height;

  bool accepts(int w, int h) => w == width && h == height;

  String get sizeDescription => '${width}x$height';
}

/// Keyed by the directory name under `images/`, which is also the name the Play
/// API uses, so a typo fails this lookup rather than being uploaded into the
/// wrong slot.
const playRequiredImages = <String, PlayImageSpec>{
  'icon': PlayImageSpec('app icon', 512, 512),
  'featureGraphic': PlayImageSpec('feature graphic', 1024, 500),
};

/// Screenshot directories Play understands, by the name it uses.
///
/// Listed rather than derived for the same reason as the App Store side: these
/// are directory names, so an unrecognised one is a typo that would otherwise
/// publish nowhere silently.
const playScreenshotTypes = <String>{
  'phoneScreenshots',
  'sevenInchScreenshots',
  'tenInchScreenshots',
  'tvScreenshots',
  'wearScreenshots',
};

/// Play's bounds on a screenshot's edge, in pixels. Play's own numbers.
const playMinScreenshotEdge = 320;
const playMaxScreenshotEdge = 3840;

/// Play's maximum per screenshot type. Play's own number, enforced at upload.
const playMaxScreenshots = 8;

/// **This package's policy floor, not Play's rule.**
///
/// Play's hard minimum is app-level — a listing needs at least two screenshots
/// somewhere — and per-type minimums belong to its tablet-optimisation tier
/// rather than to publishing. But a type a project has *declared* and filled
/// with a single placeholder is a listing defect worth naming, so it is checked
/// here and labelled as ours. If a project ever has a legitimate reason to
/// publish one image for a declared type, this is the number to argue with, and
/// it can be argued with because it says whose it is.
const playPolicyMinScreenshotsPerDeclaredType = 2;

/// One locale's Play listing.
class PlayLocaleMetadata {
  PlayLocaleMetadata(this.locale);

  final String locale;

  /// `title`, `short_description`, `full_description`, as stored.
  final Map<String, String> text = {};

  /// Directory name under `images/` -> the files in it, in publish order.
  final Map<String, List<File>> images = {};
}

/// A Play listing tree.
class PlayMetadata {
  PlayMetadata(this.path);

  final String path;

  /// From `details/default_language.txt`. Play has a distinguished locale and
  /// the App Store has no equivalent, so this has no counterpart in
  /// [AppStoreMetadata].
  String? defaultLanguage;

  final List<PlayLocaleMetadata> locales = [];
}

/// Loads the Play metadata tree at [path].
///
/// Throws [MetadataException] — shared with the App Store side, because a
/// caller checking both wants one exception type and one message style.
PlayMetadata loadPlayMetadata(String path) {
  final root = Directory(path);
  if (!root.existsSync()) {
    throw MetadataException('$path does not exist');
  }

  final metadata = PlayMetadata(path);

  final defaultLanguage = File('$path/details/default_language.txt');
  if (defaultLanguage.existsSync()) {
    final value = defaultLanguage.readAsStringSync().trim();
    metadata.defaultLanguage = value.isEmpty ? null : value;
  }

  final listings = Directory('$path/listings');
  if (!listings.existsSync()) {
    throw MetadataException(
      '$path has no listings/ directory — a Play tree keeps each locale in '
      'listings/<bcp-47>/',
    );
  }

  final localeDirs = listings.listSync().whereType<Directory>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final dir in localeDirs) {
    final locale = dir.path.split(Platform.pathSeparator).last;
    final entry = PlayLocaleMetadata(locale);

    for (final field in playListingLimits.keys) {
      final file = File('${dir.path}/$field.txt');
      if (file.existsSync()) {
        // Trailing newline removed and nothing else: a text file ends with one
        // and Play does not store it, but stripping any further would be the
        // normalisation this file's header warns about.
        entry.text[field] = _withoutTrailingNewline(file.readAsStringSync());
      }
    }

    final images = Directory('${dir.path}/images');
    if (images.existsSync()) {
      final imageDirs = images.listSync().whereType<Directory>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final imageDir in imageDirs) {
        final name = imageDir.path.split(Platform.pathSeparator).last;
        final files =
            imageDir
                .listSync()
                .whereType<File>()
                .where((f) => _isImage(f.path))
                .toList()
              ..sort((a, b) => a.path.compareTo(b.path));
        entry.images[name] = files;
      }
    }

    metadata.locales.add(entry);
  }

  return metadata;
}

/// Loads the Play tree at [path] and reports what Play would refuse.
///
/// [requireScreenshotTypes] is the app's own requirement — which types this
/// listing must carry — and is the only thing a consumer names. The icon and
/// feature graphic are Play's and are always required.
///
/// [requireLocales] behaves as on the App Store side: a declared locale missing
/// from the tree is an error. A locale present in the tree that nobody declared
/// is *reported*, not failed — adding a language should not be a two-commit
/// operation, and the same asymmetry is settled the same way in
/// [checkAppStoreTree].
List<ReleaseProblem> checkPlayTree(
  String path, {
  Set<String> requireScreenshotTypes = const {},
  Set<String> requireLocales = const {},
}) {
  final PlayMetadata metadata;
  try {
    metadata = loadPlayMetadata(path);
  } on MetadataException catch (e) {
    return [ReleaseProblem(path, e.message)];
  }

  final problems = <ReleaseProblem>[];

  if (metadata.locales.isEmpty) {
    return [ReleaseProblem(path, 'no locales — nothing would publish')];
  }

  final present = metadata.locales.map((l) => l.locale).toSet();

  for (final locale in requireLocales) {
    if (!present.contains(locale)) {
      problems.add(
        ReleaseProblem(path, 'no listing for required locale $locale'),
      );
    }
  }

  // Play has a distinguished locale and the App Store does not. A default
  // naming a locale the tree does not carry is a listing that cannot publish,
  // and it is invisible in a diff of either file alone.
  final defaultLanguage = metadata.defaultLanguage;
  if (defaultLanguage != null && !present.contains(defaultLanguage)) {
    problems.add(
      ReleaseProblem(
        '$path → details/default_language.txt',
        'names $defaultLanguage, which has no listings/$defaultLanguage/ '
            'directory — the default locale has to be one the tree carries',
      ),
    );
  }
  if (defaultLanguage != null &&
      requireLocales.isNotEmpty &&
      !requireLocales.contains(defaultLanguage)) {
    problems.add(
      ReleaseProblem(
        '$path → details/default_language.txt',
        'names $defaultLanguage, which is not among the declared locales '
            '(${(requireLocales.toList()..sort()).join(', ')})',
      ),
    );
  }

  // **A locale in the tree that nobody declared is not reported here.**
  //
  // An earlier draft did report it, with a comment claiming it was "reported,
  // not failed" — which was untrue twice over. `ReleaseProblem` carries no
  // severity, so every caller fails on it; and `checkAppStoreTree` settles the
  // same question the opposite way, by skipping such a locale silently. One
  // store failing where the other shrugs is not a policy, it is an accident.
  //
  // The decision on record is that an undeclared locale reports and does not
  // fail. Until there is a mechanism that can express that, the honest
  // implementation is the one that matches its sibling.

  // Which locale carries the images Play requires. Localized graphics are
  // optional per locale and fall back to the default language, so demanding an
  // icon in every locale directory fails a tree Play accepts — a text-only
  // `de-DE/` beside a fully illustrated `en-US/` is an ordinary, published
  // shape. Only the locale that has to stand alone is held to it.
  final fallbackLocale =
      metadata.defaultLanguage ??
      (metadata.locales.length == 1 ? metadata.locales.single.locale : null);

  for (final locale in metadata.locales) {
    problems.addAll(
      _checkLocale(
        path,
        locale,
        requireScreenshotTypes,
        // Same reasoning as the images: a locale without its own screenshots
        // shows the default language's.
        //
        // **When the fallback cannot be determined, nothing is treated as
        // one.** An earlier revision passed `true` for every locale here, on
        // the theory that checking more was the safe direction. It is not: a
        // two-locale tree with no `default_language.txt` then reported a
        // missing icon against the locale that happened not to carry one,
        // which is an innocent locale — someone acting on that adds an icon to
        // a translation that never needed it and still has the real problem.
        //
        // The real problem is reported once, below. This is the same rule the
        // App Store platform selection follows: when the answer cannot be
        // determined, say so rather than picking one and blaming what follows
        // from the pick.
        isFallback: fallbackLocale != null && locale.locale == fallbackLocale,
      ),
    );
  }

  if (fallbackLocale == null && metadata.locales.length > 1) {
    problems.add(
      ReleaseProblem(
        '$path → details/default_language.txt',
        'is missing, and the tree has ${metadata.locales.length} locales — so '
            'which one supplies the icon, the feature graphic and the '
            'screenshots the others fall back to cannot be told from the tree',
      ),
    );
  }

  return problems;
}

List<ReleaseProblem> _checkLocale(
  String path,
  PlayLocaleMetadata locale,
  Set<String> requireScreenshotTypes, {
  required bool isFallback,
}) {
  final problems = <ReleaseProblem>[];
  final where = '$path → ${locale.locale}';

  for (final field in playListingLimits.entries) {
    final value = locale.text[field.key];
    if (value == null || value.isEmpty) {
      problems.add(
        ReleaseProblem(where, '${field.key}.txt is missing or empty'),
      );
      continue;
    }
    if (value.length > field.value) {
      problems.add(
        ReleaseProblem(
          where,
          '${field.key}.txt is ${value.length} characters, over the '
          '${field.value} Play accepts',
        ),
      );
    }
  }

  // Play's rules, so they are asserted whatever the config says — but only of
  // the locale that has to stand alone. A locale that overrides the graphic is
  // held to the size; one that inherits it is not asked for a file it does not
  // need.
  for (final entry in playRequiredImages.entries) {
    final files = locale.images[entry.key];
    final spec = entry.value;
    if (files == null || files.isEmpty) {
      if (isFallback) {
        problems.add(
          ReleaseProblem(
            where,
            'no ${entry.key}/ image — Play requires ${spec.label} of the '
            'listing every other locale falls back to, at exactly '
            '${spec.sizeDescription}',
          ),
        );
      }
      continue;
    }
    if (files.length > 1) {
      problems.add(
        ReleaseProblem(
          where,
          '${entry.key}/ holds ${files.length} images and Play takes exactly '
          'one — which of them publishes is not something this tree decides',
        ),
      );
    }
    for (final file in files) {
      final info = readImageInfo(file.readAsBytesSync());
      final name = '${entry.key}/${_basename(file.path)}';
      if (info == null) {
        problems.add(ReleaseProblem(where, '$name is not a PNG or a JPEG'));
        continue;
      }
      if (!spec.accepts(info.width, info.height)) {
        problems.add(
          ReleaseProblem(
            where,
            '$name is ${info.width}x${info.height}, and Play takes ${spec.label} '
            'at exactly ${spec.sizeDescription}',
          ),
        );
      }
    }
  }

  // Screenshots fall back to the default language too, so a translated listing
  // that reuses them is ordinary rather than incomplete.
  //
  // The condition is outside the loop rather than a `break` inside it. It is
  // loop-invariant either way and both are correct today, but a `break` reads
  // as "skip this type" while meaning "skip all of them", and it is one
  // inserted per-type condition away from being wrong.
  if (isFallback) {
    for (final type in requireScreenshotTypes) {
      final files = locale.images[type];
      if (files == null || files.isEmpty) {
        problems.add(
          ReleaseProblem(
            where,
            'no $type, which this app is required to carry',
          ),
        );
      }
    }
  }

  for (final entry in locale.images.entries) {
    final type = entry.key;
    if (playRequiredImages.containsKey(type)) {
      continue;
    }
    if (!playScreenshotTypes.contains(type)) {
      problems.add(
        ReleaseProblem(
          where,
          'images/$type is not a directory Play publishes '
          '(${(playScreenshotTypes.toList()..sort()).join(', ')}, or '
          '${(playRequiredImages.keys.toList()..sort()).join(', ')}) — it '
          'would be ignored rather than refused',
        ),
      );
      continue;
    }

    final files = entry.value;
    if (files.isEmpty) {
      continue;
    }
    if (files.length > playMaxScreenshots) {
      problems.add(
        ReleaseProblem(
          where,
          '$type holds ${files.length} images, over the $playMaxScreenshots '
          'Play accepts',
        ),
      );
    }
    // This package's floor rather than Play's — see the constant — and it
    // applies only to a type the project *declared*. A directory that is
    // merely present carries no promise: an undeclared `wearScreenshots/` with
    // one image is a listing Play accepts, and failing it would be this
    // package inventing a rule and enforcing it against a live store.
    if (requireScreenshotTypes.contains(type) &&
        files.length < playPolicyMinScreenshotsPerDeclaredType) {
      problems.add(
        ReleaseProblem(
          where,
          '$type holds ${files.length} image; a declared screenshot type with '
          'fewer than $playPolicyMinScreenshotsPerDeclaredType reads as '
          "unfinished (this tool's floor, not a Play limit)",
        ),
      );
    }

    for (final file in files) {
      final name = '$type/${_basename(file.path)}';
      final info = readImageInfo(file.readAsBytesSync());
      if (info == null) {
        problems.add(ReleaseProblem(where, '$name is not a PNG or a JPEG'));
        continue;
      }
      final shortest = info.width < info.height ? info.width : info.height;
      final longest = info.width < info.height ? info.height : info.width;
      if (shortest < playMinScreenshotEdge) {
        problems.add(
          ReleaseProblem(
            where,
            '$name is ${info.width}x${info.height}; Play wants every side at '
            'least $playMinScreenshotEdge',
          ),
        );
      }
      if (longest > playMaxScreenshotEdge) {
        problems.add(
          ReleaseProblem(
            where,
            '$name is ${info.width}x${info.height}; Play wants every side at '
            'most $playMaxScreenshotEdge',
          ),
        );
      }
    }
  }

  return problems;
}

/// Play accepts PNG and JPEG. Anything else in an image directory is a file
/// somebody left there, and is reported by the loader rather than published.
bool _isImage(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.png') ||
      lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg');
}

String _basename(String path) => path.split(Platform.pathSeparator).last;

String _withoutTrailingNewline(String value) {
  if (value.endsWith('\r\n')) {
    return value.substring(0, value.length - 2);
  }
  if (value.endsWith('\n')) {
    return value.substring(0, value.length - 1);
  }
  return value;
}
