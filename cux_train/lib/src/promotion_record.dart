/// The promotion record: what a release has already reached, and how.
///
/// **The record is the reason step 1 exists at all.** The plan's §8 puts it
/// plainly — "anything less leaves no record, and the record is what every
/// later stage is built on". Resuming a `production` run that spans days,
/// deciding when the version tag may be spent, and answering "is 1.9.12
/// finished?" are all one question asked of this state.
///
/// **What is deliberately not here: writing it**, and that split survived the
/// question it was waiting on. §9 item 4 asked whether the writer belongs in
/// `cux_train` or in a `cux_ship release record` command beside `release
/// finish`, leaning toward the latter because `cux_ship` already owns the
/// `uploaded/` namespace and the tag config. The answer is that `cux_ship` owns
/// the *tag* and this file owns the *name* — `UploadRecord` has said since it
/// was written that "the caller owns the convention, because what a released
/// tag is called differs per repository and this must never assume a shape", so
/// no new command was needed, only an export. `record_writer.dart` is the join.
///
/// So this file owns the grammar and the reading, which is what it would have
/// owned either way. A caller hands it ref names; it does not run git, and
/// nothing here needs a credential or a network.
library;

import 'destinations.dart';

/// A ref name this file could not read as a record.
class PromotionRecordException implements Exception {
  PromotionRecordException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What a record says happened.
///
/// **Two states, and the second one is load-bearing.** §6.1: `s` (skip) leaves
/// a destination unrecorded so the next run stops at it again, while `f`
/// records that it was attempted and refused. Without the second, "the console
/// rejected the binary" looks exactly like "nobody has looked yet" — and being
/// unable to tell those apart is the failure §2 says the record exists to fix.
///
/// A third state — "I saw it live" — is §9 item 6 and is not here. For a
/// destination that can be read, `status` upgrades [handedOver] to *observed*
/// from the read itself rather than from a record, so the state would only
/// ever be written for destinations where nobody can check it.
enum PromotionOutcome {
  /// The step was performed. For a `manual` destination this means *handed
  /// over*, never *live*: the operator submitted it, and a console that takes
  /// days to review has still only been handed the build.
  handedOver('promoted'),

  /// The step was attempted and the destination refused it.
  attemptedAndRefused('refused');

  const PromotionOutcome(this.namespace);

  /// The ref namespace this outcome is written under.
  ///
  /// **A separate namespace rather than a flag inside the ref**, because the
  /// existence of a ref is what everything else reads. A refusal filed under
  /// `promoted/` would be counted as a promotion by anything that globs the
  /// namespace and does not parse what it found — which is every `git
  /// for-each-ref` one-liner anybody will ever write against this.
  final String namespace;

  static PromotionOutcome? byNamespace(String namespace) {
    for (final outcome in values) {
      if (outcome.namespace == namespace) {
        return outcome;
      }
    }
    return null;
  }

  /// Every namespace a caller has to glob to read the whole record.
  static List<String> get namespaces => [
    for (final outcome in values) outcome.namespace,
  ];
}

/// One thing that happened to one destination at one stage.
class PromotionRecord {
  const PromotionRecord({
    required this.destination,
    required this.stage,
    required this.version,
    required this.build,
    required this.outcome,
  });

  /// The destination's name as the table spells it, `appstore:ios` included.
  final String destination;

  final Stage stage;

  /// The version name, as it appears between `v` and `+`.
  ///
  /// Opaque on purpose: this file compares versions for equality and never
  /// orders them. `cux_ship` owns what a version means.
  final String version;

  /// The build number, which is what identifies the artifact.
  final int build;

  final PromotionOutcome outcome;

  /// The ref name, without a `refs/tags/` prefix.
  String get ref =>
      '${outcome.namespace}/${_pathFor(destination)}/${stage.name}/'
      'v$version+$build';

  /// **A `family:member` name cannot go into a ref, so it travels as a path.**
  ///
  /// `git check-ref-format` refuses a colon outright — verified, not assumed —
  /// and six of AuthPass's nineteen destinations have one (`appstore:ios`,
  /// `appstore:macos`, and the four `direct:` rows). The plan writes the shape
  /// as `promoted/<dest>/<stage>/v…+N` throughout and does not say what
  /// happens to those six; the donor never hit it because it only ever
  /// recorded `play`.
  ///
  /// A slash is the right substitute rather than a hyphen: it is what the
  /// colon already means — a family and a member — and it keeps
  /// `promoted/appstore/` as a namespace somebody can glob for both Apple
  /// rows. The cost is that the destination is no longer one path component,
  /// which is why [parse] reads from the right.
  static String _pathFor(String destination) =>
      destination.replaceAll(':', '/');

  /// A build number as [ref] writes one: decimal digits, no sign, no padding.
  static final _buildPattern = RegExp(r'^[1-9][0-9]*$');

  /// Reads a ref name written by [ref].
  ///
  /// [source] names where the ref came from, for the refusal.
  ///
  /// **Every ref the caller passes must parse.** A caller globs the two
  /// namespaces [PromotionOutcome.namespaces] names, so anything it hands over
  /// is already claimed to be a record; one that does not fit is a record
  /// written by something that disagrees with this grammar, and skipping it
  /// would silently under-count exactly the state the finish rule counts.
  factory PromotionRecord.parse(String ref, {required String source}) {
    final parts = ref.split('/');
    // namespace + at least one destination component + stage + version
    if (parts.length < 4) {
      throw PromotionRecordException(
        '$source: `$ref` is not a promotion record — expected '
        '`<namespace>/<destination>/<stage>/v<version>+<build>`',
      );
    }

    final outcome = PromotionOutcome.byNamespace(parts.first);
    if (outcome == null) {
      throw PromotionRecordException(
        '$source: `$ref` starts with `${parts.first}`, which is not a record '
        'namespace — expected ${PromotionOutcome.namespaces.join(' or ')}',
      );
    }

    // **Read from the right.** The destination is one component or two and
    // the three after it are fixed, so the right-hand end is the part whose
    // shape is known. Reading from the left would have to guess where the
    // destination stops.
    final versionPart = parts.last;
    final stage = Stage.byName(parts[parts.length - 2]);
    if (stage == null) {
      throw PromotionRecordException(
        '$source: `$ref` records a stage called '
        '`${parts[parts.length - 2]}` — expected '
        '${Stage.values.map((s) => s.name).join(', ')}',
      );
    }

    if (!versionPart.startsWith('v')) {
      throw PromotionRecordException(
        '$source: `$ref` ends with `$versionPart`, which does not begin with '
        '`v` — expected `v<version>+<build>`',
      );
    }
    final plus = versionPart.lastIndexOf('+');
    if (plus < 0) {
      throw PromotionRecordException(
        '$source: `$ref` ends with `$versionPart` and names no build — a '
        'record identifies the artifact by build number, so `v<version>` '
        'alone cannot be one',
      );
    }
    final version = versionPart.substring(1, plus);
    if (version.isEmpty) {
      throw PromotionRecordException(
        '$source: `$ref` ends with `$versionPart` and names no version',
      );
    }
    // **The digits are checked before they are parsed**, because
    // `int.tryParse` is more generous than [ref] is: it reads `0x10` as
    // sixteen, `02196` as 2196 and ` 5 ` as five, and each of those is a ref
    // this file would then write back under a different name. The pattern
    // also carries the "positive" half — no sign, no leading zero — so the
    // only thing left for `tryParse` to refuse is a number too long to hold.
    final buildText = versionPart.substring(plus + 1);
    final build = _buildPattern.hasMatch(buildText)
        ? int.tryParse(buildText)
        : null;
    if (build == null) {
      throw PromotionRecordException(
        '$source: `$ref` ends with `$versionPart`, whose build is not a '
        'positive whole number',
      );
    }

    // **One component or two, and neither empty** — the bound the comment
    // above states and reading from the right does not by itself enforce.
    // Whatever is left of the stage is taken as the destination, so without
    // this `promoted/a/b/c/production/v…` reads back as `a:b:c`, a name the
    // table refuses to declare and no destination can therefore match.
    final destinationParts = parts.sublist(1, parts.length - 2);
    if (destinationParts.length > 2 || destinationParts.any((p) => p.isEmpty)) {
      throw PromotionRecordException(
        '$source: `$ref` puts `${destinationParts.join('/')}` where the '
        'destination goes, which is not a destination name — expected '
        '`<name>` or `<family>/<member>`',
      );
    }

    return PromotionRecord(
      destination: destinationParts.join(':'),
      stage: stage,
      version: version,
      build: build,
      outcome: outcome,
    );
  }

  @override
  String toString() => ref;
}
