// SPDX-License-Identifier: Apache-2.0
//
// `appstore upload --json`, end to end: the stream split, the states, and the
// one thing this stream deliberately does not carry.
//
// **The Play half is `test/play_upload_events_test.dart`, and the two are
// separate files rather than one parameterised over a store** — the same split
// the reuse suites make, and for a sharper reason here than there. These
// streams are not the same stream. Play reports bytes and commits a
// transaction; the App Store reports neither, and waits on Apple's processing
// instead. A shared suite would have to assert the intersection, which is
// exactly the part that needed no test.
//
// **`transferring` is not reachable from here, and that is a real gap rather
// than an omission.** The state is announced immediately before
// `uploadPackage`, which shells out to `xcrun altool` — so a case reaching it
// would, on a contributor's macOS machine, hand a real artifact to a real
// Apple endpoint with this file's fake credentials. Every case below therefore
// takes the branch where Apple already holds the build, which is the branch
// `upload_reuse_test.dart` exists for and the one a re-run actually takes. The
// line's shape is covered in `test/upload_events_test.dart`, against the
// emitter; what no test here covers is that the CLI calls it at the right
// moment. Written down rather than papered over — `upload_phases_test.dart`
// has the same shape of hole for the same reason, and says so too.
import 'dart:convert';
import 'dart:io';

import 'package:cux_ship/documents.dart';
import 'package:cux_ship/src/appstore/asc_client.dart';
import 'package:cux_ship/src/appstore/cli.dart';
import 'package:test/test.dart';

/// A build resource as Apple sends one. `upload_reuse_test.dart`'s shape.
Map<String, dynamic> _build(String version) => {
  'type': 'builds',
  'id': 'build-$version',
  '_platform': 'IOS',
  'attributes': {
    'version': version,
    'processingState': 'VALID',
    'expired': false,
  },
};

/// Canned App Store Connect, narrowed to the reads an upload makes.
class _FakeClient implements AscClient {
  _FakeClient(this.builds);

  final List<Map<String, dynamic>> builds;

  @override
  void close() {}

  @override
  AscCredentials get credentials => AscCredentials(
    keyId: 'FAKEKEYID',
    issuerId: 'fake-issuer',
    privateKeyPem:
        'NOT A KEY — no path in upload_events_test.dart reaches '
        'AscClient.bearerToken. If you are reading this in a signing error, '
        'one now does.',
  );

  @override
  Future<List<Map<String, dynamic>>> getAll(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path == '/v1/apps') {
      return [
        {
          'type': 'apps',
          'id': 'app-1',
          'attributes': {
            'name': 'Example',
            'bundleId': query?['filter[bundleId]'],
          },
        },
      ];
    }
    if (const {
      '/v1/certificates',
      '/v1/bundleIds',
      '/v1/profiles',
    }.contains(path)) {
      return const [];
    }
    expect(path, '/v1/builds');
    final version = query?['filter[version]'];
    return builds
        .where((b) => (b['attributes'] as Map)['version'] == version)
        .toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Captures a stream. `upload_reuse_test.dart`'s shape, twice over.
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

typedef _Run = ({List<String> out, String err});

void main() {
  late File artifact;

  setUp(() {
    final dir = Directory.systemTemp.createTempSync('cux_ship_asc_events');
    addTearDown(() => dir.deleteSync(recursive: true));
    artifact = File('${dir.path}/app.ipa')
      ..writeAsBytesSync(List<int>.filled(4096, 7));
  });

  /// One `appstore upload --artifact` against [client], streams kept apart.
  Future<_Run> upload({List<String> extra = const []}) async {
    final args = buildAscParser(AscCommand.upload).parse([
      '--platform',
      'ios',
      '--bundle-id',
      'design.codeux.example',
      '--artifact',
      artifact.path,
      '--build-number',
      '52',
      '--version-name',
      '1.0.0',
      '--no-metadata',
      ...extra,
    ]);

    final out = _Memory();
    final err = _Memory();
    await IOOverrides.runZoned(
      () => runAsc(
        AscCommand.upload,
        args,
        // Apple already holds 52, which is the branch that does not reach
        // altool — see the header.
        ascClient: _FakeClient([_build('52')]),
      ),
      stdout: () => out,
      stderr: () => err,
    );
    await out.close();
    await err.close();

    return (
      out: const LineSplitter().convert(out.buffer.toString()),
      err: err.buffer.toString(),
    );
  }

  List<AppStoreUploadEvent> events(List<String> lines) => [
    for (final line in lines)
      AppStoreUploadEvent.fromJson(jsonDecode(line) as Map<String, dynamic>),
  ];

  group('the two streams stay apart', () {
    test('stdout is events and nothing else', () async {
      final run = await upload(extra: ['--json']);

      expect(run.out, isNotEmpty);
      for (final line in run.out) {
        expect(
          () => jsonDecode(line),
          returnsNormally,
          reason: 'stdout carried prose: $line',
        );
      }
    });

    test('and the app banner is one of the lines that moved', () async {
      // **The first line a document-producing run has always printed**, and
      // the one a consumer's decoder would hit first if it had not moved. It
      // is named rather than covered by "stderr is non-empty", because it is
      // printed from a different place than the upload's own reporting.
      final run = await upload(extra: ['--json']);

      expect(run.err, contains('is app app-1'));
      expect(run.err, contains('==> Apple already holds build 52'));
      expect(run.err, contains('==> done'));
    });

    test('and without --json nothing changes at all', () async {
      final run = await upload();

      expect(run.out.join('\n'), contains('==> Apple already holds build 52'));
      expect(run.out.join('\n'), contains('==> done'));
      expect(run.err, isEmpty);
    });
  });

  group('the states an upload passes through', () {
    test('including the long one, which is Apple processing', () async {
      // `processing` is where an Apple upload spends most of its wall clock —
      // 5 to 15 minutes with nothing printed in between — and naming it is the
      // whole reason this stream exists on this store.
      final run = await upload(extra: ['--json']);
      final states = [
        for (final event in events(run.out))
          if (event.event == UploadEvent.state) event.state,
      ];

      expect(states, [
        UploadState.preparing,
        UploadState.reusing,
        UploadState.processing,
      ]);
    });

    test('and the wait is reported on stderr, not among the events', () async {
      // `printProcessingProgress` is the only thing that prints inside that
      // wait. It writes to stdout by default, which under `--json` is the one
      // place it must not.
      final run = await upload(extra: ['--json']);

      expect(run.err, contains('has finished processing'));
      expect(run.out.join('\n'), isNot(contains('finished processing')));
    });

    test('--skip-waiting leaves the processing state out', () async {
      // The flag defers the wait to another command, so claiming the state
      // would report a phase this run never entered.
      final run = await upload(extra: ['--json', '--skip-waiting']);
      final states = [
        for (final event in events(run.out))
          if (event.event == UploadEvent.state) event.state,
      ];

      expect(states, isNot(contains(UploadState.processing)));
    });
  });

  group('no byte progress, and no field to carry one', () {
    test('not one progress line, however the run went', () async {
      // **The decision, pinned rather than left to the absence of code.**
      // altool is a subprocess whose transport Apple documents nowhere, so
      // there is no per-chunk signal to report — and the alternative, a tick
      // on a timer, turns at the same rate whether the socket is moving or
      // dead. A build that "helpfully" added one would be reporting a wedged
      // upload as a healthy one, which is the failure this stream exists to
      // make visible.
      final run = await upload(extra: ['--json']);

      expect(
        events(run.out).where((e) => e.event == UploadEvent.progress),
        isEmpty,
      );
    });

    test('and no line carries a bytesSent key at all', () async {
      // One level below the case above: the *format* has no such field, so a
      // consumer cannot be written expecting one to arrive later.
      final run = await upload(extra: ['--json']);

      for (final line in run.out) {
        expect(
          (jsonDecode(line) as Map<String, dynamic>).keys,
          isNot(contains('bytesSent')),
        );
      }
    });
  });

  group('the last line says the run finished', () {
    test('and names the platform beside the build number', () async {
      // iOS and macOS are given the same build number from one commit by
      // design, so a number with no platform beside it names two different
      // binaries — which is the defect `finishAfterSkippedWait` carries the
      // platform on every line to avoid.
      final run = await upload(extra: ['--json']);
      final last = events(run.out).last;

      expect(last.event, UploadEvent.result);
      expect(last.result!.bundleId, 'design.codeux.example');
      expect(last.result!.platform, AscPlatform.ios);
      expect(last.result!.buildNumber, '52');
      expect(last.result!.versionName, '1.0.0');
      expect(last.result!.waitedForProcessing, isTrue);
      expect(
        events(run.out).where((e) => e.event == UploadEvent.result),
        hasLength(1),
      );
    });

    test('and says so when the wait was skipped', () async {
      // A caller reading `true` knows the build is VALID, because
      // `awaitProcessing` raises rather than returning on anything else.
      // Reading `false` it knows only that Apple has the bytes — which is a
      // different answer to "can this go to testers", and the one field that
      // separates them.
      final run = await upload(extra: ['--json', '--skip-waiting']);

      expect(events(run.out).last.result!.waitedForProcessing, isFalse);
    });
  });

  group('a --dry-run --json is the other format, not this one', () {
    test('it writes a listing diff document and no events', () async {
      // **One stdout, one format on it.** A dry run transfers nothing, waits
      // on nothing and writes nothing, so an event stream of it would report
      // states nothing entered — and a run emitting both shapes at once would
      // be parseable by neither consumer.
      final args = buildAscParser(AscCommand.upload).parse([
        '--platform',
        'ios',
        '--bundle-id',
        'design.codeux.example',
        '--artifact',
        artifact.path,
        '--build-number',
        '52',
        '--version-name',
        '1.0.0',
        '--no-metadata',
        '--dry-run',
        '--json',
      ]);

      final out = _Memory();
      final err = _Memory();
      await IOOverrides.runZoned(
        () => runAsc(
          AscCommand.upload,
          args,
          ascClient: _FakeClient([_build('52')]),
        ),
        stdout: () => out,
        stderr: () => err,
      );
      await out.close();
      await err.close();

      // `--no-metadata` means there is no listing to diff either, so what is
      // being asserted is the absence of the stream rather than the presence
      // of the document — which `appstore/listing_diff_json_test.dart` covers
      // with a tree to compare.
      expect(
        out.buffer.toString(),
        isNot(contains('"kind":"appstore.upload"')),
      );
      expect(err.buffer.toString(), contains('==> dry run'));
    });
  });
}
