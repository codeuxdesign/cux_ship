// SPDX-License-Identifier: Apache-2.0
//
// `verify` refuses a pubspec version with no changelog section, end to end —
// spawned, because the check is wired in `VerifyCommand.run`, which reads the
// version off the project and the changelog off the flags, and no unit test
// reaches that wiring. The two flags that move either input are the cases:
// `--changelog` names another file, `--app-dir` names another pubspec.
import 'dart:io';

import 'package:test/test.dart';

import 'cli_snapshot.dart';

late Directory _repo;

void _write(String relative, String contents) {
  final file = File('${_repo.path}/$relative');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

/// `--app-dir` is global and goes before the command; the rest are `verify`'s.
ProcessResult _verify(List<String> args, {List<String> global = const []}) =>
    Process.runSync(Platform.resolvedExecutable, [
      '--enable-asserts',
      cliSnapshot,
      ...global,
      'verify',
      ...args,
    ], workingDirectory: _repo.path);

const _shipped = '# Changelog\n\n## 1.0.0\n\n- Something\n';
const _withNext =
    '# Changelog\n\n## 1.0.1\n\n- Next\n\n## 1.0.0\n\n- Something\n';

void main() {
  setUp(() {
    _repo = Directory.systemTemp.createTempSync('cux_ship_verify_section');
    Process.runSync('git', ['init', '-q'], workingDirectory: _repo.path);
  });

  tearDown(() => _repo.deleteSync(recursive: true));

  test('a pubspec version with no section fails, naming it', () {
    _write('pubspec.yaml', 'name: consumer\nversion: 1.0.1+2\n');
    _write('CHANGELOG.md', _shipped);

    final result = _verify([]);
    expect(result.exitCode, 1, reason: '${result.stdout}${result.stderr}');
    expect('${result.stderr}', contains('§ 1.0.1'));
    expect('${result.stderr}', contains('no section'));
  });

  test('a pubspec version with a section passes, and says it was checked', () {
    _write('pubspec.yaml', 'name: consumer\nversion: 1.0.1+2\n');
    _write('CHANGELOG.md', _withNext);

    final result = _verify([]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect('${result.stdout}', contains('section    1.0.1 (pubspec.yaml)'));
  });

  test('the summary names the check, not a result it did not get', () {
    _write('pubspec.yaml', 'name: consumer\nversion: 1.0.1+2\n');
    _write('CHANGELOG.md', _shipped);

    final result = _verify([]);
    expect(result.exitCode, 1, reason: '${result.stdout}${result.stderr}');
    expect('${result.stdout}', contains('section    1.0.1 (pubspec.yaml)'));
    expect('${result.stdout}', isNot(contains('has its section')));
  });

  test('an empty section is enough', () {
    // What `release finish` leaves behind, and a legitimate answer.
    _write('pubspec.yaml', 'name: consumer\nversion: 1.0.1+2\n');
    _write('CHANGELOG.md', '# Changelog\n\n## 1.0.1\n\n## 1.0.0\n\n- Old\n');

    final result = _verify([]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  });

  test('--changelog is the file that is checked', () {
    _write('pubspec.yaml', 'name: consumer\nversion: 1.0.1+2\n');
    _write('CHANGELOG.md', _shipped);
    _write('notes/CHANGES.md', _withNext);

    final named = _verify(['--changelog', 'notes/CHANGES.md']);
    expect(named.exitCode, 0, reason: '${named.stdout}${named.stderr}');

    _write('notes/CHANGES.md', _shipped);
    _write('CHANGELOG.md', _withNext);
    final other = _verify(['--changelog', 'notes/CHANGES.md']);
    expect(other.exitCode, 1, reason: '${other.stdout}${other.stderr}');
    expect('${other.stderr}', contains('notes/CHANGES.md § 1.0.1'));
  });

  test('--app-dir is the pubspec that is read', () {
    // The changelog stays at the repository root; only the version moves.
    _write('pubspec.yaml', 'name: workspace\nversion: 9.9.9\n');
    _write('app/pubspec.yaml', 'name: consumer\nversion: 1.0.1+2\n');
    _write('CHANGELOG.md', _shipped);

    final result = _verify([], global: ['--app-dir', 'app']);
    expect(result.exitCode, 1, reason: '${result.stdout}${result.stderr}');
    expect('${result.stderr}', contains('§ 1.0.1'));
    expect('${result.stderr}', isNot(contains('9.9.9')));
  });

  test('no pubspec version means nothing to compare, not a failure', () {
    _write('CHANGELOG.md', _shipped);

    final result = _verify([]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect('${result.stdout}', isNot(contains('section    ')));
  });
}
