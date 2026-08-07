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
import 'package:cux_ship_appstore/cli.dart';
import 'package:cux_ship_appstore/flatten_cli.dart';
import 'package:cux_ship_play/cli.dart';
import 'package:cux_ship_verify/cux_ship_verify.dart';

import 'src/confirm.dart';
import 'src/project.dart';
import 'src/release.dart';

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
  runner.argParser.addFlag(
    'yes',
    abbr: 'y',
    negatable: false,
    help:
        'Do not ask before publishing. Required in CI, where there is no '
        'terminal to ask at.',
  );
  return runner
    ..addCommand(_AppstoreCommand())
    ..addCommand(_PlayCommand())
    ..addCommand(_ReleaseCommand())
    ..addCommand(_ScreenshotsCommand())
    ..addCommand(VerifyCommand());
}

/// The `--yes` flag, read off the top-level results a subcommand can reach.
bool _assumeYes(Command<void> command) =>
    command.globalResults?.flag('yes') ?? false;

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
  };

  @override
  Future<void> run() {
    final project = ProjectContext.read();
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
    final project = ProjectContext.read();
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

      final commit = args.option('commit') ?? git.run(['rev-parse', 'HEAD']);

      // Read off the released commit rather than the working tree: the tree
      // may already have moved on, and the version that was published is a
      // property of what was published.
      final version =
          args.option('version') ??
          pubspecVersion(git.run(['show', '$commit:pubspec.yaml'])) ??
          (throw ReleaseException(
            'no version in pubspec.yaml at $commit — pass --version',
          ));

      final log = finishRelease(
        git,
        FinishOptions(
          commit: commit,
          version: version,
          buildNumber: args.option('build-number'),
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

// ------------------------------------------------------------------ verify

/// The offline checks, against a consuming repository's own files.
///
/// Public because it is useful on its own: a project with no store credentials
/// and no artifact can still run this on every push, which is the whole point
/// of it.
class VerifyCommand extends Command<void> {
  VerifyCommand() {
    argParser
      ..addOption(
        'changelog',
        defaultsTo: 'CHANGELOG.md',
        help: 'CHANGELOG.md to check every version section of.',
      )
      ..addOption(
        'appstore',
        help:
            'App Store metadata tree to validate. Skipped when not given, '
            'because a project may have no Apple listing.',
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
    final problems = <ReleaseProblem>[
      ...checkChangelogFile(args.option('changelog')!),
      if (args.option('appstore') case final tree?)
        ...checkAppStoreTree(
          tree,
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
