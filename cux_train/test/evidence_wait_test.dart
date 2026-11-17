// The wait, away from the verb: what it resolves, what it reports, and when
// it calls a release's remote lane finished.
//
// `internal_command_test.dart` drives the loop through the verb, which is
// where the ordering lives. These are the pieces whose being wrong would be
// invisible there — a verdict that reads right and answers wrong, and a
// duration printed as 60m in one sentence and 1h in the next.
import 'package:cux_train/cux_train.dart';
import 'package:test/test.dart';

Destination _destination(String name, {String? read}) => Destination(
  name: name,
  steps: const {Stage.internal: DestinationStep(kind: StepKind.wait)},
  read: read,
);

WaitedDestination _row(
  String name,
  WaitOutcome outcome, {
  int? build,
  String? note,
}) => WaitedDestination(name: name, outcome: outcome, build: build, note: note);

WaitReport _report(
  List<WaitedDestination> rows, {
  bool dryRun = false,
  Duration timeout = const Duration(hours: 1),
}) => WaitReport(
  version: '1.9.13',
  build: 2196,
  destinations: rows,
  timeout: timeout,
  elapsed: timeout,
  dryRun: dryRun,
);

void main() {
  group('describeDuration', () {
    test('is the shortest honest spelling', () {
      expect(describeDuration(const Duration(hours: 1)), '1h');
      expect(describeDuration(const Duration(hours: 2)), '2h');
      expect(describeDuration(const Duration(minutes: 45)), '45m');
      // Not 1h, and not 1h30m either: the units stop where the message does.
      expect(describeDuration(const Duration(minutes: 90)), '90m');
      expect(describeDuration(const Duration(seconds: 90)), '90s');
      expect(describeDuration(const Duration(seconds: 30)), '30s');
    });
  });

  group('a report', () {
    test('is complete when every destination holds the candidate', () {
      expect(
        _report([
          _row('play', WaitOutcome.observed, build: 2196),
          _row('web', WaitOutcome.observed, build: 2196),
        ]).complete,
        isTrue,
      );
    });

    test('is not complete while one is pending', () {
      final report = _report([
        _row('play', WaitOutcome.observed, build: 2196),
        _row('web', WaitOutcome.pending, note: 'nothing there yet'),
      ]);

      expect(report.complete, isFalse);
      expect(report.outstanding.map((it) => it.name), ['web']);
    });

    test('is complete in a dry run too, when the build is in fact there', () {
      // **A read answers about now, not about what this invocation did.** A
      // `!dryRun &&` here would say the stage is not complete about a stage
      // that plainly is — the false negative `RunReport.complete` lost for
      // the same reason.
      final report = _report([
        _row('play', WaitOutcome.observed, build: 2196),
      ], dryRun: true);

      expect(report.complete, isTrue);
      expect(report.render(), contains('nothing had to be dispatched'));
    });

    test(
      'a dry run with anything outstanding is incomplete, as any run is',
      () {
        expect(
          _report([
            _row('play', WaitOutcome.observed, build: 2196),
            _row('web', WaitOutcome.pending, note: 'nothing there yet'),
          ], dryRun: true).complete,
          isFalse,
        );
      },
    );

    test(
      'says what it waited and how long for, and never that it was told no',
      () {
        final rendered = _report([
          _row('play', WaitOutcome.pending, build: 2195, note: 'holds 2195'),
          _row('web', WaitOutcome.observed, build: 2196),
        ]).render();

        expect(rendered, contains('1.9.13 — build 2196 — internal'));
        expect(rendered, contains('play  pending  — holds 2195'));
        expect(rendered, contains('web   observed'));
        expect(rendered, contains('1 destination is still pending after 1h'));
        expect(rendered, contains('Not hearing back is not being told no'));
        // The one thing the summary must not read as.
        expect(rendered, isNot(contains('failed')));
      },
    );

    test('counts in the plural when there is more than one', () {
      final rendered = _report([
        _row('play', WaitOutcome.pending),
        _row('web', WaitOutcome.pending),
      ], timeout: const Duration(minutes: 5)).render();

      expect(rendered, contains('2 destinations are still pending after 5m'));
    });
  });

  group('a wait', () {
    test('resolves every read command when it is built', () {
      final wait = EvidenceWait(
        destinations: [
          _destination('appstore:ios', read: 'read {destination} {build}'),
        ],
        build: 2196,
        version: '1.9.13',
        root: '.',
        output: StringBuffer(),
        timeout: const Duration(hours: 1),
      );

      expect(wait.argvFor('appstore:ios'), ['read', 'appstore:ios', '2196']);
    });

    test('refuses a read command it will not spawn, before anything waits', () {
      expect(
        () => EvidenceWait(
          destinations: [_destination('play', read: 'read {buidl}')],
          build: 2196,
          version: '1.9.13',
          root: '.',
          output: StringBuffer(),
          timeout: const Duration(hours: 1),
        ),
        throwsA(isA<StepCommandException>()),
      );
    });

    test('is a programming error over a destination with nothing to read', () {
      // The table parser refuses a `wait` row with no `read`, so reaching
      // this means a caller built a wait the parser would not have given it.
      expect(
        () => EvidenceWait(
          destinations: [_destination('play')],
          build: 2196,
          version: '1.9.13',
          root: '.',
          output: StringBuffer(),
          timeout: const Duration(hours: 1),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}
