// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

import 'package:cux_ship/src/reachable.dart';
import 'package:test/test.dart';

/// A server that answers whatever each path is told to answer.
///
/// `/no-head` answers by *method*, which is the case that matters: a host that
/// refuses HEAD and serves GET is common, and treating it as unreachable would
/// be a false alarm.
Future<HttpServer> _server(Map<String, int> statuses) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final status = request.uri.path == '/no-head'
        ? (request.method == 'HEAD'
              ? HttpStatus.methodNotAllowed
              : HttpStatus.ok)
        : (statuses[request.uri.path] ?? HttpStatus.notFound);
    request.response.statusCode = status;
    await request.response.close();
  });
  return server;
}

void main() {
  group('unreachableUrls', () {
    late HttpServer server;
    late String base;

    setUp(() async {
      server = await _server({
        '/ok': HttpStatus.ok,
        '/gone': HttpStatus.notFound,
        '/no-head': HttpStatus.methodNotAllowed,
      });
      base = 'http://${server.address.address}:${server.port}';
    });

    tearDown(() => server.close(force: true));

    test('says nothing about a URL that answers', () async {
      expect(await unreachableUrls({'privacyPolicyUrl': '$base/ok'}), isEmpty);
    });

    test('reports a 404 with its status', () async {
      final problems = await unreachableUrls({
        'privacyPolicyUrl': '$base/gone',
      });
      expect(problems, hasLength(1));
      expect(problems.single.field, 'privacyPolicyUrl');
      expect(problems.single.detail, 'answered 404');
    });

    test('falls back to GET when a host refuses HEAD', () async {
      // Some hosts answer GET perfectly and refuse HEAD. Reporting that as
      // unreachable would be a false alarm of exactly the kind this check must
      // not produce, since a false alarm here teaches people to ignore it.
      final problems = await unreachableUrls({'supportUrl': '$base/no-head'});
      expect(problems, isEmpty);
    });

    test('reports a host that does not resolve, without throwing', () async {
      final problems = await unreachableUrls({
        'marketingUrl': 'https://this-host-does-not-exist.invalid/',
      }, timeout: const Duration(seconds: 5));
      expect(problems, hasLength(1));
      expect(problems.single.detail, isNotNull);
    });

    test('ignores anything that is not a URL', () async {
      // The metadata loader already refuses these; a reachability check is not
      // where a malformed value should be reported a second time.
      expect(await unreachableUrls({'supportUrl': 'not a url'}), isEmpty);
    });

    test('an empty map does no work at all', () async {
      expect(await unreachableUrls(const {}), isEmpty);
    });
  });
}
