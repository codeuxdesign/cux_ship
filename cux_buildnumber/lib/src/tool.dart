/// The tool itself: the command surface of git-buildnumber.sh v1.3, driving
/// `git` as a subprocess. All argument lists come from `git_args.dart` and all
/// arithmetic from `logic.dart`; this file holds only sequencing and I/O.
///
/// **The consumers do not read refs — they run the tool and parse stdout**, so
/// the stdout of every command below is a compatibility contract:
/// `generate` prints a bare integer and nothing else; `find-commit` prints a
/// `git log` block a consumer greps `^commit <sha>` out of; `get` exits 0 with
/// empty stdout on an unnumbered commit; `push` and `sync` print nothing at
/// all. Everything else goes to stderr.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'git_args.dart';
import 'logic.dart';

/// The version of the shell script this port tracks.
const gitBuildNumberVersion = '1.3';

const _red = '\x1b[1;91m';
const _yellow = '\x1b[33m';
const _blue = '\x1b[34m';
const _dim = '\x1b[02m';
const _reset = '\x1b[0m';

/// A failure with a user-facing message — the port of the script's `fail`.
/// Always exits 1.
class ToolFailure implements Exception {
  ToolFailure(this.message);

  final String message;
}

/// A git invocation the script would have aborted on (`set -e`), carrying the
/// child's exit code.
class GitFailure implements Exception {
  GitFailure(this.exitCode, this.command);

  final int exitCode;
  final String command;
}

class _GitResult {
  _GitResult(this.exitCode, this.stdoutBytes, this.stderrText);

  final int exitCode;
  final List<int> stdoutBytes;
  final String stderrText;

  String get stdoutText =>
      const Utf8Decoder(allowMalformed: true).convert(stdoutBytes);

  String get trimmed => stdoutText.trim();
}

/// Dart's [Process.exitCode] reports a signal death as `-signal`; the shell
/// reports it as `128 + signal`, and the exit-code contract is the shell's.
int _shellExitCode(int code) => code < 0 ? 128 - code : code;

/// Runs the tool and returns the process exit code.
Future<int> runGitBuildNumber(
  List<String> args, {
  Map<String, String>? environment,
}) async {
  final tool = BuildNumberTool(
    environment: environment ?? Platform.environment,
  );
  var code = 0;
  try {
    code = await tool.dispatch(args);
  } on ToolFailure catch (failure) {
    stderr.writeln('${_red}FAIL: ${failure.message} $_reset');
    code = 1;
  } on GitFailure catch (failure) {
    final rc = _shellExitCode(failure.exitCode);
    stderr.writeln(
      '$_red  FATAL Exiting with error ($rc): '
      '${failure.command}$_reset',
    );
    code = rc == 0 ? 1 : rc;
  }
  try {
    await stdout.flush();
    await stderr.flush();
  } on Object catch (_) {
    // A closed pipe downstream is the reader's business, not a failure here.
  }
  return code;
}

class BuildNumberTool {
  BuildNumberTool({required Map<String, String> environment})
    : _env = environment {
    final remote = _envOr('GIT_REMOTE', 'origin');
    pushRemote = _envOr('GIT_PUSH_REMOTE', remote);
    fetchRemote = _envOr('GIT_FETCH_REMOTE', remote);
    ignoreRepositoryState = _envOr('IGNORE_REPOSITORY_STATE', '0');
    diffIndexRawArgs = _envOr('DIFF_INDEX_ARGS', '--ignore-space-at-eol');
    maxAttempts = int.tryParse(_envOr('MAX_ATTEMPTS', '10')) ?? 10;
    verbose = _env['VERBOSE'] == 'true';
  }

  final Map<String, String> _env;
  late final String pushRemote;
  late final String fetchRemote;
  late final String ignoreRepositoryState;
  late final String diffIndexRawArgs;
  late final int maxAttempts;
  late final bool verbose;

  ObservedRefs _observed = noObservedRefs;

  /// Whether a fetch has run in this process. Separate from the observed
  /// values, because "no value observed" is the legitimate first-run state —
  /// the refs do not exist on the remote yet — and is indistinguishable from
  /// "never looked" if the values alone are consulted. Getting that wrong
  /// makes the push lease against what this process just wrote, which every
  /// remote then fails.
  bool _fetched = false;

  String _remoteRefsOutput = '';

  /// The shell's `${VAR:-default}`: empty counts as unset.
  String _envOr(String key, String fallback) {
    final value = _env[key];
    if (value == null || value.isEmpty) {
      return fallback;
    }
    return value;
  }

  Future<int> dispatch(List<String> args) async {
    final command = args.isEmpty ? 'generate' : args.first;
    switch (command) {
      case 'generate':
        final number = await _generateOrGet();
        stdout.writeln(number);
        return 0;
      case 'fetch':
        await _fetch();
        return 0;
      case 'push':
        await _push();
        return 0;
      case 'sync':
        // Push first: the fetch force-updates the local refs from the remote,
        // so fetching first makes the push a no-op by construction and `sync`
        // silently becomes `fetch`. Publish what is here, then take what is
        // there.
        await _push();
        await _fetch();
        return 0;
      case 'get':
        await _fetch();
        final number = await _existingBuildNumber();
        if (number != null) {
          stdout.writeln(number);
        }
        // Exits 0 with empty stdout when the commit has no number — that is
        // the contract, however natural a non-zero exit would be.
        return 0;
      case 'find':
      case 'find-commit':
        final number = args.length > 1 ? args[1] : '';
        if (number.isEmpty) {
          _printUsage();
          throw ToolFailure('find-commit needs a build number');
        }
        return _findCommit(number);
      case 'force':
        if (args.length < 2) {
          // The shell dies on an unbound `$2` here rather than printing
          // usage; match the shape — stderr, exit 1, nothing on stdout.
          stderr.writeln('force: missing build number (\$2: unbound variable)');
          return 1;
        }
        await _force(args[1]);
        return 0;
      case 'force-incr':
        final number = await _forceIncr();
        stdout.writeln(number);
        return 0;
      case 'log':
        // --first-parent because each entry carries the built commit as a
        // second parent; without it this walks the project's whole history
        // instead of the allocation log.
        return _gitLogPassthrough(['--first-parent', refsCommits]);
      case 'help':
        _printUsage();
        return 0;
      default:
        _printUsage();
        throw ToolFailure('Unknown argument (${args.join(' ')})');
    }
  }

  // ------------------------------------------------------------- generate

  Future<String> _generateOrGet() async {
    for (var attempt = 1; ; attempt++) {
      // The dirty-tree check runs before the existing-note check, so
      // `generate` refuses a dirty repository even when the commit already
      // has a number.
      await _assertCleanRepository();
      if (mayTrustLocalNote(attempt)) {
        final existing = await _existingBuildNumber();
        if (existing != null) {
          return existing;
        }
      }
      await _fetch();
      final fetched = await _existingBuildNumber();
      if (fetched != null) {
        return fetched;
      }
      final counter = await _readCounter();
      if (counter == null) {
        _logi('No buildnumber yet, starting one now.');
      }
      final number = nextBuildNumber(counter);
      await _writeBuildNumber('$number', 'increment');
      if (await _push(nofail: true)) {
        return '$number';
      }
      if (!shouldRetryAfterLostPush(
        attempt: attempt,
        maxAttempts: maxAttempts,
      )) {
        // Leaving the unpublished write behind means the next run finds its
        // own note on attempt 1, returns it without fetching or pushing, and
        // reports a number nothing else in the world has.
        await _restoreObserved();
        throw ToolFailure(
          'Could not publish a build number after $maxAttempts attempts. '
          'Another job may be allocating continuously, or the remote is '
          'rejecting writes.',
        );
      }
      _logi(
        'Another allocation won the race; refetching and taking the '
        'next number.',
      );
    }
  }

  Future<String> _forceIncr() async {
    for (var attempt = 1; ; attempt++) {
      await _fetch();
      await _assertCleanRepository();
      final current = await _generateOrGet();
      // That call may have fetched and pushed. The observations this process
      // holds are from before it, so leasing against them refuses every push
      // here — burning a number per attempt and returning a higher one than
      // asked for. Re-observe before writing.
      await _fetch();
      final currentNumber = int.tryParse(current);
      if (currentNumber == null) {
        throw ToolFailure('build number is not a number: "$current"');
      }
      final counter = await _readCounter();
      final next = forceIncrNext(counter: counter, current: currentNumber);
      await _writeBuildNumber('$next', 'force increment');
      if (await _push(nofail: true)) {
        return '$next';
      }
      if (!shouldRetryAfterLostPush(
        attempt: attempt,
        maxAttempts: maxAttempts,
      )) {
        throw ToolFailure(
          'Could not force-increment after $maxAttempts attempts.',
        );
      }
      _logi('Another allocation won the race; refetching.');
    }
  }

  Future<void> _force(String number) async {
    await _fetch();
    await _writeBuildNumber(number, 'forced');
    stdout.writeln('Written build number.');
    await _push();
  }

  // ---------------------------------------------------------- find-commit

  Future<int> _findCommit(String number) async {
    final entryName = 'b$number';
    final lsTree = await _git([
      'ls-tree',
      '--full-tree',
      refsCommits,
      entryName,
    ]);
    if (lsTree.exitCode != 0) {
      throw GitFailure(lsTree.exitCode, 'git ls-tree');
    }
    final blobHash = lsTreeEntryHash(lsTree.stdoutText, entryName);
    if (blobHash == null) {
      stdout.writeln(
        'Unable to find buildnumber $number - make sure to '
        'run: git-buildnumber fetch',
      );
      return 1;
    }
    final commits = (await _mustGit(['cat-file', 'blob', blobHash])).stdoutText;
    final shas = commits
        .split(RegExp(r'\s+'))
        .where((sha) => sha.isNotEmpty)
        .toList();
    _logi('Found the following commits: ${uniqueAdjacentLines(commits)}');
    // stdout is the `git log -1` block and nothing else — promote.sh seds
    // `^commit <sha>` out of it, so a bare SHA here would break every tagged
    // promotion.
    return _gitLogPassthrough([...shas, '-1']);
  }

  // -------------------------------------------------------------- plumbing

  Future<void> _assertCleanRepository() async {
    if (ignoreRepositoryState == '1') {
      return;
    }
    final result = await _git(diffIndexArgs(diffIndexRawArgs));
    if (result.exitCode != 0) {
      throw ToolFailure(
        'Requires a clean repository state, without uncommitted changes.',
      );
    }
  }

  Future<String?> _existingBuildNumber() async {
    final result = await _git([
      'notes',
      '--ref=$refsNotes',
      'show',
    ], quietStderr: true);
    if (result.exitCode != 0) {
      return null;
    }
    return result.trimmed;
  }

  Future<int?> _readCounter() async {
    final result = await _git([
      'cat-file',
      'blob',
      refsLast,
    ], quietStderr: true);
    if (result.exitCode != 0) {
      return null;
    }
    final value = int.tryParse(result.trimmed);
    if (value == null) {
      throw ToolFailure(
        '$refsLast does not hold a number: "${result.trimmed}"',
      );
    }
    return value;
  }

  Future<void> _fetch() async {
    _logPartial(_dim, 'TRACE', 'Fetching from $fetchRemote ...    ');
    // Guarded probe: an older git that does not know the flag simply fails to
    // print `true`, and the full (unshallow) fetch path is taken — the port
    // must not hard-refuse where the shell degrades.
    final probe = await _git([
      'rev-parse',
      '--is-shallow-repository',
    ], quietStderr: true);
    final shallow = probe.stdoutText.contains('true');
    final fetch = await _git(fetchArgs(remote: fetchRemote, shallow: shallow));
    if (fetch.exitCode != 0) {
      throw GitFailure(fetch.exitCode, 'git fetch');
    }
    // Recorded immediately after the fetch — this is the value the push will
    // lease against. **A lease is a claim about the remote, so it is read
    // from the remote**: a fetch only updates refs the remote actually has,
    // so reading local refs here would let a local-only ref claim a value the
    // remote never held, and every push then dies "stale info".
    await _observeRemote();
    _fetched = true;
    _logBare(_dim, 'DONE');
  }

  /// What the push remote currently holds, read once for all three refs.
  ///
  /// **An unreachable remote must not look like an empty one.** `ls-remote`
  /// exits non-zero when it cannot reach the remote and zero-with-no-output
  /// when the ref simply is not there; collapsing those means a network or
  /// auth failure reads as "no refs yet", which drops every lease and turns
  /// the next push into an unguarded force.
  Future<void> _observeRemote() async {
    final result = await _git(
      lsRemoteArgs(remote: pushRemote),
      quietStderr: true,
    );
    if (result.exitCode != 0) {
      throw ToolFailure(
        'Cannot read $pushRemote. Refusing to push without '
        'knowing what it holds.',
      );
    }
    _remoteRefsOutput = result.stdoutText;
    _observed = (
      last: _remoteRef(refsLast),
      commits: _remoteRef(refsCommits),
      notes: _remoteRef(refsNotes),
    );
  }

  String? _remoteRef(String ref) {
    for (final line in _remoteRefsOutput.split('\n')) {
      final fields = line
          .split(RegExp(r'\s+'))
          .where((f) => f.isNotEmpty)
          .toList();
      if (fields.length >= 2 && fields[1] == ref) {
        return fields[0];
      }
    }
    return null;
  }

  Future<bool> _push({bool nofail = false}) async {
    _logPartial(_dim, 'TRACE', 'Pushing to $pushRemote ...    ');
    // A push with no preceding fetch has nothing to lease against — but it
    // must not *fetch* to get one. A fetch force-updates the local refs from
    // the remote, discarding exactly the local allocation being published.
    // Read the remote without touching anything local instead.
    //
    // (A lease taken at push time is satisfied by definition, so a bare
    // `push` can overwrite a newer remote. v1.3 shipped knowing that, and the
    // port preserves it: fixing it means deciding whether local state that
    // lost a race is publishable at all.)
    if (!_fetched) {
      await _observeRemote();
    }
    final result = await _git(
      pushArgs(remote: pushRemote, observed: _observed),
    );
    if (result.exitCode != 0) {
      _logBare(_dim, 'ERROR');
      if (!nofail) {
        throw ToolFailure('Error while pushing to remote. Exiting');
      }
      _logi('Error while pushing to remote');
      return false;
    }
    _logBare(_dim, 'DONE');
    return true;
  }

  /// Puts the local refs back to what the remote had, discarding a write that
  /// was never published.
  Future<void> _restoreObserved() async {
    await _restoreOne(refsLast, _observed.last);
    await _restoreOne(refsCommits, _observed.commits);
    await _restoreOne(refsNotes, _observed.notes);
  }

  Future<void> _restoreOne(String ref, String? value) async {
    if (value != null) {
      await _git(['update-ref', ref, value]);
    } else {
      await _git(['update-ref', '-d', ref], quietStderr: true);
    }
  }

  Future<void> _writeBuildNumber(String number, String reason) async {
    final headSha = (await _mustGit(['rev-parse', 'HEAD'])).trimmed;
    final message = 'buildnumber: $number ($reason) at commit $headSha';
    final counterHash = (await _mustGit([
      'hash-object',
      '-w',
      '--stdin',
    ], input: utf8.encode(counterBlobContent(number)))).trimmed;
    // Compare-and-swap against the current value when the ref exists; an
    // absent ref makes the update unconditional, which is the first-run case.
    final oldLast = await _showRef(refsLast);
    await _mustGit([
      'update-ref',
      '-m',
      message,
      '--create-reflog',
      refsLast,
      counterHash,
      if (oldLast != null) ...[oldLast],
    ]);
    await _mustGit([
      'notes',
      '--ref=$refsNotes',
      'add',
      '-m',
      number,
      '-f',
      'HEAD',
    ]);

    _logd('writing our own commits log');

    final entryName = 'b$number';
    var chainHash = await _showRef(refsCommits);
    if (chainHash == null) {
      // **The chain needs a root of its own, so the built commit is always
      // the *second* parent.** Without one, the first allocation has no
      // previous entry, `-p HEAD` lands in first position, and a
      // first-parent walk then leaves the allocation log for the project's
      // history. An empty parentless commit costs nothing and keeps the
      // invariant true from the first entry onwards.
      final emptyTree = (await _mustGit([
        'mktree',
      ], input: const <int>[])).trimmed;
      chainHash = (await _mustGit([
        'commit-tree',
        emptyTree,
        '-m',
        'buildnumbers: start of the allocation log',
      ])).trimmed;
    }
    // The chain being appended to may predate the root and the parent pair —
    // v1.2 entries chain to a sole parent and hold the SHA only as blob
    // content — so nothing here may assume the shape this version writes.
    final lsTree = (await _mustGit([
      'ls-tree',
      '--full-tree',
      chainHash,
    ])).stdoutText;
    final previousHash = lsTreeEntryHash(lsTree, entryName);
    var previous = const <int>[];
    if (previousHash != null) {
      // Another commit already has this build number.. but anyway..
      _logd('Another commit ($previousHash) already uses this.');
      previous = (await _mustGit([
        'cat-file',
        'blob',
        previousHash,
      ])).stdoutBytes;
    }
    final blobHash = (await _mustGit([
      'hash-object',
      '-w',
      '--stdin',
    ], input: chainBlobContent(previous: previous, headSha: headSha))).trimmed;
    final treeHash = (await _mustGit(
      ['mktree'],
      input: utf8.encode(
        chainTreeInput(
          existingLsTree: lsTree,
          entryName: entryName,
          blobHash: blobHash,
        ),
      ),
    )).trimmed;
    // **The built commit is a parent, not just a filename in the tree.**
    // As blob content alone the SHA is a lookup, not a reference: `git gc`
    // collects the commit as soon as the last branch containing it goes
    // away, and the note still resolves afterwards, answering with a SHA
    // that no longer exists. As a parent it survives gc, and pushing this
    // ref carries its objects to the remote. It is the *second* parent so
    // `git log --first-parent` still walks only the allocation history.
    final newChain = (await _mustGit([
      'commit-tree',
      '-p',
      chainHash,
      '-p',
      'HEAD',
      treeHash,
      '-m',
      message,
    ])).trimmed;
    await _mustGit([
      'update-ref',
      '-m',
      message,
      '--create-reflog',
      refsCommits,
      newChain,
    ]);
  }

  Future<String?> _showRef(String ref) async {
    final result = await _git(['show-ref', '-s', ref]);
    if (result.exitCode != 0 || result.trimmed.isEmpty) {
      return null;
    }
    return result.trimmed;
  }

  // ------------------------------------------------------------ processes

  Future<_GitResult> _git(
    List<String> args, {
    List<int>? input,
    bool quietStderr = false,
  }) async {
    if (verbose) {
      _log(_dim, 'TRACE', 'git ${args.join(' ')}');
    }
    final process = await Process.start('git', args);
    try {
      if (input != null) {
        process.stdin.add(input);
      }
      await process.stdin.close();
    } on Object catch (_) {
      // The child exited before reading its stdin; its exit code tells the
      // story.
    }
    final stdoutFuture = process.stdout.fold<BytesBuilder>(
      BytesBuilder(copy: false),
      (builder, chunk) => builder..add(chunk),
    );
    final stderrFuture = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final code = await process.exitCode;
    final stdoutBytes = (await stdoutFuture).takeBytes();
    final stderrText = await stderrFuture;
    if (!quietStderr && stderrText.isNotEmpty) {
      stderr.write(stderrText);
    }
    return _GitResult(code, stdoutBytes, stderrText);
  }

  Future<_GitResult> _mustGit(List<String> args, {List<int>? input}) async {
    final result = await _git(args, input: input);
    if (result.exitCode != 0) {
      throw GitFailure(result.exitCode, 'git ${args.join(' ')}');
    }
    return result;
  }

  /// `git log` with our stdout, so the block reaches the consumer verbatim.
  /// Exit 141 (SIGPIPE, a closed pipe downstream) is tolerated.
  Future<int> _gitLogPassthrough(List<String> args) async {
    if (verbose) {
      _log(_dim, 'TRACE', 'git log ${args.join(' ')}');
    }
    try {
      await stdout.flush();
      await stderr.flush();
    } on Object catch (_) {
      // A closed pipe; git log will meet it too.
    }
    final process = await Process.start('git', [
      'log',
      ...args,
    ], mode: ProcessStartMode.inheritStdio);
    final code = _shellExitCode(await process.exitCode);
    if (code != 0 && code != 141) {
      return code;
    }
    _log(_dim, 'TRACE', 'git log success with $code');
    return 0;
  }

  // -------------------------------------------------------------- logging

  void _log(String color, String level, String message) {
    stderr.writeln('$color  $level $message$_reset');
  }

  void _logPartial(String color, String level, String message) {
    stderr.write('$color  $level $message$_reset');
  }

  void _logBare(String color, String message) {
    stderr.writeln('$color   $message$_reset');
  }

  void _logd(String message) => _log(_blue, 'DEBUG', message);

  void _logi(String message) => _log(_yellow, 'INFO', message);

  void _printUsage() {
    stdout.writeln('git-buildnumber, version $gitBuildNumberVersion');
    stdout.writeln('Usage: git-buildnumber <command>');
    stdout.writeln();
    stdout.writeln('Commands:');
    stdout.writeln(
      '  generate             -- The default, outputs build number for current commit',
    );
    stdout.writeln('                          or generates a new one.');
    stdout.writeln(
      '  find-commit <number> -- Finds the commit (message) for a given build number.',
    );
    stdout.writeln(
      '  force <number>       -- Uses the given number as the current buildnumber of',
    );
    stdout.writeln('                          the current commit.');
    stdout.writeln(
      '  force-incr           -- Forces generation of a new build number for the ',
    );
    stdout.writeln('                          current commit.');
    stdout.writeln(
      '  get                  -- show the build number for the current commit (if any)',
    );
    stdout.writeln('  sync                 -- fetch && push');
    stdout.writeln('  fetch                -- fetch all refs from remote');
    stdout.writeln(
      '  log                  -- shows the latest build numbers and corresponding ',
    );
    stdout.writeln('                          commits');
    stdout.writeln('  push                 -- push all refs from remote');
  }
}
