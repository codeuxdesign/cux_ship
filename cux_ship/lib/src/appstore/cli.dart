// SPDX-License-Identifier: Apache-2.0

// Publishes a signed .ipa, the App Store listing, or both, to App Store Connect.
//
//   cux_ship appstore upload --ipa dist/ios/x.ipa --bundle-id design.codeux.holdthewheel \
//     --build-number 12 --version-name 1.0.0 [--dry-run]
//
// A library rather than an executable: the `cux_ship` package wires [AscCommand]
// to subcommands, so there is one binary rather than one per store. What used to
// be modes selected by flag — `--promote`, `--list-builds` — are subcommands
// now, which is why [runAsc] takes the mode as an argument instead of reading it
// back out of [ArgResults].
//
// Invoked by a project's upload script, which has already checked the manifest,
// the artifact digest and the provenance rules. This program does the API work
// and nothing else — everything it needs arrives as an argument or, for the API
// key, as an environment variable. It knows nothing about SOPS or manifests.
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
// rebuild of the same commit. It takes no --ipa, which is the whole point, and
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
import 'package:cux_ship_verify/metadata.dart';
import 'package:cux_ship_verify/release_notes.dart';

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
    AscCommand.signing,
  }.contains(this);
}

/// The locale the listing is written in.
///
/// Apple spells it `en-US`, matching a Play listing's default language rather
/// than diverging for no reason.
const _defaultLocale = 'en-US';

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
      allowed: ['ios', 'macos'],
      help: 'Which App Store platform to act on.',
    );

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
        ..addOption('ipa', help: 'Path to the signed .ipa (or .pkg for macos).')
        ..addOption(
          'build-number',
          help: 'CFBundleVersion; verified against what Apple reports.',
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
    this.changelog,
    this.metadata,
  });

  /// Empty, for a caller that wants nothing inferred.
  static const none = AscDefaults();

  final String? bundleId;
  final String? versionName;
  final String? changelog;
  final String? metadata;
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
      'no bundle identifier — none could be read from the Xcode project, so '
      'pass --bundle-id',
    );
  }

  final locale = opt('locale') ?? _defaultLocale;
  final dryRun = flag('dry-run');

  // Inference applies only where it makes sense. An upload publishes the
  // listing when there is one to publish; a promote never does, so the
  // metadata default is not offered to it.
  final ipaPath = opt('ipa');
  final metadataPath = cmd == AscCommand.upload
      ? (opt('metadata') ?? defaults.metadata)
      : null;
  final promote = cmd == AscCommand.promote;
  final reads = cmd.isRead;

  if (cmd == AscCommand.upload && ipaPath == null && metadataPath == null) {
    fail('nothing to do — pass --ipa, --metadata, or both');
  }

  final versionName = opt('version-name') ?? defaults.versionName;
  final buildNumber = opt('build-number');
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
  if (promote && versionName == null) {
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
    stdout.writeln(
      '==> ${metadata.locales.length} locale(s), '
      '${metadata.categories.length} categor(y|ies)'
      '${metadata.ageRating == null ? '' : ', age rating'}'
      '${metadata.reviewNotes == null ? '' : ', review notes'} validated',
    );
  }

  /// Release notes for [forVersion], resolved late because promotion does not
  /// know its version until Apple has said what is on TestFlight.
  String? notesFor(String forVersion) {
    if (changelogPath == null) {
      return literalNotes;
    }
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

    if (metadata != null) {
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
        final version = await store.ensureVersion(
          app,
          versionName,
          create: true,
        );
        if (version == null) {
          stdout.writeln(
            '    (dry run created no version, so the fields below are skipped)',
          );
        } else {
          final copyright = metadata.copyright;
          if (copyright != null) {
            stdout.writeln('==> copyright');
            await store.writeVersionAttributes(version, {
              'copyright': copyright,
            });
          }

          final reviewNotes = metadata.reviewNotes;
          if (reviewNotes != null) {
            stdout.writeln('==> review notes');
            await store.writeReviewDetails(version, reviewNotes);
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

    // -------------------------------------------------------------- promote

    if (promote) {
      final version = await store.ensureVersion(
        app,
        versionName!,
        create: true,
      );

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
