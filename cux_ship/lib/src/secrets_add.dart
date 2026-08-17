// SPDX-License-Identifier: Apache-2.0
//
// Putting a credential *into* the secrets file.
//
// Everything else in `secrets` reads or materializes; `pack` is the one write,
// and it only ever updates a `placed` file that `place` wrote first. So adding
// a certificate, a profile or a token meant a hand-written pipeline —
//
//   ruby -rjson -rbase64 -e 'print JSON.generate(Base64.strict_encode64(...))' p.mobileprovision \
//     | sops set --value-stdin secrets/release.yaml '["apple"]["profiles"]["ios_appstore"]["base64"]'
//
// — which nobody remembers, which encodes the schema path by hand, and which
// writes one field at a time so an interrupted run leaves a half-credential.
//
// The rule here is that **a human names a file and an instance, and the tool
// works out the rest**: the schema path, the base64, the JSON quoting, and
// every field that can be read back out of the artifact itself.
part of 'secrets.dart';

/// What a file actually is, as opposed to what it is called.
///
/// Identified by content rather than by extension, which buys two things. The
/// error names the real mistake — "this is a PEM private key, not a PKCS#12
/// bundle; did you mean `add api-key`" rather than "wrong flag" — and it
/// catches the case an extension cannot, a correctly named file with the wrong
/// thing inside. That happens, because people rename downloads.
enum ArtifactKind {
  pkcs12('a PKCS#12 bundle'),
  pemPrivateKey('a PEM private key'),
  opensshKey('an OpenSSH private key'),
  provisioningProfile('a provisioning profile'),
  json('a JSON document'),
  javaKeystore('a Java keystore'),
  unknown('not something this recognizes');

  const ArtifactKind(this.what);

  final String what;
}

/// Which of [ArtifactKind] these bytes are.
///
/// Deliberately structural. A `.mobileprovision` and a `.p12` are both DER
/// SEQUENCEs and cannot be told apart by their first bytes — but a provisioning
/// profile is CMS *signed* data wrapping a plaintext plist, so the XML is
/// sitting there in the clear, while a p12 is encrypted through and through.
/// That is the discriminator, and it is a fact about the formats rather than a
/// heuristic about these files.
ArtifactKind identifyArtifact(List<int> bytes) {
  if (bytes.isEmpty) {
    return ArtifactKind.unknown;
  }
  // JKS and JCEKS carry magic numbers. Checked before anything else because
  // they are unambiguous and a keystore is otherwise easy to mistake for a
  // generic binary.
  if (_startsWith(bytes, [0xFE, 0xED, 0xFE, 0xED]) ||
      _startsWith(bytes, [0xCE, 0xCE, 0xCE, 0xCE])) {
    return ArtifactKind.javaKeystore;
  }

  final head = String.fromCharCodes(
    bytes.take(120).where((b) => b >= 0x09 && b < 0x80),
  );
  if (head.contains('-----BEGIN OPENSSH PRIVATE KEY-----')) {
    return ArtifactKind.opensshKey;
  }
  if (head.contains('-----BEGIN') && head.contains('PRIVATE KEY-----')) {
    return ArtifactKind.pemPrivateKey;
  }

  final trimmed = head.trimLeft();
  if (trimmed.startsWith('{')) {
    return ArtifactKind.json;
  }

  // DER: a SEQUENCE with a long-form length, which is every real p12 and every
  // real profile.
  if (bytes[0] == 0x30) {
    // A profile's plist is not encrypted, so it is findable as plain bytes. A
    // p12 has no plaintext beyond its structure.
    if (_containsAscii(bytes, '<?xml') || _containsAscii(bytes, '<plist')) {
      return ArtifactKind.provisioningProfile;
    }
    return ArtifactKind.pkcs12;
  }

  // PKCS#12 written by some tools starts with a zip-like container; and a JKS
  // that is really a PKCS12 (the modern default) lands in the branch above.
  return ArtifactKind.unknown;
}

bool _startsWith(List<int> bytes, List<int> prefix) {
  if (bytes.length < prefix.length) {
    return false;
  }
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) {
      return false;
    }
  }
  return true;
}

bool _containsAscii(List<int> bytes, String needle) {
  final target = needle.codeUnits;
  // Bounded: the plist header sits near the front of a profile, and scanning a
  // whole multi-megabyte p12 for it would cost more than it tells us.
  final limit = bytes.length < 65536 ? bytes.length : 65536;
  outer:
  for (var i = 0; i + target.length <= limit; i++) {
    for (var j = 0; j < target.length; j++) {
      if (bytes[i + j] != target[j]) {
        continue outer;
      }
    }
    return true;
  }
  return false;
}

/// One kind of credential, as `secrets add` accepts it.
class _AddKind {
  const _AddKind({
    required this.noun,
    required this.section,
    required this.family,
    required this.accepts,
    this.singleton = false,
    this.needsEnv = false,
    this.takesFile = true,
  });

  /// What the user types: `certificate`, `profile`, `api-key`.
  final String noun;

  /// Where it lives, as sops path components before the instance name.
  final List<String> section;

  /// The family or singleton key — `certificates`, `profiles`, `tokens`.
  final String family;

  /// Artifact kinds this will accept. Anything else is refused by name.
  final Set<ArtifactKind> accepts;

  /// A singleton has no instance name — there is only ever one.
  final bool singleton;

  /// Needs `--env`, because the variable is declared rather than minted.
  final bool needsEnv;

  /// A token has no file; its value comes from stdin or a prompt.
  final bool takesFile;

  /// Whether this kind needs a password or value typed in.
  ///
  /// A certificate and a keystore carry one that must open them; a token *is*
  /// one. Everything else is fully described by its file.
  bool get needsSecretInput =>
      noun == 'certificate' || noun == 'keystore' || noun == 'token';

  List<String> pathFor(String instance) => [
    ...section,
    family,
    if (!singleton) instance,
  ];
}

const addKinds = <String, _AddKind>{
  'certificate': _AddKind(
    noun: 'certificate',
    section: ['apple'],
    family: 'certificates',
    accepts: {ArtifactKind.pkcs12},
  ),
  'profile': _AddKind(
    noun: 'profile',
    section: ['apple'],
    family: 'profiles',
    accepts: {ArtifactKind.provisioningProfile},
  ),
  'api-key': _AddKind(
    noun: 'api-key',
    section: ['apple'],
    family: 'api_keys',
    accepts: {ArtifactKind.pemPrivateKey},
  ),
  'keystore': _AddKind(
    noun: 'keystore',
    section: ['android'],
    family: 'keystores',
    accepts: {ArtifactKind.pkcs12, ArtifactKind.javaKeystore},
  ),
  'play-account': _AddKind(
    noun: 'play-account',
    section: ['android'],
    family: 'play_service_account',
    accepts: {ArtifactKind.json},
    singleton: true,
  ),
  'token': _AddKind(
    noun: 'token',
    section: [],
    family: 'tokens',
    accepts: {},
    needsEnv: true,
    takesFile: false,
  ),
  'ssh-key': _AddKind(
    noun: 'ssh-key',
    section: [],
    family: 'ssh_keys',
    accepts: {ArtifactKind.opensshKey, ArtifactKind.pemPrivateKey},
    needsEnv: true,
  ),
};

/// The names this family allows, or null when the project chooses them.
///
/// Read out of the schema rather than restated here, so `add` and the reader
/// cannot disagree about what a valid name is — the reader has always refused
/// an unknown one, and a writer with its own opinion would let something in
/// that the reader then rejects for the whole file.
Set<String>? _allowedInstancesFor(_AddKind kind) {
  _Node? node = _schema;
  for (final step in [...kind.section, kind.family]) {
    if (node is _Section) {
      node = node.children[step];
    } else {
      return null;
    }
  }
  return node is _Family ? node.instances : null;
}

/// The kinds `secrets add` accepts, for help text and completion.
List<String> get addKindNames => addKinds.keys.toList()..sort();

/// Whether [kindName] would accept an artifact of [artifact].
///
/// Public because the accept sets are the whole of the content-sniffing
/// contract, and a contract only the implementation can see is one the tests
/// cannot hold it to.
bool addKindAccepts(String kindName, ArtifactKind artifact) =>
    addKinds[kindName]?.accepts.contains(artifact) ?? false;

/// `AuthKey_` is a team key, `ApiKey_` an individual one.
///
/// The filename is the only signal altool gets, and this reads it back out
/// rather than asking — the two fields most often got wrong become two fields
/// nobody types. See `_apiKeyFileName`, which does the same mapping forwards.
({String id, String kind})? apiKeyFactsFromName(String fileName) {
  final match = RegExp(
    r'^(AuthKey|ApiKey)_([A-Za-z0-9]+)\.p8$',
  ).firstMatch(p.basename(fileName));
  if (match == null) {
    return null;
  }
  return (
    id: match.group(2)!,
    kind: match.group(1) == 'AuthKey' ? 'team' : 'individual',
  );
}

/// What [addCredential] did, for the caller to report.
class AddResult {
  const AddResult({
    required this.path,
    required this.fields,
    required this.notes,
    required this.replaced,
    this.staleProfiles = const [],
    this.staleProfilesUnknown = false,
  });

  final String path;

  /// Field names written, in schema order. Never values.
  final List<String> fields;

  /// What was read back out of the artifact — subject, serial, expiry, uuid.
  /// Printed so the operator can see they added what they meant to.
  final List<String> notes;

  final bool replaced;

  /// Profiles that were issued against the certificate this replaced, and are
  /// therefore now unusable. Established before the write, while the outgoing
  /// certificate was still there to fingerprint.
  final List<String> staleProfiles;

  /// True when the pairing could not be established at all — not a Mac, or the
  /// outgoing certificate would not open. Distinct from an empty
  /// [staleProfiles], because "no profiles are affected" and "this could not be
  /// checked" are different claims and only one of them is reassuring.
  final bool staleProfilesUnknown;
}

/// Writes one credential into the secrets file, as a single sops operation.
///
/// **Every field of the instance lands in one `sops set` over the instance
/// map.** Field-at-a-time writing is what makes half-credentials possible, and
/// a half-credential is the dangerous state: a keystore with no password does
/// not fail as "you forgot the password", it falls through to the debug key.
/// The review contact is the same shape — three of four throws and takes every
/// command that loads secrets down with it. Making the partial state
/// unrepresentable is better than reporting it well.
Future<AddResult> addCredential({
  required String repoRoot,
  required File secretsFile,
  required String kindName,
  required String instance,
  String? filePath,
  String? env,
  String? issuerId,
  String? password,
  bool replace = false,
  List<String> Function(String filePath)? describeProfile,
  List<String> Function(String certificatePath)? findStaleProfiles,
}) async {
  final kind = addKinds[kindName];
  if (kind == null) {
    final known = (addKinds.keys.toList()..sort()).join(', ');
    throw ProjectException(
      'no such credential kind: $kindName\n    there is: $known',
    );
  }

  if (!kind.singleton && !_instanceName.hasMatch(instance)) {
    throw ProjectException(
      '$instance is not a usable name — lowercase letters, digits and '
      'underscores, starting with a letter',
    );
  }

  // Some families close the set of names, because the names mean something —
  // Apple has exactly three certificate kinds. The *reader* has always enforced
  // that; this did not, so a mistyped instance was written, and only the
  // read-back noticed. That left an invalid credential in the file, which
  // `secrets exec` then refuses **as a whole** — a per-credential typo taking
  // down every command that loads secrets, which is the same class this command
  // exists to make impossible.
  final allowed = _allowedInstancesFor(kind);
  if (allowed != null && !allowed.contains(instance)) {
    throw ProjectException(
      '$instance is not one of the ${kind.noun} kinds there are.\n'
      '    There is: ${(allowed.toList()..sort()).join(', ')}',
    );
  }
  if (kind.needsEnv) {
    if (env == null || env.isEmpty) {
      throw ProjectException(
        'a ${kind.noun} needs --env, naming the variable it is exported as',
      );
    }
    // Checked here, with the loader's own rule, because otherwise a bad name
    // is accepted now and throws at materialization — and there it takes down
    // *every* command that loads secrets, not just this credential. That is
    // the same shape as the partial write this command exists to prevent:
    // a per-credential defect made fatal to the whole file.
    final problem = envNameProblem(env);
    if (problem != null) {
      throw ProjectException('--env $problem');
    }
  }

  final path = kind.pathFor(instance);
  final pretty = path.join('.');

  // Refusing to overwrite is the point. Silently replacing a signing key is
  // worse than any partial write, and the operator who meant to rotate can say
  // so — while the one who mistyped an instance name finds out now rather than
  // when a build signs with something unexpected.
  final existing = inspectSecretKeys(
    secretsFile,
  ).credentials.where((c) => c.path == pretty).firstOrNull;
  if (existing != null && !replace) {
    throw ProjectException(
      '$pretty already exists, holding ${existing.fields.join(', ')}.\n'
      '    To rotate it deliberately, pass --replace.',
    );
  }

  // Asked before the write, because afterwards the outgoing certificate is gone
  // and with it the only way to know which profiles were issued against it.
  var staleProfiles = const <String>[];
  var staleProfilesUnknown = false;
  if (existing != null && kind.noun == 'certificate') {
    if (findStaleProfiles == null) {
      staleProfilesUnknown = true;
    } else {
      try {
        staleProfiles = findStaleProfiles(pretty);
      } catch (_) {
        // Reported as unknown rather than as none. The write still proceeds:
        // failing a rotation because the *advisory* could not be produced would
        // be the worse trade, and the operator is told what was not checked.
        staleProfilesUnknown = true;
      }
    }
  }

  final fields = <String, String>{};
  final notes = <String>[];

  if (kind.takesFile) {
    if (filePath == null) {
      throw ProjectException('a ${kind.noun} needs a file');
    }
    final file = File(filePath);
    if (!file.existsSync()) {
      throw ProjectException('no such file: $filePath');
    }
    final bytes = file.readAsBytesSync();
    final actual = identifyArtifact(bytes);
    if (!kind.accepts.contains(actual)) {
      throw ProjectException(_wrongArtifact(kind, actual, filePath));
    }
    await _fieldsFromFile(
      kind: kind,
      file: file,
      bytes: bytes,
      password: password,
      issuerId: issuerId,
      fields: fields,
      notes: notes,
      describeProfile: describeProfile,
    );
  }

  switch (kind.noun) {
    case 'token':
      final value = password;
      if (value == null || value.isEmpty) {
        throw ProjectException(
          'no value for the token — pipe it on stdin, or pass --value-file',
        );
      }
      fields['env'] = env!;
      fields['value'] = value;
    case 'ssh-key':
      fields['env'] = env!;
  }

  // Every field, one write.
  await _sopsSetMap(
    repoRoot: repoRoot,
    secretsFile: secretsFile,
    path: path,
    value: fields,
  );

  // Verify by re-reading rather than by trusting the exit code. Every manual
  // write made today needed a separate check afterwards, and those checks are
  // what caught the schema problems.
  final after = inspectSecretKeys(secretsFile);
  final written = after.credentials.where((c) => c.path == pretty).firstOrNull;
  if (written == null) {
    throw ProjectException(
      'wrote $pretty but reading it back did not find it. The write may have '
      'landed anyway —\n'
      '    run `secrets list`, which needs no identity, and remove it with '
      '`secrets remove` if it is there.',
    );
  }
  if (written.missing.isNotEmpty) {
    throw ProjectException(
      'wrote $pretty but it is missing ${written.missing.join(', ')}',
    );
  }

  return AddResult(
    path: pretty,
    fields: written.fields,
    notes: notes,
    replaced: existing != null,
    staleProfiles: staleProfiles,
    staleProfilesUnknown: staleProfilesUnknown,
  );
}

String _wrongArtifact(_AddKind kind, ArtifactKind actual, String filePath) {
  final suggestion = addKinds.values
      .where((k) => k.accepts.contains(actual))
      .map((k) => k.noun)
      .toList();
  return [
    '${p.basename(filePath)} is ${actual.what}, '
        'which is not what a ${kind.noun} is made of.',
    if (suggestion.isNotEmpty)
      '    Did you mean: ${suggestion.map((s) => 'add $s').join(', ')}?',
    if (suggestion.isEmpty)
      '    A ${kind.noun} wants '
          '${kind.accepts.map((a) => a.what).join(' or ')}.',
  ].join('\n');
}

Future<void> _fieldsFromFile({
  required _AddKind kind,
  required File file,
  required List<int> bytes,
  required String? password,
  required String? issuerId,
  required Map<String, String> fields,
  required List<String> notes,
  required List<String> Function(String filePath)? describeProfile,
}) async {
  final encoded = base64.encode(bytes);
  switch (kind.noun) {
    case 'certificate':
      if (password == null || password.isEmpty) {
        throw ProjectException(
          'a certificate needs the password that opens its .p12 — '
          'pipe it on stdin, or pass --password-file',
        );
      }
      // Checked before it is stored. A p12 whose password is wrong imports as
      // nothing useful and fails at signing time, a long way from here.
      final facts = readPkcs12Facts(file.path, password);
      fields['p12_base64'] = encoded;
      fields['password'] = password;
      notes.addAll(facts);
    case 'profile':
      fields['base64'] = encoded;
      // Read through a callback rather than by calling into keychain.dart:
      // that file imports this one, and reaching back would invert the layering
      // — `secrets` is the part that knows sops, and `keychain` is built on it.
      // It is also why this is reporting rather than validation: whether the
      // file *is* a profile was already settled by [identifyArtifact], which
      // needs no Mac. Only the pretty details need `security cms`.
      if (describeProfile != null) {
        try {
          notes.addAll(describeProfile(file.path));
        } catch (e) {
          notes.add('stored, but its details could not be read: $e');
        }
      }
    case 'api-key':
      final facts = apiKeyFactsFromName(file.path);
      if (facts == null) {
        throw ProjectException(
          '${p.basename(file.path)} is not named the way Apple names these.\n'
          '    They arrive as AuthKey_<id>.p8 (a team key) or '
          'ApiKey_<id>.p8 (an individual one),\n'
          '    and the filename is the only thing that says which — so it has '
          'to be the name Apple gave it.',
        );
      }
      fields['id'] = facts.id;
      fields['kind'] = facts.kind;
      fields['private_key_base64'] = encoded;
      if (issuerId != null && issuerId.isNotEmpty) {
        fields['issuer_id'] = issuerId;
      }
      notes.add('${facts.kind} key ${facts.id}');
    case 'keystore':
      if (password == null || password.isEmpty) {
        throw ProjectException(
          'a keystore needs its password — pipe it on stdin, or pass '
          '--password-file',
        );
      }
      fields['base64'] = encoded;
      fields['password'] = password;
    case 'play-account':
      fields['json_base64'] = encoded;
      final decoded = json.decode(utf8.decode(bytes));
      if (decoded is Map && decoded['client_email'] is String) {
        notes.add('${decoded['client_email']}');
      }
    case 'ssh-key':
      fields['base64'] = encoded;
  }
}

/// Subject, serial and expiry of the certificate inside a .p12 — and, by
/// getting them at all, proof that [password] opens it.
///
/// The check is the point. A .p12 stored with the wrong password is accepted
/// everywhere until something tries to sign with it, which is a full CI cycle
/// away and reports itself as a signing failure rather than as a bad password.
///
/// Password by environment rather than argument, and the `-legacy` attempt
/// first, both lifted from `readCertificateEnddate`: an argument is visible to
/// `ps`, OpenSSL 3 refuses the older PKCS#12 encryption Apple still hands out,
/// and LibreSSL — which is what `openssl` is on a stock macOS — does not know
/// the flag at all.
List<String> readPkcs12Facts(String p12Path, String password) {
  final result = Process.runSync(
    'sh',
    [
      '-c',
      '{ openssl pkcs12 -in "\$1" -passin env:CUX_P12_PASSWORD -nokeys -clcerts '
          '-legacy 2>/dev/null '
          '|| openssl pkcs12 -in "\$1" -passin env:CUX_P12_PASSWORD -nokeys '
          '-clcerts 2>/dev/null; } '
          '| openssl x509 -noout -subject -serial -enddate 2>/dev/null',
      'sh',
      p12Path,
    ],
    environment: {'CUX_P12_PASSWORD': password},
  );
  final out = (result.stdout as String).trim();
  if (out.isEmpty) {
    throw ProjectException(
      'that password does not open ${p.basename(p12Path)}.\n'
      '    Nothing has been written — a .p12 stored with the wrong password '
      'fails at signing time,\n'
      '    which is a long way from here and does not look like a password '
      'problem when it does.',
    );
  }
  return out
      .split('\n')
      .map((line) => line.trim())
      .where((l) => l.isNotEmpty)
      .toList();
}

/// One `sops set` writing an entire instance map.
///
/// sops applies the file's own `creation_rules` per leaf when it re-encrypts,
/// so the cleartext fields — `path`, `env`, `kind` — stay readable without an
/// identity exactly as they do when written one at a time.
Future<void> _sopsSetMap({
  required String repoRoot,
  required File secretsFile,
  required List<String> path,
  required Map<String, String> value,
}) async {
  final sops = findSops(repoRoot);
  final selector = path.map((p) => '["$p"]').join();
  final process = await Process.start(sops, [
    'set',
    secretsFile.path,
    selector,
    '--value-stdin',
  ], environment: _sopsIdentityEnvironment());
  // Through stdin, never a command line: an argument is visible in `ps` to
  // every user on the machine, and the value here is the credential itself.
  process.stdin.write(jsonEncode(value));
  await process.stdin.close();
  final code = await process.exitCode;
  if (code != 0) {
    throw ProjectException(
      'could not write ${path.join('.')} into ${secretsFile.path} — '
      'sops set exited $code',
    );
  }
}

/// Where sops should look for an identity, when the environment has not said.
///
/// Lifted out of [_decrypt] so writing and reading cannot drift apart — a write
/// that finds no identity while the matching read does would be a confusing
/// way to fail.
Map<String, String> _sopsIdentityEnvironment() {
  final environment = <String, String>{};
  final home = Platform.environment['HOME'];
  if (Platform.environment['SOPS_AGE_KEY'] == null &&
      Platform.environment['SOPS_AGE_KEY_FILE'] == null &&
      home != null) {
    final identity = File('$home/.config/sops/age/keys.txt');
    if (identity.existsSync()) {
      environment['SOPS_AGE_KEY_FILE'] = identity.path;
    }
  }
  return environment;
}

/// Removes a credential entirely.
///
/// Retiring one by hand-editing YAML is the same failure class as adding one
/// that way, and it is the operation people perform under pressure, having just
/// decided something is compromised. That is the worst possible moment to be
/// counting square brackets.
Future<String> removeCredential({
  required String repoRoot,
  required File secretsFile,
  required String kindName,
  required String instance,
}) async {
  final kind = addKinds[kindName];
  if (kind == null) {
    final known = (addKinds.keys.toList()..sort()).join(', ');
    throw ProjectException(
      'no such credential kind: $kindName\n    there is: $known',
    );
  }
  final path = kind.pathFor(instance);
  final pretty = path.join('.');
  final existing = inspectSecretKeys(
    secretsFile,
  ).credentials.where((c) => c.path == pretty).firstOrNull;
  if (existing == null) {
    throw ProjectException('no $pretty in ${secretsFile.path}');
  }

  final sops = findSops(repoRoot);
  final selector = path.map((p) => '["$p"]').join();
  final result = Process.runSync(sops, [
    'unset',
    secretsFile.path,
    selector,
  ], environment: _sopsIdentityEnvironment());
  if (result.exitCode != 0) {
    throw ProjectException(
      'could not remove $pretty from ${secretsFile.path} — '
      'sops unset exited ${result.exitCode}: ${result.stderr}',
    );
  }

  final after = inspectSecretKeys(secretsFile);
  if (after.credentials.any((c) => c.path == pretty)) {
    throw ProjectException(
      'asked sops to remove $pretty but it is still there',
    );
  }
  return pretty;
}
