/// What every verb about one release candidate has to do before it can start.
///
/// **Extracted on the second verb rather than the first, which is the right
/// time.** `status` needed a table, a build and a release; so does `ready`, and
/// so will `production`. One of those three is not plumbing: the ledger is
/// keyed on the build *and* the version, and it is keyed on the version because
/// a previous commit found that `--release` was a label nothing checked. A verb
/// that built its own ledger and passed only the build would reopen that hole
/// quietly — the grid would render, the numbers would be real, and the header
/// would name a release nothing had verified. [ledgerFor] is the one call, so
/// there is one place for that to be right.
///
/// **It is a base class and not a mixin**, because the three options have to be
/// declared in a constructor body: `Command.argParser` is built before the
/// subclass's constructor runs, and a mixin cannot reach it at the moment the
/// parser is still empty.
library;

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cux_ship/provenance.dart' show Git;
import 'package:path/path.dart' as p;

import 'destinations.dart';
import 'promotion_ledger.dart';
import 'promotion_record.dart';

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

/// A verb that is about one build of one release.
///
/// Subclasses implement [Command.run] and call [refuseStrayArguments],
/// [readTable], [candidateBuild], [candidateRelease] and [ledgerFor]; nothing
/// here writes to [output] or decides an exit code.
abstract class CandidateCommand extends Command<void> {
  CandidateCommand({
    StringSink? output,
    String? root,
    Git Function(String)? openGit,
  }) : output = output ?? stdout,
       root = root ?? Directory.current.path,
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
            'The release this run is about. Required, for the same reason as '
            '--build.',
      )
      ..addOption(
        'table',
        valueHelp: 'PATH',
        defaultsTo: defaultTableFile,
        help: 'The destination table to read.',
      );
  }

  /// Where this verb's result goes. A test passes a buffer.
  final StringSink output;

  /// The directory the table is resolved against and the refs are read from.
  final String root;

  final Git Function(String) _openGit;

  /// What `--build` may be spelled as: decimal, optionally signed.
  static final _digits = RegExp(r'^-?[0-9]+$');

  /// Refuses a word after the flags, because `package:args` would drop it.
  ///
  /// A leaf command is handed its positional arguments and nothing checks that
  /// it read them, so `status --build N --release V production` printed the
  /// whole grid and exited 0 with `production` ignored — the "flag that would
  /// do nothing" the plan refuses, in the one spelling the parser does not
  /// refuse for us. It matters more on a verb that acts than it did on
  /// `status`: a dropped `--store`-shaped word reads as a narrowed run.
  void refuseStrayArguments() {
    final stray = argResults!.rest;
    if (stray.isNotEmpty) {
      usageException(
        '$name takes no arguments besides its flags, and was given '
        '`${stray.join(' ')}`.',
      );
    }
  }

  /// The destination table named by `--table`, parsed.
  DestinationTable readTable() {
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
    final resolved = p.isAbsolute(path) ? path : p.join(root, path);
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

  /// The build named by `--build`.
  int candidateBuild() {
    final declared = argResults!['build'] as String?;
    if (declared == null) {
      // **The refusal names what will replace it.** §3 gives the candidate two
      // sources — `--build N`, or the number `refs/buildnumbers` allocated for
      // the tip of `stable` — and expressly not the newest `uploaded/` tag,
      // which §2 shows is routinely a pull request's. The second source is not
      // wired yet, so the flag is required; saying so here is what stops the
      // next reader from assuming the omission is the design.
      usageException(
        '$name needs the build it is about: --build N. A release is keyed by '
        'version and every number under it is a build, so a run for no '
        'particular build would name numbers nothing could be compared '
        'against. (Reading it from `refs/buildnumbers` for the tip of '
        '`stable`, which the plan also allows, is not wired yet.)',
      );
    }
    // **The digits are checked before they are parsed**, for the reason
    // `PromotionRecord.parse` gives: `int.tryParse` reads `0x10` as sixteen,
    // and a run for build 16 is not what anybody who typed that meant. The
    // sign and a zero are let through on purpose — what consumes the number
    // refuses a build below 1 itself, and narrowing them here would make that
    // guard unreachable from the command line.
    final build = _digits.hasMatch(declared) ? int.tryParse(declared) : null;
    if (build == null) {
      usageException('--build must be a number, and `$declared` is not one.');
    }
    return build;
  }

  /// The release named by `--release`.
  String candidateRelease() {
    final declared = argResults!['release'] as String?;
    if (declared == null || declared.trim().isEmpty) {
      usageException(
        '$name needs the release it is about: --release X.Y.Z. A build '
        'number does not say which release it belongs to — one version is two '
        'dozen builds — so an answer without it is a page of numbers nobody '
        'can file. (It is not read from the `uploaded/` tag for the build, '
        'because that tag\'s name is the consumer\'s convention rather than '
        'this package\'s to parse.)',
      );
    }
    return declared;
  }

  /// Every promotion record for [build] of [version], read from [root].
  ///
  /// **Both halves, so that `--release` is checked rather than printed.** The
  /// ledger used to be keyed on the build alone, which made that flag a label:
  /// a record for build 2196 of 1.9.13 was reported under whatever version the
  /// operator typed, and the one line that says which release the numbers
  /// belong to was the part nothing verified. It is one call here because a
  /// second verb reaching for `PromotionLedger.forBuild` itself is how that
  /// comes back.
  PromotionLedger ledgerFor({required int build, required String version}) =>
      PromotionLedger.forBuild(
        promotionRefs(_openGit(root)),
        build: build,
        version: version,
        source: 'git tag',
      );
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
