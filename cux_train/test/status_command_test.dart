// `status` end to end: a table on disk, records in a real repository, a grid
// on stdout.
//
// **In process rather than spawned, and the two existing CLI suites stay
// spawned.** `cli_library_entry_test.dart` and `usage_test.dart` assert things
// that are only true of a *process* — that the VM accepts the library as a
// script, which stream each kind of output lands on, what the exit code is —
// and none of those can be observed from inside. What this file asserts is
// what the verb does with what it reads, which a spawn would let it check only
// through text, one VM start per case.
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cux_train/cux_train.dart';
import 'package:cux_train/runner.dart';
import 'package:cux_train/src/status_command.dart';
import 'package:test/test.dart';

late Directory _root;
late Git _git;

/// A table with one destination of each shape that matters to a grid: one a
/// person acts on at production, and one nobody acts on anywhere.
const _table = '''
destinations:
  huawei:
    internal: {kind: run, command: "_tools/upload-artifact.sh"}
    beta: none
    production:
      kind: manual
      console: "https://developer.huawei.com"
  flathub:
    production: none
''';

void _writeTable(String yaml, {String name = defaultTableFile}) =>
    File('${_root.path}/$name').writeAsStringSync(yaml);

void _commit() {
  File('${_root.path}/file.txt').writeAsStringSync('a release');
  _git.run(['add', '-A']);
  _git.run(['commit', '-q', '-m', 'a release']);
}

void _tag(String name, String body) =>
    _git.run(['tag', '-a', name, '-m', body]);

/// Runs the verb with its working directory and its repository both at [_root].
///
/// A runner of its own rather than [buildRunner], because the root has to be
/// injected; that the real tree offers the same verb is asserted separately, so
/// the wiring between the two is not something only this file knows.
Future<String> _status(List<String> args) async {
  final output = StringBuffer();
  final runner = CommandRunner<void>('cux_train', 'under test')
    ..addCommand(StatusCommand(output: output, root: _root.path));
  await runner.run(['status', ...args]);
  return output.toString();
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('cux_train_status');
    _git = Git(_root.path);
    _git.run(['init', '-q', '-b', 'main']);
    _git.run(['config', 'user.email', 'test@example.com']);
    _git.run(['config', 'user.name', 'Test']);
    _commit();
    _writeTable(_table);
  });

  tearDown(() => _root.deleteSync(recursive: true));

  group('the grid it prints', () {
    test(
      'renders every declared destination for the named candidate',
      () async {
        final out = await _status(['--build', '2196', '--release', '1.9.13']);

        expect(out, startsWith('1.9.13 — build 2196'));
        expect(out, contains('huawei'));
        expect(out, contains('flathub'));
        // Nothing is recorded, so the row a person acts on is `pending` and the
        // row nobody acts on is `n/a`. That difference is the whole evidence
        // model showing up on a command line for the first time.
        expect(out, contains('pending'));
        expect(out, contains('n/a'));
      },
    );

    test('a record for the candidate reaches its cell', () async {
      _tag('promoted/huawei/production/v1.9.13+2196', 'handed over');

      final out = await _status(['--build', '2196', '--release', '1.9.13']);

      expect(out, contains('2196 attested'));
    });

    test('a record for another build does not', () async {
      // **The ledger is keyed to one build because it is history.** Every
      // release ever made lives in `promoted/`, so a grid that read the
      // namespace without filtering would report last release's hand-over as
      // this candidate's.
      _tag('promoted/huawei/production/v1.9.12+1940', 'last release');

      final out = await _status(['--build', '2196', '--release', '1.9.13']);

      expect(out, isNot(contains('1940')));
      expect(out, contains('pending'));
    });

    test('--release is checked against the records, not just printed', () {
      // **The flag was a label.** The ledger filtered on build alone, so a
      // record for build 2196 of 1.9.13 was rendered under whatever version
      // was typed: `--release 1.9.99` printed `1.9.99 — build 2196` and
      // `2196 attested`, exit 0. That is precisely the "confidently about the
      // wrong release" failure this flag is required in order to prevent, so
      // the requirement was buying nothing until the value was compared.
      _tag('promoted/huawei/production/v1.9.13+2196', 'handed over');

      return expectLater(
        _status(['--build', '2196', '--release', '1.9.99']),
        throwsA(
          isA<PromotionRecordException>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('1.9.13'), contains('1.9.99')),
          ),
        ),
      );
    });
  });

  group('the refs it asks git for', () {
    test('covers every namespace an outcome declares', () {
      // **The guard this exists for is not "it reads two namespaces".** The
      // finish rule counts what is outstanding over these refs, so a namespace
      // the reader forgets is not a missing row in a report — it is a
      // destination the rule stops waiting on, and the release tag is spent
      // early. Deriving the patterns from the enum is what makes a third
      // outcome reach this call without anybody remembering to come here, and
      // this case fails the moment somebody writes the two names out.
      _tag('promoted/huawei/production/v1.9.13+2196', 'd');
      _tag('refused/huawei/production/v1.9.13+2196', 'f');
      _tag('uploaded/v1.9.13+2196', 'not a record');

      final refs = promotionRefs(_git);

      expect(refs, hasLength(PromotionOutcome.values.length));
      for (final outcome in PromotionOutcome.values) {
        expect(
          refs.any((ref) => ref.startsWith('${outcome.namespace}/')),
          isTrue,
          reason: 'no ref read for ${outcome.namespace}',
        );
      }
      // The `uploaded/` tag is in the same repository and is not a record.
      expect(refs, isNot(contains('uploaded/v1.9.13+2196')));
    });

    test('a refusal wins over a hand-over, through the command', () async {
      // Both can exist — `f` on Monday, the console accepts on Thursday — and
      // the ledger returns the worse of the two. This asserts the command does
      // not quietly read one namespace and render it.
      _tag('promoted/huawei/production/v1.9.13+2196', 'd');
      _tag('refused/huawei/production/v1.9.13+2196', 'f');

      final out = await _status(['--build', '2196', '--release', '1.9.13']);

      expect(out, contains('failed'));
    });
  });

  group('what it refuses', () {
    test('a table that is not there, by name, and not as a usage error', () {
      File('${_root.path}/$defaultTableFile').deleteSync();

      return expectLater(
        _status(['--build', '2196', '--release', '1.9.13']),
        throwsA(
          isA<DestinationTableException>().having(
            (e) => e.message,
            'message',
            allOf(contains(defaultTableFile), contains('--table')),
          ),
        ),
      );
    });

    test('a candidate it was not given', () {
      return expectLater(
        _status(['--release', '1.9.13']),
        throwsA(
          isA<UsageException>().having(
            (e) => e.message,
            'message',
            allOf(contains('--build'), contains('refs/buildnumbers')),
          ),
        ),
      );
    });

    test('a candidate that is not a number', () {
      return expectLater(
        _status(['--build', 'latest', '--release', '1.9.13']),
        throwsA(
          isA<UsageException>().having(
            (e) => e.message,
            'message',
            contains('`latest` is not one'),
          ),
        ),
      );
    });

    test('a release it was not given', () {
      return expectLater(
        _status(['--build', '2196']),
        throwsA(
          isA<UsageException>().having(
            (e) => e.message,
            'message',
            contains('--release'),
          ),
        ),
      );
    });

    test('a build of zero, which the grid itself will not hold', () {
      // The flag parses and the grid refuses it. Asserted here because the
      // command is where the two meet: a verb that clamped or defaulted it
      // would make the grid's own guard unreachable.
      return expectLater(
        _status(['--build', '0', '--release', '1.9.13']),
        throwsA(isA<StatusGridException>()),
      );
    });

    test('a build spelled in hex, which int.tryParse would read', () {
      // `0x10` parses as sixteen, and the grid for build 16 renders without
      // complaint — every cell `pending`, which is also what a real candidate
      // with nothing recorded looks like.
      return expectLater(
        _status(['--build', '0x10', '--release', '1.9.13']),
        throwsA(
          isA<UsageException>().having(
            (e) => e.message,
            'message',
            contains('`0x10` is not one'),
          ),
        ),
      );
    });

    test('a word after the flags, rather than dropping it', () {
      // `package:args` hands a leaf command its positional arguments and does
      // not check that anything read them. Without the guard this prints the
      // whole grid and exits 0, and `production` did nothing.
      return expectLater(
        _status(['--build', '2196', '--release', '1.9.13', 'production']),
        throwsA(
          isA<UsageException>().having(
            (e) => e.message,
            'message',
            contains('production'),
          ),
        ),
      );
    });

    test('--store, because status does not narrow', () {
      // Not wired on this verb, and the thing to hold is that it is *refused*:
      // declared and unread, it would be the flag that does nothing. A verb
      // that learns to narrow replaces this case rather than deleting it.
      return expectLater(
        _status([
          '--build',
          '2196',
          '--release',
          '1.9.13',
          '--store',
          'huawei',
        ]),
        throwsA(isA<UsageException>()),
      );
    });

    test('a table that is a directory, as that and not as missing', () {
      Directory('${_root.path}/tables').createSync();

      return expectLater(
        _status([
          '--build',
          '2196',
          '--release',
          '1.9.13',
          '--table',
          'tables',
        ]),
        throwsA(
          isA<DestinationTableException>().having(
            (e) => e.message,
            'message',
            allOf(contains('tables'), contains('is a directory')),
          ),
        ),
      );
    });

    test('a table that cannot be read, as a table problem', () {
      // Bytes that are not UTF-8 make `readAsStringSync` throw a
      // `FileSystemException`, which `cli.dart` has no clause for.
      File('${_root.path}/$defaultTableFile').writeAsBytesSync([0xff, 0xfe]);

      return expectLater(
        _status(['--build', '2196', '--release', '1.9.13']),
        throwsA(
          isA<DestinationTableException>().having(
            (e) => e.message,
            'message',
            allOf(contains(defaultTableFile), contains('could not be read')),
          ),
        ),
      );
    });

    test('a ref in a record namespace that is not a record', () {
      // **Whatever build it was asked about.** The ledger parses every ref
      // before it filters, so one hand-written `promoted/` tag stops `status`
      // for every release until it is removed. That is the library's rule
      // reaching the command line, held here so that a reader who "fixes" it
      // by skipping has a case to argue with.
      _tag('promoted/oops', 'by hand');

      return expectLater(
        _status(['--build', '2196', '--release', '1.9.13']),
        throwsA(
          isA<PromotionRecordException>().having(
            (e) => e.message,
            'message',
            contains('promoted/oops'),
          ),
        ),
      );
    });
  });

  group('the command tree', () {
    test('offers status, so the wiring is not only in this file', () {
      expect(buildRunner().commands.keys, contains('status'));
    });

    test('names the table file the plan settled on', () {
      // §4: the table would live in `.cux-ship.yaml`, and cannot, because an
      // unknown key there throws on every command. A rename here is a change
      // to what consumers put in their repository root.
      expect(defaultTableFile, '.cux-train.yaml');
    });
  });
}
