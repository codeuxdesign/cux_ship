// `production` is `beta` at another stage plus three things, and all three are
// about the version tag: the finish rule that gates it, the `after-finish`
// destinations that follow it, and the fact that the tag is written by a
// command the consumer declares rather than by a name this package composes.
// These cases are those three.
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cux_train/cux_train.dart';
import 'package:cux_train/src/candidate_command.dart';
import 'package:cux_train/src/production_command.dart';
import 'package:test/test.dart';

late Directory _root;
late Git _git;
late StringBuffer _out;
late List<List<String>> _calls;

/// Two ordinary destinations, one that acts after the tag, and one nobody
/// acts on — the four shapes the finish rule has to tell apart.
const _table = '''
finish: {kind: run, command: "release-finish {version}"}
destinations:
  play:
    production: {kind: ship, command: "ship play {build}"}
  huawei:
    production: {kind: manual, console: "https://developer.huawei.com"}
  web:
    production: none
  fdroid:
    after-finish: true
    production: {kind: run, command: "fdroid-tag {version}"}
''';

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

/// Answers `d` to every manual step, so a case can get a stage fully recorded.
class _AlwaysDone implements OperatorConsole {
  @override
  bool get attached => true;

  @override
  ManualAnswer? ask() => ManualAnswer.done;

  @override
  String? askNote() => null;

  @override
  bool? confirm(String question) => true;
}

Future<int> _spawnStub(
  List<String> argv, {
  required String workingDirectory,
}) async {
  _calls.add(argv);
  return argv.first == 'boom' ? 1 : 0;
}

void _writeTable(String yaml) =>
    File('${_root.path}/$defaultTableFile').writeAsStringSync(yaml);

Future<void> _production(List<String> args, {OperatorConsole? console}) async {
  final runner = CommandRunner<void>('cux_train', 'under test')
    ..addCommand(
      ProductionCommand(
        output: _out,
        root: _root.path,
        console: console ?? _NoConsole(),
        spawn: _spawnStub,
        push: false,
      ),
    );
  await runner.run(['production', ...args, '--yes']);
}

List<String> _tags(String pattern) => _git
    .run(['tag', '-l', pattern])
    .split('\n')
    .where((line) => line.trim().isNotEmpty)
    .map((line) => line.trim())
    .toList();

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('cux_train_production');
    _git = Git(_root.path);
    _git.run(['init', '-q', '-b', 'main']);
    _git.run(['config', 'user.email', 'test@example.com']);
    _git.run(['config', 'user.name', 'Test']);
    File('${_root.path}/f.txt').writeAsStringSync('built');
    _git.run(['add', '-A']);
    _git.run(['commit', '-q', '-m', 'built']);
    _git.run([
      'tag',
      '-a',
      'uploaded/v1.9.13+2196',
      '-m',
      'build 2196 of 1.9.13',
    ]);
    _writeTable(_table);
    _out = StringBuffer();
    _calls = [];
  });

  tearDown(() => _root.deleteSync(recursive: true));

  group('the finish rule', () {
    test('holds the tag while a destination is unrecorded', () async {
      // `huawei` is manual and nobody is at the terminal, so it stays
      // pending — which is exactly the state the rule exists to notice.
      await expectLater(
        _production(['--build', '2196', '--release', '1.9.13']),
        throwsA(isA<PromotionIncomplete>()),
      );

      expect(_calls.map((it) => it.first), isNot(contains('release-finish')));
      expect(_out.toString(), contains('The version tag is not spent'));
      expect(_out.toString(), contains('huawei'));
    });

    test('is not held by a destination nobody acts on', () async {
      // `web` is `none` at production: nobody acts, so nothing records, and
      // waiting for a record no step writes would hold the tag forever.
      await _production([
        '--build',
        '2196',
        '--release',
        '1.9.13',
      ], console: _AlwaysDone());

      expect(_out.toString(), isNot(contains('The version tag is not spent')));
      expect(_calls.map((it) => it.first), contains('release-finish'));
    });

    test('is not held by a destination ordered after it', () async {
      // `fdroid` has a production step and is excluded, because the tag it
      // pushes annotates the one this step is about to write.
      await _production([
        '--build',
        '2196',
        '--release',
        '1.9.13',
      ], console: _AlwaysDone());

      expect(_calls.map((it) => it.first), contains('release-finish'));
    });

    test('is about the record, not about how the run was narrowed', () async {
      // §4: a `production` spanning days ends with `--store huawei`, and a
      // rule keyed on narrowing could never let that run spend the tag.
      // The first run finishes `play` and leaves the tag held by `huawei`,
      // which is incomplete and says so.
      await expectLater(
        _production([
          '--build',
          '2196',
          '--release',
          '1.9.13',
          '--store',
          'play',
        ]),
        throwsA(isA<PromotionIncomplete>()),
      );
      _out.clear();
      _calls.clear();

      await _production([
        '--build',
        '2196',
        '--release',
        '1.9.13',
        '--store',
        'huawei',
      ], console: _AlwaysDone());

      expect(
        _calls.map((it) => it.first),
        contains('release-finish'),
        reason: 'the last narrowed run finishes the release',
      );
    });

    test('says so when a narrowed run leaves the tag held', () async {
      await expectLater(
        _production([
          '--build',
          '2196',
          '--release',
          '1.9.13',
          '--store',
          'play',
        ]),
        throwsA(isA<PromotionIncomplete>()),
      );

      expect(_out.toString(), contains('narrowed with --store'));
      expect(_out.toString(), contains('huawei'));
    });
  });

  group('the order around the tag', () {
    test('an after-finish destination runs after the finish step', () async {
      await _production([
        '--build',
        '2196',
        '--release',
        '1.9.13',
      ], console: _AlwaysDone());

      final spawned = _calls.map((it) => it.first).toList();
      expect(
        spawned.indexOf('release-finish'),
        lessThan(spawned.indexOf('fdroid-tag')),
        reason: 'fdroid-vX.Y.Z cannot precede the vX.Y.Z it annotates',
      );
    });

    test('and is recorded like any other destination', () async {
      await _production([
        '--build',
        '2196',
        '--release',
        '1.9.13',
      ], console: _AlwaysDone());

      expect(
        _tags('promoted/*'),
        containsAll([
          'promoted/fdroid/production/v1.9.13+2196',
          'promoted/play/production/v1.9.13+2196',
        ]),
      );
    });

    test('is not walked at all while the tag is held', () async {
      // Running it early would push `fdroid-vX.Y.Z` for a release that may
      // never be finished.
      await expectLater(
        _production(['--build', '2196', '--release', '1.9.13']),
        throwsA(isA<PromotionIncomplete>()),
      );

      expect(_calls.map((it) => it.first), isNot(contains('fdroid-tag')));
    });
  });

  group('the finish step', () {
    test('is the command the table declares, interpolated', () async {
      await _production([
        '--build',
        '2196',
        '--release',
        '1.9.13',
      ], console: _AlwaysDone());

      // `contains` needs a matcher here: two Dart lists with equal elements
      // are not `==`, so a bare list would compare by identity and never
      // match.
      expect(_calls, contains(orderedEquals(['release-finish', '1.9.13'])));
    });

    test(
      'a table with no finish step says so instead of claiming done',
      () async {
        _writeTable(
          _table.replaceFirst(
            'finish: {kind: run, command: "release-finish {version}"}\n',
            '',
          ),
        );

        await expectLater(
          _production([
            '--build',
            '2196',
            '--release',
            '1.9.13',
          ], console: _AlwaysDone()),
          throwsA(isA<PromotionIncomplete>()),
        );

        expect(_out.toString(), contains('declares no `finish` step'));
      },
    );

    test(
      'a finish that is not a command is refused when the table is read',
      () async {
        _writeTable(
          _table.replaceFirst(
            'finish: {kind: run, command: "release-finish {version}"}',
            'finish: {kind: manual, console: "https://example.com"}',
          ),
        );

        await expectLater(
          _production(['--build', '2196', '--release', '1.9.13']),
          throwsA(
            isA<DestinationTableException>().having(
              (e) => e.message,
              'message',
              contains('has to run something'),
            ),
          ),
        );
      },
    );

    test('a finish that fails leaves every record in place', () async {
      _writeTable(_table.replaceFirst('release-finish {version}', 'boom'));

      await expectLater(
        _production([
          '--build',
          '2196',
          '--release',
          '1.9.13',
        ], console: _AlwaysDone()),
        throwsA(
          isA<PromotionRunException>().having(
            (e) => e.message,
            'message',
            contains('version tag was not spent'),
          ),
        ),
      );

      expect(_tags('promoted/*'), isNotEmpty);
      expect(_calls.map((it) => it.first), isNot(contains('fdroid-tag')));
    });

    test('a finish template naming a destination is refused by name', () async {
      // A finish is not about one destination, so `{destination}` has no
      // honest value — and a tag with the word `finish` in it would be worse
      // than a refusal.
      _writeTable(
        _table.replaceFirst('release-finish {version}', 'rf {destination}'),
      );

      await expectLater(
        _production([
          '--build',
          '2196',
          '--release',
          '1.9.13',
        ], console: _AlwaysDone()),
        throwsA(
          isA<StepCommandException>().having(
            (e) => e.message,
            'message',
            allOf(contains('{destination}'), contains('version, build')),
          ),
        ),
      );
    });

    test('a dry run prints it and spends nothing', () async {
      await expectLater(
        _production([
          '--build',
          '2196',
          '--release',
          '1.9.13',
          '--dry-run',
        ], console: _AlwaysDone()),
        throwsA(isA<PromotionIncomplete>()),
      );

      expect(_calls, isEmpty);
      expect(_tags('promoted/*'), isEmpty);
    });
  });
}
