/// Waiting for destinations somebody else is filling, and saying what turned
/// up.
///
/// **This is §5's remote lane.** AuthPass's `internal` pushes one branch and
/// then fifteen destinations are built and uploaded by CI, on machines this
/// process cannot see. The train's part afterwards is not to act but to read:
/// each `wait` row's `read` command is run until it answers with the candidate
/// build, or the clock runs out.
///
/// **Nothing here is recorded, and that is the point rather than an
/// omission.** §6.2 keeps *observed* and *attested* apart — a read says the
/// destination holds the build, a `promoted/` tag says somebody claims to have
/// put it there — and writing a record for something this process merely saw
/// would turn the stronger evidence into the weaker one on the way past. It
/// also makes a re-run free: the reads answer at once for everything that
/// already arrived, so `internal` resumes by looking rather than by
/// remembering.
///
/// **The timeout is not optional, because the failure signal is.** §3: without
/// `gh` there is no way to observe "its CI job has failed", so for a
/// destination whose build failed the only exit is the clock. That is why
/// there is no failed outcome here — [EvidenceMark.failed] exists for a step
/// that ran and did not land, and a wait that expired is not evidence of
/// anything. A timed-out row is `pending`, said out loud in the summary, so
/// that not hearing back is never read as a quiet success.
library;

import 'dart:io';

import 'destinations.dart';
import 'evidence.dart' show EvidenceMark;
import 'step_command.dart';

/// What a read command answered.
class ReadOutput {
  const ReadOutput({
    required this.exitCode,
    this.stdout = '',
    this.stderr = '',
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

/// Runs [argv] and captures what it said.
///
/// **Captured, where a step's spawn inherits.** A step is an upload whose own
/// output the operator wants; a read is a question whose answer is the
/// program's, and a read that printed to the terminal would put a bare number
/// in the release log every minute for an hour.
typedef ReadSpawn =
    Future<ReadOutput> Function(
      List<String> argv, {
      required String workingDirectory,
    });

/// The real read: a child process, captured.
Future<ReadOutput> readByRunning(
  List<String> argv, {
  required String workingDirectory,
}) async {
  final result = await Process.run(
    argv.first,
    argv.skip(1).toList(),
    workingDirectory: workingDirectory,
  );
  return ReadOutput(
    exitCode: result.exitCode,
    stdout: '${result.stdout}',
    stderr: '${result.stderr}',
  );
}

/// A read this package will not make sense of.
///
/// **It ends the wait rather than being carried as one row's note**, which is
/// the opposite of how an unreadable destination is treated, and the
/// difference is where the mistake is. An endpoint that times out is a state
/// of the world and waiting is the right response; a read command that prints
/// something other than a build number is a table defect, and no amount of
/// waiting changes what it prints.
class EvidenceWaitException implements Exception {
  EvidenceWaitException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A wait that ended with something still outstanding.
///
/// Carries the report it ended with, which has already been rendered — the
/// exception exists to turn that into an exit code, exactly as
/// `PromotionIncomplete` does for a walk.
class EvidenceIncomplete implements Exception {
  EvidenceIncomplete(this.report);

  final WaitReport report;

  @override
  String toString() =>
      '${report.outstanding.length} destination(s) were still pending when '
      'the wait ended';
}

/// What one destination's wait came to.
///
/// **Two outcomes, which are §6.2's two marks for a read, and a dry run uses
/// the same pair.** There was a third here — `looked`, for a dry run's one
/// round — and it was a word for an activity sitting among words for evidence:
/// a dry run that *sees* the build has observed it, as truly as a wait that
/// sat for an hour, and one that does not has no evidence either way. What is
/// different about a dry run belongs to the run rather than to the row, and it
/// is said once, in [WaitReport.complete] and in the verdict.
enum WaitOutcome {
  /// It answered with the candidate build.
  observed('observed'),

  /// It did not, before the wait ended. §6.2's `pending`: no evidence either
  /// way, which is what a dispatched build whose wait expired has produced.
  pending('pending');

  const WaitOutcome(this.summary);

  final String summary;

  /// Whether this destination is settled for this build.
  bool get arrived => this == observed;
}

/// One destination's row in the wait.
class WaitedDestination {
  const WaitedDestination({
    required this.name,
    required this.outcome,
    this.build,
    this.note,
  });

  final String name;
  final WaitOutcome outcome;

  /// The build the last read saw, where it saw one. **Not always the
  /// candidate** — a destination still holding the previous release is the
  /// ordinary state of a wait that has not finished, and naming it is how the
  /// operator tells "nothing yet" from "something, and not this".
  final int? build;

  /// Why this row is what it is: the older build, the read's own error, or
  /// that the destination is empty so far.
  final String? note;
}

/// What a whole wait came to.
class WaitReport {
  WaitReport({
    required this.version,
    required this.build,
    required List<WaitedDestination> destinations,
    required this.timeout,
    required this.elapsed,
    required this.dryRun,
  }) : destinations = List.unmodifiable(destinations);

  final String version;
  final int build;
  final List<WaitedDestination> destinations;
  final Duration timeout;
  final Duration elapsed;
  final bool dryRun;

  /// Whether every destination this wait covers holds the candidate.
  ///
  /// **There was a `!dryRun &&` here and it was the same bug twice.** The
  /// argument for it was that a dry run dispatches nothing, so what it found
  /// is the state before this release — and that is simply not what a read
  /// answers. A dry run that reads 2196 at every destination has found the
  /// build *there*, and saying the stage is not complete about a stage that
  /// plainly is, is the false negative `RunReport.complete` removed for the
  /// same reason a commit earlier: the term only ever changed the one case
  /// where the answer was already right.
  ///
  /// A dry run with anything outstanding is incomplete without it, because a
  /// row nothing has reached is [WaitOutcome.pending] either way.
  bool get complete => destinations.every((it) => it.outcome.arrived);

  List<WaitedDestination> get outstanding => [
    for (final it in destinations)
      if (!it.outcome.arrived) it,
  ];

  String render() {
    final lines = <String>[
      '',
      '$version — build $build — internal — the remote lane'
          '${dryRun ? ' — dry run, nothing was dispatched' : ''}',
      '',
    ];
    final widest = destinations.fold<int>(
      0,
      (widest, it) => it.name.length > widest ? it.name.length : widest,
    );
    for (final it in destinations) {
      final note = it.note == null ? '' : '  — ${it.note}';
      lines.add('  ${it.name.padRight(widest)}  ${it.outcome.summary}$note');
    }
    lines
      ..add('')
      ..add(_verdict());
    return '${lines.join('\n')}\n';
  }

  String _verdict() {
    // **Complete is asked first, and a dry run reaches it**, which is the
    // ordering `RunReport._verdict` settled: a dry run that found the build
    // everywhere has nothing to tell the operator to run again, and the
    // sentence about this invocation would be answering a question nobody
    // asked.
    if (complete) {
      return 'Every destination this run waits on holds build $build'
          '${dryRun ? ', and nothing had to be dispatched' : ''}.';
    }
    if (dryRun) {
      return 'Nothing was dispatched, so this is one look at each rather than '
          'a wait: it says where these destinations stand now. Run it again '
          'without --dry-run to dispatch and wait.';
    }
    final names = outstanding.map((it) => it.name).join(', ');
    final count = outstanding.length == 1
        ? '1 destination is'
        : '${outstanding.length} destinations are';
    // **"Still pending after 1h" is §3's own sentence**, and the reason it is
    // worded as the clock running out rather than as a failure: nothing here
    // was told no. A build that will never arrive and one that arrives a
    // minute from now produce the same row, so the run says what it waited
    // for and leaves the reading to somebody who can look at CI.
    return '$count still pending after ${describeDuration(timeout)}: $names. '
        'Not hearing back is not being told no — the builds may still be '
        'running. Run internal again to look once more, or go and see why '
        'they are not there.';
  }
}

/// `1h`, `90m`, `30s` — the shortest honest spelling, for a message.
String describeDuration(Duration duration) {
  if (duration.inSeconds % 3600 == 0 && duration.inHours >= 1) {
    return '${duration.inHours}h';
  }
  if (duration.inSeconds % 60 == 0 && duration.inMinutes >= 1) {
    return '${duration.inMinutes}m';
  }
  return '${duration.inSeconds}s';
}

/// How often the wait looks again, when nothing says otherwise.
const Duration defaultPollInterval = Duration(seconds: 60);

/// One run of the remote lane: read every `wait` destination until each holds
/// the candidate, or the clock runs out.
class EvidenceWait {
  /// **Constructing it resolves every read command**, so a `{typo}` or a
  /// `cmd && other` in one of them refuses here. `internal` builds the wait
  /// before it dispatches, which is what makes that refusal free: resolved at
  /// the first poll instead, it would arrive after the push, with the build
  /// already running and nothing able to read it.
  EvidenceWait({
    required List<Destination> destinations,
    required this.build,
    required this.version,
    required this.root,
    required this.output,
    required this.timeout,
    this.interval = defaultPollInterval,
    this.dryRun = false,
    ReadSpawn? read,
    Future<void> Function(Duration)? sleep,
    DateTime Function()? now,
  }) : destinations = List.unmodifiable(destinations),
       read = read ?? readByRunning,
       sleep = sleep ?? _realSleep,
       now = now ?? DateTime.now,
       _argv = {
         for (final destination in destinations)
           destination.name: _resolveRead(destination, version, build),
       };

  final List<Destination> destinations;
  final int build;
  final String version;
  final String root;
  final StringSink output;
  final Duration timeout;
  final Duration interval;
  final bool dryRun;
  final ReadSpawn read;
  final Future<void> Function(Duration) sleep;
  final DateTime Function() now;

  final Map<String, List<String>> _argv;

  static Future<void> _realSleep(Duration duration) =>
      Future<void>.delayed(duration);

  static List<String> _resolveRead(
    Destination destination,
    String version,
    int build,
  ) {
    final command = destination.read;
    if (command == null) {
      // The table parser refuses a `wait` row with no `read`, so reaching
      // this means a caller built the wait over a destination the parser
      // would not have given it.
      throw StateError(
        '${destination.name} has no `read`, so there is nothing to wait for',
      );
    }
    return resolveStepCommand(
      command,
      values: {
        'version': version,
        'build': '$build',
        'destination': destination.name,
        'stage': Stage.internal.name,
      },
      where: '${destination.name}.read',
    );
  }

  /// The command [destination] is read with, resolved.
  List<String> argvFor(String destination) => _argv[destination]!;

  /// A name padded to the width of the widest, so the progress lines line up
  /// with each other and with the report's rows.
  String _padded(String name) => name.padRight(
    destinations.fold<int>(
      0,
      (widest, it) => it.name.length > widest ? it.name.length : widest,
    ),
  );

  Future<WaitReport> perform() async {
    final started = now();
    final latest = <String, WaitedDestination>{};

    // **A line saying what is about to happen, because the first thing the
    // operator sees otherwise is a bare destination name.** A real run put
    // `play  nothing there yet` directly under the walk's closing verdict,
    // where it reads as part of the walk.
    final names = destinations.map((it) => it.name).join(', ');
    output.write(
      dryRun
          ? '\nlooking once at $names — nothing was dispatched\n'
          : '\nwaiting for $names — up to ${describeDuration(timeout)}\n',
    );

    while (true) {
      for (final destination in destinations) {
        if (latest[destination.name]?.outcome.arrived ?? false) {
          continue;
        }
        final before = latest[destination.name];
        final look = await _look(destination);
        latest[destination.name] = look;
        // **Only changes are printed, and an arrival always is.** An hour of
        // "snap: nothing there yet" every minute is a log nobody reads, and
        // the line that matters — the moment a destination turned up — is in
        // the middle of it.
        if (look.outcome.arrived) {
          output.write('  ${_padded(destination.name)}  holds $build\n');
        } else if (before == null || before.note != look.note) {
          output.write('  ${_padded(destination.name)}  ${look.note}\n');
        }
      }

      final outstanding = [
        for (final destination in destinations)
          if (!(latest[destination.name]?.outcome.arrived ?? false))
            destination.name,
      ];
      if (outstanding.isEmpty || dryRun) {
        break;
      }
      final elapsed = now().difference(started);
      if (elapsed >= timeout) {
        break;
      }
      output.write(
        '  waiting on ${outstanding.length}: ${outstanding.join(', ')} — '
        '${describeDuration(elapsed)} elapsed of '
        '${describeDuration(timeout)}\n',
      );
      // **Never sleep past the deadline.** With the interval a minute and
      // `--wait-timeout 30s`, sleeping the whole interval would make the
      // shortest wait somebody can ask for twice as long as the default
      // round — and the flag exists to be shorter than the default, not to be
      // rounded up to it.
      final remaining = timeout - elapsed;
      await sleep(remaining < interval ? remaining : interval);
    }

    return WaitReport(
      version: version,
      build: build,
      destinations: [
        for (final destination in destinations) latest[destination.name]!,
      ],
      timeout: timeout,
      elapsed: now().difference(started),
      dryRun: dryRun,
    );
  }

  /// One read of one destination.
  Future<WaitedDestination> _look(Destination destination) async {
    final argv = _argv[destination.name]!;
    final ReadOutput answer;
    try {
      answer = await read(argv, workingDirectory: root);
    } on ProcessException catch (error) {
      // **The same shape as an endpoint that will not answer**, and a reason
      // to keep looking rather than to stop: a read command that is not there
      // yet — a script on a volume that has not mounted, a tool being
      // installed — is a state of the machine, and the next poll may well
      // find it.
      return _notYet(
        destination,
        'could not start `${argv.first}`: ${error.message}',
      );
    }
    if (answer.exitCode != 0) {
      final said = _firstLine(answer.stderr);
      return _notYet(
        destination,
        'the read exited ${answer.exitCode}${said == null ? '' : ': $said'}',
      );
    }

    final said = answer.stdout.trim();
    if (said.isEmpty) {
      return _notYet(destination, 'nothing there yet');
    }
    final seen = _digits.hasMatch(said) ? int.tryParse(said) : null;
    if (seen == null) {
      throw EvidenceWaitException(
        '${destination.name}: `${argv.join(' ')}` exited 0 and printed '
        '`${_firstLine(said)}`, which is not a build number. A read answers '
        'with one number, or with nothing at all if the destination has no '
        'build yet — waiting will not change what this prints, so the wait '
        'stopped here.',
      );
    }
    if (seen != build) {
      // **The older build is named, not reduced to "no".** It is the
      // difference between a destination that has never had a release and one
      // that is a release behind, which is the thing §3 says is worth seeing.
      return WaitedDestination(
        name: destination.name,
        outcome: WaitOutcome.pending,
        build: seen,
        note: 'holds $seen',
      );
    }
    return WaitedDestination(
      name: destination.name,
      outcome: WaitOutcome.observed,
      build: seen,
    );
  }

  WaitedDestination _notYet(Destination destination, String note) =>
      WaitedDestination(
        name: destination.name,
        outcome: WaitOutcome.pending,
        note: note,
      );

  static final _digits = RegExp(r'^[0-9]+$');

  static String? _firstLine(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final newline = trimmed.indexOf('\n');
    return newline < 0 ? trimmed : '${trimmed.substring(0, newline)}…';
  }
}
