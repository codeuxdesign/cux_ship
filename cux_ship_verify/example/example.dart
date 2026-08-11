// SPDX-License-Identifier: Apache-2.0
//
// Both stores enforce their limits *after* an artifact has been transferred and
// processed — a release note four characters too long, or a screenshot carrying
// the alpha channel every capture has, is refused days later and by a machine.
//
// So the point of these checks is *when* they run. This file shows them as a
// script; the place they belong is your own test suite, where they run on the
// push that introduces the problem rather than at release time. See the README.
import 'package:cux_ship_verify/cux_ship_verify.dart';

void main() {
  final problems = <ReleaseProblem>[
    // Every version section, against both stores' caps — which are not the
    // same number and do not filter the same way, so a section can fit one and
    // not the other.
    ...checkChangelogFile('CHANGELOG.md'),

    // The committed metadata tree, as App Store Connect would read it: text
    // limits, URL schemes, category ids, screenshot dimensions, and the alpha
    // channel Apple refuses outright.
    ...checkAppStoreTree(
      'store/appstore',
      // A universal app needs an iPad set as well as an iPhone one, and Apple
      // refuses the *submission* rather than the upload — so an absent set is
      // invisible until review.
      requireScreenshotTypes: {'APP_IPHONE_67', 'APP_IPAD_PRO_3GEN_129'},
      requireLocales: {'en-US'},
    ),
  ];

  if (problems.isEmpty) {
    print('release inputs are publishable');
    return;
  }
  // All of them at once. Reported one at a time, the second is found only after
  // the first has been fixed and pushed.
  for (final problem in problems) {
    print(problem);
  }
}
