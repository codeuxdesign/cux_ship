// SPDX-License-Identifier: Apache-2.0

// Publishes a signed .ipa, the App Store listing, or both, to App Store Connect.
//
//   cux_ship appstore upload --artifact dist/ios/x.ipa --bundle-id design.codeux.holdthewheel \
//     --build-number 12 --version-name 1.0.0 [--dry-run]
//
// A library rather than an executable: the `cux_ship` package wires [AscCommand]
// to subcommands, so there is one binary rather than one per store. What used to
// be modes selected by flag — `--promote`, `--list-builds` — are subcommands
// now, which is why [runAsc] takes the mode as an argument instead of reading it
// back out of [ArgResults].
//
// This program does the API work and nothing else: everything it needs arrives
// as an argument or, for the API key, as an environment variable. It still
// knows nothing about SOPS.
//
// **It used to know nothing about manifests either, and that has changed.** The
// rule was that a project's upload script had already checked the manifest, the
// artifact digest and the provenance rules. That held while every project had
// such a script — and on this side no such script has ever existed, so an Apple
// upload meant eight flags typed by hand, which in one afternoon produced three
// consecutive failed uploads and a fourth where iOS went up as build 51 while
// macOS went up as 52. `--manifest` is optional and an explicit flag still wins.
//
// The Apple counterpart of cux_ship_play, and deliberately shaped like it,
// with one difference that is not cosmetic: **App Store Connect has no edit
// transaction.** Play's uploader opens an edit, builds a whole release inside
// it, and commits or discards it atomically. Here every write lands the moment
// it is made. Two consequences run through the whole design:
//
//   - Everything that can be checked offline is checked before any credential
//     is even loaded, so a 4001-character description fails with no network
//     access at all. That is what makes `--metadata --dry-run` a usable lint.
//   - `--dry-run` does every read and prints every write it would make, but it
//     cannot rehearse Apple's own validation of a write. That is a weaker
//     promise than the Play side's and is said out loud rather than implied.
//
// --metadata publishes the store listing from a directory tree. Every argument
// is independent, so a listing-only push needs no artifact:
//
//   cux_ship appstore upload --bundle-id design.codeux.holdthewheel \
//     --metadata store/appstore --dry-run
//
// `appstore promote` is how the App Store is reached, and builds nothing: it
// points an App Store version at a build TestFlight already holds and submits it
// for review, so what ships is the identical binary testers ran rather than a
// rebuild of the same commit. It takes no --artifact, which is the whole point, and
// the CLI now enforces that by construction rather than by a validation error.
//
// `appstore builds` and `appstore versions` are the read side, and the only way
// to confirm a publish independently of the run that claims to have done it.
//
// What is *not* here is everything Apple has no API for: creating the app
// record, the App Privacy questionnaire, the agreements, and pricing. None of
// them are per-release state, so a normal release touches none of them. See
// docs/RELEASING-APPLE.md §4.
import 'dart:io';

import 'package:args/args.dart';
import 'package:cux_ship_verify/cux_ship_verify.dart';
import 'package:cux_ship_verify/metadata.dart';
import 'package:cux_ship_verify/release_notes.dart';

import '../asc_platforms.dart';
import '../listing_requirements.dart';
import '../notes_source.dart';
import '../reachable.dart';
import 'app_store.dart';
import 'asc_client.dart';
import 'signing_report.dart';
import 'testflight_notes.dart';

/// Which App Store Connect operation [runAsc] performs.
///
/// These were flags on one executable — `--promote`, `--list-builds` and the
/// rest — which meant every invocation had to be validated against every other
/// mode's arguments, and `--promote --ipa` was a combination the parser happily
/// accepted and the code then had to reject. As subcommands each one carries
/// only its own arguments, so most of those checks are now impossible to fail
/// rather than caught.
enum AscCommand {
  upload('upload'),
  promote('promote'),
  builds('builds'),
  versions('versions'),
  screenshotTypes('screenshot-types'),
  buildNumber('build-number'),
  awaitBuild('wait'),
  signing('signing');

  const AscCommand(this.name);

  /// The subcommand as typed, used in diagnostics.
  final String name;

  /// True for the operations that only read, which return before any write.
  bool get isRead => const {
    AscCommand.builds,
    AscCommand.versions,
    AscCommand.screenshotTypes,
    AscCommand.buildNumber,
    AscCommand.awaitBuild,
    AscCommand.signing,
  }.contains(this);
}

/// The locale the listing is written in.
///
/// Apple spells it `en-US`, matching a Play listing's default language rather
/// than diverging for no reason.
const _defaultLocale = 'en-US';

/// `45m`, `90s`, or a bare number of seconds. Null when it is none of those.
///
/// Its own function so `--timeout 45` cannot silently mean 45 microseconds,
/// which is what handing the string to a `Duration` constructor would invite.
/// Returns null rather than failing so the caller can name the option.
Duration? _duration(String value) {
  final match = RegExp(r'^(\d+)(s|m|h)?$').firstMatch(value.trim());
  if (match == null) {
    return null;
  }
  final n = int.parse(match.group(1)!);
  return switch (match.group(2)) {
    'm' => Duration(minutes: n),
    'h' => Duration(hours: n),
    _ => Duration(seconds: n),
  };
}

/// The arguments [cmd] accepts.
///
/// No `help` flag: `CommandRunner` adds one to every command it owns, and a
/// second would collide.
ArgParser buildAscParser(AscCommand cmd) {
  final parser = ArgParser()
    ..addOption('bundle-id', help: 'e.g. design.codeux.holdthewheel.')
    ..addOption(
      'platform',
      defaultsTo: 'ios',
      allowed: ascPlatforms,
      help: 'Which App Store platform to act on.',
    );

  if (cmd == AscCommand.awaitBuild) {
    parser
      ..addOption(
        'build-number',
        help:
            'The build to wait for. If this never arrives, check the bundle '
            'id first: a wrong one resolves to a different app and reports '
            'nothing uploaded, which reads like a build that has not landed. '
            'Required, and deliberately not defaulted '
            'to the newest: the point of waiting on another machine is to wait '
            'for a *specific* build, and "newest" would succeed on somebody '
            "else's upload.",
      )
      ..addOption(
        'timeout',
        defaultsTo: '45m',
        help: 'How long to wait before giving up, e.g. 45m or 90s.',
      )
      ..addOption('poll', defaultsTo: '30s', help: 'How often to ask.');
    return parser;
  }

  if (cmd.isRead) {
    return parser;
  }

  parser
    ..addOption('version-name', help: 'CFBundleShortVersionString.')
    ..addOption('locale', defaultsTo: _defaultLocale)
    ..addOption(
      'changelog',
      help:
          'CHANGELOG.md to take the release notes from, using the section for '
          'the version being released.',
    )
    ..addOption(
      'release-notes',
      help: 'File whose contents become the notes. Alternative to --changelog.',
    )
    ..addFlag('dry-run', negatable: false, help: 'Every read, no writes.');

  switch (cmd) {
    case AscCommand.upload:
      parser
        // Named for what it is rather than for one platform's extension.
        // `--platform macos` is first-class here, so a macOS release handing
        // its .pkg to a flag called `--ipa` read as though macOS had been
        // bolted onto an iOS-shaped command — and `--pkg`, which is what
        // anyone would try first, failed with "no such option". Both spellings
        // are accepted, so neither platform's users need the other's.
        ..addOption(
          'artifact',
          aliases: ['ipa', 'pkg'],
          help: 'Path to the signed .ipa (ios) or .pkg (macos).',
        )
        ..addOption(
          'build-number',
          help: 'CFBundleVersion; verified against what Apple reports.',
        )
        ..addOption(
          'commit',
          help:
              'The commit this artifact was BUILT from — a build manifest\'s '
              'gitSha, never a commit found by searching for a version. Only '
              'read when the repository declares tag.upload.enabled.',
        )
        ..addOption(
          'manifest',
          help:
              'A build manifest to take --artifact, --build-number, '
              '--version-name and --commit from, instead of typing them. The '
              'artifact is verified against the digest it records. Explicit '
              'flags still win.',
        )
        ..addFlag(
          'allow-dirty',
          negatable: false,
          help:
              'Upload a manifest whose build came from a dirty tree, where the '
              'commit it names does not describe what is in the artifact.',
        )
        ..addOption(
          'beta-group',
          help:
              'TestFlight group to give the build to. An internal group needs '
              "no review, which is the closest thing to Play's internal track.",
        )
        ..addOption(
          'metadata',
          help: 'Directory of store listing text and screenshots to publish.',
        )
        ..addFlag(
          'no-metadata',
          negatable: false,
          help:
              'Upload the build and nothing else, leaving the store listing '
              'untouched. For a TestFlight build, which is not a version '
              'submission and needs no listing — and which is otherwise '
              'refused whenever the App Store version is locked by review.',
        )
        ..addFlag(
          'skip-waiting',
          negatable: false,
          help:
              'Do not wait for Apple to finish processing the build. Leaves '
              'the release notes unset, so it is for debugging rather than '
              'releases.',
        );
    case AscCommand.promote:
      parser
        ..addOption(
          'beta-group',
          help:
              'Give the build to this TestFlight group instead of submitting '
              'it for review. Widening the audience of a build that already '
              'exists is what promotion means, and a group is an audience — so '
              'this needs no upload, creates no App Store version, and '
              'publishes no listing.',
        )
        ..addOption(
          'metadata',
          help:
              'Directory of store listing text and screenshots to publish. '
              'Submitting for review is when the listing becomes what a '
              'shopper reads, so this is where the committed tree is '
              'asserted; an upload never publishes it.',
        )
        ..addOption(
          'build-number',
          help:
              'Which processed build to submit. Defaults to the newest Apple '
              'holds.',
        )
        ..addFlag(
          'phased',
          negatable: false,
          help:
              "Release over Apple's seven-day phased schedule once approved. "
              'Not a fraction — Apple runs the schedule itself.',
        );
    case AscCommand.builds:
    case AscCommand.versions:
    case AscCommand.screenshotTypes:
    case AscCommand.buildNumber:
    case AscCommand.awaitBuild:
    case AscCommand.signing:
      throw StateError('unreachable: handled by cmd.isRead above');
  }

  return parser;
}

/// Values a caller worked out from the project, used where a flag was omitted.
///
/// Passed in rather than read here, because knowing what a Flutter project
/// looks like is not this package's business — it talks to App Store Connect.
class AscDefaults {
  const AscDefaults({
    this.bundleId,
    this.versionName,
    this.artifact,
    this.buildNumber,
    this.changelog,
    this.metadata,
    this.bundleIdProblem,
    this.listingRequirements,
    this.listingProblem,
  });

  /// Empty, for a caller that wants nothing inferred.
  static const none = AscDefaults();

  final String? bundleId;
  final String? versionName;
  final String? changelog;
  final String? metadata;

  /// The artifact and build number a build manifest recorded, when the caller
  /// resolved one. Both are overridden by an explicit flag — a manifest is
  /// inference, and inference loses to what was typed.
  final String? artifact;
  final String? buildNumber;

  /// Why [bundleId] is null, when the caller knows something worth saying.
  ///
  /// "None could be read" and "several were read, and none can be assumed"
  /// are different situations that one null cannot tell apart, and only the
  /// first is answered by *pass the flag*. Reporting the second as the first
  /// sends someone to look at their credentials or their app record, which is
  /// where the afternoon goes.
  final String? bundleIdProblem;

  /// What the repository declares the listing must carry, or null when it
  /// declares nothing. See [ListingRequirements].
  final ListingRequirements? listingRequirements;

  /// Why the requirement could not be worked out, when nothing declared one.
  ///
  /// Requiring nothing is a legitimate answer; requiring nothing *because the
  /// question could not be answered* is not, and the two are indistinguishable
  /// without this.
  final String? listingProblem;
}

/// Called once, immediately before the first write, with a summary of it.
///
/// Nothing here decides what confirmation means — it may prompt, or return at
/// once for `--yes`. Read-only commands and `--dry-run` never reach it.
typedef AscConfirm = void Function(String summary);

/// Runs [cmd] against App Store Connect.
///
/// [args] comes from [buildAscParser] for the same [cmd], so an option that
/// belongs to another subcommand is simply absent rather than null — hence the
/// `opt`/`flag` readers below. Anything still missing falls back to [defaults].
/// Publishes the App Store listing from a metadata tree.
///
/// **Its own function because two commands need it, for opposite reasons.** A
/// listing-only invocation publishes deliberately. A promotion publishes
/// because that is the moment the listing becomes what a shopper reads. An
/// upload carrying an artifact does neither: these writes reach
/// `appStoreVersionLocalizations` through `ensureVersion`, which *creates* the
/// version record, so publishing beside a TestFlight build would bring an App
/// Store version into existence for a release nobody had decided to make.
Future<void> _publishAscListing(
  AppStore store,
  App app,
  AppStoreMetadata metadata,
  String locale,
  String? versionName,
  // Passed rather than reached for: the caller's closure names the subcommand
  // in its message, and a listing failure should say whether it came from an
  // upload or a promote.
  Never Function(String) fail,
) async {
  final appInfo = await store.editableAppInfo(app);

  final contentRights = metadata.contentRights;
  if (contentRights != null) {
    stdout.writeln('==> content rights');
    await store.writeContentRights(app, contentRights);
  }

  if (metadata.categories.isNotEmpty) {
    stdout.writeln('==> categories');
    await store.writeCategories(appInfo, metadata.categories);
  }
  final ageRating = metadata.ageRating;
  if (ageRating != null) {
    stdout.writeln('==> age rating');
    await store.writeAgeRating(appInfo, ageRating);
  }

  for (final localeMetadata in metadata.locales) {
    if (localeMetadata.appInfo.isNotEmpty) {
      stdout.writeln('==> ${localeMetadata.locale}: name and subtitle');
      await store.writeAppInfoLocalization(
        appInfo,
        localeMetadata.locale,
        localeMetadata.appInfo,
      );
    }
  }

  // The version-scoped half needs a version to hang off. Created when
  // absent, because a listing push before the first release is exactly
  // when there is nothing there yet.
  final needsVersion =
      metadata.reviewNotes != null ||
      metadata.locales.any(
        (l) => l.version.isNotEmpty || l.screenshots.isNotEmpty,
      );
  if (needsVersion) {
    if (versionName == null) {
      fail(
        'pushing descriptions or screenshots needs --version-name, because '
        'Apple scopes them to a version rather than to the app',
      );
    }
    final version = await store.ensureVersion(app, versionName, create: true);
    if (version == null) {
      stdout.writeln(
        '    (dry run created no version, so the fields below are skipped)',
      );
    } else {
      final copyright = metadata.copyright;
      if (copyright != null) {
        stdout.writeln('==> copyright');
        await store.writeVersionAttributes(version, {'copyright': copyright});
      }

      final reviewNotes = metadata.reviewNotes;
      if (reviewNotes != null) {
        stdout.writeln('==> review notes');
        await store.writeReviewDetails(
          version,
          reviewNotes,
          contact: ReviewContact.fromEnvironment(),
        );
      }

      for (final localeMetadata in metadata.locales) {
        if (localeMetadata.version.isNotEmpty) {
          stdout.writeln('==> ${localeMetadata.locale}: listing text');
          await store.writeVersionLocalization(
            version,
            localeMetadata.locale,
            localeMetadata.version,
          );
        }
        if (localeMetadata.screenshots.isNotEmpty) {
          final localization = await store.versionLocalization(
            version,
            localeMetadata.locale,
          );
          if (localization == null) {
            stdout.writeln(
              '    (no ${localeMetadata.locale} localization yet, so its '
              'screenshots are skipped)',
            );
            continue;
          }
          for (final entry in localeMetadata.screenshots.entries) {
            stdout.writeln('==> ${localeMetadata.locale}: ${entry.key}');
            await store.replaceScreenshots(
              localization,
              entry.key,
              entry.value,
            );
          }
        }
      }
    }
  }
}

Future<void> runAsc(
  AscCommand cmd,
  ArgResults args, {
  AscDefaults defaults = AscDefaults.none,
  AscConfirm? confirm,
}) async {
  Never fail(String message) {
    stderr.writeln('cux_ship appstore ${cmd.name}: $message');
    exit(1);
  }

  String? opt(String name) =>
      args.options.contains(name) ? args.option(name) : null;
  bool flag(String name) => args.options.contains(name) && args.flag(name);

  final platform = AscPlatform.byName(opt('platform')!);
  final bundleId = opt('bundle-id') ?? defaults.bundleId;
  if (bundleId == null) {
    fail(
      defaults.bundleIdProblem ??
          'no bundle identifier — none could be read from the Xcode project, '
              'so pass --bundle-id',
    );
  }

  // Parsed and bounded here rather than at the point of use, because this
  // package checks what it can offline before loading a credential — and an
  // argument is the most checkable thing there is. Validated later, `--poll 0`
  // is reported only after the network has already been touched.
  Duration? awaitTimeout;
  Duration? awaitPoll;
  if (cmd == AscCommand.awaitBuild) {
    final timeoutText = args.option('timeout')!;
    final pollText = args.option('poll')!;
    awaitTimeout =
        _duration(timeoutText) ??
        fail('--timeout is "$timeoutText" — write it as 45m or 90s.');
    awaitPoll =
        _duration(pollText) ??
        fail('--poll is "$pollText" — write it as 45m or 90s.');
    // A floor, because the failure is silent and somebody else's: `--poll 0`
    // parses, and then asks Apple for builds as fast as the network allows for
    // as long as --timeout says. A typo that reads as harmless should be an
    // argument error rather than forty-five minutes of hammering.
    if (awaitPoll < const Duration(seconds: 1)) {
      fail(
        '--poll is "$pollText" — one second is the floor, or this becomes an '
        'unthrottled request loop against Apple.',
      );
    }
    if (awaitTimeout < const Duration(seconds: 1)) {
      fail(
        '--timeout is "$timeoutText" — at zero this checks once and then '
        'reports a build as refused for being young.',
      );
    }
  }

  final locale = opt('locale') ?? _defaultLocale;
  final dryRun = flag('dry-run');

  // Inference applies only where it makes sense. An upload publishes the
  // listing when there is one to publish; a promote never does, so the
  // metadata default is not offered to it.
  final ipaPath = opt('artifact') ?? defaults.artifact;
  // `--no-metadata` turns the inference off; it does not merely decline to add
  // one. Omitting `--metadata` never disabled the listing publish, because the
  // inference fills it from `store/appstore` whenever that directory exists —
  // so before this flag there was no way to put a build on TestFlight without
  // also pushing the listing, and a version locked by review (WAITING_FOR_REVIEW
  // or IN_REVIEW — both ordinary states) made that fail after the binary and
  // the notes had already gone up. A command that did everything asked and then
  // exited non-zero, which invites the one response that is wrong: run it again.
  // Promote resolves metadata as well as upload. It did not, which made the
  // listing publishable only by a listing-only invocation — so the design's
  // publication point had no code behind it.
  final noMetadata = cmd == AscCommand.upload && flag('no-metadata');
  if (noMetadata && opt('metadata') != null) {
    fail('--metadata and --no-metadata ask for opposite things');
  }
  final metadataPath =
      (cmd == AscCommand.upload || cmd == AscCommand.promote) && !noMetadata
      ? (opt('metadata') ?? defaults.metadata)
      : null;
  final promote = cmd == AscCommand.promote;
  final reads = cmd.isRead;

  if (cmd == AscCommand.upload && ipaPath == null && metadataPath == null) {
    fail('nothing to do — pass --artifact, --metadata, or both');
  }

  final versionName = opt('version-name') ?? defaults.versionName;
  final buildNumber = opt('build-number') ?? defaults.buildNumber;
  File? artifact;
  if (ipaPath != null) {
    if (buildNumber == null || versionName == null) {
      fail('--ipa also needs --build-number and --version-name');
    }
    if (int.tryParse(buildNumber) == null) {
      fail('--build-number must be an integer, got "$buildNumber"');
    }
    artifact = File(ipaPath);
    if (!artifact.existsSync()) {
      fail('no such file: $ipaPath');
    }
  }
  // A promotion to a beta group is exempt: it creates no App Store version, so
  // there is nothing for a version name to name. Requiring one would be asking
  // for a fact about a record the command deliberately does not make.
  if (promote && versionName == null && opt('beta-group') == null) {
    fail(
      'no version name — none could be read from pubspec.yaml, so pass '
      '--version-name to say which version to submit',
    );
  }

  final notesPath = opt('release-notes');
  // The changelog default applies only when no literal notes were given;
  // offering both and then refusing the pair would be inference creating the
  // conflict it complains about.
  final changelogPath =
      opt('changelog') ?? (notesPath == null ? defaults.changelog : null);
  if (notesPath != null && opt('changelog') != null) {
    fail('--release-notes and --changelog both supply the notes; pick one');
  }

  String? literalNotes;
  if (notesPath != null) {
    final file = File(notesPath);
    if (!file.existsSync()) {
      fail('no such release notes file: $notesPath');
    }
    literalNotes = file.readAsStringSync().trim();
    if (literalNotes.length > appStoreReleaseNotesLimit) {
      fail(
        'release notes are ${literalNotes.length} characters; the App Store '
        'allows $appStoreReleaseNotesLimit',
      );
    }
  }

  // Read and validated before the credentials are even loaded. Everything that
  // can fail locally fails with no network access at all, which is what makes
  // `--metadata --dry-run` usable as an offline lint on a laptop with no
  // secrets — the same property cux_ship_play has.
  AppStoreMetadata? metadata;
  if (metadataPath != null) {
    try {
      metadata = loadMetadata(metadataPath);
    } on MetadataException catch (e) {
      fail(e.message);
    }

    // The requirements the *repository* declares, applied here and not only in
    // `verify`. A requirement that is a property of the repository and is
    // enforced by one command out of two is worse than a flag, because it
    // reads as a standing fact and is not one. This is the command that
    // reaches Apple, so it is the one that must not publish a listing missing
    // a locale somebody declared.
    final listingProblem = defaults.listingProblem;
    if (listingProblem != null) {
      fail(listingProblem);
    }

    final requirements = defaults.listingRequirements;
    if (requirements != null) {
      final problems = checkAppStoreTree(
        metadataPath,
        requireScreenshotTypes: requirements.screenshotTypes,
        requireLocales: requirements.locales,
      );
      if (problems.isNotEmpty) {
        fail(
          'the listing does not satisfy what this repository declares:\n'
          '${problems.map((ReleaseProblem p) => '    $p').join('\n')}',
        );
      }
    }

    stdout.writeln(
      '==> ${metadata.locales.length} locale(s), '
      '${metadata.categories.length} categor(y|ies)'
      '${metadata.ageRating == null ? '' : ', age rating'}'
      '${metadata.reviewNotes == null ? '' : ', review notes'} validated',
    );

    // Reported, never fatal. A URL can be legitimately dead at exactly one
    // release — a policy site deployed after the app it belongs to — and a
    // gate there would fail correctly and teach the bypass. See reachable.dart.
    //
    // **Not under --dry-run.** The block above promises that
    // `--metadata --dry-run` validates a tree "with no network access at all",
    // which is what makes it usable as an offline lint on a laptop with no
    // secrets. A reachability check there would break that promise and, worse,
    // print "could not be reached" about a URL that is fine — a false alarm
    // this file's own reasoning says is the thing to avoid, since it is what
    // teaches people to ignore the check.
    for (final locale in dryRun ? const <LocaleMetadata>[] : metadata.locales) {
      final urls = <String, String>{
        for (final field in const [
          'privacyPolicyUrl',
          'supportUrl',
          'marketingUrl',
        ])
          if (locale.appInfo[field] != null) field: locale.appInfo[field]!,
        for (final field in const ['supportUrl', 'marketingUrl'])
          if (locale.version[field] != null) field: locale.version[field]!,
      };
      for (final problem in await unreachableUrls(urls)) {
        stdout.writeln(
          '==> note: ${locale.locale} ${problem.field} '
          '${problem.url} ${problem.detail}',
        );
      }
    }
  }

  /// Release notes for [forVersion], resolved late because promotion does not
  /// know its version until Apple has said what is on TestFlight.
  String? notesFor(String forVersion) {
    if (changelogPath == null) {
      return literalNotes;
    }
    requireCommittedNotes([changelogPath]);
    final notes = changelogNotesOf(
      changelogPath,
      forVersion,
      platform: platform.changelog,
    );
    switch (notes) {
      case NoSection():
        fail(
          '$changelogPath has no section for $forVersion.\n'
          '  Add one. Empty is a fine answer — it publishes the newest older\n'
          '  version that did change something here, or\n'
          '  "$noUserVisibleChanges" if there is none. Absent is not the same\n'
          '  answer as empty.',
        );
      case NotesText(:final text, :final fromVersion):
        if (text.length > appStoreReleaseNotesLimit) {
          fail(
            "$changelogPath's $fromVersion section is ${text.length} "
            'characters once filtered to ${platform.changelog}; the App Store '
            'allows $appStoreReleaseNotesLimit',
          );
        }
        // Said out loud: publishing one version's notes under another
        // version's name should never happen quietly.
        if (fromVersion.isEmpty) {
          stdout.writeln(
            '==> nothing at or below $forVersion is user-visible on '
            '${platform.changelog} — publishing "$text"',
          );
        } else if (fromVersion != forVersion) {
          stdout.writeln(
            '==> $forVersion changes nothing on ${platform.changelog} — '
            "publishing $fromVersion's notes instead",
          );
        }
        return text;
    }
  }

  // Asked after every offline check and before any credential is loaded, so a
  // typo in the metadata tree is reported without the prompt in the way, and
  // nothing has touched the network by the time the question is put.
  //
  // Read-only commands and --dry-run skip it: neither writes anything, and a
  // prompt on a harmless command is how the habit of answering yes is learned.
  if (confirm != null && !reads && !dryRun) {
    confirm(
      _summarizeAsc(
        cmd: cmd,
        bundleId: bundleId,
        platform: platform.name,
        versionName: versionName,
        buildNumber: buildNumber,
        ipaPath: ipaPath,
        metadataPath: metadataPath,
        changelogPath: changelogPath,
        locale: locale,
        phased: flag('phased'),
      ),
    );
  }

  // Built only once every local check has passed.
  final AscCredentials credentials;
  try {
    final loaded = AscCredentials.fromEnvironment();
    if (loaded == null) {
      fail(
        'no App Store Connect credentials.\n'
        '  APPLE_API_KEY_ID, APPLE_API_ISSUER_ID and APPLE_API_PRIVATE_KEY_PATH\n'
        '  are set by tool/with-secrets.sh. Run this through it, or export them\n'
        '  yourself. See docs/RELEASING-APPLE.md §1.',
      );
    }
    credentials = loaded;
  } on StateError catch (e) {
    fail(e.message);
  }

  final client = AscClient(credentials);

  // Account wide, so it returns before resolveApp: the audit is about the
  // team's certificates and identifiers, and asking Apple to resolve an app
  // would fail for a project that has no App Store record yet.
  if (cmd == AscCommand.signing) {
    final ok = await reportSigning(client, bundleId: bundleId);
    if (!ok) {
      exit(1);
    }
    return;
  }

  final writer = Writer(client, dryRun: dryRun);
  final store = AppStore(client, writer, platform: platform);

  if (dryRun) {
    stdout.writeln(
      '==> dry run: every read happens, no write does. App Store Connect has\n'
      '    no edit transaction, so this cannot rehearse Apple\'s validation of\n'
      '    a write the way the Play uploader can.',
    );
  }

  try {
    final app = await store.resolveApp(bundleId);
    if (cmd != AscCommand.buildNumber) {
      stdout.writeln('==> ${app.name} ($bundleId) is app ${app.id}');
    }

    if (cmd == AscCommand.buildNumber) {
      await store.printBuildNumber(app);
      return;
    }
    if (cmd == AscCommand.awaitBuild) {
      // Positional, because it is required anyway and `wait 2132` is what the
      // command is for. `--build-number` still works: the composition this
      // exists to serve is `appstore wait $(cux_ship appstore build-number)`,
      // and both spellings read the same there.
      final positional = args.rest.isEmpty ? null : args.rest.first;
      final buildNumber = positional ?? args['build-number'] as String?;
      if (buildNumber == null || buildNumber.isEmpty) {
        fail(
          'which build? Pass it as `appstore wait <build-number>`. '
          'Deliberately not defaulted to the newest: the point of waiting from '
          'another machine is to wait for a *specific* build, and "newest" '
          "would succeed on somebody else's upload.",
        );
      }
      final flagged = args['build-number'] as String?;
      if (positional != null && flagged != null) {
        fail(
          'the build number was given twice, as "$positional" and as '
          '"$flagged" — pass it once.',
        );
      }
      await store.awaitProcessing(
        app,
        buildNumber,
        timeout: awaitTimeout!,
        poll: awaitPoll!,
      );
      return;
    }
    if (cmd == AscCommand.builds) {
      await store.listBuilds(app);
    }
    if (cmd == AscCommand.versions) {
      await store.listVersions(app);
    }
    if (cmd == AscCommand.screenshotTypes) {
      await store.listScreenshotTypes(app);
    }
    if (reads) {
      return;
    }

    // ------------------------------------------------------------- the build

    Map<String, dynamic>? build;
    if (artifact != null) {
      // Apple never accepts a CFBundleVersion twice and answers the attempt
      // with ITMS-90189. A build number is allocated once per commit and a
      // release build refuses a dirty tree, so "Apple holds this build number"
      // means "Apple holds this commit's binary" — nothing is being confused
      // with anything else, and the honest thing is to use it. The binaries
      // are deliberately not compared: two archives over one commit differ
      // byte for byte, so provenance rests on the commit here as it does
      // everywhere else in this tooling.
      final existing = await store.findBuild(app, buildNumber!);
      if (existing != null) {
        stdout.writeln(
          '==> Apple already holds build $buildNumber — using it rather than '
          're-uploading',
        );
      } else {
        await uploadPackage(
          ipa: artifact,
          app: app,
          platform: platform,
          versionName: versionName!,
          buildNumber: buildNumber,
          credentials: credentials,
          dryRun: dryRun,
        );
      }

      if (dryRun && existing == null) {
        stdout.writeln('    would then wait for processing and set the notes');
      } else if (flag('skip-waiting')) {
        stdout.writeln('==> not waiting for processing, as asked');
      } else {
        build = await store.awaitProcessing(app, buildNumber);

        final notes = notesFor(versionName!);
        if (notes != null) {
          stdout.writeln('==> TestFlight notes');
          // TestFlight refuses emoji, which CHANGELOG.md is full of by design.
          // Said out loud rather than done quietly, because what testers read
          // then differs from what Play users read.
          var testFlightNotes = notes;
          if (needsStrippingForTestFlight(notes)) {
            testFlightNotes = stripForTestFlight(notes);
            stdout.writeln(
              '    TestFlight rejects emoji, so they are stripped from the '
              'notes\n'
              '    (the App Store release notes keep them)',
            );
          }
          await store.setWhatToTest(build, locale, testFlightNotes);
        }
        final group = opt('beta-group');
        if (group != null) {
          stdout.writeln('==> beta group');
          await store.addToBetaGroup(app, build, group);
        }
      }
    }

    // ---------------------------------------------------------- the listing

    // **An upload carrying an artifact does not write the listing.**
    //
    // The writes below reach `appStoreVersionLocalizations` through
    // `ensureVersion`, which *creates* the version record — so publishing the
    // listing alongside a TestFlight build brings an App Store version into
    // existence for a release nobody has decided to make, and fills it with
    // whatever the working tree says. The store-metadata design puts listing
    // publication at the promotion to the public audience for exactly that
    // reason.
    //
    // A listing-only invocation — `--metadata` with no artifact — is the
    // deliberate exception, the same one Play's `--listing-only` is: nothing is
    // being shipped for the copy to be ahead of, and moving the live page now
    // is the entire purpose of the command.
    if (metadata != null && ipaPath != null) {
      stdout.writeln(
        '==> listing: untouched — an upload does not publish it.\n'
        '    Publish deliberately with --metadata and no artifact.',
      );
    } else if (metadata != null) {
      await _publishAscListing(store, app, metadata, locale, versionName, fail);
    }

    // -------------------------------------------------------------- promote

    if (promote) {
      // Read rather than assumed. The point of promoting is that what goes to
      // review is what testers ran, and that only holds if the build comes
      // from what Apple says it has.
      final builds = await store.builds(app);
      final usable = builds
          .where(
            (b) =>
                (b['attributes']
                        as Map<String, dynamic>?)?['processingState'] ==
                    'VALID' &&
                (b['attributes'] as Map<String, dynamic>?)?['expired'] != true,
          )
          .toList();
      if (usable.isEmpty) {
        fail('no processed, unexpired build to promote');
      }
      usable.sort((a, b) {
        int number(Map<String, dynamic> x) =>
            int.tryParse(
              '${(x['attributes'] as Map<String, dynamic>?)?['version']}',
            ) ??
            -1;
        return number(b).compareTo(number(a));
      });
      final chosen = buildNumber == null
          ? usable.first
          : usable.firstWhere(
              (b) =>
                  '${(b['attributes'] as Map<String, dynamic>?)?['version']}' ==
                  buildNumber,
              orElse: () => fail(
                'build $buildNumber is not a processed build of this app',
              ),
            );

      // **A group is an audience, so giving a build to one is a promotion.**
      // It is the same operation Play calls promotion — an existing build, no
      // upload, a wider audience — and spelling it this way is what makes the
      // listing rule derived rather than asserted: promotions to the public
      // audience publish, promotions to a group do not, on both stores for one
      // reason.
      //
      // No `--version-name` is required and no version is created. An App
      // Store version is the public artefact; a TestFlight group is not, and
      // conflating them is how a version record appears for a release nobody
      // has decided to make.
      final betaGroup = opt('beta-group');
      if (betaGroup != null) {
        final number =
            (chosen['attributes'] as Map<String, dynamic>?)?['version'];
        stdout.writeln('==> giving build $number to "$betaGroup"');
        await store.addToBetaGroup(app, chosen, betaGroup);
        stdout.writeln(
          '==> done — not submitted for review, and the listing is untouched',
        );
        if (dryRun) {
          // Said here because this path returns before the closing notice, and
          // a dry run that printed "done" and nothing else would read as a
          // write that happened.
          stdout.writeln('==> dry run — nothing was written');
        }
        return;
      }

      final version = await store.ensureVersion(
        app,
        versionName!,
        create: true,
      );

      if (version != null) {
        await store.attachBuild(version, chosen);

        final notes = notesFor(versionName);
        if (notes != null) {
          // A first release has no "What's New": there is no previous version
          // for it to be new against, and Apple refuses the write with a
          // message that does not explain itself. The description carries the
          // story for a first release, and it is already published from
          // store/appstore/.
          if (await store.isFirstVersion(app, version)) {
            stdout.writeln(
              '==> $versionName is this app\'s first App Store version, so it '
              'has no\n'
              '    "What\'s New" — the release notes are skipped and the '
              'description stands',
            );
          } else {
            stdout.writeln('==> release notes');
            await store.writeVersionLocalization(version, locale, {
              'whatsNew': notes,
            });
          }
        }
        if (flag('phased')) {
          stdout.writeln('==> phased release');
          await store.enablePhasedRelease(version);
        }
        // **The listing publishes here, and only here.** This is the moment
        // it becomes what a shopper reads, and the version record it hangs
        // off exists by now — which is what makes it possible at all. Before
        // the submission, so a review sees the copy that was meant to
        // accompany it rather than the previous release's.
        if (metadata != null) {
          await _publishAscListing(
            store,
            app,
            metadata,
            locale,
            versionName,
            fail,
          );
        }

        stdout.writeln('==> submitting for review');
        await store.submitForReview(app, version);
      }
    }

    if (dryRun) {
      stdout.writeln('==> dry run — nothing was written');
    } else {
      stdout.writeln('==> done');
    }
  } on AscApiException catch (e) {
    stderr.writeln('asc_upload: $e');
    exitCode = 1;
  } on ProcessingTimeout catch (e) {
    // Caught rather than left to the runtime: an uncaught exception exits 255
    // with a stack trace, and a stack trace above the one sentence that says
    // "read the e-mail" is how that sentence gets skimmed past.
    stderr.writeln('asc_upload: $e');
    exitCode = 1;
  } on MetadataException catch (e) {
    stderr.writeln('asc_upload: ${e.message}');
    exitCode = 1;
  } finally {
    client.close();
  }
}

/// What is about to happen, in the terms the caller will recognise.
///
/// Built here rather than by the caller because only this function knows what
/// each subcommand actually does with the arguments — that `promote` ignores a
/// metadata tree, or that an absent `--build-number` means "whatever Apple says
/// is newest" rather than nothing.
String _summarizeAsc({
  required AscCommand cmd,
  required String bundleId,
  required String platform,
  required String? versionName,
  required String? buildNumber,
  required String? ipaPath,
  required String? metadataPath,
  required String? changelogPath,
  required String locale,
  required bool phased,
}) {
  final rows = <String, String?>{
    'app': '$bundleId ($platform)',
    'version': versionName,
    'build': switch (cmd) {
      AscCommand.promote => buildNumber ?? 'newest processed build Apple holds',
      _ => buildNumber,
    },
    'artifact': ipaPath,
    'listing': metadataPath,
    'notes from': changelogPath,
    'locale': locale,
    'phased': phased ? 'yes — over Apple\'s seven-day schedule' : null,
  };

  final heading = switch (cmd) {
    AscCommand.promote =>
      'About to submit for App Store review. Once Apple approves it, this is '
          'public.',
    AscCommand.upload when ipaPath != null =>
      'About to upload a build to TestFlight'
          '${metadataPath == null ? '' : ' and publish the listing'}.',
    _ => 'About to publish the App Store listing.',
  };

  final width = rows.entries
      .where((e) => e.value != null)
      .map((e) => e.key.length)
      .fold(0, (a, b) => a > b ? a : b);
  final buffer = StringBuffer('\n$heading\n');
  for (final row in rows.entries) {
    if (row.value == null) {
      continue;
    }
    buffer.writeln('  ${row.key.padRight(width)}   ${row.value}');
  }
  return buffer.toString();
}
