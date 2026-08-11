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

  test('a tracked target is refused even when it already matches', () {
    // The state, not the transition. After a normal place the file exists and
    // matches, so a guard that only runs on the write path never runs again —
    // and this is precisely when somebody may have `git add -f`ed it, after
    // which the next `git commit -a` publishes the plaintext.
    final f = file('placed/thing');
    place(_root.path, f);
    run(['add', '-f', 'placed/thing']);

    expect(f.outcomeIn(_root.path), PlaceOutcome.matching);
    expect(
      () => checkPlaceable(_root.path, f.at, f.path),
      throwsSaying(contains('already tracks')),
    );
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
        // Dart's own stat rather than shelling out: `stat -f '%Lp'` is BSD and
        // Linux wants `-c '%a'`, so the shell version passed on a Mac and
        // failed on CI.
        expect(target.statSync().modeString(), 'rw-------');
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

  group('packing', () {
    // A sops that understands the two calls this makes: `-d` cats the file, and
    // `set` rewrites one index from stdin. Faked because what is being tested
    // is the index this constructs and the value it feeds — sops' encryption is
    // sops' business, and is exercised for real by hand.
    void fakeSops() {
      final script = File('${_root.path}/.bin/sops');
      script.parent.createSync(recursive: true);
      script.writeAsStringSync(
        '#!/bin/sh\n'
        'if [ "\$1" = "-d" ]; then cat "\$2"; exit 0; fi\n'
        'if [ "\$1" = "set" ]; then\n'
        '  value=\$(cat)\n'
        '  printf "%s\\n%s\\n" "\$3" "\$value" > "\$2.set"\n'
        '  exit 0\n'
        'fi\n'
        'exit 64\n',
      );
      Process.runSync('chmod', ['755', script.path]);
    }

    setUp(fakeSops);

    test('an edited file is written back at its own index', () async {
      write(
        'secrets/release.yaml',
        'placed:\n  env_secrets:\n'
            '    path: lib/env/secrets.dart\n    base64: YQ==\n',
      );
      write('lib/env/secrets.dart', 'edited');

      final result = await packPlaced(
        repoRoot: _root.path,
        secretsFile: File('${_root.path}/secrets/release.yaml'),
        file: PlacedFile(
          at: 'placed.env_secrets',
          path: 'lib/env/secrets.dart',
          content: 'a'.codeUnits,
        ),
      );
      expect(result, PackResult.packed);

      final written = File(
        '${_root.path}/secrets/release.yaml.set',
      ).readAsStringSync().split('\n');
      // The index names the family and the instance — if either is renamed
      // without this following, pack would silently write to nothing.
      expect(written.first, '["placed"]["env_secrets"]["base64"]');
      // JSON-encoded, and the base64 of what is actually on disk.
      expect(written[1], '"ZWRpdGVk"');
    });

    test('an unchanged file is left alone', () {
      write('secrets/release.yaml', 'placed: {}\n');
      write('lib/env/secrets.dart', 'a');
      expect(
        packPlaced(
          repoRoot: _root.path,
          secretsFile: File('${_root.path}/secrets/release.yaml'),
          file: PlacedFile(
            at: 'placed.env_secrets',
            path: 'lib/env/secrets.dart',
            content: 'a'.codeUnits,
          ),
        ),
        completion(PackResult.unchanged),
      );
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
