// `internal` is the verb with two lanes, and these cases are about the seam
// between them: what the train performs, what it only watches, and the order
// that keeps a refusal free.
//
// **The clock is injected and the reads are stubbed**, because the thing under
// test is a wait — a case that slept for real would be an hour long, and one
// that read a real endpoint would be about the network.
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cux_train/cux_train.dart';
import 'package:cux_train/src/candidate_command.dart';
import 'package:cux_train/src/internal_command.dart';
import 'package:test/test.dart';

late Directory _root;
late Git _git;
late StringBuffer _out;
late List<List<String>> _calls;
late List<Map<String, String>> _envs;
late List<List<String>> _reads;
late Map<String, List<ReadOutput>> _answers;
late DateTime _clock;
late List<Duration> _slept;

/// Two destinations CI fills, one this machine owns, and one with no internal
/// step at all — the four shapes the verb has to tell apart.
const _table = '''
dispatch: {kind: run, command: "push-stable {build}"}
gates:
  internal:
    - {kind: run, command: "pre-build {version}"}
  production:
    - {kind: run, command: "not-this-stage"}
destinations:
  play:
    internal: wait
    read: "read-play {build}"
  web:
    internal: wait
    public-at-internal: true
    read: "read-web {build}"
  "direct:macos":
    internal: {kind: run, command: "notarize {build}"}
  huawei:
    internal: none
    production: {kind: manual, console: "https://developer.huawei.com"}
''';

const _candidate = ['--build', '2196', '--release', '1.9.13'];

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

/// A terminal that says yes, and remembers what it was asked.
class _Agrees implements OperatorConsole {
  final List<String> asked = [];

  @override
  bool get attached => true;

  @override
  ManualAnswer? ask() => ManualAnswer.done;

  @override
  String? askNote() => null;

  @override
  bool? confirm(String question) {
    asked.add(question);
    return true;
  }
}

/// A terminal that says no.
class _Declines extends _Agrees {
  @override
  bool? confirm(String question) {
    asked.add(question);
    return false;
  }
}

Future<int> _spawnStub(
  List<String> argv, {
  required String workingDirectory,
  Map<String, String> environment = const {},
}) async {
  _calls.add(argv);
  _envs.add(environment);
  if (argv.first == 'missing') {
    throw ProcessException(argv.first, argv.sublist(1), 'No such file');
  }
  return argv.first == 'boom' || argv.first == 'refuse' ? 1 : 0;
}

/// Answers each read from a queue keyed by the command's name. The last answer
/// repeats, so a case says "nothing, then 2196" or just "nothing, forever".
Future<ReadOutput> _readStub(
  List<String> argv, {
  required String workingDirectory,
}) async {
  _reads.add(argv);
  final queued = _answers[argv.first];
  if (queued == null || queued.isEmpty) {
    return const ReadOutput(exitCode: 0);
  }
  return queued.length == 1 ? queued.first : queued.removeAt(0);
}

ReadOutput _holds(int build) => ReadOutput(exitCode: 0, stdout: '$build\n');
const _nothing = ReadOutput(exitCode: 0);

DateTime _now() => _clock;

Future<void> _sleep(Duration duration) async {
  _slept.add(duration);
  _clock = _clock.add(duration);
}

void _writeTable(String yaml) =>
    File('${_root.path}/$defaultTableFile').writeAsStringSync(yaml);

Future<void> _internal(List<String> args, {OperatorConsole? console}) async {
  final runner = CommandRunner<void>('cux_train', 'under test')
    ..addCommand(
      InternalCommand(
        output: _out,
        root: _root.path,
        console: console ?? _NoConsole(),
        spawn: _spawnStub,
        push: false,
        read: _readStub,
        sleep: _sleep,
        now: _now,
        pollInterval: const Duration(minutes: 1),
      ),
    );
  await runner.run(['internal', ...args]);
}

List<String> _tags(String pattern) => _git
    .run(['tag', '-l', pattern])
    .split('\n')
    .where((line) => line.trim().isNotEmpty)
    .map((line) => line.trim())
    .toList();

List<String> _spawned() => _calls.map((it) => it.first).toList();

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('cux_train_internal');
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
    _envs = [];
    _reads = [];
    _answers = {
      'read-play': [_holds(2196)],
      'read-web': [_holds(2196)],
    };
    _clock = DateTime.utc(2026, 11, 17, 9);
    _slept = [];
  });

  tearDown(() => _root.deleteSync(recursive: true));

  group('the order', () {
    test('is gate, dispatch, local lane, then the wait', () async {
      await _internal([..._candidate, '--yes']);

      expect(_spawned(), ['pre-build', 'push-stable', 'notarize']);
      // The reads only start once the dispatch has happened: reading before
      // it would be asking about a build nothing had set going.
      expect(_reads, isNotEmpty);
      expect(
        _out.toString(),
        stringContainsInOrder(['dispatch  push-stable 2196', 'notarize 2196']),
      );
    });

    test(
      'runs the gates this stage declares and not another stage\'s',
      () async {
        await _internal([..._candidate, '--yes']);

        expect(_spawned(), contains('pre-build'));
        expect(_spawned(), isNot(contains('not-this-stage')));
        // §7's contract, the same here as at production: the destinations the
        // run will act on, waiting rows included — they are what it is for.
        expect(_envs.first['HOOK_STORES'], 'play web direct:macos');
      },
    );

    test('a gate that refuses stops it before the dispatch', () async {
      _writeTable(_table.replaceAll('pre-build {version}', 'refuse'));

      await expectLater(
        _internal([..._candidate, '--yes']),
        throwsA(
          isA<PromotionRunException>().having(
            (e) => e.message,
            'message',
            allOf(contains('refuse'), contains('run internal again')),
          ),
        ),
      );

      expect(_spawned(), ['refuse']);
      expect(_reads, isEmpty);
    });
  });

  group('the two lanes', () {
    test('a waiting destination is read, never walked or recorded', () async {
      await _internal([..._candidate, '--yes']);

      // Nothing was spawned on their behalf, and — the point of §6.2 — no
      // record was written for what this process only saw. A read says the
      // destination holds the build; a `promoted/` tag would say somebody
      // claims to have put it there, which is the weaker of the two.
      expect(_spawned(), isNot(contains('read-play')));
      expect(_tags('promoted/play/*'), isEmpty);
      expect(_tags('promoted/web/*'), isEmpty);
      // The local lane is recorded as any walked step is.
      expect(_tags('promoted/direct/macos/*'), [
        'promoted/direct/macos/internal/v1.9.13+2196',
      ]);
    });

    test('the local lane failing does not stop the wait', () async {
      // §3: a failed cell is reported and does not stop the others. Across
      // the lanes as much as within one.
      _writeTable(_table.replaceAll('notarize {build}', 'boom'));

      await expectLater(
        _internal([..._candidate, '--yes']),
        throwsA(isA<PromotionIncomplete>()),
      );

      expect(_reads.map((it) => it.first), containsAll(['read-play']));
      expect(_out.toString(), contains('Every destination this run waits on'));
    });

    test('a re-run reads again rather than remembering', () async {
      // Resumability without a record: everything that already arrived
      // answers at once, so the second run costs two reads and no wait.
      await _internal([..._candidate, '--yes']);
      final first = _reads.length;
      _calls.clear();
      await _internal([..._candidate, '--yes']);

      expect(_reads.length, first * 2);
      expect(_slept, isEmpty);
      // The local lane is skipped the second time, because that one *is*
      // recorded.
      expect(_spawned(), isNot(contains('notarize')));
    });
  });

  group('the wait', () {
    test('ends when every destination holds the candidate', () async {
      _answers['read-play'] = [_nothing, _nothing, _holds(2196)];

      await _internal([..._candidate, '--yes']);

      expect(_slept, [const Duration(minutes: 1), const Duration(minutes: 1)]);
      expect(_out.toString(), contains('play  holds 2196'));
      expect(
        _out.toString(),
        contains('Every destination this run waits on holds build 2196'),
      );
    });

    test('an older build is named rather than read as nothing', () async {
      // A destination that has never had a release and one that is a release
      // behind are different states, and §3 says the difference is the thing
      // worth seeing.
      _answers['read-play'] = [_holds(2195)];

      await expectLater(
        _internal([..._candidate, '--yes']),
        throwsA(isA<EvidenceIncomplete>()),
      );

      expect(_out.toString(), contains('play  pending  — holds 2195'));
    });

    test('times out into pending, which is not failed', () async {
      _answers['read-play'] = [_nothing];

      await expectLater(
        _internal([..._candidate, '--yes']),
        throwsA(isA<EvidenceIncomplete>()),
      );

      expect(_clock.difference(DateTime.utc(2026, 11, 17, 9)).inMinutes, 60);
      expect(
        _out.toString(),
        contains('1 destination is still pending after 1h: play'),
      );
      expect(
        _out.toString(),
        contains('Not hearing back is not being told no'),
      );
      // Nothing was told no, so nothing is recorded as refused.
      expect(_tags('refused/*'), isEmpty);
    });

    test(
      '--wait-timeout shortens it, and the summary says what it was',
      () async {
        _answers['read-play'] = [_nothing];

        await expectLater(
          _internal([..._candidate, '--yes', '--wait-timeout', '5m']),
          throwsA(isA<EvidenceIncomplete>()),
        );

        expect(_clock.difference(DateTime.utc(2026, 11, 17, 9)).inMinutes, 5);
        expect(_out.toString(), contains('still pending after 5m'));
      },
    );

    test('a timeout shorter than one round does not sleep past it', () async {
      // The flag is there to ask for a shorter wait than the default round,
      // and sleeping the whole interval would round it back up: a
      // `--wait-timeout 30s` that takes a minute is the flag not working.
      _answers['read-play'] = [_nothing];

      await expectLater(
        _internal([..._candidate, '--yes', '--wait-timeout', '30s']),
        throwsA(isA<EvidenceIncomplete>()),
      );

      expect(_slept, [const Duration(seconds: 30)]);
      expect(_out.toString(), contains('still pending after 30s'));
    });

    test(
      'a read that cannot answer is waited through, with its reason',
      () async {
        // Not evidence about the step: an endpoint that will not answer says
        // nothing about whether the build is there, so the wait keeps looking.
        _answers['read-play'] = [
          const ReadOutput(
            exitCode: 7,
            stderr: 'curl: (6) could not resolve\n',
          ),
          _holds(2196),
        ];

        await _internal([..._candidate, '--yes']);

        expect(_out.toString(), contains('the read exited 7: curl: (6)'));
        expect(_out.toString(), contains('play  holds 2196'));
      },
    );

    test('a read that answers with something else stops the wait', () async {
      // A table defect rather than a state of the world: no amount of
      // waiting changes what the command prints.
      _answers['read-play'] = [
        const ReadOutput(exitCode: 0, stdout: '1.9.13+2196\n'),
      ];

      await expectLater(
        _internal([..._candidate, '--yes']),
        throwsA(
          isA<EvidenceWaitException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('is not a build number'),
              contains('waiting will not change'),
            ),
          ),
        ),
      );

      expect(_slept, isEmpty);
    });

    test('is narrowed by --store, like every other verb', () async {
      await _internal([..._candidate, '--yes', '--store', 'play']);

      expect(_reads.map((it) => it.first).toSet(), {'read-play'});
      expect(_spawned(), isNot(contains('notarize')));
    });
  });

  group('before anything is spent', () {
    test('a read command that will not resolve refuses first', () async {
      // The whole reason the wait is built before the dispatch: resolved at
      // the first poll instead, this arrives with fifteen builds already
      // running and nothing able to read them.
      _writeTable(_table.replaceAll('read-play {build}', 'read-play {buidl}'));

      await expectLater(
        _internal([..._candidate, '--yes']),
        throwsA(isA<StepCommandException>()),
      );

      expect(_calls, isEmpty);
      expect(_reads, isEmpty);
    });

    test('a dispatch command that will not resolve refuses first', () async {
      _writeTable(_table.replaceAll('push-stable {build}', 'push {nope}'));

      await expectLater(
        _internal([..._candidate, '--yes']),
        throwsA(isA<StepCommandException>()),
      );

      expect(_calls, isEmpty);
    });

    test('a dispatch that fails leaves nothing to wait for', () async {
      _writeTable(_table.replaceAll('push-stable {build}', 'boom'));

      await expectLater(
        _internal([..._candidate, '--yes']),
        throwsA(
          isA<PromotionRunException>().having(
            (e) => e.message,
            'message',
            contains('nothing to wait for'),
          ),
        ),
      );

      expect(_reads, isEmpty);
      expect(_spawned(), isNot(contains('notarize')));
    });

    test('the confirmation names what the push makes public', () async {
      // §3's one requirement of this prompt: for `web`, `packagecloud` and
      // the snap on `edge`, `internal` reaches users, and a verb whose help
      // says "testers have it" must not hide that.
      final console = _Agrees();

      await _internal(_candidate, console: console);

      expect(console.asked, ['Go ahead?']);
      expect(
        _out.toString(),
        stringContainsInOrder([
          'About to start build 2196 of 1.9.13 going:',
          'dispatch  push-stable 2196',
          'direct:macos  (run, here)',
          'then wait up to 1h for play, web',
          'web is public at internal',
        ]),
      );
    });

    test('it names only the rows this run touches', () async {
      final console = _Agrees();

      await _internal([..._candidate, '--store', 'play'], console: console);

      expect(_out.toString(), isNot(contains('public at internal')));
    });

    test('a no stops it with nothing spent', () async {
      await expectLater(
        _internal(_candidate, console: _Declines()),
        throwsA(isA<PromotionRunException>()),
      );

      expect(_spawned(), ['pre-build']);
      expect(_reads, isEmpty);
    });

    test('off a terminal and without --yes it stops too', () async {
      await expectLater(
        _internal(_candidate),
        throwsA(
          isA<PromotionRunException>().having(
            (e) => e.message,
            'message',
            contains('--yes'),
          ),
        ),
      );

      expect(_spawned(), ['pre-build']);
    });

    test('the walk does not ask a second time', () async {
      // The one confirmation covered the lane as well, and a second question
      // about a decision already made can only be answered by saying yes
      // again.
      final console = _Agrees();

      await _internal(_candidate, console: console);

      expect(console.asked, hasLength(1));
      expect(_spawned(), contains('notarize'));
    });
  });

  group('--dry-run', () {
    test('runs the gates, dispatches nothing, and looks once', () async {
      _answers['read-play'] = [_nothing];

      // **A dry run leaves both lanes unfinished**, so the walk is what
      // throws: every step it printed is `wouldAct`, which is not finished.
      // Either exception is the same exit code, and both reports have already
      // been rendered by then — the next case is about the wait's half.
      await expectLater(
        _internal([..._candidate, '--dry-run']),
        throwsA(isA<PromotionIncomplete>()),
      );

      expect(_spawned(), ['pre-build']);
      expect(_slept, isEmpty);
      expect(_reads.map((it) => it.first), ['read-play', 'read-web']);
      expect(
        _out.toString(),
        stringContainsInOrder([
          'would dispatch  push-stable 2196',
          'would run  notarize 2196',
          'play  pending',
          'Nothing was dispatched, so this is one look at each',
        ]),
      );
    });

    test(
      'finds the build already there and says so, without dispatching',
      () async {
        // **A read answers about now**, so a dry run that sees 2196 at every
        // waiting destination has found the stage complete, and exits 0 about
        // it. The first draft had the wait report `!dryRun && …`, which said
        // no about a stage that plainly was — the false negative the walk's
        // own `complete` lost a commit earlier, rediscovered here by driving
        // the real verb twice.
        //
        // Narrowed to the waiting rows: the local lane *would act*, which is
        // incomplete for the ordinary reason and would be the verdict the run
        // ended on.
        await _internal([
          ..._candidate,
          '--dry-run',
          '--store',
          'play',
          '--store',
          'web',
        ]);

        // `observed`, in a dry run, and that is the honest mark: the read
        // really did see 2196 there.
        expect(_out.toString(), contains('play  observed'));
        expect(_out.toString(), contains('web   observed'));
        expect(
          _out.toString(),
          contains('holds build 2196, and nothing had to be dispatched'),
        );
        expect(_calls.map((it) => it.first), isNot(contains('push-stable')));
        expect(_tags('promoted/*'), isEmpty);
      },
    );
  });

  group('--wait-timeout', () {
    test('takes a number with a unit', () async {
      for (final spelling in ['90s', '45m', '2h']) {
        _writeTable(_table);
        _answers['read-play'] = [_holds(2196)];
        await _internal([..._candidate, '--yes', '--wait-timeout', spelling]);
      }
    });

    test('refuses a bare number rather than guessing minutes', () async {
      // "60" is as likely to mean a minute as an hour, and the one thing a
      // timeout must not be is sixty times what somebody meant.
      await expectLater(
        _internal([..._candidate, '--yes', '--wait-timeout', '60']),
        throwsA(
          isA<UsageException>().having(
            (e) => e.message,
            'message',
            contains('number with a unit'),
          ),
        ),
      );
    });

    test('refuses zero, which is --dry-run written another way', () async {
      await expectLater(
        _internal([..._candidate, '--yes', '--wait-timeout', '0m']),
        throwsA(
          isA<UsageException>().having(
            (e) => e.message,
            'message',
            contains('--dry-run'),
          ),
        ),
      );
    });
  });

  group('a table without the two new keys', () {
    const plain = '''
destinations:
  play:
    internal: {kind: ship, command: "ship play {build}"}
''';

    test(
      'is the donor\'s shape: a walk, with nothing to dispatch or wait for',
      () async {
        _writeTable(plain);

        await _internal([..._candidate, '--yes']);

        expect(_spawned(), ['ship']);
        expect(_reads, isEmpty);
        expect(_tags('promoted/play/*'), [
          'promoted/play/internal/v1.9.13+2196',
        ]);
      },
    );
  });
}
