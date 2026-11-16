// What the first verb that spends something actually does, and — more of
// these — what it refuses to write down.
//
// **The table is §3's `beta` shape**: two destinations a command ships to, one
// console a person uses, and one with no beta audience at all. The run is
// driven with a scripted console and a recording spawn, so every case is about
// the decision rather than about a process or a terminal.
import 'dart:io';

import 'package:cux_train/cux_train.dart';
import 'package:test/test.dart';

late Directory _root;
late Git _git;
late StringBuffer _out;

final _table = DestinationTable.parse('''
destinations:
  play:
    beta: {kind: ship, command: "ship play --track beta --build {build}"}
  appstore:ios:
    beta: {kind: ship, command: "ship appstore ios {version}"}
  huawei:
    beta: {kind: manual, console: "https://developer.huawei.com"}
  snap:
    beta: {kind: ship, command: "ship snap --channel beta"}
  web:
    beta: none
    production: {kind: run, command: "deploy.sh"}
''', source: '.cux-train.yaml');

/// A console that answers from a script, and says whether anybody is there.
class _ScriptedConsole implements OperatorConsole {
  _ScriptedConsole(this._answers, {this.attached = true, List<String?>? notes})
    : _notes = notes ?? [];

  final List<ManualAnswer?> _answers;
  final List<String?> _notes;

  @override
  final bool attached;

  /// The confirmations it was asked, so a case can assert it was not asked.
  final List<String> confirmed = [];

  bool agreeToConfirm = true;

  @override
  ManualAnswer? ask() => _answers.isEmpty ? null : _answers.removeAt(0);

  @override
  String? askNote() => _notes.isEmpty ? null : _notes.removeAt(0);

  @override
  bool? confirm(String question) {
    confirmed.add(question);
    return agreeToConfirm;
  }
}

/// Records what would have been spawned and answers a scripted exit code.
class _Spawns {
  _Spawns({this.exitCodes = const {}});

  /// Exit code per first-argument-after-the-program, defaulting to 0.
  final Map<String, int> exitCodes;
  final List<List<String>> calls = [];

  Future<int> call(
    List<String> argv, {
    required String workingDirectory,
  }) async {
    calls.add(argv);
    return exitCodes[argv.length > 1 ? argv[1] : argv.first] ?? 0;
  }
}

String _commit() {
  File('${_root.path}/file.txt').writeAsStringSync('built');
  _git.run(['add', '-A']);
  _git.run(['commit', '-q', '-m', 'built']);
  return _git.run(['rev-parse', 'HEAD']);
}

/// Every promotion ref now in the repository, which is what was written.
List<String> _written() => _git
    .run(['tag', '-l', 'promoted/*', 'refused/*'])
    .split('\n')
    .where((line) => line.trim().isNotEmpty)
    .map((line) => line.trim())
    .toList();

Future<RunReport> _run({
  OperatorConsole? console,
  _Spawns? spawns,
  List<String> store = const [],
  bool dryRun = false,
  bool yes = true,
  List<String> already = const [],
  DestinationTable? table,
  String uploadedTag = 'uploaded/v1.9.13+2196',
}) async {
  for (final ref in already) {
    _git.run(['tag', ref]);
  }
  final selection = resolveStores(
    table: table ?? _table,
    names: store,
    stage: Stage.beta,
  );
  final run = PromotionRun(
    selection: selection,
    ledger: PromotionLedger.forBuild(
      _git
          .run(['tag', '-l', 'promoted/*', 'refused/*'])
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .map((line) => line.trim())
          .toList(),
      build: 2196,
      version: '1.9.13',
      source: 'git tag',
    ),
    stage: Stage.beta,
    build: 2196,
    version: '1.9.13',
    root: _root.path,
    uploadedTag: uploadedTag,
    git: _git,
    output: _out,
    console: console ?? _ScriptedConsole([]),
    dryRun: dryRun,
    yes: yes,
    spawn: (spawns ?? _Spawns()).call,
    push: false,
  );
  return run.perform();
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('cux_train_promotion_run');
    _git = Git(_root.path);
    _git.run(['init', '-q', '-b', 'main']);
    _git.run(['config', 'user.email', 'test@example.com']);
    _git.run(['config', 'user.name', 'Test']);
    final built = _commit();
    _git.run([
      'tag',
      '-a',
      'uploaded/v1.9.13+2196',
      built,
      '-m',
      'build 2196 of 1.9.13',
    ]);
    _out = StringBuffer();
  });

  tearDown(() => _root.deleteSync(recursive: true));

  group('a step that spawns', () {
    test('spawns the resolved command and records the hand-over', () async {
      final spawns = _Spawns();
      final report = await _run(spawns: spawns, store: ['play']);

      expect(spawns.calls.single, [
        'ship',
        'play',
        '--track',
        'beta',
        '--build',
        '2196',
      ]);
      expect(_written(), ['promoted/play/beta/v1.9.13+2196']);
      expect(report.complete, isTrue);
    });

    test('a command that fails records nothing at all', () async {
      // **The decision this file exists to hold.** A `refused/` tag would be
      // the obvious thing to write, and nothing in this package ever clears
      // one — `recordFor` lets a refusal beat a later hand-over — so a tag
      // written for a network blip would mark the destination refused for the
      // life of the build. A failed command is an incident, not a verdict.
      final spawns = _Spawns(exitCodes: {'play': 1});
      final report = await _run(spawns: spawns, store: ['play']);

      expect(_written(), isEmpty);
      expect(report.steps.single.outcome, StepOutcome.failed);
      expect(report.complete, isFalse);
    });

    test('a failure leaves the destination for the next run', () async {
      await _run(
        spawns: _Spawns(exitCodes: {'play': 1}),
        store: ['play'],
      );
      // Nothing was recorded, so a second run has it outstanding again.
      final spawns = _Spawns();
      final report = await _run(spawns: spawns, store: ['play']);

      expect(spawns.calls, hasLength(1));
      expect(report.complete, isTrue);
    });

    test('one failing destination does not stop the others', () async {
      // §3's rule, stated for stores: "a store refusing does not stop the
      // others". A loop that broke here would make the order of the table
      // decide how much of a release happened.
      final spawns = _Spawns(exitCodes: {'play': 1});
      final report = await _run(
        spawns: spawns,
        store: ['play', 'appstore:ios'],
      );

      expect(spawns.calls, hasLength(2));
      expect(_written(), ['promoted/appstore/ios/beta/v1.9.13+2196']);
      expect(report.steps.map((it) => it.outcome), [
        StepOutcome.failed,
        StepOutcome.handedOver,
      ]);
    });

    test('a command that cannot be started is a failure, and the run goes '
        'on', () async {
      // A program that is not on the path never answers an exit code at all:
      // `Process.start` throws. That is one destination's bad luck, exactly
      // as a non-zero exit is, and it used to end the run as a stack trace.
      final calls = <List<String>>[];
      final selection = resolveStores(
        table: _table,
        names: ['play', 'appstore:ios'],
        stage: Stage.beta,
      );
      final report = await PromotionRun(
        selection: selection,
        ledger: PromotionLedger(const []),
        stage: Stage.beta,
        build: 2196,
        version: '1.9.13',
        root: _root.path,
        uploadedTag: 'uploaded/v1.9.13+2196',
        git: _git,
        output: _out,
        console: _ScriptedConsole([]),
        yes: true,
        spawn: (argv, {required workingDirectory}) async {
          calls.add(argv);
          if (argv[1] == 'play') {
            throw ProcessException(
              argv.first,
              argv.skip(1).toList(),
              'No such file or directory',
              2,
            );
          }
          return 0;
        },
        push: false,
      ).perform();

      expect(calls, hasLength(2));
      expect(_written(), ['promoted/appstore/ios/beta/v1.9.13+2196']);
      expect(report.steps.first.outcome, StepOutcome.failed);
      expect(report.steps.first.detail, contains('could not start `ship`'));
      expect(report.steps.last.outcome, StepOutcome.handedOver);
    });

    test('the record is written for the destination the table names', () async {
      // `appstore:ios` cannot go into a ref with its colon, and the slash it
      // becomes is why `PromotionRecord.parse` reads from the right.
      await _run(store: ['appstore:ios']);
      expect(_written(), ['promoted/appstore/ios/beta/v1.9.13+2196']);
    });
  });

  group('a manual step', () {
    test('d records the hand-over', () async {
      final console = _ScriptedConsole([ManualAnswer.done]);
      final report = await _run(console: console, store: ['huawei']);

      expect(_written(), ['promoted/huawei/beta/v1.9.13+2196']);
      expect(report.complete, isTrue);
    });

    test('s records nothing, so the next run stops here again', () async {
      final console = _ScriptedConsole([ManualAnswer.skip]);
      final report = await _run(console: console, store: ['huawei']);

      expect(_written(), isEmpty);
      expect(report.steps.single.outcome, StepOutcome.leftUnrecorded);
      expect(report.complete, isFalse);
    });

    test(
      'f with a reason records the refusal under its own namespace',
      () async {
        final console = _ScriptedConsole(
          [ManualAnswer.failed],
          notes: ['64-bit libs missing from the apk'],
        );
        final report = await _run(console: console, store: ['huawei']);

        expect(_written(), ['refused/huawei/beta/v1.9.13+2196']);
        expect(report.steps.single.detail, '64-bit libs missing from the apk');
        // A refusal is outstanding, which is what makes `f` a retry rather than
        // a tombstone.
        expect(report.complete, isFalse);
      },
    );

    test(
      'f with no reason records nothing, rather than failing the run',
      () async {
        // `writePromotion` refuses an unexplained refusal outright. Letting that
        // throw would lose a run that may have finished five other destinations,
        // and an operator who pressed `f` and then said nothing has told us
        // exactly what `s` means.
        final console = _ScriptedConsole([ManualAnswer.failed], notes: [null]);
        final report = await _run(console: console, store: ['huawei']);

        expect(_written(), isEmpty);
        expect(report.steps.single.outcome, StepOutcome.leftUnrecorded);
        expect(_out.toString(), contains('No reason given'));
      },
    );

    test('q ends the run and leaves the rest not reached', () async {
      // `snap` is declared after `huawei`, and the order a run walks is the
      // table's rather than the order `--store` was typed in.
      final console = _ScriptedConsole([ManualAnswer.quit]);
      final report = await _run(console: console, store: ['huawei', 'snap']);

      expect(_written(), isEmpty);
      expect(report.steps.map((it) => it.outcome), [
        StepOutcome.leftUnrecorded,
        StepOutcome.notReached,
      ]);
    });

    test('q keeps what earlier destinations recorded', () async {
      // §6.1: "`q` ends the run with everything so far kept."
      final console = _ScriptedConsole([ManualAnswer.quit]);
      await _run(console: console, store: ['play', 'huawei']);

      expect(_written(), ['promoted/play/beta/v1.9.13+2196']);
    });

    test('end of input is treated as quit, not as done', () async {
      final console = _ScriptedConsole([]);
      final report = await _run(console: console, store: ['huawei']);

      expect(_written(), isEmpty);
      expect(report.steps.single.detail, 'input ended');
    });
  });

  group('before anything is spent', () {
    test('a command that will not resolve at a later destination stops the '
        'run before the first one spawns', () async {
      // The mistake is in the second row. Found when the loop reached it,
      // `play` had already been handed the build by then.
      final spawns = _Spawns();

      await expectLater(
        _run(
          spawns: spawns,
          table: DestinationTable.parse('''
destinations:
  play:
    beta: {kind: ship, command: "ship play"}
  snap:
    beta: {kind: ship, command: "ship snap {artifact}"}
''', source: '.cux-train.yaml'),
        ),
        throwsA(
          isA<StepCommandException>().having(
            (e) => e.message,
            'message',
            contains('snap.beta.command'),
          ),
        ),
      );
      expect(spawns.calls, isEmpty);
      expect(_written(), isEmpty);
    });

    test(
      'a missing uploaded tag stops the run before anything spawns',
      () async {
        // The record is written after the command succeeds, so a tag that is
        // not in this checkout used to be discovered with the build already
        // promoted at the first store and nothing saying so.
        final spawns = _Spawns();

        await expectLater(
          _run(
            spawns: spawns,
            store: ['play'],
            uploadedTag: 'uploaded/v1.9.13+9999',
          ),
          throwsA(
            isA<PromotionWriteException>().having(
              (e) => e.message,
              'message',
              contains('uploaded/v1.9.13+9999'),
            ),
          ),
        );
        expect(spawns.calls, isEmpty);
      },
    );

    test(
      'a dry run is refused for the same reasons the run would be',
      () async {
        await expectLater(
          _run(
            store: ['play'],
            dryRun: true,
            uploadedTag: 'uploaded/v1.9.13+9999',
          ),
          throwsA(isA<PromotionWriteException>()),
        );
      },
    );
  });

  group('--yes', () {
    test('does not answer a manual step', () async {
      // §6.1 in one line: `--yes` means "do not ask me before doing what you
      // were going to do", and the train was never going to do this one. A
      // `--yes` that recorded a console hand-over would be the tool asserting
      // a person did something.
      final console = _ScriptedConsole([ManualAnswer.skip]);
      await _run(console: console, store: ['huawei'], yes: true);

      expect(_written(), isEmpty);
    });

    test('skips the confirmation before the destinations that spawn', () async {
      final console = _ScriptedConsole([]);
      await _run(console: console, store: ['play'], yes: true);

      expect(console.confirmed, isEmpty);
    });
  });

  group('off a terminal', () {
    test('a manual destination is pending and nothing is recorded', () async {
      final console = _ScriptedConsole([ManualAnswer.done], attached: false);
      final report = await _run(console: console, store: ['huawei']);

      expect(_written(), isEmpty);
      expect(report.steps.single.outcome, StepOutcome.pending);
    });

    test('everything else is still done', () async {
      // §6.1: reported as pending "and the run exits non-zero having done
      // everything else". A run that stopped at the first manual row would
      // make an unattended beta worth nothing.
      final console = _ScriptedConsole([], attached: false);
      final report = await _run(
        console: console,
        store: ['huawei', 'play'],
        yes: true,
      );

      expect(_written(), ['promoted/play/beta/v1.9.13+2196']);
      expect(report.complete, isFalse);
    });
  });

  group('the confirmation', () {
    test('is asked once before anything is spent', () async {
      final console = _ScriptedConsole([]);
      await _run(console: console, store: ['play'], yes: false);

      expect(console.confirmed, hasLength(1));
    });

    test('declining spends nothing', () async {
      final console = _ScriptedConsole([])..agreeToConfirm = false;
      final spawns = _Spawns();

      await expectLater(
        _run(console: console, spawns: spawns, store: ['play'], yes: false),
        throwsA(isA<PromotionRunException>()),
      );
      expect(spawns.calls, isEmpty);
      expect(_written(), isEmpty);
    });

    test(
      'is not asked off a terminal, where it would never be answered',
      () async {
        final console = _ScriptedConsole([], attached: false);

        await expectLater(
          _run(console: console, store: ['play'], yes: false),
          throwsA(
            isA<PromotionRunException>().having(
              (e) => e.message,
              'message',
              contains('--yes'),
            ),
          ),
        );
        expect(console.confirmed, isEmpty);
      },
    );
  });

  group('--dry-run', () {
    test('prints the command and spawns nothing', () async {
      final spawns = _Spawns();
      await _run(spawns: spawns, store: ['play'], dryRun: true);

      expect(spawns.calls, isEmpty);
      expect(_out.toString(), contains('ship play --track beta --build 2196'));
    });

    test('records nothing, and is not complete while there is work', () async {
      // Otherwise `--dry-run` is the cheapest way to a zero exit from a verb
      // whose exit code is the thing a script branches on. It holds because
      // `wouldAct` is not a finished outcome, which is where the property
      // belongs — see `complete`.
      final report = await _run(store: ['play'], dryRun: true);

      expect(_written(), isEmpty);
      expect(report.complete, isFalse);
    });

    test('is complete when there was nothing left to do', () async {
      // **The case a surviving mutation exposed.** `complete` used to carry a
      // `!dryRun`, which answered no here — about a build that is fully at
      // the stage. The exit code is read as "is this build at beta", so that
      // was a false negative, and the only case the term changed.
      final report = await _run(
        store: ['play'],
        dryRun: true,
        already: ['promoted/play/beta/v1.9.13+2196'],
      );

      expect(report.complete, isTrue);
      expect(report.render(), contains('is recorded at beta'));
      expect(report.render(), isNot(contains('Run it again')));
    });

    test('prints a manual instruction without asking anything', () async {
      final console = _ScriptedConsole([ManualAnswer.done]);
      await _run(console: console, store: ['huawei'], dryRun: true);

      expect(_out.toString(), contains('https://developer.huawei.com'));
      expect(_written(), isEmpty);
    });
  });

  group('resuming', () {
    test('a destination already recorded is not acted on again', () async {
      final spawns = _Spawns();
      final report = await _run(
        spawns: spawns,
        store: ['play'],
        already: ['promoted/play/beta/v1.9.13+2196'],
      );

      expect(spawns.calls, isEmpty);
      expect(report.complete, isTrue);
    });

    test('names what it skipped, rather than only counting it', () async {
      // Read days later by somebody who did not type the earlier run.
      await _run(
        store: ['play', 'appstore:ios'],
        already: ['promoted/play/beta/v1.9.13+2196'],
      );

      expect(_out.toString(), contains('Already recorded at beta'));
      expect(_out.toString(), contains('play'));
    });

    test('a refusal is outstanding and comes up again', () async {
      final console = _ScriptedConsole([ManualAnswer.done]);
      final report = await _run(
        console: console,
        store: ['huawei'],
        already: ['refused/huawei/beta/v1.9.13+2196'],
      );

      expect(report.steps.single.outcome, StepOutcome.handedOver);
    });
  });

  group('the report', () {
    test('names the destinations with no stage here', () async {
      final report = await _run(store: ['play', 'web'], yes: true);

      expect(report.noStageHere, ['web']);
      expect(report.render(), contains('no beta audience: web'));
    });

    test('says how to carry on when something is outstanding', () async {
      final report = await _run(
        spawns: _Spawns(exitCodes: {'play': 1}),
        store: ['play'],
      );

      expect(report.render(), contains('still outstanding'));
      expect(report.render(), contains('picks up where this stopped'));
    });
  });
}
