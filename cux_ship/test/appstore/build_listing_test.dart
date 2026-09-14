// SPDX-License-Identifier: Apache-2.0
//
// The build listing became a value a caller reads rather than lines a caller
// greps, and the two claims that carries are both about *ordering*.
//
// Apple's `sort=-version` is lexical: build 9 comes back above build 10. This
// package has always known that — `appstore build-number` sorts numerically
// before answering — and the listing beside it did not, so the two commands
// could name different builds from the same account. One comparator now,
// tested here.
//
// The second claim is that "newest" and "newest usable" are different
// questions. A build uploaded four minutes ago is the newest and cannot be
// released, and a consumer asking "which build does the store hold" wants the
// first while a promote wants the second.
import 'dart:io';

import 'package:cux_ship/src/appstore/app_store.dart';
import 'package:cux_ship/src/appstore/asc_client.dart';
import 'package:cux_ship/src/appstore/reads.dart';
import 'package:test/test.dart';

/// A build resource as Apple sends one.
///
/// [platform] is not part of the real payload — Apple filters on
/// `preReleaseVersion.platform` server-side and does not echo it back. The
/// fake carries it so it can filter the way the real endpoint does; the model
/// never reads it.
Map<String, dynamic> _build(
  String version, {
  String? state = 'VALID',
  bool expired = false,
  String? uploaded = '2026-09-04T09:12:33-07:00',
  String platform = 'IOS',
  List<String>? groupIds,
  String? detailId,
  bool groupsLinksOnly = false,
  bool detailLinksOnly = false,
}) => {
  'type': 'builds',
  'id': 'build-$platform-$version',
  '_platform': platform,
  'attributes': {
    'version': version,
    'processingState': ?state,
    'expired': expired,
    'uploadedDate': ?uploaded,
  },
  // **Omitted entirely when null, which is the shape that matters.** Apple
  // sends `relationships.betaGroups` with `links` and no `data` key for a
  // request that did not ask — measured on `relationships.build` and recorded
  // at `_buildNumberOf` — so a fixture that always carried an empty `data`
  // could never produce the null the model uses to mean *not asked*.
  if (groupIds != null ||
      detailId != null ||
      groupsLinksOnly ||
      detailLinksOnly)
    'relationships': <String, dynamic>{
      if (groupIds != null)
        'betaGroups': {
          'data': [
            for (final id in groupIds) {'type': 'betaGroups', 'id': id},
          ],
        }
      // **Apple's shape for a relationship the request did not include**:
      // `links` and no `data` key at all, measured on `relationships.build`
      // and recorded at `_buildNumberOf`. Distinct from omitting the whole
      // `relationships` block, which is what a build carrying *no* asked-for
      // relationship looks like — and the distinction is not academic: the
      // two land on different guards in `_relatedMany`, and only this one
      // reaches the arm that a real read missing `include=betaGroups` takes.
      else if (groupsLinksOnly)
        'betaGroups': {
          'links': {'self': '/v1/builds/b/relationships/betaGroups'},
        },
      if (detailId != null)
        'buildBetaDetail': {
          'data': {'type': 'buildBetaDetails', 'id': detailId},
        }
      // The to-one half of the same shape, and it had no fixture: a request
      // that did not send `include=buildBetaDetail` gets `links` and no `data`
      // key, which is the third arm of `_relatedOne` exactly as it is the
      // third arm of `_relatedMany`. Every test reached the to-one guards by
      // omitting the relationship instead, so this arm was reachable from
      // nothing.
      else if (detailLinksOnly)
        'buildBetaDetail': {
          'links': {'self': '/v1/builds/b/relationships/buildBetaDetail'},
        },
    },
};

/// A `betaGroups` resource as Apple sends one.
///
/// [internal] is `null` for the group whose `isInternalGroup` never arrived,
/// which is the case [BetaGroupKind.unknown] exists for — a sparse fieldset or
/// an API change, not a third kind of group.
Map<String, dynamic> _group(String id, {String? name, bool? internal}) => {
  'type': 'betaGroups',
  'id': id,
  'attributes': {'name': ?name, 'isInternalGroup': ?internal},
};

/// A `buildBetaDetails` resource as Apple sends one.
Map<String, dynamic> _detail(String id, {String? externalState}) => {
  'type': 'buildBetaDetails',
  'id': id,
  'attributes': {'externalBuildState': ?externalState},
};

/// Canned App Store Connect, narrowed to `/v1/builds`.
///
/// **It filters by platform, because the branch under test depends on that.**
/// iOS and macOS builds of the same commit carry the same build number, so a
/// fake that returned both would make a dropped platform filter — which this
/// package has shipped once — invisible to every test here.
///
/// **It also sideloads only what the query asked for**, which is the second
/// branch the audience reading depends on. A fake that returned `included`
/// whichever query arrived could not tell a read that sent
/// `include=betaGroups` from one that did not — and that difference is the
/// whole of [AppStoreBuild.betaGroups]'s null.
class _FakeClient implements AscClient {
  _FakeClient(this.builds, {this.sideloaded = const {}, this.includedCap});

  final List<Map<String, dynamic>> builds;

  /// Keyed `type:id`, as [AscClient.getAllWithIncluded] returns it.
  final Map<String, Map<String, dynamic>> sideloaded;

  /// Apple's ceiling on `included` **per response and per relationship**, or
  /// null for a fake that sideloads everything it was asked for.
  ///
  /// **Without this the remedy's own branch was unreachable from every test.**
  /// A fake that answers every named resource however many were named can
  /// never produce the shape the defect was made of — a `data` naming more
  /// resources than `included` carries — so `limit: '200'` and `limit: '50'`
  /// behaved identically here while differing by 22 builds against the real
  /// account. That is `docs/CONTRIBUTING.md`'s rule about a fake carrying the
  /// semantics the tested branch selects on, applied to a truncation.
  ///
  /// **Per response is the load-bearing word**, and it is the measured one:
  /// the cap applies to each of Apple's answers rather than to the query, so
  /// paging smaller resolves everything. A fake capping the *merged* result
  /// would model a per-query ceiling, make the page size irrelevant, and fail
  /// the fix.
  final int? includedCap;

  final List<Map<String, String>> queries = <Map<String, String>>[];

  /// Delegates the way the real client does, so a test asserting on [queries]
  /// sees one request however the code under test reached it.
  @override
  Future<List<Map<String, dynamic>>> getAll(
    String path, {
    Map<String, String>? query,
  }) async => (await getAllWithIncluded(path, query: query)).data;

  @override
  Future<
    ({
      List<Map<String, dynamic>> data,
      Map<String, Map<String, dynamic>> included,
    })
  >
  getAllWithIncluded(String path, {Map<String, String>? query}) async {
    expect(path, '/v1/builds');
    queries.add(query ?? const {});
    final platform = query?['filter[preReleaseVersion.platform]'];
    // **A relationship's name is not its resource type**, and the two differ
    // on exactly one of the two this reads: `include=buildBetaDetail` is
    // singular and sideloads resources of type `buildBetaDetails`, while
    // `betaGroups` is spelled the same on both sides. Gating on the type
    // directly silently sideloaded nothing for the detail — which is how this
    // mapping came to be written down rather than assumed.
    const typeOf = <String, String>{
      'betaGroups': 'betaGroups',
      'buildBetaDetail': 'buildBetaDetails',
    };
    final asked = <String>{
      for (final name in (query?['include'] ?? '').split(','))
        if (typeOf[name] case final String type) type,
    };
    final data = builds
        .where((b) => platform == null || b['_platform'] == platform)
        .toList();
    final available = <String, Map<String, dynamic>>{
      for (final entry in sideloaded.entries)
        if (asked.contains(entry.value['type'])) entry.key: entry.value,
    };
    final cap = includedCap;
    if (cap == null) {
      return (data: data, included: available);
    }
    // **Paged the way the real endpoint is, because the cap is per page.**
    // `getAllWithIncluded` follows `links.next` and merges, so what a caller
    // finally sees is every page's `included` unioned — and that union is
    // complete exactly when no single page named more than the cap.
    final pageSize = int.tryParse(query?['limit'] ?? '') ?? 200;
    final merged = <String, Map<String, dynamic>>{};
    for (var start = 0; start < data.length; start += pageSize) {
      final page = data.skip(start).take(pageSize);
      final namedByType = <String, List<String>>{};
      for (final build in page) {
        for (final key in _namedResources(build)) {
          final type = key.split(':').first;
          if (!asked.contains(type)) {
            continue;
          }
          final named = namedByType.putIfAbsent(type, () => <String>[]);
          if (!named.contains(key)) {
            named.add(key);
          }
        }
      }
      // Apple truncates rather than erroring, and it truncates per
      // relationship: the groups can all fit in the same response that drops
      // two thirds of the build details, which is why this counts by type.
      for (final entry in namedByType.entries) {
        for (final key in entry.value.take(cap)) {
          if (available[key] case final Map<String, dynamic> resource) {
            merged[key] = resource;
          }
        }
      }
    }
    return (data: data, included: merged);
  }

  /// The `type:id` keys a build's `relationships` name, in the order it names
  /// them — which is the order Apple's truncation keeps.
  static List<String> _namedResources(Map<String, dynamic> build) {
    final relationships = build['relationships'];
    if (relationships is! Map<String, dynamic>) {
      return const <String>[];
    }
    final keys = <String>[];
    for (final relationship in relationships.values) {
      if (relationship is! Map<String, dynamic>) {
        continue;
      }
      final data = relationship['data'];
      final entries = data is List
          ? data.whereType<Map<String, dynamic>>()
          : <Map<String, dynamic>>[if (data is Map<String, dynamic>) data];
      for (final entry in entries) {
        if (entry['type'] case final String type) {
          if (entry['id'] case final String id) {
            keys.add('$type:$id');
          }
        }
      }
    }
    return keys;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Captures what a command printed. `beta_groups_test.dart`'s shape.
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

  AppStoreBuilds listingOf(List<Map<String, dynamic>> payload) =>
      appStoreBuildsFrom(payload, AscPlatform.ios);

  group('ordering', () {
    test('is numeric, so 10 is newer than 9', () {
      // Apple's own sort puts "9" first. Answering "which build does the store
      // hold" off that is wrong for every account that has crossed a power of
      // ten, which is all of them.
      final listing = listingOf([_build('9'), _build('100'), _build('10')]);

      expect(listing.builds.map((b) => b.buildNumber), ['100', '10', '9']);
      expect(listing.newestBuildNumber, '100');
    });

    test('and the printed listing is in that order too', () {
      // The listing and `appstore build-number` used to be able to disagree,
      // because only one of them sorted.
      final listing = listingOf([_build('9'), _build('10')]);

      expect(listing.lines.first, contains('build 10'));
      expect(listing.lines.last, contains('build 9'));
    });
  });

  group('the number a caller compares with', () {
    test('is an int, because comparing the strings is the same mistake one '
        'layer up', () {
      // Found live in the first consumer: `status` took the newest build by
      // comparing what this package printed against an integer out of a git
      // tag. Correct only while every build number has the same width — that
      // account was on 148 through 153 — and wrong at 1000.
      final listing = listingOf([_build('999'), _build('1000')]);

      expect(listing.newest?.buildNumberAsInt, 1000);
      // The mistake the accessor exists to prevent, stated so it cannot be
      // read as a stylistic preference.
      expect('999'.compareTo('1000'), greaterThan(0));
    });

    test('is null for a build number that is not one', () {
      // Apple accepts `1.2.3` as a CFBundleVersion. Null rather than zero, so
      // the caller answers the case instead of silently ordering it first.
      final build = listingOf([_build('1.2.3')]).builds.single;

      expect(build.buildNumberAsInt, isNull);
      expect(build.buildNumber, '1.2.3');
    });

    test('and such a build sorts last rather than displacing a real one', () {
      final listing = listingOf([_build('1.2.3'), _build('2131')]);

      expect(listing.newestBuildNumber, '2131');
      expect(listing.builds.last.buildNumber, '1.2.3');
    });
  });

  group('newest against newest usable', () {
    test('the newest build is the newest build, still processing or not', () {
      final listing = listingOf([
        _build('2132', state: 'PROCESSING'),
        _build('2131'),
      ]);

      expect(listing.newestBuildNumber, '2132');
      expect(listing.newest?.processingState, 'PROCESSING');
    });

    test('and the two accessors are a pair, not the same thing twice', () {
      // `newest` answers "which build does the store hold" and `newestUsable`
      // answers "which could I promote now". A consumer wants the first for a
      // status line and the second before a release.
      final listing = listingOf([
        _build('2132', state: 'PROCESSING'),
        _build('2131'),
      ]);

      expect(listing.newest?.buildNumber, '2132');
      expect(listing.newestUsable?.buildNumber, '2131');
      expect(listing.newest?.buildNumber, listing.newestBuildNumber);
    });

    test('while the newest usable one is the newest Apple has processed', () {
      final listing = listingOf([
        _build('2132', state: 'PROCESSING'),
        _build('2131'),
      ]);

      expect(listing.newestUsable?.buildNumber, '2131');
    });

    test('an expired build is processed and still not usable', () {
      // TestFlight builds last 90 days. An expired one is VALID for as long as
      // it is listed and can no longer be given to anybody.
      final listing = listingOf([
        _build('2132', expired: true),
        _build('2131'),
      ]);

      expect(listing.newestBuildNumber, '2132');
      expect(listing.newestUsable?.buildNumber, '2131');
    });

    test('with nothing usable it is null rather than the newest', () {
      final listing = listingOf([_build('2132', state: 'PROCESSING')]);

      expect(listing.newestUsable, isNull);
      expect(listing.newestBuildNumber, '2132');
    });
  });

  group('fields', () {
    test('the upload timestamp is parsed and also kept as Apple sent it', () {
      // Both, because [lines] renders the raw one: Apple's offset spelling and
      // `DateTime.toIso8601String` are not the same string, and the printed
      // output is something a consumer shows verbatim.
      final build = listingOf([
        _build('7', uploaded: '2026-09-04T09:12:33-07:00'),
      ]).builds.single;

      expect(build.uploadedDate, '2026-09-04T09:12:33-07:00');
      expect(build.uploadedAt, DateTime.utc(2026, 9, 4, 16, 12, 33));
    });

    test('an absent processing state is null rather than a guess', () {
      final build = listingOf([_build('7', state: null)]).builds.single;

      expect(build.processingState, isNull);
      expect(build.usable, isFalse);
    });

    test('a build can be looked up by number', () {
      final listing = listingOf([_build('2132'), _build('2131')]);

      expect(listing.build('2131')?.processingState, 'VALID');
      expect(listing.build('9999'), isNull);
    });
  });

  group('lines', () {
    test('are what `appstore builds` has always printed', () {
      final listing = listingOf([
        _build('2132', uploaded: '2026-09-04T09:12:33-07:00'),
      ]);

      expect(listing.lines, [
        '  build 2132  VALID  uploaded 2026-09-04T09:12:33-07:00',
      ]);
    });

    test('say so when a build has expired', () {
      final listing = listingOf([_build('2132', expired: true)]);

      expect(listing.lines.single, endsWith('  (expired)'));
    });

    test('with no builds say nothing has ever been uploaded', () {
      // "none" on its own reads as something to fix with a flag.
      expect(listingOf(const []).lines, [
        '  no builds at all — nothing has ever been uploaded',
      ]);
    });

    test('stop at twenty while the list answers over all of them', () {
      // The printed form is for reading; the list is for answering questions.
      final listing = listingOf([
        for (var i = 0; i < 25; i++) ...[_build('${2100 + i}')],
      ]);

      expect(listing.lines, hasLength(20));
      expect(listing.builds, hasLength(25));
      expect(listing.newestBuildNumber, '2124');
    });
  });

  group('the command', () {
    test('prints exactly the model lines', () async {
      final client = _FakeClient([_build('9'), _build('10')]);
      final out = await _printed(() => printBuilds(storeOf(client), app));

      expect(
        out,
        '${listingOf([_build('9'), _build('10')]).lines.join('\n')}\n',
      );
    });

    test('and asks for the two relationships the audience needs', () async {
      // One request, not a follow-up per build: `status` reads three builds on
      // each of two platforms, so a per-build round trip is six extra calls to
      // answer something Apple will put in the first response.
      final client = _FakeClient([_build('9')]);
      await _printed(() => printBuilds(storeOf(client), app));

      expect(client.queries.single['include'], 'betaGroups,buildBetaDetail');
      expect(client.queries, hasLength(1));
    });

    test('and asks for a page no larger than Apple will sideload', () async {
      // **The page size is the fix, and nothing in the request says so.**
      // `included` is capped at 50 resources per relationship *per response*
      // and `buildBetaDetail` is one resource per build, so a page of more
      // than 50 builds names more details than one answer can carry. At
      // `limit: '200'` that silently cost 22 of 72 macOS builds their state,
      // measured 2026-09-14.
      //
      // Asserted against the literal 50 rather than against the constant, so
      // that raising both together — which is the shape the mistake would
      // take — is still red.
      final client = _FakeClient([_build('9')]);
      await _printed(() => printBuilds(storeOf(client), app));

      expect(client.queries.single['limit'], '50');
    });

    test('while a read with no audience keeps Apple\'s biggest page', () async {
      // **`builds` stopped delegating to `buildsWithIncluded` for this.** Its
      // only caller is `appstore promote`, which discards every sideloaded
      // resource — so inheriting a page size that exists to protect `included`
      // would be four times the round trips on the release path to protect
      // something it does not read.
      final client = _FakeClient([_build('9')]);
      await storeOf(client).builds(app);

      expect(client.queries.single['include'], isNull);
      expect(client.queries.single['limit'], '200');
    });

    test('and resolves every build on an account past the cap', () async {
      // **The measured defect, reproduced.** 72 builds, Apple's real ceiling
      // of 50 sideloaded resources per relationship per response — which is
      // what `_FakeClient.includedCap` models, and without it this test and
      // the one above pass at any page size at all.
      //
      // At `limit: '200'` this is one response naming 72 details and carrying
      // 50, and 22 builds come back with no state. At `limit: '50'` it is two
      // responses of 50 and 22, neither over the ceiling, and
      // `getAllWithIncluded` merges them.
      final builds = [
        for (var n = 100; n < 172; n++) ...[_build('$n', detailId: 'd-$n')],
      ];
      final client = _FakeClient(
        builds,
        sideloaded: {
          for (var n = 100; n < 172; n++) ...{
            'buildBetaDetails:d-$n': _detail(
              'd-$n',
              externalState: 'BETA_APPROVED',
            ),
          },
        },
        includedCap: 50,
      );

      final payload = await storeOf(client).buildsWithIncluded(app);
      final listing = appStoreBuildsFrom(
        payload.data,
        AscPlatform.ios,
        included: payload.included,
      );

      expect(listing.builds, hasLength(72));
      expect(
        listing.builds.where((b) => b.externalBuildState == null),
        isEmpty,
        reason: 'a build past the first page lost its detail to the cap',
      );
      // And the parser agrees with the request: nothing was named and left
      // unsent, which is the reading that would go on being true if the page
      // size were wrong and the states happened to be null anyway.
      expect(listing.builds.where((b) => b.unresolvedBuildBetaDetail), isEmpty);
    });

    test('and prints the audience it asked for, end to end', () async {
      // The only test that runs the whole path — request built, `included`
      // merged, relationships resolved, line rendered. Everything else here
      // hands the parser a payload, which cannot catch the request and the
      // parser disagreeing about what was asked for.
      final client = _FakeClient(
        [
          _build('180', groupIds: const ['g-int'], detailId: 'd-1'),
        ],
        sideloaded: {
          'betaGroups:g-int': _group('g-int', name: 'Team', internal: true),
          'buildBetaDetails:d-1': _detail(
            'd-1',
            externalState: 'READY_FOR_BETA_SUBMISSION',
          ),
        },
      );

      final out = await _printed(() => printBuilds(storeOf(client), app));

      expect(
        out,
        '  build 180  VALID  uploaded 2026-09-04T09:12:33-07:00  '
        'internal: Team  external: none (READY_FOR_BETA_SUBMISSION)\n',
      );
    });

    test('and asks Apple only for this platform', () async {
      // The listing that showed a build which had never been uploaded is what
      // made the missing filter visible.
      final client = _FakeClient([
        _build('2132', platform: 'MAC_OS'),
        _build('2131', platform: 'IOS'),
      ]);
      final out = await _printed(() => printBuilds(storeOf(client), app));

      expect(out, contains('build 2131'));
      expect(out, isNot(contains('build 2132')));
      expect(
        client.queries.single['filter[preReleaseVersion.platform]'],
        'IOS',
      );
    });
  });

  group('the audience', () {
    // The defect: one TestFlight number per platform conflated *Apple finished
    // processing this* with *external testers have it*. Apple hands every
    // processed build to every internal group automatically; an external group
    // gets nothing until beta review passes. So these are two facts and the
    // listing used to carry one.
    AppStoreBuilds listingWith(
      Map<String, dynamic> build,
      List<Map<String, dynamic>> included,
    ) => appStoreBuildsFrom(
      [build],
      AscPlatform.ios,
      included: <String, Map<String, dynamic>>{
        for (final resource in included)
          '${resource['type']}:${resource['id']}': resource,
      },
    );

    test('is null when the read did not ask, not empty', () {
      // The one that has to be null rather than `[]`. A read without
      // `include=betaGroups` that reported *attached to no group* would render
      // as *no external testers have this* — true most of the time, which is
      // exactly why nobody would catch the day it was not.
      final build = listingOf([_build('180')]).newest!;

      expect(build.betaGroups, isNull);
      expect(build.internalGroups, isNull);
      expect(build.externalGroups, isNull);
      expect(build.inExternalTesting, isNull);
    });

    test('and stays null when the relationship carries links and no data', () {
      // **The arm a real un-included read takes, and it was reachable from no
      // test.** Three different shapes mean *not asked* and they land on three
      // different guards: no `relationships` block at all, a block without
      // this relationship, and — the one Apple actually sends — the
      // relationship present carrying `links` and no `data` key. The first two
      // return early, so making the third arm answer `[]` instead of null
      // passed all 35 tests. Found by making exactly that mutation.
      final build = listingWith(
        _build('180', groupsLinksOnly: true, detailId: 'd-1'),
        [_detail('d-1', externalState: 'IN_BETA_TESTING')],
      ).newest!;

      expect(build.betaGroups, isNull);
      expect(build.externalGroups, isNull);
      // And the line says nothing about an audience it did not read, even
      // though the detail beside it came back.
      expect(build.line, isNot(contains('external:')));
    });

    test('and a relationships block naming neither is null too', () {
      final build = listingWith(_build('180', detailId: 'd-1'), [
        _detail('d-1', externalState: 'IN_BETA_TESTING'),
      ]).newest!;

      expect(build.betaGroups, isNull);
    });

    test('is empty when Apple says the build is attached to nothing', () {
      final build = listingWith(
        _build('180', groupIds: const []),
        const [],
      ).newest!;

      expect(build.betaGroups, isEmpty);
      expect(build.externalGroups, isEmpty);
    });

    test('separates an internal group from an external one', () {
      final build = listingWith(
        _build('180', groupIds: const ['g-int', 'g-ext']),
        [
          _group('g-int', name: 'Team', internal: true),
          // Named as though it were internal, and it is not. The name is
          // whatever somebody typed into App Store Connect; `isInternalGroup`
          // is the answer.
          _group('g-ext', name: 'Internal-ish', internal: false),
        ],
      ).newest!;

      expect(build.internalGroups!.map((g) => g.name), ['Team']);
      expect(build.externalGroups!.map((g) => g.name), ['Internal-ish']);
    });

    test('leaves a group whose kind Apple withheld out of both lists', () {
      final build = listingWith(_build('180', groupIds: const ['g-?']), [
        _group('g-?', name: 'Mystery'),
      ]).newest!;

      expect(build.internalGroups, isEmpty);
      expect(build.externalGroups, isEmpty);
      // And says so, rather than letting the group vanish into two empties.
      expect(build.hasUnknownGroupKind, isTrue);
    });

    test('does not call an unread relationship an unknown kind', () {
      // Two different questions with two different remedies: one is *send the
      // include*, the other is *Apple withheld the attribute*.
      expect(listingOf([_build('180')]).newest!.hasUnknownGroupKind, isFalse);
    });

    test('reads the external state from the build beta detail', () {
      // The state itself, carried raw. Whether external testers *have* the
      // build takes this and the group attachment together and is the
      // `external delivery` group below — this build's groups were never
      // read, so it is precisely the case that cannot be answered.
      final build = listingWith(_build('180', detailId: 'd-1'), [
        _detail('d-1', externalState: 'IN_BETA_TESTING'),
      ]).newest!;

      expect(build.externalBuildState, 'IN_BETA_TESTING');
      expect(build.inExternalTesting, isNull);
    });

    test('and a build in beta review is not in external testing', () {
      final build = listingWith(_build('180', detailId: 'd-1'), [
        _detail('d-1', externalState: 'WAITING_FOR_BETA_REVIEW'),
      ]).newest!;

      expect(build.inExternalTesting, isFalse);
      expect(build.externalBuildState, 'WAITING_FOR_BETA_REVIEW');
    });

    test('and a processed build nobody submitted reads as not submitted', () {
      // The observed case: build 180 of 1.1.7, processed, never through
      // `beta`. VALID and not in external testing at the same time, which is
      // the pair the single column could not express.
      final build = listingWith(
        _build('180', groupIds: const ['g-int'], detailId: 'd-1'),
        [
          _group('g-int', name: 'Team', internal: true),
          _detail('d-1', externalState: 'READY_FOR_BETA_SUBMISSION'),
        ],
      ).newest!;

      expect(build.usable, isTrue);
      expect(build.internalGroups!.map((g) => g.name), ['Team']);
      expect(build.externalGroups, isEmpty);
      expect(build.inExternalTesting, isFalse);
    });

    test('and a detail Apple sent without a state stays unknown', () {
      final build = listingWith(_build('180', detailId: 'd-1'), [
        _detail('d-1'),
      ]).newest!;

      expect(build.externalBuildState, isNull);
      expect(build.inExternalTesting, isNull);
    });

    test(
      'and a named resource missing from included is skipped, not faked',
      () {
        // A placeholder would be a group with no kind, which is the one thing
        // this package refuses to invent.
        final build = listingWith(
          _build('180', groupIds: const ['g-int', 'g-gone']),
          [_group('g-int', name: 'Team', internal: true)],
        ).newest!;

        expect(build.betaGroups!.map((g) => g.name), ['Team']);
      },
    );

    test('prints both halves once either is known', () {
      // Including the empty one: a line that omits `external:` when nothing is
      // attached makes the commonest state look like a line that forgot.
      final line = listingWith(
        _build('180', groupIds: const ['g-int'], detailId: 'd-1'),
        [
          _group('g-int', name: 'Team', internal: true),
          _detail('d-1', externalState: 'READY_FOR_BETA_SUBMISSION'),
        ],
      ).newest!.line;

      expect(
        line,
        contains('internal: Team  external: none (READY_FOR_BETA_SUBMISSION)'),
      );
    });

    test('and prints no audience at all when none was read', () {
      // A listing from a read that did not ask prints what it always printed,
      // rather than a row of confident `none`s.
      final line = listingOf([_build('180')]).newest!.line;

      expect(line, isNot(contains('internal:')));
      expect(line, isNot(contains('external:')));
      expect(line, '  build 180  VALID  uploaded 2026-09-04T09:12:33-07:00');
    });

    test('and a detail carrying links and no data reads as not known', () {
      // `_relatedOne`'s third arm, which no test reached: the to-one shape a
      // request without `include=buildBetaDetail` actually gets back. The
      // to-many twin of this is covered two tests up; this side was reached
      // only by omitting the relationship, which lands on a different guard.
      final build = listingWith(
        _build('180', groupIds: const ['g-int'], detailLinksOnly: true),
        [_group('g-int', name: 'Team', internal: true)],
      ).newest!;

      expect(build.externalBuildState, isNull);
      expect(build.inExternalTesting, isNull);
    });

    test('and a detail Apple named but did not send says so', () {
      // **This was a characterization test and now it is a guard.** It read
      // *a detail Apple named but did not send reads as not known*, which
      // described the defect accurately and asserted nothing that would break
      // when it was fixed: a truncated detail and a build Apple holds no
      // detail for produced the same null, so the listing could not tell a
      // fact from a shortfall and neither could this test.
      //
      // **Live on 2026-09-14**: at `limit: '200'` Apple caps `included` at 50
      // resources per relationship, and `buildBetaDetail` is one per build, so
      // 22 of 72 macOS details never arrived with the relationship still
      // naming an id for every one of them.
      final build = listingWith(
        _build('180', groupIds: const ['g-ext'], detailId: 'd-gone'),
        [_group('g-ext', name: 'Beta Testers', internal: false)],
      ).newest!;

      expect(build.unresolvedBuildBetaDetail, isTrue);
      expect(build.externalBuildState, isNull);
      expect(build.inExternalTesting, isNull);
      // And the line says which of the two nulls this is, rather than
      // printing the state half as though nothing were missing.
      expect(build.line, contains('state not sent'));
    });

    test('and a detail nobody asked for does not count as one not sent', () {
      // The distinction the flag exists to draw, from the other side: three
      // shapes mean *not asked* — no `relationships` block, a block naming no
      // `buildBetaDetail`, and the one Apple sends, `links` and no `data` —
      // and none of them is a response that came up short. A flag that were
      // simply `externalBuildState == null` would be true for all three and
      // would say nothing at all.
      final notAsked = [
        listingWith(_build('180'), const []).newest!,
        listingWith(_build('180', groupIds: const ['g-x']), const []).newest!,
        listingWith(
          _build('180', detailLinksOnly: true, groupIds: const []),
          const [],
        ).newest!,
      ];

      for (final build in notAsked) {
        expect(build.unresolvedBuildBetaDetail, isFalse);
        expect(build.externalBuildState, isNull);
        expect(build.line, isNot(contains('state not sent')));
      }
    });

    test(
      'and groups Apple named and did not send are counted, not dropped',
      () {
        // **The sharper half, because the many side has no null to fall back
        // on.** A truncated group list used to read `[]` — *attached to
        // nothing*, a positive claim built entirely out of what was missing —
        // where the to-one side at least produced a null that meant *unknown*.
        final build = listingWith(
          _build('180', groupIds: const ['g-int', 'g-gone', 'g-also-gone']),
          [_group('g-int', name: 'Team', internal: true)],
        ).newest!;

        expect(build.betaGroups!.map((g) => g.name), ['Team']);
        expect(build.unresolvedBetaGroups, 2);
        expect(build.line, contains('groups not sent: 2'));
      },
    );

    test('and a read that asked for nothing counts no shortfall', () {
      // Zero rather than "unknown": nothing was named, so nothing went
      // missing. `betaGroups` being null is what says the read did not ask,
      // and this field would be a second, worse way to say it.
      final build = listingOf([_build('180')]).newest!;

      expect(build.betaGroups, isNull);
      expect(build.unresolvedBetaGroups, 0);
      expect(build.line, isNot(contains('groups not sent')));
    });
  });

  group('external delivery', () {
    // **Measured against a live account on 2026-09-14**, which is what moved
    // this from one `==` to two facts. `externalBuildState == 'IN_BETA_TESTING'`
    // was a constant `false`: across 51 iOS builds that state never occurred,
    // Apple's terminal external state after review being `BETA_APPROVED`, and
    // the fourteen builds external testers demonstrably had all reported that
    // they did not have them.
    AppStoreBuild deliveryOf({
      required List<String> groupIds,
      required List<Map<String, dynamic>> groups,
      String? externalState,
    }) => appStoreBuildsFrom(
      [_build('180', groupIds: groupIds, detailId: 'd-1')],
      AscPlatform.ios,
      included: <String, Map<String, dynamic>>{
        for (final resource in [
          ...groups,
          _detail('d-1', externalState: externalState),
        ])
          '${resource['type']}:${resource['id']}': resource,
      },
    ).newest!;

    test('is true for an approved build attached to an external group', () {
      // Builds 178, 179 and 180 of `design.codeux.howitwent`, exactly: both
      // groups attached, `BETA_APPROVED`, and external testers had them.
      final build = deliveryOf(
        groupIds: const ['g-int', 'g-ext'],
        groups: [
          _group('g-int', name: 'howitwent testers', internal: true),
          _group('g-ext', name: 'Beta Testers', internal: false),
        ],
        externalState: 'BETA_APPROVED',
      );

      expect(build.inExternalTesting, isTrue);
    });

    test('and false for an approved build attached to no external group', () {
      // Apple's verdict is not delivery: approval with nobody outside
      // attached means nobody outside has it.
      final build = deliveryOf(
        groupIds: const ['g-int'],
        groups: [_group('g-int', name: 'Team', internal: true)],
        externalState: 'BETA_APPROVED',
      );

      expect(build.inExternalTesting, isFalse);
    });

    test('and false while an attached external group waits on review', () {
      // The other half of the pair: attachment is what submits a build, so it
      // exists throughout review and does not mean anyone can install it.
      final build = deliveryOf(
        groupIds: const ['g-ext'],
        groups: [_group('g-ext', name: 'Beta Testers', internal: false)],
        externalState: 'WAITING_FOR_BETA_REVIEW',
      );

      expect(build.inExternalTesting, isFalse);
    });

    test('and null when the state is known and the groups were not read', () {
      // Approved, and whether anybody has it turns on a relationship this read
      // never asked for — so the answer is that it was not answered.
      final build = appStoreBuildsFrom(
        [_build('180', detailId: 'd-1')],
        AscPlatform.ios,
        included: {
          'buildBetaDetails:d-1': _detail(
            'd-1',
            externalState: 'BETA_APPROVED',
          ),
        },
      ).newest!;

      expect(build.betaGroups, isNull);
      expect(build.inExternalTesting, isNull);
    });

    test('and null when the only attached group has a kind Apple withheld', () {
      // `externalGroups` counts an unknown kind out of both lists, so
      // answering `false` from its emptiness would turn a refusal to guess
      // into a claim that nobody outside has the build.
      final build = deliveryOf(
        groupIds: const ['g-?'],
        groups: [_group('g-?', name: 'Mystery')],
        externalState: 'BETA_APPROVED',
      );

      expect(build.hasUnknownGroupKind, isTrue);
      expect(build.inExternalTesting, isNull);
    });

    test('and null when the groups Apple named did not all arrive', () {
      // **The confident `false` the parser change exists to prevent.** An
      // approved build whose attachments were truncated has an empty
      // `externalGroups` for a reason that is not about the build, and
      // answering `false` from that emptiness reports *nobody outside has
      // this* out of a shortfall — the same mistake as reading it off an
      // unknown kind, one step further out.
      final build = deliveryOf(
        groupIds: const ['g-gone'],
        groups: const [],
        externalState: 'BETA_APPROVED',
      );

      expect(build.unresolvedBetaGroups, 1);
      expect(build.externalGroups, isEmpty);
      expect(build.inExternalTesting, isNull);
    });

    test('and true anyway when a resolved external group is among them', () {
      // **Empty and non-empty are not symmetric, so the shortfall does not
      // veto an answer it cannot change.** The groups that did not arrive
      // could only add attachments, and one external group that did arrive
      // already settles the question — a null here would refuse to answer
      // something the response plainly said.
      final build = deliveryOf(
        groupIds: const ['g-ext', 'g-gone'],
        groups: [_group('g-ext', name: 'Beta Testers', internal: false)],
        externalState: 'BETA_APPROVED',
      );

      expect(build.unresolvedBetaGroups, 1);
      expect(build.inExternalTesting, isTrue);
    });

    test('and false still, for a build that never cleared review', () {
      // The early return above both fields: no attachment makes a build in
      // review installable, so a truncated group list changes nothing and
      // `false` stays an answer rather than becoming a shrug.
      final build = deliveryOf(
        groupIds: const ['g-gone'],
        groups: const [],
        externalState: 'WAITING_FOR_BETA_REVIEW',
      );

      expect(build.unresolvedBetaGroups, 1);
      expect(build.inExternalTesting, isFalse);
    });
  });

  test('the listing names the platform it answered for', () {
    // iOS and macOS builds of one commit share a build number, so a listing
    // that does not say which platform it is about is ambiguous exactly when
    // it matters.
    expect(listingOf(const []).platform, AscPlatform.ios);
  });
}
