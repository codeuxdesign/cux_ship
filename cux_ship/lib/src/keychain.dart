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
import 'dart:math';

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
///
/// [failed] carries why a key is missing from [extracted], keyed the same way.
///
/// Without it every reason a key is absent reads identically — the profile
/// genuinely lacks it, `plutil` is not the version we expect, the plist would
/// not parse — and the message names the one that is merely most likely. That
/// cost a maintainer of a consuming project an afternoon bisecting two macOS
/// versions to learn that `Platform` was present all along and the extraction
/// had failed.
ProfileFacts profileFactsFrom(
  Map<String, String> extracted,
  String at, {
  Map<String, String> failed = const {},
}) {
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
    final why = platforms.isNotEmpty
        ? 'Platform was ${platforms.join(', ')}'
        : failed['Platform'] != null
        ? 'reading Platform failed — ${failed['Platform']}'
        : 'Platform was absent';
    throw ProjectException('$at does not say which platform it is for — $why');
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
/// **`Platform` is a set, not a scalar**, and `plutil -extract Platform raw`
/// prints an array's *element count* — a modern iOS profile says
/// `[iOS, xrOS, visionOS]` and so prints `3`, a macOS one says `[OSX]` and
/// prints `1`. Neither is a platform name, and a first version read those
/// numbers and refused every real profile on both platforms. So `raw` is out.
///
/// **`json` is out too, and that was measured rather than reasoned.** On
/// `macos-15`, `plutil -extract Platform json` exits 1 with empty stderr —
/// not an absent key, not a malformed profile, a subprocess that fails and
/// says nothing. `-extract … json` has now failed twice on that runner: here,
/// on an array of *strings* which JSON represents perfectly well, and on
/// `DeveloperCertificates`, an array of `<data>` which it refuses outright.
/// Two independent failures of one format points at the format.
///
/// So `xml1`, which works on both macOS versions and needs no more parsing
/// than a `<string>` scan. Both forms are accepted here: the plist is what the
/// extraction now asks for, and the JSON array is what a hand-written fixture
/// reaches for and what older callers produced.
Set<String> _platformsFrom(String? value, String at) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) {
    return const {};
  }

  // The plist form: <array><string>iOS</string>…</array>.
  if (text.contains('<string>')) {
    return {
      for (final match in RegExp(
        r'<string>([\s\S]*?)</string>',
      ).allMatches(text))
        match.group(1)!.trim().toLowerCase(),
    }..removeWhere((p) => p.isEmpty);
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
      'than its contents, so it is extracted as xml1.',
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

/// Whole days until the `notAfter` in an `openssl x509 -enddate` line.
///
/// openssl prints `notAfter=Aug 10 11:00:16 2027 GMT`, which no Dart date
/// parser accepts — hence the month table. Null when the line is not that
/// shape, because a certificate whose date cannot be read must not stop a
/// build over it.
int? daysUntilNotAfter(String enddateLine, DateTime now) {
  final match = RegExp(
    r'notAfter=(\w{3}) +(\d{1,2}) (\d{2}):(\d{2}):(\d{2}) (\d{4})',
  ).firstMatch(enddateLine);
  if (match == null) {
    return null;
  }
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
  final month = months[match.group(1)];
  if (month == null) {
    return null;
  }
  return DateTime.utc(
    int.parse(match.group(6)!),
    month,
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
    int.parse(match.group(4)!),
    int.parse(match.group(5)!),
  ).difference(now).inDays;
}

/// How much life a certificate has left, in the words the developer-account
/// audit uses.
///
/// Same threshold and same phrasing as `appstore/signing.dart`, so the two
/// commands never disagree about what "soon" means.
String certificateExpiryNote(int? days) {
  if (days == null) {
    return '';
  }
  if (days < 0) {
    return '  ** EXPIRED ${-days}d ago **';
  }
  if (days <= _soonInDays) {
    return '  ** expires in ${days}d **';
  }
  return '  (${days}d left)';
}

/// Reads `notAfter` out of a .p12 without putting its password on a command
/// line, where `ps` would show it. The `-legacy` attempt comes first because
/// OpenSSL 3 refuses the older PKCS#12 encryption Apple still hands out, and
/// LibreSSL — which is what `openssl` is on a stock macOS — does not know the
/// flag at all.
String readCertificateEnddate(String p12Path, String password) {
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
  return result.stdout as String;
}

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

    // Every certificate's remaining life, reported at import.
    //
    // **The profile check cannot cover this.** A profile carries its own
    // ExpirationDate and a certificate carries `notAfter`; they are independent
    // dates, and it is the certificate that is capped and shared across the
    // team. A profile good for a year that embeds a certificate dying next week
    // passes every check here and then fails inside codesign — and a project on
    // automatic signing has no profile to check at all, which is how a sibling
    // project came within twenty days of a dead release path with nothing in
    // its build saying so.
    //
    // A warning, never a refusal: a certificate with a fortnight left must not
    // stop a build that is going to succeed. That is the reasoning
    // `decideProfile` already applies to a profile nobody named.
    for (final certificate in certificates) {
      final days = daysUntilNotAfter(
        readCertificateEnddate(certificate.path, certificate.password),
        DateTime.now().toUtc(),
      );
      final note = certificateExpiryNote(days);
      if (note.isNotEmpty) {
        stderr.writeln('==> ${certificate.name}$note');
      }
    }

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
/// A profile's name, expiry, and the fingerprint of every certificate it
/// embeds — the last being what `secrets check` cross-checks against the
/// certificates the file actually holds.
///
/// `DeveloperCertificates` is an array of DER blobs. Their fingerprints are
/// taken with openssl rather than hashed here, so both sides of the comparison
/// are produced by the same tool and cannot disagree about encoding.
ProfileInspection inspectProfileForCheck(String path) {
  final facts = _readProfile(path);
  return ProfileInspection(
    name: facts.name,
    expires: facts.expires,
    certificateFingerprints: _embeddedCertificateFingerprints(path),
  );
}

List<String> _embeddedCertificateFingerprints(String path) {
  final decoded = Process.runSync('security', [
    'cms',
    '-D',
    '-i',
    path,
  ], stdoutEncoding: null);
  if (decoded.exitCode != 0) {
    throw ProjectException(
      'could not decode $path — security cms exited ${decoded.exitCode}',
    );
  }
  final work = Directory.systemTemp.createTempSync('cux_ship_profile_certs');
  try {
    final plist = File('${work.path}/p.plist')
      ..writeAsBytesSync(decoded.stdout as List<int>);
    // `xml1`, not `json`. The certificates are a `<data>` array, and plutil
    // refuses that for JSON — "Invalid object in plist for JSON format" — so
    // the obvious spelling fails on every real profile. It cost nothing to find
    // because it was measured against a production profile; it would have cost
    // a great deal to find in a report that had quietly checked nothing.
    //
    // `raw` is not the alternative: on an array it prints the element count,
    // which parses fine and means something else entirely.
    final extracted = Process.runSync('plutil', [
      '-extract',
      'DeveloperCertificates',
      'xml1',
      '-o',
      '-',
      plist.path,
    ]);
    if (extracted.exitCode != 0) {
      throw ProjectException(
        'could not read the certificates out of $path — '
        'plutil -extract DeveloperCertificates xml1 exited '
        '${extracted.exitCode}: ${(extracted.stderr as String).trim()}',
      );
    }
    // Each <data> block is base64 with the line breaks plutil puts in.
    final blobs = RegExp(r'<data>([\s\S]*?)</data>')
        .allMatches(extracted.stdout as String)
        .map((m) => m.group(1)!.replaceAll(RegExp(r'\s'), ''))
        .where((s) => s.isNotEmpty)
        .toList();
    final fingerprints = <String>[];
    for (var i = 0; i < blobs.length; i++) {
      final der = File('${work.path}/cert$i.der')
        ..writeAsBytesSync(base64.decode(blobs[i]));
      final print = Process.runSync('openssl', [
        'x509',
        '-inform',
        'DER',
        '-in',
        der.path,
        '-noout',
        '-fingerprint',
        '-sha256',
      ]);
      final line = (print.stdout as String).trim();
      final value = line.split('=').last.replaceAll(':', '').toUpperCase();
      if (value.isNotEmpty) {
        fingerprints.add(value);
      }
    }
    return fingerprints;
  } finally {
    work.deleteSync(recursive: true);
  }
}

/// SHA-256 of the certificate inside a .p12, in the same shape as the profile
/// side above, so the two can be compared directly.
String? fingerprintStoredCertificate(String p12Path, String password) {
  final result = Process.runSync(
    'sh',
    [
      '-c',
      '{ openssl pkcs12 -in "\$1" -passin env:CUX_P12_PASSWORD -nokeys -clcerts '
          '-legacy 2>/dev/null '
          '|| openssl pkcs12 -in "\$1" -passin env:CUX_P12_PASSWORD -nokeys '
          '-clcerts 2>/dev/null; } '
          '| openssl x509 -noout -fingerprint -sha256 2>/dev/null',
      'sh',
      p12Path,
    ],
    environment: {'CUX_P12_PASSWORD': password},
  );
  final line = (result.stdout as String).trim();
  if (!line.contains('=')) {
    return null;
  }
  final value = line.split('=').last.replaceAll(':', '').toUpperCase();
  return value.isEmpty ? null : value;
}

/// A `.p12` built out of the login keychain, and the password that opens it.
///
/// The caller owns [work] and must delete it — the file inside is a signing
/// identity in plaintext.
class ExportedIdentity {
  const ExportedIdentity({
    required this.p12Path,
    required this.password,
    required this.work,
    required this.notes,
  });

  final String p12Path;
  final String password;
  final Directory work;

  /// Subject and expiry, read back out of the finished file.
  final List<String> notes;
}

/// Exports a signing identity from a keychain into a fresh `.p12`.
///
/// The onboarding path: it is how a certificate reaches the secrets file when
/// there is no `.p12` in hand, only an identity macOS is already holding.
/// Ported from a shell version in a sibling project, and what makes it worth
/// porting rather than reimplementing is three traps it already encodes.
///
/// **Pair on `localKeyID`, never on `friendlyName`.** openssl prints
/// `localKeyID` on a certificate bag *and* on its matching private key bag, and
/// it is the only attribute the two reliably share. `friendlyName` looks like
/// it and is not: macOS labels the certificate with the certificate's name and
/// the key with whatever the key was imported as — usually the account holder's
/// name. Filtering on it matches the certificate, misses the key, and produces
/// a `.p12` that imports without complaint and cannot sign. That is not
/// hypothetical; it is what the first version of the shell script did.
///
/// **Match the kind as well as the team.** An Apple *Development* certificate
/// carries the same `OU=`, so team alone can quietly export the development
/// identity and produce builds the App Store refuses.
///
/// **Check expiry on every candidate.** A keychain accumulates every
/// distribution certificate a team has ever held and never sheds the expired
/// ones, so "the certificate for this team" is usually several.
///
/// The password is generated rather than accepted. Nothing has to type it, and
/// a password a human picks is one they reuse.
ExportedIdentity exportIdentityFromKeychain({
  required String team,
  required String certificateKind,
  String? keychain,
}) {
  final work = Directory.systemTemp.createTempSync('cux_ship_export');
  Process.runSync('chmod', ['700', work.path]);
  try {
    final transit = _randomPassword();
    final password = _randomPassword();
    final all = '${work.path}/all.p12';

    // `security` has no way to take this from the environment, so the transit
    // password is an argument and briefly visible to `ps`. It protects a file
    // in a 0700 directory for the length of one openssl call and is discarded;
    // the password that matters — the one stored — never reaches a command
    // line.
    final exported = Process.runSync('security', [
      'export',
      '-k',
      keychain ?? _loginKeychain(),
      '-t',
      'identities',
      '-f',
      'pkcs12',
      '-P',
      transit,
      '-o',
      all,
    ]);
    if (exported.exitCode != 0) {
      throw ProjectException(
        'the keychain export was cancelled or failed — macOS asks for '
        'permission, and it has to be granted.\n'
        '${(exported.stderr as String).trim()}',
      );
    }

    // `-legacy`: security(1) writes RC2/3DES, which OpenSSL 3 will not read
    // from its default provider.
    final pem = _openssl(
      [
        'pkcs12',
        '-in',
        all,
        '-passin',
        'env:CUX_TRANSIT_PASSWORD',
        '-nodes',
        '-legacy',
      ],
      environment: {'CUX_TRANSIT_PASSWORD': transit},
    );
    File(all).deleteSync();
    if (pem == null) {
      throw ProjectException('could not read the exported keychain');
    }

    final bags = parsePemBags(pem);
    final candidates = bags
        .where(
          (b) =>
              b.isCertificate &&
              b.localKeyId != null &&
              b.body.contains(team) &&
              b.body.contains(certificateKind),
        )
        .toList();
    if (candidates.isEmpty) {
      throw ProjectException(
        'no "$certificateKind" certificate for team $team in that keychain.\n'
        '    What it does hold:\n${_identitiesIn(keychain)}',
      );
    }

    // **The longest-lived, not the first still in date.** The shell original
    // this was ported from says "any currently-valid certificate for the team
    // can sign, so the first one still in date is as good as any other — there
    // is nothing to rank beyond not expired", and that sentence is wrong.
    //
    // It was proved wrong by running it. A keychain holding a certificate with
    // twenty days left beside its freshly issued replacement passes both on
    // `-checkend 0`, and "first" picked the one being rotated away from. It
    // then reported success, and would have signed correctly until the old
    // certificate lapsed — with the rotation apparently done. "Not expired" and
    // "usable for a release" are not the same predicate, and the difference is
    // invisible on the day.
    //
    // Ranking by `notAfter` is stable under exactly the thing that should
    // change the answer. Which one was taken, and which were passed over, is
    // printed rather than decided quietly.
    PemBag? chosen;
    DateTime? chosenEnds;
    final expired = <String>[];
    final alsoValid = <String>[];
    for (final candidate in candidates) {
      final certFile = File('${work.path}/cand.pem')
        ..writeAsStringSync(candidate.certificatePem);
      final ends = _certificateEnds(certFile.path);
      if (ends == null) {
        continue;
      }
      if (!ends.isAfter(DateTime.now().toUtc())) {
        expired.add(_day(ends));
        continue;
      }
      if (chosenEnds == null || ends.isAfter(chosenEnds)) {
        if (chosenEnds != null) {
          alsoValid.add(_day(chosenEnds));
        }
        chosen = candidate;
        chosenEnds = ends;
      } else {
        alsoValid.add(_day(ends));
      }
    }
    if (chosen == null) {
      throw ProjectException(
        'every "$certificateKind" certificate for $team in that keychain has '
        'expired (${expired.length} of them: ${expired.join('; ')}).\n'
        '    Create a new one at developer.apple.com > Certificates, download '
        'it, open it so it\n'
        '    lands in the keychain beside its private key, then run this '
        'again.',
      );
    }

    // The pair: every bag carrying the chosen certificate's localKeyID.
    final pair = bags.where((b) => b.localKeyId == chosen!.localKeyId).toList();
    final certificates = pair.where((b) => b.isCertificate).length;
    final keys = pair.where((b) => b.isPrivateKey).length;
    // Both halves have to survive. One that kept only the certificate builds a
    // .p12 that imports without complaint and then cannot sign anything, which
    // is the whole reason this pairs on localKeyID.
    if (certificates < 1) {
      throw ProjectException('no certificate survived the filter for $team');
    }
    if (keys < 1) {
      throw ProjectException(
        'found the certificate for $team but not its private key.\n'
        '    The keychain holds the certificate without the key that signs for '
        'it, so nothing\n'
        '    here can sign. Either it was imported from a .cer rather than a '
        '.p12, or the key\n'
        '    lives in a different keychain — try --keychain.',
      );
    }

    final pairFile = File('${work.path}/dist.pem')
      ..writeAsStringSync(pair.map((b) => b.body).join());
    final p12Path = '${work.path}/dist.p12';
    final built = Process.runSync(
      'openssl',
      [
        'pkcs12',
        '-export',
        '-legacy',
        '-in',
        pairFile.path,
        '-passout',
        'env:CUX_P12_PASSWORD',
        '-name',
        '$certificateKind ($team)',
        '-out',
        p12Path,
      ],
      environment: {'CUX_P12_PASSWORD': password},
    );
    pairFile.deleteSync();
    if (built.exitCode != 0) {
      throw ProjectException(
        'could not build the .p12: ${(built.stderr as String).trim()}',
      );
    }

    // Read back the way a runner will, so a broken file is found here rather
    // than inside a fifteen-minute archive.
    final facts = readPkcs12Facts(p12Path, password);
    final hasKey = _openssl(
      [
        'pkcs12',
        '-in',
        p12Path,
        '-passin',
        'env:CUX_P12_PASSWORD',
        '-nocerts',
        '-nodes',
        '-legacy',
      ],
      environment: {'CUX_P12_PASSWORD': password},
    )?.contains('PRIVATE KEY');
    if (hasKey != true) {
      throw ProjectException('the .p12 this produced carries no private key');
    }

    return ExportedIdentity(
      p12Path: p12Path,
      password: password,
      work: work,
      notes: [
        ...facts,
        'exported from ${keychain ?? 'the login keychain'}',
        if (expired.isNotEmpty)
          'skipped ${expired.length} expired certificate(s) for the same team',
        // Named rather than counted. With two in-date certificates the choice
        // is the whole question, and "one other was also valid" does not let
        // anyone check it was the right one.
        if (alsoValid.isNotEmpty)
          'passed over ${alsoValid.length} shorter-lived certificate(s) '
              'for the same team, expiring ${alsoValid.join(', ')}',
      ],
    );
  } catch (_) {
    work.deleteSync(recursive: true);
    rethrow;
  }
}

/// `notAfter` of a PEM certificate, or null when openssl would not say.
DateTime? _certificateEnds(String pemPath) {
  final result = Process.runSync('openssl', [
    'x509',
    '-in',
    pemPath,
    '-noout',
    '-enddate',
  ]);
  if (result.exitCode != 0) {
    return null;
  }
  final text = (result.stdout as String).trim();
  if (!text.startsWith('notAfter=')) {
    return null;
  }
  return parseOpensslDate(text.substring('notAfter='.length).trim());
}

String _day(DateTime value) => value.toIso8601String().split('T').first;

String _loginKeychain() {
  final home = Platform.environment['HOME'];
  return '$home/Library/Keychains/login.keychain-db';
}

String _identitiesIn(String? keychain) {
  final result = Process.runSync('security', [
    'find-identity',
    '-v',
    '-p',
    'codesigning',
    ?keychain,
  ]);
  final text = (result.stdout as String).trim();
  return text.isEmpty
      ? '      (none)'
      : text.split('\n').map((l) => '      ${l.trim()}').join('\n');
}

/// 24 bytes from the platform's secure source, base64. Never typed, never
/// reused, and never on a command line.
String _randomPassword() {
  final random = Random.secure();
  return base64.encode(List<int>.generate(24, (_) => random.nextInt(256)));
}

String? _openssl(List<String> args, {Map<String, String>? environment}) {
  final result = Process.runSync('openssl', args, environment: environment);
  if (result.exitCode != 0) {
    return null;
  }
  return result.stdout as String;
}

/// One PEM bag as openssl prints it: the attribute block plus the object.
///
/// Public because the pairing rule it encodes — match on `localKeyID`, never on
/// `friendlyName` — is the whole reason this code exists, and a rule the tests
/// cannot reach is one that gets quietly rewritten.
class PemBag {
  PemBag(this.body, this.localKeyId);

  final String body;
  final String? localKeyId;

  bool get isCertificate => body.contains('-----BEGIN CERTIFICATE-----');
  bool get isPrivateKey =>
      RegExp(r'-----BEGIN( [A-Z0-9]+)? PRIVATE KEY-----').hasMatch(body);

  String get certificatePem {
    final match = RegExp(
      r'-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----',
    ).firstMatch(body);
    return match?.group(0) ?? '';
  }
}

/// Splits openssl's `-nodes` output into bags, each ending at its `-----END`.
List<PemBag> parsePemBags(String pem) {
  final bags = <PemBag>[];
  var current = StringBuffer();
  String? localKeyId;
  for (final line in pem.split('\n')) {
    if (line.startsWith('Bag Attributes')) {
      current = StringBuffer();
      localKeyId = null;
    }
    current.writeln(line);
    final idIndex = line.indexOf('localKeyID:');
    if (idIndex >= 0) {
      localKeyId = line.substring(idIndex + 'localKeyID:'.length).trim();
    }
    if (line.startsWith('-----END')) {
      bags.add(PemBag(current.toString(), localKeyId));
      current = StringBuffer();
      localKeyId = null;
    }
  }
  return bags;
}

/// A profile's own account of itself, for `secrets add profile` to print back.
///
/// Lives here rather than in `secrets_add.dart` because reading it needs
/// `security cms`, and `keychain.dart` is the file that is allowed to know a
/// Mac exists — `secrets` is the lower layer and imports nothing from here.
/// Passed in as a callback so the dependency points the right way.
///
/// Reporting, not validation: whether the file *is* a profile was already
/// settled by `identifyArtifact`, which needs no Mac and no subprocess. So this
/// failing costs a nicer message, not a wrong write.
List<String> describeProfileForAdd(String path) {
  final facts = _readProfile(path);
  return [
    '${facts.name} — ${facts.platform.name}, uuid ${facts.uuid}',
    if (facts.expires != null)
      'expires ${facts.expires!.toIso8601String().split('T').first}'
          '${certificateExpiryNote(facts.daysLeft(DateTime.now()))}',
  ];
}

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
    // `raw` for the scalars, `xml1` for `Platform` — because `raw` on an array
    // prints its element count, and `json` fails on `macos-15`: exit 1, empty
    // stderr, on an array of strings JSON represents perfectly well. That is
    // the second `-extract … json` failure on that runner, after
    // `DeveloperCertificates`, so the format is the common factor rather than
    // the field. `xml1` works on both macOS versions.
    //
    // The scalars stay on `raw`, which has never failed and is unambiguous for
    // a scalar. Only `json` has broken.
    const format = {
      'UUID': 'raw',
      'Name': 'raw',
      'Platform': 'xml1',
      'ExpirationDate': 'raw',
    };
    final extracted = <String, String>{};
    // A non-zero exit is kept rather than dropped. It used to be indistinguishable
    // from the key being absent, so a `plutil` that could not do what was asked
    // reported itself as a profile that did not say which platform it was for —
    // a true-looking statement about the wrong thing.
    final failed = <String, String>{};
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
      } else {
        failed[entry.key] =
            'plutil -extract ${entry.key} ${entry.value} exited '
            '${result.exitCode}: ${(result.stderr as String).trim()}';
      }
    }
    return profileFactsFrom(extracted, path, failed: failed);
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
  List<String> only = const [],
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
  // **The default is nothing.** The child gets the keychain this command makes
  // and whatever `--only` names, because what a build script consumes is
  // knowledge only the call site has: consumption happens below this command's
  // argv, sometimes four layers down inside a function, sometimes with the
  // variable name in a `printf` format string. Three attempts at a useful
  // default each needed more structure than the last, because a default has to
  // satisfy every consumer and is therefore a union — and a union is wrong for
  // each of them individually. See docs/design/only-selector.md.
  //
  // Read without decrypting: `env`, `kind` and the instance names are cleartext
  // by design, which is what lets the nested case filter an environment it did
  // not place and never called `loadSecrets` for.
  // `--profile` is allowed alongside `--only` here: they are different axes.
  // One decides which profiles Xcode gets installed, the other what the child's
  // environment holds — but naming a profile in `--only` is still refused,
  // because that is the conflation the two flags invite.
  checkOnlyCombination(only: only, apiKey: apiKey);

  final byCredential = variablesByCredential(secretsFile);

  // **Resolved against what this process can actually deliver, not against the
  // file.** They are the same thing when this command loads the secrets itself.
  // They differ under `secrets exec --only x -- keychain exec --only y`: the
  // outer has already placed and filtered, this command takes the
  // certificates-already-present branch and never decrypts, so the only
  // credentials it can hand on are the ones whose variables actually arrived.
  //
  // Resolving against the file there would accept a selector for something the
  // outer wrapper stripped, and the build would die four layers down with the
  // variable simply absent — which is the failure this whole flag exists to
  // move forward to the call site.
  final inherited = Platform.environment;
  final loadsItself = _certificatesIn(
    Map<String, String>.from(inherited),
  ).isEmpty;
  final deliverable = loadsItself
      ? byCredential.keys.toSet()
      : byCredential.entries
            .where(
              (e) => e.value.isNotEmpty && e.value.every(inherited.containsKey),
            )
            .map((e) => e.key)
            .toSet();

  final selection = resolveOnly(
    only,
    available: deliverable,
    at: loadsItself
        ? secretsFile.path
        : 'the environment this command received',
  );
  for (final family in selection.emptyFamilies) {
    stderr.writeln(
      '==> family "$family" selected, but there are no $family in '
      '${secretsFile.path}',
    );
  }
  // **This command's own inputs are not in `--only`'s domain.** It imports
  // certificates into a keychain and writes profiles where Xcode looks, both
  // before any child exists — neither reaches the child as a value, and neither
  // is what the flag exists to control. Filtering them starves the command of
  // the thing it is for: with an empty selection it could not find its own
  // certificate, and with the certificate named it could not find its profile.
  //
  // So they are always loaded, and the child filter below takes them back out
  // again unless the caller named them.
  final ownInputs = byCredential.keys
      .where(
        (p) =>
            p.startsWith('apple.certificates.') ||
            p.startsWith('apple.profiles.'),
      )
      .toSet();
  // `--api-key` is a selection too, in the one place it is spelled differently.
  // Without this it loaded the key and the strip below removed it again, so the
  // flag documented as *the* way to give a child an App Store credential was a
  // silent no-op — placement and visibility disagreeing, which is the same
  // family of bug as the two already fixed here.
  final selectedPaths = {
    ...selection.paths,
    if (apiKey != null)
      ...byCredential.keys.where((p) => p == 'apple.api_keys.$apiKey'),
  };
  final selectedVariables = {
    for (final path in selectedPaths) ...byCredential[path]!,
  };
  final everyCredentialVariable = {
    for (final variables in byCredential.values) ...variables,
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
      only: {...selectedPaths, ...ownInputs},
    );
    environment = secrets.environment;
    source = secretsFile.path;
    for (final note in secrets.unresolved) {
      stderr.writeln('==> not chosen: $note');
    }
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

    // The passwords have done their work — `_create` imported the certificates
    // with them, and nothing downstream of this point reads one. They are not a
    // withholdable family, because this command *needs* them; they are a
    // credential whose useful life ends here.
    //
    // Dropping them matters because they are passed by value. An xcode script
    // build phase writes its whole environment into the build log, and in a
    // public repository those logs are public — which is how a sibling project
    // published three p12 passwords in every ios and macos release for a month.
    // A consumer can unset them by hand, but only one who knows to; doing it
    // here means the next build script inherits the protection.
    final spent = environment.keys
        .where((k) => k.startsWith('APPLE_') && k.endsWith('_P12_PASSWORD'))
        .toList();
    for (final key in spent) {
      environment.remove(key);
    }
    if (spent.isNotEmpty) {
      stderr.writeln(
        '==> imported, so withheld from the child: '
        '${spent.join(', ')}',
      );
    }

    try {
      _installProfiles(
        session,
        home,
        environment,
        strictExpiry: strictExpiry,
        selected: profiles,
      );

      // **Now**, and not before: this command reads certificates and profiles
      // out of the environment to do its own work, so the strip has to come
      // after that work rather than before it.
      //
      // Removed rather than merely not placed, and that distinction is the
      // whole of it. Under `secrets exec -- keychain exec -- build` the outer
      // command has already put everything in place, so a filter that only
      // declined to place would achieve nothing while reading as correct at
      // every line. That is what 1.9.0 got wrong and 1.9.1 fixed.
      final removed = <String>[];
      for (final name in everyCredentialVariable.difference(
        selectedVariables,
      )) {
        if (environment.remove(name) != null) {
          removed.add(name);
        }
      }
      // The master key to the whole file, and not a credential *in* it — so no
      // selector can name it and no default covers it. Stripped
      // unconditionally: nothing outside cux_ship reads it, and the one
      // composition that did — a nested `secrets exec` inside this child —
      // is replaced by running the two as siblings. A child that could decrypt
      // the file would make the guarantee this command exists for hollow,
      // since a key to the file that holds `apple.api_keys` can mint the very
      // credential the archive is meant not to hold.
      for (final name in const ['SOPS_AGE_KEY', 'SOPS_AGE_KEY_FILE']) {
        if (environment.remove(name) != null) {
          removed.add(name);
        }
      }
      if (removed.isNotEmpty) {
        removed.sort();
        stderr.writeln('==> not passed to the child: ${removed.join(', ')}');
      }

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
