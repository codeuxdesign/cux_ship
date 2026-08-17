// SPDX-License-Identifier: Apache-2.0

// The App Store Connect REST API, and nothing above it.
//
// Apple publishes no Dart client and no discovery document, so this is written
// by hand — but the surface it needs is small: a signed JWT, JSON:API requests,
// pagination, and the arbitrary-URL PUTs that asset uploads use.
//
// Two things here exist because of how Apple reports failure:
//
//   - Errors arrive as `{"errors": [{"status", "code", "title", "detail"}]}`,
//     and `detail` is routinely the only field that says anything useful — the
//     HTTP status is almost always 409 or 422 regardless of cause. So the whole
//     array is surfaced verbatim rather than summarised, the same decision
//     cux_ship_play made when it went direct to get Play's rejection text.
//   - There is no edit transaction. Play's uploader can build a whole release
//     and discard it; here every write lands the moment it is made. That is why
//     callers validate everything they can offline first, and why --dry-run
//     means "every read, no writes" rather than "rehearse the whole thing".
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:http/http.dart' as http;

const _baseUrl = 'https://api.appstoreconnect.apple.com';

/// Apple's cap is 20 minutes; a token older than that is rejected outright.
/// Renewed at 15 so a long screenshot upload cannot age out mid-run.
const _tokenLifetime = Duration(minutes: 20);
const _tokenRenewAfter = Duration(minutes: 15);

/// A non-2xx answer from App Store Connect, carrying Apple's own explanation.
class AscApiException implements Exception {
  AscApiException(this.status, this.details, {required this.request});

  final int status;

  /// One entry per `errors[]` element, already flattened to readable text.
  /// Empty when the body was not the JSON:API error shape — a gateway error,
  /// say — in which case [status] is all there is.
  final List<String> details;

  /// Method and path, so a failure names what it was doing.
  final String request;

  @override
  String toString() {
    final buffer = StringBuffer('App Store Connect returned $status');
    buffer.write(' for $request');
    if (details.isEmpty) {
      return buffer.toString();
    }
    for (final detail in details) {
      buffer.write('\n  - $detail');
    }
    final guidance = guidanceFor(details);
    if (guidance != null) {
      buffer.write('\n\n$guidance');
    }
    return buffer.toString();
  }

  /// What to do about an error whose own text does not say.
  ///
  /// Most of Apple's errors name a field and are actionable as printed. A few
  /// name a *condition* the API cannot fix, and for those the useful reply is
  /// not the error text but where the work has to happen. It lives on the
  /// exception rather than at a call site so it reaches every path that prints
  /// one.
  ///
  /// Public so the suite can hold the matching to a real error string rather
  /// than to a paraphrase of one.
  static String? guidanceFor(List<String> details) {
    final text = details.join('\n').toLowerCase();

    // "Unable to Add for Review — an Admin must provide information about the
    // app's privacy practices in the App Privacy section."
    //
    // This blocks a submission and cannot be answered from here, because **App
    // Privacy is absent from the App Store Connect API** — not readable, not
    // writable. Saying so is the point: the natural reading of an API error is
    // that the caller sent something wrong, and someone will otherwise go
    // looking for the cux_ship flag that does not exist.
    //
    // Checked rather than assumed. Apple's API index enumerates the areas it
    // automates and privacy is not among them; the `App` resource carries
    // `appEncryptionDeclarations` and `accessibilityDeclarations` and nothing
    // for data usage. fastlane cannot do it with an API key either — its
    // privacy action authenticates with a web session, and its documentation
    // says the endpoints are not in the official API.
    if (text.contains('privacy practices') || text.contains('app privacy')) {
      return 'App Privacy is answered in the web console, not from here:\n'
          '    App Store Connect > your app > Distribution > App Privacy\n'
          '\n'
          '  Two things that decide who can unblock it, and when:\n'
          '    - An Admin has to do it. A Developer-role account cannot, and '
          'the error\n'
          '      does not say so.\n'
          '    - It is per app rather than per version, so it is answered once '
          'and then\n'
          '      only when what the app collects actually changes.\n'
          '\n'
          '  cux_ship cannot check this before a submission and will not '
          'pretend to.\n'
          '  App Privacy is absent from the App Store Connect API, so nothing '
          'here can\n'
          '  read what you declared or warn you that it is incomplete.';
    }
    return null;
  }
}

/// Credentials for an App Store Connect API key, of either kind.
///
/// A **team** key is created under Users and Access > Integrations > Team Keys
/// and carries a role that applies to every app in the team. Its token names
/// the team in `iss`.
///
/// An **individual** key is generated by a single App Store Connect user and
/// inherits that user's role *and* their app-level restrictions, which is the
/// only way to limit a key to particular apps — team keys cannot be scoped.
/// It has no issuer id at all, and its token says `sub: user` instead.
///
/// Apple distinguishes them nowhere except by that claim, and answers a token
/// with the wrong shape with a bare 401, so which one is in play is decided
/// here by whether an issuer id was supplied.
///
/// An individual key reaches only what its user can reach — in particular
/// certificates, identifiers and profiles are refused outright, whatever the
/// user's role, so `appstore signing` needs a team key.
class AscCredentials {
  AscCredentials({
    required this.keyId,
    required this.privateKeyPem,
    this.issuerId,
    this.keyFileName,
  });

  /// From the environment `tool/with-secrets.sh` sets up.
  ///
  /// Returns null rather than throwing when nothing is configured, so a command
  /// that only needs to validate a metadata tree can run with no credentials at
  /// all — which is what makes `--metadata --dry-run` usable as an offline lint.
  static AscCredentials? fromEnvironment() {
    final keyId = Platform.environment['APPLE_API_KEY_ID'];
    final keyPath = Platform.environment['APPLE_API_PRIVATE_KEY_PATH'];
    if (keyId == null || keyPath == null || keyId.isEmpty || keyPath.isEmpty) {
      return null;
    }
    // Empty means the same thing as absent, written by a shell that exported
    // the variable without a value — a mistake worth treating identically
    // rather than turning into a 401 later.
    final issuerId = Platform.environment['APPLE_API_ISSUER_ID']?.trim();
    final file = File(keyPath);
    if (!file.existsSync()) {
      throw StateError(
        'APPLE_API_PRIVATE_KEY_PATH points at $keyPath, which does not exist',
      );
    }
    return AscCredentials(
      keyId: keyId,
      issuerId: issuerId == null || issuerId.isEmpty ? null : issuerId,
      privateKeyPem: file.readAsStringSync(),
      keyFileName: keyPath.split(Platform.pathSeparator).last,
    );
  }

  final String keyId;

  /// The team's issuer id.
  ///
  /// An individual key does not name it in its JWT, but `altool` requires it
  /// regardless — so this may be set for either kind of key, and its presence
  /// no longer decides which kind this is. See [isIndividual].
  final String? issuerId;

  /// Basename of the `.p8`, when it came from a file.
  ///
  /// Apple's own naming carries the distinction: `ApiKey_` for an individual
  /// key, `AuthKey_` for a team key. `altool` relies on exactly this prefix.
  final String? keyFileName;

  /// Whether this is an individual (user-scoped) key rather than a team key.
  ///
  /// Decided by Apple's filename prefix when there is a filename, because an
  /// individual key now legitimately carries an issuer id for `altool`'s sake.
  /// Falls back to "no issuer means individual" for credentials built by hand.
  bool get isIndividual {
    final name = keyFileName;
    if (name != null) {
      return name.startsWith('ApiKey_');
    }
    return issuerId == null;
  }

  /// The JWT claims Apple expects for this kind of key.
  ///
  /// A team key names the team in `iss`. An individual key has no team to name
  /// and says `sub: user` — literally that string, not the user's id, which is
  /// never exposed. Sending both, or the wrong one, is a 401 with no
  /// explanation, so this is the single place that decides.
  ///
  /// `exp` is added by the signer. `aud` is set here rather than through the
  /// library's `audience` field, which serialises to a JSON array; the spec
  /// permits that and Apple does not accept it.
  Map<String, dynamic> get tokenClaims {
    final issuer = issuerId;
    return <String, dynamic>{
      if (!isIndividual && issuer != null) ...{'iss': issuer},
      if (isIndividual) ...{'sub': 'user'},
      'aud': 'appstoreconnect-v1',
    };
  }

  /// The `.p8` exactly as Apple serves it — PKCS#8, `BEGIN PRIVATE KEY`.
  final String privateKeyPem;
}

class AscClient {
  AscClient(this.credentials, {http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  final AscCredentials credentials;
  final http.Client _http;

  String? _token;
  DateTime? _tokenIssuedAt;

  /// A fresh ES256 JWT, or the cached one while it is comfortably valid.
  ///
  /// The claims differ between a team and an individual key; see
  /// [AscCredentials.tokenClaims].
  String get bearerToken {
    final issuedAt = _tokenIssuedAt;
    final cached = _token;
    if (cached != null &&
        issuedAt != null &&
        DateTime.now().difference(issuedAt) < _tokenRenewAfter) {
      return cached;
    }

    final jwt = JWT(
      credentials.tokenClaims,
      header: <String, dynamic>{'kid': credentials.keyId, 'typ': 'JWT'},
    );
    final signed = jwt.sign(
      ECPrivateKey(credentials.privateKeyPem),
      algorithm: JWTAlgorithm.ES256,
      expiresIn: _tokenLifetime,
    );
    _token = signed;
    _tokenIssuedAt = DateTime.now();
    return signed;
  }

  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async => _json('GET', path, query: query);

  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body) =>
      _json('POST', path, body: body);

  Future<Map<String, dynamic>> patch(String path, Map<String, dynamic> body) =>
      _json('PATCH', path, body: body);

  Future<void> delete(String path) async {
    await _send('DELETE', Uri.parse('$_baseUrl$path'));
  }

  /// Every page of a collection, following `links.next` until it runs out.
  ///
  /// App Store Connect caps a page at 200 and defaults to 50, and several of
  /// the things this tool reads — builds, versions — pass 50 in a busy month.
  /// A single-page read would silently look at the newest 50 and conclude the
  /// rest do not exist.
  Future<List<Map<String, dynamic>>> getAll(
    String path, {
    Map<String, String>? query,
  }) async {
    final results = <Map<String, dynamic>>[];
    var uri = Uri.parse(
      '$_baseUrl$path',
    ).replace(queryParameters: {'limit': '200', ...?query});
    while (true) {
      final body = _decode(await _send('GET', uri), 'GET ${uri.path}');
      final data = body['data'];
      if (data is List) {
        results.addAll(data.whereType<Map<String, dynamic>>());
      }
      final links = body['links'];
      final next = links is Map<String, dynamic> ? links['next'] : null;
      if (next is! String || next.isEmpty) {
        return results;
      }
      final following = Uri.parse(next);
      // The bearer token goes on whatever this names, so it does not get to
      // name another host. Reaching this would already mean Apple's own TLS
      // response was attacker-controlled — but "the token only ever goes to
      // Apple" should be a property of this code rather than a property of
      // Apple's response, and the check is one line.
      //
      // `uploadOperation` below is the deliberate opposite: it PUTs to an
      // arbitrary URL Apple hands over, and attaches no Authorization header
      // for exactly this reason.
      if (following.origin != Uri.parse(_baseUrl).origin) {
        throw StateError('pagination left App Store Connect: $next');
      }
      uri = following;
    }
  }

  /// A PUT to an arbitrary URL with headers Apple dictated.
  ///
  /// Asset uploads do not go to the API host: reserving an upload returns a
  /// list of `uploadOperations`, each naming its own URL, method, byte range
  /// and request headers. They are also **unauthenticated** — the URL carries
  /// its own signature — so sending the bearer token here would be wrong as
  /// well as unnecessary.
  Future<void> uploadOperation(
    Map<String, dynamic> operation,
    List<int> chunk,
  ) async {
    final url = operation['url'];
    final method = operation['method'];
    if (url is! String || method is! String) {
      throw StateError('upload operation has no url/method: $operation');
    }
    final headers = <String, String>{};
    final requestHeaders = operation['requestHeaders'];
    if (requestHeaders is List) {
      for (final header in requestHeaders.whereType<Map<String, dynamic>>()) {
        final name = header['name'];
        final value = header['value'];
        if (name is String && value is String) {
          headers[name] = value;
        }
      }
    }

    final request = http.Request(method, Uri.parse(url))
      ..bodyBytes = chunk
      ..headers.addAll(headers);
    final response = await http.Response.fromStream(await _http.send(request));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AscApiException(response.statusCode, [
        if (response.body.isNotEmpty) response.body,
      ], request: '$method <upload operation>');
    }
  }

  Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    var uri = Uri.parse('$_baseUrl$path');
    if (query != null) {
      uri = uri.replace(queryParameters: query);
    }
    return _decode(await _send(method, uri, body: body), '$method $path');
  }

  Map<String, dynamic> _decode(http.Response response, String request) {
    if (response.body.isEmpty) {
      return <String, dynamic>{};
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw AscApiException(response.statusCode, [
        'expected a JSON object, got ${decoded.runtimeType}',
      ], request: request);
    }
    return decoded;
  }

  /// One request, with retries for the failures that are worth retrying.
  ///
  /// 429 is Apple's rate limit and 5xx is Apple having a bad minute; both are
  /// transient and both are worth a second try, because the alternative is
  /// failing a release for a reason that would have gone away. Everything else
  /// — 401, 403, 409, 422 — is a fact about the request and retrying it would
  /// only be slower.
  Future<http.Response> _send(
    String method,
    Uri uri, {
    Map<String, dynamic>? body,
  }) async {
    const maxAttempts = 4;
    for (var attempt = 1; ; attempt++) {
      final request = http.Request(method, uri);
      request.headers['Authorization'] = 'Bearer $bearerToken';
      if (body != null) {
        request.headers['Content-Type'] = 'application/json';
        request.body = jsonEncode(body);
      }

      final response = await http.Response.fromStream(
        await _http.send(request),
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return response;
      }

      final retryable =
          response.statusCode == 429 || response.statusCode >= 500;
      if (retryable && attempt < maxAttempts) {
        await Future<void>.delayed(Duration(seconds: 2 * attempt));
        continue;
      }

      throw AscApiException(
        response.statusCode,
        _errorDetails(response.body),
        request: '$method ${uri.path}',
      );
    }
  }

  /// Flattens Apple's `errors[]` into one readable line each.
  ///
  /// `title` and `detail` are both kept when they differ: `title` is the
  /// category ("Entity Error.Attribute.Invalid") and `detail` is the sentence
  /// that names the actual field, and which one carries the useful part varies
  /// by endpoint. `source.pointer` is appended where present, because for a
  /// rejected attribute it is the only thing that says *which* attribute.
  static List<String> _errorDetails(String body) {
    if (body.isEmpty) {
      return const [];
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return [body];
    }
    if (decoded is! Map<String, dynamic>) {
      return [body];
    }
    final errors = decoded['errors'];
    if (errors is! List) {
      return [body];
    }
    final details = <String>[];
    for (final error in errors.whereType<Map<String, dynamic>>()) {
      final title = error['title'];
      final detail = error['detail'];
      final parts = <String>[
        if (title is String && title.isNotEmpty) title,
        if (detail is String && detail.isNotEmpty && detail != title) detail,
      ];
      final source = error['source'];
      if (source is Map<String, dynamic>) {
        final pointer = source['pointer'] ?? source['parameter'];
        if (pointer is String && pointer.isNotEmpty) {
          parts.add('($pointer)');
        }
      }
      details.add(parts.isEmpty ? error.toString() : parts.join(' — '));
    }
    return details.isEmpty ? [body] : details;
  }

  void close() => _http.close();
}
