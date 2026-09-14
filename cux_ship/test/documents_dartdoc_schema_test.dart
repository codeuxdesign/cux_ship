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
import 'dart:io';

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
}
