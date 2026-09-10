// SPDX-License-Identifier: Apache-2.0
//
// `tool/status.sh` reports what is open by grepping the `Status:` lines in
// docs/design/. **A document whose status is not in the vocabulary does not
// report as an error — it vanishes from the report**, which is the failure
// this file exists for: the index would say "three open" and be believed, with
// a fourth sitting in a file spelled `draft`.
//
// That is not hypothetical. Before the vocabulary existed the sixteen status
// lines used eight phrasings for what turned out to be four states — `draft`,
// `decisions pending`, `answered in part`, `implemented`, `decided and built`
// — and any index over them would have been wrong in whichever direction its
// author had not thought of.
//
// The vocabulary is read out of the script rather than repeated here, so there
// is one list. A copy would be the drift `tool/check.sh` was written to end,
// in the file arguing against it.
import 'dart:io';

import 'package:test/test.dart';

/// [name] from the repository root, whichever directory the suite is run from.
///
/// `dart test` runs from `cux_ship/` under `tool/check.sh` and from the root
/// when somebody runs it by hand. Throwing rather than skipping, because a
/// test that cannot find what it checks would pass by default.
File _atRoot(String name) {
  for (final path in ['../$name', name]) {
    final file = File(path);
    if (file.existsSync()) {
      return file;
    }
  }
  throw StateError(
    'cannot find $name from ${Directory.current.path} — and a status test '
    'that cannot find the statuses would pass by default',
  );
}

Directory _designDocs() {
  for (final path in ['../docs/design', 'docs/design']) {
    final directory = Directory(path);
    if (directory.existsSync()) {
      return directory;
    }
  }
  throw StateError(
    'cannot find docs/design from ${Directory.current.path} — and a status '
    'test that cannot find the documents would pass by default',
  );
}

void main() {
  // `STATES=(open proposed decided built)` out of tool/status.sh.
  final states = () {
    final script = _atRoot('tool/status.sh').readAsStringSync();
    final declaration = RegExp(
      r'^STATES=\(([^)]*)\)',
      multiLine: true,
    ).firstMatch(script);
    // Thrown rather than expected, because this runs while the suite is being
    // built and an `expect` out here fails the whole file with a stack trace
    // instead of a sentence.
    if (declaration == null) {
      throw StateError(
        'tool/status.sh no longer declares STATES=(…), so this test cannot '
        'know the vocabulary it is enforcing',
      );
    }
    return declaration.group(1)!.split(RegExp(r'\s+'))
      ..removeWhere((s) => s.isEmpty);
  }();

  final documents = _designDocs()
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.md'))
      .toList();

  test('there are design documents to check', () {
    // The whole file rests on this, and an empty glob is silent.
    expect(documents, isNotEmpty);
    expect(states, isNotEmpty);
  });

  test('every Status: line uses a word tool/status.sh reports on', () {
    final wrong = <String>[];
    final counted = <String>[];

    for (final document in documents) {
      final lines = document.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].startsWith('Status:')) {
          continue;
        }
        counted.add('${document.path}:${i + 1}');
        final match = RegExp(r'^Status: \*\*(\w+)\*\*').firstMatch(lines[i]);
        if (match == null || !states.contains(match.group(1))) {
          wrong.add('${document.path}:${i + 1}  ${lines[i]}');
        }
      }
    }

    expect(
      wrong,
      isEmpty,
      reason:
          'these would be dropped from tool/status.sh silently. Use one of '
          '${states.join(", ")} and put the nuance in the sentence after it',
    );
    expect(counted, isNotEmpty, reason: 'no Status: lines found at all');
  });

  test('and every document opens with one', () {
    // Near the top, not merely somewhere: a document whose only status is a
    // section three hundred lines down has no state of its own, and the index
    // would report the section as though it were the document.
    for (final document in documents) {
      final head = document.readAsLinesSync().take(10);
      expect(
        head.where((l) => l.startsWith('Status: **')),
        isNotEmpty,
        reason: '${document.path} has no Status: line in its first 10 lines',
      );
    }
  });
}
