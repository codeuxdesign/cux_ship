// SPDX-License-Identifier: Apache-2.0
//
// `cux_ship storefront released` — when the public actually got a version.
//
// Four properties carry almost all the risk here, and every one of them is a
// thing that looks right while being wrong:
//
//   - **`versionReleasedDate` must be Apple's `currentVersionReleaseDate`**
//     and never `releaseDate`. Apple's shorter name reads as the answer and is
//     the app's launch day; swapped, this command reports a plausible wrong
//     date for every app older than its current version, and nothing looks
//     broken.
//   - **An app the storefront does not know is an answer**, printed as a
//     document with a null `app` and exit 6 — not a failure with empty stdout.
//   - **stdout carries the document and nothing else**, including on that
//     absence path, which is the one a caller meets first.
//   - **There is no `--platform`.** The storefront answers per app, measured,
//     and a flag would be a value the caller chose rather than one the store
//     said. See docs/design/storefront-release-date.md.
//
// The fake is the [StorefrontClient] seam; the real [ItunesClient] is driven
// over a local socket at the bottom of this file, because every one of its
// failure branches is a property of a *response* and is unreachable from the
// interface the rest of the suite fakes.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cux_ship/documents.dart';
import 'package:cux_ship/exit_codes.dart' as public;
import 'package:cux_ship/src/json_output.dart';
import 'package:cux_ship/src/storefront/cli.dart';
import 'package:cux_ship/src/storefront/itunes_client.dart';
import 'package:cux_ship/src/storefront/reads.dart';
import 'package:test/test.dart';

/// One `/lookup` result, shaped as the live storefront sends one.
///
/// **Apple's key names, not ours.** The whole point of the read under test is
/// the mapping between the two, so a fixture written in this package's
/// vocabulary would agree with the encoder by construction and could not catch
/// the swap the file header names.
///
/// The values are the live answer for `design.codeux.howitwent` on 15
/// September 2026, so a failure here can be compared against something real:
/// version 1.1.6, released 2026-09-10, first released 2026-08-25.
Map<String, dynamic> _result({
  int? trackId = 6802083801,
  String? trackName = 'How It Went',
  String kind = 'software',
  String version = '1.1.6',
  String? currentVersionReleaseDate = '2026-09-10T21:48:31Z',
  String? releaseDate = '2026-08-25T07:00:00Z',
}) => <String, dynamic>{
  'trackId': ?trackId,
  'trackName': ?trackName,
  'kind': kind,
  'version': version,
  'currentVersionReleaseDate': ?currentVersionReleaseDate,
  'releaseDate': ?releaseDate,
  'trackViewUrl': 'https://apps.apple.com/us/app/how-it-went/id6802083801?uo=4',
  // Keys the read does not touch, carried because the live response has sixty
  // of them and a fixture holding only the seven that are read cannot catch a
  // reader that grabbed the wrong one.
  'bundleId': 'design.codeux.howitwent',
  'minimumOsVersion': '15.0',
  'features': <String>['iosUniversal'],
};

/// Canned storefront.
///
/// **It filters by bundle id and by country, because the real endpoint does
/// and the tested branch selects on it.** An unknown bundle id is a 200 with
/// an empty `results` — not a 404 — and that empty answer is the *whole*
/// absence path. A fake that answered the same record to every lookup would
/// make that branch unreachable from this file, which is
/// `docs/CONTRIBUTING.md` §"A fake must carry the semantics the tested branch
/// selects on".
///
/// **Country filtering carries the second fact the endpoint conflates**: an
/// app that exists but is not sold on a storefront answers exactly like one
/// that has never been released. [sold] is how a case says which it is.
class _FakeStorefront implements StorefrontClient {
  _FakeStorefront(this.apps, {this.sold = const <String>{'us'}, this.failure});

  /// Bundle id -> the result the storefront holds for it.
  final Map<String, Map<String, dynamic>> apps;

  /// The storefronts these apps are sold on.
  final Set<String> sold;

  /// Raised instead of answering, for the transient case. A failure path gets
  /// its own injection, and this one is shaped like the real thing: the
  /// storefront refusing, rather than an app being absent.
  final StorefrontException? failure;

  final asked = <({String bundleId, String country})>[];

  @override
  Future<List<Map<String, dynamic>>> lookup({
    required String bundleId,
    required String country,
  }) async {
    asked.add((bundleId: bundleId, country: country));
    final refusal = failure;
    if (refusal != null) {
      throw refusal;
    }
    if (!sold.contains(country)) {
      return const <Map<String, dynamic>>[];
    }
    final app = apps[bundleId];
    return <Map<String, dynamic>>[
      if (app != null) ...[app],
    ];
  }
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

Future<({String out, String err, int status})> _released(
  StorefrontClient client, {
  List<String> extra = const <String>['--json'],
  String bundleId = 'design.codeux.howitwent',
}) async {
  final args = buildStorefrontParser(
    StorefrontCommand.released,
  ).parse(<String>['--bundle-id', bundleId, ...extra]);
  final out = _MemoryStdout();
  final err = _MemoryStdout();
  await IOOverrides.runZoned(
    () => runStorefront(StorefrontCommand.released, args, client: client),
    stdout: () => out,
    stderr: () => err,
  );
  await out.close();
  await err.close();
  // Read before the tearDown resets it, so a case can assert on it without
  // caring about ordering.
  return (
    out: out.buffer.toString(),
    err: err.buffer.toString(),
    status: exitCode,
  );
}

Map<String, dynamic> _document(({String out, String err, int status}) said) =>
    jsonDecode(said.out) as Map<String, dynamic>;

void main() {
  setUp(() => exitCode = 0);
  tearDown(() => exitCode = 0);

  group('the date', () {
    test('is the current version\'s, not the app\'s first release', () async {
      final said = await _released(
        _FakeStorefront({'design.codeux.howitwent': _result()}),
      );

      final document = StorefrontReleasedDocument.fromJson(_document(said));

      // **The assertion this file exists for.** Apple's two dates are eighteen
      // days apart on this app, and a reader that took `releaseDate` would
      // report the launch day as the release date of 1.1.6 — plausible, wrong,
      // and silent.
      expect(document.app!.versionReleasedDate, '2026-09-10T21:48:31Z');
      expect(document.app!.firstReleasedDate, '2026-08-25T07:00:00Z');
      expect(document.app!.version, '1.1.6');
    });

    test('and both survive a round trip through the published classes', () {
      final release = StorefrontRelease(
        bundleId: 'design.codeux.howitwent',
        country: 'us',
        app: storefrontAppFrom(_result()),
      );

      final document = storefrontReleasedDocument(release);
      final again = StorefrontReleasedDocument.fromJson(
        jsonDecode(jsonEncode(document)) as Map<String, dynamic>,
      );

      expect(again.app!.versionReleasedDate, document.app!.versionReleasedDate);
      expect(again.app!.firstReleasedDate, document.app!.firstReleasedDate);
      expect(again.app!.appleId, 6802083801);
      expect(again.app!.productKind, 'software');
      expect(again.kind, DocumentKind.storefrontReleased);
      expect(again.schema, storefrontReleasedSchema);
    });

    test('and a storefront that sent neither says so rather than guessing', () {
      final app = storefrontAppFrom(
        _result(currentVersionReleaseDate: null, releaseDate: null),
      );

      expect(app.versionReleasedDate, isNull);
      expect(app.firstReleasedDate, isNull);
      // Null is a fact about the response, and the rendering has to carry it
      // rather than printing an empty column that reads as a date of nothing.
      expect(app.lines.first, contains('(no date)'));
    });
  });

  group('an app the storefront does not hold', () {
    test('is a document with a null app, not an empty stdout', () async {
      final said = await _released(
        _FakeStorefront({'design.codeux.howitwent': _result()}),
        bundleId: 'design.codeux.nosuchapp',
      );

      // Decoding is the assertion: a failure would have left stdout empty and
      // this throws at character 1.
      final document = StorefrontReleasedDocument.fromJson(_document(said));

      expect(document.app, isNull);
      expect(document.bundleId, 'design.codeux.nosuchapp');
    });

    test('exits 6, which is the whole point of it being an answer', () async {
      final said = await _released(
        _FakeStorefront({'design.codeux.howitwent': _result()}),
        bundleId: 'design.codeux.nosuchapp',
      );

      expect(said.status, notOnStorefrontExit);
      expect(said.status, 6, reason: 'the number a consumer hard-codes');
      // Not the code for "App Store Connect holds no such version". A consumer
      // branching on one number for both would report a version nobody has
      // created yet and an app that has never shipped as the same event.
      expect(notOnStorefrontExit, isNot(public.noSuchVersionExit));
    });

    test('and an app that shipped exits 0', () async {
      final said = await _released(
        _FakeStorefront({'design.codeux.howitwent': _result()}),
      );

      expect(said.status, 0);
    });

    test('renders a sentence, because an empty display says nothing', () async {
      final said = await _released(
        _FakeStorefront({'design.codeux.howitwent': _result()}),
        bundleId: 'design.codeux.nosuchapp',
      );

      final document = StorefrontReleasedDocument.fromJson(_document(said));

      // **The only input where `display` carries the whole meaning.** A
      // consumer iterating an empty array prints nothing, and an app the
      // output said nothing about reads as an app with nothing wrong — which
      // is the failure this is the answer to.
      expect(document.display, isNotEmpty);
      expect(document.display.single, contains('is not on the us App Store'));
    });

    test('and an app not sold here reads the same, deliberately', () async {
      // Two facts arrive as one, and that is the endpoint's doing rather than
      // this package's. The test exists so the next reader meets it as
      // measured behaviour rather than as a bug.
      final said = await _released(
        _FakeStorefront(
          {'design.codeux.howitwent': _result()},
          sold: const <String>{'de'},
        ),
      );

      expect(said.status, notOnStorefrontExit);
      expect(StorefrontReleasedDocument.fromJson(_document(said)).app, isNull);
    });
  });

  group('the envelope', () {
    test('stdout is the document and nothing else', () async {
      final said = await _released(
        _FakeStorefront({'design.codeux.howitwent': _result()}),
      );

      expect(() => jsonDecode(said.out), returnsNormally);
      expect(said.out, isNot(contains('==>')));
      expect(said.err, contains('==>'));
    });

    test('and that holds on the absence path too', () async {
      // **The path where it is easiest to get wrong**, because the branch that
      // reports absence is written after the one that reports an app, and a
      // `stdout.writeln` there is invisible on every happy-path case.
      final said = await _released(
        _FakeStorefront({'design.codeux.howitwent': _result()}),
        bundleId: 'design.codeux.nosuchapp',
      );

      expect(() => jsonDecode(said.out), returnsNormally);
      expect(said.out, isNot(contains('==>')));
    });

    test(
      'without --json nothing is JSON and the lines are the lines',
      () async {
        final said = await _released(
          _FakeStorefront({'design.codeux.howitwent': _result()}),
          extra: const <String>[],
        );

        final release = StorefrontRelease(
          bundleId: 'design.codeux.howitwent',
          country: 'us',
          app: storefrontAppFrom(_result()),
        );
        // One formatter. A consumer printing `display` verbatim and a person
        // reading the command's own output have to be reading the same thing,
        // which is only true while the document renders the model rather than
        // re-rendering it.
        for (final line in release.lines) {
          expect(said.out, contains(line));
        }
      },
    );

    test('the document display is not the app entry\'s', () async {
      final said = await _released(
        _FakeStorefront({'design.codeux.howitwent': _result()}),
      );

      final document = StorefrontReleasedDocument.fromJson(_document(said));

      // The document has a heading naming what was asked and which storefront
      // answered; the entry does not. Deriving either from the other is wrong
      // in both directions, which is why both are carried.
      expect(
        document.display.length,
        greaterThan(document.app!.display.length),
      );
      expect(document.display.first, contains('design.codeux.howitwent'));
      expect(document.app!.display, isNot(contains(document.display.first)));
    });
  });

  group('it describes an app, not a platform', () {
    test('there is no --platform to pass', () {
      // **Structural rather than documentary.** The storefront returns one
      // record for a universal purchase — `/lookup` ignores `entity`, and a
      // `/search` restricted to `macSoftware` returns that same record with
      // the same id, version and date. A `--platform` here would be a value
      // the caller chose, and a consumer would key two grid columns on it.
      final parser = buildStorefrontParser(StorefrontCommand.released);

      expect(parser.options.containsKey('platform'), isFalse);
      expect(
        () => parser.parse(const <String>['--platform', 'ios']),
        throwsFormatException,
      );
    });

    test('and the document carries no platform key', () async {
      final said = await _released(
        _FakeStorefront({'design.codeux.howitwent': _result()}),
      );

      expect(_document(said).containsKey('platform'), isFalse);
    });

    test('productKind is Apple\'s word and is not read as one', () {
      // A universal purchase answers `software` while running on the Mac, so
      // this field cannot be turned into a platform without lying about
      // exactly the app it was measured against.
      expect(storefrontAppFrom(_result()).productKind, 'software');
      expect(
        storefrontAppFrom(_result(kind: 'mac-software')).productKind,
        'mac-software',
      );
    });
  });

  group('--country', () {
    test('defaults to us and travels to the endpoint', () async {
      final client = _FakeStorefront({'design.codeux.howitwent': _result()});

      final said = await _released(client);

      expect(client.asked.single.country, 'us');
      expect(_document(said)['country'], 'us');
    });

    test('and what was asked for is what the document reports', () async {
      final client = _FakeStorefront(
        {'design.codeux.howitwent': _result()},
        sold: const <String>{'de'},
      );

      final said = await _released(
        client,
        extra: const <String>['--json', '--country', 'de'],
      );

      // **Both halves.** A `country` that reached the endpoint but not the
      // document would leave a consumer unable to say which region's answer it
      // is holding, and a document reporting a country the lookup did not use
      // would be worse than either.
      expect(client.asked.single.country, 'de');
      expect(_document(said)['country'], 'de');
      expect(said.status, 0);
    });
  });

  group('the storefront refusing', () {
    test('is never read as an app that has not been released', () async {
      // **The failure this file's absence path could most easily become.** A
      // `catch` in the read that answered `app: null` on a refusal would
      // report "nothing has been released there" for a rate-limited lookup or
      // a network that went away — a sentence a consumer renders in its report
      // and a human believes, under exit 6, which says the answer is trusted.
      //
      // The injection is shaped like the real failure: the storefront
      // refusing, rather than the app being absent, which is the distinction
      // the branch turns on.
      final client = _FakeStorefront(
        const <String, Map<String, dynamic>>{},
        failure: StorefrontException(
          'the storefront rate-limited this lookup (429).',
          status: 429,
        ),
      );

      await expectLater(
        readStorefrontRelease(
          client,
          bundleId: 'design.codeux.howitwent',
          country: 'us',
        ),
        throwsA(isA<StorefrontException>()),
      );
    });

    test('and an absence with the same client shape does not throw', () async {
      // The other half of the same distinction, so the test above cannot pass
      // by the read throwing on everything. Same fake, same empty app map, no
      // injected failure — and this one answers rather than raising.
      final release = await readStorefrontRelease(
        _FakeStorefront(const <String, Map<String, dynamic>>{}),
        bundleId: 'design.codeux.howitwent',
        country: 'us',
      );

      expect(release.app, isNull);
    });
  });

  group('the real client, over a socket', () {
    late HttpServer server;
    late String baseUrl;
    late List<Uri> requested;

    /// What the next request answers with.
    late int status;
    late List<int> body;
    late String contentType;

    setUp(() async {
      requested = <Uri>[];
      status = 200;
      contentType = 'text/javascript';
      body = utf8.encode('{"resultCount":0,"results":[]}');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUrl = 'http://${server.address.host}:${server.port}';
      unawaited(
        server.forEach((request) async {
          requested.add(request.uri);
          request.response
            ..statusCode = status
            ..headers.contentType = ContentType.parse(contentType)
            ..add(body);
          await request.response.close();
        }),
      );
    });

    tearDown(() => server.close(force: true));

    test('asks for the bundle id and the country', () async {
      await ItunesClient(
        baseUrl: baseUrl,
      ).lookup(bundleId: 'design.codeux.howitwent', country: 'de');

      expect(requested.single.path, '/lookup');
      expect(requested.single.queryParameters, {
        'bundleId': 'design.codeux.howitwent',
        'country': 'de',
      });
    });

    test('reads a non-ASCII app name as UTF-8, not as latin1', () async {
      // **The header does not say `charset`, which is the live behaviour.**
      // `package:http` falls back to latin1 without one, so `response.body`
      // would hand back `MÃ¼nchen` — and most of the App Store is not ASCII.
      // Decoding the bytes explicitly is the fix, and this is what reaches it.
      contentType = 'text/javascript';
      body = utf8.encode(
        jsonEncode({
          'resultCount': 1,
          'results': [
            {'trackName': 'München Radwege', 'version': '1.0'},
          ],
        }),
      );

      final results = await ItunesClient(
        baseUrl: baseUrl,
      ).lookup(bundleId: 'design.codeux.example', country: 'us');

      expect(results.single['trackName'], 'München Radwege');
    });

    test('a 400 is a refusal that names --country', () async {
      // What an unrecognized country returns, measured against the live
      // endpoint — and the likeliest way anybody lands on this branch.
      status = 400;
      body = utf8.encode('');

      expect(
        () => ItunesClient(
          baseUrl: baseUrl,
        ).lookup(bundleId: 'design.codeux.example', country: 'zz'),
        throwsA(
          isA<StorefrontException>()
              .having((e) => e.status, 'status', 400)
              .having((e) => e.message, 'message', contains('--country')),
        ),
      );
    });

    test('a 429 says so rather than being retried behind the caller', () async {
      status = 429;

      expect(
        () => ItunesClient(
          baseUrl: baseUrl,
        ).lookup(bundleId: 'design.codeux.example', country: 'us'),
        throwsA(
          isA<StorefrontException>()
              .having((e) => e.status, 'status', 429)
              // **The sentence, not only the number.** Asserting the status
              // alone could not tell the branch that exists for this from the
              // generic non-200 one — that branch also reports 429 — so
              // deleting the whole rate-limit case left this green. It exists
              // to say *what* 429 means here and that asking in a loop is the
              // wrong response, and that is the part worth pinning.
              .having((e) => e.message, 'message', contains('rate-limited'))
              .having((e) => e.message, 'message', contains('rather than')),
        ),
      );
      // One request, not a retry loop: nothing is lost by failing a single
      // GET, and a loop would hide the one fact the caller needs.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(requested, hasLength(1));
    });

    test('a body that is not JSON is a refusal, not a crash', () async {
      body = utf8.encode('<html>nope</html>');

      expect(
        () => ItunesClient(
          baseUrl: baseUrl,
        ).lookup(bundleId: 'design.codeux.example', country: 'us'),
        throwsA(isA<StorefrontException>()),
      );
    });

    test('and neither is an answer with no results list', () async {
      body = utf8.encode('{"resultCount":1}');

      expect(
        () => ItunesClient(
          baseUrl: baseUrl,
        ).lookup(bundleId: 'design.codeux.example', country: 'us'),
        throwsA(
          isA<StorefrontException>().having(
            (e) => e.message,
            'message',
            contains('no results list'),
          ),
        ),
      );
    });

    test('an empty results list is an answer, not a refusal', () async {
      // The shape the absence path is built on, confirmed against the real
      // client rather than only against the fake that imitates it.
      final results = await ItunesClient(
        baseUrl: baseUrl,
      ).lookup(bundleId: 'design.codeux.nosuchapp', country: 'us');

      expect(results, isEmpty);
    });
  });
}
