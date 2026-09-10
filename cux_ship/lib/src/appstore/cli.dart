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
// **An `upload` carrying an artifact is three phases, and each one can be run
// on its own.** The transfer is exclusive and bounded — Apple accepts one
// CFBundleVersion once — the processing wait is shareable and takes five to
// fifteen minutes, and the writes that follow are exclusive again and take
// seconds. Welded together, the whole command inherits the worst of each: a
// caller shipping iOS and macOS from one commit serialises everything for the
// sake of the transfers and pays both waits end to end. So `upload
// --skip-waiting` does the transfer, `appstore wait` does the poll from
// anywhere with the API key, and `appstore what-to-test` and `appstore
// beta-release` do the writes. Running them apart is a choice; nothing is
// missing from the single command.
//
// `appstore builds` and `appstore versions` are the read side, and the only way
// to confirm a publish independently of the run that claims to have done it.
//
// What is *not* here is everything Apple has no API for: creating the app
// record, the App Privacy questionnaire, the agreements, and pricing. None of
// them are per-release state, so a normal release touches none of them; they
// are done once, by hand, in App Store Connect.
import 'dart:io';

import 'package:args/args.dart';
import 'package:cux_ship_verify/cux_ship_verify.dart';
import 'package:cux_ship_verify/metadata.dart';
import 'package:cux_ship_verify/release_notes.dart';

import '../asc_platforms.dart';
import '../json_output.dart';
import '../listing_requirements.dart';
import '../notes_source.dart';
import '../reachable.dart';
import '../release.dart' show ReleaseException;
import 'app_store.dart';
import 'apple_notes.dart';
import 'asc_client.dart';
import 'beta_release.dart';
import 'reads.dart';
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
  whatToTest('what-to-test'),
  builds('builds'),
  betaGroups('beta-groups'),
  versions('versions'),
  screenshotTypes('screenshot-types'),
  buildNumber('build-number'),
  awaitBuild('wait'),
  awaitPreviews('wait-previews'),
  previews('previews'),
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
    // **A read that can also assert a poster frame**, which is the one place
    // this set is doing double duty. `wait-previews` polls, and with a
    // `--metadata` tree it finishes the job `upload --skip-waiting` deferred
    // by moving the timecode Apple ignored at reservation. Listed here because
    // what `isRead` actually gates is the confirmation prompt and the offline
    // argument checks, and neither is wanted for a command that mostly waits;
    // the write it can make is one the tree already asked for.
    AscCommand.awaitPreviews,
    AscCommand.previews,
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

  if (cmd == AscCommand.awaitPreviews) {
    parser
      ..addOption(
        'version-name',
        help:
            'The App Store version whose previews to wait for. Required, and '
            'deliberately not defaulted to the newest — the same reason '
            '`wait` gives about build numbers: the point of waiting from '
            'another machine is to wait for a *specific* version, and '
            '"newest" would succeed on somebody else\'s.',
      )
      ..addOption(
        'metadata',
        help:
            'The tree the previews came from. Optional: without it this only '
            'waits, and with it the poster frames are asserted once Apple has '
            'finished — which is the phase `upload --skip-waiting` defers, '
            'and which needs the tree because Apple discards the timecode '
            'sent at reservation.',
      )
      ..addOption(
        'timeout',
        defaultsTo: '30m',
        help:
            'How long to wait before reporting what is still pending, e.g. '
            '2h or 90s. Reaching it is not a failure — Apple documents '
            'preview ingestion as taking up to 24 hours — so the exit code '
            'for it is distinct from both success and error.',
      )
      ..addOption('poll', defaultsTo: '30s', help: 'How often to ask.')
      ..addFlag(
        'json',
        negatable: false,
        help:
            'Print the result as a JSON document on stdout. Progress goes to '
            'stderr either way, so a caller gets a live report and a clean '
            'document without choosing between them — which is what a wait '
            'needs and a read does not, because a wait has progress and then '
            'an answer. See docs/design/json-output.md.',
      );
    return parser;
  }

  if (cmd.isRead) {
    // Only the two listings. `build-number` already prints one value a caller
    // can use unquoted, `wait` reports progress nobody decodes, and
    // `beta-groups` / `screenshot-types` have asked no one for a document —
    // and a flag on a command with no consumer is a promise made to nobody.
    if (cmd == AscCommand.previews) {
      parser
        ..addOption(
          'version-name',
          help:
              'The App Store version whose previews to print. Required: '
              'previews are version-scoped, so "the previews" is not a '
              'question with one answer.',
        )
        ..addFlag(
          'json',
          negatable: false,
          help:
              'Print the listing as a JSON document instead of prose. stdout '
              'carries the document and nothing else; every other line goes '
              'to stderr. See docs/design/json-output.md.',
        );
      return parser;
    }

    if (cmd == AscCommand.builds || cmd == AscCommand.versions) {
      parser.addFlag(
        'json',
        negatable: false,
        help:
            'Print the listing as a JSON document instead of prose. stdout '
            'carries the document and nothing else; every other line goes to '
            'stderr. See docs/design/json-output.md.',
      );
    }
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
              'Upload the artifact and stop, leaving the processing wait and '
              'the TestFlight notes to `appstore wait` and `appstore '
              'what-to-test`. For a caller waiting on several platforms at '
              'once; the notes are not set by this run and it says so.',
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
        )
        ..addOption(
          'release-type',
          // Deliberately no `allowed:`. The args package would reject
          // SCHEDULED with one generic line, and SCHEDULED is the value that
          // most needs a sentence explaining what is missing.
          help:
              'What starts the public release once Apple approves: MANUAL, or '
              'AFTER_APPROVAL to go out on approval. A different axis from '
              '--phased, which is how fast it rolls out once started. Unset '
              'leaves whatever App Store Connect holds — a new version is '
              'created MANUAL, an existing one is not touched.',
        );
    case AscCommand.whatToTest:
      // Only the build. The notes themselves come from the shared options
      // above, because "which text" is the same question here as on an
      // upload and answering it twice is how the two answers drift.
      parser.addOption(
        'build-number',
        help:
            'The build TestFlight already holds. Required, and deliberately '
            'not defaulted to the newest: notes belong to a *specific* '
            'build, and "newest" would write them onto somebody else\'s '
            'upload.',
      );
    case AscCommand.betaRelease:
    case AscCommand.builds:
    case AscCommand.betaGroups:
    case AscCommand.versions:
    case AscCommand.screenshotTypes:
    case AscCommand.buildNumber:
    case AscCommand.awaitBuild:
    case AscCommand.awaitPreviews:
    case AscCommand.previews:
    case AscCommand.signing:
      throw StateError('unreachable: handled by cmd.isRead or above');
  }

  return parser;
}

/// What to say when Apple reports no build [buildNumber] on [platform].
///
/// **An empty answer has two causes and the API cannot tell them apart**, so
/// the message names both instead of picking the likelier one. A build that has
/// just been transferred is not in `/v1/builds` immediately — measured at about
/// two minutes for a 28 MB iOS build — and during that window the build exists,
/// the number is right, and Apple says nothing.
///
/// **This used to send the reader to `appstore builds`, which is empty for the
/// same reason.** So the advice was wrong in exactly the window the split
/// creates: `upload --skip-waiting` prints `appstore wait N` as the next step,
/// an operator who instead ran `what-to-test` straight away got told to run a
/// listing that would also show nothing, and the honest conclusion from that is
/// "my build number is wrong". Found in a real TestFlight run, not reasoned
/// about.
///
/// One function because [AscCommand.betaRelease] and [AscCommand.whatToTest]
/// both need it and are reached by the same route — a build somebody else's
/// job uploaded. Two copies would be two chances for the next fix to land on
/// one of them.
String noSuchBuild({
  required AscPlatform platform,
  required String buildNumber,
  required String bundleId,
}) {
  final on = platform == AscPlatform.ios ? '' : ' --platform ${platform.name}';
  return 'Apple holds no ${platform.name} build $buildNumber for $bundleId.\n'
      '  A build that was just uploaded is not listed straight away, so if the '
      'upload\n'
      '  has only just finished this is too early rather than wrong:\n'
      '    cux_ship appstore wait$on $buildNumber\n'
      '  blocks until it appears. If it never does, `appstore builds` prints '
      'what\n'
      '  Apple holds — and check the bundle id first, because a wrong one '
      'resolves\n'
      '  to a different app and reports nothing uploaded.';
}

/// Why a build in [state] cannot be used yet, or null when it can be.
///
/// [waitingFor] names what this particular command was going to do, because
/// the refusal reads better as "its notes cannot be written" than as a generic
/// one — and the two callers are doing different things to the same build.
///
/// **Two copies of this forked advice existed, and both suggested an
/// `appstore wait` carrying no `--platform`** — which on a macOS run names the
/// iOS build of the same number: the exact defect the platform filter on the
/// build query exists to stop, reintroduced in the message that tells you how
/// to recover. One function now.
///
/// **The `PROCESSING` branch may be unreachable in practice, and that is why
/// it is tested rather than trusted.** Two live runs — 28 MB iOS and 67 MB
/// macOS, sampled at 15 and 4 seconds — never once saw `/v1/builds` list a
/// build in any state but `VALID`: it goes from absent to processed with no
/// observable window between. So the state an operator actually meets is
/// *no build at all* ([noSuchBuild]), and this is the defensive branch.
///
/// Kept, deliberately. A state nobody has observed is not a state Apple
/// promises never to report, the check is one string comparison, and the cost
/// of being wrong is asymmetric: an unnecessary refusal costs one more
/// command, while dropping the check costs a write that silently does not
/// land on a build that could not take it.
String? unusableBuildState({
  required String state,
  required String buildNumber,
  required AscPlatform platform,
  required String waitingFor,
}) {
  if (state == 'VALID') {
    return null;
  }
  // FAILED and INVALID are terminal, and `appstore wait` *raises* on them — so
  // the advice forks, or the slow-case advice sends somebody to a command that
  // can only restate the problem.
  if (state == 'FAILED' || state == 'INVALID') {
    return 'build $buildNumber came back $state from Apple\'s processing and '
        'will never be releasable. The reason is only in the e-mail Apple '
        'sends and in the Activity tab; upload a new build.';
  }
  final on = platform == AscPlatform.ios ? '' : ' --platform ${platform.name}';
  return 'build $buildNumber is $state, and $waitingFor until Apple finishes '
      'processing it — `cux_ship appstore wait$on $buildNumber` blocks until '
      'it does.';
}

/// The commands that finish an `upload --skip-waiting`, one per line.
///
/// **Split out because its two callers are unalike and both are easy to get
/// wrong.** One is an offline refusal — `--skip-waiting` with `--beta-group`.
/// The other prints after the artifact has gone up, past the credential and
/// past Apple, and was unreachable from any test when this was written; the
/// `ascClient` seam added later reaches it, which is why the warning is now
/// covered rather than merely argued for.
///
/// What it has to get right is the arguments it carries: iOS and macOS are
/// given the *same* build number from one commit by design, so a macOS run
/// whose remedy omits `--platform macos` names the other platform's build, and
/// the reader has no way to tell.
///
/// The wait comes first because everything after it needs a processed build.
/// [notes] and [betaGroup] are the two phases that sit behind the wait, and
/// each contributes a line only when this run had asked for it.
List<String> finishAfterSkippedWait({
  required AscPlatform platform,
  required String? buildNumber,
  bool notes = false,
  String? notesArgument,
  String? betaGroup,
}) {
  final on = platform == AscPlatform.ios ? '' : ' --platform ${platform.name}';
  // A refusal can fire before a build number is known — `--artifact` is what
  // requires one, and `--skip-waiting --changelog` is refused whether or not
  // one was passed. A placeholder is honest there; inventing a number is not.
  final build = buildNumber ?? '<build-number>';
  return [
    'cux_ship appstore wait$on $build',
    if (notes)
      'cux_ship appstore what-to-test$on --build-number $build'
          '${notesArgument == null ? '' : ' $notesArgument'}',
    if (betaGroup != null)
      'cux_ship appstore beta-release$on --build-number $build '
          '--beta-group "$betaGroup"',
  ];
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
  // the version record.
  //
  // Ordered before [promote] so the combination has a defined answer rather
  // than a reachability argument. Today it cannot arise — promote's parser
  // declares neither `--artifact` nor `--manifest`, and `defaults.artifact`
  // only comes from the latter — but that is a fact about two other functions,
  // and a decision table that depends on one staying true is the shape this
  // enum exists to stop.
  if (hasArtifact) {
    return ListingPublish.none;
  }
  return promote ? ListingPublish.afterVersion : ListingPublish.shared;
}

/// Writes the App Store "What's New" for a version, or says why it did not.
///
/// **One function because two commands publish it, and for one release only
/// one of them did.** `promote --changelog` wrote it; `upload --metadata
/// --changelog` accepted the flag and wrote nothing, so a listing published
/// without a promotion showed an empty "What's New in This Version" — a flag
/// taken and silently dropped, on copy a shopper reads. Reported by the
/// consumer whose whole flow is *publish, look at it, then submit*, which is
/// precisely the flow that never reaches the promote path.
///
/// Two rules travel with it and are the reason this is not two call sites:
///
///   - **A first version has no "What's New"** to be new against, and Apple
///     refuses the write with a message that does not explain itself.
///   - **The App Store rejects emoji in `whatsNew`** — measured, after this
///     file spent a release asserting the opposite — so they are stripped, and
///     the run names the characters because what ships then differs from
///     CHANGELOG.md.
///
/// Both were written inside the promote block. A second copy on the upload
/// path would have been two chances for the next fix to land on one of them.
///
/// **Apple does not gate this on a build.** The one thing that could have made
/// publishing notes from a listing-only run wrong — `whatsNew` being editable
/// only once a build is attached — was measured against a live version in
/// `PREPARE_FOR_SUBMISSION` with none: the write lands and Apple says nothing.
/// So the version being editable is the whole condition, which is what the
/// refusal branch below is left guarding.
Future<void> publishReleaseNotes(
  AppStore store,
  App app,
  Map<String, dynamic> version,
  String locale,
  String? notes,
  String? versionName, {

  /// The locales the metadata tree carries, when there is a tree. Empty means
  /// "do not check" — `promote --changelog` with no `--metadata` publishes
  /// notes against a listing this run never read.
  Set<String> declaredLocales = const {},
}) async {
  if (notes == null) {
    return;
  }
  if (await store.isFirstVersion(app, version)) {
    stdout.writeln(
      '==> ${versionName ?? 'this'} is this app\'s first App Store version, '
      'so it has no\n'
      '    "What\'s New" — the release notes are skipped and the '
      'description stands',
    );
    return;
  }
  // **Only for a locale the listing actually has.** The notes go to the CLI's
  // `--locale`, which defaults to en-US, while the tree declares its own — so
  // a `listings/de-DE/`-only tree published without `--locale de-DE` would
  // POST a *new* en-US version localization carrying release notes and no
  // description. `writeVersionLocalization` creates the record when none
  // exists, and that record is one nothing else in the tree owns.
  //
  // Skipped loudly rather than quietly: this is a listing that will not carry
  // its notes, which is the thing this whole function exists to stop happening
  // in silence.
  if (declaredLocales.isNotEmpty && !declaredLocales.contains(locale)) {
    stdout.writeln(
      '==> release notes skipped: this tree declares '
      '${declaredLocales.join(", ")} and the notes would go to $locale.\n'
      '    Pass --locale ${declaredLocales.first} to publish them there.',
    );
    return;
  }

  stdout.writeln('==> release notes');
  var releaseNotes = notes;
  if (needsStrippingForApple(notes)) {
    releaseNotes = stripForApple(notes);
    stdout.writeln(
      '    the App Store rejects emoji in "What\'s New", so these are '
      'stripped:\n'
      '      ${_removedCharacters(notes, releaseNotes)}\n'
      '    what ships here differs from CHANGELOG.md; Play publishes it '
      'verbatim',
    );
  }
  // Not compared, unlike the listing text: these notes are per-release and
  // come from CHANGELOG.md, so "unchanged since last time" is not a state a
  // release is expected to be in. The read is still passed in, so this write
  // decides POST or PATCH from a reading rather than making its own.
  // **Not wrapped, and the explanation lives in
  // `AscApiException.guidanceFor`.** Apple's answer to a version that will not
  // take notes is `Attribute 'whatsNew' cannot be edited at this time`, which
  // names the attribute and not the condition — so it needs an explanation,
  // and this used to append one to `e.details`. That list is documented as one
  // entry per Apple `errors[]` element and is publicly exported through
  // `read.dart`, so appending told a consumer Apple had said three sentences
  // it had not. The guidance seam exists for precisely this kind of error and
  // keeps Apple's words Apple's.
  //
  // **Measured, and worth keeping beside the write:** whether a version with
  // *no build attached* refuses this was the open question that decided
  // whether publishing notes from a listing-only run was sound at all — that
  // state is reachable only from this caller. Against a live version in
  // `PREPARE_FOR_SUBMISSION` with no build, the write lands, exit 0, no
  // refusal. So the remaining cause is a version locked by review, which
  // `ensureVersion` usually refuses first.
  await store.writeVersionLocalization(version, locale, {
    'whatsNew': releaseNotes,
  }, existing: await store.versionLocalizations(version));
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
/// Returns the `appStoreVersions` record it wrote against, or null when the
/// tree needed none — so a caller can write the release notes against the same
/// version rather than resolving it a second time.
Future<Map<String, dynamic>?> _publishAscListing(
  AppStore store,
  App app,
  AppStoreMetadata metadata,
  String locale,
  String? versionName,
  // Passed rather than reached for: the caller's closure names the subcommand
  // in its message, and a listing failure should say whether it came from an
  // upload or a promote.
  Never Function(String) fail, {

  /// Upload the previews and stop, leaving the ingestion wait and the
  /// poster-frame assertion to `appstore wait-previews`.
  bool skipPreviewWait = false,
}) async {
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

  // **Every acquisition that can refuse happens before any write — not
  // before its own write.**
  //
  // That distinction is the whole of this block. The app-level half already
  // acquired its record before writing app-level fields, and satisfied the
  // rule *per resource* while breaking it for the pair: the version was
  // acquired after those writes, so a run against a version Apple will not
  // let anyone edit wrote content rights, categories, the age rating and the
  // localized name, and only then took a 409 naming the version.
  //
  // Per-resource is not a weaker form of the rule; it is a different rule
  // that happens to coincide when there is one resource, which is why fixing
  // the instance would have looked complete and left the next resource added
  // to inherit the shape.
  //
  // Observed rather than reasoned about: a `--listing-only` run against a
  // READY_FOR_SALE version printed the app-level result and *then* refused.
  // It wrote nothing only because that tree happened to match. It needs
  // app-level drift and an unusable version together — the combination
  // nobody arranges and everybody meets after a rejection.
  //
  // Acquiring here costs nothing when it refuses, which is the common
  // failure. When it instead *creates* a version that write comes first, and
  // a later failure leaves a version behind — which the run already names.
  //
  // **No test holds this ordering**, and that is stated rather than hoped:
  // `_publishAscListing` is private and needs credentials and a store to
  // reach, so moving this block back below the writes fails nothing. Verified
  // by mutation rather than assumed, twice — once here and once by a review
  // that repeated it. The suite pins that the refusal is a
  // read which writes nothing — what makes the hoist free — and this comment
  // is the only thing holding where it sits.
  // Created when absent, because a listing push before the first release is
  // exactly when there is nothing there yet.
  final needsVersion = listingNeedsVersion(metadata);
  if (needsVersion && versionName == null) {
    // Unreachable via [runAsc], which asks the same question offline before a
    // credential is loaded — see the check beside [listingPublish]. Kept as
    // the invariant refusing to depend on its caller.
    fail(
      'pushing descriptions or screenshots needs --version-name, because '
      'Apple scopes them to a version rather than to the app',
    );
  }
  final version = needsVersion
      ? await store.ensureVersion(app, versionName!, create: true)
      : null;

  // **The review contact is an acquisition too, and it refuses.**
  // `fromEnvironment` rejects a half-set contact and a malformed phone
  // number, so it belongs with the other refusals rather than beside the
  // write it feeds. It sat in the version half — after content rights,
  // categories, the age rating and the localized name — where its own doc
  // comment's reason for existing ("a partial set fails after the rest of the
  // listing has already been written") described exactly what it then did.
  //
  // Read here even though nothing else in this block is offline, because the
  // invariant above is about *when a refusal happens*, not about what it
  // reads. Whether it earns a place in `runAsc`'s offline phase beside the
  // version-name check is a separate question; this is the part that stops it
  // half-applying a listing.
  final needsReviewDetail = metadata.reviewNotes != null;
  final reviewContact = needsReviewDetail
      ? ReviewContact.fromEnvironment()
      : null;

  final contentRights = changes.contentRights;
  if (contentRights != null) {
    stdout.writeln('==> content rights');
    await store.writeContentRights(app, contentRights);
  }

  if (appInfo != null) {
    if (changes.categories.isNotEmpty) {
      stdout.writeln('==> categories');
      // Read every relationship first, including the four subcategory slots
      // this tool never writes — the check has to cover what the PATCH omits,
      // because omission is the thing in question. Skipped on a dry run,
      // which writes nothing for a read-back to be evidence about.
      final before = store.writer.dryRun
          ? null
          : await store.categoryRelationships(appInfo);
      await store.writeCategories(appInfo, changes.categories);
      if (!store.writer.dryRun) {
        await _checkCategoriesNothingElseMoved(
          store,
          appInfo,
          before: before,
          declared: changes.categories.keys.toSet(),
        );
      }
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

  // The version-scoped half, hanging off the record acquired above rather
  // than one fetched here — see the invariant beside that acquisition.
  if (needsVersion) {
    if (version == null) {
      stdout.writeln(
        '    (dry run created no version, so the fields below are skipped)',
      );
    } else {
      // **Compared before writing, the same as the app-level half above.**
      // These fields used to be rewritten with identical values on every run:
      // harmless per request, and seven more chances to exit non-zero having
      // already written something. Read once here; the writes below consume
      // this rather than reading again, so the comparison and the action
      // cannot disagree.
      final localizations = await store.versionLocalizations(version);
      final existingReviewDetail = needsReviewDetail
          ? await store.reviewDetail(version)
          : null;
      final versionChanges = versionLevelChanges(
        metadata: metadata,
        version: version,
        localizations: localizations,
        reviewDetail: existingReviewDetail,
        // Acquired above, with the other refusals, and only when there are
        // notes to send it with — see there.
        contact: reviewContact,
      );

      if (versionChanges.isEmpty && declaresVersionText(metadata)) {
        stdout.writeln('==> version text: already matches, nothing written');
      }

      final copyright = versionChanges.copyright;
      if (copyright != null) {
        stdout.writeln('==> copyright');
        await store.writeVersionAttributes(version, {'copyright': copyright});
      }

      final reviewDetails = versionChanges.reviewDetails;
      if (reviewDetails != null) {
        stdout.writeln('==> review notes');
        await store.writeReviewDetails(
          version,
          reviewDetails.notes,
          contact: reviewDetails.contact,
          existing: existingReviewDetail,
        );
      }

      for (final localeMetadata in metadata.locales) {
        final changedText = versionChanges.localizations[localeMetadata.locale];
        if (changedText != null) {
          stdout.writeln(
            '==> ${localeMetadata.locale}: ${changedText.keys.join(", ")}',
          );
          await store.writeVersionLocalization(
            version,
            localeMetadata.locale,
            changedText,
            existing: localizations,
          );
        }
        if (localeMetadata.screenshots.isNotEmpty ||
            localeMetadata.previews.isNotEmpty) {
          // Found in the reading already taken above when it is there, and
          // re-read when it is not — because the write a few lines up may
          // have just created it. See [localizationForUpload].
          final localization = await store.localizationForUpload(
            version,
            localeMetadata.locale,
            known: localizations,
          );
          if (localization == null) {
            stdout.writeln(
              '    (no ${localeMetadata.locale} localization yet, so its '
              'screenshots and previews are skipped)',
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
          // **After the screenshots, not before.** A preview is the slowest
          // asset Apple ingests, so putting it last means everything cheap has
          // already landed by the time this run starts waiting — and if the
          // wait times out, the screenshots are not left unwritten behind it.
          for (final entry in localeMetadata.previews.entries) {
            stdout.writeln(
              '==> ${localeMetadata.locale}: ${entry.key} (preview)',
            );
            await store.replacePreviews(
              localization,
              entry.key,
              entry.value,
              skipWaiting: skipPreviewWait,
            );
          }
        }
      }
    }
  }
  return version;
}

/// Runs [cmd] against App Store Connect.
///
/// [ascClient] replaces the client this would otherwise build from the
/// environment, and exists so a test can reach the decisions this function
/// makes rather than only the ones `AppStore` makes. **The one that most
/// needed reaching is the already-uploaded branch**: an upload asks Apple for
/// the build number first and reuses a build Apple already holds rather than
/// letting altool refuse it, which is what makes a re-run after a partial
/// release safe, and until this parameter existed nothing could drive it —
/// the client was built at the point of use, so the branch was reachable only
/// by uploading to Apple.
///
/// A supplied client is also where `uploadPackage`'s credentials come from, so
/// the key altool is handed and the key the REST calls are signed with cannot
/// come apart.
Future<void> runAsc(
  AscCommand cmd,
  ArgResults args, {
  AscDefaults defaults = AscDefaults.none,
  AscConfirm? confirm,
  AscClient? ascClient,
}) async {
  // Set once there is a store, so a [fail] that happens after a write can
  // still name what the run left behind. Null before then, which is exactly
  // when there is nothing to name.
  AppStore? started;

  Never fail(String message) {
    stderr.writeln('cux_ship appstore ${cmd.name}: $message');
    // **[fail] exits rather than throwing, so it reaches no catch clause.**
    // That made the whole left-behind report miss its likeliest trigger: on a
    // promote, `notesFor` runs after the version is created and the build
    // attached, and it fails when CHANGELOG.md has no section for the version
    // — the ordinary mistake — so the run created a version, exited 1, and
    // said nothing about it. The report has to hang off this path too, or the
    // claim it makes is only true for the failures nobody meets.
    final store = started;
    if (store != null) {
      _reportStateLeftBehind(store);
    }
    exit(1);
  }

  String? opt(String name) =>
      args.options.contains(name) ? args.option(name) : null;
  bool flag(String name) => args.options.contains(name) && args.flag(name);

  final platform = AscPlatform.byName(opt('platform')!);
  final jsonOutput = flag('json');
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
  if (cmd == AscCommand.awaitPreviews) {
    final timeoutText = args.option('timeout')!;
    final pollText = args.option('poll')!;
    awaitTimeout =
        _duration(timeoutText) ??
        fail('--timeout is "$timeoutText" — write it as 2h or 90s.');
    awaitPoll =
        _duration(pollText) ?? fail('--poll is "$pollText" — write it as 30s.');
  }

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
  // Validated post-parse rather than by `allowed:`, so SCHEDULED gets the
  // sentence it needs instead of the parser's generic one.
  final releaseType = opt('release-type');
  if (releaseType != null) {
    final refusal = releaseTypeRefusal(releaseType);
    if (refusal != null) {
      fail(refusal);
    }
    // The same shape as the --metadata refusal above: a promotion to a group
    // creates no App Store version, so there is nothing for a release type to
    // apply to, and silently ignoring it would be the quieter failure.
    if (betaGroup != null) {
      fail(
        '--release-type and --beta-group ask for opposite things on promote: '
        'a promotion to a group creates no App Store version to release',
      );
    }
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

  if (cmd == AscCommand.whatToTest) {
    final number = opt('build-number') ?? defaults.buildNumber;
    if (number == null) {
      fail(
        'which build? --build-number is required, and deliberately not '
        'defaulted to the newest Apple holds: notes belong to a *specific* '
        'build, and "newest" would write them onto somebody else\'s upload.',
      );
    }
    if (int.tryParse(number) == null) {
      fail('--build-number must be an integer, got "$number"');
    }
    // The same reason beta-release refuses one: this command's build number
    // is an option, so a stray positional is most likely a build number the
    // run would then silently not use. `wait 2132` is the only positional
    // spelling here, and it is that command's alone.
    if (args.rest.isNotEmpty) {
      fail(
        'unexpected argument "${args.rest.first}" — what-to-test takes '
        '--build-number as an option',
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
  // Which version's notes, not which version to submit — this command creates
  // no App Store version. It is still required, because the changelog section
  // is chosen by version and picking one by inference from an empty pubspec is
  // how a build gets last release's notes.
  if (cmd == AscCommand.whatToTest && versionName == null) {
    fail(
      'no version name — none could be read from pubspec.yaml, so pass '
      "--version-name to say which version's notes to publish",
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
    final finish = finishAfterSkippedWait(
      platform: platform,
      buildNumber: buildNumber,
      betaGroup: betaGroup,
    );
    fail(
      '--skip-waiting and --beta-group ask for incompatible things: a build '
      'cannot reach a group until Apple finishes processing it.\n'
      '  Wait elsewhere and release the group separately:\n'
      '${finish.map((line) => '    $line').join('\n')}',
    );
  }
  // **`--skip-waiting` and the notes are NOT the same shape, and a first
  // version of this got that wrong.** It refused the flag alongside an
  // explicit `--changelog` or `--release-notes`, reasoning by analogy with
  // `--beta-description` above: a flag naming something the run cannot do is
  // a contradiction. Review found the analogy is with the wrong flag.
  //
  // `--beta-group` names an *action* — release to this group — and is a thing
  // the run genuinely cannot do. `--changelog` names a *file*; the variable
  // for its sibling on the next line is called `notesPath`, which is the code
  // saying so. Both are answers to "where does the text live", and the refusal
  // therefore sorted callers by **directory layout** rather than by intent:
  //
  //   - a repository with CHANGELOG.md at its root never types the flag,
  //     because `defaults.changelog` infers it, and was warned;
  //   - one that keeps it at `docs/CHANGELOG.md` must pass `--changelog` on
  //     every invocation, because that is the only way to say where it is, and
  //     was refused — for a wrapper identical in every other respect.
  //
  // `--release-notes` made it worse: it has no default at all, so a caller
  // keeping notes in a file rather than a changelog must always pass it, and
  // could therefore *never* use `--skip-waiting`. A whole class of caller shut
  // out of the decomposition by a flag that says where bytes are.
  //
  // So it warns in every case, below, at the point the wait is skipped — where
  // it can name the build number the run actually used. A refusal here would
  // have to be earned by a flag that can only mean "write the notes now", and
  // neither of these is one.
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

  // Decided here, once. Four reads follow; the two that pick a publish site
  // compare it against distinct constants, which is what makes double
  // publishing impossible rather than merely avoided. See [ListingPublish].
  //
  // This said "read at both sites below" until a review counted them. It was
  // inexact when written, got worse when a fourth read was added, and survived
  // the commit whose whole purpose was fixing the identical wording in
  // listing_publish_test.dart's header — a fair illustration of why the
  // counting keeps needing an outside reader.
  final publish = listingPublish(
    hasMetadata: metadata != null,
    hasArtifact: ipaPath != null,
    promote: promote,
  );

  // **Offline, because it is answerable offline.** A tree carrying
  // descriptions or screenshots needs a version to hang them off, and a run
  // that discovers that *during* the publish has already written the
  // app-level half — content rights, categories, the age rating — and then
  // exits. Asking here keeps the promise this command makes: everything
  // checkable without a network is checked before a credential is loaded.
  if (publish != ListingPublish.none &&
      versionName == null &&
      listingNeedsVersion(metadata!)) {
    fail(
      'pushing descriptions or screenshots needs --version-name, because '
      'Apple scopes them to a version rather than to the app',
    );
  }

  /// Release notes for [forVersion].
  ///
  /// **This used to say it was "resolved late because promotion does not know
  /// its version until Apple has said what is on TestFlight", and that is not
  /// true.** Both callers pass a `--version-name` that was known before any
  /// network call — promote requires one. The late resolution is now just
  /// where it happens to sit, and it has a cost: on a promote this runs after
  /// the version is created and the build attached, so a CHANGELOG.md missing
  /// a section for the version — the ordinary mistake — fails with those two
  /// already done. [fail] now reports what was left behind, which makes that
  /// survivable rather than silent; moving the changelog read into the offline
  /// phase would make it not happen at all, and is the better fix.
  ///
  /// **`what-to-test` has taken that fix and the other two callers have not.**
  /// It calls this from the offline block, before a credential is loaded,
  /// because it is new and could start there without changing anything's
  /// behaviour. So one command finds a missing changelog section with nothing
  /// written and two find it with writes already made. Said here rather than
  /// only there, so somebody reading the old path learns the better shape
  /// exists instead of finding it by grep.
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

  // **Resolved here rather than late, which is what the closure above says it
  // should have been all along.** Its own doc calls moving the changelog read
  // into the offline phase "the better fix" and does not do it, because the
  // paths that came first would change behaviour. This one is new, so it can
  // start where the rest of the offline work is: an absent CHANGELOG.md
  // section is the ordinary mistake, and finding it before a credential is
  // loaded costs nothing and leaves nothing behind.
  // The notes when the changelog has a section for this version, and null
  // when it does not — as opposed to [notesFor], which refuses.
  //
  // Its own closure rather than a flag on `notesFor`, because the two answer
  // different questions and only one of them is "what did the caller ask for".
  // The over-limit refusal and the uncommitted-changes refusal are kept: those
  // are wrong *files*, not absent ones, and a run that publishes a listing
  // from a changelog it cannot read should say so however it was pointed at
  // one.
  String? notesIfPresent(String forVersion) {
    if (changelogPath == null) {
      return literalNotes;
    }
    requireCommittedNotes([changelogPath]);
    final notes = changelogNotesOf(
      changelogPath,
      forVersion,
      platform: platform.changelog,
    );
    if (notes is! NotesText) {
      return null;
    }
    if (notes.text.length > appStoreReleaseNotesLimit) {
      fail(
        "$changelogPath's ${notes.fromVersion} section is "
        '${notes.text.length} characters once filtered to '
        '${platform.changelog}; the App Store allows '
        '$appStoreReleaseNotesLimit',
      );
    }
    return notes.text;
  }

  // **The listing's release notes, resolved before anything is written.**
  //
  // Evaluated at the publish site, this read three ways to `fail` *after*
  // `_publishAscListing` had written content rights, categories, the age
  // rating, every localization, every screenshot and every preview: an
  // uncommitted CHANGELOG.md, a missing section, and a section over Apple's
  // limit. `notesFor`'s own doc calls moving the read into the offline phase
  // "the better fix" and declines it for the paths that came first; this one
  // is new, so it starts here.
  //
  // **A missing section is fatal only when the changelog was named.** The path
  // defaults to the project's CHANGELOG.md, so a run that asked for
  // screenshots and nothing else was newly refused for notes it had not
  // requested — the flag was inferred, and inference must not manufacture a
  // requirement. When `--changelog` or `--release-notes` was passed the notes
  // *are* what was asked for, and an absent section stays an error, because
  // "absent is not the same answer as empty" is the rule that flag carries.
  String? listingReleaseNotes;
  if (publish == ListingPublish.shared &&
      metadata != null &&
      versionName != null &&
      listingNeedsVersion(metadata)) {
    final named = opt('changelog') != null || notesPath != null;
    listingReleaseNotes = named
        ? notesFor(versionName)
        : notesIfPresent(versionName);
  }

  String? whatToTestNotes;
  if (cmd == AscCommand.whatToTest) {
    whatToTestNotes = notesFor(versionName!);
    if (whatToTestNotes == null) {
      fail(
        'no notes to publish — no CHANGELOG.md was found and neither '
        '--changelog nor --release-notes named one. Writing the TestFlight '
        '"What to Test" is all this command does, so there is nothing left '
        'for it to do.',
      );
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
        releaseType: releaseType,
      ),
    );
  }

  // Built only once every local check has passed.
  //
  // A supplied [ascClient] carries its own credentials, so the load is skipped
  // rather than done and discarded — which also means a test never needs the
  // environment `secrets exec` sets up.
  final AscClient client;
  if (ascClient != null) {
    client = ascClient;
  } else {
    final AscCredentials credentials;
    try {
      final loaded = AscCredentials.fromEnvironment();
      if (loaded == null) {
        // The same route the Play message names. This used to send people to a
        // `tool/with-secrets.sh` and a `docs/RELEASING-APPLE.md` that exist in
        // no consumer — the names of one repository's wrapper from before
        // `secrets exec` replaced it, surviving in the one message an operator
        // meets on their first run without credentials.
        fail(
          'no App Store Connect credentials.\n'
          '  APPLE_API_KEY_ID, APPLE_API_ISSUER_ID and APPLE_API_PRIVATE_KEY_PATH\n'
          '  are not set. Run this through `cux_ship secrets exec`, which writes\n'
          '  the key file and sets all three, or export them yourself.',
        );
      }
      credentials = loaded;
    } on StateError catch (e) {
      fail(e.message);
    }
    client = AscClient(credentials);
  }

  /// Releases the client, if this function is the one that opened it.
  ///
  /// A closure rather than the condition written twice, because there are two
  /// exits: `signing` returns before the `try` below is entered, so the
  /// `finally` there covers every path except that one. Two copies of an
  /// ownership rule is how they stop agreeing.
  void releaseClient() {
    if (ascClient == null) {
      client.close();
    }
  }

  // Account wide, so it returns before resolveApp: the audit is about the
  // team's certificates and identifiers, and asking Apple to resolve an app
  // would fail for a project that has no App Store record yet.
  //
  // **And returning before `resolveApp` means returning before the `try` at the
  // bottom**, so this path has never been covered by that `finally` and has to
  // release the client itself. Harmless while `runAsc` only ever ran in a
  // process about to exit; not harmless now that it can be called in-process,
  // where a client nobody closed simply stays open.
  if (cmd == AscCommand.signing) {
    final bool ok;
    try {
      ok = await reportSigning(client, bundleId: bundleId);
    } finally {
      releaseClient();
    }
    // After the release rather than inside the `try`: `exit` terminates without
    // unwinding, so a `finally` below it would not run.
    if (!ok) {
      exit(1);
    }
    return;
  }

  final writer = Writer(client, dryRun: dryRun);
  final store = AppStore(client, writer, platform: platform);
  started = store;

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
      // **Under `--json`, stdout carries the document and nothing else.** This
      // is the only line that reaches stdout before a listing does, and it is
      // the whole of what stdout purity costs on this path — `resolveApp`
      // prints nothing, and the listings are the last thing to run.
      //
      // Written out as a branch rather than as `jsonOutput ? stderr : stdout`
      // because `close_sinks` reads a local holding either one as a sink this
      // function forgot to close, and it is not wrong to ask.
      final banner = '==> ${app.name} ($bundleId) is app ${app.id}';
      if (jsonOutput) {
        stderr.writeln(banner);
      } else {
        stdout.writeln(banner);
      }
    }

    if (cmd == AscCommand.buildNumber) {
      await store.printBuildNumber(app);
      return;
    }
    if (cmd == AscCommand.previews) {
      final wanted = args.option('version-name');
      if (wanted == null || wanted.isEmpty) {
        fail(
          'which version? Pass `appstore previews --version-name 1.2.0`. '
          'Previews are version-scoped, so "the previews" has no single '
          'answer.',
        );
      }
      // **There is no "no such version" line here, because that answer never
      // arrives as one.** `ensureVersion(create: false)` throws a 404 naming
      // the version and the request when Apple holds none; it returns null
      // only on the *create* path, where a dry-run has no version to report,
      // and that path cannot be reached from a read. A branch for null here
      // would be dead code claiming an API this method does not have — and it
      // was one, until a test written against the real behaviour found it
      // printing nothing at all where it promised a diagnosis.
      final version = (await store.ensureVersion(app, wanted, create: false))!;
      final on = await store.previewsOn(version);
      final lines = <String>[
        if (on.isEmpty)
          '$wanted carries no previews'
        else
          for (final entry in on) ...[
            '${entry.locale ?? '?'}  ${entry.previewType ?? '?'}  '
                '${entry.preview.fileName ?? entry.preview.id}  '
                'video ${entry.preview.videoState ?? '-'}  '
                'frame ${entry.preview.frameState ?? '-'}  '
                'poster ${entry.preview.frameTimeCode?.isNotEmpty ?? false ? entry.preview.frameTimeCode : '(not set)'}',
          ],
      ];
      if (args.flag('json')) {
        writeJsonDocument(
          appStorePreviewsDocument(
            on,
            platform: platform,
            bundleId: bundleId,
            versionName: wanted,
            display: lines,
          ),
        );
        return;
      }
      for (final line in lines) {
        stdout.writeln(line);
      }
      return;
    }

    if (cmd == AscCommand.awaitPreviews) {
      final wanted = args.option('version-name');
      if (wanted == null || wanted.isEmpty) {
        fail(
          'which version? Pass `appstore wait-previews --version-name 1.2.0`. '
          'Deliberately not defaulted to the newest, for the reason `wait` '
          'gives about build numbers: waiting from another machine is waiting '
          'for a *specific* version, and "newest" would succeed on somebody '
          "else's.",
        );
      }
      // Null is unreachable with `create: false` — see the note in the
      // `previews` branch above. Apple holding no such version arrives as a
      // 404 that already names it.
      final version = (await store.ensureVersion(app, wanted, create: false))!;
      final on = await store.previewsOn(version);
      if (on.isEmpty) {
        stdout.writeln('==> $wanted carries no previews — nothing to wait for');
        return;
      }
      for (final entry in on) {
        // stderr under `--json`, because stdout carries the document and
        // nothing else — the invariant this file states for every other
        // `--json` command, and the one an unconditional writeln breaks.
        final line =
            '==> ${entry.locale ?? '?'} ${entry.previewType ?? '?'}: '
            '${entry.preview.fileName ?? entry.preview.id}';
        if (args.flag('json')) {
          stderr.writeln(line);
        } else {
          stdout.writeln(line);
        }
      }
      // **Progress on stderr, always.** A wait is progress and *then* an
      // answer, so one document at the end cannot be rendered as progress —
      // splitting by stream rather than by flag gives a person the live report
      // and a program the clean document, without either having to choose. It
      // also sidesteps NDJSON: streaming progress as data later becomes a
      // compatible addition rather than a redesign.
      await store.awaitPreviewProcessing(
        [
          for (final entry in on) ...{?entry.preview.id},
        ],
        timeout: awaitTimeout ?? const Duration(minutes: 30),
        poll: awaitPoll ?? const Duration(seconds: 30),
        onProgress: (progress) => stderr.writeln(
          '      ${progress.fileName ?? progress.previewId} at '
          '${progress.waited.inSeconds}s: '
          'video ${progress.videoState ?? 'not reported'}, '
          'poster frame ${progress.frameState ?? 'not reported'}'
          '${progress.frameStateAbandoned ? ' (taking the video as final)' : ''}',
        ),
      );
      // **With a tree, the wait finishes the job rather than only reporting
      // it.** Apple discards `previewFrameTimeCode` sent at reservation, so
      // the frame has to be asserted after ingestion — which is exactly the
      // phase `upload --skip-waiting` defers, and the reason this command
      // takes a `--metadata` the plan originally said it would not.
      if (metadata != null) {
        final localizations = await store.versionLocalizations(version);
        for (final locale in metadata.locales) {
          // Read once for this version and handed to every locale, rather
          // than re-read per locale: nothing in this command writes a
          // localization, so one reading cannot go stale under it.
          final localization = await store.localizationForUpload(
            version,
            locale.locale,
            known: localizations,
          );
          if (localization == null) {
            continue;
          }
          for (final entry in locale.previews.entries) {
            await store.assertPosterFramesOn(
              localization,
              entry.key,
              entry.value,
            );
          }
        }
      }
      if (args.flag('json')) {
        // Re-read, because this document is about what Apple holds now and
        // the wait's own polls are progress rather than a settled answer.
        final settled = await store.previewsOn(version);
        writeJsonDocument(
          appStorePreviewsDocument(
            settled,
            platform: platform,
            bundleId: bundleId,
            versionName: wanted,
            display: <String>[
              for (final entry in settled) ...[
                '${entry.locale ?? '?'}  ${entry.previewType ?? '?'}  '
                    '${entry.preview.fileName ?? entry.preview.id}  ready',
              ],
            ],
          ),
        );
        return;
      }
      stdout.writeln('==> previews are ready');
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
      await printBuilds(store, app, json: jsonOutput);
    }
    if (cmd == AscCommand.betaGroups) {
      await store.listBetaGroups(app);
    }
    if (cmd == AscCommand.versions) {
      await printVersions(store, app, json: jsonOutput);
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
          noSuchBuild(
            platform: platform,
            buildNumber: buildNumber,
            bundleId: bundleId,
          ),
        );
      }
      final attributes = build['attributes'] as Map<String, dynamic>?;
      final state = attributes?['processingState'] as String? ?? '(unknown)';
      final unusable = unusableBuildState(
        state: state,
        buildNumber: buildNumber,
        platform: platform,
        waitingFor: 'a build cannot reach a group',
      );
      if (unusable != null) {
        fail(unusable);
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

    // --------------------------------------------------------- what-to-test

    // The notes half of an upload, for a caller that did the waiting itself.
    //
    // **A command does something or waits for something, never both.** An
    // upload transfers an artifact (minutes, and exclusive — Apple takes one
    // CFBundleVersion once), then waits for processing (five to fifteen
    // minutes, and shareable — any machine with the API key can poll), then
    // writes the notes (seconds, exclusive again). A caller shipping iOS and
    // macOS from one commit has to serialise the whole command for the sake
    // of the two exclusive phases, and so pays both long polls end to end
    // with nothing else running.
    //
    // `appstore wait` already let the poll move; this is the piece that made
    // moving it useless, because `setWhatToTest` had exactly one call site
    // and it was inside the branch that did the waiting. The decomposition is
    // now whole: `upload --skip-waiting`, then `wait`, then this, then
    // `beta-release` where a group is wanted.
    //
    // Shaped like beta-release deliberately, down to the refusals: it needs a
    // processed build, and it **refuses rather than waiting** for one. A
    // command that quietly blocked here would put the two phases back
    // together under a new name.
    if (cmd == AscCommand.whatToTest) {
      final build = await store.findBuild(app, buildNumber!);
      if (build == null) {
        fail(
          noSuchBuild(
            platform: platform,
            buildNumber: buildNumber,
            bundleId: bundleId,
          ),
        );
      }
      final attributes = build['attributes'] as Map<String, dynamic>?;
      final state = attributes?['processingState'] as String? ?? '(unknown)';
      final unusable = unusableBuildState(
        state: state,
        buildNumber: buildNumber,
        platform: platform,
        waitingFor: 'its notes cannot be written',
      );
      if (unusable != null) {
        fail(unusable);
      }

      stdout.writeln('==> TestFlight notes for build $buildNumber');
      // The same announcement the upload path makes, for the same reason: what
      // testers read then differs from what Play users read, and that is said
      // out loud rather than done quietly.
      var text = whatToTestNotes!;
      if (needsStrippingForApple(text)) {
        text = stripForApple(text);
        stdout.writeln(
          '    TestFlight rejects emoji, so they are stripped from the notes\n'
          '    (Play publishes them verbatim)',
        );
      }
      // **Called unconditionally, including under `--dry-run`, and that is
      // not the bug it looks like.** `Writer(client, dryRun: dryRun)` is what
      // makes the run honest: the POST and the PATCH inside are suppressed
      // there and it prints its own `would update: what to test (<locale>)`
      // instead. Written down because a reader meeting "call the writer, then
      // print nothing was written" re-checks it — one already has.
      await store.setWhatToTest(build, locale, text);
      stdout.writeln(dryRun ? '==> dry run — nothing was written' : '==> done');
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
          // From the client rather than a variable of its own: the two must
          // name the same key, and a supplied client is the only source of
          // truth about which one that is.
          credentials: client.credentials,
          dryRun: dryRun,
        );
      }

      if (dryRun && existing == null) {
        stdout.writeln('    would then wait for processing and set the notes');
      } else if (flag('skip-waiting')) {
        stdout.writeln('==> not waiting for processing, as asked');
        // **Named, because skipping the wait skips the notes with it**, and
        // that used to be visible only in the flag's own help — where a
        // caller reaching for concurrency has no reason to look, since the
        // sentence there described a debugging flag. This is the whole of the
        // loudness now; see the note beside the beta-group refusal for why
        // there is no refusal here to go with it.
        //
        // **The suggested line carries whichever notes flag this run was
        // given**, so it is paste-able rather than merely indicative. Without
        // it the remedy silently reverts to the inferred CHANGELOG.md, which
        // for the caller most likely to be reading — one that passed a flag
        // *because* inference is wrong for their layout — names the wrong
        // file, or none.
        if (changelogPath != null || literalNotes != null) {
          final asked = opt('changelog') != null
              ? '--changelog ${opt('changelog')}'
              : notesPath != null
              ? '--release-notes $notesPath'
              : null;
          final finish = finishAfterSkippedWait(
            platform: platform,
            buildNumber: buildNumber,
            notes: true,
            notesArgument: asked,
          );
          stdout.writeln(
            '    so the TestFlight notes are NOT set. Finish elsewhere:\n'
            '${finish.map((line) => '      $line').join('\n')}',
          );
        }
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
      final published = await _publishAscListing(
        store,
        app,
        metadata!,
        locale,
        versionName,
        fail,
        // **The flag reaches the metadata path at last.** It is declared on
        // `upload` and was read only inside the artifact branch, so the one
        // command that publishes a preview never consulted it — an escape
        // hatch that existed, was spelled correctly, and was unreachable.
        skipPreviewWait: flag('skip-waiting'),
      );
      // **The "What's New" a listing-only publish used to drop on the floor.**
      // `--changelog` is accepted by this command and was read only for the
      // TestFlight notes an artifact upload writes — so a metadata-only run
      // passed it, said nothing, and left the App Store showing an empty
      // "What's New in This Version". See [publishReleaseNotes], which carries
      // the first-version rule and the emoji strip so that both publishers get
      // them.
      //
      // Skipped when the tree needed no version: there is then nothing to hang
      // release notes off, and `--version-name` was not required.
      // **Gated on the flag, not on the resolved notes**, which is what the
      // first attempt got wrong: the notes are only resolved when the tree
      // needs a version, so on an app-level-only tree `listingReleaseNotes`
      // is always null and the message could never fire — a skip notice that
      // was itself silent.
      // **A skipped wait leaves the poster frame unset, and that has to be
      // the loudest line of the run.** `--skip-waiting` already defers the
      // TestFlight notes and says so; this is worse, because Apple discards
      // the timecode sent at reservation — so a preview left un-asserted poses
      // at Apple's default, which is invisible rather than absent and cannot
      // be changed after approval. The follow-up is not advice.
      if (store.previewsLeftIngesting.isNotEmpty) {
        final on = platform == AscPlatform.ios
            ? ''
            : ' --platform ${platform.name}';
        stdout.writeln(
          '==> ${store.previewsLeftIngesting.length} preview set(s) are '
          'uploaded and still ingesting, and their poster frames are NOT set '
          'yet.\n'
          '    Finish with:\n'
          '      cux_ship appstore wait-previews$on --bundle-id $bundleId '
          '--version-name $versionName \\\n'
          '        --metadata ${metadataPath ?? '<tree>'}',
        );
      }
      if (published == null &&
          (opt('changelog') != null || notesPath != null)) {
        // **The narrowed remains of the defect this change closes.** A tree
        // declaring only app-level fields — categories, age rating, content
        // rights, a localized name — needs no version, so there is no record
        // to hang release notes off and none was created. The notes are
        // genuinely not publishable here, but saying nothing is what the
        // original bug did, and the whole point is that a flag taken and
        // dropped must not look like a command that did what was asked.
        stdout.writeln(
          '==> release notes skipped: this tree declares nothing Apple scopes '
          'to a version,\n'
          '    so no version was created to carry them. Add version-scoped '
          'listing text,\n'
          '    or publish the notes with `appstore promote --changelog`.',
        );
      }
      if (published != null) {
        await publishReleaseNotes(
          store,
          app,
          published,
          locale,
          listingReleaseNotes,
          versionName,
          declaredLocales: {
            for (final l in metadata.locales) ...{l.locale},
          },
        );
      }
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
        releaseType: releaseType,
      );

      if (version != null) {
        // **Effective, not intended** — the consuming project's rule, which
        // this package applies throughout (see `baked_facts.dart`). Read off
        // the record Apple acknowledged rather than off the flag, because the
        // interesting case is the run where nobody passed one: tonight's
        // release went out MANUAL after somebody had decided otherwise, and
        // no line anywhere said so.
        //
        // Promote only. A listing publish also creates a version, but it is
        // not deciding how a release starts — the promote that later adopts
        // that version is, and this is where the decision lands.
        //
        // Suppressed on a dry run, where nothing was written: printing the
        // record's current value beside a flag asking for a different one
        // would be an "effective" line a real run falsifies.
        final effective =
            (version['attributes'] as Map<String, dynamic>?)?['releaseType'];
        if (!dryRun && effective is String) {
          stdout.writeln(
            '==> release type: $effective'
            '${effective == 'MANUAL' ? ' — release it yourself once approved' : ''}',
          );
        }
        await store.attachBuild(version, chosen);

        await publishReleaseNotes(
          store,
          app,
          version,
          locale,
          notesFor(versionName),
          versionName,
        );
        if (flag('phased')) {
          stdout.writeln('==> phased release');
          await store.enablePhasedRelease(version);
        }
        // **On a promotion the listing publishes here, and nowhere else** —
        // which [publish] now makes true rather than merely stated.
        //
        // Scoped to the promotion on purpose. The sentence this replaces said
        // "here, and only here" flatly, which was false twice over: it was
        // false of the promote it described, because the shared site fired as
        // well, and it is still false of the program, because a listing-only
        // run publishes at the shared site by design. Being exact about which
        // run it is talking about is the difference between a comment that
        // survives the next reader and the one that did not.
        //
        // This is the moment the listing becomes what a shopper reads, and
        // the version record it hangs off exists by now, which is what makes
        // it possible at all. Before the submission, so a review sees the copy
        // that was meant to accompany it rather than the previous release's.
        if (publish == ListingPublish.afterVersion) {
          // No `skipPreviewWait`: `--skip-waiting` is declared on `upload`
          // alone, so `promote --skip-waiting` does not parse and the refusal
          // the design document proposed would guard a combination nobody can
          // type. A promotion submits for review, and Apple refuses a
          // submission whose assets are in flight — so a promote must wait,
          // and here it cannot do otherwise by construction.
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
    _reportStateLeftBehind(store);
    exitCode = 1;
  } on ProcessingTimeout catch (e) {
    // Caught rather than left to the runtime: an uncaught exception exits 255
    // with a stack trace, and a stack trace above the one sentence that says
    // "read the e-mail" is how that sentence gets skimmed past.
    stderr.writeln('asc_upload: $e');
    _reportStateLeftBehind(store);
    exitCode = 1;
  } on PreviewsPending catch (e) {
    // **Two callers, two right answers, which is the argument for the wait
    // being a command.** For `wait-previews` the deadline is the outcome, not
    // a failure: Apple documents ingestion in hours, the assets are uploaded,
    // and nothing is wrong. It exits [previewsPendingExit] so a script can
    // branch on three states — done, still going, broken — without reading a
    // word, which is what the one consumer asked for after a status of theirs
    // escaped from four regular expressions matched against stdout.
    //
    // Everywhere else the same condition means "I cannot safely proceed to a
    // submission", and stays exit 1.
    if (cmd == AscCommand.awaitPreviews) {
      stderr.writeln('asc_upload: $e');
      stderr.writeln(
        '  Re-run `cux_ship appstore wait-previews` to keep waiting; nothing '
        'is re-uploaded.',
      );
      exitCode = previewsPendingExit;
      return;
    }
    // **The clause the sibling above exists to justify, missing for one
    // release.** Replacing the wait's `AscApiException(504)` with a type that
    // says more took its catch clause away with it: the deadline exited 255
    // with a stack trace over the message, which is precisely the failure
    // `ProcessingTimeout`'s comment describes — and worse here, because this
    // exception's entire value is its wording and the outcome it reports is
    // one the design document calls *ordinary*.
    //
    // Exit 1, not [previewsPendingExit]. That code belongs to `appstore
    // wait-previews`, which does not exist yet; here the deadline means "I
    // cannot safely proceed to a submission", which is the same fatal thing
    // the 504 meant. Reserving a code is not the same as spending it.
    stderr.writeln('asc_upload: $e');
    _reportStateLeftBehind(store);
    exitCode = 1;
  } on MetadataException catch (e) {
    stderr.writeln('asc_upload: ${e.message}');
    _reportStateLeftBehind(store);
    exitCode = 1;
  } catch (_) {
    // Anything not named above — a StateError from a response shaped wrongly,
    // a SocketException mid-promote — still exits having possibly created a
    // version. Rethrown so the exit code and stack trace are unchanged; the
    // report is the only thing added, because the state left behind is a fact
    // about the run rather than about which exception ended it.
    _reportStateLeftBehind(store);
    rethrow;
  } finally {
    // Only the one this function opened. A supplied [ascClient] belongs to
    // whoever supplied it, and may outlive this call — the same rule
    // `_openPlay` follows for the Play side, and the reason both are stated
    // rather than left to whoever reads the `finally` next.
    releaseClient();
  }
}

/// Says whether a category write moved a relationship nobody asked it to.
///
/// **A category PATCH names only what the tree declares, so it always omits
/// the rest** — the other category, and the four subcategory slots this tool
/// has never managed. Everything says omission leaves them alone: JSON:API
/// specifies it, established clients of this API distinguish omitting a
/// relationship from setting it explicitly null, and partial category
/// documents go out against a very large number of apps without lost
/// subcategories being a known problem.
///
/// That is a good argument and it is still inference. This turns it into a
/// reading, on the rare run that writes a category at all — and if it is ever
/// wrong, it is wrong on somebody's published listing, which is worth two GETs
/// to find out about on the first occurrence rather than the hundredth.
///
/// Never fails the run. The write has already happened, so there is nothing
/// left to protect by throwing, and a diagnostic that can take down a publish
/// is worse than the uncertainty it was added to remove.
Future<void> _checkCategoriesNothingElseMoved(
  AppStore store,
  Map<String, dynamic> appInfo, {
  required Map<String, String?>? before,
  required Set<String> declared,
}) async {
  final after = before == null
      ? null
      : await store.categoryRelationships(appInfo);
  if (before == null || after == null) {
    // Said out loud. A check that silently did not happen is indistinguishable
    // from one that passed, and this package's whole argument is that those
    // are different.
    stdout.writeln(
      '    (could not read the category relationships back, so nothing '
      'confirms\n'
      '     the other categories were left alone)',
    );
    return;
  }

  final moved = unrequestedCategoryChanges(
    before: before,
    after: after,
    declared: declared,
  );
  if (moved.isEmpty) {
    return;
  }
  // Loud, and on stderr, because this would mean the PATCH cleared a
  // relationship it did not name — a category quietly disappearing from a
  // published listing, and a fact about Apple's API that this package has
  // been assuming the opposite of.
  stderr.writeln(
    '  WARNING: writing the categories also changed '
    '${moved.join(", ")},\n'
    '  which ${moved.length == 1 ? 'was' : 'were'} not in the metadata tree. '
    'Apple appears to clear\n'
    '  category relationships a PATCH does not name. Check the listing in App '
    'Store\n'
    '  Connect, and please report this — cux_ship assumes the opposite.',
  );
  for (final name in moved) {
    stderr.writeln(
      '    $name: ${before[name] ?? '(unset)'} -> ${after[name] ?? '(unset)'}',
    );
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
    // Whitespace also disappears — stripping tidies the double spaces and
    // trailing indents an excised emoji leaves behind — and naming a newline
    // as a character the App Store rejects would be false. Only runes the
    // rule actually refuses are listed.
    if (!kept.contains(rune) &&
        !removed.contains(rune) &&
        needsStrippingForApple(String.fromCharCode(rune))) {
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
void _reportStateLeftBehind(AppStore store) {
  final change = store.versionChange;
  if (change != null) {
    // **The two cases want opposite remedies, so they get separate sentences.**
    // A created version can be deleted. A renamed one is a record that existed
    // before this run — usually the "1.0" Apple makes with the app — and
    // deleting it is wrong; putting the name back is the undo, which needs the
    // name it had.
    final was = change.previousVersionString;
    stderr.writeln(switch (change.change) {
      VersionChange.created =>
        '  This run created App Store version ${change.versionString} '
            'before it failed,\n'
            '  and that record is still there. Running the command again '
            'adopts it rather\n'
            '  than making a second one. Delete it in App Store Connect if '
            'the failure\n'
            '  means it should not exist.',
      VersionChange.renamed =>
        '  This run renamed an existing editable version '
            '${was == null ? '' : 'from $was '}to '
            '${change.versionString}\n'
            '  before it failed. That record predates this run, so deleting '
            'it is not the\n'
            '  undo — ${was == null ? 'renaming it back is' : 'renaming it '
                      'back to $was is'}. Running the command again adopts it '
            'as it now stands.',
    });
  }

  final submission = store.createdReviewSubmission;
  if (submission != null) {
    // Reported separately because the advice is the opposite: an empty
    // container is not litter to clear up, it is what the next attempt
    // reuses — and deleting it is the one thing that would make a rerun
    // behave worse.
    stderr.writeln(
      '  It also opened review submission $submission, which may be empty.\n'
      '  Leave it: an unsubmitted container blocks a new one, so if it is '
      'still\n'
      '  there the next run reuses it rather than failing on an error that '
      'does\n'
      '  not say why. An empty one may equally have gone by then, which is '
      'fine.',
    );
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
  required String? betaGroup,
  required String? changelogPath,
  required String locale,
  required bool phased,
  required String? releaseType,
}) {
  final rows = <String, String?>{
    'app': '$bundleId ($platform)',
    // beta-release names no version: it releases a build, and the inferred
    // pubspec version would only claim a fact the command never uses.
    // what-to-test does use one — it is which changelog section to read.
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
    // Null when unset, like every other row: nothing changes, so there is
    // nothing for the summary to say. The effective value is printed later,
    // from the record Apple acknowledged.
    'release type': releaseType,
  };

  final heading = switch (cmd) {
    AscCommand.promote =>
      'About to submit for App Store review. Once Apple approves it, this is '
          'public.',
    AscCommand.betaRelease =>
      'About to release a build TestFlight already holds to a beta group. '
          'An external group goes on to Apple for beta review.',
    // **Says what it will attempt, not what it has established.** This read
    // "on a build Apple has already processed", which is a claim about the
    // store — and the prompt is printed before any credential is loaded, so
    // nothing had checked it. In a real run the next line after the prompt
    // was "Apple holds no ios build 169".
    AscCommand.whatToTest =>
      'About to set the TestFlight "What to Test" on this build, if Apple '
          'has finished processing it. Nothing is uploaded and no audience '
          'widens.',
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
