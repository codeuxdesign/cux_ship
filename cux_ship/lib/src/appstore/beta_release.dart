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
//
// [resolveBetaDescription] runs in the caller's offline validation, not here.
// On `upload --beta-group` the artifact, the processing wait and the notes
// all land before this flow is reached, so a typo'd path or a dirty file
// discovered here would refuse *after* the build went up. Everything about
// the description that can fail without a network has to fail while nothing
// has happened yet; only "is there one anywhere" needs App Store Connect, and
// that check is this file's.
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
  BetaDescription(this.path, this.text, {required this.explicit});

  final String path;
  final String text;

  /// Whether `--beta-description` named the file, as opposed to the tree
  /// supplying it. An explicit flag against a group that cannot use it is
  /// refused; a tree file is standing state rather than an instruction, so
  /// its presence stays harmless where it does not apply.
  final bool explicit;
}

/// The description this release would publish, or null when the repository
/// deliberately supplies none.
///
/// Sources, in order: [optionPath] — `--beta-description`, a file option and
/// never a bare string, so what testers read went through a working tree
/// rather than shell history — then the listing tree's per-locale file. A
/// flag pointing at nothing is refused; an absent tree file is the ordinary
/// way of leaving the console-maintained description alone.
///
/// Everything here is offline — existence, the dirty guard, emptiness, the
/// limit — which is what lets the caller run it before a credential is even
/// loaded, and long before an artifact goes up.
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
  return BetaDescription(path, text, explicit: optionPath != null);
}

/// Gives [build] to [groupName], and for an external group carries it through
/// beta review to the point where only Apple's answer is outstanding.
///
/// [description] comes from [resolveBetaDescription], already run in the
/// caller's offline validation. [metadataPath] is only for naming the file a
/// refusal would have somebody create.
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
  BetaDescription? description,
  String? metadataPath,
}) async {
  final group = await store.findBetaGroup(app, groupName);

  final kind = betaGroupKind(group);
  // A kind Apple did not report is refused, not guessed — and the defaults
  // are not symmetric, which is the stake beyond the absent-is-not-false
  // shape. Guessing external submits an internal group for beta review:
  // wrong, but it fails at Apple where somebody sees it. Guessing internal
  // assigns an external group and prints done — precisely the silently
  // hollow release this flow exists to prevent. Refusing is the only
  // reading that cannot regress it. Cannot happen with the plain lookup
  // above (Apple returns default attributes); a sparse `fields[betaGroups]`
  // added later is what would cause it.
  if (kind == BetaGroupKind.unknown) {
    throw ReleaseException(
      'App Store Connect did not say whether "$groupName" is internal or '
      'external — the betaGroups resource carried no isInternalGroup '
      'attribute, and the two kinds need entirely different releases, so '
      'neither is guessed. Nothing has been written.',
    );
  }

  if (kind == BetaGroupKind.internal) {
    // The explicit flag is refused rather than ignored: a flag that prints a
    // warning and then does nothing is advisory output people learn to skim,
    // and honouring it here would publish a description no internal release
    // uses. Only the *flag* — a tree file is standing state, and the internal
    // path has to stay byte-identical to what it always did.
    if (description != null && description.explicit) {
      throw ReleaseException(
        '"$groupName" is an internal group, which needs no beta review and '
        'publishes no description — drop --beta-description, or release to '
        'an external group.',
      );
    }
    await store.addToBetaGroup(group, build);
    return true;
  }

  // Said out loud because the two paths do very different amounts of work,
  // and which one ran should be readable from the run itself.
  stdout.writeln(
    '    "$groupName" is an external group — carrying on through beta review',
  );

  // Every localization, read once: the preflight below wants to know whether
  // a description exists *anywhere* — a localized app may keep its only one
  // on its primary locale, and refusing over the wrong --locale would be
  // spurious — while the dedupe and the write stay scoped to [locale].
  final localizations = await store.betaAppLocalizations(app);
  Map<String, dynamic>? localization;
  for (final candidate in localizations) {
    if ((candidate['attributes'] as Map<String, dynamic>?)?['locale'] ==
        locale) {
      localization = candidate;
    }
  }
  String descriptionOf(Map<String, dynamic> l) =>
      ((l['attributes'] as Map<String, dynamic>?)?['description'] as String?)
          ?.trim() ??
      '';
  final current = localization == null ? '' : descriptionOf(localization);

  if (description == null &&
      !localizations.any((l) => descriptionOf(l).isNotEmpty)) {
    throw ReleaseException(
      'an external group needs a Beta App Description, and there is none '
      'anywhere — not in the repository, and no locale in App Store Connect '
      'holds one. Apple refuses the beta review submission without one, so '
      'nothing has been written.\n'
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
