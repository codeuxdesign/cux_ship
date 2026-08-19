import 'package:cux_buildnumber/cux_buildnumber.dart';
import 'package:test/test.dart';

void main() {
  group('nextBuildNumber', () {
    test('starts at 1 when no counter exists', () {
      expect(nextBuildNumber(null), 1);
    });

    test('increments the shared counter', () {
      expect(nextBuildNumber(41), 42);
    });
  });

  group('forceIncrNext', () {
    test('counts from the shared counter, not from HEAD\'s own note', () {
      // HEAD on 1, counter on 3: counting from the note would yield 2 — a
      // number another commit already owns — and roll the counter backwards.
      expect(forceIncrNext(counter: 3, current: 1), 4);
    });

    test('falls back to the current number when the counter is unreadable', () {
      expect(forceIncrNext(counter: null, current: 5), 6);
    });

    test('never goes below the current number', () {
      expect(forceIncrNext(counter: 1, current: 5), 6);
    });
  });

  group('retry decisions', () {
    test('only the first attempt may trust a local note', () {
      expect(mayTrustLocalNote(1), isTrue);
      expect(mayTrustLocalNote(2), isFalse);
    });

    test('attempts are bounded', () {
      expect(shouldRetryAfterLostPush(attempt: 1, maxAttempts: 2), isTrue);
      expect(shouldRetryAfterLostPush(attempt: 2, maxAttempts: 2), isFalse);
    });
  });

  group('counterBlobContent', () {
    test('carries the trailing newline — it is part of the blob hash', () {
      expect(counterBlobContent('7'), '7\n');
    });
  });

  group('lsTreeEntryHash', () {
    const lsTree =
        '100644 blob aaaa0001\tb1\n'
        '100644 blob aaaa0002\tb12\n';

    test('finds the entry by exact name', () {
      expect(lsTreeEntryHash(lsTree, 'b1'), 'aaaa0001');
      expect(lsTreeEntryHash(lsTree, 'b12'), 'aaaa0002');
    });

    test('a name that is a suffix of another does not match it', () {
      expect(lsTreeEntryHash(lsTree, 'b2'), isNull);
    });

    test('an empty tree has no entries', () {
      expect(lsTreeEntryHash('', 'b1'), isNull);
    });
  });

  group('chainTreeInput', () {
    test('replaces an entry of the same name instead of duplicating it', () {
      // Leaving the old entry in place makes mktree write a tree with two
      // entries of the same name — invalid to git fsck. Only reachable when a
      // number is rewritten (force, force-incr).
      final input = chainTreeInput(
        existingLsTree:
            '100644 blob aaaa0001\tb1\n'
            '100644 blob aaaa0002\tb2\n',
        entryName: 'b1',
        blobHash: 'ffff0009',
      );
      expect(input, '100644 blob aaaa0002\tb2\n100644 blob ffff0009\tb1\n');
    });

    test('keeps entries whose name merely ends the same way', () {
      final input = chainTreeInput(
        existingLsTree: '100644 blob aaaa0002\tb11\n',
        entryName: 'b1',
        blobHash: 'ffff0009',
      );
      expect(input, '100644 blob aaaa0002\tb11\n100644 blob ffff0009\tb1\n');
    });

    test('an empty chain tree yields the one new entry', () {
      expect(
        chainTreeInput(
          existingLsTree: '',
          entryName: 'b1',
          blobHash: 'ffff0009',
        ),
        '100644 blob ffff0009\tb1\n',
      );
    });
  });

  group('chainBlobContent', () {
    test('appends the built SHA with a trailing newline', () {
      expect(
        chainBlobContent(previous: const [], headSha: 'abc'),
        'abc\n'.codeUnits,
      );
    });

    test('a rewrite keeps the previous holder\'s line', () {
      expect(
        chainBlobContent(previous: 'old\n'.codeUnits, headSha: 'new'),
        'old\nnew\n'.codeUnits,
      );
    });
  });

  group('uniqueAdjacentLines', () {
    test('collapses adjacent duplicates and strips trailing newlines', () {
      expect(uniqueAdjacentLines('a\na\nb\n'), 'a\nb');
    });

    test('keeps non-adjacent duplicates, like uniq', () {
      expect(uniqueAdjacentLines('a\nb\na\n'), 'a\nb\na');
    });
  });
}
