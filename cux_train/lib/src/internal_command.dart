/// `cux_train internal` — build and upload everywhere; testers have it.
///
/// **The verb with two lanes, which is what makes it different from the other
/// three.** §5: AuthPass's CI builds and uploads fifteen of its nineteen
/// destinations, so `internal` spawns one *dispatch* — the push CI reacts to —
/// and then has nothing left to do at those rows but read them until the build
/// turns up. Beside that runs the one step no CI can take, the notarized macOS
/// build on the laptop, which is an ordinary walk of the rows that are not
/// waiting. §5 calls the two "remote lane" and "local lane" and keeps the
/// donor's two-lane shape with the lanes redrawn.
///
/// **The order here is §3's, and three of its four items are about spending
/// nothing you cannot get back.** The gates run first, before the push. The
/// confirmation comes next and names what the push makes public — for `web`,
/// `packagecloud` and the snap on `edge`, `internal` reaches users, which is a
/// fact about today's workflows rather than something the train causes, and a
/// command whose help says "testers have it" must not hide it. Only then the
/// dispatch, and only then is there anything to wait for.
///
/// **Sequential where §3 says parallel, deliberately.** §3 has the local build
/// running beside the wait; this runs it first and then waits. The difference
/// is wall-clock on one machine — the laptop is building either way — and what
/// it buys is that the wait's clock starts when the laptop is free, so a
/// fifteen-minute notarization does not come out of the hour the remote lane
/// is given. Real concurrency here would also mean two things writing to one
/// terminal, with the manual console's prompts among them.
library;

import 'dart:io';

import 'destinations.dart';
import 'evidence_wait.dart';
import 'operator_console.dart';
import 'promoting_command.dart';
import 'promotion_run.dart';
import 'step_command.dart';
import 'store_selection.dart';

/// How long the remote lane is given, when nothing says otherwise.
///
/// §3: "a default on the order of an hour". AuthPass's slowest CI lane is the
/// Windows build, and an hour covers it with room; the point of the default is
/// that the normal path never types the flag.
const Duration defaultWaitTimeout = Duration(hours: 1);

class InternalCommand extends PromotingCommand {
  InternalCommand({
    super.output,
    super.root,
    super.openGit,
    super.console,
    super.spawn,
    super.push,
    this.read,
    this.sleep,
    this.now,
    this.pollInterval = defaultPollInterval,
  }) {
    argParser.addOption(
      'wait-timeout',
      valueHelp: 'DURATION',
      defaultsTo: describeDuration(defaultWaitTimeout),
      help:
          'How long to wait for the destinations CI fills, as 90s, 45m or 2h. '
          'A destination that has not arrived by then is reported pending, '
          'which is not the same as refused.',
    );
  }

  /// How a destination is read. A test passes a recorder; null means a real
  /// child process.
  final ReadSpawn? read;

  /// How the wait sleeps between rounds, and what time it is. A test passes a
  /// clock it controls; null means the real ones.
  final Future<void> Function(Duration)? sleep;
  final DateTime Function()? now;

  /// How often the wait looks again.
  final Duration pollInterval;

  @override
  String get name => 'internal';

  @override
  String get description =>
      'Dispatch the build, perform the steps this machine owns, and wait for '
      'the destinations somebody else fills.';

  @override
  Future<void> run() async {
    refuseStrayArguments();
    final table = readTable();
    final build = candidateBuild();
    final version = candidateRelease();
    final timeout = _timeout();

    final selection = selectionFor(table, Stage.internal);
    final waiting = _waiting(selection);
    final lane = _lane(selection);

    // **Everything that can refuse does so before the dispatch**, which is the
    // one step here that cannot be taken back: the push starts fifteen builds,
    // and a `{typo}` in a read command found at the first poll would arrive
    // with them already running and nothing able to see them. Constructing the
    // wait resolves every read, resolving the dispatch resolves the push, and
    // the lane's preflight asks every refusal its own walk could make — among
    // them the one this verb cannot design away, that recording a local step
    // needs the candidate's `uploaded/` tag, which for a consumer whose
    // uploads are what the dispatch triggers is written by CI afterwards.
    final wait = waiting.isEmpty
        ? null
        : EvidenceWait(
            destinations: waiting,
            build: build,
            version: version,
            root: root,
            output: output,
            timeout: timeout,
            interval: pollInterval,
            dryRun: dryRun,
            read: read,
            sleep: sleep,
            now: now,
          );
    final dispatch = table.dispatch;
    final dispatchArgv = dispatch == null
        ? null
        : resolveStepCommand(
            dispatch.command!,
            values: {
              'version': version,
              'build': '$build',
              'stage': Stage.internal.name,
              // No `{destination}`, for the reason the dispatch is top-level
              // at all: it is the step that is not about one.
            },
            where: '`dispatch`.command',
          );
    final laneRun = lane.acting.isEmpty
        ? null
        : runFor(
            selection: lane,
            stage: Stage.internal,
            build: build,
            version: version,
            uploadedTag: uploadedTagFor(version: version, build: build),
            // **Named as a pass, for the reason `production`'s second one
            // is.** Unlabelled, this block's own verdict — every destination
            // it covers is recorded — printed directly above the rows that
            // were still pending, where it reads as the verdict on the run.
            pass: waiting.isEmpty ? null : 'the local lane',
            // The one confirmation below covers this walk too.
            alreadyConfirmed: true,
          );
    laneRun?.preflight();

    await runGates(
      table,
      selection,
      stage: Stage.internal,
      version: version,
      build: build,
    );

    if (!_confirmed(
      dispatchArgv: dispatchArgv,
      lane: lane,
      waiting: waiting,
      timeout: timeout,
      build: build,
      version: version,
    )) {
      throw PromotionRunException(
        'Stopped before anything was spent. Re-run with --yes to skip this '
        'question, or from a terminal where it can be answered.',
      );
    }

    if (dispatchArgv != null) {
      await _dispatch(dispatchArgv);
    }

    final laneReport = await laneRun?.perform();
    // The guard `production` uses for its second pass, for the same reason: a
    // lane whose every row was already recorded has nothing to show, and an
    // empty block saying every destination it covers is recorded is a block
    // about no destinations.
    if (laneReport != null &&
        (laneReport.steps.isNotEmpty || lane.skipped.isNotEmpty)) {
      output.write(laneReport.render());
    }

    final waitReport = await wait?.perform();
    if (waitReport != null) {
      output.write(waitReport.render());
    }

    // **Both halves are rendered before either is thrown about**, because the
    // exception is only an exit code — §3's rule that a failed cell does not
    // stop the others applies across the lanes as much as within one. The
    // local lane is asked first because it is the half this machine owns: a
    // notarization that failed is something to do now, where a destination
    // still pending is something to look at CI about.
    if (laneReport != null && !laneReport.complete) {
      throw PromotionIncomplete(laneReport);
    }
    if (waitReport != null && !waitReport.complete) {
      throw EvidenceIncomplete(waitReport);
    }
  }

  /// The destinations whose internal step is a `wait`, in table order.
  List<Destination> _waiting(StoreSelection selection) => [
    for (final destination in selection.acting)
      if (destination.stepAt(Stage.internal).kind == StepKind.wait) destination,
  ];

  /// The selection with the waiting destinations taken out.
  ///
  /// **Taken out rather than skipped**, because `skipped` means something
  /// else: a destination with no step at this stage, which the walk reports as
  /// having no internal step. A `wait` row has one, and it is being performed
  /// — by somebody else, in the other lane.
  StoreSelection _lane(StoreSelection selection) => StoreSelection(
    acting: [
      for (final destination in selection.acting)
        if (destination.stepAt(Stage.internal).kind != StepKind.wait)
          destination,
    ],
    skipped: selection.skipped,
    coversEveryDestination: selection.coversEveryDestination,
  );

  /// `--wait-timeout`, as a duration.
  Duration _timeout() {
    final declared = (argResults!['wait-timeout'] as String).trim();
    final match = _duration.firstMatch(declared);
    if (match == null) {
      // **A bare number is refused rather than read as minutes.** "60" is as
      // likely to mean a minute as an hour, and the one thing a timeout must
      // not do is be sixty times what somebody meant.
      usageException(
        '--wait-timeout is a number with a unit — 90s, 45m or 2h — and '
        '`$declared` is not one.',
      );
    }
    final amount = int.parse(match.group(1)!);
    if (amount == 0) {
      // Zero is a legitimate thing to want — look once, do not wait — but
      // `0h` and `0s` are the same instruction written two ways, and the verb
      // that means it is `--dry-run`.
      usageException(
        '--wait-timeout is 0, which would look once and report everything '
        'pending. --dry-run is the verb for looking without dispatching.',
      );
    }
    return switch (match.group(2)!) {
      's' => Duration(seconds: amount),
      'm' => Duration(minutes: amount),
      _ => Duration(hours: amount),
    };
  }

  static final _duration = RegExp(r'^([0-9]+)([smh])$');

  /// §3's confirmation: everything this invocation will set going, once.
  bool _confirmed({
    required List<String>? dispatchArgv,
    required StoreSelection lane,
    required List<Destination> waiting,
    required Duration timeout,
    required int build,
    required String version,
  }) {
    if (dryRun || yes) {
      return true;
    }
    output.write('\nAbout to start build $build of $version going:\n');
    if (dispatchArgv != null) {
      output.write('  dispatch  ${dispatchArgv.join(' ')}\n');
    }
    for (final destination in lane.acting) {
      output.write(
        '  ${destination.name}  '
        '(${destination.stepAt(Stage.internal).kind.name}, here)\n',
      );
    }
    if (waiting.isNotEmpty) {
      output.write(
        '  then wait up to ${describeDuration(timeout)} for '
        '${waiting.map((it) => it.name).join(', ')}\n',
      );
    }

    // **§3's one requirement of this prompt.** `web`, `packagecloud` and the
    // snap on `edge` reach users the moment the dispatch lands, so a verb
    // whose help says "testers have it" says here, where it is still a
    // question, which rows that is not true of.
    final public = [
      for (final destination in [...lane.acting, ...waiting])
        if (destination.publicAtInternal) destination.name,
    ];
    if (public.isNotEmpty) {
      output.write(
        '\n  ${public.join(', ')} ${public.length == 1 ? 'is' : 'are'} public '
        'at internal: ${public.length == 1 ? 'it reaches' : 'they reach'} '
        'everyone as soon as this lands, not just testers.\n',
      );
    }

    final asking = console ?? StdioConsole(output: output);
    if (!asking.attached) {
      return false;
    }
    return asking.confirm('Go ahead?') ?? false;
  }

  /// Spawns the dispatch, which is the step everything after it waits on.
  Future<void> _dispatch(List<String> argv) async {
    if (dryRun) {
      output.write('\nwould dispatch  ${argv.join(' ')}\n');
      return;
    }
    output.write('\ndispatch  ${argv.join(' ')}\n');
    final int code;
    try {
      code = await (spawn ?? spawnInheritingStdio)(
        argv,
        workingDirectory: root,
      );
    } on ProcessException catch (error) {
      throw PromotionRunException(
        'The dispatch could not be started — `${argv.first}`: '
        '${error.message} — so nothing was set going and there is nothing to '
        'wait for.',
      );
    }
    if (code != 0) {
      throw PromotionRunException(
        'The dispatch exited $code, so nothing was set going and there is '
        'nothing to wait for. Fix what it reported and run internal again.',
      );
    }
  }
}
