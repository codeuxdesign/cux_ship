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

import 'src/appstore/cli.dart';
import 'src/appstore/flatten_cli.dart';
import 'src/confirm.dart';
import 'src/deps.dart';
import 'src/keychain.dart';
import 'src/placed.dart';
import 'src/play/cli.dart';
import 'src/project.dart';
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
    ..addCommand(_ScreenshotsCommand())
    ..addCommand(_SecretsCommand())
    ..addCommand(_KeychainCommand())
    ..addCommand(_DepsCommand())
    ..addCommand(VerifyCommand());
}

/// The `--yes` flag, read off the top-level results a subcommand can reach.
bool _assumeYes(Command<void> command) =>
    command.globalResults?.flag('yes') ?? false;

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
    return runAsc(
      cmd,
      argResults!,
      defaults: AscDefaults(
        bundleId: project.bundleIdFor(platform),
        versionName: project.versionName,
        changelog: project.changelog,
        metadata: project.appStoreMetadata,
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
    return runPlay(
      cmd,
      argResults!,
      defaults: PlayDefaults(
        packageName: project.androidPackage,
        versionName: project.versionName,
        changelog: project.changelog,
        metadata: project.playMetadata,
        dataSafety: project.dataSafety,
      ),
      confirm: (summary) => confirmOrExit(summary, assumeYes: _assumeYes(this)),
    );
  }
}

// ----------------------------------------------------------------- release

class _ReleaseCommand extends Command<void> {
  _ReleaseCommand() {
    addSubcommand(_FinishCommand());
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
      final version =
          args.option('version') ??
          pubspecVersion(git.run(['show', '$commit:$pubspecPath'])) ??
          (throw ReleaseException(
            'no version in $pubspecPath at $commit — pass --version',
          ));

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

    try {
      final secret = _readSecretInput(
        passwordFile: argResults!.option('password-file'),
        valueFile: argResults!.option('value-file'),
        needed: kind.needsSecretInput,
      );
      final result = await addCredential(
        repoRoot: project.root,
        secretsFile: secretsFile,
        kindName: kindName,
        instance: instance,
        filePath: fileArg,
        env: argResults!.option('env'),
        issuerId: argResults!.option('issuer-id'),
        password: secret,
        replace: argResults!.flag('replace'),
        describeProfile: describeProfileForAdd,
      );
      stdout.writeln(
        '${result.replaced ? 'replaced' : 'added'} ${result.path}  '
        '(${result.fields.join(', ')})',
      );
      for (final note in result.notes) {
        stdout.writeln('  $note');
      }
    } on ProjectException catch (e) {
      stderr.writeln('cux_ship secrets add: ${e.message}');
      exitCode = 1;
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
    argParser.addOption(
      'file',
      help:
          'The sops-encrypted file to decrypt. Relative paths resolve against '
          'the repository root.',
      defaultsTo: 'secrets/release.yaml',
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
      stderr.writeln('cux_ship secrets keys: ${e.message}');
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
        help:
            'CHANGELOG.md to check every version section of. Defaults to the '
            "repository's, when it has one.",
      )
      ..addOption(
        'appstore',
        help:
            'App Store metadata tree to validate. Defaults to store/appstore '
            'when the project has one, and is skipped when it does not.',
      )
      ..addMultiOption(
        'require-screenshot-type',
        help:
            'A ScreenshotDisplayType the listing must carry, e.g. '
            'APP_IPAD_PRO_3GEN_129. A universal app needs an iPad set as well '
            'as an iPhone one, and Apple refuses the submission rather than '
            'the upload.',
      )
      ..addMultiOption(
        'require-locale',
        help: 'A locale the listing must carry, e.g. en-US.',
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
    final changelog = args.option('changelog') ?? project.changelog;
    final appstore = args.option('appstore') ?? project.appStoreMetadata;

    // Refused rather than passed: checking nothing and reporting success is the
    // failure this command exists to prevent, so having nothing to check is
    // itself the finding.
    if (changelog == null && appstore == null) {
      stderr.writeln(
        'cux_ship verify: nothing to check — no CHANGELOG.md and no App Store '
        'metadata tree were found, and neither was named.',
      );
      exitCode = 1;
      return;
    }

    final problems = <ReleaseProblem>[
      if (changelog != null) ...checkChangelogFile(changelog),
      if (appstore != null)
        ...checkAppStoreTree(
          appstore,
          requireScreenshotTypes: args
              .multiOption('require-screenshot-type')
              .toSet(),
          requireLocales: args.multiOption('require-locale').toSet(),
        ),
    ];

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
