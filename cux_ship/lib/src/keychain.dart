// SPDX-License-Identifier: Apache-2.0
//
// Signs from a keychain that exists for the length of one command.
//
//   cux_ship keychain exec -- tool/build.sh --release macos
//
// **The login keychain is never read, and that is the whole point.** A build
// whose signing identity comes from whatever the developer happens to have
// installed is a build nobody can reproduce: it succeeds on the laptop that has
// the certificate and fails on the one that does not, and — worse — it can
// succeed on both while signing with two different certificates. So the
// identity is imported from the project's own secrets into a keychain created
// here and destroyed however this exits.
//
// This is the platform-gated step `secrets.dart` defers to. That file decrypts
// a profile and writes the bytes somewhere findable, and says in as many words
// that filing it where Xcode looks needs `security cms` and therefore a Mac.
// This is that Mac-only half; the sops knowledge stays over there, reached
// through [loadSecrets] rather than reimplemented here.
//
// **What it does not do is build anything.** No Flutter, no Xcode, no archive,
// no export — those are the project's, and they differ between projects for
// real reasons. The contract is one environment variable: the wrapped command
// gets `APPLE_KEYCHAIN`, and is expected to pass
// `OTHER_CODE_SIGN_FLAGS="--keychain $APPLE_KEYCHAIN"` to xcodebuild.
//
// That last part is not a nicety, and the reason is worth stating where
// somebody will read it. This command cannot *remove* the login keychain from
// the search list: dropping it would take Apple's intermediate certificates
// with it and leave the leaf chaining to nothing. So during the run the login
// keychain is still searchable, and pinning codesign to ours is the only thing
// that makes "signed with the certificate we imported" true rather than likely.
// A caller that omits the flag gets no guarantee at all.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'project.dart';
import 'secrets.dart';

/// How long the keychain stays unlocked, in seconds.
///
/// Six hours, taken as the larger of the two implementations this replaces: the
/// shorter one relocked partway through a long archive, and a relock surfaces as
/// a codesign failure that names nothing useful.
///
/// It is not really a security control — the password is random, lives in this
/// process, and dies with it. What the timeout bounds is the window in which a
/// keychain orphaned by SIGKILL is still unlocked, and [collectStaleKeychains]
/// is the better answer to that.
///
/// Note `-l` (lock on sleep) rides along with `-u`, so a closed laptop relocks
/// whatever this number says. A long archive is not something to start and walk
/// away from.
const keychainLockTimeoutSeconds = 21600;

/// Which tools may use the imported key without a GUI prompt.
///
/// **`apple:` is the whole load-bearing token, and this is measured rather than
/// argued.** Six fresh keychains, a real distribution identity, one
/// non-interactive `codesign` each, anything still alive after 8s counted as
/// blocked — because a block here is a GUI prompt, which on CI is a hang rather
/// than an error:
///
///     apple-tool:,apple:,codesign:   signed
///     apple:                         signed
///     apple-tool:,apple:             signed
///     codesign:                      BLOCKED
///     apple-tool:                    BLOCKED
///     (unset)                        BLOCKED
///
/// So `codesign:` does nothing on its own and adds nothing to `apple:`; it is
/// inherited from fastlane's importer. It is kept because an unmatched partition
/// id costs nothing, but it is not the fix and should not be believed to be —
/// the fix is calling this at all, plus [_security] making a failure loud.
///
/// One trap in reproducing that experiment: `codesign` resolves an identity
/// through the *search list*, not through `--keychain` alone, so a run that has
/// not prepended the keychain first fails every variant with "no identity found"
/// and measures nothing.
const keychainPartitionList = 'apple-tool:,apple:,codesign:';

/// Names every keychain this tool creates, so [collectStaleKeychains] can find
/// one an earlier run left behind.
const keychainNamePrefix = 'cux_ship-build-';

/// How close to expiry is worth mentioning. Matches the developer-account audit
/// in `appstore/signing.dart`, so two commands do not disagree about "soon".
const _soonInDays = 30;

// ---------------------------------------------------------------- pure parts
//
// Everything above the `security` calls, so it can be tested without a Mac, a
// keychain or a real certificate.

/// Which of Apple's two provisioning-profile worlds a profile belongs to.
///
/// Xcode reads the two from different directories under different extensions
/// and will not match one filed under the other — so this is derived from the
/// profile's own `Platform` key rather than from its filename, which is a name
/// we chose ourselves and therefore proves nothing.
enum ProfilePlatform {
  ios(
    'mobileprovision',
    'Library/Developer/Xcode/UserData/Provisioning Profiles',
  ),
  macos('provisionprofile', 'Library/MobileDevice/Provisioning Profiles');

  const ProfilePlatform(this.extension, this.directory);

  /// What Xcode expects the installed file to be called.
  final String extension;

  /// Where Xcode looks, relative to the home directory.
  final String directory;
}

/// A provisioning profile, reduced to the four things installing it needs.
class ProfileFacts {
  const ProfileFacts({
    required this.uuid,
    required this.name,
    required this.platform,
    required this.expires,
  });

  /// Xcode finds a profile by the UUID in its *filename*, not by its path, so
  /// this decides what the installed copy is called.
  final String uuid;

  /// The profile's own name, for reporting. Not used to decide anything.
  final String name;

  final ProfilePlatform platform;

  /// Null when the profile omitted the field, which no real one does.
  final DateTime? expires;

  /// Whole days until expiry, negative once past.
  int? daysLeft(DateTime now) => expires?.difference(now).inDays;
}

/// The values [ProfileFacts] is built from, as `plutil -extract … raw` prints
/// them.
///
/// Split out so the parsing is testable against fixtures: the extraction itself
/// is four subprocess calls and a Mac, and none of the interesting failure modes
/// live there.
///
/// The keys are Apple's, from the decoded CMS payload.
ProfileFacts profileFactsFrom(Map<String, String> extracted, String at) {
  final uuid = extracted['UUID']?.trim();
  if (uuid == null || uuid.isEmpty) {
    throw ProjectException(
      '$at has no UUID — it is not a provisioning profile',
    );
  }

  // A path-traversal guard as much as a spelling check: this becomes a filename
  // in a directory of Xcode's, and the value came out of a file rather than out
  // of the schema.
  if (!RegExp(r'^[A-Za-z0-9-]+$').hasMatch(uuid)) {
    throw ProjectException('$at has a UUID that is not one: $uuid');
  }

  final platforms = _platformsFrom(extracted['Platform'], at);

  // Refused rather than defaulted. Guessing iOS would file a macOS profile
  // where Xcode does not look, and the build then fails inside codesign saying
  // no profile matched — which is a long way from "we filed it wrong".
  final ProfilePlatform platform;
  if (platforms.contains('osx') || platforms.contains('macos')) {
    platform = ProfilePlatform.macos;
  } else if (platforms.contains('ios') ||
      platforms.contains('tvos') ||
      platforms.contains('xros')) {
    platform = ProfilePlatform.ios;
  } else {
    throw ProjectException(
      '$at does not say which platform it is for — Platform was '
      '${platforms.isEmpty ? 'absent' : platforms.join(', ')}',
    );
  }

  return ProfileFacts(
    uuid: uuid,
    name: extracted['Name']?.trim() ?? uuid,
    platform: platform,
    expires: DateTime.tryParse(extracted['ExpirationDate']?.trim() ?? ''),
  );
}

/// One line of `security find-identity` output.
typedef Identity = ({String hash, String name, String? note});

/// The identities in `security find-identity` output.
///
/// The lines look like
///
///     1) 56CD0E47…8D4D "Apple Distribution: Someone (TEAMID)" (CSSMERR_TP_NOT_TRUSTED)
///
/// and the parenthesized note at the end is the interesting part: it is present
/// exactly when the identity is listed but unusable, which is the case a bare
/// `-v` listing renders as an empty result with no reason attached.
List<Identity> parseIdentities(String output) {
  final line = RegExp(r'^\s*\d+\)\s+(\S+)\s+"([^"]*)"\s*(?:\(([^)]*)\))?\s*$');
  final found = <Identity>[];
  for (final raw in const LineSplitter().convert(output)) {
    final match = line.firstMatch(raw);
    if (match == null) {
      continue;
    }
    found.add((
      hash: match.group(1)!,
      name: match.group(2)!,
      note: match.group(3),
    ));
  }
  return found;
}

/// What to do about one provisioning profile, given how close it is to expiry.
enum ProfileDecision { install, skipExpired, failExpired, failExpiringSoon }

/// Whether an expired profile stops the build or is merely skipped.
///
/// **The rule turns on [named], and getting this wrong is worse than not
/// checking at all.** The secrets file holds every profile a project has, and
/// `secrets exec` materializes all of them; this command has no way to know
/// which one the wrapped build is about to use. So failing on any expired
/// profile means letting a Developer ID profile lapse breaks every App Store
/// release, with an error naming a profile that build never touches — the same
/// unhelpful failure the expiry check exists to prevent, pointed the wrong way.
///
/// Naming a profile with `--profile` is the caller saying this build needs it.
/// Then, and only then, is expiry fatal.
ProfileDecision decideProfile({
  required int? daysLeft,
  required bool named,
  required bool strictExpiry,
}) {
  if (daysLeft == null) {
    return ProfileDecision.install;
  }
  if (daysLeft < 0) {
    return named ? ProfileDecision.failExpired : ProfileDecision.skipExpired;
  }
  if (named && strictExpiry && daysLeft <= _soonInDays) {
    return ProfileDecision.failExpiringSoon;
  }
  return ProfileDecision.install;
}

/// The platforms named by a profile's `Platform` key, lowercased.
///
/// **`Platform` is a set, not a scalar, and it is extracted as json for a
/// reason worth stating.** `plutil -extract Platform raw` prints an array's
/// *element count* — a modern iOS profile says `[iOS, xrOS, visionOS]` and so
/// prints `3`, while a macOS one says `[OSX]` and prints `1`. Neither is a
/// platform name, and a first version of this read those numbers and refused
/// every real profile on both platforms.
///
/// So a value that is not a list is refused with the reason, rather than being
/// split on whitespace and quietly yielding a set containing "3".
Set<String> _platformsFrom(String? value, String at) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) {
    return const {};
  }
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    decoded = null;
  }
  if (decoded is! List) {
    throw ProjectException(
      '$at: Platform came back as "$text" rather than a list.\n'
      "`plutil -extract Platform raw` prints an array's element count rather "
      'than its contents, so it has to be extracted as json.',
    );
  }
  return {for (final entry in decoded) '$entry'.toLowerCase()};
}

/// The keychain paths in `security list-keychains` output.
///
/// Quote-aware, and that is the point: the output is quote-delimited precisely
/// because a keychain path may contain spaces, and both implementations this
/// replaces strip quotes with `tr`/`sed` and so corrupt the search list for
/// anyone whose home directory has a space in it.
List<String> parseSearchList(String output) {
  final paths = <String>[];
  for (final raw in const LineSplitter().convert(output)) {
    final line = raw.trim();
    if (line.isEmpty) {
      continue;
    }
    if (line.length >= 2 && line.startsWith('"') && line.endsWith('"')) {
      paths.add(line.substring(1, line.length - 1));
    } else {
      paths.add(line);
    }
  }
  return paths;
}

/// The pid encoded in one of this tool's keychain filenames, or null when the
/// name is not one of ours.
int? pidOfKeychain(String path) {
  final name = path.split('/').last;
  if (!name.startsWith(keychainNamePrefix)) {
    return null;
  }
  final rest = name.substring(keychainNamePrefix.length);
  return int.tryParse(rest.split('.').first);
}

/// Which of [candidates] were left behind by a process that is gone.
///
/// **This is what the pid in the name is for**, and no implementation this
/// replaces collects it. A trap handles a failed build, a Ctrl-C and a SIGTERM;
/// it does not handle SIGKILL or the power going out, and what survives those is
/// a keychain file holding the distribution private key, unlocked for up to
/// [keychainLockTimeoutSeconds], plus a search-list entry pointing at it.
///
/// [alive] is injected so the decision is testable without spawning processes.
List<String> collectStaleKeychains(
  Iterable<String> candidates, {
  required bool Function(int pid) alive,
  required int selfPid,
}) => [
  for (final path in candidates)
    if (pidOfKeychain(path) case final pid?)
      // Never our own, even though we are obviously alive: the ordering of
      // garbage collection against creation is not something a later edit
      // should be able to get wrong.
      if (pid != selfPid && !alive(pid)) path,
];

// -------------------------------------------------------------- the impure half

/// One certificate to import.
typedef _Certificate = ({String name, String path, String password});

/// Runs `security`, and turns a failure into something that names the step.
///
/// Failures are loud here as a rule rather than case by case. One of the
/// implementations this replaces ends its `set-key-partition-list` with
/// `>/dev/null 2>&1 || true`, so a failure there does not fail the build — it
/// surfaces twenty minutes later as codesign opening a GUI prompt on a headless
/// runner, which is a hang. A hang is the worst available reporting of an error.
ProcessResult _security(List<String> arguments, String step) {
  final result = Process.runSync('security', arguments);
  if (result.exitCode != 0) {
    throw ProjectException(
      'could not $step — security exited ${result.exitCode}\n'
      '    ${(result.stderr as String).trim()}',
    );
  }
  return result;
}

/// A keychain that exists for the length of one command.
class _Session {
  _Session(this.path, this.password);

  final String path;
  final String password;

  /// Absolute paths of profiles this run wrote, so cleanup removes those and
  /// only those.
  final List<String> installedProfiles = [];

  /// Removes everything this run created.
  ///
  /// Deleting the keychain also removes it from the search list — `security
  /// delete-keychain` documents exactly that — so there is deliberately no
  /// snapshot-and-restore of the list here. Restoring a snapshot would be worse
  /// than nothing: with two builds running, the second prepends itself after the
  /// first took its snapshot, and the first would then "restore" the second out
  /// of existence mid-archive. Delete composes; restore does not.
  ///
  /// Never throws. It runs in a `finally`, and an exception raised while
  /// unwinding another one replaces the failure the user actually needs to see.
  void dispose() {
    for (final profile in installedProfiles) {
      try {
        final file = File(profile);
        if (file.existsSync()) {
          file.deleteSync();
        }
      } on FileSystemException {
        // Reported rather than raised: a profile we could not remove is untidy,
        // and the build result is what matters here.
        stderr.writeln('==> could not remove $profile');
      }
    }
    Process.runSync('security', ['delete-keychain', path]);
  }
}

/// Creates the keychain and imports [certificates] into it.
_Session _create({
  required String home,
  required List<_Certificate> certificates,
  required String? expectTeam,
}) {
  final path = '$home/Library/Keychains/$keychainNamePrefix$pid.keychain-db';

  // PIDs recycle, and `create-keychain` on an existing path does not start
  // clean.
  final existing = File(path);
  if (existing.existsSync()) {
    Process.runSync('security', ['delete-keychain', path]);
  }

  // `openssl rand`, and not `tr </dev/urandom | head`: head exits at its byte
  // count, tr takes SIGPIPE, and a shell with pipefail turns that into a fatal
  // 141 — which is a confusing way for a build to die at step one.
  final random = Process.runSync('openssl', ['rand', '-hex', '24']);
  if (random.exitCode != 0) {
    throw ProjectException('could not generate a keychain password');
  }
  final password = (random.stdout as String).trim();

  // A note on what is visible in `ps` while this runs: `security` takes both
  // this password and the p12 password on the command line, and has no way to
  // read either from stdin. The keychain password is random and dies with this
  // process, so it discloses nothing worth having; the p12 password is a real
  // secret and is exposed for the length of one `import`. Every implementation
  // of this on any CI has the same window, and closing it would mean not using
  // `security`. Recorded because an undocumented exposure is the kind that gets
  // rediscovered as a finding.
  _security(['create-keychain', '-p', password, path], 'create $path');

  final session = _Session(path, password);
  try {
    _security([
      'set-keychain-settings',
      '-lut',
      '$keychainLockTimeoutSeconds',
      path,
    ], 'set the lock timeout');
    _security(['unlock-keychain', '-p', password, path], 'unlock $path');

    for (final certificate in certificates) {
      // `-T` names the tools allowed to use the key. Not `-A`, which would let
      // anything on the machine use it without prompting.
      _security([
        'import',
        certificate.path,
        '-k',
        path,
        '-P',
        certificate.password,
        '-T',
        '/usr/bin/codesign',
        '-T',
        '/usr/bin/security',
        '-T',
        '/usr/bin/productbuild',
      ], 'import the ${certificate.name} certificate');
    }

    _security([
      'set-key-partition-list',
      '-S',
      keychainPartitionList,
      '-s',
      '-k',
      password,
      path,
    ], 'allow codesign to use the imported key');

    // Prepended, never replaced. Replacing would drop the system keychain and
    // with it Apple's intermediate certificates, leaving the leaf chaining to
    // nothing — which fails as an untrusted signature rather than as a missing
    // keychain.
    final current = parseSearchList(
      _security(['list-keychains', '-d', 'user'], 'read the search list').stdout
          as String,
    );
    _security([
      'list-keychains',
      '-d',
      'user',
      '-s',
      path,
      ...current.where((k) => k != path),
    ], 'add $path to the search list');

    // Only when something was imported that should yield one. An installer
    // certificate signs a .pkg rather than code and never appears under the
    // codesigning policy, so a keychain holding nothing else would otherwise be
    // told "no signing identity at all — that is what a .p12 exported without
    // its private key does", which is a confident wrong answer about a
    // certificate that is perfectly fine.
    if (certificates.any((c) => !c.name.contains('installer'))) {
      _verifyIdentity(path, expectTeam);
    }

    // The installer certificate is checked separately because `find-identity
    // -p codesigning` does not list it at all — it signs a .pkg rather than
    // code. Without this, a Mac App Store run whose installer certificate
    // failed to import gets a clean bill of health here and fails in
    // productbuild at the end of the build.
    if (certificates.any((c) => c.name.contains('installer'))) {
      // **No `-p codesigning` here, and that is the entire trick.** An
      // installer identity does not appear under the codesigning policy at
      // all, so a check that keeps the policy and merely greps for a different
      // string finds nothing and passes anyway.
      final installers = parseIdentities(
        _security([
              'find-identity',
              '-v',
              path,
            ], 'list the installer identities in $path').stdout
            as String,
      ).where((i) => i.name.contains('Installer')).toList();
      if (installers.isEmpty) {
        throw ProjectException(
          'an installer certificate was imported but yielded no installer '
          'identity.\n'
          'A Mac App Store .pkg is signed by "3rd Party Mac Developer '
          'Installer", which is a different certificate from "Developer ID '
          'Installer" and from the one that signs the app.',
        );
      }
      // The team check applies here too, so it is not lost when an installer
      // certificate is the only thing imported and the codesigning check above
      // was skipped.
      if (expectTeam != null &&
          !installers.any((i) => i.name.contains(expectTeam))) {
        throw ProjectException(
          'the installer certificate does not belong to team $expectTeam.\n'
          '${installers.map((i) => '    ${i.name}').join('\n')}',
        );
      }
      // Named rather than counted, because the two kinds are not
      // interchangeable and this command cannot tell which the build wants:
      // "3rd Party Mac Developer Installer" signs a Mac App Store package,
      // "Developer ID Installer" signs a direct download. Refusing either would
      // be guessing; printing which one arrived makes the wrong certificate
      // visible here instead of discovered by productbuild at the end.
      stderr.writeln('==> ${installers.map((i) => i.name).join(', ')}');
    }
    return session;
  } on Object {
    session.dispose();
    rethrow;
  }
}

/// Refuses to continue unless the keychain actually holds a usable identity.
///
/// **Scoped to this keychain, and matched against the team.** The two
/// implementations this replaces have one of those each: a global check passes
/// because some *other* keychain has an identity, which is the exact dependency
/// this command exists to remove; and a check that ignores the team passes with
/// a certificate belonging to a different account, which fails much later with a
/// profile-mismatch error that does not mention certificates at all.
void _verifyIdentity(String keychain, String? expectTeam) {
  // Both listings, because the difference between them is the diagnosis. `-v`
  // alone cannot tell "the p12 had no private key" from "the key is here and
  // the certificate does not chain", and those need opposite fixes: re-export
  // the certificate, or install the issuing intermediate. Asking for the
  // unfiltered list costs one subprocess and turns a guess into a statement.
  final all = parseIdentities(
    _security([
          'find-identity',
          '-p',
          'codesigning',
          keychain,
        ], 'list the identities in $keychain').stdout
        as String,
  );
  final valid = parseIdentities(
    _security([
          'find-identity',
          '-v',
          '-p',
          'codesigning',
          keychain,
        ], 'list the valid identities in $keychain').stdout
        as String,
  );

  if (all.isEmpty) {
    throw ProjectException(
      'the certificate imported but the keychain holds no signing identity '
      'at all.\n'
      'That is what a .p12 exported without its private key does — re-export '
      'it with the key.',
    );
  }
  if (valid.isEmpty) {
    // Named with the reason `security` gave, because the reason is the whole
    // content of this error. In CI the usual cause is that the issuing
    // intermediate — Apple's WWDR certificate — is not on the machine at all,
    // and the leaf then chains to nothing.
    throw ProjectException(
      'the signing identity is in the keychain but is not usable:\n'
      '${all.map((i) => '    ${i.name}${i.note == null ? '' : ' — ${i.note}'}').join('\n')}\n'
      'The private key is there, so this is the certificate chain: the '
      'issuing intermediate is missing or the certificate has expired.',
    );
  }
  if (expectTeam != null && !valid.any((i) => i.name.contains(expectTeam))) {
    throw ProjectException(
      'no identity in the new keychain belongs to team $expectTeam.\n'
      'The certificate is for a different developer account than the project '
      'builds for, which imports perfectly and then fails much later as a '
      'profile mismatch.\n'
      '${valid.map((i) => '    ${i.name}').join('\n')}',
    );
  }
  stderr.writeln('==> ${valid.map((i) => i.name).join(', ')}');
}

/// Reads the four fields installing a profile needs.
ProfileFacts _readProfile(String path) {
  // Bytes rather than a decoded string: this is a CMS payload and nothing has
  // promised it is UTF-8, and it is about to be handed straight back to a tool
  // that will parse it as a plist.
  final decoded = Process.runSync('security', [
    'cms',
    '-D',
    '-i',
    path,
  ], stdoutEncoding: null);
  if (decoded.exitCode != 0) {
    throw ProjectException(
      '$path is not a provisioning profile — security cms could not decode it',
    );
  }

  // Through a file, because `Process.runSync` cannot write to a child's stdin
  // at all — the alternative is the async API and an await in a function whose
  // callers are otherwise synchronous.
  final work = Directory.systemTemp.createTempSync('cux_ship_profile');
  try {
    final plist = File('${work.path}/profile.plist')
      ..writeAsBytesSync(decoded.stdout as List<int>);

    // One `plutil` call per key, rather than converting the whole payload to
    // JSON: `plutil -convert json` refuses any plist containing a date, and
    // every real profile carries ExpirationDate. A fixture written without one
    // would have passed.
    // `raw` for the scalars, `json` for `Platform` — because `raw` on an array
    // prints its element count. json works here and not on the whole payload
    // because the extracted subtree is a list of strings; converting the entire
    // profile would hit ExpirationDate and be refused.
    const format = {
      'UUID': 'raw',
      'Name': 'raw',
      'Platform': 'json',
      'ExpirationDate': 'raw',
    };
    final extracted = <String, String>{};
    for (final entry in format.entries) {
      final result = Process.runSync('plutil', [
        '-extract',
        entry.key,
        entry.value,
        '-o',
        '-',
        plist.path,
      ]);
      if (result.exitCode == 0) {
        extracted[entry.key] = (result.stdout as String).trim();
      }
    }
    return profileFactsFrom(extracted, path);
  } finally {
    work.deleteSync(recursive: true);
  }
}

// ------------------------------------------------------------------ the command

/// Runs [command] with a temporary keychain holding the project's signing
/// identity, and returns its exit code.
Future<int> runKeychainExec({
  required String repoRoot,
  required File secretsFile,
  required List<String> command,
  String? expectTeam,
  bool strictExpiry = false,
  Set<String>? profiles,
  String? apiKey,
}) async {
  if (command.isEmpty) {
    throw ProjectException(
      'nothing to run — put the command after `--`, as in\n'
      '    cux_ship keychain exec -- tool/build.sh --release macos',
    );
  }
  // Refused rather than passed through. A build that carries on without the
  // keychain signs from whatever the machine happens to have, which is the one
  // outcome this command exists to prevent — and it would exit zero.
  if (!Platform.isMacOS) {
    throw ProjectException(
      'keychain exec needs macOS — `security` and Apple code signing exist '
      'nowhere else',
    );
  }
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) {
    throw ProjectException('HOME is not set, and the keychain lives under it');
  }

  // Certificates already in the environment win, and that is what makes both
  // shapes work: `keychain exec -- …` on its own, and `secrets exec -- keychain
  // exec -- …` when something else already loaded them. Which one happened is
  // printed rather than inferred.
  // Decided once, and applied to the child's environment whichever way that
  // environment was built. **This is the part that is easy to get wrong**: in
  // `secrets exec -- keychain exec -- build` the outer command has already put
  // every credential in place, and this command then takes the
  // certificates-already-present path and never calls `loadSecrets` at all. A
  // withholding that only happened during loading would achieve nothing there
  // while every line of it read as correct.
  final withheld = {
    'android.keystores',
    'android.play_service_account',
    if (apiKey == null) 'apple.api_keys',
  };

  LoadedSecrets? secrets;
  var environment = Map<String, String>.from(Platform.environment);
  var source = 'the environment';
  if (_certificatesIn(environment).isEmpty) {
    secrets = loadSecrets(
      repoRoot: repoRoot,
      secretsFile: secretsFile,
      apiKey: apiKey,
      // This command is macOS-gated and exists to sign Apple builds, so its
      // child is an Apple build and nothing else. Each of these is withheld for
      // its own reason:
      //
      //   android.keystores          the child cannot sign an Android artifact,
      //                              and requiring --keystore to pick between
      //                              two locked the first consumer out of an
      //                              Apple command entirely.
      //   android.play_service_account  the child cannot publish to Play, so
      //                              it has no use for it. Until 2.0.0 this was
      //                              the sharper argument of the three — the
      //                              credential was passed by *value*, and an
      //                              Xcode script build phase writes its whole
      //                              environment into the build log, which is
      //                              how it reached a public CI log in a
      //                              sibling project. It is a path now, like
      //                              everything else, so withholding it is
      //                              hygiene rather than the fix it once was.
      //   apple.api_keys             signing needs no App Store key, and a
      //                              build step may deliberately hold none.
      //                              --api-key asks for it.
      withhold: withheld,
    );
    environment = secrets.environment;
    source = secretsFile.path;
    for (final note in secrets.unresolved) {
      stderr.writeln('==> not chosen: $note');
    }
  }

  // Whatever built it, the withheld variables leave. Reported when one was
  // actually there, because a credential removed from a child's environment is
  // a thing the operator should see rather than deduce — and because seeing it
  // is what tells them the outer wrapper was handing it over.
  final removed = <String>[];
  for (final family in withheld) {
    for (final name in familyVariables[family]!) {
      if (environment.remove(name) != null) {
        removed.add(name);
      }
    }
  }
  if (removed.isNotEmpty) {
    stderr.writeln('==> removed from the environment: ${removed.join(', ')}');
  }

  try {
    final certificates = _certificatesIn(environment);
    if (certificates.isEmpty) {
      throw ProjectException(
        'no Apple signing certificate in $source.\n'
        'Add one under apple.certificates in the secrets file:\n'
        '    apple:\n'
        '      certificates:\n'
        '        distribution:\n'
        '          p12_base64: ...\n'
        '          password: ...',
      );
    }
    stderr.writeln(
      '==> ${certificates.map((c) => c.name).join(', ')} from $source',
    );

    _collect(home);

    final session = _create(
      home: home,
      certificates: certificates,
      expectTeam: expectTeam,
    );
    try {
      _installProfiles(
        session,
        home,
        environment,
        strictExpiry: strictExpiry,
        selected: profiles,
      );

      environment['APPLE_KEYCHAIN'] = session.path;
      stderr.writeln('==> APPLE_KEYCHAIN=${session.path}');
      stderr.writeln('==> running ${command.join(' ')} in $repoRoot');

      final process = await Process.start(
        command.first,
        command.skip(1).toList(),
        environment: environment,
        // **Without this the removals above do nothing.** `Process.start`
        // merges the map into the parent's environment by default, so a
        // variable deleted from the map is restored from this process's own —
        // which is precisely the case that matters, since under `secrets exec
        // -- keychain exec` the parent is the one holding the credential.
        //
        // Safe because [environment] began as a full copy of this process's
        // environment rather than an empty map, so PATH and the rest are in it.
        //
        // This was caught by reading the child's environment. The line above
        // saying `removed from the environment` printed correctly throughout,
        // because it reports what this process did to a map rather than what
        // the child received.
        includeParentEnvironment: false,
        workingDirectory: repoRoot,
        mode: ProcessStartMode.inheritStdio,
      );

      // Forwarded rather than acted on, so the child exits and the ordinary path
      // below does the cleanup. A Dart process gets none of this for free, where
      // a shell script's foreground child is signalled by the terminal and its
      // trap fires on the way out.
      final signals = [
        ProcessSignal.sigint.watch().listen(process.kill),
        ProcessSignal.sigterm.watch().listen(process.kill),
      ];
      try {
        // Awaited before the `finally` below runs: deleting the keychain out
        // from under a live codesign produces errors that explain nothing.
        return await process.exitCode;
      } finally {
        for (final subscription in signals) {
          await subscription.cancel();
        }
      }
    } finally {
      session.dispose();
    }
  } finally {
    secrets?.dispose();
  }
}

/// Every `APPLE_<name>_P12_PATH` that has its password beside it.
List<_Certificate> _certificatesIn(Map<String, String> environment) {
  final pattern = RegExp(r'^APPLE_([A-Z0-9_]+)_P12_PATH$');
  final found = <_Certificate>[];
  for (final key in environment.keys.toList()..sort()) {
    final match = pattern.firstMatch(key);
    if (match == null) {
      continue;
    }
    final path = environment[key]!;
    final password = environment['APPLE_${match.group(1)}_P12_PASSWORD'];
    // Half a credential is worse than none: importing with an empty password
    // fails in a way that reads as a corrupt certificate.
    if (password == null || path.isEmpty) {
      throw ProjectException(
        '$key is set but APPLE_${match.group(1)}_P12_PASSWORD is not',
      );
    }
    found.add((
      name: match.group(1)!.toLowerCase(),
      path: path,
      password: password,
    ));
  }
  return found;
}

/// Deletes keychains this tool left behind when a run was killed outright.
void _collect(String home) {
  final directory = Directory('$home/Library/Keychains');
  if (!directory.existsSync()) {
    return;
  }
  final stale = collectStaleKeychains(
    directory.listSync().map((e) => e.path),
    // `ps -p`, not `kill -0`. `kill -0` fails for a process owned by another
    // user as loudly as for one that does not exist, so it reads EPERM as dead
    // — and the consequence of getting that wrong is deleting a live build's
    // signing keychain out from under it, which surfaces as a signing key
    // vanishing mid-archive. `ps` answers the question actually being asked:
    // is there a process with this id.
    alive: (pid) =>
        Process.runSync('ps', ['-p', '$pid', '-o', 'pid=']).exitCode == 0,
    selfPid: pid,
  );
  for (final path in stale) {
    stderr.writeln('==> removing a keychain left by a killed run: $path');
    Process.runSync('security', ['delete-keychain', path]);
    final file = File(path);
    if (file.existsSync()) {
      file.deleteSync();
    }
  }
}

/// Files every `APPLE_PROFILE_<name>_PATH` where Xcode looks for it.
///
/// **[selected] is what decides whether an expired profile is fatal**, and the
/// distinction matters more than it looks. `secrets exec` materializes *every*
/// profile the file holds, by design — a project legitimately carries an App
/// Store profile and a Developer ID one, and this command cannot tell which the
/// wrapped build is about to use. Failing on any expired one would mean letting
/// a Developer ID profile lapse breaks every App Store release, naming a
/// profile that build never touches. That is the same class of unhelpful error
/// this expiry check exists to prevent, pointed the wrong way.
///
/// So: a profile the caller *named* is one this build needs, and an expired one
/// is fatal. A profile that merely turned up is warned about and skipped —
/// skipped rather than installed, because an expired profile is of no use to
/// anything and leaving it out keeps the failure, if there is one, about the
/// profile that is actually missing.
void _installProfiles(
  _Session session,
  String home,
  Map<String, String> environment, {
  required bool strictExpiry,
  required Set<String>? selected,
}) {
  final pattern = RegExp(r'^APPLE_PROFILE_([A-Z0-9_]+)_PATH$');
  final now = DateTime.now();
  final seen = <String>{};

  for (final key in environment.keys.toList()..sort()) {
    final match = pattern.firstMatch(key);
    if (match == null) {
      continue;
    }
    final instance = match.group(1)!.toLowerCase();
    seen.add(instance);
    if (selected != null && !selected.contains(instance)) {
      continue;
    }
    final source = environment[key]!;
    final facts = _readProfile(source);

    // Reported at the cheapest possible moment either way. An expired profile
    // fails inside codesign with an error that does not contain the word
    // expired, and this is the difference between a sentence and an afternoon.
    final days = facts.daysLeft(now);
    switch (decideProfile(
      daysLeft: days,
      named: selected != null,
      strictExpiry: strictExpiry,
    )) {
      case ProfileDecision.failExpired:
        throw ProjectException(
          '${facts.name} expired ${-days!} days ago — renew it and re-encrypt '
          'it into the secrets file',
        );
      case ProfileDecision.skipExpired:
        // Skipped rather than installed: an expired profile is of no use to
        // anything, and leaving it out keeps any resulting failure about the
        // profile that is actually missing.
        stderr.writeln(
          '==> ${facts.name} expired ${-days!} days ago — skipped. Name it '
          'with --profile $instance if this build needs it.',
        );
        continue;
      case ProfileDecision.failExpiringSoon:
        throw ProjectException(
          '${facts.name} expires in $days days, and --strict-expiry was given',
        );
      case ProfileDecision.install:
        // Carrying profiles in secrets is what makes this worth saying at all —
        // automatic signing was the thing quietly renewing them.
        if (days != null && days <= _soonInDays) {
          stderr.writeln('==> ${facts.name} expires in $days days');
        }
    }

    final directory = Directory('$home/${facts.platform.directory}')
      ..createSync(recursive: true);
    final target =
        '${directory.path}/${facts.uuid}.${facts.platform.extension}';

    // A profile that was already there is left alone, and is not removed on the
    // way out. Clobbering one Xcode downloaded and then deleting it takes away
    // something this run did not provide — one of the implementations this
    // replaces does exactly that.
    if (File(target).existsSync()) {
      stderr.writeln('==> ${facts.name} is already installed');
      continue;
    }
    File(source).copySync(target);
    session.installedProfiles.add(target);
    stderr.writeln('==> ${facts.name} -> ${facts.uuid}');
  }

  // A named profile that is not there is refused rather than ignored. Carrying
  // on would install nothing and let the build discover it as "no profile
  // matched", which names neither the profile nor the typo.
  final missing = selected?.difference(seen) ?? const <String>{};
  if (missing.isNotEmpty) {
    throw ProjectException(
      '--profile named ${missing.join(', ')}, which '
      '${missing.length == 1 ? 'is' : 'are'} not in the secrets file.\n'
      '    it holds: ${seen.isEmpty ? 'no profiles at all' : (seen.toList()..sort()).join(', ')}',
    );
  }
}
