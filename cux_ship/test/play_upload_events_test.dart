// SPDX-License-Identifier: Apache-2.0
//
// `play upload --json`, end to end: what lands on stdout, what lands on
// stderr, and in what order.
//
// **The seam is the transport, not the API.** `play_upload_reuse_test.dart`
// hands `runPlay` a fake `AndroidPublisherApi`, which is the right shape for
// what it asks — *which calls were made* — and the wrong one here: a fake API
// never reaches googleapis' resumable uploader, so no byte ever moves and the
// progress lines this file exists for could not exist. Handing it a real
// `AndroidPublisherApi` over a fake `http.Client` runs the generated code, the
// chunking and the retry policy for real, and leaves only the network faked.
//
// **One thing is out of reach and is worth naming rather than papering
// over.** In production `_openPlay` builds the client and wraps it; here the
// test builds and wraps it, because a supplied API arrives holding a client
// nothing can get at. So the two calls `_openPlay` makes are made here in the
// same order, and what that one line of production code composes is the only
// part of this path no test can reach — it needs a service-account credential
// to get as far as.
//
// **stdout and stderr are captured separately on purpose.** The split is the
// contract: a consumer decodes stdout and shows stderr to a person, and a
// suite that concatenated them — as several older suites here do, for claims
// where the stream does not matter — could not tell the two apart and would
// pass against a build that had mixed them.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cux_ship/documents.dart';
import 'package:cux_ship/src/play/cli.dart';
import 'package:cux_ship/src/upload_events.dart';
import 'package:googleapis/androidpublisher/v3.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'cli_snapshot.dart';

/// Google Play, narrowed to the requests one upload makes.
///
/// Answers in the shapes the generated models decode: an `AppEdit` for the
/// insert and the commit, a `BundlesListResponse` for the bundle list, a
/// `Bundle` for the completed upload, and the `Track` echoed back.
class _PlayTransport extends http.BaseClient {
  _PlayTransport({this.held = const <int>[]});

  /// versionCodes Play already holds for this app, which is what decides
  /// between the transfer and the reuse.
  final List<int> held;

  /// Every request, as `METHOD path`.
  final calls = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls.add('${request.method} ${request.url.path}');
    await request.finalize().drain<void>();

    final path = request.url.path;

    http.StreamedResponse json(String body) => http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

    if (path.contains('/resumable/upload/')) {
      return http.StreamedResponse(
        const Stream<List<int>>.empty(),
        200,
        headers: {'location': 'https://upload.example/session-1'},
      );
    }
    if (request.url.host == 'upload.example') {
      final range = request.headers['content-range']!;
      final total = int.parse(range.split('/').last);
      final end = int.parse(range.split('/').first.split('-').last);
      return end + 1 < total
          ? http.StreamedResponse(const Stream<List<int>>.empty(), 308)
          : json('{"versionCode":2132}');
    }
    if (path.endsWith('/bundles')) {
      return json(
        held.isEmpty
            ? '{}'
            : '{"bundles":[${held.map((c) => '{"versionCode":$c}').join(",")}]}',
      );
    }
    if (path.endsWith(':commit') || path.endsWith('/edits')) {
      return json('{"id":"edit-1"}');
    }
    if (request.method == 'DELETE') {
      return http.StreamedResponse(const Stream<List<int>>.empty(), 204);
    }
    // tracks.update, which the caller reads nothing out of.
    return json('{"track":"internal"}');
  }
}

/// Captures a stream. `play_upload_reuse_test.dart`'s shape, twice over —
/// stdout and stderr are two different questions here.
class _Memory implements Stdout {
  final buffer = StringBuffer();

  @override
  void writeln([Object? object = '']) => buffer.writeln(object);

  @override
  void write(Object? object) => buffer.write(object);

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// What one run wrote, kept apart.
typedef _Run = ({List<String> out, String err, List<String> calls});

void main() {
  late File aab;

  setUp(() {
    final dir = Directory.systemTemp.createTempSync('cux_ship_play_events');
    addTearDown(() => dir.deleteSync(recursive: true));
    // **Two and a bit chunks, so the transfer is more than one event.** A
    // one-chunk artifact would make "a line per chunk" and "one line at the
    // end" indistinguishable.
    aab = File('${dir.path}/app.aab')
      ..writeAsBytesSync(List<int>.filled(1024 * 1024 * 2 + 4096, 7));
  });

  Future<_Run> upload({
    List<int> held = const <int>[],
    List<String> extra = const [],
  }) async {
    final args = buildPlayParser(PlayCommand.upload).parse([
      '--package',
      'design.codeux.example',
      '--aab',
      aab.path,
      '--build-number',
      '2132',
      '--version-name',
      '1.0.0',
      '--track',
      'internal',
      ...extra,
    ]);

    final out = _Memory();
    final err = _Memory();
    late _PlayTransport transport;
    await IOOverrides.runZoned(
      () async {
        transport = _PlayTransport(held: held);
        // The two calls `_openPlay` makes, in the same order — see the header.
        // Built inside the zone so that `stdout` is the captured one.
        final api = AndroidPublisherApi(
          PlayUploadEvents(stdout).observeChunks(transport),
        );
        await runPlay(PlayCommand.upload, args, androidPublisher: api);
      },
      stdout: () => out,
      stderr: () => err,
    );
    await out.close();
    await err.close();

    return (
      out: const LineSplitter().convert(out.buffer.toString()),
      err: err.buffer.toString(),
      calls: transport.calls,
    );
  }

  /// [lines] decoded, which is also an assertion that every one of them is a
  /// whole document of the published kind.
  List<PlayUploadEvent> events(List<String> lines) => [
    for (final line in lines)
      PlayUploadEvent.fromJson(jsonDecode(line) as Map<String, dynamic>),
  ];

  group('the two streams stay apart', () {
    test('stdout is events and nothing else', () async {
      final run = await upload(extra: ['--json']);

      // Not "it parses" — every line parses, which is the claim. One
      // unparseable line makes the whole stream unusable to a consumer
      // reading it line by line, and a check over the first line would miss
      // exactly the case that happens: a `==>` line in the middle.
      expect(run.out, isNotEmpty);
      for (final line in run.out) {
        expect(
          () => jsonDecode(line),
          returnsNormally,
          reason: 'stdout carried prose: $line',
        );
      }
      expect(events(run.out), isNotEmpty);
    });

    test('and stderr still carries the whole human log', () async {
      // **Not merely "stderr is non-empty".** The point of moving rather than
      // suppressing is that the log a person reads after a failure is the same
      // log as before, so the lines are named.
      final run = await upload(extra: ['--json']);

      expect(run.err, contains('==> opened edit edit-1'));
      expect(run.err, contains('==> uploading'));
      expect(run.err, contains('==> Play accepted versionCode 2132'));
      expect(run.err, contains('==> committed'));
    });

    test('and without --json nothing changes at all', () async {
      // The other half: the split must be the flag's doing. Without this, a
      // build that always wrote the log to stderr would satisfy the case
      // above and would have broken every existing caller.
      final run = await upload();

      expect(run.out.join('\n'), contains('==> opened edit edit-1'));
      expect(run.out.join('\n'), contains('==> committed'));
      expect(run.err, isEmpty);
    });
  });

  group('the states an upload passes through', () {
    test('in the order the upload passes through them', () async {
      final run = await upload(extra: ['--json']);
      final states = [
        for (final event in events(run.out))
          if (event.event == UploadEvent.state) event.state,
      ];

      expect(states, [
        UploadState.preparing,
        UploadState.transferring,
        UploadState.accepting,
        UploadState.committing,
      ]);
    });

    test('and the transfer says how big before it says how far', () async {
      // A consumer holding the denominator from the first line can render a
      // bar immediately; one that has to wait for the first acknowledgement
      // cannot, and on a slow link that is a minute of nothing.
      final run = await upload(extra: ['--json']);
      final transferring = events(
        run.out,
      ).firstWhere((e) => e.state == UploadState.transferring);

      expect(transferring.bytesTotal, aab.lengthSync());
      expect(events(run.out).first.bytesTotal, isNull);
    });

    test('a bundle Play already holds transfers nothing and says so', () async {
      // The reuse branch, which is reached on every re-run of a release that
      // partly landed. `transferring` must not be claimed for it — a bar that
      // fills for a transfer that never happened is worse than no bar.
      final run = await upload(held: [2132], extra: ['--json']);
      final states = [
        for (final event in events(run.out))
          if (event.event == UploadEvent.state) event.state,
      ];

      expect(states, [
        UploadState.preparing,
        UploadState.reusing,
        UploadState.committing,
      ]);
      // The load-bearing half: the states above are a claim about what did not
      // happen, and only the call log can say whether it is true.
      expect(run.calls.where((c) => c.contains('resumable')), isEmpty);
      expect(events(run.out).every((e) => e.bytesSent == null), isTrue);
    });
  });

  group('progress is bytes Play took', () {
    test('one line per chunk, ending at the artifact size', () async {
      final run = await upload(extra: ['--json']);
      final sent = [for (final event in events(run.out)) ?event.bytesSent];

      expect(sent, hasLength(3));
      expect(sent.last, aab.lengthSync());
      expect(
        events(run.out).every(
          (e) => e.bytesTotal == null || e.bytesTotal == aab.lengthSync(),
        ),
        isTrue,
      );
    });

    test('and it arrives between transferring and accepting', () async {
      // Ordering across the two emitters — the CLI writes the states, the
      // observing client writes the progress, and nothing but the order they
      // reach the sink in keeps them coherent.
      final all = events((await upload(extra: ['--json'])).out);
      final transferring = all.indexWhere(
        (e) => e.state == UploadState.transferring,
      );
      final accepting = all.indexWhere((e) => e.state == UploadState.accepting);
      final firstProgress = all.indexWhere(
        (e) => e.event == UploadEvent.progress,
      );

      expect(firstProgress, greaterThan(transferring));
      expect(firstProgress, lessThan(accepting));
    });
  });

  group('the confirmation moves too, and it is printed first of all', () {
    // **A subprocess, because the confirmation is built in `runner.dart`.**
    // `runPlay` is handed a closure; which sink that closure writes to is
    // decided one layer up, from the same `--json` flag, and nothing
    // in-process here goes through that layer. So this spawns the CLI.
    //
    // It is the *first* thing a run prints — before the edit, before any
    // credential — so a consumer's decoder meets it before it meets an event.
    // Left on stdout it would make every stream unreadable from its first
    // byte, which is the failure mode `appstore upload --dry-run --json` had
    // twice over with its own banners.
    test('--json --yes writes the summary to stderr, not stdout', () {
      final result = Process.runSync(Platform.resolvedExecutable, [
        '--enable-asserts',
        cliSnapshot,
        '--yes',
        'play',
        'upload',
        '--package',
        'design.codeux.example',
        '--aab',
        aab.path,
        '--build-number',
        '2132',
        '--version-name',
        '1.0.0',
        '--json',
      ], workingDirectory: aab.parent.path);
      final said = '${result.stdout}${result.stderr}';

      // It gets as far as the one thing a test cannot supply, which is what
      // says the summary was reached rather than skipped.
      expect(said, contains('--yes given, proceeding.'), reason: said);
      expect(
        result.stderr,
        contains('About to publish to the "internal" track'),
        reason: said,
      );
      expect(result.stdout, isEmpty, reason: said);
    });

    test('and without --json it is on stdout, exactly as before', () {
      // The other half: the move has to be the flag's doing. Without this, a
      // build that had sent every confirmation to stderr would satisfy the
      // case above and would have changed what every existing caller sees.
      final result = Process.runSync(Platform.resolvedExecutable, [
        '--enable-asserts',
        cliSnapshot,
        '--yes',
        'play',
        'upload',
        '--package',
        'design.codeux.example',
        '--aab',
        aab.path,
        '--build-number',
        '2132',
        '--version-name',
        '1.0.0',
      ], workingDirectory: aab.parent.path);

      expect(
        result.stdout,
        contains('About to publish to the "internal" track'),
      );
      expect(result.stdout, contains('--yes given, proceeding.'));
    });
  });

  group('the last line says the run finished', () {
    test('with what Play holds, not what the command line asked for', () async {
      final run = await upload(extra: ['--json']);
      final last = events(run.out).last;

      expect(last.event, UploadEvent.result);
      expect(last.result, isNotNull);
      expect(last.result!.packageName, 'design.codeux.example');
      expect(last.result!.track, 'internal');
      expect(last.result!.versionName, '1.0.0');
      expect(last.result!.versionCode, 2132);
      expect(last.result!.committed, isTrue);
      // Exactly one, so a consumer waiting for it cannot be handed two.
      expect(
        events(run.out).where((e) => e.event == UploadEvent.result),
        hasLength(1),
      );
    });

    test('a dry run transfers for real and says it committed nothing', () async {
      // **Play's dry run is not a rehearsal that sends nothing.** It opens a
      // real edit, transfers the real bundle and discards the edit, so every
      // event before the last describes something that happened — and
      // `committed` is the only thing in the stream that can say the last step
      // did not.
      final run = await upload(extra: ['--json', '--dry-run']);
      final last = events(run.out).last;

      expect(last.result!.committed, isFalse);
      expect(last.result!.versionCode, 2132);
      // Both halves, because "committed: false" is worth nothing if the run
      // also skipped the transfer it is claiming to have rehearsed.
      expect(run.calls.where((c) => c.contains('resumable')), isNotEmpty);
      expect(run.calls.where((c) => c.endsWith(':commit')), isEmpty);
      expect([
        for (final event in events(run.out))
          if (event.event == UploadEvent.state) event.state,
      ], isNot(contains(UploadState.committing)));
    });
  });
}
