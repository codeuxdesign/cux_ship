// SPDX-License-Identifier: Apache-2.0
//
// These rewrite two files during a release, at the moment when getting it wrong
// is most expensive: the version has already been published, so a bump that
// silently does nothing hands the branch a name that is already in front of
// users. Every function here therefore has a test for the case where it should
// *refuse*, not only the case where it works.
import 'dart:io';

import 'package:cux_ship/src/release.dart';
import 'package:test/test.dart';

late Directory _root;
late Git _git;

/// A repository with one commit, a pubspec and a changelog.
///
/// [appDir] puts the pubspec in a subdirectory, as a monorepo does. The
/// changelog stays at the top either way — that is the arrangement, not an
/// oversight.
void repo({String version = '1.0.3+41', String appDir = ''}) {
  _git.run(['init', '-q', '-b', 'main']);
  _git.run(['config', 'user.email', 'test@example.com']);
  _git.run(['config', 'user.name', 'Test']);
  write(pubspecPathFor(appDir), 'name: an_app\nversion: $version\n');
  write('CHANGELOG.md', '# Changelog\n\n## 1.0.3\n\n- Something\n');
  _git.run(['add', '-A']);
  _git.run(['commit', '-q', '-m', 'first']);
}

void write(String name, String contents) {
  final file = File('${_root.path}/$name');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

String read(String name) => File('${_root.path}/$name').readAsStringSync();

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('cux_ship_release_test');
    _git = Git(_root.path);
  });

  tearDown(() {
    _root.deleteSync(recursive: true);
  });

  group('nextPatchVersion', () {
    test('increments the patch level', () {
      expect(nextPatchVersion('1.0.3'), '1.0.4');
      expect(nextPatchVersion('1.9.9'), '1.9.10');
      expect(nextPatchVersion('0.0.0'), '0.0.1');
    });

    test('refuses anything it cannot bump unambiguously', () {
      // Guessing the next version during a release is worse than stopping.
      for (final bad in ['1.0', '1.0.3-beta', '1.0.3+41', 'v1.0.3', '']) {
        expect(
          () => nextPatchVersion(bad),
          throwsA(isA<ReleaseException>()),
          reason: 'accepted "$bad"',
        );
      }
    });
  });

  group('bumpPubspecVersion', () {
    test('rewrites the version and keeps the build suffix', () {
      // The +N is the build number, overridden per build, so its value here has
      // never mattered — but rewriting it would look like it did.
      const pubspec = 'name: an_app\nversion: 1.0.3+41\n';
      expect(
        bumpPubspecVersion(pubspec, '1.0.4'),
        'name: an_app\nversion: 1.0.4+41\n',
      );
    });

    test('works with no build suffix', () {
      expect(
        bumpPubspecVersion('name: a\nversion: 1.0.3\n', '1.0.4'),
        'name: a\nversion: 1.0.4\n',
      );
    });

    test('leaves the rest of the file alone', () {
      const pubspec =
          'name: an_app\n'
          'version: 1.0.3+41\n'
          'environment:\n'
          '  sdk: ^3.12.2\n'
          'dependencies:\n'
          '  something:\n'
          '    version: 9.9.9\n';
      final result = bumpPubspecVersion(pubspec, '1.0.4');
      expect(result, contains('version: 1.0.4+41'));
      // A nested `version:` under a dependency must not be touched.
      expect(result, contains('    version: 9.9.9'));
    });

    test('refuses a pubspec with no version line', () {
      expect(
        () => bumpPubspecVersion('name: an_app\n', '1.0.4'),
        throwsA(isA<ReleaseException>()),
      );
    });
  });

  group('insertChangelogSection', () {
    test('inserts above the newest version section', () {
      const changelog = '# Changelog\n\n## 1.0.3\n\n- Something\n';
      expect(
        insertChangelogSection(changelog, '1.0.4'),
        '# Changelog\n\n## 1.0.4\n\n## 1.0.3\n\n- Something\n',
      );
    });

    test('prose headings above the versions are preserved', () {
      // The real changelog opens with rules sections, and the new version
      // belongs below those and above the newest release.
      const changelog =
          '# Changelog\n\n## Tone\n\nBe brief.\n\n## 1.0.3\n\n- Something\n';
      final result = insertChangelogSection(changelog, '1.0.4');
      expect(result, contains('## Tone\n\nBe brief.\n\n## 1.0.4\n\n## 1.0.3'));
    });

    test('refuses a changelog with no version sections', () {
      expect(
        () => insertChangelogSection('# Changelog\n\nNothing yet.\n', '1.0.4'),
        throwsA(isA<ReleaseException>()),
      );
    });
  });

  group('finishRelease', () {
    test('tags the commit and bumps the branch', () {
      repo();
      final head = _git.run(['rev-parse', 'HEAD']);

      final log = finishRelease(
        _git,
        FinishOptions(
          commit: head,
          version: '1.0.3',
          buildNumber: '41',
          push: false,
        ),
      );

      expect(log, contains('tagged v1.0.3'));
      expect(log, contains('bumped to 1.0.4'));
      expect(_git.run(['tag', '-l']), 'v1.0.3');
      expect(read('pubspec.yaml'), contains('version: 1.0.4+41'));
      expect(read('CHANGELOG.md'), contains('## 1.0.4'));
      // Only the two files, committed together.
      expect(_git.run(['status', '--porcelain']), isEmpty);
      expect(
        _git.run(['log', '-1', '--format=%s']),
        'Move main to 1.0.4, now that 1.0.3 is on production',
      );
    });

    test('the tag names the version, build and destination', () {
      repo();
      finishRelease(
        _git,
        FinishOptions(
          commit: _git.run(['rev-parse', 'HEAD']),
          version: '1.0.3',
          buildNumber: '41',
          destination: 'the App Store',
          push: false,
        ),
      );
      expect(
        _git.run(['tag', '-l', '-n99', 'v1.0.3']),
        contains('1.0.3 (41) released to the App Store'),
      );
    });

    test('running it twice is harmless — the second store cannot re-bump', () {
      // The whole reason this is safe to call once per store rather than once
      // per release, and the reason a retry after a half-failed release does
      // not compound the damage.
      repo();
      final head = _git.run(['rev-parse', 'HEAD']);
      final options = FinishOptions(
        commit: head,
        version: '1.0.3',
        push: false,
      );

      finishRelease(_git, options);
      final afterFirst = read('pubspec.yaml');

      final second = finishRelease(_git, options);
      expect(second, anyElement(startsWith('v1.0.3 already exists at ')));
      expect(
        second,
        contains('pubspec.yaml is already past 1.0.3 — not bumping'),
      );
      expect(read('pubspec.yaml'), afterFirst);
      expect('\n${read('CHANGELOG.md')}'.split('\n## 1.0.4').length - 1, 1);
    });

    test('a repeat pushes a tag the first run created but failed to push', () {
      // The tag existing *locally* says nothing about the remote holding it,
      // and the release tag is what a later reader resolves a version against.
      // Pushing only on the run that created the tag means one failed push is
      // permanent: every repeat finds it locally and finishes green.
      repo();
      final head = _git.run(['rev-parse', 'HEAD']);
      final origin = Directory.systemTemp.createTempSync('cux_ship_origin');
      addTearDown(() => origin.deleteSync(recursive: true));
      Process.runSync('git', ['init', '-q', '--bare', origin.path]);
      _git.run(['remote', 'add', 'origin', '${origin.path}-does-not-exist']);

      final options = FinishOptions(commit: head, version: '1.0.3');
      expect(
        () => finishRelease(_git, options),
        throwsA(isA<ReleaseException>()),
      );

      _git.run(['remote', 'set-url', 'origin', origin.path]);
      expect(
        finishRelease(_git, options),
        anyElement(contains('pushed v1.0.3')),
      );
      expect(
        Git(origin.path).run(['rev-parse', 'refs/tags/v1.0.3^{commit}']),
        head,
      );
    });

    test('a short sha names the same release as the full one', () {
      // Whatever the caller passes is compared against `rev-parse` output, so
      // without normalizing it the *repeat* is the thing that breaks, and it
      // breaks by accusing the release of naming a second commit.
      repo();
      final head = _git.run(['rev-parse', 'HEAD']);

      finishRelease(
        _git,
        FinishOptions(commit: head, version: '1.0.3', push: false),
      );

      expect(
        finishRelease(
          _git,
          FinishOptions(
            commit: head.substring(0, 8),
            version: '1.0.3',
            push: false,
          ),
        ),
        anyElement(startsWith('v1.0.3 already exists at ')),
      );
    });

    test('refuses when the tag already names a different commit', () {
      // Leaving an existing tag alone is right when it names this release —
      // that is what makes a retry safe. It is wrong when the same version has
      // been recorded against a different commit, because carrying on leaves
      // whichever one is wrong standing as the record of what shipped.
      repo();
      final first = _git.run(['rev-parse', 'HEAD']);
      finishRelease(
        _git,
        FinishOptions(commit: first, version: '1.0.3', push: false),
      );

      write('another.txt', 'more work');
      _git.run(['add', '-A']);
      _git.run(['commit', '-q', '-m', 'second']);
      final second = _git.run(['rev-parse', 'HEAD']);

      expect(
        () => finishRelease(
          _git,
          FinishOptions(commit: second, version: '1.0.3', push: false),
        ),
        throwsA(
          isA<ReleaseException>().having(
            (e) => e.toString(),
            'message',
            allOf(contains(first), contains(second)),
          ),
        ),
      );
      expect(
        _git.run(['rev-parse', 'refs/tags/v1.0.3^{commit}']),
        first,
        reason: 'the refusal must not move the tag it refused to overwrite',
      );
    });

    test('a branch already past the released version is not bumped', () {
      repo(version: '1.0.9+50');
      final log = finishRelease(
        _git,
        FinishOptions(
          commit: _git.run(['rev-parse', 'HEAD']),
          version: '1.0.3',
          push: false,
        ),
      );
      expect(log, contains('pubspec.yaml is already past 1.0.3 — not bumping'));
      expect(read('pubspec.yaml'), contains('version: 1.0.9+50'));
    });

    test('refuses to bump from the wrong branch', () {
      repo();
      _git.run(['checkout', '-q', '-b', 'some-feature']);
      expect(
        () => finishRelease(
          _git,
          FinishOptions(
            commit: _git.run(['rev-parse', 'HEAD']),
            version: '1.0.3',
            push: false,
          ),
        ),
        throwsA(
          isA<ReleaseException>().having(
            (e) => e.message,
            'message',
            contains('belongs on main'),
          ),
        ),
      );
    });

    test('refuses when pubspec.yaml has uncommitted changes', () {
      // `git commit <paths>` takes the working tree's version, so an unrelated
      // edit would be swept into the release commit.
      repo();
      write('pubspec.yaml', 'name: an_app\nversion: 1.0.3+41\n# edited\n');
      expect(
        () => finishRelease(
          _git,
          FinishOptions(
            commit: _git.run(['rev-parse', 'HEAD']),
            version: '1.0.3',
            push: false,
          ),
        ),
        throwsA(
          isA<ReleaseException>().having(
            (e) => e.message,
            'message',
            contains('uncommitted changes'),
          ),
        ),
      );
    });

    test('--no-bump still tags, and does not check the branch', () {
      repo();
      _git.run(['checkout', '-q', '-b', 'some-feature']);
      final log = finishRelease(
        _git,
        FinishOptions(
          commit: _git.run(['rev-parse', 'HEAD']),
          version: '1.0.3',
          bump: false,
          push: false,
        ),
      );
      expect(log, contains('tagged v1.0.3'));
      expect(read('pubspec.yaml'), contains('version: 1.0.3+41'));
    });

    test('--no-tag still bumps', () {
      repo();
      final log = finishRelease(
        _git,
        FinishOptions(
          commit: _git.run(['rev-parse', 'HEAD']),
          version: '1.0.3',
          tag: false,
          push: false,
        ),
      );
      expect(log, contains('bumped to 1.0.4'));
      expect(_git.run(['tag', '-l']), isEmpty);
    });

    test('a dry run writes nothing and commits nothing', () {
      repo();
      final before = _git.run(['rev-parse', 'HEAD']);
      final log = finishRelease(
        _git,
        FinishOptions(
          commit: before,
          version: '1.0.3',
          dryRun: true,
          push: false,
        ),
      );

      expect(log.join('\n'), contains('would tag v1.0.3'));
      expect(log.join('\n'), contains('would bump pubspec.yaml to 1.0.4'));
      expect(_git.run(['tag', '-l']), isEmpty);
      expect(read('pubspec.yaml'), contains('version: 1.0.3+41'));
      expect(read('CHANGELOG.md'), isNot(contains('## 1.0.4')));
      expect(_git.run(['rev-parse', 'HEAD']), before);
    });

    test('an app in a subdirectory bumps there, and the changelog at the '
        'top', () {
      repo(appDir: 'app');
      final head = _git.run(['rev-parse', 'HEAD']);

      final log = finishRelease(
        _git,
        FinishOptions(
          commit: head,
          version: '1.0.3',
          buildNumber: '41',
          appDir: 'app',
          push: false,
        ),
      );

      expect(log, contains('bumped to 1.0.4'));
      expect(read('app/pubspec.yaml'), contains('version: 1.0.4+41'));
      expect(read('CHANGELOG.md'), contains('## 1.0.4'));

      // The two paths go up in one commit, and it has to be the nested one:
      // `git commit pubspec.yaml` in a monorepo does not match a file and git
      // refuses, which is the loud half. The quiet half this guards is a
      // commit that took only the changelog.
      expect(_git.run(['status', '--porcelain']), isEmpty);
      expect(
        _git.run(['show', '--name-only', '--format=', 'HEAD']).split('\n'),
        containsAll(['CHANGELOG.md', 'app/pubspec.yaml']),
      );
    });

    test('a nested pubspec with uncommitted changes is refused', () {
      // The dirty guard has to follow the path, or `git commit <paths>` sweeps
      // an unrelated edit into the release commit.
      repo(appDir: 'app');
      write('app/pubspec.yaml', 'name: an_app\nversion: 1.0.3+41\n# edited\n');
      expect(
        () => finishRelease(
          _git,
          FinishOptions(
            commit: _git.run(['rev-parse', 'HEAD']),
            version: '1.0.3',
            appDir: 'app',
            push: false,
          ),
        ),
        throwsA(
          isA<ReleaseException>().having(
            (e) => e.message,
            'message',
            allOf(contains('app/pubspec.yaml'), contains('uncommitted')),
          ),
        ),
      );
    });

    test('a wrong --app-dir names the path it looked for', () {
      // The message is the whole diagnosis here: "no pubspec.yaml" would send
      // somebody looking for a missing file rather than at the flag.
      repo(appDir: 'app');
      expect(
        () => finishRelease(
          _git,
          FinishOptions(
            commit: _git.run(['rev-parse', 'HEAD']),
            version: '1.0.3',
            appDir: 'apps',
            push: false,
          ),
        ),
        throwsA(
          isA<ReleaseException>().having(
            (e) => e.message,
            'message',
            contains('no apps/pubspec.yaml in'),
          ),
        ),
      );
    });

    test('a dry run still reports a changelog that would fail', () {
      // Rehearsing is worth nothing if it only rehearses the happy path.
      repo();
      write('CHANGELOG.md', '# Changelog\n\nNo versions here.\n');
      _git.run(['commit', '-q', '-a', '-m', 'break the changelog']);
      expect(
        () => finishRelease(
          _git,
          FinishOptions(
            commit: _git.run(['rev-parse', 'HEAD']),
            version: '1.0.3',
            dryRun: true,
            push: false,
          ),
        ),
        throwsA(isA<ReleaseException>()),
      );
    });
  });
}
