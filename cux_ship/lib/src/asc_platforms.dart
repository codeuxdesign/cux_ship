// SPDX-License-Identifier: Apache-2.0
//
// The App Store platforms this tool acts on.
//
// Its own file for the same reason `ListingRequirements` got one: the config
// reader needs it and the App Store CLI needs it, and having the config import
// the CLI for a two-element constant is the coupling that move was made to
// avoid.
//
// One list rather than two, so a platform name cannot be valid in
// `.cux-ship.yaml` and unknown to `--platform`.
//
// **There is a third spelling, and it is the one that resolves rather than
// validates.** `AscPlatform.byName` turns an admitted name into an enum value
// and throws `ArgumentError` for anything else. So this const governs what is
// *admitted* and the enum governs what is *understood*, and adding a platform
// to one alone means the parser accepts it, the config accepts it, and then a
// consumer's release crashes with a stack trace instead of a readable refusal.
//
// `asc_platforms_test.dart` holds the two in step. A test rather than deriving
// one from the other: `AscPlatform` lives beside the API client, so a
// derivation would pull googleapis into the config reader — the coupling this
// file exists to avoid.
library;

const ascPlatforms = ['ios', 'macos'];
