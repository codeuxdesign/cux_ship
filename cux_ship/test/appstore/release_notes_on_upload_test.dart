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
import 'package:cux_ship/src/listing_requirements.dart';
import 'package:test/test.dart';

/// Canned App Store Connect for a listing-only publish.
///
/// **It honours `filter[platform]` on the versions collection**, because
/// `isFirstVersion` is a question about that collection and the whole
/// first-version branch turns on the answer: a fake returning one version
/// would send every case down "this app's first", where no notes are written
/// and this suite would agree with a program that never wrote any.
///
/// **And it holds the version localizations a run creates**, because the
/// notes now go to every localization Apple holds — so which records exist is
/// the question the tested branch selects on. A fake answering the
/// localizations listing with nothing, as this one did, would send every run
/// down the "Apple holds none" branch, and a loop over one locale would be
/// indistinguishable from a loop over all of them. A POST adds the record,
/// the listing returns what exists, and `filter[locale]` is honoured where a
/// caller passes it — each carrying what Apple's collection does.
class _FakeClient implements AscClient {
  _FakeClient({
    this.versions = const [],
    Iterable<String> heldLocales = const [],
  }) : _localizations = [
         for (final locale in heldLocales) ...[_localization(locale)],
       ];

  /// What Apple holds for the platform, before this run.
  final List<Map<String, dynamic>> versions;

  /// The version's `appStoreVersionLocalizations`, held and created.
  final List<Map<String, dynamic>> _localizations;

  /// Build 7's TestFlight "What to Test" records, as Apple holds them.
  final betaBuildLocalizations = <Map<String, dynamic>>[];

  static Map<String, dynamic> _localization(String locale) => {
    'type': 'appStoreVersionLocalizations',
    'id': 'loc-$locale',
    'attributes': <String, dynamic>{'locale': locale},
  };

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
    if (path == '/v1/builds') {
      // One processed build, 7. `filter[version]` is honoured because
      // `findBuild` asks by number and a fake answering every number would
      // hide a wrong one.
      final wanted = query?['filter[version]'];
      return [
        if (wanted == null || wanted == '7') ...[
          {
            'type': 'builds',
            'id': 'build-7',
            'attributes': {'version': '7', 'processingState': 'VALID'},
          },
        ],
      ];
    }
    if (path == '/v1/betaBuildLocalizations') {
      // `filter[locale]` decides between POST and PATCH in `setWhatToTest`, so
      // it is honoured: a fake returning one record whatever was asked would
      // PATCH every locale onto the same one.
      return [
        for (final l in betaBuildLocalizations) ...[
          if ((l['attributes'] as Map<String, dynamic>)['locale'] ==
              query?['filter[locale]'])
            l,
        ],
      ];
    }
    if (path.endsWith('/appStoreVersionLocalizations')) {
      final wanted = query?['filter[locale]'];
      return [
        for (final l in _localizations) ...[
          if (wanted == null ||
              (l['attributes'] as Map<String, dynamic>)['locale'] == wanted)
            l,
        ],
      ];
    }
    // No appInfos: the tree here carries only version-scoped text, so the
    // app-level half has nothing to compare.
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
    if (path == '/v1/betaBuildLocalizations') {
      final attributes =
          (body['data'] as Map<String, dynamic>)['attributes']
              as Map<String, dynamic>;
      betaBuildLocalizations.add({
        'type': 'betaBuildLocalizations',
        'id': 'beta-${attributes['locale']}',
        'attributes': {...attributes},
      });
      return {'data': betaBuildLocalizations.last};
    }
    if (path == '/v1/appStoreVersionLocalizations') {
      final attributes =
          (body['data'] as Map<String, dynamic>)['attributes']
              as Map<String, dynamic>;
      _localizations.add(_localization(attributes['locale'] as String));
      return {'data': _localizations.last};
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

/// Every `whatsNew` this run sent, by the locale it went to.
///
/// A POST names its locale in the attributes; a PATCH names only the record,
/// whose id the fake derives from the locale. A list rather than a map, so a
/// locale written twice shows up twice.
List<(String, String)> _whatsNewByLocale(_FakeClient client) => [
  for (final write in [...client.posted, ...client.patched]) ...[
    if ((write.body['data'] as Map<String, dynamic>)['attributes']
        case {'whatsNew': final String text} && final attributes)
      (
        attributes['locale'] as String? ??
            write.path.substring(write.path.lastIndexOf('loc-') + 4),
        text,
      ),
  ],
];

Future<String> _upload(
  _FakeClient client, {
  List<String> extra = const [],
  Set<String> declared = const {},
}) => _run(AscCommand.upload, client, declared: declared, [
  '--metadata',
  '${_root.path}/store/appstore',
  ...extra,
]);

Future<String> _run(
  AscCommand cmd,
  _FakeClient client,
  List<String> extra, {
  Set<String> declared = const {},
}) {
  final args = buildAscParser(cmd).parse([
    '--bundle-id',
    'design.codeux.example',
    '--version-name',
    '1.1.6',
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
      await runAsc(
        cmd,
        args,
        ascClient: client,
        // What `.cux-ship.yaml`'s `appstore.locales` hands down, when a case
        // declares any.
        defaults: declared.isEmpty
            ? AscDefaults.none
            : AscDefaults(
                listingRequirements: ListingRequirements(locales: declared),
              ),
      );
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
    // `--locale en-US` against a de-DE-only tree would POST a *new* en-US
    // version localization carrying release notes and no description — a
    // record nothing in the tree owns. Named explicitly, the flag keeps its
    // one-locale meaning, and this is still refused loudly.
    File(
      '${_root.path}/store/appstore/listings/en-US/description.txt',
    ).deleteSync();
    _write(
      'store/appstore/listings/de-DE/description.txt',
      'Eine Simulation, kein Spiel.',
    );
    final client = _FakeClient(versions: [_version('old', '1.1.5')]);

    final said = await _upload(client, extra: ['--locale', 'en-US']);

    expect(_whatsNewSent(client), isEmpty);
    expect(said, contains('release notes skipped'));
    expect(said, contains('--locale de-DE'));
  });

  test('without --locale, a de-DE-only tree gets its notes in de-DE', () async {
    // What `--locale`'s en-US default used to get wrong in the other
    // direction: the notes went nowhere unless somebody named the locale.
    File(
      '${_root.path}/store/appstore/listings/en-US/description.txt',
    ).deleteSync();
    _write(
      'store/appstore/listings/de-DE/description.txt',
      'Eine Simulation, kein Spiel.',
    );
    final client = _FakeClient(versions: [_version('old', '1.1.5')]);

    await _upload(client);

    expect(_whatsNewByLocale(client), [('de-DE', '- A shorter tour intro')]);
  });

  group('every localization Apple holds gets "What\'s New"', () {
    // The 409 of 29 September 2026: a listing had gained de-DE, the notes went
    // to en-US alone, and Apple refused the review submission because a
    // localization of an update had no "What's New".
    setUp(() {
      _write(
        'store/appstore/listings/de-DE/description.txt',
        'Eine Simulation, kein Spiel.',
      );
    });

    test('with no locale file, each gets the changelog', () async {
      final client = _FakeClient(
        versions: [_version('old', '1.1.5')],
        heldLocales: ['en-US', 'de-DE'],
      );

      await _upload(client, declared: {'en-US', 'de-DE'});

      expect(_whatsNewByLocale(client), [
        ('en-US', '- A shorter tour intro'),
        ('de-DE', '- A shorter tour intro'),
      ]);
    });

    test('a locale file is that locale\'s, and only that locale\'s', () async {
      _write(
        'CHANGELOG.de-DE.md',
        '## 1.1.6\n\n- Ein kürzeres Intro\n\n## 1.1.5\n\n- Älter\n',
      );
      final client = _FakeClient(
        versions: [_version('old', '1.1.5')],
        heldLocales: ['en-US', 'de-DE'],
      );

      final said = await _upload(client, declared: {'en-US', 'de-DE'});

      expect(_whatsNewByLocale(client), [
        ('en-US', '- A shorter tour intro'),
        ('de-DE', '- Ein kürzeres Intro'),
      ]);
      expect(said, contains('de-DE ← CHANGELOG.de-DE.md'));
      expect(said, contains('en-US ← CHANGELOG.md (no CHANGELOG.en-US.md)'));
    });

    test('a locale the listing publish creates gets notes too', () async {
      // Apple holds only en-US before the run; the tree's de-DE record is
      // created by the listing publish, and the notes are written after it —
      // the shape a version gaining a language in the same run has.
      final client = _FakeClient(
        versions: [_version('old', '1.1.5')],
        heldLocales: ['en-US'],
      );

      await _upload(client, declared: {'en-US', 'de-DE'});

      expect(_whatsNewByLocale(client).map((w) => w.$1).toSet(), {
        'en-US',
        'de-DE',
      });
    });

    test('a localization nobody declares is written, and named', () async {
      // A localization with no "What's New" blocks the submission; one with
      // the default notes is merely untranslated. So it is written — and the
      // run says which, so it can be declared or removed on purpose.
      final client = _FakeClient(
        versions: [_version('old', '1.1.5')],
        heldLocales: ['en-US', 'de-DE', 'fr-FR'],
      );

      final said = await _upload(client, declared: {'en-US', 'de-DE'});

      expect(
        _whatsNewByLocale(client),
        contains(('fr-FR', '- A shorter tour intro')),
      );
      expect(
        said,
        contains('fr-FR: Apple holds a localization this repository'),
      );
    });

    test('--locale still means that one locale', () async {
      final client = _FakeClient(
        versions: [_version('old', '1.1.5')],
        heldLocales: ['en-US', 'de-DE'],
      );

      await _upload(
        client,
        declared: {'en-US', 'de-DE'},
        extra: ['--locale', 'de-DE'],
      );

      expect(_whatsNewByLocale(client), [('de-DE', '- A shorter tour intro')]);
    });

    test('a promote writes them after the listing creates a locale', () async {
      // **The order is the fix.** A promote wrote the notes before the listing
      // publish, so a localization the listing publish created — a language
      // gained in this very release — had none, and the submission that
      // follows is exactly the one Apple refused. Apple holds only en-US here
      // until the listing publishes de-DE.
      final client = _FakeClient(
        versions: [_version('old', '1.1.5')],
        heldLocales: ['en-US'],
      );

      await _run(
        AscCommand.promote,
        client,
        declared: {'en-US', 'de-DE'},
        ['--metadata', '${_root.path}/store/appstore'],
      );

      expect(_whatsNewByLocale(client).map((w) => w.$1).toSet(), {
        'en-US',
        'de-DE',
      });
      // And before the submission, which is what reads them.
      final writes = [
        for (final w in client.posted) ...[w.path],
      ];
      expect(
        writes.indexOf('/v1/reviewSubmissionItems'),
        greaterThan(writes.lastIndexOf('/v1/appStoreVersionLocalizations')),
      );
    });
  });

  group('TestFlight "What to Test" goes to every declared locale', () {
    // Not a submission requirement — Apple does not gate a beta on it — but a
    // German tester should read what a German shopper will.
    List<(String, String)> whatToTest(_FakeClient client) => [
      for (final l in client.betaBuildLocalizations) ...[
        (
          (l['attributes'] as Map<String, dynamic>)['locale'] as String,
          (l['attributes'] as Map<String, dynamic>)['whatsNew'] as String,
        ),
      ],
    ];

    test('one record per locale, each with its own text', () async {
      _write('CHANGELOG.de-DE.md', '## 1.1.6\n\n- Ein kürzeres Intro\n');
      final client = _FakeClient();

      await _run(
        AscCommand.whatToTest,
        client,
        declared: {'en-US', 'de-DE'},
        ['--build-number', '7'],
      );

      expect(whatToTest(client), [
        ('en-US', '- A shorter tour intro'),
        ('de-DE', '- Ein kürzeres Intro'),
      ]);
    });

    test('with --locale, only that one', () async {
      final client = _FakeClient();

      await _run(
        AscCommand.whatToTest,
        client,
        declared: {'en-US', 'de-DE'},
        ['--build-number', '7', '--locale', 'de-DE'],
      );

      expect(whatToTest(client), [('de-DE', '- A shorter tour intro')]);
    });

    test('with nothing declared, en-US as always', () async {
      final client = _FakeClient();

      await _run(AscCommand.whatToTest, client, ['--build-number', '7']);

      expect(whatToTest(client), [('en-US', '- A shorter tour intro')]);
    });
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
