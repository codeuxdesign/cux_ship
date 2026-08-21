// SPDX-License-Identifier: Apache-2.0
//
// Recording an upload is off unless a repository asks for it, and the cases
// here are mostly about that default holding — because turning it on requires
// push credentials on the upload job, and a repository that never asked would
// discover that as uploads failing rather than as a record being skipped.
import 'dart:io';

import 'package:cux_ship/src/config.dart';
import 'package:cux_ship/src/project.dart' show ProjectException;
import 'package:cux_ship/src/provenance.dart';
import 'package:cux_ship/src/release.dart' show Git, ReleaseException;
import 'package:test/test.dart';

late Directory _root;
late Directory _origin;
late Git _git;

void _config(String yaml) =>
    File('${_root.path}/.cux-ship.yaml').writeAsStringSync(yaml);

String _commit(String message) {
  File('${_root.path}/file.txt').writeAsStringSync(message);
  _git.run(['add', '-A']);
  _git.run(['commit', '-q', '-m', message]);
  return _git.run(['rev-parse', 'HEAD']);
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('cux_ship_prov_config');
    _git = Git(_root.path);
    _git.run(['init', '-q', '-b', 'main']);
    _git.run(['config', 'user.email', 'test@example.com']);
    _git.run(['config', 'user.name', 'Test']);
    // A record is pushed, because a record on one machine is not a record —
    // so every fixture that writes one needs somewhere for it to go.
    _origin = Directory.systemTemp.createTempSync('cux_ship_prov_origin');
    Process.runSync('git', ['init', '-q', '--bare', _origin.path]);
    _git.run(['remote', 'add', 'origin', _origin.path]);
  });

  tearDown(() {
    _root.deleteSync(recursive: true);
    _origin.deleteSync(recursive: true);
  });

  group('config', () {
    test('absent means off', () {
      expect(ProjectConfig.read(_root.path).uploadTag.enabled, isFalse);
    });

    test('an empty tag.upload block is still off', () {
      _config('tag:\n  upload:\n');
      expect(ProjectConfig.read(_root.path).uploadTag.enabled, isFalse);
    });

    test('declared on, with the namespaced default shape', () {
      _config('tag:\n  upload:\n    enabled: true\n');
      final p = ProjectConfig.read(_root.path).uploadTag;
      expect(p.enabled, isTrue);
      expect(p.nameFor(version: '1.0.4', build: '56'), 'uploaded/v1.0.4+56');
    });

    test('the default tag cannot be read as a release tag', () {
      // `sort -V` ranks build metadata above the version it annotates, so a
      // release guard taking the highest `v*` tag would read a bare
      // `v1.0.4+56` as a released 1.0.4 and refuse to build it. The namespace
      // is what keeps the record out of that glob.
      _config('tag:\n  upload:\n    enabled: true\n');
      final name = ProjectConfig.read(
        _root.path,
      ).uploadTag.nameFor(version: '1.0.4', build: '56');
      expect(name.startsWith('v'), isFalse);
      expect(name, startsWith('uploaded/'));
    });

    test('an override is honored', () {
      _config(
        'tag:\n  upload:\n    enabled: true\n    format: b/{version}-{build}\n',
      );
      expect(
        ProjectConfig.read(
          _root.path,
        ).uploadTag.nameFor(version: '2.0.0', build: '7'),
        'b/2.0.0-7',
      );
    });

    test('a tag template without {build} is refused', () {
      // Every upload of one version would take the same name, and the
      // collision check would then report an ordinary second upload as one
      // build number naming two commits — the loudest error here, raised
      // falsely, for as long as the configuration stands.
      _config(
        'tag:\n  upload:\n    enabled: true\n    format: uploaded/v{version}\n',
      );
      expect(
        () => ProjectConfig.read(_root.path),
        throwsA(
          isA<ProjectException>().having(
            (e) => e.message,
            'message',
            contains('{build}'),
          ),
        ),
      );
    });

    test('tag.release defaults to what release finish always wrote', () {
      // Enabled where an upload record is not: a release tag is what this tool
      // has always written, and a record of every upload is new and opt-in.
      final r = ProjectConfig.read(_root.path).releaseTag;

      expect(r.enabled, isTrue);
      expect(r.nameFor(version: '1.2.3'), 'v1.2.3');
    });

    test('tag.release.format is read, and needs no {build}', () {
      // The asymmetry with an upload record, which *requires* {build}: a
      // release names a version, and one build happens to carry it.
      _config('tag:\n  release:\n    format: rel/{version}\n');
      final r = ProjectConfig.read(_root.path).releaseTag;

      expect(r.nameFor(version: '1.2.3'), 'rel/1.2.3');
    });

    test('a format with no enabled is refused as the contradiction it is', () {
      // The block was validated and then ignored: the {build} check ran, the
      // default stayed false, and no tag was ever written. A setting that
      // appears to be applied and is not is the one failure this file's own
      // header says the config refuses everywhere else.
      _config('tag:\n  upload:\n    format: uploaded/v{version}+{build}\n');
      expect(
        () => ProjectConfig.read(_root.path),
        throwsA(
          isA<ProjectException>().having(
            (e) => e.toString(),
            'message',
            contains('never used'),
          ),
        ),
      );
    });

    test('a format alongside enabled: false is still refused', () {
      // Turning it off explicitly and naming a shape is the same contradiction
      // — and the more likely typo, because it reads as configured.
      _config(
        'tag:\n  upload:\n    enabled: false\n'
        '    format: uploaded/v{version}+{build}\n',
      );
      expect(
        ProjectConfig.read(_root.path).uploadTag.enabled,
        isFalse,
        reason:
            'explicit is not a contradiction: the operator said both things '
            'on purpose and the format is inert by their instruction',
      );
    });

    test('a release format wanting {build} without one is refused', () {
      // `{build}` is legal in a release format and parse-time cannot judge it:
      // whether a build number exists is a property of the invocation. So the
      // refusal has to be here, at the point the name is made — and it has to
      // be a refusal rather than an empty substitution, which would write and
      // push `v1.2.3+`, a tag wrong by one trailing character in a name nobody
      // reads twice.
      _config('tag:\n  release:\n    format: v{version}+{build}\n');
      final r = ProjectConfig.read(_root.path).releaseTag;

      expect(
        () => r.nameFor(version: '1.2.3'),
        throwsA(
          isA<ProjectException>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('needs a build number'), contains('v1.2.3+')),
          ),
        ),
      );
      expect(
        r.nameFor(version: '1.2.3', build: '56'),
        'v1.2.3+56',
        reason: 'the same format is fine once the number is there',
      );
    });

    test('an empty build number is refused like a missing one', () {
      // A shell that resolved its build number to "" passes an empty string
      // rather than null, and would otherwise land in exactly the same place.
      const r = TagKindConfig(enabled: true, format: 'v{version}+{build}');
      expect(
        () => r.nameFor(version: '1.2.3', build: ''),
        throwsA(isA<ProjectException>()),
      );
    });

    test('tag.release.enabled false is read', () {
      _config('tag:\n  release:\n    enabled: false\n');
      expect(ProjectConfig.read(_root.path).releaseTag.enabled, isFalse);
    });

    test('a release format with no {version} is refused', () {
      // Two releases would collide under one name, and `release finish` would
      // then refuse the second claiming one version reached two commits — the
      // loudest error this tool has, raised falsely, from a config typo.
      _config('tag:\n  release:\n    format: released\n');
      expect(
        () => ProjectConfig.read(_root.path),
        throwsA(
          isA<ProjectException>().having(
            (e) => e.toString(),
            'message',
            contains('{version}'),
          ),
        ),
      );
    });

    test('the two kinds are independent', () {
      // One block configured must not disturb the other's default, or a
      // repository that sets a release format silently loses upload recording.
      _config('tag:\n  release:\n    format: rel/{version}\n');
      final c = ProjectConfig.read(_root.path);

      expect(c.uploadTag.enabled, isFalse, reason: 'still opt-in');
      expect(c.releaseTag.format, 'rel/{version}');
    });

    test('an unrecognised tag kind is refused too', () {
      _config('tag:\n  nonesuch:\n    enabled: true\n');
      expect(
        () => ProjectConfig.read(_root.path),
        throwsA(isA<ProjectException>()),
      );
    });

    test('an unknown key under tag.upload is refused', () {
      _config('tag:\n  upload:\n    record_uploads: true\n');
      expect(() => ProjectConfig.read(_root.path), throwsA(isA<Exception>()));
    });
  });

  group('recordUploadIfConfigured', () {
    test('does nothing at all when off', () {
      final built = _commit('built');
      final result = recordUploadIfConfigured(
        _root.path,
        const TagKindConfig(enabled: false, format: defaultUploadTagFormat),
        store: 'play',
        version: '1.0.0',
        build: '49',
        commit: built,
        checksum: null,
      );
      expect(result, isNull);
      expect(_git.run(['tag', '-l']), isEmpty);
    });

    test('writes the record when on', () {
      final built = _commit('built');
      final result = recordUploadIfConfigured(
        _root.path,
        const TagKindConfig(enabled: true, format: defaultUploadTagFormat),
        store: 'play',
        version: '1.0.0',
        build: '49',
        commit: built,
        checksum: 'abc123',
        dryRun: true,
      );

      expect(result, UploadRecordResult.created);
      // dryRun, so the tag must not exist — the assertion that makes the one
      // above mean something.
      expect(_git.run(['tag', '-l']), isEmpty);
    });

    test('the annotation carries what the commit cannot', () {
      final built = _commit('built');
      recordUploadIfConfigured(
        _root.path,
        const TagKindConfig(enabled: true, format: defaultUploadTagFormat),
        store: 'appstore/ios',
        version: '1.0.0',
        build: '49',
        commit: built,
        checksum: 'abc123',
      );
      final body = _git.run(['tag', '-l', '-n99', 'uploaded/v1.0.0+49']);
      expect(body, contains('build 49'));
      expect(body, contains('appstore/ios'));
    });

    test('refuses when on and --commit was not given', () {
      _commit('built');
      expect(
        () => recordUploadIfConfigured(
          _root.path,
          const TagKindConfig(enabled: true, format: defaultUploadTagFormat),
          store: 'play',
          version: '1.0.0',
          build: '49',
          commit: null,
          checksum: null,
        ),
        throwsA(
          isA<ReleaseException>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('--commit'), contains('gitSha')),
          ),
        ),
        reason:
            'inferring HEAD would record the wrong commit on an upload job '
            'that did not do the build',
      );
    });

    test('refuses when on and the build number is not known', () {
      final built = _commit('built');
      expect(
        () => recordUploadIfConfigured(
          _root.path,
          const TagKindConfig(enabled: true, format: defaultUploadTagFormat),
          store: 'play',
          version: '1.0.0',
          build: null,
          commit: built,
          checksum: null,
        ),
        throwsA(isA<ReleaseException>()),
      );
    });
  });
}
