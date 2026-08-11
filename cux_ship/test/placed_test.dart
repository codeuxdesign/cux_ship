// SPDX-License-Identifier: Apache-2.0
//
// The placed family writes plaintext into the working tree and leaves it there,
// which every other credential in this tool deliberately does not. So these
// tests are almost entirely about the guards: the promise is not "plaintext
// never outlives the run" but "plaintext never enters history", and the only
// thing making that true is that a target git could ever track is refused.
import 'dart:io';

import 'package:cux_ship/src/placed.dart';
import 'package:cux_ship/src/project.dart';
import 'package:cux_ship/src/secrets.dart';
import 'package:test/test.dart';

late Directory _root;

void run(List<String> arguments) =>
    Process.runSync('git', arguments, workingDirectory: _root.path);

void write(String relative, String contents) {
  final file = File('${_root.path}/$relative');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

PlacedFile file(String path, [String contents = 'a secret']) =>
    PlacedFile(at: 'placed.thing', path: path, content: contents.codeUnits);

Matcher throwsSaying(Object fragment) => throwsA(
  isA<ProjectException>().having((e) => e.message, 'message', fragment),
);

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('cux_ship_placed_test');
    run(['init', '-q']);
    write('.gitignore', 'lib/env/secrets.dart\nplaced/\n');
  });

  tearDown(() => _root.deleteSync(recursive: true));

  group('refusing a target git could track', () {
    test('a path that is not ignored', () {
      // The whole guarantee: if git can see it, a secret must not go there.
      expect(
        () => checkPlaceable(_root.path, 'placed.x', 'lib/env/other.dart'),
        throwsSaying(contains('not ignored')),
      );
    });

    test('a path that is tracked, even though it is ignored', () {
      // .gitignore does not apply to a file git already knows about, so a path
      // once added with `git add -f` stays trackable and the next `commit -a`
      // publishes it. Ignored-but-tracked is the case a check-ignore-only guard
      // waves through.
      write('placed/thing', 'placeholder');
      run(['add', '-f', 'placed/thing']);
      expect(
        () => checkPlaceable(_root.path, 'placed.x', 'placed/thing'),
        throwsSaying(contains('already tracks')),
      );
    });

    test('a path inside a submodule', () {
      // The superproject's ignore rules do not answer for a nested repository,
      // so a file placed there is trackable somewhere this never looked.
      write('deps/inner/.git', 'gitdir: ../../.git/modules/inner\n');
      write('.gitignore', 'deps/inner/secret\n');
      expect(
        () => checkPlaceable(_root.path, 'placed.x', 'deps/inner/secret'),
        throwsSaying(contains('submodule')),
      );
    });
  });

  group('refusing a target outside the repository', () {
    test('an absolute path', () {
      expect(
        () => checkPlaceable(_root.path, 'placed.x', '/etc/passwd'),
        throwsSaying(contains('inside the repository')),
      );
    });

    test('a path that climbs out', () {
      expect(
        () => checkPlaceable(_root.path, 'placed.x', '../escape'),
        throwsSaying(contains('inside the repository')),
      );
    });

    test('a path through a symlinked directory', () {
      // Lexically clean, and still leaves the repository. This is why the
      // containment check resolves before judging rather than after.
      final outside = Directory.systemTemp.createTempSync('cux_ship_outside');
      addTearDown(() => outside.deleteSync(recursive: true));
      Link(
        '${_root.path}/placed/away',
      ).createSync(outside.path, recursive: true);
      expect(
        () => checkPlaceable(_root.path, 'placed.x', 'placed/away/secret'),
        throwsSaying(contains('outside the repository')),
      );
    });

    test('a target that is itself a symlink', () {
      Link(
        '${_root.path}/placed/link',
      ).createSync('/etc/passwd', recursive: true);
      expect(
        () => checkPlaceable(_root.path, 'placed.x', 'placed/link'),
        throwsSaying(contains('symlink')),
      );
    });
  });

  group('placing', () {
    test('writes it, readable only by its owner', () {
      place(_root.path, file('lib/env/secrets.dart'));
      final target = File('${_root.path}/lib/env/secrets.dart');
      expect(target.readAsStringSync(), 'a secret');
      if (!Platform.isWindows) {
        final mode = Process.runSync('stat', [
          '-f',
          '%Lp',
          target.path,
        ]).stdout.toString().trim();
        expect(mode, '600');
      }
    });

    test('leaves nothing partial behind', () {
      place(_root.path, file('lib/env/secrets.dart'));
      expect(Directory('${_root.path}/lib/env').listSync().map((e) => e.path), [
        endsWith('secrets.dart'),
      ]);
    });
  });

  group('the three outcomes', () {
    test('absent, then matching', () {
      final f = file('lib/env/secrets.dart');
      expect(f.outcomeIn(_root.path), PlaceOutcome.absent);
      place(_root.path, f);
      expect(f.outcomeIn(_root.path), PlaceOutcome.matching);
    });

    test('an edited file is differing, and clean refuses it', () {
      // The reason `pack` can be deferred but this cannot: without it, the
      // maintainer's edit exists only here, and removing it is data loss on a
      // routine command.
      final f = file('lib/env/secrets.dart');
      place(_root.path, f);
      write('lib/env/secrets.dart', 'edited by hand');
      expect(f.outcomeIn(_root.path), PlaceOutcome.differing);
      expect(() => clean(_root.path, f), throwsSaying(contains('edited')));
      expect(
        File('${_root.path}/lib/env/secrets.dart').readAsStringSync(),
        'edited by hand',
      );
    });

    test('clean removes what is still ours, and is quiet about absence', () {
      final f = file('lib/env/secrets.dart');
      place(_root.path, f);
      expect(clean(_root.path, f), isTrue);
      expect(File('${_root.path}/lib/env/secrets.dart').existsSync(), isFalse);
      expect(clean(_root.path, f), isFalse);
    });
  });

  test('the schema cannot be extended into a disclosure', () {
    // `path`, `env` and `kind` are stored in cleartext so the pre-flight works
    // with no identity. A future family whose secret-bearing field took one of
    // those names would publish it, which is a rule worth enforcing rather than
    // writing down.
    expect(assertSchemaKeepsSecretsEncrypted, returnsNormally);
  });
}
