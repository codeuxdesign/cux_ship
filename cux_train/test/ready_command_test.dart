// `ready` end to end: a table on disk, records in a real repository, a verdict
// on stdout and in the exit code.
//
// **Mostly in process, with the exit code spawned.** What a verb does with
// what it reads is cheapest to assert from inside, one `CommandRunner` per
// case; the exit code is not observable there at all, and it is the half of
// this verb a launcher actually consumes — `train ready && train production`
// reads the number and never the text. So the last group pays for a VM start.
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cux_train/cux_train.dart';
import 'package:cux_train/runner.dart';
import 'package:cux_train/src/candidate_command.dart';
import 'package:cux_train/src/ready_command.dart';
import 'package:test/test.dart';

late Directory _root;
late Git _git;

/// AuthPass's shape, narrowed: a console that can refuse, a step ordered after
/// the version tag, and a destination nobody acts on at production.
const _table = '''
destinations:
  huawei:
    internal: {kind: run, command: "_tools/upload-artifact.sh"}
    production:
      kind: manual
      console: "https://developer.huawei.com"
  fdroid:
    after-finish: true
    production: {kind: run, command: "_tools/fdroid-tag.sh"}
  web:
    production: none
''';

void _writeTable(String yaml, {String name = defaultTableFile}) =>
    File('${_root.path}/$name').writeAsStringSync(yaml);

void _commit() {
  File('${_root.path}/file.txt').writeAsStringSync('a release');
  _git.run(['add', '-A']);
  _git.run(['commit', '-q', '-m', 'a release']);
}

void _tag(String name, String body) =>
    _git.run(['tag', '-a', name, '-m', body]);

/// Runs the verb with its working directory and its repository both at [_root].
Future<String> _ready(List<String> args) async {
  final output = StringBuffer();
  final runner = CommandRunner<void>('cux_train', 'under test')
    ..addCommand(ReadyCommand(output: output, root: _root.path));
  await runner.run(['ready', ...args]);
  return output.toString();
}

/// The same verb as a process, so the exit code is a real one.
final String _packageConfig = () {
  for (final candidate in [
    '../.dart_tool/package_config.json',
    '.dart_tool/package_config.json',
  ]) {
    final file = File(candidate);
    if (file.existsSync()) {
      return file.absolute.path;
    }
  }
  throw StateError('run dart pub get at the workspace root');
}();

ProcessResult _spawn(List<String> args) => Process.runSync(
  Platform.resolvedExecutable,
  ['--packages=$_packageConfig', 'package:cux_train/cli.dart', ...args],
  workingDirectory: _root.path,
);

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('cux_train_ready');
    _git = Git(_root.path);
    _git.run(['init', '-q', '-b', 'main']);
    _git.run(['config', 'user.email', 'test@example.com']);
    _git.run(['config', 'user.name', 'Test']);
    _commit();
    _writeTable(_table);
  });

  tearDown(() => _root.deleteSync(recursive: true));

  group('the answer it prints', () {
    test('is yes for a release nothing is recorded against', () async {
      final out = await _ready(['--build', '2196', '--release', '1.9.13']);

      expect(out, startsWith('1.9.13 — build 2196'));
      expect(out, contains('production could run.'));
      expect(out, contains('huawei  manual  https://developer.huawei.com'));
    });

    test('reads the refusals out of the repository it was given', () async {
      // The whole point of the verb reaching for git: a refusal recorded days
      // ago, by a different run, is what `production` is about to walk into.
      _tag('refused/huawei/production/v1.9.13+2196', 'the console said no');

      final out = await _ready(['--build', '2196', '--release', '1.9.13']);

      expect(out, contains('one thing to take with you:'));
      expect(out, contains('huawei turned this build down'));
    });

    test('a release spelled with a stray space still finds its records', () {
      // `--release '1.9.13 '` is a quoting slip, and only an all-whitespace
      // value was refused — so the header printed a stray space and the
      // comparison against `v1.9.13+2196` then failed, reporting a release
      // with records as one with none.
      _tag('promoted/huawei/production/v1.9.13+2196', 'done');

      return expectLater(
        _ready(['--build', '2196', '--release', '1.9.13 ']),
        completion(
          allOf(startsWith('1.9.13 — build 2196'), contains('act on 1 of 2')),
        ),
      );
    });

    test('a hand-over for another build does not count as this one', () async {
      _tag('promoted/huawei/production/v1.9.12+2007', 'last release');

      final out = await _ready(['--build', '2196', '--release', '1.9.13']);

      expect(out, contains('it would act on 2'));
    });
  });

  group('what it refuses', () {
    test('a table that is not there, by name', () async {
      File('${_root.path}/$defaultTableFile').deleteSync();

      await expectLater(
        _ready(['--build', '2196', '--release', '1.9.13']),
        throwsA(
          isA<DestinationTableException>().having(
            (it) => it.message,
            'message',
            contains(defaultTableFile),
          ),
        ),
      );
    });

    test('a candidate it was not given', () async {
      await expectLater(
        _ready(['--release', '1.9.13']),
        throwsA(isA<UsageException>()),
      );
    });

    test('a release it was not given', () async {
      await expectLater(
        _ready(['--build', '2196']),
        throwsA(isA<UsageException>()),
      );
    });

    test('a build spelled in hex, which int.tryParse would read', () async {
      await expectLater(
        _ready(['--build', '0x10', '--release', '1.9.13']),
        throwsA(isA<UsageException>()),
      );
    });

    test('a word after the flags, rather than dropping it', () async {
      // The guard is on the shared base, so it covers this verb without
      // anybody writing it twice — which is the reason the base exists.
      await expectLater(
        _ready(['--build', '2196', '--release', '1.9.13', 'huawei']),
        throwsA(isA<UsageException>()),
      );
    });

    test('--store, because ready does not narrow', () async {
      // §4 settles that the finish rule is not keyed on how an invocation was
      // narrowed, so a narrowed readiness answer would be about a question
      // nobody asked. An option nobody declared is one the parser refuses.
      await expectLater(
        _ready(['--build', '2196', '--release', '1.9.13', '--store', 'huawei']),
        throwsA(isA<UsageException>()),
      );
    });
  });

  group('the exit code, which is what a launcher reads', () {
    test('is 0 when production could run', () {
      final result = _spawn([
        'ready',
        '--build',
        '2196',
        '--release',
        '1.9.13',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout, contains('production could run.'));
    });

    test('is still 0 when a destination refused the build', () {
      // **This case asserted the opposite and the opposite was wrong.** A
      // refusal is recorded so that the next `production` run returns to that
      // destination (§6.1), and nothing clears one — so a non-zero exit here
      // made `ready && production`, which this package's README recommended,
      // stop that build's release permanently.
      _tag('refused/huawei/production/v1.9.13+2196', 'the console said no');

      final result = _spawn([
        'ready',
        '--build',
        '2196',
        '--release',
        '1.9.13',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout, contains('production could run'));
      expect(result.stdout, contains('turned this build down'));
      expect(result.stderr, isEmpty);
    });

    test('is still 0 once the console has accepted it after all', () {
      // The permanence, which is what made the inversion costly rather than
      // merely wrong: `recordFor` lets a refusal win over a later hand-over.
      _tag('refused/huawei/production/v1.9.13+2196', 'the console said no');
      _tag('promoted/huawei/production/v1.9.13+2196', 'accepted on Thursday');

      final result = _spawn([
        'ready',
        '--build',
        '2196',
        '--release',
        '1.9.13',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
    });

    test('is 1 for a table that will not parse, which is a failure', () {
      _writeTable('destinations: []');

      final result = _spawn([
        'ready',
        '--build',
        '2196',
        '--release',
        '1.9.13',
      ]);

      expect(result.exitCode, 1);
    });
  });

  test('the real command tree offers ready', () {
    // The wiring between the runner and this verb is not something only this
    // file knows: every case above builds a runner of its own so the root can
    // be injected, and this is what says the shipped tree has the same verb.
    expect(buildRunner().commands.keys, containsAll(['status', 'ready']));
  });
}
