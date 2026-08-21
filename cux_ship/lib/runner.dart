// SPDX-License-Identifier: Apache-2.0
//
// The command tree. One binary, subcommands grouped by store, because that is
// how the work is actually thought about — "I am doing an App Store thing" —
// and because a flag-selected mode cannot express which arguments belong to
// which operation.
//
// The parsers come from the store packages themselves rather than being
// restated here: each `Command` overrides [Command.argParser] with the parser
// its own library builds. There is one description of `--bundle-id`, in the
// package that reads it.
//
// A note on what is deliberately absent. No subcommand here changes a version,
// writes a tag, or touches git. A build number belongs to a commit, both stores
// promote that same build, and so the version they publish is the same one —
// which only holds if promotion cannot move it. Tagging and bumping is a
// once-per-release step and belongs to whatever drives this, not to any single
// store's promote.
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:cux_ship_verify/cux_ship_verify.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import 'src/appstore/cli.dart';
import 'src/appstore/flatten_cli.dart';
import 'src/asc_platforms.dart';
import 'src/build_manifest.dart';
import 'src/config.dart';
import 'src/confirm.dart';
import 'src/deps.dart';
import 'src/keychain.dart';
import 'src/listing_requirements.dart';
import 'src/manifest_cli.dart';
import 'src/placed.dart';
import 'src/play/cli.dart';
import 'src/project.dart';
import 'src/provenance.dart';
import 'src/release.dart';
import 'src/secrets.dart';

/// Builds the whole command tree.
CommandRunner<void> buildRunner() {
  final runner = CommandRunner<void>(
    'cux_ship',
    'Ship a Dart or Flutter app to the stores.\n'
        '\n'
        'Run from a project root. Almost everything is read from the project '
        'itself — the applicationId from Gradle, the bundle identifier from '
        'the Xcode project, the version from pubspec.yaml — so the common case '
        'is a bare subcommand and the flags are overrides.\n'
        '\n'
        'Anything that becomes public asks first. Pass --yes to skip that, '
        'which is also required when there is no terminal.',
  );
  runner.argParser
    ..addFlag(
      'yes',
      abbr: 'y',
      negatable: false,
      help:
          'Do not ask before publishing. Required in CI, where there is no '
          'terminal to ask at.',
    )
    ..addOption(
      'app-dir',
      help:
          'Where the Flutter app lives when it is not the repository root — '
          '"app" in a monorepo. pubspec.yaml, android/ and ios/ are read from '
          'there; CHANGELOG.md and store/ stay at the repository root, because '
          'a release describes what the repository shipped rather than what '
          'one package did. This is a property of the repository rather than '
          'of a command, so the usual home for it is app-dir in '
          '.cux-ship.yaml; this flag and CUX_SHIP_APP_DIR override that, in '
          'that order.',
    );
  return runner
    ..addCommand(_AppstoreCommand())
    ..addCommand(_PlayCommand())
    ..addCommand(_ReleaseCommand())
    ..addCommand(_ManifestCommand())
    ..addCommand(_ScreenshotsCommand())
    ..addCommand(_SecretsCommand())
    ..addCommand(_KeychainCommand())
    ..addCommand(_DepsCommand())
    ..addCommand(VerifyCommand());
}

/// The `--yes` flag, read off the top-level results a subcommand can reach.
bool _assumeYes(Command<void> command) =>
    command.globalResults?.flag('yes') ?? false;

/// The build manifest `--manifest` names, read and verified, or null.
///
/// **Read once here rather than in each place that wants a value from it.** The
/// verification hashes the artifact — 69 MB on one of these projects — so doing
/// it per-consumer would be paid twice for no reason, and worse, two reads
/// could disagree if `dist/` changed underneath.
BuildManifest? _manifest(Command<void> command) {
  final args = command.argResults!;
  if (!args.options.contains('manifest')) {
    return null;
  }
  final path = args.option('manifest');
  if (path == null || path.isEmpty) {
    return null;
  }
  final manifest = BuildManifest.read(path)
    ..verify(
      allowDirty:
          args.options.contains('allow-dirty') && args.flag('allow-dirty'),
    );
  stderr.writeln(
    '==> ${manifest.artifact} — build ${manifest.buildNumber} of '
    '${manifest.versionName} from ${manifest.gitSha}, digest verified',
  );
  // Said out loud on its own line, including when the answer is "not checked".
  // A format with no reader is trusted, and a trusted format that printed
  // nothing would read exactly like a verified one.
  stderr.writeln('    ${manifest.crossCheck()}');
  return manifest;
}

/// Writes the upload record, when the repository has asked for one.
///
/// **Before the store command runs, not after.** A record written afterwards
/// makes the failure mode "shipped but unprovable" — an artifact in front of
/// users whose commit nobody can name — while a record written first fails the
/// upload it could not vouch for. The second is recoverable and the first is
/// not.
///
/// Only for `upload`; a promote moves a build the store already holds and is
/// not the moment anything was published *from* this repository. Only when the
/// subcommand actually carries the options, so a parser that never declared
/// `--commit` is skipped rather than interrogated.
void _recordUploadIfAsked(
  Command<void> command, {
  required ProjectContext project,
  required ProjectConfig config,
  required String store,
  required String? Function() versionName,
  BuildManifest? manifest,
}) {
  final args = command.argResults!;
  // **`argParser.options` is what was *declared*; `ArgResults.options` is what
  // was *provided or defaulted*.** This asked the second and meant the first,
  // so recording was skipped for every caller that did not type `--commit` —
  // which is every caller using `--manifest`, the flag that exists to supply it.
  // Nothing failed: the guard is the silent kind, and `record-uploads: true`
  // read as working for as long as nobody looked for the tag.
  if (command.name != 'upload' ||
      !command.argParser.options.containsKey('commit')) {
    return;
  }
  String? opt(String name) =>
      command.argParser.options.containsKey(name) ? args.option(name) : null;

  final result = recordUploadIfConfigured(
    project.root,
    config.uploadTag,
    store: store,
    version: opt('version-name') ?? manifest?.versionName ?? versionName(),
    build: opt('build-number') ?? manifest?.buildNumber,
    // The manifest's gitSha is the whole reason --commit exists, so a caller
    // that passed one has already answered the question the flag asks.
    commit: opt('commit') ?? manifest?.gitSha,
    checksum: manifest?.sha256Digest,
    // A dry run must not write a record: it deletes its store edit rather than
    // committing, so nothing is published and there is nothing to record.
    dryRun: args.options.contains('dry-run') && args.flag('dry-run'),
  );
  if (result != null) {
    stderr.writeln(switch (result) {
      UploadRecordResult.created => '==> recorded this upload',
      UploadRecordResult.alreadyRecorded => '==> upload already recorded',
    });
  }
}

/// The `--app-dir` option, falling back to `CUX_SHIP_APP_DIR`.
///
/// The environment is what lets a wrapper script set it once rather than
/// threading the flag through every invocation it makes. An empty value counts
/// as unset, so `CUX_SHIP_APP_DIR=` in a shell means the same as not exporting
/// it at all rather than naming a directory called "".
String? _appDir(Command<void> command) {
  final value =
      command.globalResults?.option('app-dir') ??
      Platform.environment['CUX_SHIP_APP_DIR'];
  return (value == null || value.isEmpty) ? null : value;
}

/// The project, with `--app-dir` applied.
///
/// A bad value is a usage error rather than something to work around: inference
/// failing quietly is exactly what the flag exists to prevent, so a directory
/// that is missing or outside the repository has to stop the command instead of
/// yielding a context in which nothing was found.
ProjectContext _project(Command<void> command) {
  try {
    return ProjectContext.read(appDir: _appDir(command));
  } on ProjectException catch (e) {
    throw UsageException('--app-dir: ${e.message}', command.usage);
  }
}

// --------------------------------------------------------------- app store

class _AppstoreCommand extends Command<void> {
  _AppstoreCommand() {
    for (final cmd in AscCommand.values) {
      addSubcommand(_AscSubcommand(cmd));
    }
  }

  @override
  String get name => 'appstore';

  @override
  String get description =>
      'App Store Connect: upload, promote, and read back.';
}

class _AscSubcommand extends Command<void> {
  _AscSubcommand(this.cmd) : argParser = buildAscParser(cmd);

  final AscCommand cmd;

  @override
  final ArgParser argParser;

  @override
  String get name => cmd.name;

  @override
  String get description => switch (cmd) {
    AscCommand.upload =>
      'Upload a signed .ipa, the listing, or both. Everything checkable '
          'offline is checked before a credential is loaded.',
    AscCommand.promote =>
      'Submit a build TestFlight already holds for App Store review. Builds '
          'and uploads nothing; changes no version.',
    AscCommand.builds => 'Print the builds Apple holds.',
    AscCommand.versions => 'Print the App Store versions.',
    AscCommand.screenshotTypes =>
      "Print the ScreenshotDisplayType values this app carries — Apple's "
          'published enum lags the console, so read rather than guess.',
    AscCommand.buildNumber =>
      'Print the newest processed build number and nothing else, for scripts.',
    AscCommand.awaitBuild =>
      'Wait for a build Apple is processing, and say which of the three ways '
          'it ended. Needs only the API key, so it belongs on a cheap runner '
          'rather than the macOS one that built it.',
    AscCommand.signing =>
      'Print the certificates, App IDs and profiles the developer account '
          'holds, so drift from automatic signing is visible. Reads only, and '
          'needs an Admin key.',
  };

  @override
  Future<void> run() {
    final project = _project(this);
    final platform = argResults!.option('platform') ?? 'ios';
    final config = ProjectConfig.read(project.root);
    final store = config.appstore;
    final manifest = _manifest(this);
    _recordUploadIfAsked(
      this,
      project: project,
      config: config,
      store: 'appstore/$platform',
      versionName: () => project.versionName,
      manifest: manifest,
    );
    return runAsc(
      cmd,
      argResults!,
      defaults: AscDefaults(
        bundleId: project.bundleIdFor(platform),
        bundleIdProblem: project.bundleIdProblemFor(platform),
        versionName: manifest?.versionName ?? project.versionName,
        artifact: manifest?.artifactPath,
        buildNumber: manifest?.buildNumber,
        changelog: project.changelog,
        metadata: project.appStoreMetadata,
        // Why the requirement could not be derived, when nothing declared one
        // either. Without it this path falls back to requiring nothing and
        // says nothing — which is the silent-pass shape the release removes,
        // surviving on the one command that reaches Apple.
        listingProblem: store == null
            ? null
            : _derivationProblem(
                // Empty rather than read: the App Store parser has no
                // --require-screenshot-type. That flag belongs to `verify`,
                // and reading it here is what crashed every appstore
                // subcommand in 3.2.0.
                const {},
                store,
                project,
                platform: platform,
              )?.message,
        // Null when the repository declares nothing, so a project that has not
        // adopted the config is unaffected. Declared, and this is the command
        // that has to honour it — see the check at the call site.
        listingRequirements: store == null
            ? null
            : ListingRequirements(
                locales: store.locales,
                screenshotTypes: store.screenshotsFor(platform).isNotEmpty
                    ? store.screenshotsFor(platform)
                    : project.requiredScreenshotTypes(platform) ?? const {},
              ),
      ),
      confirm: (summary) => confirmOrExit(summary, assumeYes: _assumeYes(this)),
    );
  }
}

// -------------------------------------------------------------------- play

class _PlayCommand extends Command<void> {
  _PlayCommand() {
    for (final cmd in PlayCommand.values) {
      addSubcommand(_PlaySubcommand(cmd));
    }
  }

  @override
  String get name => 'play';

  @override
  String get description => 'Google Play: upload, promote, and read back.';
}

class _PlaySubcommand extends Command<void> {
  _PlaySubcommand(this.cmd) : argParser = buildPlayParser(cmd);

  final PlayCommand cmd;

  @override
  final ArgParser argParser;

  @override
  String get name => cmd.name;

  @override
  String get description => switch (cmd) {
    PlayCommand.upload =>
      'Upload a signed .aab, the listing, or both, in one edit transaction '
          'that commits or discards as a whole.',
    PlayCommand.promote =>
      'Point a track at a versionCode Play already holds. Builds and uploads '
          'nothing; changes no version.',
    PlayCommand.tracks => 'Print what Play currently has on each track.',
    PlayCommand.listing => 'Print what Play currently holds for the listing.',
    PlayCommand.versionCode =>
      'Print the newest versionCode on --track and nothing else, for scripts.',
  };

  @override
  Future<void> run() {
    final project = _project(this);
    final config = ProjectConfig.read(project.root);
    final store = config.play;
    final manifest = _manifest(this);
    _recordUploadIfAsked(
      this,
      project: project,
      config: config,
      store: 'play',
      versionName: () => project.versionName,
      manifest: manifest,
    );
    return runPlay(
      cmd,
      argResults!,
      defaults: PlayDefaults(
        packageName: project.androidPackage,
        versionName: manifest?.versionName ?? project.versionName,
        artifact: manifest?.artifactPath,
        buildNumber: manifest?.buildNumber,
        changelog: project.changelog,
        metadata: project.playMetadata,
        dataSafety: project.dataSafety,
        // Play's screenshot vocabulary is directory names, so it comes from
        // play.screenshots and nowhere else — there is nothing to derive it
        // from, and the App Store's flag names a different vocabulary.
        listingRequirements: store == null
            ? null
            : ListingRequirements(
                locales: store.locales,
                screenshotTypes: store.screenshotsFor(StoreConfig.anyPlatform),
              ),
      ),
      confirm: (summary) => confirmOrExit(summary, assumeYes: _assumeYes(this)),
    );
  }
}

// ----------------------------------------------------------------- release

/// Teaches this clone to fetch the refs a build-number allocator keeps.
///
/// **A separate command rather than something a release does silently**, and
/// the reason is that it edits `.git/config`, which is the one piece of state a
/// release command has no business changing on its own. Run once per clone —
/// and per worktree only if that worktree has its own remote configuration,
/// which the ordinary one does not.
class _RefspecsCommand extends Command<void> {
  _RefspecsCommand() {
    argParser
      ..addOption(
        'remote',
        defaultsTo: 'origin',
        help: 'The remote whose fetch refspecs are extended.',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Say what would change, and change nothing.',
      );
  }

  @override
  String get name => 'refspecs';

  @override
  String get description =>
      'Configure this clone to fetch refs/buildnumbers/* and the build-number '
      'notes ref, which a default clone ignores.';

  @override
  void run() {
    final project = _project(this);
    final log = configureBuildnumberRefspecs(
      Git(project.root),
      remote: argResults!.option('remote')!,
      dryRun: argResults!.flag('dry-run'),
    );
    for (final line in log) {
      stdout.writeln('==> $line');
    }
  }
}

class _ReleaseCommand extends Command<void> {
  _ReleaseCommand() {
    addSubcommand(_FinishCommand());
    addSubcommand(_RefspecsCommand());
  }

  @override
  String get name => 'release';

  @override
  String get description =>
      'Repository-side steps that belong to a release rather than to a store.';
}

class _FinishCommand extends Command<void> {
  _FinishCommand() {
    argParser
      ..addOption(
        'commit',
        help:
            'The commit that was released, and what gets tagged. Defaults to '
            'HEAD.',
      )
      ..addOption(
        'version',
        help:
            'The marketing version that was released. Defaults to the version '
            "in the released commit's pubspec.yaml, which is the one the "
            'stores were given.',
      )
      ..addOption(
        'build-number',
        help: 'Recorded in the tag message, so a tag names its build.',
      )
      ..addOption(
        'destination',
        defaultsTo: 'production',
        help: 'Where it went, for the tag and commit messages.',
      )
      ..addOption(
        'branch',
        defaultsTo: 'main',
        help: 'The branch the bump commit belongs on.',
      )
      ..addFlag('tag', defaultsTo: true, help: 'Tag the released commit.')
      ..addFlag(
        'bump',
        defaultsTo: true,
        help: 'Move the branch to the next patch version.',
      )
      ..addFlag(
        'push',
        defaultsTo: true,
        help: 'Push the tag and the bump, when there is an origin.',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Say what would happen. Writes nothing and commits nothing.',
      );
  }

  @override
  String get name => 'finish';

  @override
  String get description =>
      'Tag the released commit and move the branch to the next patch version. '
      'Run once per release, after every store has been promoted — not once '
      'per store.';

  @override
  void run() {
    final args = argResults!;

    try {
      // The repository root, not the working directory. `dart run cux_ship` is
      // usually invoked from the consumer package that pins it — tool/cux_ship
      // — and pubspec.yaml and CHANGELOG.md belong to the repository, not to
      // whichever subdirectory the command was started in.
      final top = Process.runSync('git', [
        'rev-parse',
        '--show-toplevel',
      ], workingDirectory: Directory.current.path);
      if (top.exitCode != 0) {
        throw ReleaseException(
          'not inside a git repository: ${Directory.current.path}',
        );
      }
      final git = Git((top.stdout as String).trim());

      // Resolved against the repository root, and repository-relative from
      // here on: every use below is a git argument, and git takes none of them
      // as an absolute path.
      final appDir = ProjectContext.relativeAppDir(
        git.root,
        ProjectContext.effectiveAppDir(git.root, _appDir(this)),
      );
      final pubspecPath = pubspecPathFor(appDir);

      final commit = args.option('commit') ?? git.run(['rev-parse', 'HEAD']);

      // Read off the released commit rather than the working tree: the tree
      // may already have moved on, and the version that was published is a
      // property of what was published.
      //
      // Parsed here rather than carried as text. `--version` is a string from
      // a command line and `pubspecVersion` returns a `Version`; leaving the
      // two to meet as `Object` is how a version ends up compared with `==` on
      // its spelling. A `--version` that is not a version is a usage error and
      // says so at the boundary, not four calls later.
      final explicit = args.option('version');
      final Version version;
      if (explicit != null) {
        try {
          version = Version.parse(explicit);
        } on FormatException {
          throw ReleaseException('--version "$explicit" is not a version');
        }
      } else {
        version =
            pubspecVersion(git.run(['show', '$commit:$pubspecPath'])) ??
            (throw ReleaseException(
              'no version in $pubspecPath at $commit — pass --version',
            ));
      }

      final log = finishRelease(
        git,
        FinishOptions(
          commit: commit,
          version: version,
          buildNumber: args.option('build-number'),
          appDir: appDir,
          destination: args.option('destination')!,
          branch: args.option('branch')!,
          tag: args.flag('tag'),
          bump: args.flag('bump'),
          push: args.flag('push'),
          dryRun: args.flag('dry-run'),
        ),
      );
      for (final line in log) {
        stdout.writeln('==> $line');
      }
    } on ReleaseException catch (e) {
      stderr.writeln('cux_ship release finish: ${e.message}');
      exitCode = 1;
    } on ProjectException catch (e) {
      // From --app-dir. Reported here rather than as a UsageException because
      // by this point the repository root has been read and the message names
      // real paths, which is more use than the usage text would be.
      stderr.writeln('cux_ship release finish: --app-dir: ${e.message}');
      exitCode = 1;
    }
  }
}

// ---------------------------------------------------------------- manifest

class _ManifestCommand extends Command<void> {
  _ManifestCommand() {
    addSubcommand(_ManifestWriteCommand());
  }

  @override
  String get name => 'manifest';

  @override
  String get description =>
      'The sidecar file a build writes beside its artifact, and that every '
      'upload is named by.';
}

class _ManifestWriteCommand extends Command<void> {
  _ManifestWriteCommand() : argParser = buildManifestWriteParser();

  @override
  final ArgParser argParser;

  @override
  String get name => 'write';

  @override
  String get description =>
      'Write the manifest for a built artifact. Run it after signing: the '
      'digest is taken from the bytes as they stand.';

  @override
  String get invocation =>
      'cux_ship manifest write --artifact <path> --platform <p> '
      '--version-name <v> --build-number <n> --git-sha <sha> --no-dirty';

  @override
  void run() {
    try {
      runManifestWrite(argResults!);
    } on ReleaseException catch (e) {
      stderr.writeln('cux_ship manifest write: ${e.message}');
      exitCode = 1;
    }
  }
}

// ------------------------------------------------------------- screenshots

class _ScreenshotsCommand extends Command<void> {
  _ScreenshotsCommand() {
    addSubcommand(_FlattenCommand());
  }

  @override
  String get name => 'screenshots';

  @override
  String get description => 'Operations on captured screenshots.';
}

class _FlattenCommand extends Command<void> {
  _FlattenCommand() : argParser = buildFlattenParser();

  @override
  final ArgParser argParser;

  @override
  String get name => 'flatten';

  @override
  String get description =>
      'Remove the alpha channel from PNGs, in place. Every simulator and '
      'emulator capture has one; Apple refuses it.';

  @override
  String get invocation => 'cux_ship screenshots flatten [--check] <path>...';

  @override
  void run() => runFlatten(argResults!);
}

// ----------------------------------------------------------------- secrets

class _SecretsCommand extends Command<void> {
  _SecretsCommand() {
    addSubcommand(_SecretsAddCommand());
    addSubcommand(_SecretsCheckCommand());
    addSubcommand(_SecretsRemoveCommand());
    addSubcommand(_SecretsExecCommand());
    addSubcommand(_SecretsListCommand());
    addSubcommand(_SecretsPlaceCommand());
    addSubcommand(_SecretsCleanCommand());
    addSubcommand(_SecretsPackCommand());
  }

  @override
  String get name => 'secrets';

  @override
  String get description =>
      'Credentials, and the only part of cux_ship that knows sops exists.';
}

/// `secrets add <kind> <name> <file>`.
///
/// Positional rather than flagged, and the same shape for every kind: a human
/// names a file and an instance, and the tool works out the schema path, the
/// base64, the JSON quoting and everything readable back out of the artifact.
/// `--p12`/`--p8`/`--file` were the trivia this exists to remove.
///
/// The shape is not perfectly uniform — a token has no file, `play-account` has
/// no name — and that is said in the help rather than left to be discovered.
class _SecretsAddCommand extends Command<void> {
  _SecretsAddCommand() {
    argParser
      ..addOption(
        'file',
        help: 'The sops-encrypted file to write into.',
        defaultsTo: 'secrets/release.yaml',
      )
      ..addOption(
        'env',
        help:
            'The variable this is exported as. Required for token and ssh-key, '
            'which are declared rather than minted so a typo stays a typo.',
      )
      ..addOption(
        'issuer-id',
        help: 'For an api-key: the issuer, when the key is a team one.',
      )
      ..addOption(
        'password-file',
        help:
            'File holding the password that opens a .p12 or keystore. Read '
            'from a file rather than an argument, because an argument is '
            'visible to every `ps` on the machine.',
      )
      ..addOption(
        'value-file',
        help: 'For a token: the file holding its value. Otherwise read stdin.',
      )
      ..addFlag(
        'replace',
        negatable: false,
        help:
            'Rotate an existing credential. Without this, adding over one that '
            'exists is refused — silently replacing a signing key is worse '
            'than any partial write.',
      )
      ..addFlag(
        'from-keychain',
        negatable: false,
        help:
            'For a certificate: build the .p12 out of a macOS keychain instead '
            'of taking one, with a generated password. The onboarding path, '
            'for when there is an identity but no file.',
      )
      ..addOption(
        'team',
        help:
            'With --from-keychain: the team id, as it appears in OU=. '
            'Defaults to DEVELOPMENT_TEAM from the Xcode project, and is '
            'refused rather than guessed when the project names more than '
            'one.',
      )
      ..addOption(
        'certificate-kind',
        defaultsTo: 'Apple Distribution',
        help:
            'With --from-keychain: which certificate. Matched as well as the '
            'team, because an Apple Development certificate carries the same '
            'OU and would otherwise be exported silently.',
      )
      ..addOption(
        'keychain',
        help:
            'With --from-keychain: which keychain to export from. Defaults to '
            'the login keychain.',
      );
  }

  @override
  String get name => 'add';

  @override
  String get description =>
      'Put a credential into the secrets file: '
      '${addKindNames.join(', ')}.\n'
      'Usage: secrets add <kind> <name> <file>, where each applies — a token '
      'takes no file (its value comes from stdin or --value-file), and '
      'play-account takes no name.';

  @override
  Future<void> run() async {
    final project = _project(this);
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      throw UsageException('which kind? ${addKindNames.join(', ')}', usage);
    }
    final kindName = rest.first;
    final kind = addKinds[kindName];
    if (kind == null) {
      throw UsageException(
        'no such kind: $kindName — there is ${addKindNames.join(', ')}',
        usage,
      );
    }

    // A singleton has no name, so its file is the first positional after the
    // kind; everything else takes a name then a file.
    final instance = kind.singleton ? '' : (rest.length > 1 ? rest[1] : '');
    final fileArg = kind.singleton
        ? (rest.length > 1 ? rest[1] : null)
        : (rest.length > 2 ? rest[2] : null);

    if (!kind.singleton && instance.isEmpty) {
      throw UsageException('what should this $kindName be called?', usage);
    }
    // Two positionals, exactly one of which should exist on disk. Catching the
    // swap here means the memorable order does not have to be enforced by
    // syntax.
    if (fileArg != null &&
        !File(fileArg).existsSync() &&
        File(instance).existsSync()) {
      throw UsageException(
        'those look swapped — "$instance" is a file and "$fileArg" is not.\n'
        'The order is: secrets add $kindName <name> <file>',
        usage,
      );
    }

    final option = argResults!.option('file')!;
    final secretsFile = File(
      p.isAbsolute(option) ? option : p.join(project.root, option),
    );

    // The keychain path supplies both the file and its password, so neither is
    // asked for. It is the only case where the password is generated rather
    // than taken: we are building the .p12, nothing ever has to type its
    // password, and one a human picks is one they reuse.
    ExportedIdentity? exported;
    var artifact = fileArg;
    final exportedNotes = <String>[];
    try {
      if (argResults!.flag('from-keychain')) {
        if (kindName != 'certificate') {
          throw UsageException(
            '--from-keychain builds a certificate; $kindName does not come '
            'from a keychain',
            usage,
          );
        }
        if (!Platform.isMacOS) {
          throw ProjectException('--from-keychain needs macOS');
        }
        // Defaults from DEVELOPMENT_TEAM, as `keychain exec --team` already
        // did. This was the one value in an Apple setup still typed by hand,
        // and it is derivable from a file already being parsed for the bundle
        // identifier — retyping it once a year during a certificate rotation
        // is exactly where a transposition goes unnoticed until a profile
        // mismatch that never mentions the team.
        final team = argResults!.option('team') ?? project.developmentTeam;
        if (team == null || team.isEmpty) {
          throw UsageException(
            project.developmentTeamProblem ??
                '--from-keychain needs --team, the id as it appears in OU= — '
                    'no DEVELOPMENT_TEAM could be read from the Xcode project',
            usage,
          );
        }
        exported = exportIdentityFromKeychain(
          team: team,
          certificateKind: argResults!.option('certificate-kind')!,
          keychain: argResults!.option('keychain'),
        );
        artifact = exported.p12Path;
        exportedNotes.addAll(exported.notes);
      }

      final secret =
          exported?.password ??
          _readSecretInput(
            passwordFile: argResults!.option('password-file'),
            valueFile: argResults!.option('value-file'),
            needed: kind.needsSecretInput,
          );
      final result = await addCredential(
        repoRoot: project.root,
        secretsFile: secretsFile,
        kindName: kindName,
        instance: instance,
        filePath: artifact,
        env: argResults!.option('env'),
        issuerId: argResults!.option('issuer-id'),
        password: secret,
        replace: argResults!.flag('replace'),
        describeProfile: describeProfileForAdd,
        findStaleProfiles: Platform.isMacOS
            ? (certificatePath) => profilesEmbeddingCertificate(
                repoRoot: project.root,
                secretsFile: secretsFile,
                certificatePath: certificatePath,
                inspectProfile: inspectProfileForCheck,
                fingerprintCertificate: fingerprintStoredCertificate,
              )
            : null,
      );
      stdout.writeln(
        '${result.replaced ? 'replaced' : 'added'} ${result.path}  '
        '(${result.fields.join(', ')})',
      );
      for (final note in result.notes) {
        stdout.writeln('  $note');
      }
      // The coupling nothing else reports. A profile keeps its own expiry date,
      // so a rotation leaves profiles that look valid for years and cannot
      // sign — and the only moment to establish which is *before* the outgoing
      // certificate has been overwritten.
      if (result.staleProfiles.isNotEmpty) {
        final n = result.staleProfiles.length;
        stderr.writeln();
        stderr.writeln(
          '** $n profile${n == 1 ? ' was' : 's were'} issued against the '
          'certificate you just replaced:',
        );
        for (final profile in result.staleProfiles) {
          stderr.writeln('     $profile');
        }
        stderr.writeln(
          '   They cannot sign with the new certificate. Download replacements '
          'from the developer\n'
          '   portal and add them with '
          '`secrets add profile <name> <file> --replace`.',
        );
      } else if (result.staleProfilesUnknown) {
        stderr.writeln();
        stderr.writeln(
          '** which profiles were issued against the replaced certificate '
          'could not be\n'
          '   established, so this is not a report that none were. It needs '
          'macOS; run\n'
          '   `secrets check` on a Mac, where a profile that matches no stored '
          'certificate\n'
          '   is reported.',
        );
      }
    } on ProjectException catch (e) {
      stderr.writeln('cux_ship secrets add: ${e.message}');
      exitCode = 1;
    } finally {
      // However this ended. What is in there is a signing identity in
      // plaintext, and the encrypted copy is already written.
      if (exported != null && exported.work.existsSync()) {
        exported.work.deleteSync(recursive: true);
      }
    }
  }
}

/// Reads a password or token value without it ever being an argument.
///
/// A command-line argument is visible in `ps` to every user on the machine, and
/// the value here is the credential itself.
String? _readSecretInput({
  required String? passwordFile,
  required String? valueFile,
  required bool needed,
}) {
  final path = passwordFile ?? valueFile;
  if (path != null) {
    final file = File(path);
    if (!file.existsSync()) {
      throw ProjectException('no such file: $path');
    }
    // A trailing newline is the classic way to supply a credential that looks
    // right and authenticates as garbage.
    return file.readAsStringSync().trim();
  }
  if (!needed) {
    return null;
  }
  if (stdin.hasTerminal) {
    stdout.write('password: ');
    stdin.echoMode = false;
    try {
      final typed = stdin.readLineSync() ?? '';
      return typed.trim();
    } finally {
      stdin.echoMode = true;
      stdout.writeln();
    }
  }
  return stdin.readLineSync()?.trim();
}

class _SecretsCheckCommand extends Command<void> {
  _SecretsCheckCommand() {
    argParser.addOption(
      'file',
      help: 'The sops-encrypted file to read.',
      defaultsTo: 'secrets/release.yaml',
    );
  }

  @override
  String get name => 'check';

  @override
  String get description =>
      'Decrypt every credential and report whether it works, and whether the '
      'profiles still match the certificates. Needs an identity, so it runs '
      'where `secrets exec` runs. Exits non-zero only on a real failure — a '
      'credential this cannot authenticate is reported, not failed.';

  @override
  Future<void> run() async {
    final project = _project(this);
    final option = argResults!.option('file')!;
    final secretsFile = File(
      p.isAbsolute(option) ? option : p.join(project.root, option),
    );
    try {
      // On anything but a Mac the pairing cannot be read at all, and saying so
      // is better than a report that silently covers less than it appears to.
      final onMac = Platform.isMacOS;
      final rows = checkCredentials(
        repoRoot: project.root,
        secretsFile: secretsFile,
        inspectProfile: onMac ? inspectProfileForCheck : null,
        fingerprintCertificate: onMac ? fingerprintStoredCertificate : null,
      );
      final width = rows.fold(
        0,
        (w, r) => r.path.length > w ? r.path.length : w,
      );
      for (final row in rows) {
        stdout.writeln(
          '${row.path.padRight(width)}  '
          '${row.state.label.padRight(8)}  ${row.detail}',
        );
      }
      final failed = rows.where((r) => r.state == CheckState.failed).length;
      final opaque = rows.where((r) => r.state == CheckState.opaque).length;
      stdout.writeln();
      stdout.writeln(
        '${rows.length} checked, $failed failed, '
        '$opaque opaque (cannot be authenticated by design).',
      );
      // Only a failure colours the exit code. A token nobody can authenticate
      // is not an error and must not read as one, or the check becomes a thing
      // people learn to ignore.
      if (failed > 0) {
        exitCode = 1;
      }
    } on ProjectException catch (e) {
      stderr.writeln('cux_ship secrets check: ${e.message}');
      exitCode = 1;
    }
  }
}

class _SecretsRemoveCommand extends Command<void> {
  _SecretsRemoveCommand() {
    argParser.addOption(
      'file',
      help: 'The sops-encrypted file to write into.',
      defaultsTo: 'secrets/release.yaml',
    );
  }

  @override
  String get name => 'remove';

  @override
  String get description =>
      'Retire a credential. Hand-editing sops YAML is the same failure class '
      'as adding one that way, and it is what people do under pressure having '
      'just decided something is compromised.';

  @override
  Future<void> run() async {
    final project = _project(this);
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      throw UsageException('usage: secrets remove <kind> <name>', usage);
    }
    final kindName = rest.first;
    final kind = addKinds[kindName];
    if (kind == null) {
      throw UsageException(
        'no such kind: $kindName — there is ${addKindNames.join(', ')}',
        usage,
      );
    }
    if (!kind.singleton && rest.length < 2) {
      throw UsageException('which $kindName?', usage);
    }

    final option = argResults!.option('file')!;
    final secretsFile = File(
      p.isAbsolute(option) ? option : p.join(project.root, option),
    );
    try {
      final removed = await removeCredential(
        repoRoot: project.root,
        secretsFile: secretsFile,
        kindName: kindName,
        instance: kind.singleton ? '' : rest[1],
      );
      stdout.writeln('removed $removed');
    } on ProjectException catch (e) {
      stderr.writeln('cux_ship secrets remove: ${e.message}');
      exitCode = 1;
    }
  }
}

class _SecretsExecCommand extends Command<void> {
  _SecretsExecCommand() {
    argParser
      ..addOption(
        'keystore',
        help:
            'Which Android signing key to use, when the file holds more than '
            'one. With exactly one it is the default and this is not needed.',
      )
      ..addOption(
        'api-key',
        help:
            'Which App Store Connect key to use, when the file holds more '
            'than one — an upload key is scoped to one app, while reading the '
            'developer portal needs an Admin key.',
      );
    argParser
      ..addOption(
        'file',
        help:
            'The sops-encrypted file to decrypt. Relative paths resolve '
            'against the repository root.',
        defaultsTo: 'secrets/release.yaml',
      )
      ..addMultiOption(
        'only',
        help:
            'The credentials this command\'s child consumes, as '
            'family[.instance] — "tokens", "tokens.marks", '
            '"apple.certificates.distribution". Omitted, every credential in '
            'the file is placed, which is this command\'s default because a '
            'general-purpose wrapper that hands over nothing is inert. '
            '(`keychain exec` defaults the other way: it places nothing but '
            'the keychain.)',
      );
  }

  @override
  String get name => 'exec';

  @override
  String get description =>
      'Decrypt the secrets file and run a command with the credentials in its '
      'environment. Nothing else here reads that file: every uploader takes '
      'plain environment variables, so the encryption choice stays swappable.';

  @override
  String get invocation =>
      'cux_ship secrets exec [--file PATH] -- <command> [args...]';

  @override
  Future<void> run() async {
    final project = _project(this);
    final file = argResults!.option('file')!;
    try {
      exitCode = await runSecretsExec(
        repoRoot: project.root,
        secretsFile: File(
          p.isAbsolute(file) ? file : p.join(project.root, file),
        ),
        // Everything after `--`. Kept as rest rather than parsed, so a flag
        // meant for the child is never read as one of ours.
        command: argResults!.rest,
        keystore: argResults!.option('keystore'),
        apiKey: argResults!.option('api-key'),
        only: argResults!.multiOption('only'),
      );
    } on ProjectException catch (e) {
      stderr.writeln('cux_ship secrets exec: ${e.message}');
      exitCode = 1;
    }
  }
}

/// Shared by `place` and `clean`: both read the same file and neither
/// materializes anything.
abstract class _PlacedCommand extends Command<void> {
  _PlacedCommand() {
    argParser.addOption(
      'file',
      help:
          'The sops-encrypted file to decrypt. Relative paths resolve against '
          'the repository root.',
      defaultsTo: 'secrets/release.yaml',
    );
  }

  List<PlacedFile> _files(ProjectContext project) {
    final file = argResults!.option('file')!;
    return placedFiles(
      repoRoot: project.root,
      secretsFile: File(p.isAbsolute(file) ? file : p.join(project.root, file)),
    );
  }
}

class _SecretsPlaceCommand extends _PlacedCommand {
  @override
  String get name => 'place';

  @override
  String get description =>
      'Write the files the build reads from the working tree. Unlike `exec`, '
      'these stay until `clean` removes them — the compiler and the analyzer '
      'read them from fixed paths, so they cannot live for one command.';

  @override
  void run() {
    final project = _project(this);
    try {
      var wrote = 0;
      for (final file in _files(project)) {
        // Every declared target, before the outcome is consulted. The guard is
        // about the *target*, not about this particular write: a file that
        // already matches is the steady state after a normal place, and is
        // exactly when somebody may have `git add -f`ed it. Checking only on
        // the write path means the one state that needs the check never gets
        // it.
        checkPlaceable(project.root, file.at, file.path);
        switch (file.outcomeIn(project.root)) {
          case PlaceOutcome.matching:
            stdout.writeln('  unchanged  ${file.path}');
          case PlaceOutcome.differing:
            // Refused rather than overwritten. These are working source files —
            // somebody edits them in an editor — and the encrypted copy is not
            // automatically the newer one.
            throw ProjectException(
              '${file.path} differs from the encrypted copy.\n'
              'It has been edited since it was placed, and overwriting it '
              'would lose that.\n'
              '    keep it:     cux_ship secrets pack\n'
              '    discard it:  cux_ship secrets clean --discard-local, then '
              'place again',
            );
          case PlaceOutcome.absent:
            place(project.root, file);
            stdout.writeln('  wrote      ${file.path}');
            wrote++;
        }
      }
      if (wrote == 0) {
        stdout.writeln('nothing to write.');
      }
    } on ProjectException catch (e) {
      stderr.writeln('cux_ship secrets place: ${e.message}');
      exitCode = 1;
    }
  }
}

class _SecretsPackCommand extends _PlacedCommand {
  @override
  String get name => 'pack';

  @override
  String get description =>
      'Re-encrypt an edited working copy back into the secrets file. The other '
      'half of `place`: these are source files somebody edits, so the '
      'encrypted copy has to be able to catch up.';

  @override
  Future<void> run() async {
    final project = _project(this);
    final option = argResults!.option('file')!;
    final secretsFile = File(
      p.isAbsolute(option) ? option : p.join(project.root, option),
    );
    try {
      var packed = 0;
      for (final file in _files(project)) {
        switch (await packPlaced(
          repoRoot: project.root,
          secretsFile: secretsFile,
          file: file,
        )) {
          case PackResult.absent:
            stdout.writeln('  not here   ${file.path}');
          case PackResult.unchanged:
            stdout.writeln('  unchanged  ${file.path}');
          case PackResult.packed:
            stdout.writeln('  packed     ${file.path}');
            packed++;
        }
      }
      if (packed == 0) {
        stdout.writeln('nothing to pack.');
      }
    } on ProjectException catch (e) {
      stderr.writeln('cux_ship secrets pack: ${e.message}');
      exitCode = 1;
    }
  }
}

class _SecretsCleanCommand extends _PlacedCommand {
  _SecretsCleanCommand() {
    argParser.addFlag(
      'discard-local',
      negatable: false,
      help:
          'Remove a placed file even when it has been edited since. Named for '
          'what it destroys rather than --force, because that is the only '
          'thing worth knowing before running it.',
    );
  }

  @override
  String get name => 'clean';

  @override
  String get description =>
      'Remove the files `place` wrote. Only removes what still matches the '
      'encrypted copy, so an edit made since is refused rather than lost.';

  @override
  void run() {
    final project = _project(this);
    final discard = argResults!.flag('discard-local');
    try {
      var removed = 0;
      for (final file in _files(project)) {
        if (discard && file.outcomeIn(project.root) == PlaceOutcome.differing) {
          File(p.join(project.root, file.path)).deleteSync();
          stdout.writeln('  discarded  ${file.path}');
          removed++;
          continue;
        }
        if (clean(project.root, file)) {
          stdout.writeln('  removed    ${file.path}');
          removed++;
        }
      }
      if (removed == 0) {
        stdout.writeln('nothing to remove.');
      }
    } on ProjectException catch (e) {
      stderr.writeln('cux_ship secrets clean: ${e.message}');
      exitCode = 1;
    }
  }
}

class _SecretsListCommand extends Command<void> {
  _SecretsListCommand() {
    argParser.addOption(
      'file',
      help:
          'The sops-encrypted file to read. Relative paths resolve against the '
          'repository root.',
      defaultsTo: 'secrets/release.yaml',
    );
  }

  @override
  String get name => 'list';

  @override
  String get description =>
      'List the credential names in the secrets file, and say which are '
      'recognized. Decrypts nothing and needs no identity — a sops file keeps '
      'its keys in cleartext and encrypts only the values.';

  @override
  void run() {
    final project = _project(this);
    final file = argResults!.option('file')!;
    try {
      final keys = inspectSecretKeys(
        File(p.isAbsolute(file) ? file : p.join(project.root, file)),
      );
      // Named before the verdict, so a file with nothing wrong still shows what
      // it holds — the question this answers is usually "what is in here", and
      // only sometimes "is anything broken".
      //
      // Per credential rather than per value: the credential is the thing that
      // is complete or not, and a keystore missing its password is one broken
      // thing rather than three fine values and an absent one.
      for (final credential in keys.credentials) {
        final missing = credential.missing.isEmpty
            ? ''
            : '  — missing ${credential.missing.join(', ')}';
        stdout.writeln(
          '${credential.missing.isEmpty ? '  ' : '! '}${credential.path}'
          '  ${credential.fields.join(', ')}$missing',
        );
      }
      for (final problem in keys.problems) {
        stdout.writeln('! $problem');
      }

      // Half configured counts as broken here, and can: a missing field is a
      // missing *name*, so it is visible without decrypting anything — which
      // makes this the whole pre-flight rather than half of one.
      final broken =
          keys.problems.length +
          keys.credentials.where((c) => c.missing.isNotEmpty).length;
      if (broken == 0) {
        stdout.writeln(
          '\n${keys.credentials.length} credentials, all understood.',
        );
        return;
      }
      // This is what `secrets exec` refuses outright, so reporting it here is
      // the whole point: it runs before a release rather than during one.
      stderr.writeln(
        '\n$broken marked ! above — `secrets exec` will refuse this file.\n'
        'known: ${knownSecretKeys().join('\n       ')}',
      );
      exitCode = 1;
    } on ProjectException catch (e) {
      stderr.writeln('cux_ship secrets list: ${e.message}');
      exitCode = 1;
    }
  }
}

// ---------------------------------------------------------------- keychain

class _KeychainCommand extends Command<void> {
  _KeychainCommand() {
    addSubcommand(_KeychainExecCommand());
  }

  @override
  String get name => 'keychain';

  @override
  String get description =>
      'Apple code signing from a keychain that lives for one command. macOS '
      'only.';
}

class _KeychainExecCommand extends Command<void> {
  _KeychainExecCommand() {
    argParser
      ..addOption(
        'file',
        help:
            'The sops-encrypted file to read the certificate from, when it is '
            'not already in the environment. Relative paths resolve against '
            'the repository root.',
        defaultsTo: 'secrets/release.yaml',
      )
      ..addOption(
        'team',
        help:
            'The Apple team the signing identity must belong to. Defaults to '
            'DEVELOPMENT_TEAM from the Xcode project, so a certificate '
            'belonging to another account is refused here rather than '
            'surfacing later as a profile mismatch.',
      )
      ..addMultiOption(
        'only',
        help:
            'The credentials the child consumes, beyond the keychain itself, '
            'as family[.instance] — "tokens.marks", '
            '"ssh_keys.github_deploy". Omitted, the child gets APPLE_KEYCHAIN '
            'and nothing else: no tokens, no keys, and not the sops identity. '
            'This command wraps a build script, so what that script consumes '
            'is knowledge only the call site has — it happens below this '
            "command's arguments, sometimes several layers down.",
      )
      ..addOption(
        'api-key',
        help:
            'Put an App Store Connect key in the environment. Without this, '
            'none is placed at all — signing needs no key, and a build step '
            'that deliberately holds no App Store credential should not have '
            'to accept one to get a keychain. An absent key also fails loudly '
            'in whatever wanted it, unlike an absent Android keystore, which '
            'is why neither is refused up front here.',
      )
      ..addMultiOption(
        'profile',
        help:
            'A provisioning profile this build needs, by its name in the '
            'secrets file. Repeatable. The secrets file holds every profile '
            'the project has — an App Store one and a Developer ID one, say — '
            'and this command cannot tell which the build is about to use. So '
            'naming them says these matter: a named profile that has expired '
            'stops the build, while one that merely turned up is warned about '
            'and skipped. Without this, nothing is fatal, because failing a '
            'release over a profile it never touches is the error this is '
            'trying to prevent.',
      )
      ..addFlag(
        'strict-expiry',
        negatable: false,
        help:
            'Also refuse a named profile that expires within 30 days. Needs '
            '--profile to have any effect, for the reason above. For a release '
            'run, which should not be the thing that discovers a renewal is '
            'due.',
      );
  }

  @override
  String get name => 'exec';

  @override
  String get description =>
      'Import the signing certificate into a temporary keychain, run a '
      'command with APPLE_KEYCHAIN set, and destroy the keychain however it '
      'ends. The login keychain is never read, so the build signs with the '
      'certificate in the secrets file or it does not build.';

  @override
  String get invocation =>
      'cux_ship keychain exec [--team ID] -- <command> [args...]';

  @override
  Future<void> run() async {
    final project = _project(this);
    final file = argResults!.option('file')!;
    // An ambiguous project must not quietly become an unchecked one. A null
    // expectTeam means "do not check", which is the right meaning when the
    // project names no team and the wrong one when it names several: the check
    // exists to catch a certificate from another account, and silently
    // dropping it is a worse answer than the first-match guess this replaced.
    if (argResults!.option('team') == null &&
        project.developmentTeamProblem != null) {
      throw UsageException(project.developmentTeamProblem!, usage);
    }
    try {
      exitCode = await runKeychainExec(
        repoRoot: project.root,
        secretsFile: File(
          p.isAbsolute(file) ? file : p.join(project.root, file),
        ),
        // Everything after `--`, kept as rest so a flag meant for the child is
        // never read as one of ours.
        command: argResults!.rest,
        expectTeam: argResults!.option('team') ?? project.developmentTeam,
        strictExpiry: argResults!.flag('strict-expiry'),
        only: argResults!.multiOption('only'),
        // Null rather than an empty set when none were named: "install
        // everything, fail on nothing" and "install exactly these" are
        // different instructions, and an empty set is the first.
        profiles: argResults!.multiOption('profile').isEmpty
            ? null
            : argResults!.multiOption('profile').toSet(),
        apiKey: argResults!.option('api-key'),
      );
    } on ProjectException catch (e) {
      stderr.writeln('cux_ship keychain exec: ${e.message}');
      exitCode = 1;
    }
  }
}

// -------------------------------------------------------------------- deps

class _DepsCommand extends Command<void> {
  _DepsCommand() {
    for (final cmd in DepsCommand.values) {
      addSubcommand(_DepsSubcommand(cmd));
    }
  }

  @override
  String get name => 'deps';

  @override
  String get description =>
      'The sops and age binaries the secrets path needs, pinned by hash and '
      'installed into .bin/ at the repository root.';
}

class _DepsSubcommand extends Command<void> {
  _DepsSubcommand(this.cmd) {
    argParser.addOption(
      'bin-dir',
      help:
          'Where to install. Defaults to .bin at the repository root, which is '
          'where `secrets exec` looks first.',
    );
  }

  final DepsCommand cmd;

  @override
  String get name => cmd.name;

  /// `update` re-pins cux_ship's own sources and refuses to run outside a
  /// cux_ship checkout, so to every consuming project it is a documented way
  /// to get an error. Hidden rather than removed: the maintainer still needs
  /// it, and it still works when typed.
  @override
  bool get hidden => cmd == DepsCommand.update;

  @override
  String get description => switch (cmd) {
    DepsCommand.install => 'Install whatever is pinned and .bin/ lacks.',
    DepsCommand.check =>
      'Report what is installed, and exit non-zero if anything is missing.',
    DepsCommand.update =>
      "Re-pin to the latest upstream releases. Rewrites cux_ship's own "
          'deps_pins.dart, so it only works inside a cux_ship checkout — a '
          'project that consumes cux_ship gets new pins by moving its ref.',
  };

  @override
  Future<void> run() async {
    try {
      final binDir =
          argResults!.option('bin-dir') ?? p.join(_project(this).root, '.bin');
      exitCode = await runDeps(cmd, binDir: binDir);
    } on ProjectException catch (e) {
      stderr.writeln('cux_ship deps ${cmd.name}: ${e.message}');
      exitCode = 1;
    }
  }
}

// ------------------------------------------------------------------ verify

/// The version that first required a store block to declare its locales.
///
/// Named in the failure rather than only in the changelog, because the reader's
/// question is not *what is missing* but *why did this work yesterday*. It cost
/// one string and it is the difference between a message that serves somebody
/// who upgraded deliberately and one that serves somebody who did not.
const _storeConfigSince = '3.2.0';

/// What a declared store block has to say, and what a tree has to be there for.
///
/// Two failures, and they are the same failure from opposite ends: a block that
/// declares nothing, and a block that declares a store whose tree is not there.
/// Both are configurations that read as complete and check less than they
/// appear to.
List<ReleaseProblem> _declarationProblems(
  ProjectConfig config,
  ArgResults args,
  String? appstore,
  String? play,
) {
  final problems = <ReleaseProblem>[];
  final overriddenLocales = args.multiOption('require-locale').isNotEmpty;

  void check(String key, StoreConfig? store, String? tree) {
    if (store == null) {
      // A tree nobody declared. It is still checked against everything
      // intrinsic to it — sizes, transparency, text limits — but nothing knows
      // which locales it *should* carry, so the one thing that cannot be
      // inferred is the one thing missing. Reported rather than passed over,
      // because a listing tree with no declaration is how a check ends up
      // green while requiring nothing.
      if (tree != null) {
        problems.add(
          ReleaseProblem(
            '$cuxShipConfigFile: $key',
            'is not declared, and $tree exists — so the tree is checked but '
                'nothing says which locales it must carry, and a locale that '
                'silently stopped being there would not be noticed. Declaring '
                '$key has been required since $_storeConfigSince: add '
                '$key.locales, e.g. locales: [en-US]',
          ),
        );
      }
      return;
    }
    if (store.locales.isEmpty && !overriddenLocales) {
      problems.add(
        ReleaseProblem(
          '$cuxShipConfigFile: $key',
          'declares no locales, so nothing would be required of the listing '
              'and this check would pass without checking. $key.locales is '
              'required since $_storeConfigSince — add the locales this app '
              'publishes, e.g. locales: [en-US]',
        ),
      );
    }
    if (tree == null) {
      problems.add(
        ReleaseProblem(
          '$cuxShipConfigFile: $key',
          'is declared and no metadata tree was found — declaring the block '
              'is what says this project publishes there, so either create the '
              'tree, name it, or remove the block',
        ),
      );
    }
  }

  check('appstore', config.appstore, appstore);
  check('play', config.play, play);
  return problems;
}

/// The locales a listing must carry: the flag when given, the config otherwise.
Set<String> _requiredLocales(ArgResults args, StoreConfig? store) {
  final flag = args.multiOption('require-locale').toSet();
  return flag.isNotEmpty ? flag : (store?.locales ?? const {});
}

/// The screenshot types an **App Store** listing must carry.
///
/// Precedence is the tool's usual one — flag, then file, then inference — and
/// the inference step is what makes this work with nothing declared.
///
/// **`--require-screenshot-type` is App Store only, and deliberately.** Its
/// values are `ScreenshotDisplayType` names; Play's are directory names like
/// `phoneScreenshots`, and the two vocabularies are disjoint. One unscoped flag
/// feeding both checks meant the flag's own documented example —
/// `--require-screenshot-type APP_IPAD_PRO_3GEN_129` — made the Play check
/// demand a directory by that name and fail. Play's requirements come from
/// `play.screenshots` only.
Set<String> _appStoreScreenshotTypes(
  ArgResults args,
  StoreConfig? store,
  ProjectContext project, {
  String platform = 'ios',
}) {
  final flag = args.multiOption('require-screenshot-type').toSet();
  if (flag.isNotEmpty) {
    return flag;
  }
  final declared = store?.screenshotsFor(platform) ?? const <String>{};
  if (declared.isNotEmpty) {
    return declared;
  }
  return project.requiredScreenshotTypes(platform) ?? const {};
}

/// Why the App Store screenshot requirement could not be derived, when nothing
/// declared it either.
///
/// Without this the refusal built into [ProjectContext] is dead: an ambiguous
/// project yields no derived set, the caller falls back to requiring nothing,
/// and a carefully worded problem string is set and never read. Requiring
/// nothing *silently* is the shape this release exists to remove, so the
/// inability to derive is itself reported.
///
/// [flagTypes] is what `--require-screenshot-type` supplied, or empty when the
/// caller has no such flag. **Taken as a value rather than read out of
/// [ArgResults], because only the caller knows its own parser.** Reading it
/// here crashed every `appstore` subcommand in 3.2.0: the option is declared on
/// `verify` alone, this function was wired into the upload path as well, and
/// `multiOption` throws `Invalid argument(s): Could not find an option named
/// "--require-screenshot-type"` before the command does anything.
///
/// The guard-shaped fix — ask whether the option exists, then read it — would
/// have worked and left the same trap for the next helper shared across two
/// parsers. A parameter makes the question unaskable.
ReleaseProblem? _derivationProblem(
  Set<String> flagTypes,
  StoreConfig? store,
  ProjectContext project, {
  String platform = 'ios',
}) {
  if (flagTypes.isNotEmpty) {
    return null;
  }
  if ((store?.screenshotsFor(platform) ?? const <String>{}).isNotEmpty) {
    return null;
  }
  final problem = project.targetedDeviceFamilyProblem;
  if (problem == null || project.requiredScreenshotTypes(platform) != null) {
    return null;
  }
  return ReleaseProblem('appstore.screenshots.$platform', problem);
}

/// The offline checks, against a consuming repository's own files.
///
/// Public because it is useful on its own: a project with no store credentials
/// and no artifact can still run this on every push, which is the whole point
/// of it.
class VerifyCommand extends Command<void> {
  VerifyCommand() {
    argParser
      // Both default to what the project has, found from the repository root
      // rather than the working directory — a literal 'CHANGELOG.md' default
      // would resolve against wherever this was invoked from, which for every
      // consumer is the package that pins it rather than the repository.
      ..addOption(
        'changelog',
        valueHelp: 'path',
        help:
            'CHANGELOG.md to check every version section of. Defaults to the '
            "repository's, so plain `cux_ship verify` already checks it.",
      )
      ..addOption(
        'appstore',
        valueHelp: 'path',
        help:
            'One App Store metadata tree to validate, instead of the ones '
            'found. Defaults to store/appstore/<platform> when the tree is '
            'split per platform and store/appstore when it is flat — both '
            'trees are checked, so this is for a tree kept somewhere else.',
      )
      ..addOption(
        'platform',
        allowed: ascPlatforms,
        help:
            'Which App Store platform to check, and which platform --appstore '
            'names. Chooses among appstore.screenshots. Omit it to check every '
            'tree the repository has; required alongside --appstore when two '
            'platforms are declared, because one path cannot say which it is.',
      )
      ..addOption(
        'play',
        valueHelp: 'path',
        help:
            'Play metadata tree to validate. Defaults to store/play when '
            '.cux-ship.yaml declares a play: block.',
      )
      ..addOption(
        'data-safety',
        valueHelp: 'path',
        help:
            "Play's data safety CSV. Defaults to store/play/data-safety.csv. "
            'Checked for structure, never for whether the answers are true.',
      )
      ..addMultiOption(
        'require-screenshot-type',
        help:
            'A ScreenshotDisplayType the listing must carry, e.g. '
            'APP_IPAD_PRO_3GEN_129. Overrides what the Xcode project implies. '
            'Normally unnecessary: TARGETED_DEVICE_FAMILY says whether an iPad '
            'set is required, and Apple refuses the submission rather than the '
            'upload.',
      )
      ..addMultiOption(
        'require-locale',
        help:
            'A locale the listing must carry, e.g. en-US. Overrides '
            'appstore.locales and play.locales.',
      );
  }

  @override
  String get name => 'verify';

  @override
  String get description =>
      'Check release inputs offline: release-note length, screenshot sizes and '
      'transparency, required locales. No network, no credentials.';

  @override
  void run() {
    final args = argResults!;
    final project = _project(this);
    final config = ProjectConfig.read(project.root);
    final changelog = args.option('changelog') ?? project.changelog;

    // **Declaring the block is what says a project publishes to a store**, and
    // it is what the *requirements* hang off — which locales, which screenshot
    // types. It is deliberately not what decides whether a tree is looked at.
    //
    // A tree that is present is checked against the rules intrinsic to it
    // whether or not anybody declared it, because an upgrade that silently
    // checks less than the version before it is the failure this change exists
    // to remove, committed on the way in. An undeclared tree is reported, and
    // a declared one additionally has to satisfy what it declared.
    final play = args.option('play') ?? project.playMetadata;
    final dataSafety = args.option('data-safety') ?? project.dataSafety;

    // **Which platform's requirements each App Store tree is checked against.**
    //
    // A path carries no platform, so without this there is nothing for
    // `appstore.screenshots.macos` to be selected *by* — and an earlier
    // revision silently applied `ios:` to every tree, failing a macOS listing
    // Apple holds for lacking iPhone screenshots. A declared requirement
    // enforcing the *other* platform's rules is worse than one enforcing none.
    //
    // What changed is where the platform comes from when nobody says. It used
    // to be a refusal — "pass --platform to say which tree this is" — and that
    // was right while `--appstore` was the only way to reach a tree, because
    // one path genuinely cannot be two platforms. It is wrong when the paths
    // are *derived*, because `store/appstore/macos` is not ambiguous about
    // which platform it holds. So a repository with a split layout gets every
    // tree checked, each against its own rules, in one run.
    //
    // The refusal survives for `--appstore`, which is still one path.
    final platform = args.option('platform');
    final named = args.option('appstore');
    final Map<String, String> appStoreTrees;
    if (named != null) {
      final declaredPlatforms =
          config.appstore?.screenshots.keys.toSet() ?? const <String>{};
      if (platform == null && declaredPlatforms.length > 1) {
        stderr.writeln(
          'cux_ship verify: $cuxShipConfigFile declares appstore.screenshots '
          'for ${(declaredPlatforms.toList()..sort()).join(' and ')}, and '
          '--appstore names one tree — pass --platform to say which of them '
          'it is, or the wrong platform\'s requirements would be applied.',
        );
        exitCode = 1;
        return;
      }
      appStoreTrees = {platform ?? 'ios': named};
    } else {
      appStoreTrees = project.appStoreTrees(platform: platform);
    }

    final problems = <ReleaseProblem>[
      ..._declarationProblems(
        config,
        args,
        appStoreTrees.isEmpty ? null : appStoreTrees.values.first,
        play,
      ),
      if (changelog != null) ...checkChangelogFile(changelog),
      for (final MapEntry(key: platform, value: tree)
          in appStoreTrees.entries) ...[
        ?_derivationProblem(
          args.multiOption('require-screenshot-type').toSet(),
          config.appstore,
          project,
          platform: platform,
        ),
        ...checkAppStoreTree(
          tree,
          requireScreenshotTypes: _appStoreScreenshotTypes(
            args,
            config.appstore,
            project,
            platform: platform,
          ),
          requireLocales: _requiredLocales(args, config.appstore),
        ),
      ],
      if (play != null)
        ...checkPlayTree(
          play,
          // Play's own vocabulary, from the config only — see
          // _appStoreScreenshotTypes for why the flag does not reach here.
          requireScreenshotTypes:
              config.play?.screenshotsFor(StoreConfig.anyPlatform) ?? const {},
          requireLocales: _requiredLocales(args, config.play),
        ),
      if (dataSafety != null) ...checkDataSafetyFile(dataSafety),
    ];

    // Refused rather than passed: checking nothing and reporting success is the
    // failure this command exists to prevent, so having nothing to check is
    // itself the finding.
    if (changelog == null &&
        appStoreTrees.isEmpty &&
        play == null &&
        dataSafety == null) {
      stderr.writeln(
        'cux_ship verify: nothing to check — no CHANGELOG.md, no App Store or '
        'Play metadata tree, and no data safety declaration were found, and '
        'none was named. Name one with --changelog, --appstore, --play or '
        '--data-safety.',
      );
      exitCode = 1;
      return;
    }

    // **What was checked, named, on the way past.**
    //
    // A clean run used to print one line, so a reader could not tell whether
    // the data safety declaration had been validated or silently skipped —
    // they had to suspect it and go looking. That is the failure this release
    // exists to close, on the success path: absence of output reading as
    // coverage. Every artifact says so itself.
    for (final line in [
      if (changelog != null) 'changelog  $changelog',
      for (final tree in appStoreTrees.entries) ...[
        'appstore   ${tree.value} (${tree.key})',
      ],
      if (play != null) 'play       $play',
      if (dataSafety != null) 'data safe  $dataSafety',
    ]) {
      stdout.writeln('    checked $line');
    }

    if (problems.isEmpty) {
      stdout.writeln('==> release inputs are publishable');
      return;
    }
    // Every problem at once. Reported one at a time, the second is found only
    // after the first is fixed and pushed.
    stderr.writeln('cux_ship verify: ${problems.length} problem(s)');
    for (final problem in problems) {
      stderr.writeln('  $problem');
    }
    exitCode = 1;
  }
}
