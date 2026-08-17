// SPDX-License-Identifier: Apache-2.0
//
// "Do my stored credentials work, and do they agree with each other?"
//
// The third of three levels, each needing strictly more than the last and
// answering something the last cannot:
//
//   verify        offline, no credentials    the release inputs
//   secrets list  no identity                the file's shape
//   secrets check with identity              do the credentials work, and agree
//
// The question this answers has had no command. "Is anything about to expire"
// is continuous and an upload-time warning serves it; "is my setup correct" is
// asked after adding a credential, after a rotation, after onboarding a
// machine — and an upload-time warning is structurally too late for it. If a
// certificate is merely expiring you learn mid-release; if it is already
// expired, or a profile no longer holds a usable certificate, you learn fifteen
// minutes into an archive, from codesign, in its own vocabulary.
//
// **The cross-checks are the part nothing else can do.** A single-artifact
// command sees one credential; only something holding the whole decrypted file
// can ask whether a profile still embeds a certificate that is actually stored.
// That pairing is not derivable from either side alone — a Developer ID profile
// in this project outlives the certificate inside it, so a profile's own expiry
// date says nothing about whether it still holds a usable certificate.
part of 'secrets.dart';

/// What looking produced.
///
/// One axis, not a scale. [opaque] is not "verified but less so" — it is the
/// state of a credential that *cannot* be checked, ever, by this tool. Naming
/// it for a property rather than for a missing action is deliberate: anything
/// in the `unverified`/`untestable` family frames it as a verification that did
/// not happen, which invites someone to go and do it, and then becomes a nag
/// people learn to skip past.
enum CheckState {
  verified('verified'),
  opaque('opaque'),
  failed('failed');

  const CheckState(this.label);

  final String label;
}

/// One credential, and what looking at it produced.
class CheckRow {
  const CheckRow(this.path, this.state, this.detail);

  final String path;
  final CheckState state;

  /// Why, in the operator's terms. Never a value.
  final String detail;
}

/// What a provisioning profile says about itself, for the cross-check.
class ProfileInspection {
  const ProfileInspection({
    required this.name,
    required this.expires,
    required this.certificateFingerprints,
  });

  final String name;
  final DateTime? expires;

  /// SHA-256 of each certificate the profile embeds, uppercase hex, no colons.
  final List<String> certificateFingerprints;
}

/// Reads every credential and reports whether it works.
///
/// [inspectProfile] and [fingerprintCertificate] are passed in rather than
/// called directly, because decoding a profile needs `security cms` and this
/// file is the lower layer — `keychain.dart` imports this one, so reaching the
/// other way would invert it. Null means the cross-check is unavailable, which
/// is what a non-Mac gets, and it is reported as such rather than skipped
/// silently.
List<CheckRow> checkCredentials({
  required String repoRoot,
  required File secretsFile,
  ProfileInspection Function(String path)? inspectProfile,
  String? Function(String p12Path, String password)? fingerprintCertificate,
}) {
  final credentials = _decrypt(repoRoot: repoRoot, secretsFile: secretsFile);
  final rows = <CheckRow>[];

  // Materialized together, and removed however this ends: openssl and security
  // both want a path, and the alternative is leaving plaintext behind.
  final work = Directory.systemTemp.createTempSync('cux_ship_check');
  try {
    // Stored certificates by fingerprint, so a profile can be asked whether
    // the certificate it embeds is one we actually hold.
    final storedCertificates = <String, String>{};

    for (final credential in credentials) {
      rows.add(
        _checkOne(
          credential,
          work: work,
          inspectProfile: inspectProfile,
          fingerprintCertificate: fingerprintCertificate,
          storedCertificates: storedCertificates,
        ),
      );
    }

    // Second pass: the pairing. Deliberately after every certificate has been
    // seen, because a profile can be listed before the certificate it embeds
    // and a one-pass version would report a false mismatch depending on
    // alphabetical order.
    if (inspectProfile != null) {
      rows.addAll(
        _crossCheckProfiles(
          credentials,
          work: work,
          inspectProfile: inspectProfile,
          storedCertificates: storedCertificates,
        ),
      );
    } else if (credentials.any((c) => c.path.startsWith('apple.profiles.'))) {
      rows.add(
        const CheckRow(
          'apple.profiles',
          CheckState.opaque,
          'the profile-to-certificate pairing needs macOS, so it was not checked',
        ),
      );
    }
  } finally {
    work.deleteSync(recursive: true);
  }

  rows.sort((a, b) => a.path.compareTo(b.path));
  return rows;
}

CheckRow _checkOne(
  _Credential credential, {
  required Directory work,
  required ProfileInspection Function(String path)? inspectProfile,
  required String? Function(String p12Path, String password)?
  fingerprintCertificate,
  required Map<String, String> storedCertificates,
}) {
  final path = credential.path;
  try {
    if (path.startsWith('apple.certificates.')) {
      final p12 = _writeBase64(
        work,
        '${credential.instance}.p12',
        credential.fields['p12_base64']!,
        path,
      ).path;
      final password = credential.fields['password']!;
      final facts = readPkcs12Facts(p12, password);
      final enddate = readCertificateEnddateFor(p12, password);
      final days = enddate?.difference(DateTime.now().toUtc()).inDays;
      if (fingerprintCertificate != null) {
        final fingerprint = fingerprintCertificate(p12, password);
        if (fingerprint != null) {
          storedCertificates[fingerprint] = path;
        }
      }
      final subject = facts
          .firstWhere((f) => f.startsWith('subject='), orElse: () => '')
          .replaceFirst('subject=', '')
          .trim();
      if (days != null && days < 0) {
        return CheckRow(path, CheckState.failed, 'expired ${-days}d ago');
      }
      return CheckRow(
        path,
        CheckState.verified,
        [
          if (subject.isNotEmpty) subject,
          if (days != null) 'expires in ${days}d',
        ].join('  '),
      );
    }

    if (path.startsWith('apple.profiles.')) {
      if (inspectProfile == null) {
        return CheckRow(path, CheckState.opaque, 'needs macOS to decode');
      }
      final file = _writeBase64(
        work,
        '${credential.instance}.mobileprovision',
        credential.fields['base64']!,
        path,
      ).path;
      final profile = inspectProfile(file);
      final days = profile.expires?.difference(DateTime.now().toUtc()).inDays;
      if (days != null && days < 0) {
        return CheckRow(path, CheckState.failed, 'expired ${-days}d ago');
      }
      return CheckRow(
        path,
        CheckState.verified,
        [profile.name, if (days != null) 'expires in ${days}d'].join('  '),
      );
    }

    if (path.startsWith('apple.api_keys.')) {
      final kind = credential.fields['kind'];
      final issuer = credential.fields['issuer_id'];
      if (kind != 'team' && kind != 'individual') {
        return CheckRow(path, CheckState.failed, 'kind is "$kind"');
      }
      // A team key's JWT carries `iss`; an individual key's must not. Storing
      // one without the other is how an individual key got sent `iss` and came
      // back as a bare 401 after a full build.
      if (kind == 'team' && (issuer == null || issuer.isEmpty)) {
        return CheckRow(
          path,
          CheckState.failed,
          'a team key needs issuer_id, and none is stored',
        );
      }
      return CheckRow(
        path,
        CheckState.verified,
        '$kind key ${credential.fields['id']}',
      );
    }

    if (path.startsWith('android.keystores.')) {
      final store = _writeBase64(
        work,
        '${credential.instance}.keystore',
        credential.fields['base64']!,
        path,
      ).path;
      final password = credential.fields['password']!;
      final alias = credential.fields['key_alias'];
      final result = Process.runSync(
        'sh',
        [
          '-c',
          'keytool -list -keystore "\$1" -storepass "\$CUX_STORE_PASSWORD" 2>&1',
          'sh',
          store,
        ],
        environment: {'CUX_STORE_PASSWORD': password},
      );
      if (result.exitCode == 127 ||
          (result.stdout as String).contains('command not found')) {
        return CheckRow(path, CheckState.opaque, 'no keytool on this machine');
      }
      final out = result.stdout as String;
      if (result.exitCode != 0) {
        return CheckRow(
          path,
          CheckState.failed,
          'the stored password does not open it',
        );
      }
      if (alias != null && !out.contains(alias)) {
        return CheckRow(
          path,
          CheckState.failed,
          'opens, but holds no alias "$alias"',
        );
      }
      return CheckRow(path, CheckState.verified, 'opens, alias $alias present');
    }

    if (path == 'android.play_service_account') {
      final decoded = json.decode(
        utf8.decode(base64.decode(credential.fields['json_base64']!)),
      );
      if (decoded is! Map || decoded['client_email'] is! String) {
        return CheckRow(path, CheckState.failed, 'not a service account json');
      }
      // Whether Google still honours it is Google's to say, and asking costs a
      // network round trip with a credential — so what is established here is
      // the shape, and that is said rather than implied.
      return CheckRow(
        path,
        CheckState.opaque,
        '${decoded['client_email']} — well formed, never authenticated',
      );
    }

    if (path.startsWith('tokens.') || path.startsWith('ssh_keys.')) {
      final env = credential.fields['env'];
      if (env == null) {
        return CheckRow(path, CheckState.failed, 'has no env');
      }
      // [envNameProblem] rather than a copy of its rule, and this is the place
      // where that matters most. This check exists to *predict* whether
      // `loadSecrets` will throw — and there it takes down every command that
      // loads secrets, not just this credential. A predictor holding its own
      // copy of the rule predicts its own behaviour rather than the loader's,
      // so the moment the two drift `check` reports `verified` for a credential
      // that then breaks the build. That is worse than not checking: it turns a
      // loud failure into a confident all-clear.
      final problem = envNameProblem(env);
      if (problem != null) {
        return CheckRow(path, CheckState.failed, 'env $problem');
      }
      if (path.startsWith('ssh_keys.')) {
        final kind = identifyArtifact(
          base64.decode(credential.fields['base64']!),
        );
        if (kind != ArtifactKind.opensshKey &&
            kind != ArtifactKind.pemPrivateKey) {
          return CheckRow(path, CheckState.failed, 'is ${kind.what}');
        }
        return CheckRow(
          path,
          CheckState.opaque,
          '$env — ${kind.what}, never authenticated',
        );
      }
      final value = credential.fields['value'];
      if (value == null || value.isEmpty) {
        return CheckRow(path, CheckState.failed, 'has no value');
      }
      // The honest state. cux_ship cannot know how to authenticate an arbitrary
      // token, and a report calling it "verified" would be claiming something
      // nobody checked. Deliberately not made checkable by letting the file
      // describe a command or URL to test it with: that would turn a credential
      // file into something that executes, and the property worth keeping is
      // that this tool cannot be tricked into spending a token it holds.
      return CheckRow(
        path,
        CheckState.opaque,
        '$env — present, never authenticated',
      );
    }

    if (path.startsWith('placed.')) {
      return CheckRow(
        path,
        CheckState.verified,
        'writes to ${credential.fields['path']}',
      );
    }

    return CheckRow(path, CheckState.opaque, 'nothing known to check');
  } on ProjectException catch (e) {
    // A fact about the credential: every deliberate throw in these files raises
    // this, and the message is already written for the operator.
    return CheckRow(path, CheckState.failed, e.message);
  } catch (e) {
    // A fact about *this tool*, and said so. A blanket catch renders a null
    // check error as "apple.profiles.ios_appstore failed: Null check operator
    // used on a null value", which reads as "your profile is broken" when it
    // means "the checker is" — the same shape as a failing subprocess reading
    // as an absent value, which has now cost three separate bugs.
    return CheckRow(
      path,
      CheckState.failed,
      'cux_ship could not check this: $e',
    );
  }
}

/// Which stored profiles were issued against the certificate at
/// [certificatePath] — asked *before* that certificate is replaced.
///
/// This is the operational half of the fact the cross-check reports. Replacing
/// a certificate invalidates every profile issued against it, and no artifact
/// says so: the profile keeps its own expiry date, and in this project a
/// Developer ID profile outlives the certificate inside it by eighteen years.
/// So the moment to name them is while the outgoing certificate is still there
/// to be fingerprinted — afterwards the evidence is gone.
///
/// Returns an empty list when nothing can be established, and the caller says
/// so rather than reporting "no profiles affected", which is a different claim.
List<String> profilesEmbeddingCertificate({
  required String repoRoot,
  required File secretsFile,
  required String certificatePath,
  required ProfileInspection Function(String path) inspectProfile,
  required String? Function(String p12Path, String password)
  fingerprintCertificate,
}) {
  final credentials = _decrypt(repoRoot: repoRoot, secretsFile: secretsFile);
  final certificate = credentials
      .where((c) => c.path == certificatePath)
      .firstOrNull;
  if (certificate == null) {
    return const [];
  }
  final work = Directory.systemTemp.createTempSync('cux_ship_stale');
  try {
    final p12 = _writeBase64(
      work,
      'outgoing.p12',
      certificate.fields['p12_base64']!,
      certificatePath,
    ).path;
    final fingerprint = fingerprintCertificate(
      p12,
      certificate.fields['password']!,
    );
    if (fingerprint == null) {
      return const [];
    }
    final affected = <String>[];
    for (final profile in credentials.where(
      (c) => c.path.startsWith('apple.profiles.'),
    )) {
      try {
        final file = _writeBase64(
          work,
          '${profile.instance}.mobileprovision',
          profile.fields['base64']!,
          profile.path,
        ).path;
        if (inspectProfile(
          file,
        ).certificateFingerprints.contains(fingerprint)) {
          affected.add(profile.path);
        }
      } catch (_) {
        // A profile that cannot be read cannot be cleared either, so it is not
        // reported as affected — the cross-check in `secrets check` is where an
        // unreadable profile is meant to surface.
      }
    }
    return affected;
  } finally {
    work.deleteSync(recursive: true);
  }
}

/// Does each profile still embed a certificate this file actually holds?
///
/// The coupling nothing else sees. Replacing a certificate silently invalidates
/// every App Store profile issued against it, and neither artifact says so: the
/// profile keeps its own expiry date, which this project has a counterexample
/// for — a Developer ID profile outliving the certificate inside it. So a
/// profile that looks valid for months can already be unusable.
List<CheckRow> _crossCheckProfiles(
  List<_Credential> credentials, {
  required Directory work,
  required ProfileInspection Function(String path) inspectProfile,
  required Map<String, String> storedCertificates,
}) {
  final rows = <CheckRow>[];
  // Said out loud rather than returning nothing. A cross-check that silently
  // does not run reads exactly like one that ran and found nothing wrong, and
  // this function had that bug: a plutil failure emptied the fingerprint list
  // and every pairing was skipped without a word.
  if (storedCertificates.isEmpty) {
    rows.add(
      const CheckRow(
        'profiles ↔ certificates',
        CheckState.opaque,
        'no certificate fingerprints could be read, so no pairing was checked',
      ),
    );
    return rows;
  }
  for (final credential in credentials.where(
    (c) => c.path.startsWith('apple.profiles.'),
  )) {
    try {
      final file = _writeBase64(
        work,
        '${credential.instance}.mobileprovision',
        credential.fields['base64']!,
        credential.path,
      ).path;
      final profile = inspectProfile(file);
      if (profile.certificateFingerprints.isEmpty) {
        rows.add(
          CheckRow(
            '${credential.path} ↔ certificates',
            CheckState.opaque,
            'the profile embeds no certificates this could read',
          ),
        );
        continue;
      }
      final matched = profile.certificateFingerprints
          .where(storedCertificates.containsKey)
          .map((f) => storedCertificates[f]!)
          .toList();
      if (matched.isEmpty) {
        rows.add(
          CheckRow(
            '${credential.path} ↔ certificates',
            CheckState.failed,
            'embeds no certificate this file holds — it was issued against one '
                'that has since been replaced, so signing with it will fail',
          ),
        );
      } else {
        rows.add(
          CheckRow(
            '${credential.path} ↔ certificates',
            CheckState.verified,
            'embeds ${matched.join(', ')}',
          ),
        );
      }
    } on ProjectException catch (e) {
      rows.add(
        CheckRow(
          '${credential.path} ↔ certificates',
          CheckState.failed,
          e.message,
        ),
      );
    } catch (e) {
      rows.add(
        CheckRow(
          '${credential.path} ↔ certificates',
          CheckState.failed,
          'cux_ship could not check this: $e',
        ),
      );
    }
  }
  return rows;
}

/// `notAfter` as a date, or null when openssl would not say.
///
/// Separate from [readPkcs12Facts] because that one throws when the password is
/// wrong, and here a missing date and a wrong password want different answers.
DateTime? readCertificateEnddateFor(String p12Path, String password) {
  final result = Process.runSync(
    'sh',
    [
      '-c',
      '{ openssl pkcs12 -in "\$1" -passin env:CUX_P12_PASSWORD -nokeys -clcerts '
          '-legacy 2>/dev/null '
          '|| openssl pkcs12 -in "\$1" -passin env:CUX_P12_PASSWORD -nokeys '
          '-clcerts 2>/dev/null; } | openssl x509 -noout -enddate 2>/dev/null',
      'sh',
      p12Path,
    ],
    environment: {'CUX_P12_PASSWORD': password},
  );
  final text = (result.stdout as String).trim();
  if (!text.startsWith('notAfter=')) {
    return null;
  }
  return parseOpensslDate(text.substring('notAfter='.length).trim());
}

/// `Mar  1 12:00:00 2027 GMT`, which is not a format `DateTime.parse` knows.
///
/// Public because `keychain.dart` ranks certificates by the same field, and two
/// parsers for one format is the drift this file has already been bitten by.
DateTime? parseOpensslDate(String value) {
  const months = {
    'Jan': 1,
    'Feb': 2,
    'Mar': 3,
    'Apr': 4,
    'May': 5,
    'Jun': 6,
    'Jul': 7,
    'Aug': 8,
    'Sep': 9,
    'Oct': 10,
    'Nov': 11,
    'Dec': 12,
  };
  final match = RegExp(
    r'^(\w{3})\s+(\d{1,2})\s+(\d{2}):(\d{2}):(\d{2})\s+(\d{4})',
  ).firstMatch(value);
  if (match == null || !months.containsKey(match.group(1))) {
    return null;
  }
  return DateTime.utc(
    int.parse(match.group(6)!),
    months[match.group(1)]!,
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
    int.parse(match.group(4)!),
    int.parse(match.group(5)!),
  );
}
