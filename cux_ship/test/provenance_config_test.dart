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
      expect(ProjectConfig.read(_root.path).provenance.recordUploads, isFalse);
    });

    test('an empty provenance block is still off', () {
      _config('provenance:\n');
      expect(ProjectConfig.read(_root.path).provenance.recordUploads, isFalse);
    });

    test('declared on, with the namespaced default shape', () {
      _config('provenance:\n  record-uploads: true\n');
      final p = ProjectConfig.read(_root.path).provenance;
      expect(p.recordUploads, isTrue);
      expect(p.tagFor(version: '1.0.4', build: '56'), 'uploaded/v1.0.4+56');
    });

    test('the default tag cannot be read as a release tag', () {
      // `sort -V` ranks build metadata above the version it annotates, so a
      // release guard taking the highest `v*` tag would read a bare
      // `v1.0.4+56` as a released 1.0.4 and refuse to build it. The namespace
      // is what keeps the record out of that glob.
      _config('provenance:\n  record-uploads: true\n');
      final name = ProjectConfig.read(
        _root.path,
      ).provenance.tagFor(version: '1.0.4', build: '56');
      expect(name.startsWith('v'), isFalse);
      expect(name, startsWith('uploaded/'));
    });

    test('an override is honored', () {
      _config(
        'provenance:\n  record-uploads: true\n  tag: b/{version}-{build}\n',
      );
      expect(
        ProjectConfig.read(
          _root.path,
        ).provenance.tagFor(version: '2.0.0', build: '7'),
        'b/2.0.0-7',
      );
    });

    test('a tag template without {build} is refused', () {
      // Every upload of one version would take the same name, and the
      // collision check would then report an ordinary second upload as one
      // build number naming two commits — the loudest error here, raised
      // falsely, for as long as the configuration stands.
      _config(
        'provenance:\n  record-uploads: true\n  tag: uploaded/v{version}\n',
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

    test('an unknown key under provenance is refused', () {
      _config('provenance:\n  record_uploads: true\n');
      expect(() => ProjectConfig.read(_root.path), throwsA(isA<Exception>()));
    });
  });

  group('recordUploadIfConfigured', () {
    test('does nothing at all when off', () {
      final built = _commit('built');
      final result = recordUploadIfConfigured(
        _root.path,
        const ProvenanceConfig(),
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
        const ProvenanceConfig(recordUploads: true),
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
        const ProvenanceConfig(recordUploads: true),
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
          const ProvenanceConfig(recordUploads: true),
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
          const ProvenanceConfig(recordUploads: true),
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
