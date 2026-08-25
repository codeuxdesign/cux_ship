// SPDX-License-Identifier: Apache-2.0

// Releases a build TestFlight already holds to a beta group.
//
// One flow behind three spellings — `upload --beta-group`, `promote
// --beta-group` and `beta-release` — because the work is identical once the
// build exists, and it forks on what kind of group receives it:
//
//   - An **internal** group gets the build by assignment alone, within
//     minutes. Assign, done, exactly as before.
//   - An **external** group gets nothing from assignment. TestFlight shows a
//     build to external testers only after Apple's beta review, and Apple
//     refuses that submission while the Beta App Description is empty — so a
//     tool that assigned the group and stopped would report a release that
//     delivered nothing. Here the flow carries on: reassert the description,
//     submit for beta review, and read back which state the build landed in.
//
// The description follows the standing metadata rule, **present means
// owned**: a `beta_description.txt` in the listing tree is reasserted on
// every release, because a source of truth nothing pushes is one the console
// quietly drifts from. And absent means left alone — a description somebody
// maintains in App Store Connect is respected, and only *no description
// anywhere* is refused, before anything has been written.
import 'dart:io';

import '../notes_source.dart';
import '../release.dart' show ReleaseException;
import 'app_store.dart';

/// What Apple accepts in `betaAppLocalizations.description`, in UTF-16 code
/// units — over-counting outside the BMP, wrong in the safe direction, the
/// same arithmetic as every listing limit.
const betaAppDescriptionLimit = 4000;

/// Where the listing tree keeps the Beta App Description for [locale] —
/// beside the other per-locale listing files, so one directory answers "what
/// does this locale say about the app" for TestFlight and the store alike.
String betaDescriptionFileIn(String metadataPath, String locale) => [
  metadataPath,
  'listings',
  locale,
  'beta_description.txt',
].join(Platform.pathSeparator);

/// A Beta App Description the repository supplies, and the file it came from.
///
/// The path is kept because the dirty-file guard and every refusal want to
/// name it, not merely quote it.
class BetaDescription {
  BetaDescription(this.path, this.text);

  final String path;
  final String text;
}

/// The description this release would publish, or null when the repository
/// deliberately supplies none.
///
/// Sources, in order: [optionPath] — `--beta-description`, a file option and
/// never a bare string, so what testers read went through a working tree
/// rather than shell history — then the listing tree's per-locale file. A
/// flag pointing at nothing is refused; an absent tree file is the ordinary
/// way of leaving the console-maintained description alone.
BetaDescription? resolveBetaDescription({
  String? optionPath,
  String? metadataPath,
  required String locale,
}) {
  var path = optionPath;
  if (path != null) {
    if (!File(path).existsSync()) {
      throw ReleaseException('--beta-description: no such file: $path');
    }
  } else if (metadataPath != null) {
    final treeFile = betaDescriptionFileIn(metadataPath, locale);
    if (File(treeFile).existsSync()) {
      path = treeFile;
    }
  }
  if (path == null) {
    return null;
  }

  // The changelog's guard, for the changelog's reason: this text reaches
  // testers, and a working tree is the one copy nobody else has seen.
  requireCommittedNotes([path], what: 'the beta app description');

  final text = File(path).readAsStringSync().trim();
  if (text.isEmpty) {
    throw ReleaseException(
      '$path is empty — delete the file to leave the description as App Store '
      'Connect has it, rather than publishing a blank one',
    );
  }
  if (text.length > betaAppDescriptionLimit) {
    throw ReleaseException(
      '$path is ${text.length} characters; TestFlight allows '
      '$betaAppDescriptionLimit',
    );
  }
  return BetaDescription(path, text);
}

/// Gives [build] to [groupName], and for an external group carries it through
/// beta review to the point where only Apple's answer is outstanding.
///
/// Returns true when the group was internal — where assignment alone *is* the
/// release, nothing further happens, and the caller keeps whatever closing
/// sentence it always printed for that case.
Future<bool> releaseToBetaGroup(
  AppStore store,
  App app,
  Map<String, dynamic> build,
  String groupName, {
  required String locale,
  String? descriptionPath,
  String? metadataPath,
}) async {
  final group = await store.findBetaGroup(app, groupName);

  if (isInternalBetaGroup(group)) {
    await store.addToBetaGroup(group, build);
    return true;
  }

  // External, so everything that can refuse does it now, before the first
  // write — App Store Connect has no edit transaction to discard, and a
  // refusal after the group assignment would leave a half-made release.
  final description = resolveBetaDescription(
    optionPath: descriptionPath,
    metadataPath: metadataPath,
    locale: locale,
  );
  // Read once, whatever happens next: the preflight needs it when the
  // repository supplies nothing, the dedupe needs it when it does.
  final localization = await store.betaAppLocalization(app, locale);
  final current =
      ((localization?['attributes'] as Map<String, dynamic>?)?['description']
              as String?)
          ?.trim() ??
      '';
  if (description == null && current.isEmpty) {
    throw ReleaseException(
      'an external group needs a Beta App Description, and there is none '
      'anywhere — not in the repository, not in App Store Connect. Apple '
      'refuses the beta review submission without one, so nothing has been '
      'written.\n'
      'Either create '
      '${betaDescriptionFileIn(metadataPath ?? 'store/appstore', locale)} — '
      'owned and reasserted by every release from then on — or fill it in '
      'once in App Store Connect > TestFlight > Test Information, which this '
      'tool then leaves alone.',
    );
  }

  await store.addToBetaGroup(group, build);

  if (description != null) {
    stdout.writeln('==> beta app description');
    if (description.text == current) {
      // The Play-images lesson: writing a value the store already holds
      // reports change where there is none, so an identical description is
      // said to be identical rather than re-sent.
      stdout.writeln('    unchanged — App Store Connect already holds this');
    } else {
      await store.writeBetaAppDescription(
        app,
        locale,
        description.text,
        existing: localization,
      );
    }
  }

  stdout.writeln('==> beta review');
  await store.submitBetaReview(build);
  await store.reportExternalBuildState(build);
  return false;
}
