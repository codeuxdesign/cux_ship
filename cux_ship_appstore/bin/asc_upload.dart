// SPDX-License-Identifier: Apache-2.0

// Publishes a signed .ipa, the App Store listing, or both, to App Store Connect.
//
//   dart run cux_ship_appstore:asc_upload --ipa dist/ios/x.ipa --bundle-id design.codeux.holdthewheel \
//     --build-number 12 --version-name 1.0.0 [--dry-run]
//
// Invoked by tool/upload.sh, which has already checked the manifest, the
// artifact digest and the provenance rules. This program does the API work and
// nothing else — everything it needs arrives as an argument or, for the API
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
// --metadata publishes the store listing from a directory tree, described in
// store/appstore/README.md. Every argument is independent, so a listing-only
// push needs no artifact:
//
//   dart run cux_ship_appstore:asc_upload --bundle-id design.codeux.holdthewheel \
//     --metadata ../../store/appstore --dry-run
//
// --promote is how the App Store is reached, and builds nothing: it points an
// App Store version at a build TestFlight already holds and submits it for
// review, so what ships is the identical binary testers ran rather than a
// rebuild of the same commit. tool/promote.sh drives it.
//
// --list-builds and --list-versions are the read side, and the only way to
// confirm a publish independently of the run that claims to have done it.
//
// What is *not* here is everything Apple has no API for: creating the app
// record, the App Privacy questionnaire, the agreements, and pricing. None of
// them are per-release state, so a normal release touches none of them. See
// docs/RELEASING-APPLE.md §4.
import 'dart:io';

import 'package:args/args.dart';
import 'package:cux_ship_appstore/app_store.dart';
import 'package:cux_ship_appstore/asc_client.dart';
import 'package:cux_ship_appstore/metadata.dart';
import 'package:cux_ship_appstore/testflight_notes.dart';
import 'package:cux_ship_notes/release_notes.dart';

Never _fail(String message) {
  stderr.writeln('asc_upload: $message');
  exit(1);
}

/// The locale the listing is written in.
///
/// Apple spells it `en-US`, matching `store/play/details/default_language.txt`
/// rather than diverging for no reason.
const _defaultLocale = 'en-US';

Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('bundle-id', help: 'e.g. design.codeux.holdthewheel.')
    ..addOption(
      'platform',
      defaultsTo: 'ios',
      allowed: ['ios', 'macos'],
      help: 'Which App Store platform to act on.',
    )
    ..addOption('ipa', help: 'Path to the signed .ipa (or .pkg for macos).')
    ..addOption(
      'build-number',
      help: 'CFBundleVersion; verified against what Apple reports.',
    )
    ..addOption('version-name', help: 'CFBundleShortVersionString.')
    ..addOption('locale', defaultsTo: _defaultLocale)
    ..addOption(
      'beta-group',
      help:
          'TestFlight group to give the build to. An internal group needs no '
          'review, which is the closest thing to Play\'s internal track.',
    )
    ..addOption(
      'metadata',
      help: 'Directory of store listing text and screenshots to publish.',
    )
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
    ..addFlag(
      'promote',
      negatable: false,
      help:
          'Attach the newest processed build to an App Store version and '
          'submit it for review. Builds and uploads nothing.',
    )
    ..addFlag(
      'phased',
      negatable: false,
      help:
          "Release over Apple's seven-day phased schedule once approved. Not a "
          'fraction — Apple runs the schedule itself.',
    )
    ..addFlag(
      'skip-waiting',
      negatable: false,
      help:
          'Do not wait for Apple to finish processing the build. Leaves the '
          'release notes unset, so it is for debugging rather than releases.',
    )
    ..addFlag('dry-run', negatable: false, help: 'Every read, no writes.')
    ..addFlag('list-builds', negatable: false, help: 'Print builds and exit.')
    ..addFlag(
      'list-versions',
      negatable: false,
      help: 'Print App Store versions and exit.',
    )
    ..addFlag(
      'list-screenshot-types',
      negatable: false,
      help:
          'Print the ScreenshotDisplayType values this app already carries, '
          "which is how to check a name rather than guess at it — Apple's "
          'published enum lags the console.',
    )
    ..addFlag(
      'print-build-number',
      negatable: false,
      help:
          'Print the newest processed build number and nothing else, for '
          'scripts that have to name what they are about to act on.',
    )
    ..addFlag('help', abbr: 'h', negatable: false);

  final args = parser.parse(argv);
  if (args.flag('help')) {
    stdout.writeln(parser.usage);
    return;
  }

  final bundleId = args.option('bundle-id');
  if (bundleId == null) {
    _fail('--bundle-id is required\n${parser.usage}');
  }

  final platform = AscPlatform.byName(args.option('platform')!);
  final locale = args.option('locale')!;
  final dryRun = args.flag('dry-run');

  final ipaPath = args.option('ipa');
  final metadataPath = args.option('metadata');
  final promote = args.flag('promote');
  final reads =
      args.flag('list-builds') ||
      args.flag('list-versions') ||
      args.flag('list-screenshot-types') ||
      args.flag('print-build-number');

  if (ipaPath == null && metadataPath == null && !promote && !reads) {
    _fail(
      'nothing to do — pass --ipa, --metadata, --promote or one of the '
      '--list-* flags\n${parser.usage}',
    );
  }

  // Promotion publishes bits Apple already holds, which is the whole reason a
  // release can be trusted to be what testers ran. Handing it an artifact
  // would mean one of the two is not what ships.
  if (promote && ipaPath != null) {
    _fail('--promote submits what Apple already has; drop --ipa');
  }

  final versionName = args.option('version-name');
  final buildNumber = args.option('build-number');
  File? artifact;
  if (ipaPath != null) {
    if (buildNumber == null || versionName == null) {
      _fail('--ipa also needs --build-number and --version-name');
    }
    if (int.tryParse(buildNumber) == null) {
      _fail('--build-number must be an integer, got "$buildNumber"');
    }
    artifact = File(ipaPath);
    if (!artifact.existsSync()) {
      _fail('no such file: $ipaPath');
    }
  }
  if (promote && versionName == null) {
    _fail('--promote needs --version-name, to know which version to submit');
  }

  final notesPath = args.option('release-notes');
  final changelogPath = args.option('changelog');
  if (notesPath != null && changelogPath != null) {
    _fail('--release-notes and --changelog both supply the notes; pick one');
  }

  String? literalNotes;
  if (notesPath != null) {
    final file = File(notesPath);
    if (!file.existsSync()) {
      _fail('no such release notes file: $notesPath');
    }
    literalNotes = file.readAsStringSync().trim();
    if (literalNotes.length > appStoreReleaseNotesLimit) {
      _fail(
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
      _fail(e.message);
    }
    stdout.writeln(
      '==> ${metadata.locales.length} locale(s), '
      '${metadata.categories.length} categor(y|ies)'
      '${metadata.ageRating == null ? '' : ', age rating'} validated',
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
        _fail(
          '$changelogPath has no section for $forVersion.\n'
          '  Add one. Empty is a fine answer — it publishes the newest older\n'
          '  version that did change something here, or\n'
          '  "$noUserVisibleChanges" if there is none. Absent is not the same\n'
          '  answer as empty.',
        );
      case NotesText(:final text, :final fromVersion):
        if (text.length > appStoreReleaseNotesLimit) {
          _fail(
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

  // Built only once every local check has passed.
  final AscCredentials credentials;
  try {
    final loaded = AscCredentials.fromEnvironment();
    if (loaded == null) {
      _fail(
        'no App Store Connect credentials.\n'
        '  APPLE_API_KEY_ID, APPLE_API_ISSUER_ID and APPLE_API_PRIVATE_KEY_PATH\n'
        '  are set by tool/with-secrets.sh. Run this through it, or export them\n'
        '  yourself. See docs/RELEASING-APPLE.md §1.',
      );
    }
    credentials = loaded;
  } on StateError catch (e) {
    _fail(e.message);
  }

  final client = AscClient(credentials);
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
    if (!args.flag('print-build-number')) {
      stdout.writeln('==> ${app.name} ($bundleId) is app ${app.id}');
    }

    if (args.flag('print-build-number')) {
      await store.printBuildNumber(app);
      return;
    }
    if (args.flag('list-builds')) {
      await store.listBuilds(app);
    }
    if (args.flag('list-versions')) {
      await store.listVersions(app);
    }
    if (args.flag('list-screenshot-types')) {
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
      } else if (args.flag('skip-waiting')) {
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
        final group = args.option('beta-group');
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
      final needsVersion = metadata.locales.any(
        (l) => l.version.isNotEmpty || l.screenshots.isNotEmpty,
      );
      if (needsVersion) {
        if (versionName == null) {
          _fail(
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
        _fail('no processed, unexpired build to promote');
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
              orElse: () => _fail(
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
        if (args.flag('phased')) {
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
