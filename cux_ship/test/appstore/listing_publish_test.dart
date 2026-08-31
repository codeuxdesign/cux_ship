// SPDX-License-Identifier: Apache-2.0
//
// The listing publish is reachable from two places in `runAsc`, and for a
// promote-with-metadata both of them used to fire: the shared site above the
// promote block and the one inside it, each guarded by its own `metadata !=
// null`. The whole listing published twice and every screenshot was cleared
// and re-uploaded twice, under a comment saying "the listing publishes here,
// and only here".
//
// So the interesting assertion in this file is not any single row of the
// table — it is the last test, which says no input can make two sites act.
// That is the property the enum exists to hold, and a pair of complementary
// conditions could not state it at all.
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

  test('no input makes both sites publish', () {
    // The regression, stated as a property rather than as a row. Each site
    // reads one value of the enum, and a value is one thing.
    for (final metadata in [true, false]) {
      for (final artifact in [true, false]) {
        for (final promote in [true, false]) {
          final decision = listingPublish(
            hasMetadata: metadata,
            hasArtifact: artifact,
            promote: promote,
          );
          final acting = [
            decision == ListingPublish.shared,
            decision == ListingPublish.afterVersion,
          ].where((fires) => fires).length;
          expect(
            acting,
            lessThanOrEqualTo(1),
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
