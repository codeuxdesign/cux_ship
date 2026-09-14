// SPDX-License-Identifier: Apache-2.0
//
// Byte progress, and the claim that it is the store's count rather than ours.
//
// **Driven through googleapis' real resumable uploader, not a stand-in for
// it.** `ResumableChunkObserver` reads a protocol this repository does not
// implement — one `PUT` per chunk carrying a `Content-Range`, answered `308`
// until the last — and every sentence in its doc comment is a claim about what
// that uploader does. A fake uploader would let those sentences be whatever
// this file wanted them to be. So the cases below build a real
// `AndroidPublisherApi` over a fake *transport* and call `bundles.upload` with
// `UploadOptions.resumable`: the chunking, the retry policy and the header
// spelling are all the package's own.
//
// **The chunk size is deliberately not configured in the first case.** 1 MiB
// is `ResumableUploadOptions`' default and is what a real upload uses, so it is
// also what decides how many lines a 68 MB bundle produces — the number the
// "tens of events, not thousands" requirement is actually about. A test that
// set its own would be measuring a number no run ever uses.
//
// The end-to-end suites are `play_upload_events_test.dart` and
// `appstore/upload_events_test.dart`; this one is about the signal itself.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cux_ship/documents.dart';
import 'package:cux_ship/src/upload_events.dart';
import 'package:googleapis/androidpublisher/v3.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// One mebibyte, which is `ResumableUploadOptions`' default chunk size.
const _chunk = 1024 * 1024;

/// Where the events go. An [IOSink] because that is what the emitter writes to,
/// and a list of lines because newline-delimited JSON is a list of lines.
class _Capture implements IOSink {
  final lines = <String>[];

  @override
  void writeln([Object? object = '']) => lines.add('$object');

  /// Nothing to flush — it exists so `close_sinks` can see the sink closed,
  /// which is the same shape `play_upload_reuse_test.dart` uses.
  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Play's side of the resumable protocol, and nothing else.
///
/// **It answers `308` with no `Range` header, which is what Play does and is
/// worth stating** — the offset a line reports comes from the *request's*
/// `Content-Range`, not from anything in the response. A fake that echoed a
/// range back would let a reader believe the observer parses one, and the
/// resume case below would prove nothing.
class _PlayTransport extends http.BaseClient {
  _PlayTransport({
    this.failFirstChunkWith,
    this.failFinalChunkWith,
    this.onFinalChunkRequest,
  });

  /// A status to answer the first chunk with before accepting it, or null.
  ///
  /// 500 rather than 403: the uploader retries the first family and raises on
  /// the second, and the case this exists for is a chunk that is *re-sent*.
  final int? failFirstChunkWith;

  /// The same, for the **final** chunk, which is a different case entirely.
  ///
  /// The final chunk is the one the `accepting` announcement is written
  /// before, so a retry of *this* chunk sends the request again — and the
  /// announcement with it, unless the observer holds a flag. Failing the first
  /// chunk cannot reach that: `accepting` is never written for it.
  final int? failFinalChunkWith;

  /// Every request, as `METHOD path` — so a case can say what was not sent.
  final calls = <String>[];

  /// Called as the final chunk *arrives*, before it is answered.
  ///
  /// **The only vantage point from which "before the request" is
  /// distinguishable from "after the response".** A case reading the sink
  /// afterwards sees the same order either way, because nothing else is
  /// written in between — which is exactly how a first version of the ordering
  /// case passed against a build that had moved the line.
  final void Function()? onFinalChunkRequest;

  var _failed = false;
  var _failedFinal = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls.add('${request.method} ${request.url.path}');

    // Draining the body matters: the uploader streams each chunk, and a
    // transport that never reads one leaves the source subscription paused.
    await request.finalize().drain<void>();

    if (request.method == 'POST') {
      return http.StreamedResponse(
        const Stream<List<int>>.empty(),
        200,
        headers: {'location': 'https://upload.example/session-1'},
      );
    }

    final range = request.headers['content-range']!;
    final total = int.parse(range.split('/').last);
    final end = int.parse(range.split('/').first.split('-').last);

    if (end + 1 == total) {
      onFinalChunkRequest?.call();
      if (failFinalChunkWith != null && !_failedFinal) {
        _failedFinal = true;
        return http.StreamedResponse(
          const Stream<List<int>>.empty(),
          failFinalChunkWith!,
        );
      }
    }

    if (failFirstChunkWith != null && !_failed) {
      _failed = true;
      return http.StreamedResponse(
        const Stream<List<int>>.empty(),
        failFirstChunkWith!,
      );
    }

    if (end + 1 < total) {
      return http.StreamedResponse(const Stream<List<int>>.empty(), 308);
    }
    return http.StreamedResponse(
      Stream.value(utf8.encode('{"versionCode":2132}')),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }
}

/// An artifact of [bytes], as a `Media` the uploader will chunk.
Media _artifact(int bytes) =>
    Media(Stream.value(List<int>.filled(bytes, 0)), bytes);

/// Uploads [bytes] through an observed client and returns the lines written.
Future<List<String>> _upload(
  int bytes, {
  _PlayTransport? transport,
  ResumableUploadOptions? options,
}) async {
  final capture = _Capture();
  final api = AndroidPublisherApi(
    PlayUploadEvents(capture).observeChunks(transport ?? _PlayTransport()),
  );

  await api.edits.bundles.upload(
    'design.codeux.example',
    'edit-1',
    uploadMedia: _artifact(bytes),
    uploadOptions: options ?? UploadOptions.resumable,
  );
  await capture.close();
  return capture.lines;
}

/// The `bytesSent` of every progress line in [lines], in order.
List<int> _sent(List<String> lines) => [
  for (final line in lines)
    if (PlayUploadEvent.fromJson(jsonDecode(line) as Map<String, dynamic>)
        case PlayUploadEvent(event: UploadEvent.progress, :final bytesSent?))
      bytesSent,
];

void main() {
  group('a line per chunk the store takes', () {
    test('and the offsets are the ones the protocol carried', () async {
      // Three and a half chunks, so the last one is short — which is the case
      // that separates "counted the chunks" from "read the ranges".
      final lines = await _upload(_chunk * 3 + _chunk ~/ 2);

      expect(_sent(lines), [
        _chunk,
        _chunk * 2,
        _chunk * 3,
        _chunk * 3 + _chunk ~/ 2,
      ]);
    });

    test('so a 68 MB bundle is tens of lines, not thousands', () async {
      // **The requirement, measured rather than asserted in prose.** The
      // coalescing is the protocol's 1 MiB chunk and not a threshold of ours,
      // so this is what fixes the rate — and it is the number that changes if
      // anybody ever reaches for a smaller chunk to get a smoother bar.
      final lines = await _upload(_chunk * 8);

      expect(_sent(lines), hasLength(8));
      expect(
        (68 * 1000 * 1000 / _chunk).ceil(),
        lessThan(100),
        reason: 'the same arithmetic at the size the requirement names',
      );
    });

    test('the last line is the whole artifact, never short of it', () async {
      // A bar that stops at 96% and then jumps to a state name reads as a
      // transfer that was abandoned. The final chunk is acknowledged like any
      // other, so the last number is the total.
      final bytes = _chunk * 2 + 17;
      final lines = await _upload(bytes);

      expect(_sent(lines).last, bytes);
    });
  });

  group('accepting is the wait with no bytes left to count', () {
    test('it is written before the final chunk is even sent', () async {
      // **The ordering is the claim, and it is only visible from inside the
      // request.** Play validates the artifact *inside* the response to the
      // last chunk, so a state written after that response names a wait that
      // was already over — the whole defect this state exists to fix,
      // reintroduced one line later.
      //
      // Read back from the finished stream the two orderings are identical,
      // because nothing else is written between them. The first version of
      // this case did exactly that and was green against both, which is what
      // the transport's `onFinalChunkRequest` hook is for.
      final capture = _Capture();
      late List<String> whenAsked;
      final transport = _PlayTransport(
        onFinalChunkRequest: () => whenAsked = List.of(capture.lines),
      );
      final api = AndroidPublisherApi(
        PlayUploadEvents(capture).observeChunks(transport),
      );

      await api.edits.bundles.upload(
        'design.codeux.example',
        'edit-1',
        uploadMedia: _artifact(_chunk * 2 + 1),
        uploadOptions: UploadOptions.resumable,
      );
      await capture.close();

      expect(
        jsonDecode(whenAsked.last) as Map<String, dynamic>,
        containsPair('state', 'accepting'),
        reason: 'the wait was named only after Play had already answered',
      );
      // And once, so a consumer is not told twice that the bytes are all in.
      expect(
        capture.lines.where((l) => l.contains('"accepting"')),
        hasLength(1),
      );
      expect(_sent(capture.lines).last, _chunk * 2 + 1);
    });

    test('and a retried final chunk does not announce the wait twice', () async {
      // **The case the ordering makes possible.** `accepting` is written
      // *before* the request, which is the whole point of it — and googleapis
      // answers a 5xx by sending the same final chunk again. Without a flag on
      // the observer that is two `accepting` lines for one wait, and a
      // consumer that treats a state transition as an edge sees the upload
      // re-enter a state it never left.
      //
      // **Failing the *first* chunk cannot reach this**, which is why the
      // retry case further down did not catch it: `accepting` is never written
      // for a chunk that is not the last.
      final transport = _PlayTransport(failFinalChunkWith: 500);
      final lines = await _upload(
        _chunk * 2 + 1,
        transport: transport,
        options: ResumableUploadOptions(backoffFunction: (_) => Duration.zero),
      );

      expect(
        transport.calls.where((c) => c.startsWith('PUT')),
        hasLength(4),
        reason: 'the fake must actually have been asked twice for the last one',
      );
      expect(lines.where((l) => l.contains('"accepting"')), hasLength(1));
      // And the transfer still completes, so this is not passing because the
      // upload died before a second announcement could happen.
      expect(_sent(lines).last, _chunk * 2 + 1);
    });

    test('and a one-chunk artifact still gets one', () async {
      // The smallest upload is one chunk, which is both the first and the
      // last. A condition written as "not the first" would lose it.
      final lines = await _upload(64);
      final states = [
        for (final line in lines)
          PlayUploadEvent.fromJson(
            jsonDecode(line) as Map<String, dynamic>,
          ).state,
      ];

      expect(states.where((s) => s == UploadState.accepting), hasLength(1));
    });
  });

  group('a line means the store took the bytes', () {
    test('a retried chunk is not a second line', () async {
      // The uploader re-sends a chunk the server answered 500, with the same
      // `Content-Range`. The failed attempt must contribute no line — a
      // consumer computing a rate from two lines for one megabyte reports
      // twice the throughput at the moment the transfer is going worst.
      //
      // **This is also why the observer needs no de-duplication.** googleapis
      // retries on 5xx and nothing else, so a range it re-sends is one that
      // was never acknowledged; the status check is what covers it, and a
      // second guard over the same case could never be watched failing.
      final transport = _PlayTransport(failFirstChunkWith: 500);
      final lines = await _upload(
        _chunk * 2,
        transport: transport,
        // Zero backoff so this costs no wall clock; the retry itself is the
        // package's own policy and is not being replaced.
        options: ResumableUploadOptions(backoffFunction: (_) => Duration.zero),
      );

      expect(
        transport.calls.where((c) => c.startsWith('PUT')),
        hasLength(3),
        reason: 'the fake must actually have been asked twice for one chunk',
      );
      expect(_sent(lines), [_chunk, _chunk * 2]);
    });

    test('a chunk the store refused is no line at all', () async {
      // 403 is the one that matters: it is what Play answers a service account
      // without "Release to testing tracks", and it arrives mid-transfer. A
      // progress line for it would report bytes nobody holds, under an upload
      // that is about to fail.
      final transport = _PlayTransport(failFirstChunkWith: 403);
      final capture = _Capture();
      final api = AndroidPublisherApi(
        PlayUploadEvents(capture).observeChunks(transport),
      );

      await expectLater(
        api.edits.bundles.upload(
          'design.codeux.example',
          'edit-1',
          uploadMedia: _artifact(_chunk * 2),
          uploadOptions: UploadOptions.resumable,
        ),
        throwsA(anything),
      );

      expect(_sent(capture.lines), isEmpty);
      await capture.close();
    });
  });

  group('the offset is read off the wire, which is what makes it absolute', () {
    test('a resumed upload does not start again from zero', () async {
      // **The resume case, driven directly**, because googleapis always starts
      // a fresh session at zero and no run through it can reach a non-zero
      // first chunk. What is being checked is the thing that would break it: a
      // counter of its own, which would report this chunk as 1 MiB rather than
      // as the 41st.
      //
      // Direct rather than through the uploader is the honest shape for it —
      // the observer's whole contract is "whatever range the request carried",
      // and this is a request carrying one.
      final capture = _Capture();
      final observer = PlayUploadEvents(
        capture,
      ).observeChunks(_PlayTransport());

      // The 41st mebibyte of a 68 MB bundle, as a resumed session sends it.
      const start = 40 * _chunk;
      await observer.send(
        http.Request('PUT', Uri.parse('https://upload.example/session-1'))
          ..headers['content-range'] =
              'bytes $start-${start + _chunk - 1}/68000000',
      );

      await capture.close();
      expect(_sent(capture.lines), [41 * _chunk]);
      // The number a counter would have produced instead, stated so this
      // cannot pass by accident on an arithmetic that happens to agree.
      expect(_sent(capture.lines).single, isNot(_chunk));
    });

    test('everything that is not a chunk passes through, silently', () async {
      // The client carries the edit calls and the token refresh as well, and
      // a line for one of those would be a byte count for a request that moved
      // no artifact at all.
      final transport = _PlayTransport();
      final capture = _Capture();
      final observer = PlayUploadEvents(capture).observeChunks(transport);

      await observer.send(
        http.Request('POST', Uri.parse('https://example/v3/edits')),
      );

      await capture.close();
      expect(capture.lines, isEmpty);
      expect(transport.calls, ['POST /v3/edits']);
    });
  });

  group('the App Store emitter carries a size and never a count', () {
    // **The half of `transferring` no end-to-end suite can reach.** On the
    // App Store side the state is announced immediately before `xcrun altool`,
    // so a case driving the CLI to it would hand a real artifact to Apple on
    // any machine that has altool — `appstore/upload_events_test.dart` says so
    // in its header. What is checkable here is the line's shape, which is what
    // a consumer is written against.
    test('the transferring line says how big', () async {
      final capture = _Capture();

      AppStoreUploadEvents(
        capture,
      ).state(UploadState.transferring, bytesTotal: 29360128);

      await capture.close();
      final event = AppStoreUploadEvent.fromJson(
        jsonDecode(capture.lines.single) as Map<String, dynamic>,
      );
      expect(event.kind, DocumentKind.appStoreUpload);
      expect(event.state, UploadState.transferring);
      expect(event.bytesTotal, 29360128);
      // Its own counter, not `appstore.listing-diff`'s: one flag on one
      // command produces both, and they change for different reasons.
      expect(event.schema, 1);
    });

    test('and a run without --json writes nothing at all', () async {
      // The emitters are called unconditionally from the upload paths rather
      // than wrapped in a flag test at each site, so "silent when off" is the
      // property that keeps an ordinary run byte-identical to what it was.
      final silent = AppStoreUploadEvents(null)
        ..state(UploadState.processing)
        ..result(
          bundleId: 'design.codeux.example',
          platform: AscPlatform.ios,
          versionName: '1.0.0',
          buildNumber: '169',
          waitedForProcessing: true,
        );

      expect(silent.out, isNull);
    });
  });

  group('every line is one of the published documents', () {
    test('it decodes, and round-trips through the class', () async {
      // The format is `documents.dart`, and a consumer decodes with `fromJson`
      // rather than against keys learned from this encoder. A line that the
      // class cannot read is a line nothing outside can read either.
      final lines = await _upload(_chunk + 1);

      for (final line in lines) {
        final json = jsonDecode(line) as Map<String, dynamic>;
        final event = PlayUploadEvent.fromJson(json);

        expect(event.schema, 1);
        expect(event.kind, DocumentKind.playUpload);
        expect(event.toJson(), json);
      }
    });

    test('and a field that does not apply is absent, not null', () async {
      // Absent and null are different facts everywhere else in this format,
      // and a union type is where the difference is load-bearing: `"state":
      // null` on a progress line would say the line has a state and lost it.
      final lines = await _upload(_chunk + 1);
      final progress = lines
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .firstWhere((j) => j['event'] == 'progress');

      expect(progress.keys, isNot(contains('state')));
      expect(progress.keys, isNot(contains('result')));
      expect(progress['bytesSent'], _chunk);
    });

    test('and each line is one object, with no newline inside it', () async {
      // Newline-delimited JSON is defined by there being exactly one object
      // between two newlines. `writeJsonDocument`'s indenting would break that
      // silently — every line would still be valid JSON, and no line would be
      // a whole document.
      final lines = await _upload(_chunk + 1);

      for (final line in lines) {
        expect(line, isNot(contains('\n')));
        expect(jsonDecode(line), isA<Map<String, dynamic>>());
      }
    });
  });
}
