// SPDX-License-Identifier: Apache-2.0
//
// A beta group's *name* is the one input `--beta-group` cannot infer, default
// or guess, and until `beta-groups` existed nothing printed one: the only
// command that touched groups filtered by exact name, so a caller who did not
// already know the name had to leave the tool and read App Store Connect.
//
// Both tests here are about that single fact — one gives the name away up
// front, the other gives it away at the moment somebody has just proved they
// do not have it.
import 'dart:io';

import 'package:cux_ship/src/appstore/app_store.dart';
import 'package:cux_ship/src/appstore/asc_client.dart';
import 'package:cux_ship/src/appstore/cli.dart' show AscCommand;
import 'package:test/test.dart';

/// Canned App Store Connect. `beta_release_test.dart`'s shape, narrowed to the
/// one collection these tests read.
class _FakeClient implements AscClient {
  _FakeClient(this.groups);

  final List<Map<String, dynamic>> groups;
  final List<String> requests = <String>[];

  /// Makes the *unfiltered* listing throw, which is the enrichment call and not
  /// the lookup — so a test can fail one without failing the other.
  bool failUnfiltered = false;

  @override
  Future<List<Map<String, dynamic>>> getAll(
    String path, {
    Map<String, String>? query,
  }) async {
    requests.add(
      'GET $path${query?['filter[name]'] == null ? '' : ' by name'}',
    );
    if (failUnfiltered && query?['filter[name]'] == null) {
      throw const SocketException('connection reset');
    }
    // The real endpoint filters server-side, so the fake has to as well —
    // otherwise a lookup for a name that does not exist would come back full
    // and the 404 under test would never be reached.
    final wanted = query?['filter[name]'];
    if (wanted == null) {
      return groups;
    }
    return groups
        .where(
          (g) => (g['attributes'] as Map<String, dynamic>?)?['name'] == wanted,
        )
        .toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _group(String name, {required bool internal}) => {
  'id': 'id-$name',
  'attributes': {'name': name, 'isInternalGroup': internal},
};

/// Captures what a command printed. `beta_release_test.dart`'s shape.
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

  test('it prints every group and, for each, the kind', () async {
    // **The kind is half the answer, not decoration.** Assignment alone
    // delivers an internal group within minutes and delivers an external one
    // nothing at all until beta review passes — so a reader choosing a name
    // from this list is choosing how much a release costs.
    final client = _FakeClient([
      _group('howitwent testers', internal: true),
      _group('Beta Testers', internal: false),
    ]);
    final out = await _printed(() => storeOf(client).listBetaGroups(app));

    expect(out, contains('howitwent testers'));
    expect(out, contains('internal'));
    expect(out, contains('Beta Testers'));
    expect(out, contains('external'));
  });

  test('with no groups it says where they are made, not just that there '
      'are none', () async {
    // Groups cannot be created over the API, so "none" without that sentence
    // reads as a thing to fix with a flag.
    final out = await _printed(
      () => storeOf(_FakeClient([])).listBetaGroups(app),
    );

    expect(out, contains('no beta groups'));
    expect(out, contains('App Store Connect'));
    expect(out, contains('cannot be created over the API'));
  });

  test('a lookup that misses names the groups that exist', () async {
    // **The 404 that sent me to the console.** Filtering by exact name answers
    // only about the name asked for, so a refusal that stops there withholds
    // the one string the caller is missing — and it is in the response the
    // command is already entitled to make.
    final client = _FakeClient([
      _group('howitwent testers', internal: true),
      _group('Beta Testers', internal: false),
    ]);

    await expectLater(
      storeOf(client).findBetaGroup(app, 'Externa1 Testers'),
      throwsA(
        isA<AscApiException>().having(
          (e) => e.toString(),
          'message',
          allOf(
            contains('no beta group called "Externa1 Testers"'),
            contains('"Beta Testers" (external)'),
            contains('"howitwent testers" (internal)'),
          ),
        ),
      ),
    );
  });

  test('a listing that fails keeps the refusal it was meant to improve', () async {
    // **The enrichment is a second network call inside a failure path.** If it
    // throws, the useful refusal — the group does not exist — would be replaced
    // by an unrelated transport error, and the diagnosis lost to the thing
    // added to improve it. Worth having, never worth the original message.
    final client = _FakeClient([_group('Beta Testers', internal: false)])
      ..failUnfiltered = true;

    await expectLater(
      storeOf(client).findBetaGroup(app, 'Externa1 Testers'),
      throwsA(
        isA<AscApiException>().having(
          (e) => e.toString(),
          'message',
          allOf(
            contains('no beta group called "Externa1 Testers"'),
            // Falls back to the guidance it had before the listing existed.
            contains('App Store Connect > TestFlight > Groups'),
            isNot(contains('This app has')),
          ),
        ),
      ),
    );
  });

  test('it is a read, so it returns before anything can be written', () {
    // The property that makes it safe to reach for while diagnosing a failed
    // release, which is exactly when somebody will.
    expect(AscCommand.betaGroups.isRead, isTrue);
    expect(AscCommand.betaGroups.name, 'beta-groups');
  });
}
