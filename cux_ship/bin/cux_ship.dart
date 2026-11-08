// SPDX-License-Identifier: Apache-2.0
//
// The one executable. Named after its package so that `dart run cux_ship` and
// `dart pub global activate cux_ship` both work without naming it twice.
//
// **The body moved to `lib/cli.dart` and this is the re-export**, so that a
// consumer can name the entry as `package:cux_ship/cli.dart` and stop reading
// `rootUri` out of `package_config.json` to find this file. That library's
// header carries the whole reason; this line keeps the two invocations above
// working, because `pub global activate` and `dart run <package>` both look for
// an executable under `bin/`.
//
// An `export` rather than an `import` and a delegating `main`: the VM resolves
// the script's `main` through the exported namespace, so there is no wrapper to
// keep in step. Both forms were measured working before this one was chosen.
export 'package:cux_ship/cli.dart' show main;
