// What the grid prints, and the distinctions layout is where you lose.
//
// **The evidence model already decided every mark here** — these cases are
// about the step after that, where §6.2's "the grid says so in the cell and
// never promotes it to *holds*" is either kept or thrown away. A renderer that
// prints `observed` and `attested` identically passes every test in
// `evidence_test.dart`.
import 'package:cux_train/cux_train.dart';
import 'package:test/test.dart';

final _table = DestinationTable.parse('''
destinations:
  play:
    read: "play tracks"
    internal: {kind: ship, command: "play internal"}
    production: {kind: ship, command: "play promote"}
  huawei:
    production: {kind: manual, console: "https://developer.huawei.com"}
  snap:
    public-at-internal: true
    read: "snap info"
    internal: {kind: run, command: "snap-edge.sh"}
    production: {kind: manual, console: "https://snapcraft.io"}
  web:
    public-at-internal: true
    internal: {kind: run, command: "web.sh"}
    production: none
''', source: '.cux-train.yaml');

const _candidate = 2196;
const _version = '1.9.13';

StatusGrid _grid({
  List<String> refs = const [],
  ObservationsByCell observations = const {},
  DestinationTable? table,
  String version = _version,
  int candidate = _candidate,
}) => StatusGrid.of(
  table: table ?? _table,
  ledger: PromotionLedger.forBuild(refs, build: candidate, source: 'refs/tags'),
  version: version,
  candidate: candidate,
  observations: observations,
);

/// The line of [render] that starts with [name], with runs of spaces squeezed
/// so a case can state what a row says without restating every column width.
String _row(String render, String name) => render
    .split('\n')
    .firstWhere((line) => line.startsWith('$name '))
    .replaceAll(RegExp(r' {2,}'), ' | ');

void main() {
  group('the rule layout is where you lose', () {
    test('a read and a record never render the same', () {
      // §6.2: "Where only attestation exists, the grid says so in the cell and
      // never promotes it to holds." Both cells name 2196; only one of them
      // means the destination was asked.
      final render = _grid(
        refs: ['promoted/huawei/production/v1.9.13+2196'],
        observations: {('play', Stage.production): const Holds(_candidate)},
      ).render();

      expect(_row(render, 'play'), contains('2196 observed'));
      expect(_row(render, 'huawei'), contains('2196 attested'));
    });

    test('a cell holding another build names that build, not the candidate', () {
      // §3: never normalised away, "because that difference is the thing worth
      // seeing". snap stable holding 1940 against a candidate of 2196 is the
      // plan's own example.
      final render = _grid(
        refs: ['promoted/snap/production/v1.9.13+2196'],
        observations: {('snap', Stage.production): const Holds(1940)},
      ).render();

      expect(_row(render, 'snap'), contains('1940 disagreed'));
      expect(_row(render, 'snap'), isNot(contains('2196 disagreed')));
    });

    test('every mark is spelled out, so none reads as stronger by being '
        'shorter', () {
      final render = _grid(
        refs: [
          'promoted/huawei/production/v1.9.13+2196',
          'refused/snap/production/v1.9.13+2196',
        ],
        observations: {('play', Stage.production): const Holds(_candidate)},
      ).render();

      // Not one bare `2196` anywhere: every build number carries its class.
      for (final line in render.split('\n')) {
        if (!line.contains('2196')) {
          continue;
        }
        expect(
          line,
          anyOf(
            startsWith(_version),
            contains('2196 observed'),
            contains('2196 attested'),
            contains('2196 failed'),
            contains('recorded at 2196'),
          ),
          reason: 'a build number with no mark beside it: $line',
        );
      }
    });
  });

  group('the header', () {
    test('names the version and the candidate build', () {
      // §3: the grid is keyed by version and the build lives in the cell, so
      // the header is the only place that says which release this is about.
      expect(_grid().render(), startsWith('1.9.13 — build 2196\n'));
    });

    test('refuses a grid with no version, which nothing else would say', () {
      expect(
        () => _grid(version: '  '),
        throwsA(
          isA<StatusGridException>().having(
            (e) => e.message,
            'message',
            contains('which release'),
          ),
        ),
      );
    });

    test('refuses a candidate that is not a build number', () {
      expect(
        () => _grid(candidate: 0),
        throwsA(
          isA<StatusGridException>().having(
            (e) => e.message,
            'message',
            contains('--build'),
          ),
        ),
      );
    });
  });

  group('what is never collapsed', () {
    test('a stage no destination declares still gets a column', () {
      // Nothing in the fixture has a `beta` step. Dropping the column would
      // report the absence of a column as the absence of an audience.
      final render = _grid().render();

      expect(render.split('\n').first, isNot(contains('beta')));
      expect(
        render.split('\n')[2],
        matches(RegExp(r'destination\s+internal\s+beta\s+production')),
      );
      expect(_row(render, 'play'), 'play | pending | n/a | pending');
    });

    test('a row with nothing in it at all is kept', () {
      // A grid that drops a destination nobody acts at renders it as a
      // destination nobody declared, and §4's finish rule counts on the
      // difference: `none` at production is satisfied vacuously, while an
      // absent destination is one the rule never asked about.
      final render = _grid(
        table: DestinationTable.parse('''
destinations:
  flathub:
    read: "flathub api"
    production: none
''', source: '.cux-train.yaml'),
      ).render();

      expect(_row(render, 'flathub'), 'flathub | n/a | n/a | n/a');
    });

    test('rows stay in declaration order', () {
      // A consumer groups its own destinations by writing them together, so
      // sorting the grid would take that grouping away. `huawei` before
      // `snap` is alphabetically wrong and declaration-order right.
      final render = _grid().render();

      expect(_grid().rows.map((row) => row.destination.name), [
        'play',
        'huawei',
        'snap',
        'web',
      ]);
      expect(render.indexOf('\nhuawei'), lessThan(render.indexOf('\nsnap')));
    });
  });

  group('the one annotation', () {
    test('rides the internal cell and no other', () {
      // §6.2 puts it "beside the mark rather than among them", and `internal`
      // is the stage it makes a claim about.
      final row = _row(_grid().render(), 'snap');

      expect(row, 'snap | pending (public) | n/a | pending');
    });

    test('never has to be printed on a cell nobody acts at', () {
      // **This is why the renderer has no case for that.** A destination that
      // claims to be public at a stage it also says nobody touches is refused
      // when the table is parsed, so `(public)` can only ever ride a cell with
      // a step behind it. If this refusal is ever relaxed, this case goes red
      // and the renderer needs the branch it does not have today.
      expect(
        () => DestinationTable.parse('''
destinations:
  web:
    public-at-internal: true
    production: {kind: manual, console: "https://authpass.app"}
''', source: '.cux-train.yaml'),
        throwsA(isA<DestinationTableException>()),
      );
    });

    test('is explained once, and only when a row carries it', () {
      final with_ = _grid().render();
      final without = _grid(
        table: DestinationTable.parse('''
destinations:
  huawei:
    production: {kind: manual, console: "https://developer.huawei.com"}
''', source: '.cux-train.yaml'),
      ).render();

      expect('(public) —'.allMatches(with_).length, 1);
      expect(without, isNot(contains('(public)')));
    });
  });

  group('the notes under the grid', () {
    test('name the cell they belong to', () {
      final render = _grid(
        refs: ['promoted/snap/production/v1.9.13+2196'],
        observations: {('snap', Stage.production): const Holds(1940)},
      ).render();

      expect(
        render,
        contains('snap production — recorded at 2196, holds 1940'),
      );
    });

    test(
      'are folded to one line, so one read error cannot break the block',
      () {
        // A read's error arrives with newlines in it.
        final render = _grid(
          refs: ['promoted/play/production/v1.9.13+2196'],
          observations: {
            ('play', Stage.production): const Unreadable(
              'GET /tracks\n  timed out\n  after 30s',
            ),
          },
        ).render();

        expect(
          render,
          contains('play production — GET /tracks timed out after 30s'),
        );
      },
    );

    test('are absent when every cell speaks for itself', () {
      // Nothing public, nothing disagreed, nothing refused: the header is the
      // only line left carrying an em dash.
      final render = _grid(
        table: DestinationTable.parse('''
destinations:
  huawei:
    production: {kind: manual, console: "https://developer.huawei.com"}
''', source: '.cux-train.yaml'),
        refs: ['promoted/huawei/production/v1.9.13+2196'],
      ).render();

      expect(' — '.allMatches(render).length, 1);
      expect(render, startsWith('1.9.13 — build 2196'));
    });
  });

  group('the block itself', () {
    test('is what the command prints', () {
      final render = _grid(
        refs: [
          'promoted/huawei/production/v1.9.13+2196',
          'promoted/snap/production/v1.9.13+2196',
        ],
        observations: {
          ('play', Stage.production): const Holds(_candidate),
          ('snap', Stage.production): const Holds(1940),
        },
      ).render();

      expect(render, '''
1.9.13 — build 2196

destination  internal          beta  production
play         pending           n/a   2196 observed
huawei       n/a               n/a   2196 attested
snap         pending (public)  n/a   1940 disagreed
web          pending (public)  n/a   n/a

snap production — recorded at 2196, holds 1940

(public) — reaching this destination already reaches users, so its internal cell is not a private step
''');
    });

    test('has no line that ends in a space', () {
      // Every row is padded to the widest cell, so the last column pads too
      // unless something takes it off.
      final render = _grid().render();

      for (final line in render.split('\n')) {
        expect(line, isNot(endsWith(' ')), reason: 'ragged line: "$line"');
      }
    });

    test('columns are as wide as their widest cell, not their heading', () {
      // `beta` is four characters and every cell under it is three.
      final render = _grid().render();
      final heading = render
          .split('\n')
          .firstWhere((line) => line.startsWith('destination'));

      expect(heading, 'destination  internal          beta  production');
    });
  });

  group('the model behind it', () {
    test('fills every stage of every row', () {
      for (final row in _grid().rows) {
        for (final stage in Stage.values) {
          expect(row.cellAt(stage), isNotNull);
        }
      }
    });

    test('an observation reaches the cell it names and no other', () {
      final grid = _grid(
        observations: {('play', Stage.production): const Holds(1940)},
      );

      expect(grid.cellFor('play', Stage.production)!.build, 1940);
      expect(grid.cellFor('play', Stage.internal)!.mark, EvidenceMark.pending);
      expect(
        grid.cellFor('snap', Stage.production)!.mark,
        EvidenceMark.pending,
      );
    });

    test('a destination nobody declared has no cell', () {
      expect(_grid().cellFor('amazon', Stage.production), isNull);
    });
  });
}
