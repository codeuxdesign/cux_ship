/// The grid `status` prints: one row per destination, one column per
/// audience, and in every cell a build number with the evidence class behind
/// it.
///
/// **This file decides nothing.** Every mark it renders was decided by
/// [evidenceFor], every cell it has was decided by the table, and every record
/// it reads was decided by whoever wrote the tag. What is left is layout — and
/// layout is where §6.2's rule is kept or lost, because "the grid says so in
/// the cell and never promotes it to *holds*" is a statement about rendering
/// and about nothing else. The evidence model can draw the distinction
/// perfectly and a renderer that prints both as a bare build number throws it
/// away.
///
/// **The grid is keyed by version, and the build number lives in the cell.**
/// §3 is explicit and gives the reason: AuthPass's 1.9.13 exists as two dozen
/// builds and its destinations hold different ones, so a grid keyed by build
/// would render one release as two dozen near-empty grids. A cell whose build
/// is not the candidate's is named as such and never normalised away, "because
/// that difference is the thing worth seeing" — snap `stable` holding 1940
/// against a candidate of 2196 is the plan's motivating example.
///
/// **The candidate is handed in, never guessed here.** §3: `--build N`, or the
/// number `refs/buildnumbers` allocated for the tip of `stable`, and expressly
/// *not* the newest `uploaded/` tag, which §2 shows is routinely a pull
/// request's. This file would have no way to tell the difference, which is
/// exactly why it does not get to choose.
library;

import 'destinations.dart';
import 'evidence.dart';
import 'promotion_ledger.dart';

/// A grid that could not be built, and why.
class StatusGridException implements Exception {
  StatusGridException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What a read found, per cell.
///
/// Keyed by `(destination name, stage)` — a record rather than a map of maps,
/// so a caller writes `{('play', Stage.production): Holds(2196)}` and a lookup
/// is one index rather than two. Records compare by value, which is what makes
/// them usable as keys at all.
///
/// **A cell absent from this map is not the same as one that failed to read.**
/// Absent means no read was attempted — the destination declares no `read`, or
/// this run did not try. A read that was attempted and could not answer is
/// present, as [Unreadable], and the difference reaches the cell's note.
typedef ObservationsByCell = Map<(String, Stage), Observation>;

/// One destination's row.
class StatusRow {
  StatusRow({required this.destination, required Map<Stage, Evidence> cells})
    : cells = Map.unmodifiable(cells) {
    // **A row with a hole in it is refused here rather than at render time.**
    // [cellAt] and every renderer below it index `cells` directly, so a
    // missing stage surfaces as a bare null-check error thrown from inside
    // `render()` — about as far from the caller that built the row as it is
    // possible to land. [StatusGrid.of] always fills every stage, but this
    // constructor is public, so it has to hold the rule itself instead of
    // resting on its only in-tree caller.
    final missing = Stage.values
        .where((stage) => !cells.containsKey(stage))
        .toList();
    if (missing.isNotEmpty) {
      throw StatusGridException(
        'The row for ${destination.name} has no cell at '
        '${missing.map((stage) => stage.name).join(', ')}. Every stage gets a '
        'cell, because a grid that omits one reports an absent column as an '
        'absent audience.',
      );
    }
  }

  final Destination destination;

  /// Every stage, always — see [StatusGrid.rows] for why none is omitted.
  final Map<Stage, Evidence> cells;

  /// The cell at [stage].
  ///
  /// Not nullable: every row carries a cell at every stage, because the
  /// constructor refuses one that does not.
  Evidence cellAt(Stage stage) => cells[stage]!;
}

/// Every destination's evidence for one release candidate.
class StatusGrid {
  StatusGrid({
    required this.version,
    required this.candidate,
    required List<StatusRow> rows,
  }) : rows = List.unmodifiable(rows);

  /// Builds the grid for [candidate] of [version].
  ///
  /// [observations] is what reads found, and may be empty: on day one of §8's
  /// step 1 it is, and the grid is then "mostly `pending`; that is honest".
  factory StatusGrid.of({
    required DestinationTable table,
    required PromotionLedger ledger,
    required String version,
    required int candidate,
    ObservationsByCell observations = const {},
  }) {
    // **A grid with no version in its header is a grid nobody can file.**
    // Every other line in the output names a build, and a build number on its
    // own does not say which release it belongs to — §2's whole finding is
    // that one version spans two dozen builds. A blank header turns a report
    // into an orphan, and the failure is silent, so it is refused here.
    if (version.trim().isEmpty) {
      throw StatusGridException(
        'A status grid needs the version it is about: the build numbers in '
        'its cells do not say which release they belong to.',
      );
    }
    if (candidate < 1) {
      throw StatusGridException(
        'A status grid needs a candidate build, and $candidate is not one. '
        'Build numbers are allocated from 1 upwards; see `--build N`.',
      );
    }
    // **An observation nobody can place is refused, not dropped.**
    // [observations] is keyed by destination *name*, and a caller that spells
    // one differently from the table — `appstore` for a row the table declares
    // as `appstore:ios` — gets no error and no cell. The lookup below simply
    // misses, and the cell then renders `pending`: a read that found a failure
    // reported as "nothing known", which is the exact loss §6.2 added `failed`
    // to prevent. Silent on both sides, so it is refused up front.
    //
    // **It closes the misspelt name and not the class.** An observation for a
    // destination the table *does* declare, at a stage whose step is `none`,
    // is still discarded: [evidenceFor] settles `n/a` before it looks at one.
    // That is §6.3's open question rather than this check's, and a case in
    // `status_grid_test.dart` holds it.
    final declared = {for (final it in table.destinations) it.name};
    final unplaceable =
        observations.keys
            .map((key) => key.$1)
            .where((name) => !declared.contains(name))
            .toSet()
            .toList()
          ..sort();
    if (unplaceable.isNotEmpty) {
      throw StatusGridException(
        'A read was handed in for ${unplaceable.join(', ')}, which the '
        'destination table does not declare. It declares '
        '${declared.join(', ')}. An observation that cannot be placed in a '
        'row would be dropped, and that row would then say `pending` — '
        '"nothing known" in place of what the read found.',
      );
    }
    return StatusGrid(
      version: version,
      candidate: candidate,
      rows: [
        for (final destination in table.destinations)
          StatusRow(
            destination: destination,
            cells: {
              for (final stage in Stage.values)
                stage: evidenceFor(
                  destination: destination,
                  stage: stage,
                  candidate: candidate,
                  ledger: ledger,
                  observation: observations[(destination.name, stage)],
                ),
            },
          ),
      ],
    );
  }

  /// The release the grid is about.
  final String version;

  /// The build this run is asking about.
  final int candidate;

  /// One row per declared destination, in declaration order.
  ///
  /// **Declaration order, and every stage, with nothing collapsed.** A row
  /// whose cells are all `n/a` stays, and so does a stage no destination
  /// declares: §3 asks for one column per audience, and a grid that drops the
  /// `beta` column when this release has no beta destinations would report the
  /// absence of a column as the absence of an audience. The table's order is
  /// kept because a consumer groups its own destinations — families land
  /// together because they were written together.
  final List<StatusRow> rows;

  /// The cell for [destination] at [stage], or null if no such row.
  Evidence? cellFor(String destination, Stage stage) {
    for (final row in rows) {
      if (row.destination.name == destination) {
        return row.cellAt(stage);
      }
    }
    return null;
  }

  /// The grid as a block of text, ending in a newline.
  ///
  /// **The header is the only line that says which release this is**, which is
  /// what being keyed by version costs: every cell below it is a build number,
  /// and §2's finding is that one version spans two dozen of those. A reader
  /// who scrolls past the header is looking at numbers that could belong to
  /// any release.
  String render() {
    final blocks = <String>[
      '$version — build $candidate',
      _table(),
      ..._annotations(),
    ];
    return '${blocks.join('\n\n')}\n';
  }

  String _table() {
    const nameHeading = 'destination';
    final headings = [
      nameHeading,
      for (final stage in Stage.values) stage.name,
    ];
    final body = [
      for (final row in rows)
        [
          row.destination.name,
          for (final stage in Stage.values) _cellText(row, stage),
        ],
    ];

    final widths = [
      for (var column = 0; column < headings.length; column++)
        [
          headings[column].length,
          for (final line in body) line[column].length,
        ].reduce((a, b) => a > b ? a : b),
    ];

    return [headings, ...body].map((line) => _row(line, widths)).join('\n');
  }

  /// One line, padded to [widths] and with the trailing padding taken off.
  ///
  /// **Trailing spaces are removed rather than never written**, because the
  /// last column's width still has to be known while the line is being built —
  /// and a block of text with invisible ragged ends is a block whose tests
  /// compare against strings nobody can read.
  String _row(List<String> cells, List<int> widths) {
    final buffer = StringBuffer();
    for (var column = 0; column < cells.length; column++) {
      buffer.write(cells[column].padRight(widths[column]));
      if (column < cells.length - 1) {
        buffer.write('  ');
      }
    }
    return buffer.toString().trimRight();
  }

  String _cellText(StatusRow row, Stage stage) {
    final evidence = row.cellAt(stage);
    final mark = _markWord(evidence.mark);
    final text = evidence.build == null ? mark : '${evidence.build} $mark';

    // **The annotation rides the `internal` cell.** §6.2 puts it "beside the
    // mark rather than among them", and `internal` is the stage it makes a
    // claim about — a destination that reaches users the moment `stable` is
    // pushed. On the row's name instead it would read as a claim about all
    // three stages, which is the one thing it is not.
    //
    // **There is no case here for a cell nobody acts at**, because
    // `DestinationTable.parse` refuses `public-at-internal` on a destination
    // with no internal step. `status_grid_test.dart` holds that refusal as a
    // case of its own: if it is ever relaxed, the branch missing here is what
    // has to be written.
    //
    // It is the *parser* that refuses it and not the type. A [Destination]
    // built by hand can still carry the flag with no internal step, and this
    // renders it `n/a (public)` — an audience claimed for a step nobody takes.
    // Worth knowing before that rule is loosened, because the output is wrong
    // rather than absent.
    if (stage == Stage.internal && evidence.publicAtInternal) {
      return '$text (public)';
    }
    return text;
  }

  /// The notes under the grid, and the legend, as blocks.
  List<String> _annotations() {
    final notes = <String>[];
    var anyPublic = false;
    for (final row in rows) {
      for (final stage in Stage.values) {
        final evidence = row.cellAt(stage);
        if (stage == Stage.internal && evidence.publicAtInternal) {
          anyPublic = true;
        }
        final note = evidence.note;
        if (note != null && note.trim().isNotEmpty) {
          // **Folded to one line.** A note can be a read's error message,
          // which arrives with newlines in it, and one such note would break
          // the shape of every line under it.
          final folded = note.trim().replaceAll(RegExp(r'\s+'), ' ');
          notes.add('${row.destination.name} ${stage.name} — $folded');
        }
      }
    }

    return [
      if (notes.isNotEmpty) notes.join('\n'),
      if (anyPublic)
        '(public) — reaching this destination already reaches users, so its '
            'internal cell is not a private step',
    ];
  }
}

/// How a mark is spelled in a cell.
///
/// **Every mark is spelled out, including the two that could be left
/// implicit.** A bare build number for `observed` beside `2196 attested` would
/// read as the stronger claim by being shorter, and a reader skimming a column
/// of numbers would see agreement where there is a record and nothing else.
/// §6.2's rule is that the grid never promotes attestation to "holds"; the
/// cheapest way to keep it is to make every cell say what kind of thing it is.
String _markWord(EvidenceMark mark) => switch (mark) {
  EvidenceMark.observed => 'observed',
  EvidenceMark.attested => 'attested',
  EvidenceMark.disagreed => 'disagreed',
  EvidenceMark.failed => 'failed',
  EvidenceMark.pending => 'pending',
  // The one mark whose name is not the word for it: `n/a` is what §6.2's
  // table prints, and `notApplicable` is only what Dart allows an identifier
  // to be called.
  EvidenceMark.notApplicable => 'n/a',
};
