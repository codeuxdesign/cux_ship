// SPDX-License-Identifier: Apache-2.0
//
// Do the listing's URLs answer?
//
// A privacy policy URL that 404s is an App Store rejection, and the failure is
// entirely ordinary: the policy is usually a static site deployed by a
// different command than the app, so shipping the app and forgetting the site
// is one missed step rather than a mistake.
//
// **Three decisions here, and all three are about where a check belongs rather
// than what it checks.**
//
// *Not in cux_ship_verify.* That package has zero dependencies and makes no
// network calls, and both properties are load-bearing: they are what let a
// consumer run the offline checks from its own test suite, on every push, with
// no credentials. `verify --help` says "No network, no credentials", and that
// sentence is an invariant rather than a description of what the command
// currently happens to do. A reachability check is exactly the reasonable
// addition that would erode it.
//
// *Not behind a flag on `verify`.* A check that only runs when somebody
// remembers it is the shape this tool argues against everywhere else: fastlane
// found the same thing and made `run_precheck_before_submit` default true.
//
// *Not a gate.* This is the part that decides the design. A URL can be
// legitimately dead at exactly one moment — the first release of a project
// whose site is deployed after the app, which is a documented ordering in at
// least one consuming repository. A blocking check would fail that release
// correctly, and the fix would be to pass a flag that turns it off, which
// teaches the bypass. A release blocked by a true statement is still a release
// somebody has to get past.
//
// So: on the upload path, always, and reporting rather than failing. It costs
// nothing in the dependency graph — the upload path already holds an HTTP
// client and credentials — and the one legitimately dead release prints a line
// that is true instead of failing a build that should succeed.
import 'dart:async';
import 'dart:io';

/// What one URL did when asked.
class UrlCheck {
  const UrlCheck(this.field, this.url, this.detail);

  /// The listing field it came from, e.g. `privacy_policy_url`.
  final String field;
  final String url;

  /// What happened, in a few words. Null when it answered normally.
  final String? detail;

  bool get ok => detail == null;
}

/// Asks each of [urls] whether it answers, and returns only what did not.
///
/// Never throws and never fails a caller: everything that goes wrong becomes a
/// line of output. A DNS failure on a CI runner with no egress is not evidence
/// about the URL, and a check that cannot distinguish the two must not be the
/// thing that stops a release.
///
/// HEAD first because it is what a reachability question deserves, then GET on
/// a 405 — some hosts refuse HEAD and answer GET perfectly, and reporting that
/// as unreachable would be a false alarm of exactly the kind this file exists
/// to avoid.
Future<List<UrlCheck>> unreachableUrls(
  Map<String, String> urls, {
  Duration timeout = const Duration(seconds: 10),
  HttpClient? client,
}) async {
  if (urls.isEmpty) {
    return const [];
  }
  final http = client ?? HttpClient();
  http.connectionTimeout = timeout;
  final problems = <UrlCheck>[];
  try {
    for (final entry in urls.entries) {
      final uri = Uri.tryParse(entry.value);
      if (uri == null || !uri.hasScheme) {
        continue; // Not a reachability question; the loader already refused it.
      }
      final detail = await _ask(http, uri, timeout);
      if (detail != null) {
        problems.add(UrlCheck(entry.key, entry.value, detail));
      }
    }
  } finally {
    if (client == null) {
      http.close(force: true);
    }
  }
  return problems;
}

Future<String?> _ask(HttpClient http, Uri uri, Duration timeout) async {
  try {
    var status = await _status(http, uri, 'HEAD', timeout);
    if (status == HttpStatus.methodNotAllowed ||
        status == HttpStatus.notImplemented) {
      status = await _status(http, uri, 'GET', timeout);
    }
    if (status >= 400) {
      return 'answered $status';
    }
    return null;
  } on TimeoutException {
    return 'did not answer within ${timeout.inSeconds}s';
  } on SocketException catch (e) {
    return 'could not be reached (${e.osError?.message ?? e.message})';
  } on HandshakeException {
    return 'has a TLS problem';
  } on HttpException catch (e) {
    return 'could not be fetched (${e.message})';
  }
}

Future<int> _status(
  HttpClient http,
  Uri uri,
  String method,
  Duration timeout,
) async {
  final request = await http.openUrl(method, uri).timeout(timeout);
  request.followRedirects = true;
  final response = await request.close().timeout(timeout);
  await response.drain<void>();
  return response.statusCode;
}
