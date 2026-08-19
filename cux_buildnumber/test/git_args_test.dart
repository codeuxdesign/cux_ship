import 'package:cux_buildnumber/cux_buildnumber.dart';
import 'package:test/test.dart';

void main() {
  const observed = (
    last: 'aaaa000000000000000000000000000000000001',
    commits: 'bbbb000000000000000000000000000000000002',
    notes: 'cccc000000000000000000000000000000000003',
  );

  group('pushArgs', () {
    test(
      'carries a --force-with-lease=<ref>:<value> for every observed ref',
      () {
        final args = pushArgs(remote: 'origin', observed: observed);
        expect(
          args,
          contains(
            '--force-with-lease=refs/buildnumbers/last:${observed.last}',
          ),
        );
        expect(
          args,
          contains(
            '--force-with-lease=refs/buildnumbers/commits:'
            '${observed.commits}',
          ),
        );
        expect(
          args,
          contains(
            '--force-with-lease=refs/notes/buildnumbers:'
            '${observed.notes}',
          ),
        );
      },
    );

    test(
      'an unobserved ref gets no lease — creation is the first-run case',
      () {
        final args = pushArgs(
          remote: 'origin',
          observed: (last: observed.last, commits: null, notes: null),
        );
        expect(
          args,
          contains(
            '--force-with-lease=refs/buildnumbers/last:${observed.last}',
          ),
        );
        expect(
          args.where((a) => a.startsWith('--force-with-lease=')),
          hasLength(1),
        );
      },
    );

    test('is atomic, so a rejected lease cannot land half the refs', () {
      expect(
        pushArgs(remote: 'origin', observed: observed),
        contains('--atomic'),
      );
      expect(
        pushArgs(remote: 'origin', observed: noObservedRefs),
        contains('--atomic'),
      );
    });

    test('no element of the push argv begins with "+"', () {
      // A + on a push refspec is per-ref --force and silently overrides
      // --force-with-lease — the bug that let two racing runs both "succeed"
      // while the second erased the first's note. No black-box run shows it
      // until two runs race, which is why it is asserted here, on the argv.
      for (final args in [
        pushArgs(remote: 'origin', observed: observed),
        pushArgs(remote: 'mirror', observed: noObservedRefs),
      ]) {
        for (final arg in args) {
          expect(
            arg,
            isNot(startsWith('+')),
            reason: 'a + on the push refspec overrides --force-with-lease',
          );
        }
      }
    });

    test('pushes exactly the two ref namespaces, remote first', () {
      final args = pushArgs(remote: 'mirror', observed: noObservedRefs);
      expect(args, [
        'push',
        '-q',
        '--atomic',
        'mirror',
        'refs/buildnumbers/*:refs/buildnumbers/*',
        'refs/notes/buildnumbers*:refs/notes/buildnumbers*',
      ]);
    });
  });

  group('fetchArgs', () {
    test('force-fetches: every refspec begins with "+"', () {
      // On the fetch the + is wanted: the remote is the authority, and a
      // local ref that has drifted should be overwritten.
      final args = fetchArgs(remote: 'origin', shallow: false);
      final refspecs = args.where((a) => a.contains(':')).toList();
      expect(refspecs, hasLength(2));
      for (final refspec in refspecs) {
        expect(refspec, startsWith('+'));
      }
    });

    test('scopes the notes refspec to our own notes ref', () {
      for (final refspec in fetchRefspecs) {
        expect(
          refspec,
          isNot(contains('refs/notes/*')),
          reason: 'a bare refs/notes/* rolls back other notes refs',
        );
      }
    });

    test('--depth=1 only when the clone is already shallow', () {
      expect(fetchArgs(remote: 'origin', shallow: true), contains('--depth=1'));
      expect(
        fetchArgs(remote: 'origin', shallow: false),
        isNot(contains('--depth=1')),
      );
    });
  });

  group('lsRemoteArgs', () {
    test('asks the push remote for both ref namespaces', () {
      expect(lsRemoteArgs(remote: 'mirror'), [
        'ls-remote',
        'mirror',
        'refs/buildnumbers/*',
        'refs/notes/buildnumbers*',
      ]);
    });
  });

  group('diffIndexArgs', () {
    test('defaults keep --ignore-space-at-eol between --quiet and HEAD', () {
      expect(diffIndexArgs('--ignore-space-at-eol'), [
        'diff-index',
        '--quiet',
        '--ignore-space-at-eol',
        'HEAD',
      ]);
    });

    test('word-splits a multi-argument DIFF_INDEX_ARGS', () {
      expect(diffIndexArgs('-b  -w'), [
        'diff-index',
        '--quiet',
        '-b',
        '-w',
        'HEAD',
      ]);
    });

    test('an empty value adds nothing', () {
      expect(diffIndexArgs(''), ['diff-index', '--quiet', 'HEAD']);
    });
  });
}
