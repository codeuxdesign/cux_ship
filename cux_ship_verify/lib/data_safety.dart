// SPDX-License-Identifier: Apache-2.0
//
// Play's data safety declaration, checked for **structure only**.
//
// This file is the one release input with no pre-release check of any kind, and
// the reason is in cux_ship's own upload path. `play upload --dry-run` discards
// its edit rather than validating it, and skips the declaration outright —
// `dry run — data safety declaration not sent`. In a real run it is a separate
// POST to `applications/<pkg>/dataSafety`, deliberately *after* the commit,
// because the declaration is not versioned with a release and applies to the
// app as a whole: sending it first would change what Play shows users even if
// the edit then failed to commit and the release never happened.
//
// That ordering is right and is not being changed. It does mean the failure
// window cannot be closed by reordering — every other Play input fails
// per-call inside the edit, or at commit, or is rehearsable, and this one is
// none of those. It fails after the release is already public. So an offline
// check is not merely the cheapest place to catch a broken declaration; it is
// the only place.
//
// **Structure, never content.** Whether the answers are *true* — whether a
// declaration matches what an app actually does — is a question about that app,
// and a general publishing tool has no way to answer it. It belongs to whichever
// repository makes the claim. What is checkable here is that the file is the
// shape Play exported and still parses as one.
//
// **There is nothing to specify.** The file is Play's own export and carries its
// schema in its rows: every question states its own `Answer requirement`. So
// this validates the file against itself rather than against a copy of Play's
// rules that would rot.
import 'dart:io';

import 'release_problem.dart';

/// The header Play writes, in the order it writes it.
///
/// Checked as an ordered list rather than a set: the columns are read
/// positionally below, so a file with the right names in the wrong order would
/// parse into the wrong fields and pass every later check.
const dataSafetyColumns = <String>[
  'Question ID (machine readable)',
  'Response ID (machine readable)',
  'Response value',
  'Answer requirement',
  'Human-friendly question label',
];

/// The one requirement level this package acts on.
///
/// **The vocabulary is deliberately not enumerated.** A first draft listed
/// `REQUIRED`, `MAYBE_REQUIRED` and `MULTIPLE_CHOICE` and reported anything else
/// as unrecognised — which is precisely the copy of Play's rules this file's
/// header says it avoids, and it rotted before it shipped: run against a real
/// declaration it produced 88 problems on a file Play accepts, because the
/// export also uses `SINGLE_CHOICE` and `OPTIONAL`, and one export is no
/// evidence about the next.
///
/// Only `REQUIRED` carries an obligation this can check. Every other value
/// means *not required*, and needs no name here to mean that.
const dataSafetyRequired = 'REQUIRED';

/// One row of the declaration, as read.
class DataSafetyRow {
  const DataSafetyRow({
    required this.line,
    required this.questionId,
    required this.responseId,
    required this.responseValue,
    required this.requirement,
    required this.label,
  });

  /// 1-based line in the file, for error messages. A 175 KB CSV is not a file
  /// anybody reads top to bottom, so a problem that cannot be located is a
  /// problem nobody fixes.
  final int line;

  final String questionId;
  final String responseId;
  final String responseValue;
  final String requirement;
  final String label;
}

/// Reads the CSV at [path] and reports everything structurally wrong with it.
///
/// Returns problems rather than throwing, and returns *all* of them, for the
/// same reason [checkAppStoreTree] does: told about them one at a time, the
/// second is found only after the first is fixed and pushed.
List<ReleaseProblem> checkDataSafetyFile(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    return [ReleaseProblem(path, 'no such file')];
  }
  return checkDataSafety(file.readAsStringSync(), where: path);
}

/// [checkDataSafetyFile] over already-read [csv].
List<ReleaseProblem> checkDataSafety(
  String csv, {
  String where = 'data safety',
}) {
  final problems = <ReleaseProblem>[];

  final List<CsvRecord> records;
  try {
    records = parseCsvRecords(csv);
  } on FormatException catch (e) {
    return [ReleaseProblem(where, e.message)];
  }

  if (records.isEmpty) {
    return [
      ReleaseProblem(
        where,
        'the file is empty — export it again from the Play Console, Data '
        'safety → Export to CSV',
      ),
    ];
  }

  final header = records.first.fields;
  if (header.length != dataSafetyColumns.length ||
      !_sameOrder(header, dataSafetyColumns)) {
    return [
      ReleaseProblem(
        where,
        'the header row is not the one Play exports.\n'
        '    found:    ${header.join(' | ')}\n'
        '    expected: ${dataSafetyColumns.join(' | ')}',
      ),
    ];
  }

  // Every later check reads fields by position, so a short or long row is
  // reported here and skipped rather than being silently read as some other
  // row's data.
  final rows = <DataSafetyRow>[];
  for (var i = 1; i < records.length; i++) {
    final record = records[i].fields;
    final line = records[i].line;
    if (record.length != dataSafetyColumns.length) {
      problems.add(
        ReleaseProblem(
          '$where line $line',
          'has ${record.length} fields, and every row has to have '
              '${dataSafetyColumns.length} — a value containing a comma must be '
              'quoted',
        ),
      );
      continue;
    }
    rows.add(
      DataSafetyRow(
        line: line,
        questionId: record[0],
        responseId: record[1],
        responseValue: record[2],
        requirement: record[3],
        label: record[4],
      ),
    );
  }

  for (final row in rows) {
    if (row.questionId.isEmpty) {
      problems.add(
        ReleaseProblem('$where line ${row.line}', 'has no question id'),
      );
    }
    if (row.requirement.isEmpty) {
      problems.add(
        ReleaseProblem(
          '$where line ${row.line}',
          '${row.questionId} has no answer requirement — the column that says '
              'whether it needs an answer is blank',
        ),
      );
    }
    if (row.requirement == dataSafetyRequired && row.responseValue.isEmpty) {
      problems.add(
        ReleaseProblem(
          '$where line ${row.line}',
          '${row.questionId} is REQUIRED and has no response value — Play '
              'refuses the declaration, after the release has been committed',
        ),
      );
    }
  }

  problems.addAll(_duplicates(rows, where));

  if (rows.every((r) => r.requirement != dataSafetyRequired)) {
    problems.add(
      ReleaseProblem(
        where,
        'no REQUIRED question in ${rows.length} row(s), which a Play export '
        'always has — this is more likely a truncated or hand-assembled file '
        'than a declaration with nothing to answer',
      ),
    );
  }

  return problems;
}

/// The same question and response appearing twice.
///
/// A hand-edit hazard rather than an export one: Play sends the answers it
/// holds, and the second copy of a row is the one somebody pasted.
List<ReleaseProblem> _duplicates(List<DataSafetyRow> rows, String where) {
  final seen = <String, int>{};
  final problems = <ReleaseProblem>[];
  for (final row in rows) {
    final key = '${row.questionId}\u0000${row.responseId}';
    final first = seen[key];
    if (first != null) {
      problems.add(
        ReleaseProblem(
          '$where line ${row.line}',
          'repeats ${row.questionId}'
              '${row.responseId.isEmpty ? '' : ' / ${row.responseId}'} from line '
              '$first — two answers to one question, and which one is sent is not '
              'something this file decides',
        ),
      );
    } else {
      seen[key] = row.line;
    }
  }
  return problems;
}

// **A check that was written here and deleted, because it was wrong.**
//
// "A response id belongs to one question" sounds like a safe internal
// invariant, and it is false. Play's response ids are reused across questions
// by design — `PSL_APP_FUNCTIONALITY` is a legitimate answer to the collection
// purpose question for *every* data type, and the question ids carry the data
// type instead (`…:PSL_NAME:DATA_USAGE_COLLECTION_PURPOSE` against
// `…:PSL_DEVICE_ID:DATA_USAGE_COLLECTION_PURPOSE`). Run against a real
// declaration the check produced 22 problems on a file Play has accepted and
// is serving.
//
// It is recorded rather than quietly removed because it is the exact failure
// this package exists to avoid, committed by this package: a check that fails
// what the store accepts is worse than one that passes vacuously, since the
// first response to a red board over a live listing is to find the flag that
// turns it off. Any future cross-row claim about Play's taxonomy has to be run
// against a live export before it ships.

bool _sameOrder(List<String> a, List<String> b) {
  for (var i = 0; i < a.length; i++) {
    if (a[i].trim() != b[i]) {
      return false;
    }
  }
  return true;
}

/// A CSV reader, because this package has no dependencies and is not getting
/// one for this.
///
/// It is the RFC 4180 subset Play actually emits: comma separated, `"` quoting,
/// `""` for a literal quote inside a quoted field, and CRLF or LF line endings.
/// Anything it cannot make sense of throws [FormatException] naming the line,
/// rather than guessing — a declaration read wrongly is worse than one that
/// refuses to be read.
List<List<String>> parseCsv(String input) =>
    parseCsvRecords(input).map((r) => r.fields).toList(growable: false);

/// One parsed record, with the line its first field started on.
///
/// The line is carried rather than reconstructed from the record's index: a
/// quoted value may span newlines and a blank line is not a record, so
/// "index + 1" is wrong for every row after the first of either. A 175 KB CSV
/// is not a file anybody reads top to bottom, so a problem that cannot be
/// located is a problem nobody fixes.
class CsvRecord {
  const CsvRecord(this.line, this.fields);

  final int line;
  final List<String> fields;
}

/// [parseCsv], keeping each record's line number.
List<CsvRecord> parseCsvRecords(String input) {
  final records = <CsvRecord>[];
  var record = <String>[];
  final field = StringBuffer();
  var inQuotes = false;
  var quotedField = false;
  var line = 1;
  var recordLine = 1;
  var quoteOpenedOn = 1;
  var anyContent = false;

  void endField() {
    record.add(quotedField ? field.toString() : field.toString().trim());
    field.clear();
    quotedField = false;
  }

  void endRecord() {
    endField();
    // A trailing newline produces one empty field, which is not a row.
    if (record.length == 1 && record.first.isEmpty) {
      record = <String>[];
      recordLine = line + 1;
      return;
    }
    records.add(CsvRecord(recordLine, record));
    record = <String>[];
    recordLine = line + 1;
  }

  for (var i = 0; i < input.length; i++) {
    final char = input[i];
    if (inQuotes) {
      if (char == '"') {
        if (i + 1 < input.length && input[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        if (char == '\n') {
          line++;
        }
        field.write(char);
      }
      continue;
    }

    switch (char) {
      case '"':
        if (quotedField) {
          // A quoted value has already closed on this field, so this is text
          // after it: `"abc"def`. Silently concatenating would read a mangled
          // value as a good one, which is the whole thing this parser refuses
          // to do.
          throw FormatException(
            'line $line: text after a closing quote — a value that contains a '
            'quote has to double it ("") rather than close and reopen',
          );
        }
        if (field.toString().trim().isNotEmpty) {
          throw FormatException(
            'line $line: a quote opens in the middle of a field — a value '
            'containing a comma or a quote has to be quoted from its first '
            'character',
          );
        }
        field.clear();
        inQuotes = true;
        quotedField = true;
        quoteOpenedOn = line;
        anyContent = true;
      case ',':
        endField();
        anyContent = true;
      case '\r':
        // Swallowed; the \n that follows ends the record.
        break;
      case '\n':
        endRecord();
        line++;
      default:
        if (quotedField) {
          // Whitespace between a closing quote and the delimiter is dropped
          // rather than appended. Appending it is worse than it sounds: `"…" ,`
          // would make an answer requirement of `REQUIRED ` — a value that no
          // longer matches, silently, so a required question would read as
          // optional. Anything that is *not* whitespace is text after a closing
          // quote and is refused above.
          if (char.trim().isEmpty) {
            break;
          }
          throw FormatException(
            'line $line: text after a closing quote — a value that contains a '
            'quote has to double it ("") rather than close and reopen',
          );
        }
        field.write(char);
        anyContent = true;
    }
  }

  if (inQuotes) {
    throw FormatException(
      'the file ends inside a quoted value that opened on line $quoteOpenedOn '
      '— a missing closing quote swallows every row after it',
    );
  }
  if (field.isNotEmpty || record.isNotEmpty) {
    endRecord();
  }
  if (!anyContent) {
    return const [];
  }
  return records;
}
