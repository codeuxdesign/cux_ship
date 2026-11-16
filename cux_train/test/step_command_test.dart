// A destination's `command` is written once, by whoever set the table up, and
// then spawned on every release for years. These cases are mostly about what
// it must *not* be able to do — turn one value into two arguments, or reach
// the shell — because those two failures are silent and land in a store.
import 'package:cux_train/cux_train.dart';
import 'package:test/test.dart';

const _values = {
  'version': '1.9.13',
  'build': '2196',
  'destination': 'play',
  'stage': 'beta',
};

List<String> _resolve(String template, {Map<String, String>? values}) =>
    resolveStepCommand(
      template,
      values: values ?? _values,
      where: 'play.beta.command',
    );

void main() {
  group('splitting', () {
    test('splits on unquoted whitespace', () {
      expect(_resolve('bin/ship play --track beta'), [
        'bin/ship',
        'play',
        '--track',
        'beta',
      ]);
    });

    test('collapses runs of whitespace, including tabs and newlines', () {
      expect(_resolve('a  \t b \n c'), ['a', 'b', 'c']);
    });

    test('a single-quoted run is one argument and is literal', () {
      expect(_resolve(r"say 'one two \n'"), ['say', r'one two \n']);
    });

    test('a double-quoted run honours the backslash', () {
      expect(_resolve(r'say "one \"two\""'), ['say', 'one "two"']);
    });

    test('a backslash escapes a space outside quotes', () {
      expect(_resolve(r'cmd one\ two'), ['cmd', 'one two']);
    });

    test('an empty quoted run is an argument, not nothing', () {
      // `--notes ''` is how a caller says "deliberately blank", and dropping
      // it would shift every later argument one place left.
      expect(_resolve("cmd --notes '' --last"), [
        'cmd',
        '--notes',
        '',
        '--last',
      ]);
    });

    test('an unterminated quote is refused, naming the step', () {
      expect(
        () => _resolve("cmd 'never closed"),
        throwsA(
          isA<StepCommandException>().having(
            (e) => e.message,
            'message',
            allOf(contains('play.beta.command'), contains('unterminated')),
          ),
        ),
      );
    });

    test('a trailing backslash is refused rather than dropped', () {
      expect(() => _resolve(r'cmd one\'), throwsA(isA<StepCommandException>()));
    });

    test('a template with nothing in it is refused', () {
      expect(() => _resolve('   '), throwsA(isA<StepCommandException>()));
    });
  });

  group('interpolation', () {
    test('substitutes every placeholder it defines', () {
      expect(_resolve('ship {destination} {stage} {version} {build}'), [
        'ship',
        'play',
        'beta',
        '1.9.13',
        '2196',
      ]);
    });

    test('substitutes more than once in one argument', () {
      expect(_resolve('ship v{version}+{build}'), ['ship', 'v1.9.13+2196']);
    });

    test('a value containing a space stays one argument', () {
      // The reason interpolation happens after the split. Were it the other
      // way round, a store would be handed `--notes 1.9.13` and a stray
      // `beta`, and the step would still be recorded as handed over.
      expect(
        _resolve(
          'ship --notes {version}',
          values: {..._values, 'version': '1.9.13 beta'},
        ),
        ['ship', '--notes', '1.9.13 beta'],
      );
    });

    test('a value containing shell punctuation is still one argument', () {
      // Nothing here reaches a shell, so this is not an escaping question —
      // the characters survive exactly as given, which is the only safe
      // answer when the command line is composed from a version string.
      expect(
        _resolve(
          'ship {version}',
          values: {
            ..._values,
            'version': r'1.9.13; rm -rf ~ && echo $PATH | tee /tmp/x',
          },
        ),
        ['ship', r'1.9.13; rm -rf ~ && echo $PATH | tee /tmp/x'],
      );
    });

    test('a value containing a quote does not re-split the rest', () {
      expect(
        _resolve(
          'ship {version} --last',
          values: {..._values, 'version': "it's \"quoted\""},
        ),
        ['ship', 'it\'s "quoted"', '--last'],
      );
    });

    test('a placeholder nobody defines is refused, and lists the four', () {
      expect(
        () => _resolve('ship --file {artifact}'),
        throwsA(
          isA<StepCommandException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('{artifact}'),
              contains('version'),
              contains('build'),
              contains('destination'),
              contains('stage'),
            ),
          ),
        ),
      );
    });

    test('an unclosed brace is refused rather than passed through', () {
      // Passing it through is the silent half: the store tool is handed a
      // literal `{version` and the step is recorded as done.
      expect(
        () => _resolve('ship {version'),
        throwsA(
          isA<StepCommandException>().having(
            (e) => e.message,
            'message',
            contains('never closed'),
          ),
        ),
      );
    });

    test('a quoted placeholder is still interpolated', () {
      // Quoting is about splitting, not about meaning — somebody writing
      // `"{version}"` is guarding a space, not asking for a literal brace.
      expect(_resolve('ship "{version}"'), ['ship', '1.9.13']);
    });
  });

  group('interpolate, which the uploaded tag also uses', () {
    test('fills a tag pattern', () {
      expect(
        interpolate('uploaded/v{version}+{build}', _values, '--uploaded-tag'),
        'uploaded/v1.9.13+2196',
      );
    });

    test('refuses a placeholder the command vocabulary does not have', () {
      expect(
        () => interpolate('uploaded/{sha}', _values, '--uploaded-tag'),
        throwsA(
          isA<StepCommandException>().having(
            (e) => e.message,
            'message',
            contains('--uploaded-tag'),
          ),
        ),
      );
    });
  });
}
