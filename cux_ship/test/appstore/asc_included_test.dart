// SPDX-License-Identifier: Apache-2.0
//
// `AscClient.getAllWithIncluded` — the half of a JSON:API response that
// `getAll` throws away.
//
// **Tested against the HTTP seam rather than against a fake client**, and that
// is the point of the file existing. Every other App Store test in this suite
// fakes `AscClient` itself, which is the right level for "does this command ask
// the right question" and is exactly the wrong level here: pagination lives
// *inside* the client, so a fake standing in for the whole of it can never run
// the loop whose behaviour is under test. `AscClient` takes an `http.Client`,
// so the seam already existed.
//
// The property that needs it: **`included` is merged across pages.** Apple
// repeats a sideloaded resource on every page that references it, so a reader
// keeping only the last page's map answers correctly for the last page and
// null for everything before it — which looks exactly like a version with no
// build attached, in a document a consumer decodes.
import 'dart:convert';

import 'package:cux_ship/src/appstore/asc_client.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

const _base = 'https://api.appstoreconnect.apple.com';

/// The real client, with the one thing this file does not test stubbed out.
///
/// **Signing, and nothing else.** Every other App Store test fakes `AscClient`
/// wholesale and therefore never signs; here the genuine pagination loop has to
/// run, and `_send` reaches `bearerToken` on the way to every request. A
/// placeholder PEM fails inside the JWT library with a `RangeError` out of a
/// PEM parser, which reads as a broken test rather than as a missing key — the
/// first run of this file established that rather than the author predicting
/// it.
///
/// **A subclass rather than a checked-in key**, and `dart pub publish
/// --dry-run` is why: a real P-256 key was embedded here first, and publish
/// validation refused the archive with *"Potential leak of Private Key
/// detected"*. The fix it suggests is a `false_secrets` pattern in
/// `pubspec.yaml`, which would switch that scanner off for a path in perpetuity
/// so that one test could sign a token nobody verifies. Overriding the getter
/// costs three lines and leaves the scanner armed.
class _UnsignedClient extends AscClient {
  _UnsignedClient(super.credentials, {super.httpClient});

  @override
  String get bearerToken => 'test-token';
}

AscCredentials _credentials() => AscCredentials(
  keyId: 'FAKEKEYID',
  issuerId: 'fake-issuer',
  privateKeyPem: 'not-a-key',
);

Map<String, dynamic> _version(String id, String buildId) => {
  'type': 'appStoreVersions',
  'id': id,
  'relationships': {
    'build': {
      'data': {'type': 'builds', 'id': buildId},
    },
  },
};

Map<String, dynamic> _build(String id, String number) => {
  'type': 'builds',
  'id': id,
  'attributes': {'version': number},
};

/// Serves [pages] in order, linking each to the next the way Apple does.
///
/// The `links.next` it hands back is an absolute URL on Apple's own origin,
/// because the client refuses one that is not — a check that exists so the
/// bearer token cannot be redirected to another host.
http.Client _serving(List<Map<String, dynamic>> pages) {
  var served = 0;
  return _StubClient((request) async {
    final page = Map<String, dynamic>.of(pages[served]);
    served++;
    if (served < pages.length) {
      page['links'] = {'next': '$_base/v1/next?cursor=$served'};
    }
    return http.Response(
      jsonEncode(page),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

class _StubClient extends http.BaseClient {
  _StubClient(this.answer);

  final Future<http.Response> Function(http.BaseRequest) answer;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await answer(request);
    return http.StreamedResponse(
      Stream.value(utf8.encode(response.body)),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }
}

void main() {
  group('included travels beside the collection', () {
    test('and is keyed the way a relationship names a resource', () async {
      final client = _UnsignedClient(
        _credentials(),
        httpClient: _serving([
          {
            'data': [_version('v1', 'b1')],
            'included': [_build('b1', '169')],
          },
        ]),
      );

      final answer = await client.getAllWithIncluded('/v1/apps/1/x');

      // `type:id` is how JSON:API addresses a resource and therefore how a
      // relationship names one — the key a caller already holds.
      expect(answer.included.keys, ['builds:b1']);
      expect(answer.data, hasLength(1));
    });

    test('and is merged across pages, not read off the last one', () async {
      // **The property this file exists for.** Apple repeats a sideloaded
      // resource on every page that references it; a per-page map would answer
      // for the newest page and null for every version before it.
      final client = _UnsignedClient(
        _credentials(),
        httpClient: _serving([
          {
            'data': [_version('v1', 'b1')],
            'included': [_build('b1', '169')],
          },
          {
            'data': [_version('v2', 'b2')],
            'included': [_build('b2', '170')],
          },
        ]),
      );

      final answer = await client.getAllWithIncluded('/v1/apps/1/x');

      expect(answer.data, hasLength(2));
      expect(answer.included.keys.toSet(), {'builds:b1', 'builds:b2'});
    });

    test('and a response carrying none answers an empty map', () async {
      // Distinct from a relationship Apple could not resolve: no `include=` was
      // sent, so there is nothing to sideload and nothing is wrong.
      final client = _UnsignedClient(
        _credentials(),
        httpClient: _serving([
          {
            'data': [_version('v1', 'b1')],
          },
        ]),
      );

      final answer = await client.getAllWithIncluded('/v1/apps/1/x');

      expect(answer.included, isEmpty);
      expect(answer.data, hasLength(1));
    });

    test(
      'and getAll still answers exactly the data, having dropped it',
      () async {
        // The 23 existing callers want the list and nothing else. `getAll`
        // delegates here so the pagination loop — and the check that a `next`
        // link cannot leave Apple's origin — has one copy rather than two.
        final client = _UnsignedClient(
          _credentials(),
          httpClient: _serving([
            {
              'data': [_version('v1', 'b1')],
              'included': [_build('b1', '169')],
            },
          ]),
        );

        expect(await client.getAll('/v1/apps/1/x'), hasLength(1));
      },
    );
  });
}
