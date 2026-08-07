// SPDX-License-Identifier: Apache-2.0
//
// The offline checks, re-exported so a consumer needs exactly one dependency.
//
// Not a convenience. pub treats a git dependency's ref as part of its identity
// and does not resolve a tag to a commit before comparing, so a package named
// both directly (at a tag) and transitively (at the commit a relative `path:`
// resolved to) is an unsolvable conflict. Depending on `cux_ship` alone and
// importing this leaves nothing to collide, which is what lets a consumer pin a
// readable tag instead of a SHA.
//
//   import 'package:cux_ship/verify.dart';
//
//   test('every changelog section fits both stores', () {
//     expect(checkChangelogFile('CHANGELOG.md'), isEmpty);
//   });
export 'package:cux_ship_verify/cux_ship_verify.dart';
