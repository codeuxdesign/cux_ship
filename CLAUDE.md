# cux_ship

Release tooling for the App Store and Google Play. A pub workspace of three
published packages:

| | |
|---|---|
| `cux_ship` | the command, and everything publishing needs — googleapis, an image codec, an HTTP client, a JWT signer |
| `cux_ship_verify` | the offline half, with no dependencies at all: the CHANGELOG parser, the App Store metadata model, and the checks over both |
| `cux_buildnumber` | allocating a build number, which is a git operation a build does before it has an artifact |

**Read [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) before changing anything.**
It is three rules and a rule about the rules, and it is deliberately short: a
rule lives there only while it cannot be a check, and only after it has bitten
twice. The first of the three — *every guard's test is observed failing with the
guard removed* — governs every fix here, and is not negotiable because a test
only ever seen green proves nothing about the thing it guards.

**Publishing is [docs/RELEASING.md](docs/RELEASING.md), and it owns the version
number.** A change writes its entry under `## Unreleased` and stops there;
`pubspec.yaml`, `lib/src/version.dart` and the changelog heading move together
on a `release/x.y.z` branch. A feature branch that bumps them is claiming a
number it cannot know it will get — and with several branches open at once, each
claims the same one and they collide.

**`tool/check.sh` runs what CI runs.** Every workspace member, or name one:

```bash
tool/check.sh              # all of them
tool/check.sh cux_ship     # just this one
```

This used to be three commands written out here — `pub get`, `analyze
--fatal-infos`, `test` — and CI runs **five**. The two it omitted were
`dart format --output=none --set-exit-if-changed` and `dart pub publish
--dry-run`, so the loop this file told you to run could not go red on the two
steps that bracket it. A script rather than a longer line because the list was
being maintained in two places, which is how it came to be three of five.

`version_test.dart` asserts `cuxShipVersion` and `pubspec.yaml` agree, so run
this *after* the last edit rather than before it.

**`tool/status.sh` says what is still open**, derived from the `Status:` line
every document in `docs/design/` carries:

```bash
tool/status.sh             # everything, grouped
tool/status.sh open        # one state
```

Four words — `open`, `proposed`, `decided`, `built` — and
`design_status_test.dart` reads them out of the script and fails a document
that uses a fifth, because a status the index does not recognize does not
error: it disappears from the report, and a short list of open questions is
believed.

**A document's own status is the state of its subject, and a section may carry
its own.** `read-api.md` is `decided` at the top and `open` two hundred lines
down: the library shipped, and whether it should have existed did not stop
being a question when it did. So a header that says `built` is not a claim that
nothing inside is open — it is a claim about the thing the document is *for*,
and the honest place for the rest is a section with a status of its own. That
is why the index prints the heading beside every hit rather than the filename
alone; `tool/status.sh open` is the list, not the top of each file.

**Open questions live in the design document that argues them, not in a
tracker.** GitHub issues are for defects and anything reported from outside;
`issue_tracker:` in all three pubspecs points there. And this repository has no
`TODO` comments anywhere, on purpose — a tag records that somebody once had a
thought, where a comment records what the thought was.
