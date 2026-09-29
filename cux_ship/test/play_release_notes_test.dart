// SPDX-License-Identifier: Apache-2.0
//
// A Play release carries one `LocalizedText` per language, and a listing with
// a German translation showed German readers whatever the one element said.
// Both uploaders wrote one locale; this is the Play half of making them write
// every declared one. The App Store half, where a missing locale was a refused
// submission rather than an untranslated page, is
// `appstore/release_notes_on_upload_test.dart`.
//
// Driven through `runPlay` rather than `_assignToTrack`, because which
// languages reach the call is decided by the run — the declared set, the
// listing default, the locale files — and a test of the builder alone would
// pass while the run handed it one language.
import 'dart:io';

import 'package:cux_ship/src/listing_requirements.dart';
import 'package:cux_ship/src/play/cli.dart';
import 'package:googleapis/androidpublisher/v3.dart';
import 'package:test/test.dart';

/// Canned `androidpublisher`, narrowed to what an upload of a bundle Play
/// already holds calls — so the run reaches the track assignment without a
/// transfer, which is `play_upload_reuse_test.dart`'s subject and not this
/// one's.
class _FakeApi implements AndroidPublisherApi {
  /// The tracks written, which carry the release notes.
  final assigned = <Track>[];

  @override
  EditsResource get edits => _FakeEdits(this);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeEdits implements EditsResource {
  _FakeEdits(this.api);

  final _FakeApi api;

  @override
  EditsTracksResource get tracks => _FakeTracks(api);

  @override
  EditsBundlesResource get bundles => _FakeBundles();

  @override
  Future<AppEdit> insert(
    AppEdit request,
    String packageName, {
    String? $fields,
  }) async => AppEdit(id: 'edit-1');

  @override
  Future<void> delete(
    String packageName,
    String editId, {
    String? $fields,
  }) async {}

  @override
  Future<AppEdit> commit(
    String packageName,
    String editId, {
    bool? changesNotSentForReview,
    String? $fields,
  }) async => AppEdit(id: editId);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeBundles implements EditsBundlesResource {
  @override
  Future<BundlesListResponse> list(
    String packageName,
    String editId, {
    String? $fields,
  }) async => BundlesListResponse(bundles: [Bundle(versionCode: 7)]);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTracks implements EditsTracksResource {
  _FakeTracks(this.api);

  final _FakeApi api;

  @override
  Future<Track> update(
    Track request,
    String packageName,
    String editId,
    String track, {
    String? $fields,
  }) async {
    api.assigned.add(request);
    return request;
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

late Directory _root;

void _write(String name, String contents) =>
    File('${_root.path}/$name').writeAsStringSync(contents);

/// One `play upload --aab --changelog` of build 7, with [declared] as
/// `play.locales`.
Future<List<(String?, String?)>> _releaseNotes({Set<String>? declared}) async {
  final api = _FakeApi();
  final args = buildPlayParser(PlayCommand.upload).parse([
    '--package',
    'design.codeux.example',
    '--aab',
    '${_root.path}/app.aab',
    '--build-number',
    '7',
    '--version-name',
    '1.1.9',
    '--track',
    'internal',
    '--changelog',
    '${_root.path}/CHANGELOG.md',
  ]);
  final captured = _MemoryStdout();
  await IOOverrides.runZoned(
    () => runPlay(
      PlayCommand.upload,
      args,
      androidPublisher: api,
      defaults: PlayDefaults(
        listingRequirements: declared == null
            ? null
            : ListingRequirements(locales: declared),
      ),
    ),
    stdout: () => captured,
    stderr: () => captured,
  );
  await captured.close();
  expect(
    api.assigned,
    hasLength(1),
    reason: 'the run did not reach the track:\n${captured.buffer}',
  );
  return [
    for (final text in api.assigned.single.releases!.single.releaseNotes!) ...[
      (text.language, text.text),
    ],
  ];
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('play_release_notes');
    _write('app.aab', 'not really an aab');
    _write('CHANGELOG.md', '## 1.1.9\n\n- Drag files in\n');
  });

  tearDown(() => _root.deleteSync(recursive: true));

  test('with nothing declared, one element in the default language', () async {
    // Every release before locales could be declared, byte for byte.
    expect(await _releaseNotes(), [('en-US', '- Drag files in')]);
  });

  test('one element per declared language, none repeated', () async {
    // Play refuses a repeated language outright ("Release notes are badly
    // constructed or have duplicates"), so the default language, which is
    // also declared, must appear once.
    expect(await _releaseNotes(declared: {'en-US', 'de-DE'}), [
      ('en-US', '- Drag files in'),
      ('de-DE', '- Drag files in'),
    ]);
  });

  test("a locale file is that language's text", () async {
    _write('CHANGELOG.de-DE.md', '## 1.1.9\n\n- Dateien hineinziehen\n');

    expect(await _releaseNotes(declared: {'en-US', 'de-DE'}), [
      ('en-US', '- Drag files in'),
      ('de-DE', '- Dateien hineinziehen'),
    ]);
  });
}
