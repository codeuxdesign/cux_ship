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

  group('what reads as shell and is not', () {
    // **These all used to pass silently**, which is the failure this file
    // claims to exist against: `make build && ./upload.sh` ran `make` with
    // three arguments, and a program that ignores what it does not recognise
    // would then be recorded as having done the upload.
    for (final template in [
      'make build && ./upload.sh',
      'a || b',
      './upload.sh | tee log',
      'a; b',
      './upload.sh > log.txt',
      './upload.sh < in.txt',
      r'ship $HOME/out.apk',
      'ship `date`',
      'ship build/*.apk',
    ]) {
      test('refuses `$template`', () {
        expect(
          () => _resolve(template),
          throwsA(
            isA<StepCommandException>().having(
              (e) => e.message,
              'message',
              allOf(contains('shell'), contains('script')),
            ),
          ),
          reason: 'it would reach the command as an ordinary argument',
        );
      });
    }

    test('refuses a leading ~, which only a shell expands', () {
      expect(
        () => _resolve('~/bin/ship'),
        throwsA(isA<StepCommandException>()),
      );
    });

    test('a quoted one is allowed, because quoting says it is literal', () {
      expect(_resolve('ship --message "cost: \$5"'), [
        'ship',
        '--message',
        r'cost: $5',
      ]);
      expect(_resolve("ship --glob '*.apk'"), ['ship', '--glob', '*.apk']);
    });

    test('an escaped one is allowed too', () {
      expect(_resolve(r'ship --price \$5'), ['ship', '--price', r'$5']);
    });

    test('a ? is not refused, because a URL is not a glob', () {
      // Unlike `*`: a query string is an ordinary argument to `curl`, and
      // refusing it would teach consumers to quote their way past the guard.
      expect(_resolve('curl https://host/p?v=1'), [
        'curl',
        'https://host/p?v=1',
      ]);
    });
  });

  group('backslashes, which a Windows path is made of', () {
    test('an unquoted path keeps its separators', () {
      // A shell drops these, leaving `C:toolsship.exe`. That is a path
      // destroyed by a rule meant for escaping spaces, so this deliberately
      // differs: a backslash before a letter is a backslash.
      expect(_resolve(r'C:\tools\ship.exe play'), [
        r'C:\tools\ship.exe',
        'play',
      ]);
      expect(_resolve(r'cmd tool\upload.bat'), ['cmd', r'tool\upload.bat']);
    });

    test('a double-quoted path keeps them too', () {
      expect(_resolve(r'cmd "C:\tools\ship.exe"'), [
        'cmd',
        r'C:\tools\ship.exe',
      ]);
    });

    test('but it still escapes what there is a reason to escape', () {
      expect(_resolve(r'cmd one\ two'), ['cmd', 'one two']);
      expect(_resolve(r'cmd a\"b'), ['cmd', 'a"b']);
      expect(_resolve(r'cmd a\\b'), [r'cmd', r'a\b']);
    });

    test('inside double quotes it escapes only what POSIX says', () {
      expect(_resolve(r'cmd "a\"b"'), ['cmd', 'a"b']);
      expect(_resolve(r'cmd "a\nb"'), [r'cmd', r'a\nb']);
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
              // **The vocabulary message, not the one about this call.**
              // There are two: a name the package does not define at all, and
              // a name it defines that this particular caller has no value
              // for — `--uploaded-tag` gets only two of the four. Asserting
              // the four names alone could not tell them apart, and a
              // mutation that removed this guard survived because of it.
              contains('does not define'),
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
            allOf(contains('--uploaded-tag'), contains('does not define')),
          ),
        ),
      );
    });

    test('a name it knows but this caller has no value for blames the '
        'caller, not the package', () {
      // `--uploaded-tag` is interpolated with `version` and `build` only, so
      // `{destination}` is a reasonable thing for an operator to try. The
      // message used to say "That is a bug in cux_train rather than in the
      // table", which stopped being true the moment this function was shared
      // with a two-key caller.
      expect(
        () => interpolate('up/{destination}/{build}', {
          'version': '1.9.13',
          'build': '2196',
        }, '--uploaded-tag'),
        throwsA(
          isA<StepCommandException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('{destination}'),
              contains('version, build'),
              isNot(contains('bug in cux_train')),
            ),
          ),
        ),
      );
    });
  });
}
