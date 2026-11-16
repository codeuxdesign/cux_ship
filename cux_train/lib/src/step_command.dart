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
  final argv = _split(template, where);
  if (argv.isEmpty) {
    throw StepCommandException(
      '$where is empty, and a step that spawns nothing would be reported as '
      'done.',
    );
  }
  return [for (final argument in argv) interpolate(argument, values, where)];
}

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
      current.write(template[index + 1]);
      started = true;
      index += 2;
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
    // **Only a double quote honours the backslash**, which is what a shell
    // does and what anybody writing `"C:\\path"` or `'it'` is relying on. A
    // single-quoted run is literal, so a backslash in one is a backslash.
    if (char == r'\' && quote == '"') {
      if (index + 1 >= template.length) {
        throw StepCommandException(
          '$where ends in a backslash, which escapes nothing.',
        );
      }
      into.write(template[index + 1]);
      index += 2;
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
      // Not reachable from a caller that passes every placeholder, which is
      // why it says so rather than suggesting a fix: it is this package
      // disagreeing with itself, not the table being wrong.
      throw StepCommandException(
        '$where interpolates `{$name}`, which this run was not given a value '
        'for. That is a bug in cux_train rather than in the table.',
      );
    }
    out.write(value);
    index = close + 1;
  }
  return out.toString();
}
