# `--json`, and the document it prints

Status: **decided, not built**, 10 September 2026. This settles the transport
question [read-api.md](read-api.md) left open — recorded there the day after
the library shipped, because `read.dart` had been weighed against parsing
printed prose and never against a schema.

It specifies **the envelope and the rules**. It deliberately does not enumerate
fields: `lib/src/appstore/reads.dart` and `lib/src/play/reads.dart` are the
field list, and a table here would be a second one that drifts from it. What is
written down is what a model cannot say — how a document is versioned, what may
be parsed, and which stream it goes to.

## Not `--yaml`, and the reason is measured

The proposal was that YAML types more scalars than JSON and would therefore
carry better typing. It types more scalars. They are the wrong ones. Run
against this repository's own `yaml: ^3.1.0`:

| written | parsed as |
|---|---|
| `versionName: 1.10` | **`double` 1.1** |
| `buildNumber: 010` | **`int` 10** |
| `mas: 1.2.3` | `String` "1.2.3" |
| `track: no` | `String` "no" |
| `released: 2026-09-10` | `String` "2026-09-10" |

The first row is the whole argument. `1.10` is the field this tool exists to be
right about, and an unquoted YAML scalar silently makes it `1.1`. That is the
same string-versus-number family that has already cost this repository twice —
Apple's `sort=-version` putting build 9 above build 10, and a consumer's
`status` comparing a printed build number against an integer, correct only
while every build number had the same width. A format whose default behaviour
reintroduces it is not a candidate.

The last two rows are the second argument, and they cut the other way from how
they read. Dart's parser follows YAML 1.2's core schema, which has neither an
implicit boolean `no` nor an implicit timestamp. YAML 1.1 implementations —
PyYAML, Ruby's Psych — resolve both. So one document types differently for two
readers, and typing that depends on who is parsing is worse than none, because
both sides believe they have it. *That* divergence is not measured here and
could not be: neither PyYAML nor `yq` is installed on the machine this tooling
runs on, which is the smaller half of the same point. `jq` is.

Two more, both practical:

- **`package:yaml` does not emit.** Its entire public API is `loadYaml`,
  `loadYamlNode`, `loadYamlDocument` and `loadYamlStream`. `--yaml` means a new
  dependency or a hand-rolled emitter, in a pubspec that argues every
  dependency line by line. JSON is `dart:convert`.
- **Choosing JSON costs a YAML consumer nothing.** JSON is a subset of YAML
  1.2. Feeding `JsonEncoder` output back through `loadYaml` returns `"1.10"`
  and `"010"` as strings. A YAML consumer can read this output; a JSON consumer
  could not read YAML output.

An emitter could of course quote defensively and produce a document with none
of these hazards. That is JSON, with worse tooling and a dependency.

## The envelope is the manifest's, unchanged

Top-level `schema`, an integer. **A reader refuses an unrecognized value**
rather than reading optimistically. Adding an optional field does not bump it;
adding a required one, or changing an existing one's meaning, does. Anything a
repository needs for itself goes under a single `x` object that shared tools
never read, and a key promoted out of `x` gets a new name if its semantics
changed.

None of that is new. It is [build-manifest.md](build-manifest.md) §Compatibility
and §Extra keys, which is shipped, exercised and already understood by anyone
reading a manifest. A second convention would be a second thing to learn and a
second thing to get subtly different.

**And a `kind`, which the manifest has no need of.** There is one manifest
format and there are three of these — `appstore.builds`, `appstore.versions`,
`play.tracks`. Three types under one `schema` counter means a change to
`play.tracks` bumps the number `appstore.builds` declares, and a consumer of
builds then refuses a document that did not change. So each type versions
independently, and independent counters require the document to say which
counter applies. `kind` is load-bearing for the three that exist today, which
is why it is here; that it also costs a fourth nothing is a consequence and not
the reason.

## `display` carries the rendering, and promises nothing about it

Every result carries the rendered lines beside the fields, under `display` —
a string on an item, an array on a document — mirroring `line` and `lines` on
the models.

This is the field the whole decision turned on. Without it a consumer must
re-render from the fields, and two renderings of one model drift: a build shown
as `169` where this command shows `169  VALID  uploaded …  (expired)`. With it,
there is one formatter and the model feeds it, which is the same argument that
put `lines` on the models in the first place.

**The objection is that this ships a rendering through a data channel, and it
is a real one.** A schema exists to promise structure; `display` exists
precisely to promise nothing. Both are true, and the resolution is to say so in
the name and then say it again here:

> `display` is for showing a human. It is **outside the schema promise**. Its
> content may change in any release without a `schema` bump, and a consumer
> that parses it has taken a dependency this document explicitly refuses to
> carry. Print it; read the fields.

That is not a weaker promise than the library makes — it is the identical one,
in a different envelope. `AppStoreBuilds.lines` is already a `List<String>` a
caller could parse today and should not.

**One correction this forced.** `read.dart` and read-api.md both called these
"the store's own printed lines". They are not. `AppStoreBuild.line` is
`'  build $buildNumber  $processingState  uploaded $uploadedDate'` — *this
package's* sentence, composed from parsed fields, exactly as
`lib/src/play/reads.dart` says at the top: "The printed lines are derived from
these objects, not the other way round." The property is one formatter, not
fidelity to a store's format, and the overstated version is what made carrying
`display` look like a contradiction rather than a labelling problem.

## Two names, because there are two questions

`buildNumber` is a `String`, because `CFBundleVersion` is one and Apple accepts
`1.2.3`. `buildNumberAsInt` is emitted beside it, `null` rather than a fallback
for anything that is not a single integer. A consumer comparing against a git
tag reads the second; a consumer displaying or matching reads the first.
Computed fields are emitted rather than left to the caller — `usable`,
`newestBuildNumber`, `newestVersionCode` — because the rule this package orders
by should be the rule it hands a caller, and a schema that carries them
protects a shell caller, which a Dart library structurally cannot.

**And it collides with the manifest, deliberately and only in name.**
`build_manifest.dart` refuses a `buildNumber` that is not an integer, on the
argument recorded there: both stores count in integers and a value that is not
one means the caller passed something else. A read document takes what Apple
returns, which may be dotted. Both are right for their own document, and a
consumer parsing both has two types under one key. Renaming either would make
one document lie about its own domain, so neither is renamed and the collision
is written down instead. `buildNumberAsInt` is the name that means one thing in
both directions.

## stdout is the document. That is where the safety is.

Not the schema — the schema is a convention already in use. The engineering is
that `lib/src/` writes to stdout in 132 places across nine files against 48 to
stderr, and `fail()` calls `exit()`.

- Under `--json`, **stdout carries the document and nothing else.** Every
  `==>` line, every progress report, every rendered listing moves to stderr for
  that invocation.
- **The document is built whole and written once, at the end.** Not streamed as
  it is assembled, because a `fail()` partway through would leave half a
  document on stdout and an exit code saying to trust it. This is the manifest
  writer's "before the file is written, not after", applied to a stream.
- **Errors stay prose on stderr, and stdout stays empty.** The considered
  alternative was an error document with a `kind` of its own. It was rejected:
  the failure that matters most here is Play's 403 saying the service account
  was never granted this app, which is the only actionable line in the
  exchange, and a parseable error object invites a consumer to branch on it and
  treat the exit code as advisory. Empty stdout plus a non-zero exit is
  unambiguous, and the prose stays where a human finds it.

The stdout guard is the one thing here that is a guard rather than a shape, so
it is the one that gets a test observed failing with it removed.

## A worked example

```json
{
  "schema": 1,
  "kind": "appstore.builds",
  "platform": "IOS",
  "bundleId": "design.codeux.example",
  "newestBuildNumber": "169",
  "builds": [
    {
      "buildNumber": "169",
      "buildNumberAsInt": 169,
      "processingState": "VALID",
      "uploadedDate": "2026-09-09T14:02:11-07:00",
      "expired": false,
      "usable": true,
      "display": "  build 169  VALID  uploaded 2026-09-09T14:02:11-07:00"
    }
  ],
  "display": ["  build 169  VALID  uploaded 2026-09-09T14:02:11-07:00"]
}
```

## Scope: the three reads, and not the waits

`appstore builds`, `appstore versions`, `play tracks` — the three the open
question named, and the three the library exports.

**Not `appstore wait`, and that is measured rather than deferred.** The
consumer that asked for all of this spawns it under `secrets exec --only`,
streams stdout to a log a human reads after a failure, and heartbeats on the
last line. **The only thing it consumes is the exit code.** Not one field is
decoded. Line-delimited progress events would be built for nobody, and the
first draft of read-api.md's open section had kept exactly that as the
library's surviving justification.

**Nor release and rollout state**, which is its own task. Worth one sentence
because it bears on ordering rather than on scope: a staged rollout is a wait
whose *intermediate* state is the answer — 20% or 50% — unlike processing,
which is a state nobody wants a reading of. So "no events for `appstore wait`"
must not be generalized into "no wait ever needs typed progress". Nothing is
designed for it here; the `schema` convention is what leaves room, and it costs
nothing because it already exists.

## What this does not decide

**Whether `read.dart` survives.** It is published, and removing an export is a
major version. The consumer says it would revert onto `--json` and drop the
library given `display` in the document, and that answer is what settled
`display`. It is still a separate decision, taken after `--json` exists rather
than before, because a consumer reverting today would revert onto prose —
which is the defect the library was built to fix.

One consequence of the ordering is worth stating, because it is the reason to
do this before the rollout task rather than after: **if `--json` wins, release
and rollout state should never be added to `read.dart` at all.** Adding it
first does not merely cost a version bump later — it spends a permanent API
promise on a surface the only consumer may be about to leave.
