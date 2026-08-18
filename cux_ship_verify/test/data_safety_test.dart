// SPDX-License-Identifier: Apache-2.0
import 'package:cux_ship_verify/cux_ship_verify.dart';
import 'package:test/test.dart';

/// A minimal well-formed export: the header, one REQUIRED question answered,
/// and one multiple-choice row that is legitimately blank.
const _good = '''
Question ID (machine readable),Response ID (machine readable),Response value,Answer requirement,Human-friendly question label
PSL_DATA_COLLECTION_COLLECTS_PERSONAL_DATA,,FALSE,REQUIRED,Does your app collect or share any of the required user data types?
PSL_SUPPORTED_ACCOUNT_CREATION_METHODS,PSL_ACM_OAUTH,,MULTIPLE_CHOICE,Which of the following methods of account creation does your app support? Select all that apply / OAuth
''';

void main() {
  group('parseCsv', () {
    test('reads quoted fields containing commas', () {
      final records = parseCsv('a,b,"c, and d"\n');
      expect(records, hasLength(1));
      expect(records.single, ['a', 'b', 'c, and d']);
    });

    test('reads a doubled quote as one literal quote', () {
      final records = parseCsv('a,"he said ""no"""\n');
      expect(records.single.last, 'he said "no"');
    });

    test('accepts CRLF as well as LF', () {
      expect(parseCsv('a,b\r\nc,d\r\n'), [
        ['a', 'b'],
        ['c', 'd'],
      ]);
    });

    test('a trailing newline does not produce an empty record', () {
      expect(parseCsv('a,b\n'), hasLength(1));
    });

    test('refuses an unterminated quoted value rather than guessing', () {
      // The failure this prevents is silent: an unclosed quote swallows every
      // row after it, and a parser that shrugged would report a short file as
      // a complete one.
      expect(
        () => parseCsv('a,"b\nc,d\n'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('ends inside a quoted value'),
          ),
        ),
      );
    });

    test('refuses a quote that opens mid-field', () {
      expect(() => parseCsv('a,b"c"\n'), throwsA(isA<FormatException>()));
    });

    test('refuses text after a closing quote rather than concatenating', () {
      // `"abc"def` silently becoming `abcdef` is a mangled value read as a
      // good one, which is the one thing this parser must not do.
      expect(() => parseCsv('"abc"def\n'), throwsA(isA<FormatException>()));
    });

    test('drops whitespace between a closing quote and the delimiter', () {
      // Appending it is worse than it sounds: `"REQUIRED" ,` would yield
      // "REQUIRED " and stop matching, so a required question would silently
      // read as optional.
      expect(parseCsv('"REQUIRED" ,b\n').single, ['REQUIRED', 'b']);
    });

    test('names the line a quoted value spans from, not where it ended', () {
      expect(
        () => parseCsv('a,b\n"unterminated\nmore\nmore\n'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('opened on line 2'),
          ),
        ),
      );
    });

    test('keeps real line numbers across a value that spans newlines', () {
      final records = parseCsvRecords('a,"two\nlines"\nc,d\n');
      expect(records.map((r) => r.line), [1, 3]);
    });

    test('keeps real line numbers across a blank line', () {
      final records = parseCsvRecords('a,b\n\nc,d\n');
      expect(records.map((r) => r.line), [1, 3]);
    });
  });

  group('checkDataSafety', () {
    test('accepts a well-formed export', () {
      expect(checkDataSafety(_good), isEmpty);
    });

    test('names the header when it is not the one Play exports', () {
      final problems = checkDataSafety('one,two,three\n1,2,3\n');
      expect(problems, hasLength(1));
      expect(problems.single.message, contains('not the one Play exports'));
    });

    test('reports a REQUIRED question with no response value', () {
      final broken = _good.replaceFirst(',,FALSE,REQUIRED,', ',,,REQUIRED,');
      final problems = checkDataSafety(broken);
      expect(
        problems.map((p) => p.message),
        contains(contains('is REQUIRED and has no response value')),
      );
    });

    test('reports a row with the wrong number of fields', () {
      final problems = checkDataSafety(
        '$_good'
        'short,row\n',
      );
      expect(
        problems.map((p) => p.message),
        contains(contains('has 2 fields')),
      );
    });

    test('reports a repeated question and response', () {
      final duplicated =
          '$_good'
          'PSL_SUPPORTED_ACCOUNT_CREATION_METHODS,PSL_ACM_OAUTH,,MULTIPLE_CHOICE,again\n';
      final problems = checkDataSafety(duplicated);
      expect(problems.map((p) => p.message), contains(contains('repeats')));
    });

    test('reports a file with no REQUIRED question at all', () {
      final noRequired = _good
          .split('\n')
          .where((l) => !l.contains(',REQUIRED,'))
          .join('\n');
      final problems = checkDataSafety(noRequired);
      expect(
        problems.map((p) => p.message),
        contains(contains('no REQUIRED question')),
      );
    });

    test('accepts requirement values it has never heard of', () {
      // Regression. An earlier draft enumerated REQUIRED, MAYBE_REQUIRED and
      // MULTIPLE_CHOICE and reported everything else as unrecognised. Run
      // against a real declaration that produced 88 problems on a file Play
      // accepts and serves, because exports also use SINGLE_CHOICE and
      // OPTIONAL. Only REQUIRED carries an obligation this can check; the
      // vocabulary is Play's and is not copied here.
      final exotic =
          '$_good'
          'PSL_SUPPORT_DATA_DELETION_BY_USER,PSL_YES,,SINGLE_CHOICE,label\n'
          'PSL_INDEPENDENTLY_VALIDATED,,,OPTIONAL,label\n'
          'PSL_SOMETHING_NEW,,,A_LEVEL_INVENTED_NEXT_YEAR,label\n';
      expect(checkDataSafety(exotic), isEmpty);
    });

    test('reports a blank answer requirement', () {
      final blank =
          '$_good'
          'PSL_X,,,,label\n';
      expect(
        checkDataSafety(blank).map((p) => p.message),
        contains(contains('no answer requirement')),
      );
    });
  });

  group('checkDataSafetyFile', () {
    test('says so when the file is not there', () {
      final problems = checkDataSafetyFile('does/not/exist.csv');
      expect(problems.single.message, 'no such file');
    });
  });
}
