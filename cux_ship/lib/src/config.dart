// SPDX-License-Identifier: Apache-2.0
//
// `.cux-ship.yaml` — what is true of a repository rather than of an invocation.
//
// Everything here could be a flag, and every key is one. The reason the file
// exists is that some of those flags never vary: a monorepo's app directory is
// the same on every command, forever, and typing it each time means a shell
// script repeating one constant at eight call sites. That is the shape
// ProjectContext was written to remove, and a flag-only answer puts a small
// version of it straight back.
//
// So the rule is the same one the rest of the tool follows: **read what can be
// read, and let a flag override it.** Precedence is flag, then CUX_SHIP_APP_DIR,
// then this file, then inference.
//
// It sits beside `.sops.yaml` at the repository root and is spelled like it.
//
// **An unknown key is an error, not a value to ignore.** The file's whole job is
// to be read silently before every command, so a misspelt key that is quietly
// skipped is a setting that appears to be applied and is not — which is the one
// failure this tool is built to refuse everywhere else. There is one key today,
// so the check costs nothing and the habit is set before there are ten.
import 'dart:io';

import 'package:yaml/yaml.dart';

import 'asc_platforms.dart';
import 'project.dart';

/// The name every consumer uses. Not configurable — a config file whose
/// location is configurable has to be found before it can be read.
const cuxShipConfigFile = '.cux-ship.yaml';

/// Keys this version understands. Anything else stops the command and is
/// reported against this list.
const _knownKeys = {'app-dir', 'apple', 'appstore', 'play', 'tag'};

/// Keys understood inside `apple:`.
const _knownAppleKeys = {'signing'};

/// Kinds of tag this tool writes, and therefore the keys inside `tag:`.
///
/// Both are implemented: `upload` records one upload of one build, `release`
/// names the tag `release finish` writes. They were added a version apart, and
/// for the gap between them this comment said `release` was named-but-refused
/// — which stayed here for exactly as long as it took someone to read the code
/// instead of the comment.
const _knownTagKeys = {'upload', 'release'};

/// Keys understood inside `tag.upload:`, and eventually `tag.release:`.
///
/// One set for both kinds, because both answer the same two questions: do we
/// write this tag, and what is it called. The *defaults* differ — an upload
/// record is opt-in, a release tag is not — but a key valid in one and not the
/// other would be a trap rather than a distinction.
const _knownTagKindKeys = {'enabled', 'format'};

/// The tag shape written when nothing overrides it.
///
/// **Namespaced by construction, and that is not a style choice.** A release
/// guard that asks "has this version already shipped" by taking the highest
/// `v*` tag will read a bare `v1.0.4+56` as a released 1.0.4 — `sort -V` ranks
/// build metadata *above* the version it annotates — and then refuse to build
/// 1.0.4, naming a release that never happened. Under `uploaded/` no such glob
/// matches. One of the repositories using this tool has that guard in its older
/// form right now, which is how the trap was found.
const defaultUploadTagFormat = 'uploaded/v{version}+{build}';

/// The release tag shape when nothing overrides it.
///
/// No `{build}` on purpose, and that is the asymmetry with an upload record: a
/// release names a *version*, which one build happens to carry, while a record
/// names one upload of it. `{build}` is available if a repository wants it.
const defaultReleaseTagFormat = 'v{version}';

/// Keys understood inside `appstore:` and `play:`.
///
/// One set for both, because both blocks answer the same two questions. What
/// the answers *mean* differs — see [StoreConfig] — but a key that is valid in
/// one and not the other would be a trap rather than a distinction.
const _knownStoreKeys = {'locales', 'screenshots'};

/// How provisioning profiles are come by, which decides more than it sounds
/// like it does.
///
/// `-allowProvisioningUpdates` is a portal *write*, and an individual App Store
/// Connect key cannot even read the portal — certificates, identifiers and
/// profiles are team resources, refused whatever role the user holds. So
/// automatic signing requires a team Admin key, and a team Admin key reaches
/// every app in the team.
///
/// Manual signing is therefore what buys a scoped CI credential: the stored
/// profiles are the price of a key that cannot touch anything but this app.
/// That is a reason to choose it on a new project, not merely a legacy state to
/// migrate away from.
enum AppleSigning {
  /// Xcode creates and renews profiles. Needs a team key.
  automatic,

  /// Profiles are supplied, from `apple.profiles` in the secrets file.
  manual,
}

/// What one store's listing must carry, as the repository declares it.
///
/// **Declaring the block is what says this project publishes there.** That is
/// the whole signal: a project with an `appstore:` block and no App Store tree
/// is misconfigured and is told so, while a project with no block is one that
/// does not publish to the App Store and is skipped. Nothing has to guess from
/// whether a conventional directory happens to exist — which is a guess that
/// gets it wrong exactly when a tree moves, and gets it wrong silently.
///
/// **[screenshots] means different things on the two sides, and that is not a
/// wart.** On the App Store it is an *override* of what the Xcode project
/// already implies: `TARGETED_DEVICE_FAMILY` says whether an iPad set is
/// required, and the required display types follow from it, so a project that
/// says nothing still gets checked. Play has no equivalent to derive from, so
/// there the list is the source of truth. Presenting them as symmetric would
/// invite one implementation behind two keys.
///
/// The images Play requires of every listing — the icon and the feature
/// graphic — are deliberately absent. They are Play's rules rather than a
/// project's choice, so they are always checked and cannot be declared away.
class StoreConfig {
  const StoreConfig({this.locales = const {}, this.screenshots = const {}});

  /// Locales the listing must carry. Cannot be inferred: "the tree has what it
  /// has" is circular, and noticing a locale that silently stopped being there
  /// is the entire job.
  final Set<String> locales;

  /// Required screenshot types.
  ///
  /// Keyed by platform on the App Store side (`ios`, `macos`), because one tree
  /// serves both and the required types differ. Play has no platform axis, so
  /// its list is stored under the single key [anyPlatform].
  final Map<String, Set<String>> screenshots;

  /// The key Play's flat list is stored under.
  static const anyPlatform = '*';

  Set<String> screenshotsFor(String platform) =>
      screenshots[platform] ?? screenshots[anyPlatform] ?? const {};
}

/// One kind of tag this tool writes: whether, and under what name.
///
/// **Named for the kind rather than for the concept.** This was `provenance:`,
/// which is specialist vocabulary in two registers at once — the art world's
/// word for an object's ownership history, and, in software, the supply-chain
/// term for *signed* build attestations (npm `--provenance`, SLSA, sigstore).
/// A reader arriving from the second expects Sigstore attestations in a
/// transparency log and gets one annotated git tag. A name that promises more
/// than it delivers is worse than one that says nothing.
///
/// Every comparable tool calls this a tag: fastlane's `add_git_tag`,
/// semantic-release's `tagFormat`, Maven's `tagNameFormat`, npm's
/// `git-tag-version`. `format` echoes those on purpose.
class TagKindConfig {
  const TagKindConfig({required this.enabled, required this.format});

  /// Write this tag at all. The default differs by kind and lives at the parse
  /// site: an upload record is opt-in, a release tag is not.
  final bool enabled;

  /// `{version}` and `{build}` are substituted. See [defaultUploadTagFormat]
  /// for why the upload default is namespaced.
  final String format;

  /// The tag name for one artifact.
  ///
  /// [build] is optional because a release tag need not carry one — an upload
  /// format is *required* to contain `{build}` and a release format is not, so
  /// asking for it here would make the caller invent a value it does not have.
  ///
  /// **A format that asks for a build number without one is refused, not
  /// blanked.** `tag.release.format` is only checked for `{version}` at parse
  /// time, so `v{version}+{build}` is a legal release format — and
  /// `release finish` has no build number unless one was passed. Substituting
  /// an empty string there yields `v1.1.0+`: a tag that is written, pushed,
  /// and wrong, whose defect is one trailing character in a name nobody reads
  /// twice. The parse-time check cannot catch it because whether a build
  /// number exists is a property of the invocation rather than the file.
  String nameFor({required String version, String? build}) {
    if (format.contains('{build}') && (build == null || build.isEmpty)) {
      throw ProjectException(
        'the tag format "$format" needs a build number and this command has '
        'none, so the tag would be written as '
        '"${format.replaceAll('{version}', version).replaceAll('{build}', '')}"'
        ' — pass one, or take {build} out of the format',
      );
    }
    return format
        .replaceAll('{version}', version)
        .replaceAll('{build}', build ?? '');
  }
}

class ProjectConfig {
  const ProjectConfig({
    this.appDir,
    this.signing = AppleSigning.automatic,
    this.appstore,
    this.play,
    this.uploadTag = const TagKindConfig(
      enabled: false,
      format: defaultUploadTagFormat,
    ),
    this.releaseTag = const TagKindConfig(
      enabled: true,
      format: defaultReleaseTagFormat,
    ),
  });

  /// Reads `<repoRoot>/.cux-ship.yaml`.
  ///
  /// An absent file is not an error and yields an empty config — most projects
  /// need nothing here, and requiring the file would make the ordinary case
  /// pay for the monorepo one.
  ///
  /// Everything else is: an unreadable file, a document that is not a mapping,
  /// an unknown key, or a key of the wrong type all throw. This is read before
  /// every command, so anything wrong with it is wrong on every command, and
  /// saying so once is cheaper than a store command behaving unexpectedly.
  factory ProjectConfig.read(String repoRoot) {
    final file = File('$repoRoot/$cuxShipConfigFile');
    if (!file.existsSync()) {
      return const ProjectConfig();
    }

    final dynamic document;
    try {
      document = loadYaml(file.readAsStringSync(), sourceUrl: file.uri);
    } on YamlException catch (e) {
      throw ProjectException('$cuxShipConfigFile is not valid YAML: $e');
    }

    // An empty file parses to null, and is a legitimate thing to have — a file
    // whose every key has been commented out is still a file somebody meant to
    // keep.
    if (document == null) {
      return const ProjectConfig();
    }
    if (document is! YamlMap) {
      throw ProjectException(
        '$cuxShipConfigFile must be a mapping of settings, and is a '
        '${document.runtimeType}',
      );
    }

    _checkKeys(document, _knownKeys, null);

    return ProjectConfig(
      appDir: _string(document, 'app-dir'),
      signing: _apple(document),
      appstore: _store(document, 'appstore'),
      play: _store(document, 'play'),
      uploadTag: _uploadTag(document),
      releaseTag: _releaseTag(document),
    );
  }

  /// Reads `tag.release:` — how `release finish` names the tag it writes.
  ///
  /// **Enabled by default, where an upload record is not.** A release tag is
  /// what this tool has always written; a record of every upload is new and
  /// opt-in. Same two keys either way, because a key valid in one kind and not
  /// the other would be a trap rather than a distinction.
  static TagKindConfig _releaseTag(YamlMap document) {
    const on = TagKindConfig(enabled: true, format: defaultReleaseTagFormat);
    final tag = document['tag'];
    if (tag is! YamlMap) {
      return on;
    }
    final block = tag['release'];
    if (block == null) {
      return on;
    }
    if (block is! YamlMap) {
      throw ProjectException(
        '$cuxShipConfigFile: tag.release must be a mapping, and is a '
        '${block.runtimeType}',
      );
    }
    _checkKeys(block, _knownTagKindKeys, 'tag.release');

    final enabled = block['enabled'];
    if (enabled != null && enabled is! bool) {
      throw ProjectException(
        '$cuxShipConfigFile: tag.release.enabled must be true or false, and '
        'is $enabled',
      );
    }
    final format = _string(block, 'format') ?? defaultReleaseTagFormat;
    if (!format.contains('{version}')) {
      // A release tag that does not name its version is not a release tag: two
      // releases collide under one name, and `release finish` then refuses the
      // second claiming one version reached two commits.
      throw ProjectException(
        '$cuxShipConfigFile: tag.release.format must contain {version} — '
        '"$format" would name every release the same thing',
      );
    }
    return TagKindConfig(enabled: (enabled as bool?) ?? true, format: format);
  }

  /// Reads `tag.upload:` — the record written for one upload of one build.
  ///
  /// **Absent means off, and that is deliberate.** Recording pushes a tag to
  /// `origin` before the store is contacted, so a repository that has not asked
  /// for it would suddenly need push credentials on its upload job — and a
  /// missing write token would then block uploads rather than skip a record.
  /// Two of the three repositories using this tool have upload paths that
  /// cannot name their built commit yet. Opting in is how they choose when.
  ///
  /// What is *not* configurable-by-default is the shape: a repository that
  /// turns this on and says nothing gets [defaultUploadTagFormat], because
  /// the namespace is a correctness property rather than a preference.
  static TagKindConfig _uploadTag(YamlMap document) {
    const off = TagKindConfig(enabled: false, format: defaultUploadTagFormat);
    if (!document.containsKey('tag')) {
      return off;
    }
    final tag = document['tag'];
    if (tag == null) {
      return off;
    }
    if (tag is! YamlMap) {
      throw ProjectException(
        '$cuxShipConfigFile: tag must be a mapping of tag kinds, and is a '
        '${tag.runtimeType}',
      );
    }
    _checkKeys(tag, _knownTagKeys, 'tag');

    final block = tag['upload'];
    if (block == null) {
      return off;
    }
    if (block is! YamlMap) {
      throw ProjectException(
        '$cuxShipConfigFile: tag.upload must be a mapping, and is a '
        '${block.runtimeType}',
      );
    }
    _checkKeys(block, _knownTagKindKeys, 'tag.upload');

    final enabled = block['enabled'];
    if (enabled != null && enabled is! bool) {
      throw ProjectException(
        '$cuxShipConfigFile: tag.upload.enabled must be true or false, and is '
        '$enabled',
      );
    }
    final format = _string(block, 'format') ?? defaultUploadTagFormat;
    if (!format.contains('{build}')) {
      // Without the build number two uploads of one version collide, and the
      // collision check then reports a genuine repeat as one number naming two
      // commits — the loudest error this tool has, raised falsely, on a
      // configuration mistake made once and paid for on every release after.
      throw ProjectException(
        '$cuxShipConfigFile: tag.upload.format must contain {build} — '
        '"$format" would name every upload of one version the same thing',
      );
    }
    return TagKindConfig(
      // Opt-in: a repository that has not asked for tags does not get them.
      enabled: (enabled as bool?) ?? false,
      format: format,
    );
  }

  /// Where the Flutter app lives, when it is not the repository root.
  ///
  /// The same value `--app-dir` takes, and overridden by it.
  final String? appDir;

  /// How Apple provisioning profiles are come by. See [AppleSigning].
  final AppleSigning signing;

  /// The `appstore:` block, or null when the repository does not declare one.
  ///
  /// Null and empty are different answers and must stay so: null means *this
  /// project does not publish to the App Store*, and an empty block means *it
  /// does, and has declared nothing about it* — which is a misconfiguration
  /// rather than a project with no requirements.
  final StoreConfig? appstore;

  /// The `play:` block. Same distinction as [appstore].
  final StoreConfig? play;

  /// The `tag.upload:` block, defaulted rather than nullable — "absent" and
  /// "declared but off" are the same instruction here, unlike the store blocks
  /// above, where absence says the project does not publish there at all.
  final TagKindConfig uploadTag;

  /// How `release finish` names its tag.
  final TagKindConfig releaseTag;

  /// Reads and cross-checks the `apple:` block.
  ///
  /// Both checks live here, in plaintext, on purpose: they are the half of the
  /// design that can be evaluated with no identity and on any platform.
  /// Everything about a profile *blob* — whether it parses, which platform it
  /// is for — needs `security cms -D` and therefore a Mac, so a Linux run must
  /// still be able to tell a consumer that its configuration disagrees with
  /// itself.
  static AppleSigning _apple(YamlMap document) {
    final apple = document['apple'];
    if (apple == null) {
      return AppleSigning.automatic;
    }
    if (apple is! YamlMap) {
      throw ProjectException(
        '$cuxShipConfigFile: apple must be a mapping, and is a '
        '${apple.runtimeType}',
      );
    }

    _checkKeys(apple, _knownAppleKeys, 'apple');

    final signing = switch (_string(apple, 'signing')) {
      null || 'automatic' => AppleSigning.automatic,
      'manual' => AppleSigning.manual,
      final other => throw ProjectException(
        '$cuxShipConfigFile: apple.signing must be automatic or manual, '
        'and is $other',
      ),
    };
    return signing;
  }

  /// Reads an `appstore:` or `play:` block.
  ///
  /// Returns null when the key is absent, which is the signal that the project
  /// does not publish to that store. An empty mapping is *not* the same thing
  /// and is preserved: it says the project publishes there and has declared
  /// nothing, which the commands refuse rather than treat as no requirements.
  static StoreConfig? _store(YamlMap document, String key) {
    // containsKey rather than a null test. `appstore:` with nothing under it is
    // the most natural way to write "this project publishes there", and reading
    // it as absent would classify it as "does not publish" and then report that
    // it was never declared — while the reader is looking at the line that
    // declares it.
    if (!document.containsKey(key)) {
      return null;
    }
    final block = document[key];
    if (block == null) {
      return const StoreConfig();
    }
    if (block is! YamlMap) {
      throw ProjectException(
        '$cuxShipConfigFile: $key must be a mapping, and is a '
        '${block.runtimeType}',
      );
    }
    _checkKeys(block, _knownStoreKeys, key);

    final screenshots = <String, Set<String>>{};
    final declared = block['screenshots'];
    if (declared is YamlList) {
      // Play's shape: one flat list, because Play has no platform axis.
      screenshots[StoreConfig.anyPlatform] = _stringList(
        declared,
        '$key.screenshots',
      );
    } else if (declared is YamlMap) {
      // The App Store's shape: per platform, because one tree serves both and
      // the required types differ.
      //
      // **Play does not have this shape**, and saying so is not pedantry. Play
      // has no platform axis, so every Play consumer reads the flat list; a
      // `play: screenshots: {ios: […]}` would parse, validate, and then be
      // read by nobody — a declared requirement enforcing nothing, which is
      // the failure this file's header exists to refuse. Worse than being
      // ignored: the platform check below would *legitimize* Apple's names
      // inside a Play block.
      if (key != 'appstore') {
        throw ProjectException(
          '$cuxShipConfigFile: $key.screenshots is a mapping of platform to '
          'list, and only appstore: has platforms — Play publishes one set, so '
          'write it as a list',
        );
      }
      for (final entry in declared.entries) {
        final platform = '${entry.key}';
        // Checked against the values --platform takes, so the flag and the file
        // cannot drift apart — and so a typo is refused rather than silently
        // requiring nothing, which is the failure this file's header vows to
        // refuse everywhere. An earlier revision claimed this check existed
        // elsewhere; it did not, and a misspelt platform key parsed cleanly and
        // was ignored.
        if (!ascPlatforms.contains(platform)) {
          throw ProjectException(
            '$cuxShipConfigFile: $key.screenshots.$platform is not a platform '
            '(${(ascPlatforms.toList()..sort()).join(', ')})',
          );
        }
        final value = entry.value;
        if (value is! YamlList) {
          throw ProjectException(
            '$cuxShipConfigFile: $key.screenshots.$platform must be a list of '
            'screenshot types, and is a ${value.runtimeType}',
          );
        }
        screenshots[platform] = _stringList(
          value,
          '$key.screenshots.$platform',
        );
      }
    } else if (declared != null) {
      throw ProjectException(
        '$cuxShipConfigFile: $key.screenshots must be a list, or a mapping of '
        'platform to list, and is a ${declared.runtimeType}',
      );
    }

    final locales = block['locales'];
    return StoreConfig(
      locales: locales == null
          ? const {}
          : _stringList(
              locales is YamlList
                  ? locales
                  : throw ProjectException(
                      '$cuxShipConfigFile: $key.locales must be a list of '
                      'locales, and is a ${locales.runtimeType}',
                    ),
              '$key.locales',
            ),
      screenshots: screenshots,
    );
  }

  /// Every key in [map] has to be one of [known].
  ///
  /// Extracted at the third copy. The rule it enforces is the file's whole
  /// reason for existing — a misspelt key that is quietly skipped is a setting
  /// that appears to be applied and is not — so it should read the same
  /// wherever it is applied, and adding a block should not mean re-deriving it.
  ///
  /// [path] names the enclosing block, or null at the top level.
  static void _checkKeys(YamlMap map, Set<String> known, String? path) {
    final unknown =
        map.keys.map((k) => '$k').where((k) => !known.contains(k)).toList()
          ..sort();
    if (unknown.isEmpty) {
      return;
    }
    final where = path == null ? '' : ': $path';
    throw ProjectException(
      '$cuxShipConfigFile$where has '
      '${unknown.length == 1 ? 'an unknown key' : 'unknown keys'}: '
      '${unknown.join(', ')}\n'
      '    known keys: ${(known.toList()..sort()).join(', ')}',
    );
  }

  /// A YAML list of strings, as a set.
  ///
  /// A set because every consumer of these is asking *is this one required*,
  /// and because a repeated entry is a typo rather than a quantity. An entry
  /// that is not a string is refused rather than stringified: `locales: [en]`
  /// where somebody wrote `[en, 42]` is a mistake worth naming.
  static Set<String> _stringList(YamlList list, String where) {
    final values = <String>{};
    for (final value in list) {
      if (value is! String) {
        throw ProjectException(
          '$cuxShipConfigFile: $where contains a ${value.runtimeType}, and '
          'every entry has to be a string',
        );
      }
      if (value.isEmpty) {
        throw ProjectException(
          '$cuxShipConfigFile: $where contains an empty entry',
        );
      }
      values.add(value);
    }
    return values;
  }

  static String? _string(YamlMap map, String key) {
    final value = map[key];
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throw ProjectException(
        '$cuxShipConfigFile: $key must be a string, and is a '
        '${value.runtimeType}',
      );
    }
    return value;
  }
}
