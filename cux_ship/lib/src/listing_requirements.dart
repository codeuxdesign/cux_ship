// SPDX-License-Identifier: Apache-2.0
//
// What a repository declares its listing must carry, on the way to a store.
//
// Its own file because both store libraries need it and neither should import
// the other: it started in `appstore/cli.dart`, and leaving it there would have
// made the Play uploader depend on the App Store CLI for a two-field value
// object.
//
// Passed in rather than read here. Neither store library knows about
// `.cux-ship.yaml` and neither should — the runner resolves flag, then file,
// then inference, and hands down the answer.
library;

/// The locales and screenshot types a listing has to carry.
///
/// The two sets are in different vocabularies depending on which store is
/// asking: `ScreenshotDisplayType` names for the App Store, directory names
/// like `phoneScreenshots` for Play. They are never mixed, because each store's
/// runner builds its own from that store's block.
class ListingRequirements {
  const ListingRequirements({
    this.locales = const {},
    this.screenshotTypes = const {},
  });

  final Set<String> locales;
  final Set<String> screenshotTypes;
}
