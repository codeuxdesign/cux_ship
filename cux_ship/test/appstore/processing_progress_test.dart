// SPDX-License-Identifier: Apache-2.0
//
// `appstore wait` polls Apple for up to forty-five minutes, and until now the
// only report it made was two lines on this process's stdout. A consumer that
// streams the wait to a per-platform log with its own heartbeat could not have
// that — it had to spawn the command and read what it printed.
//
// So the wait now reports through a callback and the printing is one caller of
// it. Two things have to hold: the callback sees every poll *including the one
// that ends the wait* — a log that records only that a wait stopped is a log
// that cannot say how — and the default printing is unchanged, because it is
// what every existing release script reads.
import 'dart:io';

import 'package:cux_ship/read.dart';
import 'package:cux_ship/src/appstore/app_store.dart';
import 'package:cux_ship/src/appstore/asc_client.dart';
import 'package:test/test.dart';

Map<String, dynamic> _build(String version, String? state) => {
  'type': 'builds',
  'id': 'build-$version',
  'attributes': {'version': version, 'processingState': ?state},
};

/// Canned App Store Connect that answers a scripted sequence of polls.
///
/// **It filters by `filter[version]`, because the tested branch selects on
/// it.** `awaitProcessing` reaches its "not visible at all" state — the one a
/// rejected upload produces, and the one [ProcessingTimeout] exists for — only
/// when a lookup for a build number comes back empty, which a fake that
/// ignored the filter could never produce.
class _FakeClient implements AscClient {
  _FakeClient(this.states);

  /// One entry per poll: Apple's `processingState`, or null for a build that
  /// is not visible yet.
  final List<String?> states;

  var polls = 0;

  @override
  Future<List<Map<String, dynamic>>> getAll(
    String path, {
    Map<String, String>? query,
  }) async {
    expect(path, '/v1/builds');
    final wanted = query?['filter[version]'];
    final state = states[polls < states.length ? polls : states.length - 1];
    polls++;
    if (state == null || wanted == null) {
      return const [];
    }
    return [_build(wanted, state)];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MemoryStdout implements Stdout {
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

Future<String> _printed(Future<void> Function() body) async {
  final captured = _MemoryStdout();
  await IOOverrides.runZoned(body, stdout: () => captured);
  await captured.close();
  return captured.buffer.toString();
}

void main() {
  final app = App('app-1', 'Example', 'design.codeux.example');

  AppStore storeOf(_FakeClient client) =>
      AppStore(client, Writer(client, dryRun: true), platform: AscPlatform.ios);

  group('the callback', () {
    test(
      'sees every poll, ending with the one that finished the wait',
      () async {
        final client = _FakeClient([null, 'PROCESSING', 'VALID']);
        final seen = <BuildProcessingProgress>[];

        await storeOf(client).awaitProcessing(
          app,
          '2132',
          poll: Duration.zero,
          onProgress: seen.add,
        );

        expect(seen.map((p) => p.state), [null, 'PROCESSING', 'VALID']);
        expect(seen.last.terminal, isTrue);
        expect(seen.first.visible, isFalse);
      },
    );

    test(
      'sees the poll that failed the wait, rather than only the throw',
      () async {
        // A log that records a wait stopping without recording how is a log that
        // sends somebody back to App Store Connect to find out.
        final client = _FakeClient(['PROCESSING', 'INVALID']);
        final seen = <BuildProcessingProgress>[];

        await expectLater(
          storeOf(client).awaitProcessing(
            app,
            '2132',
            poll: Duration.zero,
            onProgress: seen.add,
          ),
          throwsA(isA<AscApiException>()),
        );

        expect(seen.map((p) => p.state), ['PROCESSING', 'INVALID']);
      },
    );

    test('carries the build number and the deadline it was given', () async {
      // Enough to write "6 of 45 minutes" without the caller keeping its own
      // clock beside the one the wait already has.
      final client = _FakeClient(['VALID']);
      final seen = <BuildProcessingProgress>[];

      await storeOf(client).awaitProcessing(
        app,
        '2132',
        timeout: const Duration(minutes: 20),
        poll: Duration.zero,
        onProgress: seen.add,
      );

      expect(seen.single.buildNumber, '2132');
      expect(seen.single.timeout, const Duration(minutes: 20));
      expect(seen.single.waited, lessThan(const Duration(minutes: 1)));
    });

    test('replaces the printing rather than adding to it', () async {
      // The point for a library caller: an in-process wait must not write to
      // the host program's stdout.
      final client = _FakeClient(['VALID']);
      final out = await _printed(
        () => storeOf(
          client,
        ).awaitProcessing(app, '2132', poll: Duration.zero, onProgress: (_) {}),
      );

      expect(out, isEmpty);
    });
  });

  group('the default printing', () {
    test('announces the wait once and says when it ended', () async {
      final client = _FakeClient(['PROCESSING', 'PROCESSING', 'VALID']);
      final out = await _printed(
        () => storeOf(client).awaitProcessing(app, '2132', poll: Duration.zero),
      );

      expect(out, '''
==> waiting for Apple to process build 2132 (usually 5–15 minutes)
==> build 2132 has finished processing
''');
    });

    test('says nothing at all when Apple refuses on the first poll', () async {
      // "waiting for Apple to process build 2132" printed immediately above a
      // throw describes something that is not about to happen.
      final client = _FakeClient(['INVALID']);

      final out = await _printed(() async {
        await expectLater(
          storeOf(client).awaitProcessing(app, '2132', poll: Duration.zero),
          throwsA(isA<AscApiException>()),
        );
      });

      expect(out, isEmpty);
    });
  });

  test(
    'a build that never appears times out naming where the answer is',
    () async {
      // Not an AscApiException: Apple answered every poll correctly, and a build
      // that never becomes visible has usually been refused by e-mail.
      final client = _FakeClient([null]);

      await expectLater(
        storeOf(client).awaitProcessing(
          app,
          '2132',
          timeout: Duration.zero,
          poll: Duration.zero,
          onProgress: (_) {},
        ),
        throwsA(
          isA<ProcessingTimeout>()
              .having((e) => e.lastState, 'lastState', isNull)
              .having((e) => e.buildNumber, 'buildNumber', '2132'),
        ),
      );
    },
  );
}
