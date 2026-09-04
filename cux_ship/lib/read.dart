// SPDX-License-Identifier: Apache-2.0
//
// Asking the stores what they hold, from Dart, without parsing command output.
//
//   import 'package:cux_ship/read.dart';
//
//   final play = await PlayReads.open(packageName: 'design.codeux.example');
//   final tracks = await play.tracks();
//   print(tracks.newestVersionCodeOn('internal'));
//   play.close();
//
// **Every name below is a promise.** Being able to change fast is most of what
// this package is for, which is why the store clients live in `src/` and why
// this file exports as little of them as a caller can be made to work with:
// four value types per store, two sessions, and the three exceptions a caller
// has to be able to catch. Adding a name here is cheap and removing one is a
// major version, so the bar for adding is that something outside this
// repository cannot be written without it.
//
// **Reads only, and that is the whole design.** Nothing here uploads,
// promotes, publishes a listing or moves a build between tracks. Those stay
// commands, deliberately, for two reasons that have nothing to do with how
// pleasant an API would be: the printed command line is what makes a failed
// release step resumable by hand, and per-step `secrets exec --only …` is what
// keeps a credential out of a step that has no use for it. An in-process write
// gives up both.
//
// Each session carries the store's own printed lines beside the parsed values
// — [PlayTracks.lines], [AppStoreBuilds.lines], [AppStoreVersions.lines] —
// because a caller that re-renders a store's table misreports the day the
// store changes it, and does so silently. Print the lines; read the fields.
//
// Both sessions take their credentials from the environment `cux_ship secrets
// exec` sets up, which is the one thing a caller moving off a spawned
// `cux_ship` has to arrange: the variables have to be in the *calling*
// process, so a stage making both a Play and an App Store read runs under one
// `secrets exec` carrying both rather than a per-call `--only`.
library;

export 'src/appstore/app_store.dart'
    show AscPlatform, BuildProcessingProgress, ProcessingTimeout;
export 'src/appstore/asc_client.dart' show AscApiException;
export 'src/appstore/reads.dart'
    show
        AppStoreBuild,
        AppStoreBuilds,
        AppStoreReads,
        AppStoreVersion,
        AppStoreVersions;
export 'src/play/reads.dart'
    show PlayReads, PlayTrack, PlayTrackRelease, PlayTracks;
