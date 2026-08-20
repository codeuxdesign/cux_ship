// SPDX-License-Identifier: Apache-2.0
//
// This comparison decides whether a release costs a handful of image operations
// or hundreds, and every case where it is *wrong* looks like a working release:
// skip when it should upload and the store keeps stale screenshots; upload when
// it should skip and nothing breaks, it just costs what it always cost. So the
// cases here are mostly about refusing to skip.
import 'package:cux_ship/src/play/cli.dart';
import 'package:test/test.dart';

void main() {
  const a = 'aaa';
  const b = 'bbb';
  const c = 'ccc';

  test('identical digests in the same order match', () {
    expect(imagesMatch([a, b, c], [a, b, c]), isTrue);
  });

  test('the same files in a different order do not', () {
    // Play shows screenshots in upload order, so a reorder is a real change to
    // what a visitor sees — and the digests alone cannot tell you that unless
    // the comparison is ordered.
    expect(imagesMatch([a, b, c], [c, b, a]), isFalse);
  });

  test('a different count never matches', () {
    expect(imagesMatch([a, b], [a, b, c]), isFalse);
    expect(imagesMatch([a, b, c], [a, b]), isFalse);
  });

  test('one changed file is enough', () {
    expect(imagesMatch([a, b, c], [a, 'zzz', c]), isFalse);
  });

  test('a digest Play does not report counts as a difference', () {
    // `Image.sha256` is nullable. A digest the store declines to describe
    // cannot be proven equal, and failing toward the extra upload is right —
    // the alternative is skipping a real change because the API was quiet.
    expect(imagesMatch([a, b], [a, null]), isFalse);
    expect(imagesMatch([a], [null]), isFalse);
  });

  test(
    'both empty matches, so a locale with no images of a type is skipped',
    () {
      expect(imagesMatch([], []), isTrue);
    },
  );

  test('empty against held does not match', () {
    // The committed tree has nothing and the store holds something: that is a
    // deletion, which is a change.
    expect(imagesMatch([], [a]), isFalse);
  });
}
