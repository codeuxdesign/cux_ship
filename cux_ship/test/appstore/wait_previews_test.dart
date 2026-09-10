// SPDX-License-Identifier: Apache-2.0
//
// `appstore wait-previews` — the sibling `appstore wait` has had since builds
// needed one, and previews did not, despite having the longest documented tail
// of any asset this tool uploads.
//
// **The exit code is the point, not a detail.** The one project running
// previews branches on exit status and never on text, deliberately, after a
// status of theirs escaped from four regular expressions matched against
// stdout. So "still ingesting" has to be distinguishable from "done" and from
// "broken" without reading a word — three states, three codes.
import 'dart:convert';
import 'dart:io';

import 'package:cux_ship/src/appstore/app_store.dart';
import 'package:cux_ship/src/appstore/asc_client.dart';
import 'package:cux_ship/src/appstore/cli.dart';
import 'package:test/test.dart';

Map<String, dynamic> _preview({
  String id = 'preview-1',
  String fileName = 'promo.mp4',
  String? videoState,
  String? frameState,
  String? frameTimeCode,
}) => {
  'type': 'appPreviews',
  'id': id,
  'attributes': {
    'fileName': fileName,
    if (frameTimeCode != null) ...{'previewFrameTimeCode': frameTimeCode},
    if (videoState != null) ...{
      'videoDeliveryState': {'state': videoState},
    },
    if (frameState != null) ...{
      'previewFrameImage': {
        'state': {'state': frameState},
      },
    },
  },
};

/// Canned App Store Connect for a version carrying one preview.
///
/// **It answers the three nested collections separately**, because that is
/// what `previewsOn` walks and what the command's report is built from: a
/// version has localizations, a localization has preview sets, a set has
/// previews. A fake that flattened them would agree with a reader that had the
/// nesting wrong.
class _FakeClient implements AscClient {
  _FakeClient({this.versions = const [], this.previews = const []});

  final List<Map<String, dynamic>> versions;

  /// What Apple reports on each poll of a single preview, in order; the last
  /// entry repeats.
  final List<Map<String, dynamic>> previews;
  var _poll = 0;

  final requests = <String>[];

  @override
  Future<List<Map<String, dynamic>>> getAll(
    String path, {
    Map<String, String>? query,
  }) async {
    requests.add('GET $path');
    if (path == '/v1/apps') {
      return [
        if (query?['filter[bundleId]'] == 'design.codeux.example')
          {
            'type': 'apps',
            'id': 'app-1',
            'attributes': {
              'bundleId': 'design.codeux.example',
              'name': 'Example',
            },
          },
      ];
    }
    if (path.endsWith('/appStoreVersions')) {
      final wanted = query?['filter[versionString]'];
      if (wanted == null) {
        return versions;
      }
      return versions
          .where(
            (v) =>
                (v['attributes'] as Map<String, dynamic>)['versionString'] ==
                wanted,
          )
          .toList();
    }
    if (path.endsWith('/appStoreVersionLocalizations')) {
      return previews.isEmpty
          ? const []
          : [
              {
                'type': 'appStoreVersionLocalizations',
                'id': 'loc-1',
                'attributes': {'locale': 'en-US'},
              },
            ];
    }
    if (path.endsWith('/appPreviewSets')) {
      return [
        {
          'type': 'appPreviewSets',
          'id': 'set-1',
          'attributes': {'previewType': 'IPHONE_67'},
        },
      ];
    }
    if (path.endsWith('/appPreviews')) {
      // **The collection reflects where the polling has got to**, because
      // Apple's does: the document `--json` prints is built from a re-read
      // *after* the wait, and a fake that always answered with the first
      // scripted state would report a preview as PROCESSING in the document
      // of a run that had just watched it finish.
      return [previews[_poll == 0 ? 0 : previews.length - 1]];
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    requests.add('GET $path');
    final data =
        previews[_poll < previews.length ? _poll : previews.length - 1];
    _poll++;
    return {'data': data};
  }

  @override
  AscCredentials get credentials =>
      AscCredentials(keyId: 'K', issuerId: 'I', privateKeyPem: 'unused');

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

Map<String, dynamic> _version(String name) => {
  'type': 'appStoreVersions',
  'id': 'version-1',
  'attributes': {
    'versionString': name,
    'appStoreState': 'PREPARE_FOR_SUBMISSION',
  },
};

Future<String> _wait(_FakeClient client, {List<String> extra = const []}) {
  final args = buildAscParser(AscCommand.awaitPreviews).parse([
    '--bundle-id',
    'design.codeux.example',
    '--version-name',
    '1.1.6',
    '--poll',
    '0s',
    ...extra,
  ]);
  final captured = _MemoryStdout();
  return IOOverrides.runZoned(
    () async {
      await runAsc(AscCommand.awaitPreviews, args, ascClient: client);
      await captured.close();
      return captured.buffer.toString();
    },
    stdout: () => captured,
    stderr: () => captured,
  );
}

void main() {
  setUp(() => exitCode = 0);
  tearDown(() => exitCode = 0);

  test('a finished preview exits zero', () async {
    final client = _FakeClient(
      versions: [_version('1.1.6')],
      previews: [_preview(videoState: 'COMPLETE', frameState: 'COMPLETE')],
    );

    final said = await _wait(client);

    expect(exitCode, 0);
    expect(said, contains('previews are ready'));
    expect(said, contains('en-US IPHONE_67: promo.mp4'));
  });

  test(
    'one still ingesting exits the pending code, not zero and not one',
    () async {
      // **The whole reason this command exists.** Exit zero would make "still
      // going" indistinguishable from "done" to a caller that branches on
      // status; exit 1 would call an outcome the design document describes as
      // ordinary a failure. Three states, three codes.
      final client = _FakeClient(
        versions: [_version('1.1.6')],
        previews: [_preview(videoState: 'PROCESSING')],
      );

      final said = await _wait(client, extra: ['--timeout', '0s']);

      expect(exitCode, previewsPendingExit);
      expect(exitCode, isNot(0));
      expect(exitCode, isNot(1));
      expect(said, contains('not a failure'));
      // The per-asset detail, because "1 preview(s) pending" cannot tell a video
      // still uploading from a poster frame not yet cut.
      expect(said, contains('promo.mp4'));
      expect(said, contains('video PROCESSING'));
      expect(said, contains('Re-run'));
    },
  );

  test('a rejected preview is a failure, not a pending state', () async {
    // The third state. `FAILED` is Apple refusing the asset, which is not
    // "not yet" — conflating the two is how a broken upload waits for ever.
    final client = _FakeClient(
      versions: [_version('1.1.6')],
      previews: [_preview(videoState: 'FAILED')],
    );

    final said = await _wait(client);

    expect(exitCode, 1);
    expect(exitCode, isNot(previewsPendingExit));
    expect(said, contains('rejected the preview'));
  });

  test('a version with no previews says so rather than waiting', () async {
    final client = _FakeClient(versions: [_version('1.1.6')]);

    final said = await _wait(client);

    expect(exitCode, 0);
    expect(said, contains('carries no previews'));
  });

  test('--json puts the document on stdout and progress on stderr', () async {
    // **A wait is progress and *then* an answer**, so one document at the end
    // cannot be rendered as progress. Splitting by stream rather than by flag
    // gives a person the live report and a program a clean document without
    // either having to choose — and it keeps the invariant every other
    // `--json` command in this file states: stdout carries the document and
    // nothing else.
    final client = _FakeClient(
      versions: [_version('1.1.6')],
      previews: [
        _preview(videoState: 'PROCESSING'),
        _preview(
          videoState: 'COMPLETE',
          frameState: 'COMPLETE',
          frameTimeCode: '00:00:02:06',
        ),
      ],
    );

    final out = _MemoryStdout();
    final err = _MemoryStdout();
    final args = buildAscParser(AscCommand.awaitPreviews).parse([
      '--bundle-id',
      'design.codeux.example',
      '--version-name',
      '1.1.6',
      '--poll',
      '0s',
      '--json',
    ]);
    await IOOverrides.runZoned(
      () => runAsc(AscCommand.awaitPreviews, args, ascClient: client),
      stdout: () => out,
      stderr: () => err,
    );

    // stdout is exactly one document and nothing else.
    final document = jsonDecode(out.buffer.toString()) as Map<String, dynamic>;
    expect(document['kind'], 'appstore.previews');
    expect(document['schema'], 1);
    expect(document['versionName'], '1.1.6');

    // Apple's own field names, so a reader can hold this beside Apple's docs.
    final entry = (document['previews'] as List).single as Map<String, dynamic>;
    expect(entry['videoDeliveryState'], 'COMPLETE');
    expect(entry['previewFrameImageState'], 'COMPLETE');
    expect(entry['previewFrameTimeCode'], '00:00:02:06');
    expect(entry['locale'], 'en-US');
    expect(entry['previewType'], 'IPHONE_67');
    expect(entry['done'], isTrue);

    // And the progress went somewhere a person can read without spoiling it.
    expect(err.buffer.toString(), contains('video PROCESSING'));
  });

  test('the report names the locale and type, not just an id', () async {
    // Apple identifies a preview by an opaque id; a person waiting on one
    // wants "the en-US IPHONE_67 one", and those live two collections up.
    final client = _FakeClient(
      versions: [_version('1.1.6')],
      previews: [_preview(videoState: 'COMPLETE', frameState: 'COMPLETE')],
    );

    final said = await _wait(client);

    expect(said, contains('en-US'));
    expect(said, contains('IPHONE_67'));
  });
}
