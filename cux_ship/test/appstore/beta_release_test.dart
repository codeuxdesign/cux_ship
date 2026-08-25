// SPDX-License-Identifier: Apache-2.0
//
// Releasing to a beta group forks on what kind of group it is, and the
// external fork is the one with teeth: description, beta review, and a
// read-back of where the build landed. Each case here pins one decision the
// flow makes — internal groups keep their old behaviour to the byte, refusals
// come before the first write, and nothing is ever written twice.
//
// The client is a fake that logs every request, because what this flow
// promises is exactly a sequence of requests: which ones happen, which are
// skipped, and that a refusal happens before any write at all.
import 'dart:io';

import 'package:cux_ship/src/appstore/app_store.dart';
import 'package:cux_ship/src/appstore/asc_client.dart';
import 'package:cux_ship/src/appstore/beta_release.dart';
import 'package:cux_ship/src/release.dart' show ReleaseException;
import 'package:test/test.dart';

/// Canned App Store Connect, remembering everything it was asked.
class _FakeClient implements AscClient {
  _FakeClient({this.collections = const {}, this.resources = const {}});

  /// `getAll` answers, keyed by path.
  final Map<String, List<Map<String, dynamic>>> collections;

  /// `get` answers, keyed by path.
  final Map<String, Map<String, dynamic>> resources;

  /// Every request, as `METHOD path`, in order.
  final log = <String>[];

  /// The body of each write, keyed by `METHOD path`.
  final bodies = <String, Map<String, dynamic>>{};

  /// The query of each read, keyed by `GET path` — recorded because a filter
  /// is load-bearing: a submissions read without `filter[build]` is invalid
  /// at Apple, and a groups read without `filter[name]` answers with *every*
  /// group, whose first element then decides internal-versus-external.
  final queries = <String, Map<String, String>?>{};

  Iterable<String> get writes => log.where((r) => !r.startsWith('GET '));

  @override
  Future<List<Map<String, dynamic>>> getAll(
    String path, {
    Map<String, String>? query,
  }) async {
    log.add('GET $path');
    queries['GET $path'] = query;
    return collections[path] ?? const [];
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    log.add('GET $path');
    queries['GET $path'] = query;
    return resources[path] ?? const {};
  }

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    log.add('POST $path');
    bodies['POST $path'] = body;
    return const {};
  }

  @override
  Future<Map<String, dynamic>> patch(
    String path,
    Map<String, dynamic> body,
  ) async {
    log.add('PATCH $path');
    bodies['PATCH $path'] = body;
    return const {};
  }

  @override
  Future<void> delete(String path) async {
    log.add('DELETE $path');
  }

  @override
  AscCredentials get credentials => throw UnimplementedError();

  @override
  String get bearerToken => throw UnimplementedError();

  @override
  Future<void> uploadOperation(
    Map<String, dynamic> operation,
    List<int> chunk,
  ) => throw UnimplementedError();

  @override
  void close() {}
}

/// Collects what the flow says, because several of its promises are
/// sentences: the "unchanged" skip, the submission no-op, the read-back state.
class _MemoryStdout implements Stdout {
  final buffer = StringBuffer();

  @override
  void writeln([Object? object = '']) => buffer.writeln(object);

  @override
  void write(Object? object) => buffer.write(object);

  /// Nothing to release — the buffer is the point — but a `Stdout` is a
  /// `Sink`, and closing it is what lets the analyzer hold every other sink
  /// in the suite to the rule.
  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

App _app() => App('APP', 'HoldTheWheel', 'design.codeux.holdthewheel');

Map<String, dynamic> _build() => {
  'id': 'B1',
  'attributes': {'version': '52', 'processingState': 'VALID'},
};

Map<String, dynamic> _group({required bool internal}) => {
  'id': 'G1',
  'attributes': {'name': 'friends', 'isInternalGroup': internal},
};

Map<String, dynamic> _localization(String description) => {
  'id': 'L1',
  'attributes': {'locale': 'en-US', 'description': description},
};

const _assign = 'POST /v1/betaGroups/G1/relationships/builds';
const _patchDescription = 'PATCH /v1/betaAppLocalizations/L1';
const _submit = 'POST /v1/betaAppReviewSubmissions';

/// A listing tree holding a committed-looking beta description — no git
/// repository around it, which the dirty guard treats as clean, the same as
/// notes from a tarball.
Directory _tree(String description) {
  final dir = Directory.systemTemp.createTempSync('cux_ship_beta');
  addTearDown(() => dir.deleteSync(recursive: true));
  Directory('${dir.path}/listings/en-US').createSync(recursive: true);
  File(
    '${dir.path}/listings/en-US/beta_description.txt',
  ).writeAsStringSync(description);
  return dir;
}

/// Runs the flow with stdout captured, returning (output, wasInternal).
///
/// Resolution happens first and separately, exactly as the CLI now does it —
/// offline, before anything has touched the fake network.
Future<(String, bool)> _release(
  _FakeClient client, {
  required bool dryRun,
  String? metadataPath,
  String? descriptionPath,
}) async {
  final description = resolveBetaDescription(
    optionPath: descriptionPath,
    metadataPath: metadataPath,
    locale: 'en-US',
  );
  final store = AppStore(
    client,
    Writer(client, dryRun: dryRun),
    platform: AscPlatform.ios,
  );
  final captured = _MemoryStdout();
  final internal = await IOOverrides.runZoned(
    () => releaseToBetaGroup(
      store,
      _app(),
      _build(),
      'friends',
      locale: 'en-US',
      description: description,
      metadataPath: metadataPath,
    ),
    stdout: () => captured,
  );
  await captured.close();
  return (captured.buffer.toString(), internal);
}

void main() {
  test('an internal group is assignment alone, exactly as before', () async {
    final client = _FakeClient(
      collections: {
        '/v1/betaGroups': [_group(internal: true)],
      },
    );
    final (output, internal) = await _release(client, dryRun: false);

    expect(internal, isTrue);
    expect(client.writes, [_assign]);
    // No review, no description — not even a read of them. The internal path
    // has to stay byte-identical to what it always did.
    expect(client.log, ['GET /v1/betaGroups', _assign]);
    // The filters are load-bearing: without filter[name], Apple answers with
    // every group and `first` silently decides internal-versus-external.
    expect(client.queries['GET /v1/betaGroups'], {
      'filter[app]': 'APP',
      'filter[name]': 'friends',
    });
    expect(output, contains('added to beta group "friends"'));
    expect(output, isNot(contains('beta review')));
  });

  test('no description anywhere refuses before any write', () async {
    final client = _FakeClient(
      collections: {
        '/v1/betaGroups': [_group(internal: false)],
        '/v1/apps/APP/betaAppLocalizations': const [],
      },
    );

    await expectLater(
      _release(client, dryRun: false),
      throwsA(
        isA<ReleaseException>().having(
          (e) => e.message,
          'message',
          allOf(
            // Both remedies, because either one alone sends the reader down
            // a single path that may not be theirs.
            contains('beta_description.txt'),
            contains('TestFlight > Test Information'),
          ),
        ),
      ),
    );
    expect(client.writes, isEmpty, reason: 'the refusal must precede writes');
  });

  test('a description blanked on the console side also refuses', () async {
    // An empty string is Apple's idea of absent here, and treating it as
    // present would let the submission fail with the 422 this preflight
    // exists to pre-empt.
    final client = _FakeClient(
      collections: {
        '/v1/betaGroups': [_group(internal: false)],
        '/v1/apps/APP/betaAppLocalizations': [_localization('')],
      },
    );
    await expectLater(
      _release(client, dryRun: false),
      throwsA(isA<ReleaseException>()),
    );
    expect(client.writes, isEmpty);
  });

  test('the whole external release is one invocation', () async {
    // The acceptance case, verbatim: the build is already on App Store
    // Connect, the group is external, and beta_description.txt is in the
    // tree — one call assigns the group, reasserts the description, submits
    // for beta review, and reads back which state the build landed in.
    final tree = _tree('What the beta of HoldTheWheel is for.\n');
    final client = _FakeClient(
      collections: {
        '/v1/betaGroups': [_group(internal: false)],
        '/v1/apps/APP/betaAppLocalizations': [_localization('older text')],
        '/v1/betaAppReviewSubmissions': const [],
      },
      resources: {
        '/v1/builds/B1/buildBetaDetail': {
          'data': {
            'id': 'D1',
            'attributes': {'externalBuildState': 'WAITING_FOR_BETA_REVIEW'},
          },
        },
      },
    );

    final (output, internal) = await _release(
      client,
      dryRun: false,
      metadataPath: tree.path,
    );

    expect(internal, isFalse);
    expect(client.writes, [_assign, _patchDescription, _submit]);
    expect(
      (client.bodies[_patchDescription]!['data']
          as Map<String, dynamic>)['attributes'],
      {'description': 'What the beta of HoldTheWheel is for.'},
    );
    expect(
      (client.bodies[_submit]!['data']
          as Map<String, dynamic>)['relationships'],
      {
        'build': {
          'data': {'type': 'builds', 'id': 'B1'},
        },
      },
    );
    // An unfiltered betaAppReviewSubmissions read is invalid at Apple, so a
    // lost filter[build] would stay green here while every real run broke.
    expect(client.queries['GET /v1/betaAppReviewSubmissions'], {
      'filter[build]': 'B1',
    });
    expect(output, contains('is an external group'));
    expect(output, contains('external build state: WAITING_FOR_BETA_REVIEW'));
  });

  test('a description the store already holds is not rewritten', () async {
    // The Play-images lesson: a write of an identical value reports change
    // where there is none, so identical is said to be identical instead.
    final tree = _tree('Same text.\n');
    final client = _FakeClient(
      collections: {
        '/v1/betaGroups': [_group(internal: false)],
        '/v1/apps/APP/betaAppLocalizations': [_localization('Same text.')],
        '/v1/betaAppReviewSubmissions': const [],
      },
    );

    final (output, _) = await _release(
      client,
      dryRun: false,
      metadataPath: tree.path,
    );

    expect(client.writes, [_assign, _submit]);
    expect(output, contains('unchanged'));
  });

  test('an already-submitted build is a printed no-op, not a second '
      'submission', () async {
    // The retried-job case: a build is submitted for beta review at most
    // once, so the second run finds the first run's submission and says what
    // Apple says about it.
    final tree = _tree('Text.\n');
    final client = _FakeClient(
      collections: {
        '/v1/betaGroups': [_group(internal: false)],
        '/v1/apps/APP/betaAppLocalizations': [_localization('Text.')],
        '/v1/betaAppReviewSubmissions': [
          {
            'id': 'S1',
            'attributes': {'betaReviewState': 'WAITING_FOR_REVIEW'},
          },
        ],
      },
    );

    final (output, _) = await _release(
      client,
      dryRun: false,
      metadataPath: tree.path,
    );

    expect(client.writes, [_assign]);
    expect(output, contains('already submitted for beta review'));
    expect(output, contains('WAITING_FOR_REVIEW'));
  });

  test('a dry run reads everything and writes nothing', () async {
    final tree = _tree('New text.\n');
    final client = _FakeClient(
      collections: {
        '/v1/betaGroups': [_group(internal: false)],
        '/v1/apps/APP/betaAppLocalizations': [_localization('older')],
        '/v1/betaAppReviewSubmissions': const [],
      },
      resources: {
        '/v1/builds/B1/buildBetaDetail': {
          'data': {
            'id': 'D1',
            'attributes': {'externalBuildState': 'READY_FOR_BETA_SUBMISSION'},
          },
        },
      },
    );

    final (output, _) = await _release(
      client,
      dryRun: true,
      metadataPath: tree.path,
    );

    expect(client.writes, isEmpty);
    expect(output, contains('would create: added to beta group "friends"'));
    expect(output, contains('would update: beta app description'));
    expect(output, contains('would create: submitted for beta review'));
  });

  test('a description on another locale is enough to proceed', () async {
    // The preflight asks whether a description exists *anywhere*: a localized
    // app may keep its only one on its primary locale, and refusing that over
    // a default --locale en-US would be spurious. The write side still stays
    // scoped to --locale, which here supplies nothing — so nothing is written
    // beyond the assignment and the submission.
    final client = _FakeClient(
      collections: {
        '/v1/betaGroups': [_group(internal: false)],
        '/v1/apps/APP/betaAppLocalizations': [
          {
            'id': 'L2',
            'attributes': {'locale': 'de-DE', 'description': 'Nur hier.'},
          },
        ],
        '/v1/betaAppReviewSubmissions': const [],
      },
    );

    final (_, internal) = await _release(client, dryRun: false);

    expect(internal, isFalse);
    expect(client.writes, [_assign, _submit]);
  });

  test('a repo description with no localization record is created', () async {
    // The POST branch: an app whose locale has no betaAppLocalizations record
    // yet gets one created rather than a null-id PATCH. Pinned against the
    // fake only — the empirically verified call was the PATCH; see the PR.
    final tree = _tree('First description.\n');
    final client = _FakeClient(
      collections: {
        '/v1/betaGroups': [_group(internal: false)],
        '/v1/apps/APP/betaAppLocalizations': const [],
        '/v1/betaAppReviewSubmissions': const [],
      },
    );

    await _release(client, dryRun: false, metadataPath: tree.path);

    const create = 'POST /v1/betaAppLocalizations';
    expect(client.writes, [_assign, create, _submit]);
    expect(client.bodies[create]!['data'], {
      'type': 'betaAppLocalizations',
      'attributes': {'locale': 'en-US', 'description': 'First description.'},
      'relationships': {
        'app': {
          'data': {'type': 'apps', 'id': 'APP'},
        },
      },
    });
  });

  test('--beta-description against an internal group is refused', () async {
    // Refused rather than ignored: a flag that prints a warning and then does
    // nothing is advisory output people learn to skim. Only the flag — a tree
    // file is standing state, not an instruction, and the internal path stays
    // byte-identical (the case above).
    final tree = _tree('x');
    final flagFile = File('${tree.path}/explicit.txt')
      ..writeAsStringSync('Only externals read this.\n');
    final client = _FakeClient(
      collections: {
        '/v1/betaGroups': [_group(internal: true)],
      },
    );

    await expectLater(
      _release(client, dryRun: false, descriptionPath: flagFile.path),
      throwsA(
        isA<ReleaseException>().having(
          (e) => e.message,
          'message',
          contains('drop --beta-description'),
        ),
      ),
    );
    expect(client.writes, isEmpty, reason: 'refused before the assignment');
  });

  test('a rejected earlier submission fails the release, loudly', () async {
    // A REJECTED submission printed as a no-op would be a green release that
    // delivered nothing — the exact shape the external path exists to end.
    final client = _FakeClient(
      collections: {
        '/v1/betaGroups': [_group(internal: false)],
        '/v1/apps/APP/betaAppLocalizations': [_localization('Text.')],
        '/v1/betaAppReviewSubmissions': [
          {
            'id': 'S1',
            'attributes': {'betaReviewState': 'REJECTED'},
          },
        ],
      },
    );

    await expectLater(
      _release(client, dryRun: false),
      throwsA(
        isA<ReleaseException>().having(
          (e) => e.message,
          'message',
          allOf(contains('rejected'), contains('upload a new build')),
        ),
      ),
    );
    expect(client.writes, [_assign], reason: 'no second submission');
  });

  test('a dirty description file is refused, like a dirty changelog', () {
    final tree = _tree('Not yet reviewed.\n');
    Process.runSync('git', ['init', '-q'], workingDirectory: tree.path);

    expect(
      () => resolveBetaDescription(metadataPath: tree.path, locale: 'en-US'),
      throwsA(
        isA<ReleaseException>().having(
          (e) => e.message,
          'message',
          contains('uncommitted'),
        ),
      ),
    );
  });

  group('which file supplies the description', () {
    test('the flag wins over the tree', () {
      final tree = _tree('Tree text.\n');
      final flagFile = File('${tree.path}/other.txt')
        ..writeAsStringSync('Flag text.\n');

      final description = resolveBetaDescription(
        optionPath: flagFile.path,
        metadataPath: tree.path,
        locale: 'en-US',
      );
      expect(description!.text, 'Flag text.');
    });

    test('a flag pointing at nothing is refused', () {
      expect(
        () => resolveBetaDescription(
          optionPath: 'does/not/exist.txt',
          locale: 'en-US',
        ),
        throwsA(isA<ReleaseException>()),
      );
    });

    test('no flag and no tree file means the console owns it', () {
      final tree = _tree('x');
      File('${tree.path}/listings/en-US/beta_description.txt').deleteSync();
      expect(
        resolveBetaDescription(metadataPath: tree.path, locale: 'en-US'),
        isNull,
      );
    });

    test('an empty file is a refusal, not a blank publish', () {
      final tree = _tree('   \n');
      expect(
        () => resolveBetaDescription(metadataPath: tree.path, locale: 'en-US'),
        throwsA(
          isA<ReleaseException>().having(
            (e) => e.message,
            'message',
            contains('delete the file'),
          ),
        ),
      );
    });

    test('the limit is enforced here, where fixing it is free', () {
      final tree = _tree('x' * (betaAppDescriptionLimit + 1));
      expect(
        () => resolveBetaDescription(metadataPath: tree.path, locale: 'en-US'),
        throwsA(
          isA<ReleaseException>().having(
            (e) => e.message,
            'message',
            contains('$betaAppDescriptionLimit'),
          ),
        ),
      );
    });
  });
}
