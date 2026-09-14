// SPDX-License-Identifier: Apache-2.0
//
// `documents.dart`'s library dartdoc is the published statement of the
// `--json` format — the README says so, and pub.dev renders it per version.
// It opens with a worked example a consumer copies, and that example refuses
// any `schema` it does not name.
//
// So the example carries a schema number, and a bump that leaves it behind
// ships a snippet telling every reader to throw on the documents this package
// now prints. That is what happened at schema 2: the counter moved to 2 and
// the example still said `!= 1`, with nothing red — `dart analyze` does not
// read comments, and no test read this one.
//
// The number rather than the prose, because the number is the part a compiler
// would have caught if it were code and is the part nobody rereads when it is
// not.
import 'dart:convert';
import 'dart:io';

import 'package:cux_ship/documents.dart';
import 'package:cux_ship/src/json_output.dart';
import 'package:test/test.dart';

void main() {
  test('the published example refuses the schema this package prints', () {
    final source = ['cux_ship/lib/documents.dart', 'lib/documents.dart']
        .map(File.new)
        .firstWhere(
          (f) => f.existsSync(),
          orElse: () => throw StateError(
            'cannot find lib/documents.dart from ${Directory.current.path} — '
            'and a test that cannot find its subject would pass by default',
          ),
        )
        .readAsStringSync();

    // The example decodes an `AppStoreBuildsDocument`, so the counter it has
    // to agree with is the builds one rather than any of its siblings.
    expect(
      source,
      contains('AppStoreBuildsDocument.fromJson'),
      reason:
          'the worked example is no longer about appstore.builds — this '
          'test is pinned to the wrong counter',
    );

    final guard = RegExp(r'builds\.schema != (\d+)').firstMatch(source);
    expect(
      guard,
      isNotNull,
      reason:
          'the example lost its schema check, which is one of the three '
          'rules the same dartdoc tells a caller to follow',
    );

    expect(
      int.parse(guard!.group(1)!),
      appStoreBuildsSchema,
      reason:
          'lib/documents.dart tells a consumer to throw on schema '
          '${guard.group(1)}, and this package prints $appStoreBuildsSchema',
    );
  });

  test(
    'the worked example in json-output.md is a document this package emits',
    () {
      // **It was not, and nothing could tell.** `docs/design/json-output.md`
      // carries an `appstore.builds` document as its worked example, and it sat
      // at schema 1 through the schema 2 bump — missing `betaGroups`,
      // `inExternalTesting` and both shortfall counters. Since `fromJson` now
      // *requires* the counters, the repository's own published example was one
      // this package would refuse to read. Found by review, not by a test, on
      // the same branch that had already shipped one stale example in
      // `documents.dart` for the same reason.
      //
      // Decoding it is the assertion. A schema number compared against the
      // constant would have passed the day the fields were added and the example
      // was not.
      final source =
          ['docs/design/json-output.md', '../docs/design/json-output.md']
              .map(File.new)
              .firstWhere(
                (f) => f.existsSync(),
                orElse: () => throw StateError(
                  'cannot find docs/design/json-output.md from '
                  '${Directory.current.path} — and a test that cannot find its '
                  'subject would pass by default',
                ),
              )
              .readAsStringSync();

      final fence = RegExp(r'```json\n(\{[\s\S]*?\n\})\n```');
      final match = fence.firstMatch(source);
      expect(
        match,
        isNotNull,
        reason: 'json-output.md no longer carries a fenced JSON example',
      );

      final decoded = jsonDecode(match!.group(1)!) as Map<String, dynamic>;
      expect(
        decoded['kind'],
        'appstore.builds',
        reason:
            'the first example is no longer the builds document — this test '
            'is pinned to the wrong one',
      );

      // The whole point: this throws if a required key is absent.
      final document = AppStoreBuildsDocument.fromJson(decoded);

      expect(document.schema, appStoreBuildsSchema);
      expect(document.builds.single.unresolvedBetaGroups, 0);
      expect(document.builds.single.unresolvedBuildBetaDetail, isFalse);
    },
  );
}
