/// Turning a destination's declared `command` into something to spawn.
///
/// **The table's `command` has been a string nothing read since it was
/// written.** `_checkedStep` refuses a `ship` or `run` step without one and
/// refuses one on a step that spawns nothing, so the field has always been
/// checked for presence and never for meaning. This file is where it acquires
/// one, and the two decisions below are the whole of it.
///
/// **It is split into arguments here, and never handed to a shell.** The
/// alternative — `sh -c '<command>'` — buys pipes and redirection for free,
/// and the price is that every value the train interpolates becomes shell
/// source: a version named `1.9.13; rm -rf ~` would be two commands, and a
/// destination's `command` is written once and read by whoever inherits the
/// repository. A consumer who wants a pipeline writes a script and names the
/// script, which is what every row in AuthPass's table does anyway.
///
/// **Interpolation happens after the split, which is the fail-closed half.**
/// Substituting first and splitting the result would let a value containing a
/// space become two arguments — `--release '1.9.13 beta'` arriving at a store
/// as `--release 1.9.13 beta` — and a value containing a quote change where
/// every later argument begins. Doing it this way, a value lands in exactly
/// one argument whatever is in it, and the only thing a template can do with
/// the shape of the command line is written in the template.
library;

/// A `command` this file would not run, and why.
class StepCommandException implements Exception {
  StepCommandException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The placeholders a template may use, and what each one names.
///
/// **Four, and deliberately not "whatever the caller passes".** The set is
/// fixed here rather than taken from the values map so that an unknown
/// placeholder is an error at the one place that can explain it — a template
/// written against a key this package does not define is a step that would
/// otherwise spawn with a literal `{artifact}` in its argument list and be
/// recorded as handed over.
const Set<String> stepPlaceholders = {
  'version',
  'build',
  'destination',
  'stage',
};

/// Splits [template] into argv and substitutes `{name}` from [values].
///
/// [where] names the step in a message — `play.beta.command`, say.
///
/// Quoting is the POSIX subset a person writing a table would expect: a
/// backslash escapes the next character, `'...'` is literal, and `"..."`
/// allows backslash escapes. A `{` that opens nothing closed is refused rather
/// than passed through, because a template that meant to interpolate and
/// silently did not is the failure this whole file exists to make loud.
List<String> resolveStepCommand(
  String template, {
  required Map<String, String> values,
  required String where,
}) {
  _refuseShellSyntax(template, where);
  final argv = _split(template, where);
  if (argv.isEmpty) {
    throw StepCommandException(
      '$where is empty, and a step that spawns nothing would be reported as '
      'done.',
    );
  }
  return [for (final argument in argv) interpolate(argument, values, where)];
}

/// What a shell would act on and this does not.
///
/// Each is followed by what it would otherwise become as an argument.
const Map<String, String> _shellSyntax = {
  '&&': 'two commands',
  '||': 'two commands',
  '|': 'a pipeline',
  ';': 'two commands',
  '>': 'a redirection',
  '<': 'a redirection',
  r'$': 'a variable',
  '`': 'a command substitution',
  // **`*` is here and `?` is not**, which is a judgement about false
  // positives rather than about globbing. Both are globs to a shell, but `?`
  // is ordinary inside a URL — `curl https://host/p?v=1` is a plausible `run`
  // step — and refusing that would make the guard something consumers quote
  // their way around out of habit. An unquoted `*` in a command template is
  // nearly always somebody expecting a glob they will not get.
  '*': 'a glob',
};

/// Refuses a template that reads as shell and would silently not behave as it.
///
/// **This is the half the no-shell decision was missing.** Nothing here
/// reaches a shell, which is deliberate — see the library comment — but a
/// consumer writing `make build && ./upload.sh` does not get an error, they
/// get `make` run with `build`, `&&` and `./upload.sh` as three arguments.
/// Plenty of programs ignore arguments they do not understand, so the step
/// then succeeds and is recorded as handed over while the upload never ran.
/// That is precisely the "meant to do something and silently did not" failure
/// this file exists to make loud, and the splitter was committing it.
///
/// **Quoted is allowed through**, because a quoted `*` or `$` is somebody
/// saying they mean the character: `--message "cost: $5"` is a literal, and
/// only an unquoted one reads as syntax.
void _refuseShellSyntax(String template, String where) {
  for (final token in _unquotedTokens(template)) {
    throw StepCommandException(
      '$where contains `$token`, which to a shell is ${_shellSyntax[token]}. '
      'Nothing here runs a shell, so it would reach the command as an '
      'ordinary argument instead — and a program that ignores an argument it '
      'does not understand would then be recorded as having done the work. '
      'Put it in a script and name the script, or quote the character if you '
      'meant it literally.',
    );
  }
  // **A leading `~` is the one that is not punctuation.** It is expanded by
  // the shell and by nothing else, so `~/bin/ship` names a directory called
  // `~` — which fails to start, loudly, only because no such program exists.
  if (template.startsWith('~')) {
    throw StepCommandException(
      '$where begins with `~`, which only a shell expands. Write the path out '
      'or name a program on the PATH.',
    );
  }
}

/// Every unquoted shell token in [template], longest match first.
Iterable<String> _unquotedTokens(String template) sync* {
  var index = 0;
  while (index < template.length) {
    final char = template[index];
    if (char == r'\') {
      index += 2;
      continue;
    }
    if (char == "'" || char == '"') {
      final close = template.indexOf(char, index + 1);
      // An unterminated quote is the splitter's error to report, with its own
      // message; stopping here leaves it to say so.
      if (close == -1) {
        return;
      }
      index = close + 1;
      continue;
    }
    final pair = index + 1 < template.length
        ? template.substring(index, index + 2)
        : '';
    // The pair first, so `&&` is reported as itself rather than as a stray
    // `&` — which is not in the map at all, because a trailing `&` is one
    // command backgrounded and reads nothing like the others.
    if (_shellSyntax.containsKey(pair)) {
      yield pair;
      index += 2;
      continue;
    }
    if (_shellSyntax.containsKey(char)) {
      yield char;
    }
    index++;
  }
}

/// What a backslash may escape outside quotes: separators, quotes, itself,
/// and every character [_shellSyntax] refuses, so that escaping one is how a
/// template says it meant the character literally.
final Set<String> _escapable = {
  ' ',
  '\t',
  '\n',
  "'",
  '"',
  r'\',
  ..._shellSyntax.keys.where((it) => it.length == 1),
};

/// Splits on unquoted whitespace, honouring the three quoting forms.
List<String> _split(String template, String where) {
  final argv = <String>[];
  final current = StringBuffer();
  var started = false;
  var index = 0;

  void flush() {
    if (started) {
      argv.add(current.toString());
      current.clear();
      started = false;
    }
  }

  while (index < template.length) {
    final char = template[index];
    if (char == r'\') {
      if (index + 1 >= template.length) {
        throw StepCommandException(
          '$where ends in a backslash, which escapes nothing.',
        );
      }
      final next = template[index + 1];
      // **A backslash escapes only what there is a reason to escape, and is
      // otherwise a backslash. This is a deliberate difference from a
      // shell.** A shell drops it either way, so `C:\tools\ship.exe` arrives
      // as `C:toolsship.exe` — a Windows path destroyed by a rule written for
      // escaping spaces. Nothing is lost by the narrower reading: the
      // characters anybody escapes on purpose are still escapable, and a
      // backslash before a letter now means the one thing somebody typing it
      // could have wanted.
      if (_escapable.contains(next)) {
        current.write(next);
        index += 2;
      } else {
        current.write(char);
        index++;
      }
      started = true;
      continue;
    }
    if (char == "'" || char == '"') {
      index = _quoted(template, index, current, where);
      started = true;
      continue;
    }
    if (char == ' ' || char == '\t' || char == '\n') {
      flush();
      index++;
      continue;
    }
    current.write(char);
    started = true;
    index++;
  }
  flush();
  return argv;
}

/// Consumes the quoted run starting at [open], returning the index after it.
int _quoted(String template, int open, StringBuffer into, String where) {
  final quote = template[open];
  var index = open + 1;
  while (index < template.length) {
    final char = template[index];
    if (char == quote) {
      return index + 1;
    }
    // **Inside double quotes a backslash escapes only what a shell lets it
    // escape**, and anything else is a literal backslash. The first version
    // escaped the next character whatever it was, which turned
    // `"C:\tools\ship.exe"` into `C:toolsship.exe` — a Windows path quietly
    // destroyed by the quoting that was supposed to protect it. POSIX says a
    // backslash in a double-quoted run is special only before `$`, a
    // backtick, `"`, `\` or a newline; everywhere else it stands for itself.
    // A single-quoted run is literal throughout, so a backslash in one is a
    // backslash.
    if (char == r'\' && quote == '"') {
      if (index + 1 >= template.length) {
        throw StepCommandException(
          '$where ends in a backslash, which escapes nothing.',
        );
      }
      final next = template[index + 1];
      if (next == r'$' || next == '`' || next == '"' || next == r'\') {
        into.write(next);
        index += 2;
        continue;
      }
      into.write(char);
      index++;
      continue;
    }
    into.write(char);
    index++;
  }
  throw StepCommandException(
    '$where has an unterminated $quote — every quote has to be closed, '
    'because where it closes decides where the next argument begins.',
  );
}

/// Replaces every `{name}` in [argument], refusing a name nobody defines.
///
/// **Public because the `uploaded/` tag is a template too.** That name is the
/// consumer's convention — `tag.upload.format` in `cux_ship` — so the train
/// takes it as a pattern rather than composing it, and a second substituter
/// for it would be a second vocabulary: `{version}` meaning one thing in a
/// command and another in a tag is the kind of difference nobody discovers
/// until a record is written under a name that does not exist.
String interpolate(String argument, Map<String, String> values, String where) {
  final out = StringBuffer();
  var index = 0;
  while (index < argument.length) {
    final char = argument[index];
    if (char != '{') {
      out.write(char);
      index++;
      continue;
    }
    final close = argument.indexOf('}', index);
    if (close == -1) {
      throw StepCommandException(
        '$where has a `{` that is never closed. Write `{version}`, '
        '`{build}`, `{destination}` or `{stage}`; a brace that interpolates '
        'nothing would reach the command as itself.',
      );
    }
    final name = argument.substring(index + 1, close);
    if (!stepPlaceholders.contains(name)) {
      throw StepCommandException(
        '$where interpolates `{$name}`, which this package does not define. '
        'It knows ${stepPlaceholders.join(', ')}.',
      );
    }
    final value = values[name];
    if (value == null) {
      // **It said "a bug in cux_train" and stopped being true the moment this
      // function went public.** `--uploaded-tag` is a template an operator
      // types and is interpolated with two of the four names, so
      // `--uploaded-tag 'up/{destination}/{build}'` — a reasonable thing to
      // try — met a message telling them the tool was broken. The caller says
      // which names it has, and the message names them.
      throw StepCommandException(
        '$where interpolates `{$name}`, which is not one of the names it can '
        'use here: ${values.keys.join(', ')}.',
      );
    }
    out.write(value);
    index = close + 1;
  }
  return out.toString();
}
