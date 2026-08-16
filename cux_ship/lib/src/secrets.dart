// SPDX-License-Identifier: Apache-2.0
//
// Decrypts a sops file and runs a command with the credentials in its
// environment.
//
//   cux_ship secrets exec -- tool/build.sh --release android
//   cux_ship secrets exec -- env
//
// **This is the only part of cux_ship that knows sops exists, and that is
// structural.** Every uploader reads plain environment variables and nothing
// else, so they work unchanged if the credentials ever come from Vault, another
// CI's secret store, or a shell somebody exported by hand. The encryption
// choice stays swappable because there is exactly one place that creates
// plaintext and one that destroys it.
//
// Values are passed in the environment rather than written to disk. The
// exceptions are the three that a tool can only open as a file — the Android
// keystore, the App Store Connect key and the distribution certificate — and
// each is materialized into a private temp directory that is removed however
// this exits.
//
// The identity is never in the repository. Locally it is
// ~/.config/sops/age/keys.txt; in CI it is the single SOPS_AGE_KEY secret, so
// switching CI provider means moving one value.
import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

import 'placed.dart';
import 'project.dart';

/// What the file may contain, declared once.
///
/// The shape is the schema and the schema is data. Everything that used to
/// recover structure from a name — which credential a key belongs to, which
/// instance, whether it is recognized at all — is now a position in this tree,
/// so the recovery cannot be reimplemented slightly differently by each caller.
/// That is not a tidiness argument: every defect this file has had was one
/// consumer's idea of "recognized" drifting from another's.
sealed class _Node {
  const _Node();
}

/// Fixed keys, enumerated here. An unknown child is fatal.
///
/// This is what keeps a typo'd structural node loud: at `apple.` the only legal
/// keys are the ones named below, and "a credential" is not among the options —
/// so `certifcates:` cannot be quietly read as something's name.
class _Section extends _Node {
  const _Section(this.children);

  final Map<String, _Node> children;
}

/// A credential that may exist more than once, each under a name of its own.
///
/// [instances] closes the set where the names mean something — Apple's
/// certificate types are an enum, so `developr_id` is a typo and can be refused.
/// Left null the names are the project's to choose, which is right for keystores
/// and profiles, and the level no schema can police.
class _Family extends _Node {
  const _Family(this.what, {required this.fields, this.instances});

  final String what;
  final List<_Field> fields;
  final Set<String>? instances;
}

/// A credential with no instance level, because there is only ever one.
class _Singleton extends _Node {
  const _Singleton(this.what, {required this.fields});

  final String what;
  final List<_Field> fields;
}

/// One value of one credential.
///
/// Required is the default: a half-configured credential is the dangerous state,
/// since a keystore with no password does not fail as "you forgot the password"
/// — Gradle falls through to the debug key and produces an artifact only Play
/// rejects, after a full upload.
class _Field {
  const _Field(this.name, {this.required = true});

  final String name;
  final bool required;
}

const _schema = _Section({
  'android': _Section({
    'keystores': _Family(
      'an Android signing key',
      fields: [
        _Field('base64'),
        _Field('password'),
        _Field('key_alias'),
        // PKCS12 uses one password for the store and the key alike, so this is
        // almost never set — but a keystore with a genuinely separate key
        // password slots straight in, and Gradle needs no special case.
        _Field('key_password', required: false),
      ],
    ),
    'play_service_account': _Singleton(
      'the Play service account',
      fields: [_Field('json_base64')],
    ),
  }),
  'apple': _Section({
    'api_keys': _Family(
      'an App Store Connect API key',
      fields: [
        _Field('id'),
        _Field('private_key_base64'),
        // Declared, not inferred. altool and this tool's JWT builder both read
        // the *filename* to decide which claims to send, and materialization
        // writes that filename — so inferring the kind from a name we chose
        // ourselves is circular, and got an individual key sent `iss` and a
        // bare 401 after a full build. The filename is derived from this and
        // the id; see _apiKeyFileName.
        _Field('kind'),
        // Optional because altool documents --api-issuer as required alongside
        // --api-key even for an individual key, while the REST JWT must not
        // carry `iss`. Having one says nothing about which kind this is.
        _Field('issuer_id', required: false),
      ],
    ),
    'certificates': _Family(
      'an Apple signing certificate',
      instances: {'distribution', 'developer_id', 'mac_installer'},
      fields: [_Field('p12_base64'), _Field('password')],
    ),
    'profiles': _Family('a provisioning profile', fields: [_Field('base64')]),
  }),
  // The escape hatch, and deliberately a narrow one. A project has credentials
  // this tool will never understand — an artifact host, a mirror — and the
  // alternative to holding them here is the project keeping a second secret
  // mechanism forever.
  //
  // `env` is declared rather than minted, so nothing has to invent a variable
  // name from an instance name, and a typo is still a typo rather than a
  // silently absent credential.
  'tokens': _Family(
    'a project token',
    fields: [_Field('env'), _Field('value')],
  ),
  // A key something wants as a *file* but has no opinion about where — ssh
  // takes `-i <path>`. Same shape as a p12, and a different shape from a
  // credential the build reads at a path it does not choose, which is the one
  // question that decides where anything in here belongs.
  'ssh_keys': _Family('an ssh key', fields: [_Field('base64'), _Field('env')]),
  // Written where the build expects it, and left there — the other families all
  // materialize into a temp directory that is removed however the run ends.
  //
  // These are source: `flutter build` and the analyzer read them from those
  // exact paths, and a test imports one, so they cannot live in a temp
  // directory and cannot vanish when a command exits. `secrets exec` therefore
  // does not write them at all; `secrets place` does, and `secrets clean`
  // removes them.
  //
  // The guarantee is different in kind, and weaker: not "plaintext never
  // outlives the run" but "plaintext never enters history".
  'placed': _Family(
    'a file the build reads from the working tree',
    fields: [_Field('path'), _Field('base64')],
  ),
});

/// Fields whose values must stay readable without an identity.
///
/// `secrets keys` reports paths, and `place` checks a path against the
/// repository before writing anything — both of which need the value, so these
/// have to be outside sops' encryption. That is a real disclosure: a `path`
/// tells a reader where a project keeps things and an `env` which services it
/// uses. Both are low sensitivity and largely inferable from a repository
/// anyone can already read, and the trade buys a pre-flight that works with no
/// key at all.
const _cleartextFields = {'path', 'env', 'kind'};

/// No field carrying a secret may share a name with a cleartext one.
///
/// Stated as a rule it holds until somebody adds a family at 2am, so it is
/// asserted over the schema instead: a family whose secret-bearing field is
/// called `path` fails the suite rather than review.
///
/// Public because a check nothing calls is decoration — the suite calls it, so
/// the schema cannot be extended into a disclosure without a red test.
void assertSchemaKeepsSecretsEncrypted() => _assertNoSecretIsCleartext();

void _assertNoSecretIsCleartext() {
  void check(_Node node, String at) {
    switch (node) {
      case _Section(:final children):
        for (final entry in children.entries) {
          check(entry.value, at.isEmpty ? entry.key : '$at.${entry.key}');
        }
      case _Family(:final fields) || _Singleton(:final fields):
        for (final field in fields) {
          final carriesSecret =
              field.name.endsWith('base64') ||
              field.name.contains('password') ||
              field.name == 'value';
          if (carriesSecret && _cleartextFields.contains(field.name)) {
            throw StateError(
              '$at.${field.name} carries a secret and is named like a field '
              'that is stored in cleartext',
            );
          }
        }
    }
  }

  check(_schema, '');
}

/// Instance names become filenames — `<instance>.p12` in the temp directory,
/// and one profile per name — so the grammar is a path-traversal guard as much
/// as a spelling rule. No dots, no separators, nothing that leaves the
/// directory it is written into.
final _instanceName = RegExp(r'^[a-z][a-z0-9]*(_[a-z0-9]+)*$');

/// One credential found in the file: where it is, what it is, and its values.
class _Credential {
  const _Credential({
    required this.path,
    required this.what,
    required this.instance,
    required this.fields,
  });

  /// `android.keystores.upload`, and what every message about it says.
  final String path;
  final String what;

  /// The instance name, or `''` for a singleton.
  final String instance;

  /// Field name to value. Values are ciphertext when the file has not been
  /// decrypted, which is why the walk never looks at them.
  final Map<String, String> fields;

  bool get isComplete => missing.isEmpty;

  List<String> get missing => [
    for (final field in _fieldsOf(what, path))
      if (field.required && !fields.containsKey(field.name)) field.name,
  ];
}

/// The declared fields of whatever sits at [path]. Only used for reporting, so
/// it re-descends rather than being threaded through.
List<_Field> _fieldsOf(String what, String path) {
  final parts = path.split('.');
  _Node? node = _schema;
  for (final part in parts) {
    if (node is _Section) {
      node = node.children[part];
    } else if (node is _Family) {
      break;
    }
  }
  return switch (node) {
    _Family(:final fields) => fields,
    _Singleton(:final fields) => fields,
    _ => const [],
  };
}

/// The block sops writes to record its own recipients and MAC.
///
/// Stripped by `sops -d`, so it is only seen when reading a file that has not
/// been decrypted — and only ever at the top level. A `sops` key anywhere else
/// is an unknown key and stays fatal.
const _sopsMetadataKey = 'sops';

/// Every credential in [document], or an error naming the path of the first
/// thing that is not one.
///
/// **This is the only reader.** `secrets keys` calls it and ignores the values;
/// the parser calls it and keeps them. Recognition is reaching a leaf without an
/// error, so there is nowhere for a second opinion about what counts as
/// recognized to live.
({List<_Credential> credentials, List<String> problems}) _walk(
  YamlMap document,
  String path,
) {
  final found = <_Credential>[];
  final problems = <String>[];
  _descend(_schema, document, '', path, found, problems);
  found.sort((a, b) => a.path.compareTo(b.path));
  return (credentials: found, problems: problems);
}

void _descend(
  _Node node,
  YamlMap map,
  String at,
  String path,
  List<_Credential> found,
  List<String> problems,
) {
  final where = at.isEmpty ? '' : '$at.';
  switch (node) {
    case _Section(:final children):
      for (final entry in map.entries) {
        final key = '${entry.key}';
        // Only at the top level, and only this one name.
        if (at.isEmpty && key == _sopsMetadataKey) {
          continue;
        }
        final child = children[key];
        if (child == null) {
          problems.add(
            '$where$key is not something this understands — known here: '
            '${(children.keys.toList()..sort()).join(', ')}',
          );
          continue;
        }
        final value = entry.value;
        if (value is! YamlMap) {
          problems.add(
            '$where$key must be a mapping, and is a ${value.runtimeType}',
          );
          continue;
        }
        _descend(child, value, '$where$key', path, found, problems);
      }

    case _Family(:final what, :final fields, :final instances):
      for (final entry in map.entries) {
        final instance = '${entry.key}';
        if (instances != null && !instances.contains(instance)) {
          problems.add(
            '$where$instance is not one of the kinds there are — known here: '
            '${(instances.toList()..sort()).join(', ')}',
          );
          continue;
        }
        if (!_instanceName.hasMatch(instance)) {
          problems.add(
            '$where$instance is not a usable name — it becomes a filename, so '
            'it must be lowercase letters, digits and underscores, starting '
            'with a letter',
          );
          continue;
        }
        final value = entry.value;
        if (value is! YamlMap) {
          problems.add(
            '$where$instance must be a mapping of '
            '${fields.map((f) => f.name).join(', ')}, and is a '
            '${value.runtimeType}',
          );
          continue;
        }
        found.add(
          _Credential(
            path: '$where$instance',
            what: what,
            instance: instance,
            fields: _leaves(value, fields, '$where$instance', problems),
          ),
        );
      }

    case _Singleton(:final what, :final fields):
      found.add(
        _Credential(
          path: at,
          what: what,
          instance: '',
          fields: _leaves(map, fields, at, problems),
        ),
      );
  }
}

/// The declared fields of one credential, refusing anything else.
Map<String, String> _leaves(
  YamlMap map,
  List<_Field> fields,
  String at,
  List<String> problems,
) {
  final known = {for (final f in fields) f.name};
  final values = <String, String>{};
  for (final entry in map.entries) {
    final key = '${entry.key}';
    if (!known.contains(key)) {
      problems.add(
        '$at.$key is not a field of this credential — known here: '
        '${(known.toList()..sort()).join(', ')}',
      );
      continue;
    }
    final value = entry.value;
    if (value is YamlMap || value is YamlList) {
      problems.add('$at.$key must be a value, and is a ${value.runtimeType}');
      continue;
    }
    if (value == null) {
      continue;
    }
    // Scalars are stringified rather than type-checked: a key alias that is all
    // digits parses as an int, and refusing it would be pedantry.
    values[key] = '$value';

    // A field this has to read without an identity, that sops encrypted anyway.
    // The dependency on `.sops.yaml` is only tolerable if getting it wrong is
    // loud: silently, `secrets keys` would report a path of `ENC[...]` and the
    // pre-flight would check a path nothing will ever write to.
    if (_cleartextFields.contains(key) && values[key]!.startsWith('ENC[')) {
      problems.add(
        '$at.$key is encrypted, and has to be readable without a key — add '
        "unencrypted_regex: '^(${_cleartextFields.join('|')})\$' to "
        '.sops.yaml and re-encrypt',
      );
    }
  }
  return values;
}

/// One credential found in a secrets file: where it is, and what it holds.
///
/// Per credential rather than per value, because the credential is the unit
/// that is complete or not — a keystore missing its password is one broken
/// thing, not three fine values and one absent one.
typedef SecretKey = ({
  String path,
  String what,
  List<String> fields,
  List<String> missing,
});

/// What is wrong with a secrets file, if anything.
///
/// Separate from the credentials rather than thrown, so one run reports
/// everything wrong at once — a file with three typos should not need three
/// attempts to fix.
typedef SecretsReport = ({List<SecretKey> credentials, List<String> problems});

/// The credential names in [secretsFile], **without decrypting it**.
///
/// A sops-encrypted file keeps its keys in cleartext and encrypts only the
/// values, so the shape of one can be read with no identity and no risk of a
/// secret reaching a terminal — which makes this the check to run *before*
/// adopting a new version, since an unrecognized key stops `secrets exec` dead.
///
/// **It calls [_walk], the same and only reader the parser calls**, which is the
/// only reason it can be trusted: a pre-flight that approximates the real rules
/// is a pre-flight that eventually disagrees with them. Sharing a *walker* was
/// not enough the last time — "is this recognized" was computed in a second
/// place, and the two answers drifted while a test that compared one to itself
/// stayed green. Here recognition is reaching a leaf without a problem, so
/// there is no second answer to hold.
///
/// It also replaced a `grep` recommended in the skill, whose character class
/// omitted digits and so hid every name carrying actual key material —
/// reporting the few that mattered least and reading as a clean bill of health.
///
/// Completeness is reported too, and can be: a missing field is a missing
/// *name*, so half-configuration is now visible from the encrypted file rather
/// than only after decryption.
SecretsReport inspectSecretKeys(File secretsFile) {
  if (!secretsFile.existsSync()) {
    throw ProjectException('no ${secretsFile.path}');
  }
  final dynamic document;
  try {
    document = loadYaml(secretsFile.readAsStringSync());
  } on YamlException catch (e) {
    // `e.message` for the same reason as the decrypting parser below, even
    // though this one reads the *encrypted* file and would normally echo
    // nothing but ciphertext. The case it covers is a file that has been
    // written and not yet encrypted — checking its shape before running `sops
    // -e` is exactly what somebody would do — where the source line a parse
    // error quotes is plaintext.
    throw ProjectException(
      '${secretsFile.path} is not valid YAML: ${e.message}',
    );
  }
  if (document is! YamlMap) {
    throw ProjectException(
      '${secretsFile.path} must be a mapping of credentials',
    );
  }

  final walked = _walk(document, secretsFile.path);
  return (
    credentials: [
      for (final credential in walked.credentials)
        (
          path: credential.path,
          what: credential.what,
          fields: credential.fields.keys.toList()..sort(),
          missing: credential.missing,
        ),
    ],
    problems: walked.problems,
  );
}

/// Every credential this understands, as paths, sorted.
///
/// Describes the schema rather than a list kept beside it, so it cannot fall
/// behind what is actually accepted.
List<String> knownSecretKeys() {
  final paths = <String>[];
  void walk(_Node node, String at) {
    final where = at.isEmpty ? '' : '$at.';
    switch (node) {
      case _Section(:final children):
        for (final entry in children.entries) {
          walk(entry.value, '$where${entry.key}');
        }
      case _Family(:final fields):
        paths.add('$at.<name>.{${fields.map((f) => f.name).join(', ')}}');
      case _Singleton(:final fields):
        paths.add('$at.{${fields.map((f) => f.name).join(', ')}}');
    }
  }

  walk(_schema, '');
  return paths..sort();
}

/// What was decrypted, and where the files it had to write went.
class LoadedSecrets {
  LoadedSecrets(
    this.environment,
    this.loaded,
    this._work, {
    this.placed = const [],
    this.unresolved = const [],
  });

  /// The child's environment: this process's, plus the credentials.
  final Map<String, String> environment;

  /// The groups that were present, for reporting. Naming what was loaded
  /// rather than what was asked for is what makes a credential that silently
  /// did not arrive visible instead of inferred.
  final List<String> loaded;

  /// Credentials this deliberately did **not** write.
  ///
  /// `exec` names them and carries on. A command that needs none of them is
  /// legitimate — promoting a build has no business failing because a Dart
  /// source file is not on disk — but a family that could be silently absent
  /// is exactly the defect this file has already had once.
  final List<String> placed;

  /// Families this deliberately did not choose between, because the caller said
  /// it does not read them.
  ///
  /// Reported for the same reason [placed] is: the alternative to naming it is
  /// a credential that is absent for a good reason being indistinguishable from
  /// one that is absent for a bad one.
  final List<String> unresolved;

  final Directory _work;

  void dispose() {
    if (_work.existsSync()) {
      _work.deleteSync(recursive: true);
    }
  }
}

/// Locates the `sops` binary: the project's `.bin` first, then PATH.
String findSops(String repoRoot) {
  final local = File('$repoRoot/.bin/sops');
  if (local.existsSync()) {
    return local.path;
  }
  final which = Process.runSync('sh', ['-c', 'command -v sops']);
  final found = (which.stdout as String).trim();
  if (which.exitCode == 0 && found.isNotEmpty) {
    return found;
  }
  throw ProjectException(
    'sops not found — run `cux_ship deps install`, or put sops on PATH',
  );
}

/// Decrypts [secretsFile] and returns the environment a child should get.
///
/// Nothing is written outside the temp directory held by the result, and the
/// caller must [LoadedSecrets.dispose] it.
/// The credentials in [secretsFile], decrypted.
///
/// Split out so `place` and `clean` can read the file without materializing
/// anything: they write into the working tree rather than a temp directory, and
/// have no business creating one.
List<_Credential> _decrypt({
  required String repoRoot,
  required File secretsFile,
}) {
  if (!secretsFile.existsSync()) {
    throw ProjectException('no ${secretsFile.path}');
  }

  // The *encrypted* file, before anything decrypts it. After `sops -d` a `path`
  // that sops encrypted is indistinguishable from one it left alone, so this is
  // the only moment the difference is visible — and without it only `secrets
  // keys` would notice, while exec, place and clean carried on. That would
  // quietly cost the property the cleartext fields exist for: that the
  // pre-flight works with no identity, on any platform. A file readable only by
  // someone holding a key has already lost it.
  final shape = inspectSecretKeys(secretsFile);
  if (shape.problems.isNotEmpty) {
    throw ProjectException(
      '${secretsFile.path} does not describe credentials this understands:\n'
      '${shape.problems.map((p) => '    $p').join('\n')}',
    );
  }

  final sops = findSops(repoRoot);

  // sops looks for an identity in SOPS_AGE_KEY, SOPS_AGE_KEY_FILE and a
  // platform-specific default that is ~/Library/Application Support/sops/age on
  // macOS. Pointing at the XDG path explicitly keeps one location working on
  // both, and leaves an already-set variable — which is how CI supplies it —
  // alone.
  final sopsEnvironment = <String, String>{};
  final home = Platform.environment['HOME'];
  if (Platform.environment['SOPS_AGE_KEY'] == null &&
      Platform.environment['SOPS_AGE_KEY_FILE'] == null &&
      home != null) {
    final identity = File('$home/.config/sops/age/keys.txt');
    if (identity.existsSync()) {
      sopsEnvironment['SOPS_AGE_KEY_FILE'] = identity.path;
    }
  }

  final result = Process.runSync(sops, [
    '-d',
    secretsFile.path,
  ], environment: sopsEnvironment);
  if (result.exitCode != 0) {
    throw ProjectException(
      'could not decrypt ${secretsFile.path} — no usable age identity.\n'
      '    Locally:  ~/.config/sops/age/keys.txt\n'
      '    In CI:    set SOPS_AGE_KEY to the private key',
    );
  }

  return _parse(result.stdout as String, secretsFile.path);
}

/// Decrypts, materializes, and hands back the environment a child should see.
/// The variables each withholdable family sets, so a caller can *remove* them
/// as well as decline to add them.
///
/// **Declining to add is not enough on its own, and the difference is subtle
/// enough to have nearly shipped.** `secrets exec -- keychain exec -- build`
/// is a documented composition, and in it the outer command has already put
/// every credential in the environment before the inner one runs. The inner
/// withholding then achieves exactly nothing while looking correct at every
/// line — the build inherits the key regardless.
///
/// So withholding a family means the variables are absent from the child's
/// environment however they got there, not merely that this process declined
/// to set them.
const familyVariables = {
  'android.keystores': {
    'ANDROID_KEYSTORE_PATH',
    'ANDROID_KEYSTORE_PASSWORD',
    'ANDROID_KEY_ALIAS',
    'ANDROID_KEY_PASSWORD',
  },
  'android.play_service_account': {'GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH'},
  'apple.api_keys': {
    'APPLE_API_KEY_ID',
    'APPLE_API_PRIVATE_KEY_PATH',
    'APPLE_API_ISSUER_ID',
    'API_PRIVATE_KEYS_DIR',
  },
};

/// Credential families a caller may declare it does not consume.
///
/// Enumerated so a typo in [loadSecrets]'s `withhold` is refused rather than
/// silently withholding nothing.
final withholdableFamilies = familyVariables.keys.toSet();

/// [withhold] is what a caller that knows its child's platform turns off.
///
/// Ambiguity is normally fatal here, and rightly: `secrets exec` hands the
/// environment to a child it knows nothing about, so it cannot tell whether the
/// keystore it failed to pick was needed, and a keystore that silently does not
/// arrive makes Gradle fall through to the debug key and produces an artifact
/// only Play rejects.
///
/// That reasoning does not survive the caller being `keychain exec`, which is
/// macOS-gated and signs Apple builds. There the child provably never reads
/// `ANDROID_KEYSTORE_*`, and refusing to start because the file holds two
/// Android keystores locks a project out of a command that does not touch them
/// — which is what happened to the first consumer, on the first run.
///
/// So the choice is the caller's, and stays fatal by default.
LoadedSecrets loadSecrets({
  required String repoRoot,
  required File secretsFile,
  String? keystore,
  String? apiKey,
  Set<String> withhold = const {},
}) {
  // A name that withholds nothing because it is misspelled would put a
  // credential in the environment that the caller believes it excluded — and
  // for `android.play_service_account` that credential is a private key. So an
  // unknown name is refused rather than ignored.
  final unknown = withhold.difference(withholdableFamilies);
  if (unknown.isNotEmpty) {
    throw ProjectException(
      'cannot withhold ${unknown.join(', ')} — no such credential family.\n'
      '    there is: ${(withholdableFamilies.toList()..sort()).join(', ')}',
    );
  }
  final values = _decrypt(repoRoot: repoRoot, secretsFile: secretsFile);

  // 0700 by construction — createTempSync uses mkdtemp. The files below are
  // narrowed explicitly anyway, because they inherit this process's umask
  // rather than the directory's mode.
  final work = Directory.systemTemp.createTempSync('cux_ship_secrets');
  try {
    return _materialize(
      values,
      work,
      keystore: keystore,
      apiKey: apiKey,
      withhold: withhold,
    );
  } on Object {
    work.deleteSync(recursive: true);
    rethrow;
  }
}

/// Re-encrypts the working copy of a placed file back into the secrets file.
///
/// The other half of [place], and the reason a placed credential can be edited
/// at all: these are working source, so somebody changes `lib/env/secrets.dart`
/// in an editor and the encrypted copy has to be able to catch up. Without this
/// an edit lives only in the working tree, and `place` refusing to overwrite it
/// is the only thing standing between that and losing it.
///
/// Delegated to `sops set` rather than a decrypt-and-re-encrypt round trip:
/// only the one value is rewritten, the recipients and the rest of the file are
/// sops' business, and the new value goes over **stdin** so a private key never
/// appears in a process listing.
Future<PackResult> packPlaced({
  required String repoRoot,
  required File secretsFile,
  required PlacedFile file,
}) async {
  final target = File('$repoRoot/${file.path}');
  if (!target.existsSync()) {
    return PackResult.absent;
  }
  if (file.outcomeIn(repoRoot) == PlaceOutcome.matching) {
    return PackResult.unchanged;
  }

  final sops = findSops(repoRoot);
  final instance = file.at.split('.').last;
  final process = await Process.start(sops, [
    'set',
    secretsFile.path,
    '["placed"]["$instance"]["base64"]',
    '--value-stdin',
  ]);
  process.stdin.write(jsonEncode(base64.encode(target.readAsBytesSync())));
  await process.stdin.close();
  final code = await process.exitCode;
  if (code != 0) {
    throw ProjectException(
      'could not write ${file.path} back into ${secretsFile.path} — '
      'sops set exited $code',
    );
  }
  return PackResult.packed;
}

/// What [packPlaced] did.
enum PackResult {
  /// Nothing in the working tree to pack.
  absent,

  /// The working copy already matches what is encrypted.
  unchanged,

  /// The encrypted copy now matches the working copy.
  packed,
}

/// The files this repository expects in its working tree, decrypted.
///
/// Nothing is written and no temp directory is created — deciding what to do
/// with them is [place] and [clean]'s business, and both refuse before writing.
List<PlacedFile> placedFiles({
  required String repoRoot,
  required File secretsFile,
}) => [
  for (final credential in _decrypt(
    repoRoot: repoRoot,
    secretsFile: secretsFile,
  ))
    if (credential.path.startsWith('placed.'))
      PlacedFile(
        at: credential.path,
        path: credential.fields['path']!,
        content: _decode(
          credential.fields['base64']!,
          '${credential.path}.base64',
        ),
      ),
];

List<_Credential> _parse(String plaintext, String path) {
  final dynamic document;
  try {
    document = loadYaml(plaintext);
  } on YamlException catch (e) {
    // `e.message` and not `$e`. A YamlException stringifies with the offending
    // source line and a caret under it — and what this parses is the
    // *decrypted* document, so the whole exception puts key material on stderr
    // and into whatever log is capturing it. The bare reason says as much about
    // what to fix and discloses nothing.
    throw ProjectException('$path did not decrypt to valid YAML: ${e.message}');
  }
  if (document is! YamlMap) {
    throw ProjectException('$path must be a mapping of credentials');
  }

  final walked = _walk(document, path);

  // Everything wrong at once. A file with three typos should take one attempt
  // to fix, not three — and an unrecognized name is a typo whose consequence is
  // silent: the credential never arrives, the build falls back to a debug key
  // or an anonymous API call, and the failure surfaces at the store.
  if (walked.problems.isNotEmpty) {
    throw ProjectException(
      '$path does not describe credentials this understands:\n'
      '${walked.problems.map((p) => '    $p').join('\n')}',
    );
  }

  // Half-configured is the dangerous state, so it is refused here rather than
  // discovered downstream — per credential, because that is the unit that is
  // complete or not.
  for (final credential in walked.credentials) {
    if (credential.isComplete) {
      continue;
    }
    throw ProjectException(
      '$path: ${credential.path} is half configured — '
      '${credential.missing.join(', ')} '
      '${credential.missing.length == 1 ? 'is' : 'are'} missing.\n'
      'Set all of a credential or none of it: a partial set fails at the '
      'store rather than here.',
    );
  }

  return walked.credentials;
}

/// Turns credentials into the environment a child sees.
///
/// **Every family's materializer is reached from the same list the parser
/// validated**, so a credential cannot be checked by one and forgotten by the
/// other. The previous shape asked `values.containsKey('keystore_base64')` and
/// so looked straight past any credential with a name — which validated,
/// reported nothing amiss, and set no variables at all.
LoadedSecrets _materialize(
  List<_Credential> credentials,
  Directory work, {
  String? keystore,
  String? apiKey,
  Set<String> withhold = const {},
}) {
  final environment = Map<String, String>.from(Platform.environment);
  final loaded = <String>[];
  final unresolved = <String>[];

  Iterable<_Credential> under(String family) =>
      credentials.where((c) => c.path.startsWith('$family.'));

  /// Whether [family] was withheld, recording why for the caller to print.
  bool held(String family, String because) {
    if (!withhold.contains(family)) {
      return false;
    }
    final held = credentials
        .where((c) => c.path == family || c.path.startsWith('$family.'))
        .toList();
    if (held.isEmpty) {
      return true;
    }
    // The parenthetical names *which* instances were skipped, so it earns its
    // place for a family that has them and reads as a stutter for a singleton
    // that does not — `android.play_service_account (android.play_service_account)`.
    final names = held.map((c) => c.instance).where((i) => i.isNotEmpty);
    final which = names.isEmpty ? '' : ' (${names.join(', ')})';
    // Named rather than skipped quietly. The caller says it does not need this,
    // and it is still the case that a credential which did not arrive has to be
    // visible rather than inferred from a failure three minutes later.
    unresolved.add('$family$which — $because');
    return true;
  }

  // --- Android ---------------------------------------------------------------

  // One keystore fills the fixed names every consumer already reads. Instance
  // names never become variable names: uppercasing is not injective, so `dist`
  // and `dist_p12` would mint the same variable and one would silently win.
  final keystores =
      held('android.keystores', 'this command does not sign Android artifacts')
      ? const <_Credential>[]
      : _select(
          under('android.keystores').toList(),
          keystore,
          'keystore',
          'signs',
        );
  if (keystores.length == 1) {
    final keystore = keystores.single;
    final file = _writeBase64(
      work,
      '${keystore.instance}.p12',
      keystore.fields['base64']!,
      '${keystore.path}.base64',
    );
    environment['ANDROID_KEYSTORE_PATH'] = file.path;
    environment['ANDROID_KEYSTORE_PASSWORD'] = keystore.fields['password']!;
    environment['ANDROID_KEY_ALIAS'] = keystore.fields['key_alias']!;
    environment['ANDROID_KEY_PASSWORD'] =
        keystore.fields['key_password'] ?? keystore.fields['password']!;
    loaded.add(keystore.path);
  }

  // **The only credential here passed by value rather than by path, and that
  // makes it the only one that can escape through a log.**
  //
  // Everything else is a filename in a temp directory that no longer exists by
  // the time anyone reads the output — `ANDROID_KEYSTORE_PATH`,
  // `APPLE_*_P12_PATH`, `APPLE_PROFILE_*_PATH`. This one is the private key
  // itself. An Xcode script build phase writes its entire environment into the
  // build log, so an Apple build carrying this variable prints a Google private
  // key into a file people paste around — and into public CI logs, which is
  // where it was found.
  //
  // Written to a file, like every other credential, and exported as a path.
  //
  // It used to be exported by value, and that is how a Google private key
  // reached four public CI logs: an xcode script phase echoes its whole
  // environment into the build log, and a variable holding a key therefore
  // prints the key. A variable holding a *filename* prints a filename, in a
  // temp directory this process removes on the way out.
  //
  // That is the whole reason for the major version. Withholding, which 1.9.x
  // added, only ever mitigated it — each layer can speak for its own child and
  // no further, so an inner `secrets exec` reintroduced the value for its own
  // subtree. A path cannot be reintroduced in a form that matters.
  if (!held(
    'android.play_service_account',
    'this command does not publish to Play',
  )) {
    for (final account in credentials.where(
      (c) => c.path == 'android.play_service_account',
    )) {
      final file = _writeBase64(
        work,
        'play_service_account.json',
        account.fields['json_base64']!,
        '${account.path}.json_base64',
      );
      environment['GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH'] = file.path;
      loaded.add(account.path);
    }
  }

  // --- Apple -----------------------------------------------------------------

  // Every key goes into one directory, because altool finds a key by its id
  // inside $API_PRIVATE_KEYS_DIR rather than by a path. The selected one also
  // fills the singular names, for xcodebuild and for AscCredentials.
  // **Not placed unless asked for, when the caller says so** — and the reason
  // is a real asymmetry with the keystore above rather than a second helping of
  // the same argument.
  //
  // A keystore that fails to arrive is *silent*: Gradle falls through to the
  // debug signing config and produces an artifact only Play rejects, minutes
  // after a full upload. Refusing up front is worth it. An App Store key that
  // fails to arrive is *loud*: every consumer of one opens with
  // `: "${APPLE_API_KEY_ID:?…}"` or equivalent and dies on its first line
  // naming the cause. So being fatal buys something there and nothing here.
  //
  // And it costs something. A build script can deliberately hold no App Store
  // credential — which is what lets CI sign without holding anything able to
  // create or revoke signing material — and forcing a key into that step to get
  // a keychain gives away exactly the property it was built for.
  final apiKeys = under('apple.api_keys').toList();
  final withheldKeys =
      apiKey == null &&
      held(
        'apple.api_keys',
        'none named, so no App Store credential is placed in the environment',
      );
  if (apiKeys.isNotEmpty && !withheldKeys) {
    final keys = Directory('${work.path}/private_keys')..createSync();
    for (final key in apiKeys) {
      _writeBase64(
        keys,
        _apiKeyFileName(key.fields['kind']!, key.fields['id']!, key.path),
        key.fields['private_key_base64']!,
        '${key.path}.private_key_base64',
      );
      loaded.add(key.path);
    }
    environment['API_PRIVATE_KEYS_DIR'] = keys.path;

    final key = _select(apiKeys, apiKey, 'api-key', 'is used').single;
    environment['APPLE_API_KEY_ID'] = key.fields['id']!;
    environment['APPLE_API_PRIVATE_KEY_PATH'] =
        '${keys.path}/'
        '${_apiKeyFileName(key.fields['kind']!, key.fields['id']!, key.path)}';
    final issuer = key.fields['issuer_id'];
    if (issuer != null) {
      environment['APPLE_API_ISSUER_ID'] = issuer;
    }
  }

  // All of them, not one: a release run legitimately signs with the App Store
  // certificate, notarizes with Developer ID and signs a .pkg with the
  // installer certificate. The names are a closed set, so they are enumerable
  // and collision-free by construction rather than by rule.
  for (final certificate in under('apple.certificates')) {
    final file = _writeBase64(
      work,
      '${certificate.instance}.p12',
      certificate.fields['p12_base64']!,
      '${certificate.path}.p12_base64',
    );
    final prefix = 'APPLE_${certificate.instance.toUpperCase()}_P12';
    environment['${prefix}_PATH'] = file.path;
    environment['${prefix}_PASSWORD'] = certificate.fields['password']!;
    loaded.add(certificate.path);
  }

  for (final profile in under('apple.profiles')) {
    // Extension deliberately not derived from the name: a macOS profile is a
    // .provisionprofile and an iOS one a .mobileprovision, and Xcode will not
    // match one filed under the other. Reading which it is needs `security cms`
    // and therefore a Mac, so installation is a separate, platform-gated step —
    // this only puts the bytes somewhere it can find them.
    final file = _writeBase64(
      work,
      '${profile.instance}.profile',
      profile.fields['base64']!,
      '${profile.path}.base64',
    );
    environment['APPLE_PROFILE_${profile.instance.toUpperCase()}_PATH'] =
        file.path;
    loaded.add(profile.path);
  }

  // --- The project's own -----------------------------------------------------

  // Declared rather than minted, so nothing invents a variable name from an
  // instance name, and a name this tool already exports cannot be quietly
  // overwritten by a token that happens to share it.
  for (final token in under('tokens')) {
    final name = token.fields['env']!;
    _checkExportable(name, token.path, environment);
    environment[name] = token.fields['value']!;
    loaded.add(token.path);
  }

  for (final key in under('ssh_keys')) {
    final name = key.fields['env']!;
    _checkExportable(name, key.path, environment);
    final file = _writeBase64(
      work,
      '${key.instance}.key',
      key.fields['base64']!,
      '${key.path}.base64',
    );
    environment[name] = file.path;
    loaded.add(key.path);
  }

  // **Removed, not merely not-added** — and this is the half that is easy to
  // leave out. The environment above starts as a copy of this process's own, so
  // under `secrets exec -- keychain exec -- build` every credential is already
  // present before the inner command decides to withhold anything. Declining to
  // set a variable that is already set achieves nothing while reading as
  // correct.
  for (final family in withhold) {
    for (final name in familyVariables[family]!) {
      environment.remove(name);
    }
  }

  // Named, not written. `secrets place` writes these; exec promises that
  // plaintext does not outlive the run, and these outlive it by design.
  final placed = [for (final file in under('placed')) file.path];

  return LoadedSecrets(
    environment,
    loaded,
    work,
    placed: placed,
    unresolved: unresolved,
  );
}

/// The one instance to use, or an error naming the alternatives.
///
/// Exactly one is the default because that is the case that cannot be wrong.
/// Two or more is a choice, and a tool that picks for you picks silently — so
/// it refuses and lists them. A name that is not there is an error too, rather
/// than a fall back to the default: falling back would run an Admin-gated read
/// with a scoped key and surface as a bare 403 from Apple.
List<_Credential> _select(
  List<_Credential> available,
  String? chosen,
  String flag,
  String verb,
) {
  if (chosen != null) {
    final match = available.where((c) => c.instance == chosen);
    if (match.isEmpty) {
      throw ProjectException(
        'there is no $chosen in this file.\n'
        '    it holds: ${available.map((c) => c.instance).join(', ')}',
      );
    }
    return [match.single];
  }
  if (available.length > 1) {
    throw ProjectException(
      'this file holds ${available.length} of these — '
      '${available.map((c) => c.instance).join(', ')} — so which one $verb is '
      'not something to infer.\n'
      'Name it: --$flag <name>',
    );
  }
  return available;
}

/// Refuses a declared variable name that is malformed, or that would overwrite
/// something this tool exports.
///
/// A token quietly taking `ANDROID_KEYSTORE_PATH` would redirect a real
/// credential, and the file's own author would be unlikely to notice.
void _checkExportable(String name, String at, Map<String, String> environment) {
  if (!RegExp(r'^[A-Z][A-Z0-9_]*$').hasMatch(name)) {
    throw ProjectException(
      '$at.env is $name, which is not a usable variable name — '
      'capitals, digits and underscores, starting with a letter',
    );
  }
  if (_reservedNames.contains(name)) {
    throw ProjectException(
      '$at.env is $name, which is a name this tool sets itself — '
      'a credential would be overwritten and nothing would say so',
    );
  }
}

/// The names materialization sets, so a token cannot quietly take one.
///
/// Derived from [familyVariables] rather than listed beside it. The two were
/// the same nine names written twice, and the failure mode of letting them
/// drift is silent in both directions: a name missing here lets a token
/// overwrite a real credential, and one missing there leaves a secret in a
/// child's environment that the caller believes it withheld.
final _reservedNames = {for (final names in familyVariables.values) ...names};

/// What Apple named the key, derived from what kind it is.
///
/// Not stored: the filename carries exactly the id and the kind, and both are
/// declared fields, so a stored name is a third copy that can disagree with the
/// other two. altool and this tool's JWT builder both read the prefix to decide
/// which claims to send, which is why getting it wrong is a bare 401 after a
/// full build rather than a parse error.
String _apiKeyFileName(String kind, String keyId, String at) => switch (kind) {
  'individual' => 'ApiKey_$keyId.p8',
  'team' => 'AuthKey_$keyId.p8',
  _ => throw ProjectException(
    '$at.kind is $kind — it must be team or individual, and it decides '
    'which claims Apple is sent',
  ),
};

List<int> _decode(String value, String key) {
  try {
    return base64.decode(value.trim());
  } on FormatException {
    throw ProjectException('$key is not valid base64');
  }
}

File _writeBase64(Directory dir, String name, String value, String key) {
  final bytes = _decode(value, key);
  if (bytes.isEmpty) {
    throw ProjectException('$key decodes to nothing');
  }
  final file = File('${dir.path}/$name')..writeAsBytesSync(bytes);
  // Explicit rather than trusting the umask: this is a private key, and the
  // directory being 0700 is only half of it on a machine whose umask is 022.
  Process.runSync('chmod', ['600', file.path]);
  return file;
}

/// Runs [command] with the credentials from [secretsFile] in its environment,
/// and returns its exit code.
///
/// The child runs with the **repository root** as its working directory, the
/// same frame of reference the rest of the tool uses — `cux_ship` is normally
/// invoked from `tool/cux_ship`, and a command like `tool/build.sh android`
/// would not resolve from there.
Future<int> runSecretsExec({
  required String repoRoot,
  required File secretsFile,
  required List<String> command,
  String? keystore,
  String? apiKey,
}) async {
  if (command.isEmpty) {
    throw ProjectException(
      'nothing to run — put the command after `--`, as in\n'
      '    cux_ship secrets exec -- tool/build.sh --release android',
    );
  }

  final secrets = loadSecrets(
    repoRoot: repoRoot,
    secretsFile: secretsFile,
    keystore: keystore,
    apiKey: apiKey,
  );
  try {
    // To stderr, so `cux_ship secrets exec -- env | grep …` pipes the child's
    // output and not this. What was *loaded* rather than what was asked for:
    // a credential that silently did not arrive has to be visible here rather
    // than inferred from a failure three minutes later.
    stderr.writeln(
      '==> loaded ${secrets.loaded.isEmpty ? 'nothing' : secrets.loaded.join(', ')}',
    );
    // Named, not written, and not an error either: a command that needs none of
    // them is legitimate — promoting a build has no business failing because a
    // Dart source file is not on disk. But a family that could be silently
    // absent is exactly the defect this file has already had once, so it says
    // so rather than leaving it to be discovered as a missing import.
    if (secrets.placed.isNotEmpty) {
      stderr.writeln(
        '==> not written by exec: ${secrets.placed.join(', ')}'
        ' — cux_ship secrets place',
      );
    }
    stderr.writeln('==> running ${command.join(' ')} in $repoRoot');

    final process = await Process.start(
      command.first,
      command.skip(1).toList(),
      environment: secrets.environment,
      workingDirectory: repoRoot,
      mode: ProcessStartMode.inheritStdio,
    );

    // Watched so the VM does not die on Ctrl-C without cleaning up — the
    // default behavior terminates immediately and would leave a decrypted
    // private key in the temp directory. The signal is forwarded rather than
    // acted on here, so the child gets to exit and the ordinary path below
    // does the removal.
    final signals = [
      ProcessSignal.sigint.watch().listen((s) => process.kill(s)),
      ProcessSignal.sigterm.watch().listen((s) => process.kill(s)),
    ];
    try {
      return await process.exitCode;
    } finally {
      for (final subscription in signals) {
        await subscription.cancel();
      }
    }
  } finally {
    // Not `exec`, and this is why: replacing this process would mean nothing
    // ever ran the cleanup, leaving a decrypted private key behind on every
    // invocation.
    secrets.dispose();
  }
}
