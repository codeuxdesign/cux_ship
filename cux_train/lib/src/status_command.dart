/// `status`: read the records, render the grid, write nothing.
///
/// **The first verb wired to the library, and the only one that spends
/// nothing.** It can still be wrong — a grid can misreport — but it cannot cost
/// anything. §3 of `docs/design/authpass-on-the-train.md` defines it as "reads,
/// writes nothing", which is what makes it the right one to land first: every
/// other verb in the plan spends something — a push, a console submission, the
/// version tag — and none of them can be exercised against a real repository
/// until the thing that *reports* state is trustworthy.
///
/// **What this file is allowed to decide.** The grid, the evidence model and
/// the ledger all refuse to guess: `StatusGrid.of` will not invent a version,
/// `PromotionLedger.forBuild` will not infer a build, and
/// `DestinationTable.parse` deliberately has no opinion about which file it was
/// handed. Those are the right defaults for a library, and they leave exactly
/// three decisions for a command line to make — where the table is, which
/// release this is, and which build. This file makes the first and refuses the
/// other two, which is the same discipline one layer up.
library;

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cux_ship/provenance.dart' show Git;
import 'package:path/path.dart' as p;

import 'destinations.dart';
import 'promotion_ledger.dart';
import 'promotion_record.dart';
import 'status_grid.dart';

/// The default name of the file the destination table lives in.
///
/// **A sibling file, and §4 settles that it stays one for now.** The natural
/// home is a `train:` block in `.cux-ship.yaml`, beside the `tag` config whose
/// namespace the records must agree with — but `cux_ship`'s `_checkKeys`
/// *throws* on an unknown key, and it is read before every command, so a
/// `train:` block would fail every upload in a consumer's CI until the release
/// that learns the word. That release does not exist yet and may never be cut,
/// which §4 records as "a tolerable end state rather than a broken one".
const String defaultTableFile = '.cux-train.yaml';

/// Prints the evidence grid for one release candidate.
class StatusCommand extends Command<void> {
  StatusCommand({
    StringSink? output,
    String? root,
    Git Function(String)? openGit,
  }) : _output = output ?? stdout,
       _root = root ?? Directory.current.path,
       _openGit = openGit ?? Git.new {
    argParser
      ..addOption(
        'build',
        valueHelp: 'N',
        help:
            'The build this run is about. Required: the candidate is named, '
            'never guessed.',
      )
      ..addOption(
        'release',
        valueHelp: 'X.Y.Z',
        help:
            'The release the grid is about. Required, for the same reason as '
            '--build.',
      )
      ..addOption(
        'table',
        valueHelp: 'PATH',
        defaultsTo: defaultTableFile,
        help: 'The destination table to read.',
      );
  }

  final StringSink _output;
  final String _root;
  final Git Function(String) _openGit;

  /// What `--build` may be spelled as: decimal, optionally signed.
  static final _digits = RegExp(r'^-?[0-9]+$');

  @override
  String get name => 'status';

  @override
  String get description =>
      'Print the evidence grid for one release candidate. Reads only.';

  @override
  void run() {
    // **A word after the flags is refused, because `package:args` would
    // otherwise drop it.** A leaf command is handed its positional arguments
    // and nothing checks that it read them, so `status --build N --release V
    // production` printed the whole grid and exited 0 with `production`
    // ignored — the "flag that would do nothing" the plan refuses, in the one
    // spelling the parser does not refuse for us.
    final stray = argResults!.rest;
    if (stray.isNotEmpty) {
      usageException(
        'status takes no arguments besides its flags, and was given '
        '`${stray.join(' ')}`.',
      );
    }

    final table = _table();
    final build = _build();
    final release = _release();

    final grid = StatusGrid.of(
      table: table,
      ledger: PromotionLedger.forBuild(
        promotionRefs(_openGit(_root)),
        build: build,
        // **Both halves, so that `--release` is checked rather than printed.**
        // The ledger used to be keyed on the build alone, which made this flag
        // a label: a record for build 2196 of 1.9.13 was reported under
        // whatever version the operator typed, and the grid's header — the one
        // line that says which release the numbers belong to — was the part
        // nothing verified.
        version: release,
        source: 'git tag',
      ),
      version: release,
      candidate: build,
    );

    _output.write(grid.render());
  }

  DestinationTable _table() {
    final path = argResults!['table'] as String;
    // **Resolved against the same root the refs are read from.** The table
    // declares the destinations and the refs record what happened at them, so
    // a run that took those two from different places would report one
    // repository's progress against another's list of destinations — and
    // nothing in the output would say so. Ordinarily they are the same
    // directory, because the launcher sits at the repository root; the two
    // only come apart when a caller passes a root, which is exactly when
    // getting it wrong would be silent.
    //
    // **The root is a directory, not the repository's top level.** Git walks
    // upwards from it and this does not, so from a subdirectory the refs are
    // found and the default table is not. That fails by name, below, rather
    // than silently — unless the subdirectory holds a table of its own.
    final resolved = p.isAbsolute(path) ? path : p.join(_root, path);
    if (Directory(resolved).existsSync()) {
      // `File.existsSync` is false for a directory, so without this the
      // message below would tell the operator to write a file where a
      // directory already is.
      throw DestinationTableException(
        '$path is a directory, and the destination table is a file. Name the '
        'file with --table.',
      );
    }
    final file = File(resolved);
    if (!file.existsSync()) {
      // **Named as a table problem rather than as a usage error**, because the
      // path is usually right and the file is usually missing: the default is
      // a file the consumer has to write, and on the day the train is first
      // run in a repository it does not exist yet. A 64 here would tell an
      // operator they typed the command wrong when they did not.
      throw DestinationTableException(
        '$path does not exist. The destination table is the one thing the '
        'train cannot work out for itself — it is the list of places a '
        'release goes. Write it there, or name another file with --table.',
      );
    }
    final String yaml;
    try {
      yaml = file.readAsStringSync();
    } on FileSystemException catch (error) {
      // A file that exists and cannot be read — no permission, or bytes that
      // are not UTF-8. `cli.dart` maps the table's exception onto a sentence
      // and knows nothing about `dart:io`'s, so it is translated here.
      throw DestinationTableException(
        '$path could not be read: ${error.message}',
      );
    }
    return DestinationTable.parse(yaml, source: path);
  }

  int _build() {
    final declared = argResults!['build'] as String?;
    if (declared == null) {
      // **The refusal names what will replace it.** §3 gives the candidate two
      // sources — `--build N`, or the number `refs/buildnumbers` allocated for
      // the tip of `stable` — and expressly not the newest `uploaded/` tag,
      // which §2 shows is routinely a pull request's. The second source is not
      // wired yet, so the flag is required; saying so here is what stops the
      // next reader from assuming the omission is the design.
      usageException(
        'status needs the build it is about: --build N. The grid is keyed by '
        'version and every cell in it is a build number, so a grid built for '
        'no particular build would name numbers nothing could be compared '
        'against. (Reading it from `refs/buildnumbers` for the tip of '
        '`stable`, which the plan also allows, is not wired yet.)',
      );
    }
    // **The digits are checked before they are parsed**, for the reason
    // `PromotionRecord.parse` gives: `int.tryParse` reads `0x10` as sixteen,
    // and a grid for build 16 is not what anybody who typed that meant. The
    // sign and a zero are let through on purpose — the grid refuses a build
    // below 1 itself, and narrowing them here would make that guard
    // unreachable from the command line.
    final build = _digits.hasMatch(declared) ? int.tryParse(declared) : null;
    if (build == null) {
      usageException('--build must be a number, and `$declared` is not one.');
    }
    return build;
  }

  String _release() {
    final declared = argResults!['release'] as String?;
    if (declared == null || declared.trim().isEmpty) {
      usageException(
        'status needs the release it is about: --release X.Y.Z. A build '
        'number does not say which release it belongs to — one version is two '
        'dozen builds — so a grid without it is a page of numbers nobody can '
        'file. (It is not read from the `uploaded/` tag for the build, '
        'because that tag\'s name is the consumer\'s convention rather than '
        'this package\'s to parse.)',
      );
    }
    return declared;
  }
}

/// Every promotion ref in the repository [git] is open on, without `refs/tags/`.
///
/// **The patterns come from [PromotionOutcome], never from two string literals
/// here.** The ledger insists that every ref it is handed parses, and it counts
/// what the finish rule waits on — so a namespace this function forgets to ask
/// for is not a missing row in a report, it is a destination the finish rule
/// stops waiting on. A third outcome added to that enum has to reach this call
/// without anybody remembering to come here, which is why the list is derived
/// rather than written out.
List<String> promotionRefs(Git git) {
  final patterns = [
    for (final namespace in PromotionOutcome.namespaces) '$namespace/*',
  ];
  final listed = git.run(['tag', '-l', ...patterns]);
  return [
    for (final line in listed.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];
}
