// SPDX-License-Identifier: Apache-2.0

// `cux_ship storefront released` — when the public actually got a version.
//
//   cux_ship storefront released --bundle-id design.codeux.howitwent [--json]
//
// **Its own command group, and not a subcommand of `appstore`.** Every member
// of that group loads an App Store Connect key; this loads nothing, and a
// credential-free read sitting among them would read as one that had simply
// not reached the auth step yet. The consuming release train spawns every
// other read as `secrets exec --only <credential> -- …` and must not wrap this
// one — which is a property somebody reads off a command line in a log, so the
// command line is where it has to be visible.
//
// **`storefront` names an Apple thing only.** Google Play's public listing
// carries an "Updated on" date and there is no API behind it — `TrackRelease`
// has no timestamp at all and the Edits API cannot list past edits — so
// nothing should ever be added under this group for Play. Written here as well
// as in the design document because a group named for a store-neutral noun is
// exactly what invites somebody to try.
import 'dart:io';

import 'package:args/args.dart';

import 'itunes_client.dart';
import 'reads.dart';

/// Which storefront operation [runStorefront] performs.
///
/// An enum with one member, shaped like `AscCommand` and `PlayCommand` so a
/// second one is an addition rather than a restructuring. There is no second
/// one in prospect: the storefront answers one question this package has a use
/// for.
enum StorefrontCommand {
  released('released');

  const StorefrontCommand(this.name);

  /// The subcommand as typed, used in diagnostics.
  final String name;
}

/// What `cux_ship` exits with when the storefront holds no such app.
///
/// **An ordinary state, not a failure**, on exactly the argument
/// `noSuchVersionExit` makes: every run before an app's first release looks
/// like this, and a readiness check asking *"is it out yet"* the day before it
/// is out is not broken — it has its answer.
///
/// **6 rather than reusing 5**, by README.md's rule that an existing code never
/// changes meaning and a new condition takes a new number. "App Store Connect
/// holds no version named 1.1.8" and "the public storefront has never heard of
/// this app" are different conditions with different next actions, and one
/// number over both would report a version nobody has created yet and an app
/// that has never shipped as the same event.
///
/// **The document is still printed under `--json`.** This is the answer rather
/// than a failure, so it belongs on stdout where a consumer renders `display`
/// — see the design document, §"Absence is an answer, and it gets both
/// halves".
const notOnStorefrontExit = 6;

/// The parser for [cmd].
ArgParser buildStorefrontParser(StorefrontCommand cmd) => ArgParser()
  ..addOption(
    'bundle-id',
    help:
        'e.g. design.codeux.holdthewheel. Defaults to the project\'s *iOS* '
        'bundle identifier, which is the one a universal purchase is listed '
        'under — a Mac app listed separately has its own and needs this flag.',
  )
  ..addOption(
    'country',
    defaultsTo: 'us',
    help:
        'Which storefront answers, as a two-letter code. The App Store is per '
        'region, and this is not inferred from the machine: the same command '
        'would then answer differently on a laptop and on CI. An app that is '
        'not sold on this storefront reads exactly like one that has never '
        'been released, so a project that does not sell in the US has to set '
        'this.',
  )
  ..addFlag(
    'json',
    negatable: false,
    help:
        'Print the answer as a JSON document instead of prose. stdout carries '
        'the document and nothing else; every other line goes to stderr. An '
        'app the storefront does not know still prints a document — with a '
        'null "app" — and exits 6. See '
        'docs/design/storefront-release-date.md.',
  );

/// Defaults read from the project, for the arguments that have one.
class StorefrontDefaults {
  const StorefrontDefaults({this.bundleId});

  /// Nothing inferred. Used where there is no project to read.
  static const none = StorefrontDefaults();

  /// **The iOS bundle identifier, deliberately.** A universal purchase is
  /// listed under it whether or not it also runs on the Mac, and the
  /// storefront has no per-platform answer to give — so this is not "the iOS
  /// half of two answers", it is the identifier the one record is filed under.
  final String? bundleId;
}

/// Runs one storefront subcommand.
///
/// [client] is the seam a test replaces. Production builds an [ItunesClient],
/// and nothing here reads an environment variable or a credential of any kind.
Future<void> runStorefront(
  StorefrontCommand cmd,
  ArgResults args, {
  StorefrontDefaults defaults = StorefrontDefaults.none,
  StorefrontClient? client,
}) async {
  Never fail(String message) {
    stderr.writeln('cux_ship storefront ${cmd.name}: $message');
    exit(1);
  }

  final jsonOutput = args.flag('json');
  final bundleId = args.option('bundle-id') ?? defaults.bundleId;
  if (bundleId == null) {
    fail(
      'no bundle id — pass --bundle-id, or run from a project whose Xcode '
      'project names one',
    );
  }

  final country = args.option('country')!;
  if (country.isEmpty) {
    // Caught here rather than sent, because an empty `country` is dropped by
    // the storefront and answered from whichever region it defaults to — a
    // silently different question from the one that was asked.
    fail('--country is empty; it takes a storefront such as us, de or jp');
  }

  // **stderr under `--json`, on the rule every other command in this package
  // states: stdout carries the document and nothing else.** Written as a
  // branch rather than a ternary sink so the non-JSON path is visibly
  // unchanged.
  final banner =
      '==> $bundleId on the $country App Store storefront '
      '(no credential)';
  if (jsonOutput) {
    stderr.writeln(banner);
  } else {
    stdout.writeln(banner);
  }

  final StorefrontRelease release;
  try {
    release = await readStorefrontRelease(
      client ?? ItunesClient(),
      bundleId: bundleId,
      country: country,
    );
  } on StorefrontException catch (e) {
    // Prose on stderr and an empty stdout, which is what json-output.md says
    // a *failure* looks like. The absence below is the other thing and is not
    // routed through here.
    fail(e.message);
  }

  printStorefrontRelease(release, json: jsonOutput);

  if (release.app == null) {
    // **Set rather than `exit()`, so the document above is already written.**
    // `fail()` exits immediately and would be wrong twice here: it would
    // suppress the document, and it would report an answer as a failure.
    exitCode = notOnStorefrontExit;
  }
}
