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

      await expectLater(
        _ready(['--build', '2196', '--release', '1.9.13']),
        throwsA(isA<ProductionNotReady>()),
      );
    });

    test('names the blocked destination in what reaches stderr', () async {
      // The report goes to stdout; this sentence is for a log whose stdout
      // went somewhere else, so it has to carry the destination itself.
      _tag('refused/huawei/production/v1.9.13+2196', 'the console said no');

      await expectLater(
        _ready(['--build', '2196', '--release', '1.9.13']),
        throwsA(
          isA<ProductionNotReady>().having(
            (it) => it.message,
            'message',
            allOf(contains('huawei'), contains('1.9.13'), contains('2196')),
          ),
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

    test('is notReadyExit when it could not, and not 1', () {
      // **Not 1, which is the point of having a number for it.** A `ready`
      // that found a refusal has to be distinguishable from a table that
      // would not parse, or `train ready && train production` cannot tell a
      // release that is not ready from a tool that broke.
      _tag('refused/huawei/production/v1.9.13+2196', 'the console said no');

      final result = _spawn([
        'ready',
        '--build',
        '2196',
        '--release',
        '1.9.13',
      ]);

      expect(result.exitCode, notReadyExit);
      expect(result.exitCode, isNot(1));
      expect(result.stdout, contains('production cannot run'));
      expect(result.stderr, contains('production is not ready'));
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
