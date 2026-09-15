// SPDX-License-Identifier: Apache-2.0

// The public App Store storefront, and nothing above it.
//
// **A different Apple product from App Store Connect, and the reason this file
// is not in `appstore/`.** `asc_client.dart` talks to a documented REST API
// with a versioned surface and a signed JWT. This talks to the storefront the
// App Store app itself reads: undocumented, rate-limited, unauthenticated, and
// with no deprecation policy. The two are kept apart so the day this drifts it
// takes down the read built on it and nothing else —
// docs/design/storefront-release-date.md argues that at length.
//
// **It consumes no credential.** There is no key, no environment variable and
// no `secrets exec --only` selector, and there is nothing here for one to
// select. That is a property a caller can see from the argv, which is half of
// why this read exists as its own command.
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Where the storefront answers. Apple's own host for this, unchanged since
/// the iTunes Store shipped it, which is also why the vocabulary in the
/// responses calls an app a "track".
const _baseUrl = 'https://itunes.apple.com';

/// The storefront refused, or answered with something that is not a lookup.
///
/// **Not an `AscApiException` sibling**, deliberately: nothing about this
/// endpoint's failures resembles App Store Connect's `{"errors": […]}` shape,
/// and a caller catching one should never silently catch the other.
class StorefrontException implements Exception {
  StorefrontException(this.message, {this.status});

  /// What went wrong, as a sentence — this is printed as the whole report.
  final String message;

  /// The HTTP status, when there was one. Null when the failure was the body
  /// rather than the response.
  final int? status;

  @override
  String toString() => message;
}

/// One `/lookup` request, as the seam a test replaces.
///
/// An interface rather than a concrete class taking an `http.Client`, for the
/// reason the App Store side uses one: a fake that stands in here can carry
/// the endpoint's *semantics* — that an unknown bundle id is a 200 with an
/// empty `results`, not a 404 — which is the behaviour the absence branch
/// selects on. A fake HTTP client would only carry bytes.
abstract interface class StorefrontClient {
  /// Every result the storefront holds for [bundleId] on [country], which is
  /// zero or one in practice.
  ///
  /// Throws [StorefrontException] when the storefront refused. **An empty list
  /// is not a refusal** — it is the answer for an app the storefront does not
  /// know, and for an app that is not sold in [country]. The two are
  /// indistinguishable from here, which is a property of the endpoint and is
  /// written down in the design document rather than guessed at.
  Future<List<Map<String, dynamic>>> lookup({
    required String bundleId,
    required String country,
  });
}

/// [StorefrontClient] over `https://itunes.apple.com/lookup`.
class ItunesClient implements StorefrontClient {
  ItunesClient({http.Client? httpClient, String? baseUrl})
    : _http = httpClient ?? http.Client(),
      _base = baseUrl ?? _baseUrl;

  final http.Client _http;

  /// **The seam the failure paths are injected through, and it has to be a
  /// URL.** Everything below that is not the happy path is a property of the
  /// *response* — a 400 for an unrecognized country, a 429, a body that is not
  /// JSON, a body whose non-ASCII app name would arrive mojibaked if the
  /// encoding were taken from the header. None of those is reachable through
  /// [StorefrontClient], which is the seam the rest of this package fakes,
  /// because that interface begins after the response has been read. Pointing
  /// this at a local server is the only way those branches are exercised by
  /// anything, and a `catch` no test can reach rots — `docs/CONTRIBUTING.md`
  /// §"A failure path needs its own failure injection".
  final String _base;

  @override
  Future<List<Map<String, dynamic>>> lookup({
    required String bundleId,
    required String country,
  }) async {
    final uri = Uri.parse('$_base/lookup').replace(
      queryParameters: <String, String>{
        'bundleId': bundleId,
        'country': country,
      },
    );

    final http.Response response;
    try {
      response = await _http.get(uri);
    } on Object catch (e) {
      // The host, not the whole URI: a caller reading this in a log wants to
      // know which of the two Apple endpoints was unreachable.
      throw StorefrontException('could not reach ${uri.host}: $e');
    }

    if (response.statusCode == 429) {
      // **Reported rather than retried**, unlike `AscClient`, which retries
      // this. That client protects a long upload from Apple having a bad
      // minute; this is one GET, nothing is lost by failing it, and a retry
      // loop would hide the one fact the caller needs — that they are asking
      // the storefront too often — behind a delay they cannot see.
      throw StorefrontException(
        'the storefront rate-limited this lookup (429). It is an '
        'undocumented endpoint with an undocumented limit; wait and ask '
        'again rather than asking in a loop.',
        status: 429,
      );
    }

    if (response.statusCode != 200) {
      // 400 is what an unrecognized `country` returns, measured, and it is the
      // likeliest way to land here — so it is named rather than left to a bare
      // status. An unknown *bundle id* does not come here at all: it is a 200
      // with an empty `results`, which is the absence this read reports as an
      // answer.
      final hint = response.statusCode == 400
          ? ' — check --country, which must be a two-letter storefront such '
                'as us, de or jp'
          : '';
      throw StorefrontException(
        'the storefront returned ${response.statusCode} for $bundleId on the '
        '$country storefront$hint',
        status: response.statusCode,
      );
    }

    // **Decoded as UTF-8 from the bytes, not through `response.body`.**
    // `package:http` picks an encoding from the `Content-Type` header and
    // falls back to latin1 when there is no `charset`; this endpoint answers
    // `text/javascript`, and an app whose name is not ASCII — which is most
    // of the store — would arrive mojibaked. Apple sends UTF-8.
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException catch (e) {
      throw StorefrontException(
        'the storefront did not answer with JSON: ${e.message}',
        status: response.statusCode,
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw StorefrontException(
        'the storefront answered with ${decoded.runtimeType} where an object '
        'was expected',
        status: response.statusCode,
      );
    }

    final results = decoded['results'];
    if (results is! List) {
      // `resultCount` is present too and is deliberately not read: it is a
      // second statement of the same fact, and the list is the one carrying
      // the data. A response where the two disagreed would be a response this
      // package should not be guessing about.
      throw StorefrontException(
        'the storefront answer carried no results list',
        status: response.statusCode,
      );
    }

    return results.whereType<Map<String, dynamic>>().toList();
  }
}
