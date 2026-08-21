// SPDX-License-Identifier: Apache-2.0
//
// Everything here is offline. What `deps install` actually does over the
// network — fetch, hash, move — is one function whose contract is "the
// destination name never exists unless the hash matched", and the parts that
// can go wrong without a network are the ones tested: which asset name a
// platform maps to, and whether an installation is judged complete.
import 'dart:io';

import 'package:cux_ship/src/deps.dart';
import 'package:cux_ship/src/deps_pins.dart';
import 'package:cux_ship/src/project.dart';
import 'package:test/test.dart';

late Directory _bin;

/// A stand-in for a tool binary that answers `--version` the way the real one
/// does.
void installed(String name, String versionOutput) {
  final file = File('${_bin.path}/$name')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('#!/bin/sh\necho "$versionOutput"\n');
  Process.runSync('chmod', ['755', file.path]);
}

Future<({int code, List<String> log})> deps(DepsCommand command) async {
  final log = <String>[];
  final code = await runDeps(command, binDir: _bin.path, log: log.add);
  return (code: code, log: log);
}

void main() {
  setUp(() {
    _bin = Directory.systemTemp.createTempSync('cux_ship_deps_test');
  });

  tearDown(() {
    _bin.deleteSync(recursive: true);
  });

  group('asset names', () {
    test('sops uses dots and age uses dashes', () {
      // The one difference between the two projects' release assets, and
      // getting it wrong is a 404 rather than a wrong download.
      const host = (os: 'darwin', arch: 'arm64');
      expect(platformFor('sops', host), 'darwin.arm64');
      expect(platformFor('age', host), 'darwin-arm64');
    });

    test('every platform this runs on is pinned for both tools', () {
      // A pin set missing an entry is only discovered on the machine that
      // needs it, which is usually a runner rather than a laptop.
      for (final host in const [
        (os: 'darwin', arch: 'arm64'),
        (os: 'darwin', arch: 'amd64'),
        (os: 'linux', arch: 'arm64'),
        (os: 'linux', arch: 'amd64'),
      ]) {
        for (final tool in const ['sops', 'age']) {
          expect(
            () => pinFor(tool, host),
            returnsNormally,
            reason: '$tool on ${host.os}/${host.arch}',
          );
        }
      }
    });

    test('one version per tool across every platform', () {
      // A half-applied update — three platforms bumped and one left behind —
      // would otherwise install different versions on different machines.
      for (final tool in const ['sops', 'age']) {
        final versions = depsPins
            .where((p) => p.tool == tool)
            .map((p) => p.version)
            .toSet();
        expect(versions, hasLength(1), reason: '$tool: $versions');
      }
    });

    test('every pin carries a full sha256', () {
      for (final pin in depsPins) {
        expect(
          pin.sha256,
          matches(RegExp(r'^[0-9a-f]{64}$')),
          reason: '${pin.tool} ${pin.platform}',
        );
      }
    });

    test('an unpinned platform is refused rather than guessed', () {
      expect(
        () => pinFor('sops', (os: 'plan9', arch: 'arm64')),
        throwsA(isA<ProjectException>()),
      );
    });
  });

  group('check', () {
    test('reports both missing, and exits non-zero', () async {
      final result = await deps(DepsCommand.check);
      expect(result.code, 1);
      expect(result.log.join('\n'), contains('sops'));
      expect(result.log.join('\n'), contains('missing'));
    });

    test('a matching pair is ok', () async {
      final sops = pinFor('sops', currentPlatform());
      final age = pinFor('age', currentPlatform());
      installed('sops', 'sops ${sops.version}');
      installed('age', 'age version v${age.version}');
      installed('age-keygen', 'age-keygen ${age.version}');

      final result = await deps(DepsCommand.check);
      expect(result.code, 0);
      expect(result.log, everyElement(contains('ok')));
    });

    test('age without age-keygen is not a complete installation', () async {
      // age-keygen is what makes an identity, so an install missing it leaves
      // first-time setup needing a system install after all — and the version
      // check alone would have called it fine.
      final age = pinFor('age', currentPlatform());
      final sops = pinFor('sops', currentPlatform());
      installed('sops', 'sops ${sops.version}');
      installed('age', 'age version v${age.version}');

      final result = await deps(DepsCommand.check);
      expect(result.code, 1);
      expect(result.log, contains(startsWith('age ')));
    });

    test('the wrong version is reported as what is there', () async {
      installed('sops', 'sops 3.0.0');
      final result = await deps(DepsCommand.check);
      expect(result.code, 1);
      expect(result.log.join('\n'), contains('have 3.0.0'));
    });
  });

  group('windows asset naming', () {
    // **What a Mac can check about a Windows install, and what it cannot.**
    // These pin the naming rules — the part that is knowable from upstream's
    // published assets and was got wrong by assuming the pattern held. The
    // install path itself (bsdtar reading a zip, no chmod, `.exe` on disk)
    // needs a Windows machine, and this file must not pretend otherwise.

    test('sops names its Windows asset by architecture alone', () {
      // The one place upstream departs from its own convention. Every other
      // platform is `<os>.<arch>`; Windows is `sops-v3.13.3.amd64.exe`, with
      // no `windows` in it. Building the URL from `os.arch` here gives a 404,
      // which is what "it's just a pin-table addition" ran into.
      expect(platformFor('sops', (os: 'windows', arch: 'amd64')), 'amd64.exe');
      expect(platformFor('sops', (os: 'linux', arch: 'amd64')), 'linux.amd64');
      expect(
        platformFor('sops', (os: 'darwin', arch: 'arm64')),
        'darwin.arm64',
      );
    });

    test('age keeps its own convention on Windows', () {
      expect(
        platformFor('age', (os: 'windows', arch: 'amd64')),
        'windows-amd64',
      );
    });

    test('age ships a zip for Windows and a tarball everywhere else', () {
      // Not cosmetic: it decides both the URL and whether `tar` is given -xf
      // or -xzf, and GNU tar cannot read a zip at all.
      expect(ageArchiveExtension('windows-amd64'), 'zip');
      expect(ageArchiveExtension('linux-amd64'), 'tar.gz');
      expect(ageArchiveExtension('darwin-arm64'), 'tar.gz');
    });

    test('both Windows builds are pinned, and by the names upstream uses', () {
      // A pin whose platform string does not match the asset name resolves to
      // a URL that 404s at install time, on the one platform nobody here can
      // run — so the names are asserted rather than eyeballed.
      final sops = pinFor('sops', (os: 'windows', arch: 'amd64'));
      final age = pinFor('age', (os: 'windows', arch: 'amd64'));

      expect(sops.platform, 'amd64.exe');
      expect(age.platform, 'windows-amd64');
      expect(sops.sha256, hasLength(64));
      expect(age.sha256, hasLength(64));
    });

    test('windows arm64 is refused rather than half-pinned', () {
      // sops publishes arm64.exe; age publishes no windows-arm64 archive at
      // all. Pinning the half that exists would fail at install with a 404 on
      // the second tool instead of the message that says what to do.
      expect(
        () => pinFor('age', (os: 'windows', arch: 'arm64')),
        throwsA(isA<ProjectException>()),
      );
    });
  });

  group('sha256OfFile', () {
    test('matches the known digest of "abc"', () async {
      final file = File('${_bin.path}/abc')..writeAsStringSync('abc');
      expect(
        await sha256OfFile(file),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });
  });
}
