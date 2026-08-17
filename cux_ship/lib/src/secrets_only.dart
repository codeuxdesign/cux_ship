// SPDX-License-Identifier: Apache-2.0
//
// Which credentials reach a child, and the selector that names them.
//
// See docs/design/only-selector.md. The short of it: `keychain exec` gives its
// child the keychain it made and nothing else, and everything further is named
// at the call site with `--only family[.instance]`. `secrets exec` still places
// everything unless `--only` says otherwise.
//
// The reason there is no useful default is structural rather than a failure to
// pick one. A default must satisfy every consumer, so it is the union of their
// needs, and a union is wrong for each of them individually — which is why
// three attempts at one each needed more structure than the last, ending in a
// table. A union has no explanation, only a membership list. A call-site
// selector is one consumer's own set, and it has a reason that fits in the flag.
part of 'secrets.dart';

/// The environment variables one credential would export.
///
/// A pure function of the credential's path, instance and *cleartext* fields —
/// which is what lets it run without decrypting. Three families name their
/// variables from the instance (`apple.certificates`, `apple.profiles`) or from
/// a field in the file (`tokens`, `ssh_keys`), so a static map cannot express
/// them; that is the reason `familyVariables` had to become a function of the
/// parsed file rather than a constant.
///
/// **Kept beside the materializer it mirrors.** These names are asserted equal
/// to what materialization actually exports, because a filter that disagrees
/// with the placer either strips something live or fails to strip something
/// present, and both are silent.
Set<String> variablesForCredential({
  required String path,
  required String instance,
  required Map<String, String> fields,
}) {
  final family = instance.isEmpty
      ? path
      : path.substring(0, path.length - instance.length - 1);
  switch (family) {
    case 'android.keystores':
      // Fixed names: one keystore fills them, chosen by `--keystore` or by
      // being the only one.
      return const {
        'ANDROID_KEYSTORE_PATH',
        'ANDROID_KEYSTORE_PASSWORD',
        'ANDROID_KEY_ALIAS',
        'ANDROID_KEY_PASSWORD',
      };
    case 'android.play_service_account':
      return const {'GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH'};
    case 'apple.api_keys':
      // Every key lands in API_PRIVATE_KEYS_DIR; the selected one also fills
      // the singular names. ISSUER_ID only when the key carries one.
      return {
        'API_PRIVATE_KEYS_DIR',
        'APPLE_API_KEY_ID',
        'APPLE_API_PRIVATE_KEY_PATH',
        if (fields['issuer_id'] != null) 'APPLE_API_ISSUER_ID',
      };
    case 'apple.certificates':
      final prefix = 'APPLE_${instance.toUpperCase()}_P12';
      return {'${prefix}_PATH', '${prefix}_PASSWORD'};
    case 'apple.profiles':
      return {'APPLE_PROFILE_${instance.toUpperCase()}_PATH'};
    case 'tokens':
    case 'ssh_keys':
      // Declared in the file rather than minted from the instance name, and
      // stored in cleartext — which is what makes this readable without an
      // identity. A credential whose `env` is missing exports nothing rather
      // than guessing; `secrets list` already reports it as incomplete.
      final env = fields['env'];
      return env == null || env.isEmpty ? const {} : {env};
    case 'placed':
      // Written to a path in the working tree, never exported.
      return const {};
  }
  return const {};
}

/// Every credential in [secretsFile] and the variables it would export, read
/// **without decrypting**.
///
/// This is what lets a nested `keychain exec` filter an environment it did not
/// place: it takes the certificates-already-present branch and never calls
/// `loadSecrets`, so it has no plaintext — but `env`, `kind` and the instance
/// names are cleartext by design, and that is all this needs.
Map<String, Set<String>> variablesByCredential(File secretsFile) {
  if (!secretsFile.existsSync()) {
    throw ProjectException('no ${secretsFile.path}');
  }
  final dynamic document = loadYaml(secretsFile.readAsStringSync());
  if (document is! YamlMap) {
    throw ProjectException(
      '${secretsFile.path} must be a mapping of credentials',
    );
  }
  final walked = _walk(document, secretsFile.path);
  return {
    for (final credential in walked.credentials)
      credential.path: variablesForCredential(
        path: credential.path,
        instance: credential.instance,
        fields: credential.fields,
      ),
  };
}

/// A parsed `--only` selector: the credential paths it names.
///
/// Resolution is schema-aware because `apple.certificates` and `tokens.marks`
/// are both two segments and only the schema says which is family-plus-instance.
class OnlySelection {
  const OnlySelection(this.paths, this.emptyFamilies);

  /// Credential paths — `tokens.marks`, `apple.certificates.distribution`.
  final Set<String> paths;

  /// Families named that exist in the schema but hold nothing in this file.
  /// Allowed, and reported by the caller: naming a family is a scope, not a
  /// claim about contents. Naming an *instance* is an existence claim and is
  /// fatal, which is the line `decideProfile` already draws between a named
  /// profile that is absent and an unnamed one that merely turns up.
  final Set<String> emptyFamilies;

  bool get isEmpty => paths.isEmpty;
}

/// Turns `--only a,b.c` into the credential paths it names.
///
/// [available] is what the process actually holds — the file's credentials when
/// loading, or the credentials whose variables survived into this environment
/// when filtering one it did not place. **Not the file**, when the two differ:
/// under `secrets exec --only x -- keychain exec --only y --` the inner command
/// asking for something the outer stripped must fail *here*, naming it, rather
/// than four layers down inside a build.
OnlySelection resolveOnly(
  List<String> selectors, {
  required Set<String> available,
  required String at,
}) {
  final families = _schemaFamilies();
  final paths = <String>{};
  final empty = <String>{};

  // Split here rather than relying on the arg parser, so `--only a,b` and
  // `--only a --only b` mean the same thing however the caller was invoked.
  for (final raw in selectors.expand((s) => s.split(','))) {
    final selector = raw.trim();
    if (selector.isEmpty) {
      continue;
    }

    // A section is neither production. `apple` is not a family and refusing it
    // by naming its families is more use than "unknown".
    final sections = _schemaSections();
    if (sections.containsKey(selector)) {
      throw ProjectException(
        '--only $selector is a section, not a credential.\n'
        '    Name one of: ${(sections[selector]!.toList()..sort()).join(', ')}',
      );
    }

    if (families.contains(selector)) {
      // `p == selector` covers a singleton, whose credential path *is* the
      // family name — `android.play_service_account` has no instance level, so
      // splitting it at the last dot would look for a family called `android`.
      final matched = available
          .where((p) => p == selector || _familyOf(p) == selector)
          .toSet();
      if (matched.isEmpty) {
        empty.add(selector);
      }
      paths.addAll(matched);
      continue;
    }

    // Not a family, so it must be family.instance — and the family half has to
    // be one, or this is a typo rather than an instance of something unknown.
    final family = _familyOf(selector);
    if (!families.contains(family)) {
      throw ProjectException(
        '--only $selector names nothing in $at.\n'
        '    There is: ${(families.toList()..sort()).join(', ')}',
      );
    }
    if (!available.contains(selector)) {
      final siblings = available.where((p) => _familyOf(p) == family).toList()
        ..sort();
      throw ProjectException(
        siblings.isEmpty
            ? '--only $selector: there is no $family in $at.'
            : '--only $selector: no such $family. There is: '
                  '${siblings.join(', ')}',
      );
    }
    paths.add(selector);
  }
  return OnlySelection(paths, empty);
}

/// Refuses flag combinations that say the same thing twice, or two things.
///
/// `--keystore` and `--api-key` exist to resolve *which instance* fills a
/// singular set of variable names. An instance named in `--only` already says
/// that, so adjudicating the interaction was three rules where refusing it is
/// one — and the error names the replacement rather than the conflict.
///
/// `--profile` is a different axis and is not replaced: it selects which
/// profiles are *installed for Xcode*, while `--only` selects what the child's
/// environment holds. Readers will conflate them, so naming a profile in
/// `--only` is refused pointing at `--profile`, the same shape as `placed`
/// pointing at `secrets place`.
void checkOnlyCombination({
  required List<String> only,
  String? keystore,
  String? apiKey,
  bool allowProfiles = false,
}) {
  if (only.isEmpty) {
    return;
  }
  for (final entry in {'--keystore': keystore, '--api-key': apiKey}.entries) {
    if (entry.value != null) {
      throw ProjectException(
        '${entry.key} and --only say the same thing. Name the instance in '
        '--only:\n'
        '    --only <family>.${entry.value}',
      );
    }
  }
  if (allowProfiles) {
    return;
  }
  for (final selector in only.expand((s) => s.split(','))) {
    final name = selector.trim();
    if (name == 'apple.profiles' || name.startsWith('apple.profiles.')) {
      throw ProjectException(
        '--only $name: profiles are installed for Xcode rather than placed in '
        'the environment.\n'
        '    Use --profile to choose which ones are installed.',
      );
    }
    if (name == 'placed' || name.startsWith('placed.')) {
      throw ProjectException(
        '--only $name: exec never writes placed files.\n'
        '    Use `cux_ship secrets place`.',
      );
    }
  }
}

/// Families the selection excludes entirely, so they can be withheld whole.
///
/// The difference matters for the two families whose materialization *chooses*
/// between instances: skipping the family avoids `_select`, which refuses to
/// guess between two keystores. Filtering only at the instance level would make
/// it refuse on behalf of a child that asked for neither — which is the lockout
/// that made whole-family withholding necessary in the first place.
///
/// Returns null when [only] is null, so "everything" stays distinguishable from
/// "nothing selected".
Set<String>? _familiesWithNothingSelected(
  List<_Credential> credentials,
  Set<String>? only,
) {
  if (only == null) {
    return null;
  }
  final held = <String>{};
  for (final credential in credentials) {
    final family = credential.instance.isEmpty
        ? credential.path
        : credential.path.substring(
            0,
            credential.path.length - credential.instance.length - 1,
          );
    if (!only.any((p) => p == family || _familyOf(p) == family)) {
      held.add(family);
    }
  }
  return held;
}

/// `tokens.marks` -> `tokens`; `android.play_service_account` -> itself.
String _familyOf(String path) {
  final cut = path.lastIndexOf('.');
  return cut < 0 ? path : path.substring(0, cut);
}

Set<String> _schemaFamilies() {
  final names = <String>{};
  void walk(_Node node, String at) {
    switch (node) {
      case _Section(:final children):
        for (final entry in children.entries) {
          walk(entry.value, at.isEmpty ? entry.key : '$at.${entry.key}');
        }
      case _Family():
      case _Singleton():
        names.add(at);
    }
  }

  walk(_schema, '');
  return names;
}

/// Section path to the families directly under it, for the refusal message.
Map<String, Set<String>> _schemaSections() {
  final sections = <String, Set<String>>{};
  void walk(_Node node, String at) {
    if (node is! _Section) {
      return;
    }
    if (at.isNotEmpty) {
      sections[at] = {
        for (final entry in node.children.entries) '$at.${entry.key}',
      };
    }
    for (final entry in node.children.entries) {
      walk(entry.value, at.isEmpty ? entry.key : '$at.${entry.key}');
    }
  }

  walk(_schema, '');
  return sections;
}
