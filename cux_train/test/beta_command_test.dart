// `beta` end to end: flags, refusals, and the exit code a caller branches on.
//
// The engine's decisions are held in `promotion_run_test.dart`; this is the
// verb around it — what it reads from the command line, what it refuses, and
// what number a script gets back.
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cux_train/cux_train.dart';
import 'package:cux_train/src/beta_command.dart';
import 'package:cux_train/src/candidate_command.dart';
import 'package:test/test.dart';

late Directory _root;
late Git _git;

const _table = '''
destinations:
  play:
    beta: {kind: ship, command: "ship play --build {build}"}
    production: {kind: ship, command: "ship play production"}
  amazon:
    production: {kind: manual, console: "https://developer.amazon.com"}
''';

void _writeTable(String yaml) =>
    File('${_root.path}/$defaultTableFile').writeAsStringSync(yaml);

void _commit() {
  File('${_root.path}/file.txt').writeAsStringSync('a release');
  _git.run(['add', '-A']);
  _git.run(['commit', '-q', '-m', 'a release']);
}

/// A console nobody is at, which is what a test process really is.
class _NoConsole implements OperatorConsole {
  @override
  bool get attached => false;

  @override
  ManualAnswer? ask() => null;

  @override
  String? askNote() => null;

  @override
  bool? confirm(String question) => null;
}

late List<List<String>> _calls;

Future<int> _spawnStub(
  List<String> argv, {
  required String workingDirectory,
  Map<String, String> environment = const {},
}) async {
  _calls.add(argv);
  return 0;
}

Future<String> _beta(List<String> args) async {
  final output = StringBuffer();
  final runner = CommandRunner<void>('cux_train', 'under test')
    ..addCommand(
      BetaCommand(
        output: output,
        root: _root.path,
        console: _NoConsole(),
        spawn: _spawnStub,
        push: false,
      ),
    );
  await runner.run(['beta', ...args, '--yes']);
  return output.toString();
}

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

ProcessResult _run(List<String> args) => Process.runSync(
  Platform.resolvedExecutable,
  ['--packages=$_packageConfig', 'package:cux_train/cli.dart', ...args],
  workingDirectory: _root.path,
);

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('cux_train_beta');
    _git = Git(_root.path);
    _git.run(['init', '-q', '-b', 'main']);
    _git.run(['config', 'user.email', 'test@example.com']);
    _git.run(['config', 'user.name', 'Test']);
    _commit();
    _git.run([
      'tag',
      '-a',
      'uploaded/v1.9.13+2196',
      '-m',
      'build 2196 of 1.9.13',
    ]);
    _writeTable(_table);
    _calls = [];
  });

  tearDown(() => _root.deleteSync(recursive: true));

  group('what it reads from the command line', () {
    test('spawns the command with the build substituted', () async {
      await _beta(['--build', '2196', '--release', '1.9.13']);

      expect(_calls.single, ['ship', 'play', '--build', '2196']);
    });

    test('--store narrows, and a destination with no beta stage is refused '
        'by name', () async {
      // §3: `--store amazon beta` refuses rather than quietly doing nothing,
      // and says which stage amazon does have.
      await expectLater(
        _beta(['--build', '2196', '--release', '1.9.13', '--store', 'amazon']),
        throwsA(
          isA<StoreSelectionException>().having(
            (e) => e.message,
            'message',
            allOf(contains('amazon'), contains('production')),
          ),
        ),
      );
      expect(_calls, isEmpty);
    });

    test('a destination the table never declares is refused', () async {
      await expectLater(
        _beta([
          '--build',
          '2196',
          '--release',
          '1.9.13',
          '--store',
          'nintendo',
        ]),
        throwsA(isA<StoreSelectionException>()),
      );
    });

    test(
      '--uploaded-tag is a pattern, and names the commit records land on',
      () async {
        _git.run([
          'tag',
          '-a',
          'shipped/1.9.13/2196',
          '-m',
          'the consumer spells it differently',
        ]);

        await _beta([
          '--build',
          '2196',
          '--release',
          '1.9.13',
          '--uploaded-tag',
          'shipped/{version}/{build}',
        ]);

        expect(
          _git.run(['tag', '-l', 'promoted/*']).trim(),
          'promoted/play/beta/v1.9.13+2196',
        );
      },
    );

    test('a word after the flags is refused rather than dropped', () async {
      await expectLater(
        _beta(['--build', '2196', '--release', '1.9.13', 'production']),
        throwsA(isA<UsageException>()),
      );
    });

    test('--build and --release are both required', () async {
      await expectLater(
        _beta(['--build', '2196']),
        throwsA(isA<UsageException>()),
      );
      await expectLater(
        _beta(['--release', '1.9.13']),
        throwsA(isA<UsageException>()),
      );
    });
  });

  group('the gates its stage declares', () {
    test('a beta gate runs, and runs before the walk', () async {
      // The case that was missing while `runGates` had two callers and this
      // verb was not one: `gates: {beta: […]}` parsed, was believed by
      // whoever wrote it, and never ran. The other stage's gate is in the
      // same table to show the key is doing the choosing.
      _writeTable('''
gates:
  beta:
    - {kind: run, command: "pre-beta {version}"}
  production:
    - {kind: run, command: "not-this-stage"}
$_table''');

      await _beta(['--build', '2196', '--release', '1.9.13']);

      expect(_calls.map((it) => it.first).toList(), ['pre-beta', 'ship']);
    });
  });

  group('the exit code', () {
    test('is 0 when every destination is recorded', () {
      // A real child process, so the spawn, the exit code it answers and the
      // record written after it are all the real ones.
      _writeTable('''
destinations:
  play:
    beta: {kind: ship, command: "echo shipped {version}"}
''');

      final result = _run([
        'beta',
        '--build',
        '2196',
        '--release',
        '1.9.13',
        '--yes',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(
        _git.run(['tag', '-l', 'promoted/*']).trim(),
        'promoted/play/beta/v1.9.13+2196',
      );
    });

    test('a dry run with work left is 2, because none of it was done', () {
      final result = _run([
        'beta',
        '--build',
        '2196',
        '--release',
        '1.9.13',
        '--dry-run',
        '--yes',
      ]);

      expect(result.exitCode, incompleteExit);
      expect(result.stdout, contains('nothing was recorded'));
    });

    test('a dry run that finds the stage already recorded is 0', () {
      // The other side of the case above: the exit code answers whether the
      // build is at beta, and it is — whichever invocation put it there.
      _writeTable('''
destinations:
  play:
    beta: {kind: ship, command: "echo shipped {version}"}
''');
      final args = ['beta', '--build', '2196', '--release', '1.9.13', '--yes'];
      expect(_run(args).exitCode, 0);

      final result = _run([...args, '--dry-run']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout, contains('Already recorded at beta'));
      expect(result.stdout, contains('is recorded at beta'));
    });

    test('a command that cannot be started is 2, with a report', () {
      _writeTable('''
destinations:
  play:
    beta: {kind: ship, command: "no-such-program-cux-train-test play"}
''');

      final result = _run([
        'beta',
        '--build',
        '2196',
        '--release',
        '1.9.13',
        '--yes',
      ]);

      expect(result.exitCode, incompleteExit, reason: result.stderr as String);
      expect(result.stdout, contains('could not start'));
      expect(_git.run(['tag', '-l', 'promoted/*']).trim(), isEmpty);
    });

    test('a manual step with nobody to answer it is 2, not a crash', () {
      _writeTable('''
destinations:
  huawei:
    beta: {kind: manual, console: "https://developer.huawei.com"}
''');

      final result = _run([
        'beta',
        '--build',
        '2196',
        '--release',
        '1.9.13',
        '--yes',
      ]);

      expect(result.exitCode, incompleteExit, reason: result.stderr as String);
      expect(result.stdout, contains('pending'));
    });

    test('a table that will not parse is 1, which is a different thing', () {
      _writeTable('destinations: [not, a, map]');

      final result = _run([
        'beta',
        '--build',
        '2196',
        '--release',
        '1.9.13',
        '--yes',
      ]);

      expect(result.exitCode, 1);
    });

    test('a command the table spells wrongly is 1, before anything spawns', () {
      _writeTable('''
destinations:
  play:
    beta: {kind: ship, command: "ship play --notes {artifact}"}
''');

      final result = _run([
        'beta',
        '--build',
        '2196',
        '--release',
        '1.9.13',
        '--yes',
      ]);

      expect(result.exitCode, 1);
      expect(result.stderr, contains('{artifact}'));
    });

    test('without --yes and off a terminal it stops before spending', () {
      final result = _run([
        'beta',
        '--build',
        '2196',
        '--release',
        '1.9.13',
        '--store',
        'play',
      ]);

      expect(result.exitCode, 1);
      expect(result.stderr, contains('--yes'));
    });
  });

  group('the command tree', () {
    test('offers beta, with the flags that spend', () {
      final result = _run(['help', 'beta']);

      expect(result.exitCode, 0);
      for (final flag in ['--store', '--dry-run', '--yes', '--uploaded-tag']) {
        expect(result.stdout, contains(flag), reason: 'offers $flag');
      }
    });

    test('status and ready still do not offer them', () {
      // They read. A flag about spending on a verb that spends nothing is the
      // dropped flag `runner.dart` refuses to declare.
      final result = _run(['help', 'status']);

      expect(result.stdout, isNot(contains('--dry-run')));
      expect(result.stdout, isNot(contains('--yes')));
    });
  });
}
