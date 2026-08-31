// SPDX-License-Identifier: Apache-2.0
//
// The listing publish is reachable from two places in `runAsc`, and for a
// promote-with-metadata both of them used to fire: the shared site above the
// promote block and the one inside it, each guarded by its own `metadata !=
// null`. The whole listing published twice and every screenshot was cleared
// and re-uploaded twice, under a comment saying "the listing publishes here,
// and only here".
//
// **This header used to say the interesting assertion here was the one that
// proved no input can make two sites act. There was never such an assertion,
// and it cannot be written in this file.** Two attempts at it compared one
// enum value against two distinct constants — false for every possible
// implementation, killed by no mutation — and the second shipped under a
// comment claiming otherwise. The retraction reached the test and not this
// paragraph, which is the last place the claim stood.
//
// What this file covers is [listingPublish]: which runs get a publish, and
// which of the two sites is chosen. That is all of the function's behaviour
// and none of the call sites'.
//
// The property that no call site can double-publish is held structurally
// rather than tested — `publish` is one `final` local, decided once, read at
// two sites that compare it against distinct constants of one enum, so a
// single value cannot select both. Observing it for real would mean driving
// `runAsc` against a fake client and counting listing writes.
import 'package:cux_ship/src/appstore/cli.dart';
import 'package:test/test.dart';

void main() {
  group('with no metadata nothing publishes', () {
    test('however the run is otherwise spelled', () {
      for (final artifact in [true, false]) {
        for (final promote in [true, false]) {
          expect(
            listingPublish(
              hasMetadata: false,
              hasArtifact: artifact,
              promote: promote,
            ),
            ListingPublish.none,
            reason: 'artifact: $artifact, promote: $promote',
          );
        }
      }
    });
  });

  group('an upload carrying an artifact leaves the listing alone', () {
    // These writes reach appStoreVersionLocalizations through ensureVersion,
    // which *creates* the version record — publishing beside a TestFlight
    // build would bring an App Store version into existence for a release
    // nobody decided to make.
    test('even with metadata resolved', () {
      expect(
        listingPublish(hasMetadata: true, hasArtifact: true, promote: false),
        ListingPublish.none,
      );
    });

    test(
      'and the artifact wins over promote, which is not exclusive of it',
      () {
        expect(
          listingPublish(hasMetadata: true, hasArtifact: true, promote: true),
          ListingPublish.none,
        );
      },
    );
  });

  test('a listing-only invocation publishes at the shared site', () {
    expect(
      listingPublish(hasMetadata: true, hasArtifact: false, promote: false),
      ListingPublish.shared,
    );
  });

  test('a promotion publishes after the version, not at the shared site', () {
    // Not `shared`: the version record the listing hangs off does not exist
    // yet at the shared site, and the publish has to land after the build is
    // attached and before the submission so review sees the right copy.
    expect(
      listingPublish(hasMetadata: true, hasArtifact: false, promote: true),
      ListingPublish.afterVersion,
    );
  });

  test('a publish is decided for exactly the runs that should have one', () {
    // **Two attempts at this test were vacuous, and the second was worse than
    // the first, because it came with a comment claiming it was not.**
    //
    // Both wrote `decision == shared && decision == afterVersion` and asserted
    // it false. One variable against two distinct constants is false for every
    // possible implementation — no mutation can kill it. The second version
    // dressed it up as "the two call sites" and claimed that reverting a guard
    // in `runAsc` would make it fail. It would not: those guards are in
    // `runAsc`, and restating them here over a return value observes nothing
    // about them.
    //
    // **So the honest scope of this file is `listingPublish` itself**, and
    // that is what is asserted: which runs get a publish decided at all. It is
    // falsifiable — an enum that never published, or one that published for an
    // artifact upload, fails here.
    //
    // The property that no *call site* can double-publish is not testable from
    // here. It is held structurally instead: the two sites read one value, and
    // a value is one thing. Testing it would mean driving `runAsc` against a
    // fake client and counting listing writes, which nothing here does.
    for (final metadata in [true, false]) {
      for (final artifact in [true, false]) {
        for (final promote in [true, false]) {
          final decision = listingPublish(
            hasMetadata: metadata,
            hasArtifact: artifact,
            promote: promote,
          );
          expect(
            decision != ListingPublish.none,
            metadata && !artifact,
            reason:
                'metadata: $metadata, artifact: $artifact, promote: $promote',
          );
        }
      }
    }
  });

  test('a publish is decided whenever there is a listing and no artifact', () {
    // The other half of the same property: the enum must not lose a publish
    // the old pair of conditions would have made.
    for (final promote in [true, false]) {
      expect(
        listingPublish(hasMetadata: true, hasArtifact: false, promote: promote),
        isNot(ListingPublish.none),
        reason: 'promote: $promote',
      );
    }
  });
}
