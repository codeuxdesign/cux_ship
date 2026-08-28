// SPDX-License-Identifier: Apache-2.0
//
// The README's command map claims to be the whole surface, so it has to be —
// and eyeballing it has now missed twice: `beta-release` shipped absent from
// the map (#17, caught in review) and `beta-groups` did the same (#22, caught
// in review again). Same miss, different authors. The third time is this
// test's to catch, not a reviewer's.
//
// The map is compared against `buildRunner()` itself rather than a list kept
// here, because a list kept here is a second copy of the same fact — it would
// drift exactly the way the map does.
import 'dart:io';

import 'package:cux_ship/runner.dart';
import 'package:test/test.dart';

void main() {
  test('the README command map names every runnable subcommand', () {
    final readme = ['README.md', 'cux_ship/README.md']
        .map(File.new)
        .firstWhere(
          (f) => f.existsSync(),
          orElse: () => throw StateError(
            'cannot find README.md from ${Directory.current.path} — and a '
            'map test that cannot find the map would pass by default',
          ),
        )
        .readAsStringSync();

    // The map is the first fenced block after "## The command". Scoped to the
    // block rather than the whole file, because prose mentioning a command is
    // not the map carrying it.
    final heading = readme.indexOf('## The command');
    expect(heading, isNot(-1), reason: 'README lost its "## The command"');
    final open = readme.indexOf('```', heading);
    final close = readme.indexOf('```', open + 3);
    expect(close, isNot(-1), reason: 'the command map block is unterminated');
    final map = readme.substring(open, close);

    final missing = <String>[];
    for (final command in buildRunner().commands.values) {
      if (command.hidden || command.name == 'help') {
        continue;
      }
      final subcommands = command.subcommands.values
          .where((sub) => !sub.hidden && sub.name != 'help')
          .toList();
      if (subcommands.isEmpty) {
        if (!RegExp('\\b${RegExp.escape(command.name)}\\b').hasMatch(map)) {
          missing.add(command.name);
        }
        continue;
      }
      for (final sub in subcommands) {
        // The columns are independent lists, so "name<spaces>sub" on one line
        // is the only shape an entry has.
        if (!RegExp(
          '${RegExp.escape(command.name)}\\s+${RegExp.escape(sub.name)}\\b',
        ).hasMatch(map)) {
          missing.add('${command.name} ${sub.name}');
        }
      }
    }

    expect(
      missing,
      isEmpty,
      reason:
          'the README command map is missing: ${missing.join(', ')}. '
          'Add each to the map block under "## The command".',
    );
  });
}
