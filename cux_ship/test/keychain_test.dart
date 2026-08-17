// SPDX-License-Identifier: Apache-2.0
//
// The half of `keychain exec` that can be tested without a Mac, a keychain or a
// real certificate. What is left over — the `security` calls themselves — is
// verified by signing something with a generated certificate, which is a
// different kind of check and does not belong in a unit suite that mutates
// nothing.

import 'dart:io';

import 'package:cux_ship/src/keychain.dart';
import 'package:cux_ship/src/project.dart';
import 'package:test/test.dart';

void main() {
  _expiryTests();
  group('profileFactsFrom', () {
    test('reads an iOS profile', () {
      final facts = profileFactsFrom({
        'UUID': 'D2E7A1B4-0000-4E5F-9A3C-112233445566',
        'Name': 'How It Went App Store',
        'Platform': '["iOS"]',
        'ExpirationDate': '2026-11-04T09:12:33Z',
      }, 'ios.mobileprovision');

      expect(facts.uuid, 'D2E7A1B4-0000-4E5F-9A3C-112233445566');
      expect(facts.name, 'How It Went App Store');
      expect(facts.platform, ProfilePlatform.ios);
      expect(facts.expires, DateTime.utc(2026, 11, 4, 9, 12, 33));
    });

    // The whole reason the platform is read from the profile rather than taken
    // from its filename: Xcode looks in two different directories and will not
    // match one filed under the other.
    test('reads a macOS profile, which says OSX', () {
      final facts = profileFactsFrom({
        'UUID': 'ABC-123',
        'Platform': '["OSX"]',
      }, 'macos.provisionprofile');

      expect(facts.platform, ProfilePlatform.macos);
      expect(facts.platform.extension, 'provisionprofile');
      expect(
        facts.platform.directory,
        'Library/MobileDevice/Provisioning Profiles',
      );
    });

    test('the two platforms disagree about where and what', () {
      expect(ProfilePlatform.ios.extension, 'mobileprovision');
      expect(
        ProfilePlatform.ios.directory,
        'Library/Developer/Xcode/UserData/Provisioning Profiles',
      );
    });

    // Refused rather than defaulted to iOS. Guessing files a macOS profile
    // where Xcode does not look, and the build then fails inside codesign
    // saying no profile matched — which never mentions the filing.
    test('refuses a platform it does not know instead of guessing', () {
      expect(
        () => profileFactsFrom({
          'UUID': 'ABC-123',
          'Platform': '["watchOS"]',
        }, 'odd.mobileprovision'),
        throwsA(
          isA<ProjectException>().having(
            (e) => e.message,
            'message',
            contains('watchos'),
          ),
        ),
      );
    });

    test('refuses a profile with no Platform at all', () {
      expect(
        () => profileFactsFrom({'UUID': 'ABC-123'}, 'bare.mobileprovision'),
        throwsA(isA<ProjectException>()),
      );
    });

    // The message is the feature. A profile that lacks Platform and a plutil
    // that could not read it are different problems with different fixes, and
    // reporting the first for the second sent a maintainer bisecting macOS
    // versions to explain a profile that turned out to be fine.
    test('says so when reading Platform failed, rather than "absent"', () {
      expect(
        () => profileFactsFrom(
          {'UUID': 'ABC-123'},
          'ios.mobileprovision',
          failed: {'Platform': 'plutil -extract Platform json exited 1: boom'},
        ),
        throwsA(
          isA<ProjectException>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('reading Platform failed'), contains('boom')),
          ),
        ),
      );
    });

    test('still says "absent" when nothing failed', () {
      expect(
        () => profileFactsFrom({'UUID': 'ABC-123'}, 'bare.mobileprovision'),
        throwsA(
          isA<ProjectException>().having(
            (e) => e.toString(),
            'message',
            contains('Platform was absent'),
          ),
        ),
      );
    });

    test('refuses one with no UUID, since the UUID is the filename', () {
      expect(
        () => profileFactsFrom({'Platform': '["iOS"]'}, 'x.mobileprovision'),
        throwsA(isA<ProjectException>()),
      );
    });

    // The real values, from four production profiles. A modern iOS profile
    // names three platforms, which is why membership is tested rather than the
    // first element — Apple reordering the array must not move the file.
    test('a real iOS profile names three platforms and is still iOS', () {
      expect(
        profileFactsFrom({
          'UUID': 'ABC-123',
          'Platform': '["iOS","xrOS","visionOS"]',
        }, 'ios_appstore.profile').platform,
        ProfilePlatform.ios,
      );
    });

    // What the extraction now actually produces. `json` was dropped after
    // `plutil -extract Platform json` was measured exiting 1 with empty stderr
    // on a macos-15 runner — the second failure of `-extract … json` on that
    // OS, after `DeveloperCertificates`, which points at the format rather than
    // the field. These are the plist forms of the two cases above.
    test('the xml1 form the extraction now asks for is understood', () {
      expect(
        profileFactsFrom({
          'UUID': 'ABC-123',
          'Platform':
              '<array>\n\t<string>iOS</string>\n\t<string>xrOS</string>\n'
              '\t<string>visionOS</string>\n</array>',
        }, 'ios_appstore.profile').platform,
        ProfilePlatform.ios,
      );
      expect(
        profileFactsFrom({
          'UUID': 'ABC-123',
          'Platform': '<array>\n\t<string>OSX</string>\n</array>',
        }, 'macos.profile').platform,
        ProfilePlatform.macos,
      );
    });

    // The bug that broke every profile on both platforms: `plutil -extract
    // Platform raw` prints an array's *element count*, so an iOS profile came
    // back as "3" and a macOS one as "1". Refused with the reason rather than
    // split into a set containing "3", which would have been indistinguishable
    // from a platform nobody has heard of.
    test('an element count is refused, and says why', () {
      for (final counted in ['3', '1']) {
        expect(
          () => profileFactsFrom({
            'UUID': 'ABC-123',
            'Platform': counted,
          }, 'counted.profile'),
          throwsA(
            isA<ProjectException>().having(
              (e) => e.message,
              'message',
              contains('element count'),
            ),
          ),
          reason: 'Platform=$counted',
        );
      }
    });

    test('the expiry format real profiles use parses', () {
      // Verbatim from two production profiles. Parsing failure would be silent
      // — an unparseable date reads as "no expiry" — so this is pinned against
      // real input rather than against a stamp invented here.
      for (final stamp in ['2027-08-10T11:00:16Z', '2044-08-05T18:27:33Z']) {
        expect(
          profileFactsFrom({
            'UUID': 'ABC-123',
            'Platform': '["OSX"]',
            'ExpirationDate': stamp,
          }, 'x').expires,
          isNotNull,
          reason: stamp,
        );
      }
    });

    // The UUID comes out of a file and becomes a path inside a directory of
    // Xcode's, so the grammar is a traversal guard rather than a spelling rule.
    test('refuses a UUID that would escape the directory', () {
      expect(
        () => profileFactsFrom({
          'UUID': '../../../../etc/rc',
          'Platform': '["iOS"]',
        }, 'evil.mobileprovision'),
        throwsA(isA<ProjectException>()),
      );
    });

    test('a missing name falls back to the uuid rather than being blank', () {
      final facts = profileFactsFrom({
        'UUID': 'ABC-123',
        'Platform': '["iOS"]',
      }, 'x');
      expect(facts.name, 'ABC-123');
    });

    test('daysLeft is negative once past', () {
      final facts = profileFactsFrom({
        'UUID': 'ABC-123',
        'Platform': '["iOS"]',
        'ExpirationDate': '2026-01-01T00:00:00Z',
      }, 'x');
      expect(facts.daysLeft(DateTime.utc(2026, 1, 31)), -30);
      expect(facts.daysLeft(DateTime.utc(2025, 12, 2)), 30);
    });

    test('an absent expiry is null rather than an error', () {
      final facts = profileFactsFrom({
        'UUID': 'ABC-123',
        'Platform': '["iOS"]',
      }, 'x');
      expect(facts.expires, isNull);
      expect(facts.daysLeft(DateTime.utc(2026)), isNull);
    });
  });

  group('decideProfile', () {
    // The rule a peer session caught being wrong. The secrets file holds every
    // profile a project has and `secrets exec` materializes all of them, so
    // failing on any expired one means an unused Developer ID profile lapsing
    // breaks every App Store release — naming a profile that build never
    // touches, which is the unhelpful failure the check exists to prevent.
    test('an expired profile nobody named is skipped, not fatal', () {
      expect(
        decideProfile(daysLeft: -5, named: false, strictExpiry: false),
        ProfileDecision.skipExpired,
      );
    });

    test('an expired profile the caller named is fatal', () {
      expect(
        decideProfile(daysLeft: -5, named: true, strictExpiry: false),
        ProfileDecision.failExpired,
      );
    });

    test('expiring soon is fatal only when named and strict', () {
      expect(
        decideProfile(daysLeft: 10, named: true, strictExpiry: true),
        ProfileDecision.failExpiringSoon,
      );
      expect(
        decideProfile(daysLeft: 10, named: true, strictExpiry: false),
        ProfileDecision.install,
      );
      // --strict-expiry cannot make an unnamed profile fatal, or the whole
      // distinction above collapses the first time somebody passes it.
      expect(
        decideProfile(daysLeft: 10, named: false, strictExpiry: true),
        ProfileDecision.install,
      );
    });

    test('a healthy profile installs whatever the flags say', () {
      for (final named in [true, false]) {
        for (final strict in [true, false]) {
          expect(
            decideProfile(daysLeft: 200, named: named, strictExpiry: strict),
            ProfileDecision.install,
            reason: 'named=$named strict=$strict',
          );
        }
      }
    });

    test('the boundary day counts as soon, and zero is not yet expired', () {
      expect(
        decideProfile(daysLeft: 30, named: true, strictExpiry: true),
        ProfileDecision.failExpiringSoon,
      );
      expect(
        decideProfile(daysLeft: 31, named: true, strictExpiry: true),
        ProfileDecision.install,
      );
      expect(
        decideProfile(daysLeft: 0, named: true, strictExpiry: false),
        ProfileDecision.install,
      );
    });

    test('an unknown expiry installs rather than blocking', () {
      expect(
        decideProfile(daysLeft: null, named: true, strictExpiry: true),
        ProfileDecision.install,
      );
    });
  });

  group('parseIdentities', () {
    // Verbatim from `security find-identity -p codesigning` against a keychain
    // holding one self-signed certificate. The note is the whole reason this is
    // parsed rather than grepped: `-v` renders this same identity as an empty
    // list with no reason attached, and "no private key" and "does not chain"
    // need opposite fixes.
    const untrusted = '''
Policy: Code Signing
  Matching identities
  1) 56CD0E47ABBE60C7F98FD15DECAE64C7C7688D4D "Apple Distribution: Test Only (TESTTEAM99)" (CSSMERR_TP_NOT_TRUSTED)
     1 identities found

  Valid identities only
     0 valid identities found
''';

    test('reads the name and the reason it is unusable', () {
      final found = parseIdentities(untrusted);
      expect(found, hasLength(1));
      expect(found.single.name, 'Apple Distribution: Test Only (TESTTEAM99)');
      expect(found.single.hash, '56CD0E47ABBE60C7F98FD15DECAE64C7C7688D4D');
      expect(found.single.note, 'CSSMERR_TP_NOT_TRUSTED');
    });

    test('a usable identity carries no note', () {
      final found = parseIdentities(
        '  1) ABC123 "Apple Distribution: Someone (64ZPC769JY)"\n'
        '     1 identities found\n',
      );
      expect(found.single.note, isNull);
      expect(found.single.name, contains('64ZPC769JY'));
    });

    test('an empty listing is empty rather than one blank identity', () {
      expect(parseIdentities('     0 valid identities found\n'), isEmpty);
    });

    test('reads more than one', () {
      final found = parseIdentities(
        '  1) AAA "Apple Distribution: X (T1)"\n'
        '  2) BBB "3rd Party Mac Developer Installer: X (T1)"\n',
      );
      expect(found.map((i) => i.name), [
        'Apple Distribution: X (T1)',
        '3rd Party Mac Developer Installer: X (T1)',
      ]);
    });
  });

  group('parseSearchList', () {
    test('strips the quotes security writes', () {
      expect(
        parseSearchList(
          '    "/Users/x/Library/Keychains/login.keychain-db"\n'
          '    "/Library/Keychains/System.keychain"\n',
        ),
        [
          '/Users/x/Library/Keychains/login.keychain-db',
          '/Library/Keychains/System.keychain',
        ],
      );
    });

    // The reason for parsing rather than `tr -d '"'`, which is what both of the
    // implementations this replaces do: the output is quote-delimited precisely
    // so a path may contain spaces, and stripping quotes globally corrupts the
    // search list of anyone whose home directory has one.
    test('keeps a path containing spaces intact', () {
      expect(parseSearchList('    "/Users/a b/Library/Keychains/login.db"\n'), [
        '/Users/a b/Library/Keychains/login.db',
      ]);
    });

    test('ignores blank lines', () {
      expect(parseSearchList('\n  "/a"\n\n   \n  "/b"\n'), ['/a', '/b']);
    });

    test('takes an unquoted line as it stands', () {
      expect(parseSearchList('  /a/b.keychain-db\n'), ['/a/b.keychain-db']);
    });
  });

  group('pidOfKeychain', () {
    test('reads back the pid this tool encoded', () {
      expect(
        pidOfKeychain(
          '/Users/x/Library/Keychains/cux_ship-build-4711.keychain-db',
        ),
        4711,
      );
    });

    test('is null for a keychain that is not ours', () {
      expect(
        pidOfKeychain('/Users/x/Library/Keychains/login.keychain-db'),
        null,
      );
      expect(
        pidOfKeychain('/Users/x/Library/Keychains/authpass-build-9.db'),
        null,
      );
    });

    test('is null when the pid is not a number', () {
      expect(pidOfKeychain('/k/cux_ship-build-nope.keychain-db'), null);
    });
  });

  group('collectStaleKeychains', () {
    // What the pid in the name is for. A trap covers a failed build, a Ctrl-C
    // and a SIGTERM; it covers neither SIGKILL nor the power going out, and
    // what survives those holds a distribution private key.
    test('collects one left by a process that is gone', () {
      expect(
        collectStaleKeychains(
          [
            '/k/cux_ship-build-100.keychain-db',
            '/k/cux_ship-build-200.keychain-db',
          ],
          alive: (pid) => pid == 200,
          selfPid: 999,
        ),
        ['/k/cux_ship-build-100.keychain-db'],
      );
    });

    test('never collects our own, whatever the liveness check says', () {
      expect(
        collectStaleKeychains(
          ['/k/cux_ship-build-999.keychain-db'],
          alive: (pid) => false,
          selfPid: 999,
        ),
        isEmpty,
      );
    });

    test('leaves keychains belonging to anything else alone', () {
      expect(
        collectStaleKeychains(
          [
            '/k/login.keychain-db',
            '/k/authpass-build-1.keychain-db',
            '/k/cux_ship-build-1.keychain-db',
          ],
          alive: (pid) => false,
          selfPid: 999,
        ),
        ['/k/cux_ship-build-1.keychain-db'],
      );
    });
  });

  group('the constants carry the decisions', () {
    // Named so a change to either is a visible diff rather than a silent
    // regression to the value that was wrong. Six hours is the larger of the
    // two implementations, whose shorter timeout relocked partway through a
    // long archive.
    test('the lock timeout is the six hours a long archive needs', () {
      expect(keychainLockTimeoutSeconds, 21600);
    });

    test('the partition list carries apple:, which is the one that works', () {
      expect(keychainPartitionList, contains('apple:'));
    });
  });
}

void _expiryTests() {
  group('certificate expiry', () {
    final now = DateTime.utc(2026, 8, 17, 8, 0, 0);

    test('reads the date openssl actually prints', () {
      expect(
        daysUntilNotAfter('notAfter=Aug 10 11:00:16 2027 GMT\n', now),
        358,
      );
      // The case that prompted this: a certificate a sibling project was
      // signing with, three weeks out and reported nowhere in the build.
      expect(daysUntilNotAfter('notAfter=Sep  6 11:01:52 2026 GMT', now), 20);
    });

    test('an unreadable date is not a failure', () {
      expect(daysUntilNotAfter('unable to load certificate', now), isNull);
      expect(certificateExpiryNote(null), isEmpty);
    });

    test('says which way the date falls', () {
      expect(certificateExpiryNote(358), contains('358d left'));
      expect(certificateExpiryNote(20), contains('expires in 20d'));
      expect(certificateExpiryNote(-3), contains('EXPIRED 3d ago'));
    });
  });

  group('collecting a keychain a killed run left behind', () {
    // Observed rather than theorised: a build died under memory pressure and
    // left cux_ship-build-80436.keychain-db, and the *next* run declined to
    // collect it — because something else was alive holding pid 80436 by then.
    // A pid does not identify a process for long, and a collector that treats
    // it as if it does leaves the orphan forever.
    test('a recycled pid does not protect an orphan', () {
      final made = DateTime(2026, 8, 17, 14, 0);
      expect(
        collectStaleKeychains(
          ['/k/cux_ship-build-4242.keychain-db'],
          alive: (_) => true,
          selfPid: 1,
          createdAt: (_) => made,
          // Started after the keychain existed, so it cannot be the process
          // that created it.
          startedAt: (_) => made.add(const Duration(minutes: 5)),
        ),
        ['/k/cux_ship-build-4242.keychain-db'],
      );
    });

    test('the process that made it is left alone', () {
      final made = DateTime(2026, 8, 17, 14, 0);
      expect(
        collectStaleKeychains(
          ['/k/cux_ship-build-4242.keychain-db'],
          alive: (_) => true,
          selfPid: 1,
          createdAt: (_) => made,
          startedAt: (_) => made.subtract(const Duration(seconds: 30)),
        ),
        isEmpty,
      );
    });

    // The safety rests on `isAfter` being strict, so the boundary is pinned:
    // a process whose recorded start equals the file's timestamp is the owner,
    // not a recycled id.
    test('an equal timestamp is the owner, not a reuse', () {
      final made = DateTime(2026, 8, 17, 14, 0);
      expect(
        collectStaleKeychains(
          ['/k/cux_ship-build-4242.keychain-db'],
          alive: (_) => true,
          selfPid: 1,
          createdAt: (_) => made,
          startedAt: (_) => made,
        ),
        isEmpty,
      );
    });

    // Null means "cannot tell", and cannot tell must never collect: deleting a
    // live build's signing keychain is far worse than leaving an orphan.
    test('an unreadable start time never collects', () {
      expect(
        collectStaleKeychains(
          ['/k/cux_ship-build-4242.keychain-db'],
          alive: (_) => true,
          selfPid: 1,
          createdAt: (_) => DateTime(2026, 8, 17, 14, 0),
          startedAt: (_) => null,
        ),
        isEmpty,
      );
    });
  });

  group('reading a process start time', () {
    // Asks the real `ps` about this very process, rather than asserting a
    // string somebody transcribed once. The previous version of this test fed a
    // literal while its own comment claimed the format was "checked rather than
    // remembered" — which is reading it once and trusting the regex, with a
    // test asserting the transcription. A literal cannot notice a locale or
    // format drift; this can.
    test('the format this machine actually prints parses', () {
      final printed =
          Process.runSync('ps', ['-p', '$pid', '-o', 'lstart=']).stdout
              as String;
      expect(printed.trim(), isNotEmpty, reason: 'ps printed nothing');

      final parsed = parsePsStartTime(printed);
      expect(parsed, isNotNull, reason: 'could not parse: "${printed.trim()}"');

      // Sane rather than exact: this process started before now and has not
      // been running for a year.
      final now = DateTime.now();
      expect(parsed!.isAfter(now.subtract(const Duration(days: 365))), isTrue);
      expect(parsed.isBefore(now.add(const Duration(minutes: 1))), isTrue);
    });

    test('padded and multi-space forms parse too', () {
      expect(
        parsePsStartTime('Mon Aug  7 06:05:04 2026\n'),
        DateTime(2026, 8, 7, 6, 5, 4),
      );
    });

    test('anything else is null rather than a guess', () {
      expect(parsePsStartTime(''), isNull);
      expect(parsePsStartTime('not a date'), isNull);
      expect(parsePsStartTime('Mon Xxx 17 16:29:27 2026'), isNull);
    });
  });

  group('pruning the user search list', () {
    // A path that really is there, and one that really is not — the predicate
    // is `existsSync`, so a stub returning a non-existent File would make
    // "exists" mean the opposite of its name.
    File exists(String path) => File(Platform.resolvedExecutable);
    File missing(String path) => File('/definitely/missing/$path');

    const login = '/Users/x/Library/Keychains/login.keychain-db';
    const dead = '/Users/x/Library/Keychains/cux_ship-build-999.keychain-db';

    // The case that makes this worth extracting: every entry is a dead keychain
    // of ours. Writing the result would set an *empty* user search list, which
    // severs the login keychain from every later security and codesign call for
    // that user until it is repaired by hand. Declining costs nothing — the
    // next run adds a real entry and the dead ones go then.
    test('an all-dead list is never written', () {
      expect(searchListWithoutDeadKeychains([dead], missing), isNull);
      expect(
        searchListWithoutDeadKeychains([dead, '$dead.2'], missing),
        isNull,
      );
    });

    test('a dead entry beside a live one is dropped', () {
      expect(searchListWithoutDeadKeychains([login, dead], missing), [login]);
    });

    // Nothing to do is not the same as nothing to keep, and both return null —
    // so this pins that the no-change path is the reason, not the empty one.
    test('an unchanged list is not rewritten', () {
      expect(searchListWithoutDeadKeychains([login], missing), isNull);
      expect(searchListWithoutDeadKeychains([login, dead], exists), isNull);
    });

    // Only ours. A dead keychain belonging to somebody else is not this tool's
    // to remove, and a search list is shared.
    test('a foreign entry is kept even when its file is gone', () {
      const foreign = '/Users/x/Library/Keychains/somebody-else.keychain-db';
      expect(searchListWithoutDeadKeychains([foreign, dead], missing), [
        foreign,
      ]);
      expect(searchListWithoutDeadKeychains([login, foreign, dead], missing), [
        login,
        foreign,
      ]);
    });
  });
}
