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
library;

const ascPlatforms = ['ios', 'macos'];
