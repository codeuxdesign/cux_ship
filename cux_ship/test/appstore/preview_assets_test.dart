// SPDX-License-Identifier: Apache-2.0
//
// App preview videos, which differ from screenshots in three ways and are
// otherwise the same three-step reservation. Each difference is a defect
// waiting to be reintroduced by whoever reaches for the screenshot code:
//
//   - **Apple deprecated `assetDeliveryState` on `appPreviews`** and replaced
//     it with `videoDeliveryState`. Reading the screenshot field would report
//     a null state for every preview, so nothing would ever equal COMPLETE and
//     the unchanged-asset skip would silently never fire — the exact failure
//     [PublishedScreenshot] documents having already been paid for once.
//   - **A poster frame is a second asset with a second verdict.** Apple cuts
//     it out of the video after ingesting it, so a preview can report a
//     COMPLETE video and a FAILED frame, and a run that watched only the video
//     would call that a success.
//   - **A preview is up to 500 MB and takes up to twenty-four hours.** So a
//     poster frame that moved is patched rather than re-uploaded, and the
//     timeout says that reaching it is ordinary rather than a failure.
//
// And one property that is not a difference at all: the run says what the
// poster frame *is*, including when nothing chose one. A preview silently
// posed at Apple's five-second default cannot be corrected after approval
// without a new version submission.
import 'dart:io';

import 'package:cux_ship/src/appstore/app_store.dart';
import 'package:cux_ship/src/appstore/asc_client.dart';
import 'package:cux_ship_verify/metadata.dart';
import 'package:test/test.dart';

const _absent = Object();

/// One `appPreviews` resource as Apple reports it.
///
/// `videoDeliveryState` and `assetDeliveryState` are separately settable, and
/// separately absent, because the whole point of the reader under test is
/// which of the two it consults — a fake that always wrote both could not tell
/// a correct reader from one that reads the deprecated field.
Map<String, dynamic> _preview({
  String id = 'preview-1',
  Object? fileName = _absent,
  Object? checksum = _absent,
  Object? videoState = _absent,
  Object? legacyState = _absent,
  String? frameState,
  String? frameTimeCode,
  List<Map<String, dynamic>>? videoErrors,
  List<Map<String, dynamic>>? frameErrors,
}) => {
  'type': 'appPreviews',
  'id': id,
  'attributes': {
    if (!identical(fileName, _absent)) ...{'fileName': fileName},
    if (!identical(checksum, _absent)) ...{'sourceFileChecksum': checksum},
    if (frameTimeCode != null) ...{'previewFrameTimeCode': frameTimeCode},
    if (!identical(videoState, _absent) || videoErrors != null) ...{
      'videoDeliveryState': {
        if (!identical(videoState, _absent)) ...{'state': videoState},
        if (videoErrors != null) ...{'errors': videoErrors},
      },
    },
    if (!identical(legacyState, _absent)) ...{
      'assetDeliveryState': {'state': legacyState},
    },
    if (frameState != null || frameErrors != null) ...{
      'previewFrameImage': {
        'state': {
          if (frameState != null) ...{'state': frameState},
          if (frameErrors != null) ...{'errors': frameErrors},
        },
      },
    },
  },
};

PublishedPreview _published(
  String? name,
  String? sum, {
  String? state = 'COMPLETE',
  String? frameState,
  String? timeCode,
  String? id = 'preview-1',
}) => (
  id: id,
  fileName: name,
  checksum: sum,
  videoState: state,
  frameState: frameState,
  frameTimeCode: timeCode,
);

LocalPreviewAsset _local(String name, String sum, {String? timeCode}) =>
    (fileName: name, checksum: sum, frameTimeCode: timeCode);

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

/// Canned App Store Connect for the preview endpoints.
///
/// **It holds preview sets of more than one `previewType` and returns them
/// all**, because that is what the real collection read does and it is what
/// the tested branch selects on: `replacePreviews` filters client-side, and a
/// fake that returned only the asked-for type could not catch a filter that
/// was dropped, inverted, or written against `screenshotDisplayType`.
///
/// It also records every write, so a test can assert on what *did not* happen
/// — the retime case is defined by the absence of a delete and an upload.
class _FakeClient implements AscClient {
  _FakeClient({this.sets = const [], this.published = const []});

  /// `appPreviewSets` the localization holds, of whatever types.
  final List<Map<String, dynamic>> sets;

  /// `appPreviews` inside the set the tests use.
  final List<Map<String, dynamic>> published;

  /// What Apple reports on each poll of `/v1/appPreviews/{id}`, in order. The
  /// last entry repeats.
  List<Map<String, dynamic>> polls = const [];
  var _poll = 0;

  final requests = <String>[];
  final reserved = <Map<String, dynamic>>[];
  final patched = <Map<String, dynamic>>[];
  final uploads = <int>[];

  @override
  Future<List<Map<String, dynamic>>> getAll(
    String path, {
    Map<String, String>? query,
  }) async {
    requests.add('GET $path');
    if (path.endsWith('/appPreviewSets')) {
      return sets;
    }
    if (path.endsWith('/appPreviews')) {
      return published;
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    requests.add('GET $path');
    final data = polls[_poll < polls.length ? _poll : polls.length - 1];
    _poll++;
    return {'data': data};
  }

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    requests.add('POST $path');
    if (path == '/v1/appPreviews') {
      reserved.add(body);
      return {
        'data': {
          'type': 'appPreviews',
          'id': 'new-preview',
          'attributes': {
            'uploadOperations': [
              {
                'method': 'PUT',
                'url': 'https://upload.example/part-1',
                'offset': 0,
                'length': 4,
                'requestHeaders': <Map<String, String>>[],
              },
            ],
          },
        },
      };
    }
    return {
      'data': {'type': 'appPreviewSets', 'id': 'new-set', 'attributes': body},
    };
  }

  @override
  Future<Map<String, dynamic>> patch(
    String path,
    Map<String, dynamic> body,
  ) async {
    requests.add('PATCH $path');
    patched.add(body);
    return {
      'data': _preview(
        id: 'new-preview',
        fileName: 'promo.mp4',
        videoState: failCommitWithoutReason ? 'FAILED' : 'UPLOAD_COMPLETE',
        frameTimeCode: _sentTimeCode(),
      ),
    };
  }

  /// Whether Apple answers the commit with a `previewFrameTimeCode` of its own
  /// when the reservation named none.
  ///
  /// **The fake could not produce this response shape, and it is the one the
  /// annotation branch selects on.** Echoing only what was sent means a
  /// sidecar-less preview always read back null, so the branch that prints a
  /// bare `poster frame 00:00:05:00` — losing the "(Apple's default)" note in
  /// exactly the case it exists for — was unreachable from every test. Whether
  /// Apple really echoes its default is unverified; this makes the code path
  /// reachable either way, which is the point.
  bool echoesDefaultTimeCode = false;

  /// Whether the commit answers FAILED with an empty `errors[]`.
  ///
  /// The shape the no-reason hint exists for: Apple refusing an asset and
  /// saying nothing about why. A fake that always supplied a reason could
  /// not reach the branch that supplies one on Apple's behalf.
  bool failCommitWithoutReason = false;

  /// What the reservation asked for, so the commit response can echo it the
  /// way Apple does — the readback is what the log line prints.
  String? _sentTimeCode() {
    for (final body in reserved) {
      final data = body['data'];
      if (data is Map<String, dynamic>) {
        final attributes = data['attributes'];
        if (attributes is Map<String, dynamic>) {
          final sent = attributes['previewFrameTimeCode'] as String?;
          if (sent != null) {
            return sent;
          }
        }
      }
    }
    return echoesDefaultTimeCode ? defaultPreviewFrameTimeCode : null;
  }

  @override
  Future<void> delete(String path) async => requests.add('DELETE $path');

  @override
  Future<void> uploadOperation(
    Map<String, dynamic> operation,
    List<int> chunk,
  ) async => uploads.add(chunk.length);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _set(String type, {String id = 'set-1'}) => {
  'type': 'appPreviewSets',
  'id': id,
  'attributes': {'previewType': type},
};

final _localization = <String, dynamic>{
  'type': 'appStoreVersionLocalizations',
  'id': 'loc-1',
  'attributes': {'locale': 'en-US'},
};

late Directory _tmp;

/// A file on disk whose *bytes* are what the checksum is taken over.
LocalPreview _video(String name, String bytes, {String? timeCode}) {
  final file = File('${_tmp.path}/$name')..writeAsStringSync(bytes);
  return (file: file, frameTimeCode: timeCode);
}

void main() {
  setUp(() {
    _tmp = Directory.systemTemp.createTempSync('asc_preview_test');
  });
  tearDown(() => _tmp.deleteSync(recursive: true));

  group('which state Apple is asked for', () {
    test('the current field is read, not the deprecated one', () {
      // Apple's AppPreview marks assetDeliveryState deprecated in favour of
      // videoDeliveryState. Reading the screenshot field would report null
      // here, nothing would equal COMPLETE, and the skip would never fire.
      expect(previewVideoState(_preview(videoState: 'COMPLETE')), 'COMPLETE');
    });

    test('the deprecated field is still honoured when it is all there is', () {
      // Deprecated is not gone. A response carrying only the old field is
      // read rather than treated as stateless, because trusting a deprecation
      // notice to describe the present is how the skip stops firing.
      expect(previewVideoState(_preview(legacyState: 'COMPLETE')), 'COMPLETE');
    });

    test('the current field wins when both are present', () {
      expect(
        previewVideoState(
          _preview(videoState: 'FAILED', legacyState: 'COMPLETE'),
        ),
        'FAILED',
      );
    });

    test('no state at all is null, which is a fact about the response', () {
      expect(previewVideoState(_preview()), isNull);
    });

    test('the poster frame carries its own verdict', () {
      final preview = _preview(videoState: 'COMPLETE', frameState: 'FAILED');
      expect(previewVideoState(preview), 'COMPLETE');
      expect(previewFrameState(preview), 'FAILED');
    });

    test('a video error is reported once, not once per field', () {
      // Apple populates `videoDeliveryState` and the deprecated
      // `assetDeliveryState` together, and reading both listed every reason
      // twice — in the one message somebody reads to work out what was
      // refused.
      final why = previewDeliveryErrors({
        'type': 'appPreviews',
        'id': 'preview-1',
        'attributes': {
          'videoDeliveryState': {
            'state': 'FAILED',
            'errors': [
              {'code': 'BAD_FPS', 'description': 'frame rate above 30'},
            ],
          },
          'assetDeliveryState': {
            'state': 'FAILED',
            'errors': [
              {'code': 'BAD_FPS', 'description': 'frame rate above 30'},
            ],
          },
        },
      });
      expect(why, ['BAD_FPS - frame rate above 30']);
    });

    test('the deprecated field is still read when it is the only one', () {
      final why = previewDeliveryErrors({
        'type': 'appPreviews',
        'id': 'preview-1',
        'attributes': {
          'assetDeliveryState': {
            'state': 'FAILED',
            'errors': [
              {'code': 'OLD', 'description': 'from the deprecated field'},
            ],
          },
        },
      });
      expect(why, ['OLD - from the deprecated field']);
    });

    test('a rejection reports both assets\' reasons, labelled', () {
      final why = previewDeliveryErrors(
        _preview(
          videoState: 'FAILED',
          videoErrors: [
            {'code': 'BAD_FPS', 'description': 'frame rate above 30'},
          ],
          frameState: 'FAILED',
          frameErrors: [
            {'code': 'NO_FRAME', 'description': 'timecode past the end'},
          ],
        ),
      );
      expect(why, contains('BAD_FPS - frame rate above 30'));
      expect(why, contains('poster frame: NO_FRAME - timecode past the end'));
    });
  });

  group('what a run has to do', () {
    test('the same videos posed the same way need nothing', () {
      expect(
        previewPlan(
          published: [_published('01.mp4', 'aaa', timeCode: '00:00:02:06')],
          local: [_local('01.mp4', 'aaa', timeCode: '00:00:02:06')],
        ),
        PreviewPlan.unchanged,
      );
    });

    test('a moved poster frame is a patch, not an upload', () {
      // The difference this enum exists for. Merging it into `replace` would
      // be correct and would re-send up to 500 MB, then wait out an ingestion
      // queue Apple documents as taking a day — to change a string.
      expect(
        previewPlan(
          published: [_published('01.mp4', 'aaa', timeCode: '00:00:05:00')],
          local: [_local('01.mp4', 'aaa', timeCode: '00:00:02:06')],
        ),
        PreviewPlan.retime,
      );
    });

    test('changed bytes are a replace even when the frame matches', () {
      expect(
        previewPlan(
          published: [_published('01.mp4', 'aaa', timeCode: '00:00:02:06')],
          local: [_local('01.mp4', 'zzz', timeCode: '00:00:02:06')],
        ),
        PreviewPlan.replace,
      );
    });

    test('a video Apple has not finished with is not a skip', () {
      // The checksum is committed before ingestion finishes, so name and
      // checksum alone match an asset Apple went on to reject. Only COMPLETE
      // is evidence it was kept.
      for (final state in ['UPLOAD_COMPLETE', 'AWAITING_UPLOAD', 'FAILED']) {
        expect(
          previewPlan(
            published: [_published('01.mp4', 'aaa', state: state)],
            local: [_local('01.mp4', 'aaa')],
          ),
          PreviewPlan.replace,
          reason: '$state is not evidence Apple kept the bytes',
        );
      }
    });

    test('a rejected poster frame is not skipped on the next run', () {
      // **The defect the feature exists to prevent, reintroduced through the
      // skip.** Run 1 uploads, the frame fails, `awaitPreviewProcessing`
      // throws and the release aborts. Re-running is the *documented* recovery
      // from a processing timeout, so run 2 is the ordinary next step — and it
      // matched on name, checksum and video state, called the set unchanged,
      // and let a promotion submit a version whose poster Apple threw away.
      expect(
        previewPlan(
          published: [
            _published(
              '01.mp4',
              'aaa',
              frameState: 'FAILED',
              timeCode: '00:00:02:06',
            ),
          ],
          local: [_local('01.mp4', 'aaa', timeCode: '00:00:02:06')],
        ),
        PreviewPlan.replace,
      );
    });

    test('a frame state Apple never reports is not held against it', () {
      // `!= FAILED` rather than `== COMPLETE`, and the difference is a release
      // that re-uploads a 500 MB video on every run for ever: Apple is not
      // guaranteed to report a frame state at all, and a null is a fact about
      // the response rather than evidence against the asset.
      expect(
        previewPlan(
          published: [_published('01.mp4', 'aaa', timeCode: '00:00:02:06')],
          local: [_local('01.mp4', 'aaa', timeCode: '00:00:02:06')],
        ),
        PreviewPlan.unchanged,
      );
    });

    test('a tree that names no frame leaves Apple\'s alone', () {
      // "Present means owned" applied to an attribute: a video with no
      // sidecar does not reset a poster frame somebody set in the console.
      expect(
        previewPlan(
          published: [_published('01.mp4', 'aaa', timeCode: '00:00:09:00')],
          local: [_local('01.mp4', 'aaa')],
        ),
        PreviewPlan.unchanged,
      );
    });

    test('order is part of the comparison', () {
      expect(
        previewPlan(
          published: [_published('01.mp4', 'aaa'), _published('02.mp4', 'bbb')],
          local: [_local('02.mp4', 'bbb'), _local('01.mp4', 'aaa')],
        ),
        PreviewPlan.replace,
      );
    });

    test('a differing count is a replace, and so is nothing at all', () {
      expect(
        previewPlan(
          published: [_published('01.mp4', 'aaa')],
          local: [_local('01.mp4', 'aaa'), _local('02.mp4', 'bbb')],
        ),
        PreviewPlan.replace,
      );
      expect(
        previewPlan(published: const [], local: const []),
        PreviewPlan.replace,
      );
    });
  });

  group('what the run says about the poster frame', () {
    test('a chosen frame is named', () {
      expect(describePreviewFrame('00:00:02:06'), contains('00:00:02:06'));
    });

    test('an unchosen one names the default and says it is the default', () {
      // The convention this feature was asked for: a tool prints effective
      // configuration, not intent. A poster frame that silently defaults to
      // five seconds is exactly what that convention exists to prevent, and
      // here it cannot be corrected after approval without a new submission.
      final said = describePreviewFrame(null);
      expect(said, contains(defaultPreviewFrameTimeCode));
      expect(said, contains('default'));
      expect(said, contains(previewTimeCodeSuffix));
    });
  });

  group('publishing a set', () {
    AppStore storeOf(_FakeClient client, {bool dryRun = false}) => AppStore(
      client,
      Writer(client, dryRun: dryRun),
      platform: AscPlatform.ios,
    );

    test('an unchanged set uploads nothing and still says the frame', () async {
      final client = _FakeClient(
        sets: [_set('IPHONE_67')],
        published: [
          _preview(
            fileName: 'promo.mp4',
            checksum: checksumOf('bytes'.codeUnits),
            videoState: 'COMPLETE',
            frameTimeCode: '00:00:02:06',
          ),
        ],
      );

      final said = await _printed(
        () => storeOf(client).replacePreviews(_localization, 'IPHONE_67', [
          _video('promo.mp4', 'bytes', timeCode: '00:00:02:06'),
        ]),
      );

      expect(said, contains('already published'));
      // The point of saying it on a run that uploaded nothing: this is the
      // only place a reader can see what the live listing is actually posed
      // at without opening App Store Connect.
      expect(said, contains('00:00:02:06'));
      expect(client.uploads, isEmpty);
      expect(client.requests, isNot(contains(startsWith('DELETE'))));
    });

    test('a moved frame patches and does not delete or upload', () async {
      final client = _FakeClient(
        sets: [_set('IPHONE_67')],
        published: [
          _preview(
            fileName: 'promo.mp4',
            checksum: checksumOf('bytes'.codeUnits),
            videoState: 'COMPLETE',
            frameTimeCode: '00:00:05:00',
          ),
        ],
      );

      final said = await _printed(
        () => storeOf(client).replacePreviews(_localization, 'IPHONE_67', [
          _video('promo.mp4', 'bytes', timeCode: '00:00:02:06'),
        ]),
      );

      expect(client.uploads, isEmpty);
      expect(
        client.requests.where((r) => r.startsWith('DELETE')),
        isEmpty,
        reason: 'the bytes Apple holds are the bytes wanted',
      );
      expect(client.requests, contains('PATCH /v1/appPreviews/preview-1'));
      expect(said, contains('00:00:05:00'));
      expect(said, contains('00:00:02:06'));
    });

    test('the poster frame is sent with the reservation', () async {
      // Rather than only with the commit, which Apple also accepts: a run that
      // dies between the PUTs and the commit then leaves an asset Apple
      // discards rather than one posed at five seconds.
      final client = _FakeClient()
        ..polls = [
          _preview(
            id: 'new-preview',
            videoState: 'COMPLETE',
            frameState: 'COMPLETE',
          ),
        ];

      await _printed(
        () => storeOf(client).replacePreviews(_localization, 'IPHONE_67', [
          _video('promo.mp4', 'bytes', timeCode: '00:00:02:06'),
        ]),
      );

      final attributes =
          (client.reserved.single['data'] as Map<String, dynamic>)['attributes']
              as Map<String, dynamic>;
      expect(attributes['previewFrameTimeCode'], '00:00:02:06');
      expect(attributes['fileName'], 'promo.mp4');
      expect(attributes['fileSize'], 5);
    });

    test('Apple echoing its own default does not erase the note', () async {
      // The readback is preferred over what was sent, because the two
      // differing is worth seeing — but the *annotation* has to follow the
      // tree. A sidecar-less preview whose commit response carries Apple's
      // own 00:00:05:00 printed a bare `poster frame 00:00:05:00`, which reads
      // as somebody's choice. It is the opposite: nobody chose, and after
      // approval it cannot be changed without a new submission.
      final client = _FakeClient()
        ..echoesDefaultTimeCode = true
        ..polls = [
          _preview(
            id: 'new-preview',
            videoState: 'COMPLETE',
            frameState: 'COMPLETE',
          ),
        ];

      final said = await _printed(
        () => storeOf(client).replacePreviews(_localization, 'IPHONE_67', [
          _video('promo.mp4', 'bytes'),
        ]),
      );

      expect(said, contains('sent promo.mp4'));
      expect(said, contains(defaultPreviewFrameTimeCode));
      expect(
        said,
        contains('default'),
        reason: 'the whole point of the line is that nobody chose this frame',
      );
    });

    test('the matching set is the one replaced, and only it', () async {
      // The fake answers the collection read with every type it holds,
      // because the real one does — `replacePreviews` filters client-side.
      //
      // **Both halves are asserted, and the second is why.** An earlier
      // version held only the iPad set and checked that it was not deleted;
      // that stays true when the filter is written against
      // `screenshotDisplayType` — nothing matches, nothing is found, and a
      // second iPhone set is created beside the first. So the iPhone set is
      // here too, and the claim is that *it* is the one cleared. Found by
      // reverting the filter and watching the old test stay green.
      final client =
          _FakeClient(
              sets: [
                _set('IPAD_PRO_3GEN_11', id: 'ipad'),
                _set('IPHONE_67', id: 'iphone'),
              ],
              published: [
                _preview(
                  fileName: 'old.mp4',
                  checksum: 'something-else',
                  videoState: 'COMPLETE',
                ),
              ],
            )
            ..polls = [
              _preview(
                id: 'new-preview',
                videoState: 'COMPLETE',
                frameState: 'COMPLETE',
              ),
            ];

      await _printed(
        () => storeOf(client).replacePreviews(_localization, 'IPHONE_67', [
          _video('promo.mp4', 'bytes'),
        ]),
      );

      expect(client.requests, contains('DELETE /v1/appPreviewSets/iphone'));
      expect(
        client.requests,
        isNot(contains('DELETE /v1/appPreviewSets/ipad')),
        reason: 'publishing iPhone previews must not clear the iPad set',
      );
    });

    test('a dry run says what it would pose the preview at', () async {
      // The one thing a dry run of this can usefully report. Nothing else
      // shows the poster frame before it is permanent.
      final client = _FakeClient();
      final said = await _printed(
        () => storeOf(client, dryRun: true).replacePreviews(
          _localization,
          'IPHONE_67',
          [_video('promo.mp4', 'bytes', timeCode: '00:00:02:06')],
        ),
      );

      expect(said, contains('would send promo.mp4'));
      expect(said, contains('00:00:02:06'));
      expect(client.uploads, isEmpty);
    });

    test('a dry run over a video with no sidecar names the default', () async {
      final said = await _printed(
        () => storeOf(_FakeClient(), dryRun: true).replacePreviews(
          _localization,
          'IPHONE_67',
          [_video('promo.mp4', 'bytes')],
        ),
      );
      expect(said, contains(defaultPreviewFrameTimeCode));
    });
  });

  group('waiting for Apple', () {
    AppStore storeOf(_FakeClient client) => AppStore(
      client,
      Writer(client, dryRun: false),
      platform: AscPlatform.ios,
    );

    test('a COMPLETE video with a pending frame is not done', () async {
      // Apple cuts the poster out of the video after ingesting it, so this is
      // the ordinary intermediate state — and calling it done is how a run
      // submits a version whose poster frame has not been made yet.
      final client = _FakeClient()
        ..polls = [
          _preview(videoState: 'COMPLETE'),
          _preview(videoState: 'COMPLETE', frameState: 'COMPLETE'),
        ];

      await _printed(
        () => storeOf(
          client,
        ).awaitPreviewProcessing(['preview-1'], poll: Duration.zero),
      );

      expect(
        client.requests.where((r) => r.contains('appPreviews')),
        hasLength(2),
      );
    });

    test('a frame state Apple never reports does not wait for ever', () async {
      // **The wait had exactly one success condition — both COMPLETE — so a
      // preview whose `previewFrameImage` Apple simply does not report could
      // never finish.** Every release would poll the full timeout and then
      // throw a 504 about processing that had not finished, on an upload that
      // was completely fine. Nothing has watched a real preview through the
      // queue, so this is bounded rather than assumed either way.
      final client = _FakeClient()
        ..polls = [_preview(fileName: 'promo.mp4', videoState: 'COMPLETE')];

      final said = await _printed(
        () => storeOf(client).awaitPreviewProcessing(
          ['preview-1'],
          poll: Duration.zero,
          framePolls: 2,
        ),
      );

      expect(said, contains('no poster-frame state'));
      // Bounded, and it did wait: the grace period is what distinguishes this
      // from treating a null as done on the first poll, which would submit
      // while a frame was genuinely still being cut.
      expect(
        client.requests.where((r) => r.contains('appPreviews')),
        hasLength(2),
      );
    });

    test('a failed poster frame is a rejection, not a success', () async {
      final client = _FakeClient()
        ..polls = [
          _preview(
            fileName: 'promo.mp4',
            videoState: 'COMPLETE',
            frameState: 'FAILED',
            frameTimeCode: '00:00:44:00',
          ),
        ];

      await expectLater(
        _printed(
          () => storeOf(
            client,
          ).awaitPreviewProcessing(['preview-1'], poll: Duration.zero),
        ),
        throwsA(
          isA<AscApiException>().having(
            (e) => e.toString(),
            'message',
            allOf(
              contains('promo.mp4'),
              // With no error text from Apple, the guess has to be the right
              // one: it was the frame that failed, so the timecode is what to
              // look at, and the message says the value.
              contains('previewFrameTimeCode'),
              contains('00:00:44:00'),
            ),
          ),
        ),
      );
    });

    test('a failed video on commit says what to look at', () async {
      // The screenshot path has carried this hint since the day the commit
      // response stopped being discarded; the preview path did not, so an
      // immediate FAILED with an empty errors[] produced one sentence naming
      // the file and nothing about what to do with it.
      final client = _FakeClient()..failCommitWithoutReason = true;

      await expectLater(
        _printed(
          () => storeOf(client).replacePreviews(_localization, 'IPHONE_67', [
            _video('promo.mp4', 'bytes', timeCode: '00:00:02:06'),
          ]),
        ),
        throwsA(
          isA<AscApiException>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('promo.mp4'), contains('dry-run')),
          ),
        ),
      );
    });

    test('a failed video names the four rules checked offline', () async {
      final client = _FakeClient()
        ..polls = [_preview(fileName: 'promo.mp4', videoState: 'FAILED')];

      await expectLater(
        _printed(
          () => storeOf(
            client,
          ).awaitPreviewProcessing(['preview-1'], poll: Duration.zero),
        ),
        throwsA(
          isA<AscApiException>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('dry-run'), contains('frame rate')),
          ),
        ),
      );
    });

    test('a timeout says that waiting a day is normal', () async {
      // The message matters more here than anywhere else in this file. The
      // natural reading of a timeout is that the upload failed; it did not,
      // and Apple's own guidance is up to 24 hours. A caller told
      // "processing failed" goes looking for a broken upload that is fine.
      final client = _FakeClient()
        ..polls = [_preview(videoState: 'PROCESSING')];

      await expectLater(
        _printed(
          () => storeOf(client).awaitPreviewProcessing(
            ['preview-1'],
            timeout: Duration.zero,
            poll: Duration.zero,
          ),
        ),
        throwsA(
          isA<AscApiException>().having(
            (e) => e.toString(),
            'message',
            allOf(
              contains('24 hours'),
              contains('not a failure'),
              contains('uploaded'),
            ),
          ),
        ),
      );
    });

    test('a dry run waits for nothing', () async {
      final client = _FakeClient();
      await AppStore(
        client,
        Writer(client, dryRun: true),
        platform: AscPlatform.ios,
      ).awaitPreviewProcessing(['preview-1'], poll: Duration.zero);
      expect(client.requests, isEmpty);
    });
  });

  group('the tree decides whether a version is needed', () {
    test('a locale carrying only previews needs one', () {
      // The predicate is the count of what the version-scoped half writes, and
      // previews are the fifth thing it writes. A tree of previews alone that
      // reported "no version needed" would create no version, publish nothing,
      // and say nothing — which is what this predicate already shipped once.
      final metadata = AppStoreMetadata();
      final locale = LocaleMetadata('en-US');
      locale.previews['IPHONE_67'] = [
        (file: File('unused.mp4'), frameTimeCode: null),
      ];
      metadata.locales.add(locale);

      expect(listingNeedsVersion(metadata), isTrue);
    });
  });
}
