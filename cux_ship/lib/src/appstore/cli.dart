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
import '../release.dart' show ReleaseException;
import 'app_store.dart';
import 'apple_notes.dart';
import 'asc_client.dart';
import 'beta_release.dart';
import 'signing_report.dart';

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
  betaRelease('beta-release'),
  builds('builds'),
  betaGroups('beta-groups'),
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
    AscCommand.betaGroups,
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

/// `--beta-description`, shared by every command that can reach an external
/// group. A file option and never a bare string, for the release-notes
/// reason: what testers read should be committed, reviewable text, not
/// whatever was in a shell history.
const _betaDescriptionHelp =
    'File whose contents become the TestFlight Beta App Description for '
    '--locale, which Apple requires before an external group can receive a '
    'build. Without it, listings/<locale>/beta_description.txt in the '
    'metadata tree applies when present, and an absent file leaves whatever '
    'App Store Connect holds alone.';

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

  // Like `wait`, this carries only its own arguments: no artifact, no
  // changelog, no version name — it builds nothing, sets no notes, and names
  // no App Store version, so those options would be questions with no answer.
  if (cmd == AscCommand.betaRelease) {
    parser
      ..addOption(
        'build-number',
        help:
            'The build TestFlight already holds. Required, and deliberately '
            'not defaulted to the newest: a release to testers is a release '
            'of a *specific* build, and "newest" would release somebody '
            "else's upload.",
      )
      ..addOption(
        'beta-group',
        help:
            'TestFlight group to release the build to. An internal group '
            'receives it by assignment alone; an external one is carried on '
            'through beta review, without which it receives nothing.',
      )
      ..addOption('beta-description', help: _betaDescriptionHelp)
      ..addOption('locale', defaultsTo: _defaultLocale)
      ..addFlag('dry-run', negatable: false, help: 'Every read, no writes.');
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
              "no review, which is the closest thing to Play's internal "
              'track; an external group is carried on through beta review, '
              'without which it receives nothing.',
        )
        ..addOption('beta-description', help: _betaDescriptionHelp)
        ..addOption(
          'metadata',
          help: 'Directory of store listing text and screenshots to publish.',
        )
        ..addFlag(
          'no-metadata',
          negatable: false,
          help:
              'Leave the store listing untouched: upload the build, and any '
              '--beta-group release, and nothing else. For a TestFlight '
              'build, which is not a version submission and needs no listing '
              '— and which is otherwise refused whenever the App Store '
              'version is locked by review.',
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
        ..addOption('beta-description', help: _betaDescriptionHelp)
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
    case AscCommand.betaRelease:
    case AscCommand.builds:
    case AscCommand.betaGroups:
    case AscCommand.versions:
    case AscCommand.screenshotTypes:
    case AscCommand.buildNumber:
    case AscCommand.awaitBuild:
    case AscCommand.signing:
      throw StateError('unreachable: handled by cmd.isRead or above');
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
/// Whether a run publishes the App Store listing, and at which point.
///
/// **One decision, taken once and read at both places that act on it.** The
/// listing publish is reachable from two sites — the shared one after the
/// upload block, and the one inside the promote block that runs after the
/// build is attached and before the submission. Each used to carry its own
/// condition (`metadata != null` at both), and both were true for a
/// promote-with-metadata: the whole listing published twice, every screenshot
/// cleared and re-uploaded twice, under a comment claiming "the listing
/// publishes here, and only here".
///
/// Complementary conditions at two sites are the defect this file keeps
/// producing — the same shape as the `--beta-group` publish it took 3.5.0 to
/// close. An enum cannot be true in two places at once.
enum ListingPublish {
  /// Nothing to publish, or an artifact upload, which deliberately leaves the
  /// listing alone.
  none,

  /// At the shared site: a listing-only invocation, which is the whole point
  /// of the command.
  shared,

  /// Inside the promote block, after the build is attached and before the
  /// submission — so a review sees the copy meant to accompany it, from a
  /// version record that exists by then.
  afterVersion,
}

/// Decides [ListingPublish] from what the run was asked to do.
///
/// Pure, and separate from [runAsc], because a decision buried in a method
/// that needs credentials to reach is a decision nothing will check.
ListingPublish listingPublish({
  required bool hasMetadata,
  required bool hasArtifact,
  required bool promote,
}) {
  if (!hasMetadata) {
    return ListingPublish.none;
  }
  // An upload carrying an artifact publishes nothing: these writes reach
  // `appStoreVersionLocalizations` through `ensureVersion`, which *creates*
  // the version record. Checked before [promote] because the two are not
  // mutually exclusive in the argument parser's eyes.
  if (hasArtifact) {
    return ListingPublish.none;
  }
  return promote ? ListingPublish.afterVersion : ListingPublish.shared;
}

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
  // **Decide what needs writing before demanding something to write to.**
  //
  // The app-level half used to open with `editableAppInfo`, which threw when
  // no record was in an editable state — so a promotion whose listing was
  // already correct still failed, and failed before the version was created,
  // the build attached or the submission made. Nothing downstream ran.
  //
  // The order below is what keeps a failure atomic. The collection is read
  // once; the comparison runs against the record [selectAppInfo] would read;
  // the writable record is only demanded once something is known to need one,
  // and that demand throws while nothing has been written yet. Every write,
  // content rights included, happens after it.
  final infos = await store.appInfos(app);
  final readable = selectAppInfo(infos, AppInfoUse.read);

  // Both sub-resources are read once, here, and the same readings serve the
  // comparison and the write below — so the two cannot disagree about which
  // declaration the answers were checked against, or about whether a locale
  // already has a record.
  final declaration = readable == null || metadata.ageRating == null
      ? null
      : await store.ageRatingDeclaration(readable);
  final localizations =
      readable == null || !metadata.locales.any((l) => l.appInfo.isNotEmpty)
      ? null
      : await store.appInfoLocalizations(readable);

  final changes = appLevelChanges(
    metadata: metadata,
    currentContentRights: app.contentRights,
    appInfo: readable,
    ageRatingDeclaration: declaration,
    appInfoLocalizations: localizations,
  );

  if (changes.unverifiable.isNotEmpty) {
    // Said out loud: these are being written because they could not be shown
    // to already match, which is not the same as knowing they differ.
    stdout.writeln(
      '==> could not read the current ${changes.unverifiable.join(", ")}, '
      'so ${changes.unverifiable.length == 1 ? 'it is' : 'they are'} '
      'written rather than assumed unchanged',
    );
  }

  Map<String, dynamic>? appInfo;
  if (changes.needsAppInfo) {
    // Throws here, before the first write, naming what would have gone in.
    // [selectAppInfo] picks the same record for a write as for the read
    // above whenever a write target exists at all, so what was compared is
    // what is written.
    appInfo = requireWritableAppInfo(infos, fields: changes.appInfoFields);
  } else if (changes.isEmpty && declaresAppLevelFields(metadata)) {
    // Only when the tree actually declares app-level fields. Saying "already
    // matches" about fields nobody asked for would report a comparison that
    // never happened.
    stdout.writeln('==> app-level listing: already matches, nothing written');
  }

  if (metadata.ageRating != null &&
      changes.ageRating == null &&
      changes.unverifiable.contains(ageRatingField)) {
    // There is a record but no declaration hanging off it to write answers
    // to. Raised here, beside the other acquisition and still before the
    // first write, because publishing everything *except* the age rating
    // would leave a version Apple refuses to review — and doing it after
    // content rights had gone up would turn a clean failure into a
    // half-applied change.
    throw AscApiException(404, [
      'the app has no ageRatingDeclaration to write to',
    ], request: 'GET /v1/appInfos');
  }

  final contentRights = changes.contentRights;
  if (contentRights != null) {
    stdout.writeln('==> content rights');
    await store.writeContentRights(app, contentRights);
  }

  if (appInfo != null) {
    if (changes.categories.isNotEmpty) {
      stdout.writeln('==> categories');
      await store.writeCategories(appInfo, changes.categories);
    }
    final ageRating = changes.ageRating;
    if (ageRating != null) {
      stdout.writeln('==> age rating');
      await store.writeAgeRating(ageRating);
    }

    for (final entry in changes.localizations.entries) {
      stdout.writeln('==> ${entry.key}: ${entry.value.keys.join(", ")}');
      await store.writeAppInfoLocalization(
        appInfo,
        entry.key,
        entry.value,
        // The reading the comparison was made from. Non-null whenever there
        // is a localization to write: `changes.localizations` is only
        // populated for locales the metadata asks for, which is exactly what
        // made this read happen.
        existing: localizations ?? const [],
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
  final betaGroup = opt('beta-group');
  // A promotion to a group publishes no listing — which is `--beta-group`'s
  // own help text, and until here it was false: promote resolved the inferred
  // store/appstore tree and the listing publish ran before the group block
  // was reached, so `promote --beta-group X` published the whole listing,
  // could create an App Store version, and then printed "the listing is
  // untouched". Suppressing the inference is what makes the help text true;
  // an *explicit* `--metadata` alongside is a contradiction and is refused
  // rather than quietly dropped. The same shape as the version-name
  // exemption below. The beta description still resolves through
  // [listingTree] — test information, not listing.
  if (cmd == AscCommand.promote &&
      betaGroup != null &&
      opt('metadata') != null) {
    fail(
      '--metadata and --beta-group ask for opposite things on promote: a '
      'promotion to a group publishes no listing',
    );
  }
  final metadataPath =
      (cmd == AscCommand.upload || cmd == AscCommand.promote) &&
          !noMetadata &&
          !(cmd == AscCommand.promote && betaGroup != null)
      ? (opt('metadata') ?? defaults.metadata)
      : null;
  // The tree the beta app description lives in — deliberately not the gated
  // [metadataPath]. `--no-metadata` declines the App Store listing publish,
  // and the beta description is not listing: it is TestFlight test
  // information, the thing a `--no-metadata` TestFlight upload exists to
  // deliver.
  final listingTree = opt('metadata') ?? defaults.metadata;
  final promote = cmd == AscCommand.promote;
  final reads = cmd.isRead;

  if (cmd == AscCommand.betaRelease) {
    if (betaGroup == null) {
      fail(
        'which group? --beta-group names the TestFlight group to release to. '
        'App Store Connect > TestFlight > Groups is where they are made.',
      );
    }
    final number = opt('build-number');
    if (number == null) {
      fail(
        'which build? --build-number is required, and deliberately not '
        'defaulted to the newest Apple holds: a release to testers is a '
        'release of a *specific* build, and "newest" would release somebody '
        "else's upload.",
      );
    }
    if (int.tryParse(number) == null) {
      fail('--build-number must be an integer, got "$number"');
    }
    // `wait 2132` reads naturally because that command declares its build
    // number positional; this one does not, so a stray positional here is
    // most likely a build number the run would then silently not use.
    if (args.rest.isNotEmpty) {
      fail(
        'unexpected argument "${args.rest.first}" — beta-release takes '
        '--build-number and --beta-group as options',
      );
    }
  }

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
  // conflict it complains about. beta-release takes no notes at all — the
  // "What to Test" came with the upload — so the default is not offered to it.
  final changelogPath = cmd == AscCommand.betaRelease
      ? null
      : opt('changelog') ?? (notesPath == null ? defaults.changelog : null);
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

  // The beta app description, resolved offline exactly like the notes above —
  // and the placement is load-bearing on `upload --beta-group`: the artifact,
  // the processing wait and the notes all land before the group step, so a
  // typo'd path, a dirty file or an over-limit one discovered there would
  // refuse *after* the build went up. Here it refuses before a credential is
  // even loaded; only "is there a description anywhere" needs the network and
  // stays in the flow.
  final betaDescriptionPath = opt('beta-description');
  if (betaDescriptionPath != null && betaGroup == null) {
    fail(
      '--beta-description without --beta-group publishes nothing — name the '
      'group the description is for',
    );
  }
  // Incompatible rather than quietly reordered: the group step needs the
  // processed build, which is exactly the wait --skip-waiting declines. The
  // old behaviour was worse than either — the group was silently skipped and
  // the run still printed done.
  if (betaGroup != null && cmd == AscCommand.upload && flag('skip-waiting')) {
    fail(
      '--skip-waiting and --beta-group ask for incompatible things: a build '
      'cannot reach a group until Apple finishes processing it',
    );
  }
  BetaDescription? betaDescription;
  if (betaGroup != null) {
    try {
      betaDescription = resolveBetaDescription(
        optionPath: betaDescriptionPath,
        metadataPath: listingTree,
        locale: locale,
      );
    } on ReleaseException catch (e) {
      fail(e.message);
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

  // Decided here, once, and read at both sites below. See [ListingPublish]
  // for why this is an enum and not two conditions.
  final publish = listingPublish(
    hasMetadata: metadata != null,
    hasArtifact: ipaPath != null,
    promote: promote,
  );

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
        betaGroup: betaGroup,
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
    if (cmd == AscCommand.betaGroups) {
      await store.listBetaGroups(app);
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

    // --------------------------------------------------------- beta-release

    // The TestFlight sibling of promote: submits a build TestFlight already
    // holds to a beta group, builds and uploads nothing. It exists for the
    // build somebody else's job uploaded, where `upload` has nothing left to
    // carry — without this the group assignment and the beta review had no
    // command to arrive by.
    if (cmd == AscCommand.betaRelease) {
      final build = await store.findBuild(app, buildNumber!);
      if (build == null) {
        fail(
          'Apple holds no ${platform.name} build $buildNumber for $bundleId. '
          '`appstore builds` prints what it does hold.',
        );
      }
      final attributes = build['attributes'] as Map<String, dynamic>?;
      final state = attributes?['processingState'] as String? ?? '(unknown)';
      if (state != 'VALID') {
        // FAILED and INVALID are terminal, and `appstore wait` *raises* on
        // them — so the advice forks, or the slow-case advice sends somebody
        // to a command that can only restate the problem.
        if (state == 'FAILED' || state == 'INVALID') {
          fail(
            'build $buildNumber came back $state from Apple\'s processing and '
            'will never be releasable. The reason is only in the e-mail Apple '
            'sends and in the Activity tab; upload a new build.',
          );
        }
        fail(
          'build $buildNumber is $state, and a build cannot reach a group '
          'until Apple finishes processing it — `appstore wait $buildNumber` '
          'blocks until it does.',
        );
      }
      if (attributes?['expired'] == true) {
        fail(
          'build $buildNumber has expired — TestFlight builds last 90 days, '
          'so upload a new one.',
        );
      }

      stdout.writeln('==> giving build $buildNumber to "$betaGroup"');
      final internal = await releaseToBetaGroup(
        store,
        app,
        build,
        betaGroup!,
        locale: locale,
        description: betaDescription,
        metadataPath: listingTree,
      );
      if (internal) {
        stdout.writeln('==> done — an internal group needs no beta review');
      } else if (!dryRun) {
        stdout.writeln('==> done');
      }
      if (dryRun) {
        stdout.writeln('==> dry run — nothing was written');
      }
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
          if (needsStrippingForApple(notes)) {
            testFlightNotes = stripForApple(notes);
            stdout.writeln(
              '    TestFlight rejects emoji, so they are stripped from the '
              'notes\n'
              '    (Play publishes them verbatim)',
            );
          }
          await store.setWhatToTest(build, locale, testFlightNotes);
        }
        if (betaGroup != null) {
          stdout.writeln('==> beta group');
          await releaseToBetaGroup(
            store,
            app,
            build,
            betaGroup,
            locale: locale,
            description: betaDescription,
            metadataPath: listingTree,
          );
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
    if (publish == ListingPublish.none && metadata != null) {
      stdout.writeln(
        '==> listing: untouched — an upload does not publish it.\n'
        '    Publish deliberately with --metadata and no artifact.',
      );
    } else if (publish == ListingPublish.shared) {
      // Non-null by construction: [listingPublish] returns [none] when there
      // is no metadata, and this is the only thing that reads [shared].
      await _publishAscListing(
        store,
        app,
        metadata!,
        locale,
        versionName,
        fail,
      );
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
      if (betaGroup != null) {
        final number =
            (chosen['attributes'] as Map<String, dynamic>?)?['version'];
        stdout.writeln('==> giving build $number to "$betaGroup"');
        final internal = await releaseToBetaGroup(
          store,
          app,
          chosen,
          betaGroup,
          locale: locale,
          description: betaDescription,
          metadataPath: listingTree,
        );
        if (internal) {
          // The sentence belongs to the internal case alone: an external
          // group's build *was* submitted — for beta review — and printing
          // "not submitted" over that would describe a non-release as done.
          stdout.writeln(
            '==> done — not submitted for review, and the listing is untouched',
          );
        } else if (!dryRun) {
          stdout.writeln('==> done');
        }
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
            // The App Store refuses emoji in `whatsNew` too — measured, after
            // this file spent a release asserting the opposite. Announced
            // more loudly than the TestFlight strip above, and with the
            // characters named: this is copy a shopper reads, and quietly
            // publishing something other than what the changelog says is the
            // failure mode worth spending three lines to avoid.
            var releaseNotes = notes;
            if (needsStrippingForApple(notes)) {
              releaseNotes = stripForApple(notes);
              stdout.writeln(
                '    the App Store rejects emoji in "What\'s New", so these '
                'are stripped:\n'
                '      ${_removedCharacters(notes, releaseNotes)}\n'
                '    what ships here differs from CHANGELOG.md; Play '
                'publishes it verbatim',
              );
            }
            await store.writeVersionLocalization(version, locale, {
              'whatsNew': releaseNotes,
            });
          }
        }
        if (flag('phased')) {
          stdout.writeln('==> phased release');
          await store.enablePhasedRelease(version);
        }
        // **The listing publishes here, and only here** — which [publish]
        // now makes true rather than merely stated. This is the moment it
        // becomes what a shopper reads, and the version record it hangs off
        // exists by now, which is what makes it possible at all. Before the
        // submission, so a review sees the copy that was meant to accompany
        // it rather than the previous release's.
        if (publish == ListingPublish.afterVersion) {
          await _publishAscListing(
            store,
            app,
            metadata!,
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
    _reportVersionLeftBehind(store);
    exitCode = 1;
  } on ProcessingTimeout catch (e) {
    // Caught rather than left to the runtime: an uncaught exception exits 255
    // with a stack trace, and a stack trace above the one sentence that says
    // "read the e-mail" is how that sentence gets skimmed past.
    stderr.writeln('asc_upload: $e');
    _reportVersionLeftBehind(store);
    exitCode = 1;
  } on MetadataException catch (e) {
    stderr.writeln('asc_upload: ${e.message}');
    _reportVersionLeftBehind(store);
    exitCode = 1;
  } finally {
    client.close();
  }
}

/// The distinct characters stripping removed, named so the notice says what
/// it changed rather than that it changed something.
///
/// Each is printed with its code point, because the one Apple complained
/// about that is easiest to miss is invisible: a bare U+FE0F renders as
/// nothing at all, and "so these are stripped:" followed by what looks like
/// an empty line is worse than saying nothing.
String _removedCharacters(String original, String stripped) {
  final kept = stripped.runes.toSet();
  final removed = <int>[];
  for (final rune in original.runes) {
    if (!kept.contains(rune) && !removed.contains(rune)) {
      removed.add(rune);
    }
  }
  return removed
      .map(
        (rune) =>
            '${String.fromCharCode(rune)} '
            '(U+${rune.toRadixString(16).toUpperCase().padLeft(4, '0')})',
      )
      .join(', ');
}

/// Names the version record a failing run left behind, if it left one.
///
/// **A command that exits non-zero reads as "nothing happened", and here that
/// is false.** Creating the version is one of the first things a promotion
/// does, so a failure anywhere after it — the listing, the submission — exits
/// 1 having already changed what App Store Connect holds. The creation is
/// printed when it happens, but that line is above an error and gets skimmed
/// past, which invites the one response that is wrong: run it again. The
/// rerun then behaves differently from the first, because `ensureVersion`
/// adopts the record rather than making a second one.
///
/// Written to stderr beside the error rather than to stdout, so it survives
/// the same redirection the error does.
void _reportVersionLeftBehind(AppStore store) {
  final change = store.versionChange;
  if (change == null) {
    return;
  }
  final what = switch (change.change) {
    VersionChange.created =>
      'created App Store version ${change.versionString}',
    VersionChange.renamed =>
      'renamed an existing editable version to ${change.versionString}',
  };
  stderr.writeln(
    '  This run $what before it failed, and that record is still there.\n'
    '  Running the command again will adopt it rather than make a second '
    'one.\n'
    '  Delete it in App Store Connect if the failure means it should not '
    'exist.',
  );
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
  required String? betaGroup,
  required String? changelogPath,
  required String locale,
  required bool phased,
}) {
  final rows = <String, String?>{
    'app': '$bundleId ($platform)',
    // beta-release names no version: it releases a build, and the inferred
    // pubspec version would only claim a fact the command never uses.
    'version': cmd == AscCommand.betaRelease ? null : versionName,
    'build': switch (cmd) {
      AscCommand.promote => buildNumber ?? 'newest processed build Apple holds',
      _ => buildNumber,
    },
    'artifact': ipaPath,
    'listing': metadataPath,
    'beta group': betaGroup,
    'notes from': changelogPath,
    'locale': locale,
    'phased': phased ? 'yes — over Apple\'s seven-day schedule' : null,
  };

  final heading = switch (cmd) {
    AscCommand.promote =>
      'About to submit for App Store review. Once Apple approves it, this is '
          'public.',
    AscCommand.betaRelease =>
      'About to release a build TestFlight already holds to a beta group. '
          'An external group goes on to Apple for beta review.',
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
