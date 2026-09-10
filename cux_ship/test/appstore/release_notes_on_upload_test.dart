// SPDX-License-Identifier: Apache-2.0
//
// `upload --metadata --changelog CHANGELOG.md` accepted the flag and wrote no
// "What's New in This Version". The App Store showed it empty.
//
// **The write existed and lived in the promote block**, so `promote
// --changelog` was correct and the listing-only publish silently was not —
// and the consumer who found it has a flow that never reaches promote by
// design: publish everything, look at it in App Store Connect, then submit by
// hand. A flag taken and dropped, on copy a shopper reads.
//
// **These drive `runAsc` rather than `publishReleaseNotes`**, and that is the
// whole point. The rules the function carries — a first version has no "What's
// New", and Apple refuses emoji — were never the bug; the bug was that one of
// two publishers did not call it. A test of the function alone would have
// passed on the day this shipped.
import 'dart:io';

import 'package:cux_ship/src/appstore/asc_client.dart';
import 'package:cux_ship/src/appstore/cli.dart';
import 'package:test/test.dart';

/// Canned App Store Connect for a listing-only publish.
///
/// **It honours `filter[platform]` on the versions collection**, because
/// `isFirstVersion` is a question about that collection and the whole
/// first-version branch turns on the answer: a fake returning one version
/// would send every case down "this app's first", where no notes are written
/// and this suite would agree with a program that never wrote any.
class _FakeClient implements AscClient {
  _FakeClient({this.versions = const []});

  /// What Apple holds for the platform, before this run.
  final List<Map<String, dynamic>> versions;

  final posted = <({String path, Map<String, dynamic> body})>[];
  final patched = <({String path, Map<String, dynamic> body})>[];

  @override
  Future<List<Map<String, dynamic>>> getAll(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path == '/v1/apps') {
      // **Exact-matched, because `resolveApp` is.** `filter[bundleId]` is a
      // prefix match on Apple's side, so the real client has to sort a
      // `...example.beta` from `...example` itself — a fake that returned one
      // app whatever was asked could not reach that branch.
      return [
        for (final id in ['app-1'])
          if (query?['filter[bundleId]'] == 'design.codeux.example')
            {
              'type': 'apps',
              'id': id,
              'attributes': {
                'bundleId': 'design.codeux.example',
                'name': 'Example',
              },
            },
      ];
    }
    if (path.endsWith('/appStoreVersions')) {
      final all = [...versions, ..._created];
      final wanted = query?['filter[versionString]'];
      if (wanted == null) {
        return all;
      }
      return all
          .where(
            (v) =>
                (v['attributes'] as Map<String, dynamic>)['versionString'] ==
                wanted,
          )
          .toList();
    }
    // No appInfos, no existing localizations: the tree here carries only
    // version-scoped text, so the app-level half has nothing to compare and
    // the locale has no record yet.
    return const [];
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async => const {};

  /// Whether Apple refuses the `whatsNew` write for this version's state.
  ///
  /// **The shape nobody has confirmed.** `Attribute 'whatsNew' cannot be
  /// edited at this time` is known to fire for a first version and for one
  /// locked by review; whether it also fires for a version with no build
  /// attached is unverified, and that state is reachable only from this
  /// caller. A fake that always accepted the write could not tell a run that
  /// reports the refusal from one that dies with Apple's own opaque line.
  bool refusesWhatsNew = false;

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (refusesWhatsNew && _carriesWhatsNew(body)) {
      throw AscApiException(409, [
        "Attribute 'whatsNew' cannot be edited at this time",
      ], request: 'POST $path');
    }
    posted.add((path: path, body: body));
    if (path == '/v1/appStoreVersions') {
      // **A created version joins the collection, because Apple's does.**
      // Without this, `isFirstVersion` evaluates `[].every(...)` — vacuously
      // true — so the first-version branch was reached for a reason the real
      // API never produces, and mutating the predicate to `all.isEmpty` left
      // this suite green while breaking every real first release. The
      // CONTRIBUTING rule about a fake carrying what the tested branch depends
      // on, and this branch depends on the new version being counted.
      _created.add({
        'type': 'appStoreVersions',
        'id': 'version-1',
        'attributes': {
          'versionString': '1.1.6',
          'appStoreState': 'PREPARE_FOR_SUBMISSION',
        },
      });
      return {'data': _created.last};
    }
    return {
      'data': {
        'type': 'appStoreVersionLocalizations',
        'id': 'loc-1',
        'attributes': <String, dynamic>{},
      },
    };
  }

  /// Versions this run created, which Apple would list beside the rest.
  final _created = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> patch(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (refusesWhatsNew && _carriesWhatsNew(body)) {
      throw AscApiException(409, [
        "Attribute 'whatsNew' cannot be edited at this time",
      ], request: 'PATCH $path');
    }
    patched.add((path: path, body: body));
    return {'data': <String, dynamic>{}};
  }

  static bool _carriesWhatsNew(Map<String, dynamic> body) {
    final data = body['data'];
    final attributes = data is Map<String, dynamic> ? data['attributes'] : null;
    return attributes is Map<String, dynamic> &&
        attributes.containsKey('whatsNew');
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

late Directory _root;

void _write(String relative, String contents) {
  final file = File('${_root.path}/$relative');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

/// Every `whatsNew` this run sent, from whichever verb carried it.
///
/// **Both a POST and a PATCH can carry it** — `writeVersionLocalization`
/// chooses by whether Apple already holds a record for the locale — so a test
/// that watched one verb would pass or fail on the fixture's state rather than
/// on the program's behaviour.
List<String> _whatsNewSent(_FakeClient client) => [
  for (final write in [...client.posted, ...client.patched]) ...{
    ...() {
      final data = write.body['data'];
      final attributes = data is Map<String, dynamic>
          ? data['attributes']
          : null;
      final value = attributes is Map<String, dynamic>
          ? attributes['whatsNew']
          : null;
      return value is String ? [value] : <String>[];
    }(),
  },
];

Future<String> _upload(_FakeClient client, {List<String> extra = const []}) {
  final args = buildAscParser(AscCommand.upload).parse([
    '--bundle-id',
    'design.codeux.example',
    '--version-name',
    '1.1.6',
    '--metadata',
    '${_root.path}/store/appstore',
    '--changelog',
    '${_root.path}/CHANGELOG.md',
    ...extra,
  ]);
  // **Both streams**, because `runAsc` catches an App Store refusal and
  // reports it on stderr rather than letting it out — so a test that watched
  // stdout alone would see a run that looked like it finished.
  final captured = _MemoryStdout();
  return IOOverrides.runZoned(
    () async {
      await runAsc(AscCommand.upload, args, ascClient: client);
      await captured.close();
      return captured.buffer.toString();
    },
    stdout: () => captured,
    stderr: () => captured,
  );
}

Map<String, dynamic> _version(String id, String name) => {
  'type': 'appStoreVersions',
  'id': id,
  'attributes': {'versionString': name},
};

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('asc_notes_test');
    _write(
      'CHANGELOG.md',
      '# Changelog\n\n## 1.1.6\n\n- A shorter tour intro\n\n## 1.1.5\n\n- Older\n',
    );
    _write(
      'store/appstore/listings/en-US/description.txt',
      'A simulation, not a game.',
    );
  });

  tearDown(() => _root.deleteSync(recursive: true));

  test('a listing-only upload publishes the release notes', () async {
    // The defect: this wrote the description and nothing else, so App Store
    // Connect showed "What's New in This Version" empty while the command had
    // been given the changelog it should have come from.
    final client = _FakeClient(versions: [_version('old', '1.1.5')]);

    await _upload(client);

    expect(_whatsNewSent(client), ['- A shorter tour intro']);
  });

  test('a first version still has no "What\'s New"', () async {
    // Apple refuses the write with a message that does not explain itself, so
    // the rule has to travel with the write rather than sit at one call site
    // — which is the whole reason this is one function with two callers.
    final client = _FakeClient();

    final said = await _upload(client);

    expect(_whatsNewSent(client), isEmpty);
    expect(said, contains('first App Store version'));
  });

  test('emoji are stripped, and the run says which', () async {
    // Measured, after this file spent a release asserting the opposite. This
    // is copy a shopper reads, so publishing something other than what the
    // changelog says is worth three lines of output.
    _write(
      'CHANGELOG.md',
      '# Changelog\n\n## 1.1.6\n\n- 🚴 A shorter tour intro\n\n## 1.1.5\n\n- Old\n',
    );
    final client = _FakeClient(versions: [_version('old', '1.1.5')]);

    final said = await _upload(client);

    expect(_whatsNewSent(client).single, isNot(contains('🚴')));
    expect(said, contains('rejects emoji'));
  });

  test('no changelog means no release-notes write, not an empty one', () async {
    // "Present means owned" reaches this too: a run that names no notes
    // should leave whatever Apple holds rather than blanking it.
    final client = _FakeClient(versions: [_version('old', '1.1.5')]);
    // No `--changelog`, and no CHANGELOG.md to infer one from: the file is
    // written into the temp root, and nothing points this run at it.
    File('${_root.path}/CHANGELOG.md').deleteSync();
    final args = buildAscParser(AscCommand.upload).parse([
      '--bundle-id',
      'design.codeux.example',
      '--version-name',
      '1.1.6',
      '--metadata',
      '${_root.path}/store/appstore',
    ]);
    final captured = _MemoryStdout();
    await IOOverrides.runZoned(
      () => runAsc(AscCommand.upload, args, ascClient: client),
      stdout: () => captured,
    );
    await captured.close();

    expect(_whatsNewSent(client), isEmpty);
  });

  test(
    'a refused "What\'s New" names the causes, and says the listing landed',
    () async {
      // **Unverified, and handled anyway.** Apple's refusal is a *state*
      // refusal; it is known to fire for a first version (removed by
      // `isFirstVersion`) and for one locked by review, and it may fire for a
      // version with no build — a state only this caller can reach, because the
      // promote path always has a build by the time it writes.
      //
      // Rethrown rather than swallowed: a consumer whose acceptance criterion is
      // "the changelog lands" has to be told when it did not, and the listing
      // itself is already published so a repeat costs a re-run rather than a
      // half-written page.
      final client = _FakeClient(versions: [_version('old', '1.1.5')])
        ..refusesWhatsNew = true;

      final said = await _upload(client);

      // Apple's own line, unaltered — it stays in `details`, which is
      // documented as one entry per Apple `errors[]` element.
      expect(said, contains('cannot be edited at this time'));
      // And cux_ship's explanation, which now arrives through
      // `AscApiException.guidanceFor` rather than by being appended to
      // Apple's words.
      expect(said, contains('locked by review'));
      expect(said, contains('already published'));
      expect(said, contains('promote --changelog'));
      // The half that matters: Apple's own line alone would say nothing about
      // which of its causes applied, or that the rest of the publish landed.
      expect(_whatsNewSent(client), isEmpty);
    },
  );

  // **Two behaviours here are implemented and not covered, and saying which
  // beats a test that passes vacuously.**
  //
  // A missing changelog section is fatal only when `--changelog` or
  // `--release-notes` *named* one; where the path is merely inferred from the
  // project, an absent section means no notes. Neither half survives this
  // harness. `fail` exits rather than throws — deliberately, with its own
  // comment saying why — so the named case kills the runner instead of
  // reaching an expectation. And the inferred case cannot be reached at all:
  // `changelogPath` falls back to `defaults.changelog`, which is empty when
  // `runAsc` is called directly, so a test written for it has no changelog to
  // infer and asserts nothing. A first draft of that test sat here and passed
  // for exactly that reason.
  //
  // What *is* held, and structurally rather than by assertion: the resolution
  // moved above the line that builds the client, so whichever way it refuses,
  // nothing has been written when it does. The old call site sat after
  // `_publishAscListing` had published the entire listing.

  test('notes are not written to a locale the tree does not declare', () async {
    // The notes go to the CLI's `--locale`, which defaults to en-US, while the
    // tree declares its own. A de-DE-only tree published without
    // `--locale de-DE` would POST a *new* en-US version localization carrying
    // release notes and no description — a record nothing in the tree owns.
    File(
      '${_root.path}/store/appstore/listings/en-US/description.txt',
    ).deleteSync();
    _write(
      'store/appstore/listings/de-DE/description.txt',
      'Eine Simulation, kein Spiel.',
    );
    final client = _FakeClient(versions: [_version('old', '1.1.5')]);

    final said = await _upload(client);

    expect(_whatsNewSent(client), isEmpty);
    expect(said, contains('release notes skipped'));
    expect(said, contains('--locale de-DE'));
  });

  test('an app-level-only tree says why the notes were skipped', () async {
    // A tree declaring only app-level fields needs no version, so there is
    // nothing to hang release notes off. The notes are genuinely not
    // publishable — but saying nothing is what the original defect did, and a
    // flag taken and dropped must not read as a command that did what it was
    // asked.
    Directory(
      '${_root.path}/store/appstore/listings',
    ).deleteSync(recursive: true);
    _write(
      'store/appstore/info/content_rights.txt',
      'DOES_NOT_USE_THIRD_PARTY_CONTENT',
    );
    final client = _FakeClient(versions: [_version('old', '1.1.5')]);

    final said = await _upload(client);

    expect(_whatsNewSent(client), isEmpty);
    expect(said, contains('release notes skipped'));
    expect(said, contains('nothing Apple scopes'));
  });

  test(
    'a dry run over an editable version reports the notes it would write',
    () async {
      // **`--dry-run` has two shapes and the test below only reaches one.**
      // `ensureVersion` returns null on a dry run *only when it would have had
      // to create* the version; when an editable one already exists it returns
      // the real record, so `published != null` and the notes path runs. The
      // other test's fixtures carry no `appStoreState`, so `editable` is empty
      // and the create branch is taken — it would pass identically if
      // `publishReleaseNotes` ran on every dry run, because `Writer` suppresses
      // the write either way. It asserted the right thing for the wrong reason.
      final client = _FakeClient(
        versions: [
          {
            'type': 'appStoreVersions',
            'id': 'existing',
            'attributes': {
              'versionString': '1.1.6',
              'appStoreState': 'PREPARE_FOR_SUBMISSION',
            },
          },
          _version('old', '1.1.5'),
        ],
      );

      final said = await _upload(client, extra: ['--dry-run']);

      expect(said, contains('release notes'));
      expect(said, contains('would'));
      expect(client.posted, isEmpty);
      expect(client.patched, isEmpty);
    },
  );

  test('a dry run writes nothing at all', () async {
    final client = _FakeClient(versions: [_version('old', '1.1.5')]);

    await _upload(client, extra: ['--dry-run']);

    expect(client.posted, isEmpty);
    expect(client.patched, isEmpty);
  });
}
