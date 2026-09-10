# `--json`, and the document it prints

Status: **built**, 10 September 2026 — `--json` on `appstore builds`, `appstore
versions` and `play tracks`, and nothing else. This settles the transport
question [read-api.md](read-api.md) left open, recorded there the day after the
library shipped because `read.dart` had been weighed against parsing printed
prose and never against a schema.

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

**`kind` therefore sits above the schema promise, and is the one field that can
never change meaning.** A reader has to know the kind before it can decide
whether the `schema` number is one it understands, because the counters are per
kind — so `kind` is read first and is not versioned by the thing it gates. An
unrecognized `kind` is refused, on the same argument that refuses an
unrecognized `schema`: every value a release step is named by comes out of
here.

Its only consumer today **asserts** it rather than dispatching on it — a caller
always knows which subcommand it ran, and compares `kind` as a guard against
wiring the wrong parser to the wrong command. That is a weaker requirement than
dispatch: exact-match comparable, not an open enum with stable dispatch
semantics. Nothing here promises more than that, because nothing consumes more.

## `display` carries the rendering, and promises its shape but not its text

Every result carries the rendered lines beside the fields, under `display`.
**Always an array of strings, at both levels** — including where the model
renders one line. `AppStoreBuild.line` is a single string and its `display` is
a one-element array anyway.

That uniformity is not tidiness, and the shape it rejects was this document's
first draft: a string on an item, an array on a document. Two of the three
kinds do not render one line per item. `AppStoreVersion.lines` is **two**
lines, the second being `copyright:`. `PlayTrack.lines` is one line *per
release*, so a halted rollout beside its replacement is two. An item-level
string would have to join them with a newline, and a consumer wanting the items
back would have to split on it — which is parsing `display`, forbidden three
paragraphs below in this same document.

It is also a bug the consumer has already had. Its `status` shows the newest
three App Store versions and printed two and a half: the cap was
`versions.lines.take(3)`, a version spends two lines, and the third landed
mid-item. The fix was to cap the *items* and ask each for its own rendering —
`versions.versions.take(3)`. Collapse an item's rendering to a string and that
fix is not expressible against a document.

**And a document's `display` is not the concatenation of its items'.**
`AppStoreBuilds.lines` renders `builds.take(20)` while `builds` carries
everything Apple returned, and `PlayTracks.lines` appends a trailing `uploaded
bundles:` line that belongs to no track. Two renderings of one model, and
deriving either from the other is wrong in both directions.

**A document's `display` is never empty, and that is the half worth a test.**
An empty listing renders a sentence — `no builds at all — nothing has ever been
uploaded`, `no App Store versions for IOS` — because a caller iterating an
empty list prints nothing, and a store the output said nothing about reads as a
store with nothing wrong. The concatenation shortcut is correct for every
non-empty document and returns `[]` exactly when that array is the only thing
carrying meaning, so the simplification that breaks this cannot be caught by a
test written over a populated fixture. It is caught by one written over an
empty one, which is why there is one.

This is the field the whole decision turned on. Without it a consumer must
re-render from the fields, and two renderings of one model drift: a build shown
as `169` where this command shows `169  VALID  uploaded …  (expired)`. With it,
there is one formatter and the model feeds it, which is the same argument that
put `lines` on the models in the first place.

**The objection is that this ships a rendering through a data channel, and it
is a real one.** A schema exists to promise structure; `display` exists
precisely to promise nothing. Both are true, and the resolution is to say so in
the name and then say it again here:

> `display` is for showing a human. Its **text is outside the schema
> promise** — content may change in any release without a `schema` bump, and a
> consumer that parses a line has taken a dependency this document explicitly
> refuses to carry. Its **shape is inside it**: `display` is an array of
> strings, an item's rendering is addressable separately from its document's,
> and changing that is a `schema` bump like any other. Print the lines; read
> the fields.

**The two halves have to be said separately, because a consumer depends on one
and not the other.** An earlier draft put them under one "may change in any
release", which reads as covering the nesting too — and the consumer that would
port onto this said, correctly, that if it does cover the nesting it cannot
port. Unpromised text is what makes `display` safe to carry. Unpromised
*structure* would make it unusable.

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
`newestBuildNumber`, `newestBuildNumberAsInt`, `newestVersionCode` — because
the rule this package orders by should be the rule it hands a caller, and a
schema that carries them protects a shell caller, which a Dart library
structurally cannot.

**`newestBuildNumberAsInt` does not exist on the model yet, and its absence is
the argument for it.** `AppStoreBuilds.newestBuildNumber` is a `String?` whose
own doc comment says: *"do not compare this against another build number as a
string — use `AppStoreBuild.buildNumberAsInt`, via `newest`"*. **Via `newest`
is a remedy only a library caller has.** A document carrying the string alone
would hand a shell caller precisely the comparison that comment forbids, and
the way back would be to find the newest item and re-implement the ordering
rule — which the paragraph above says should be handed over rather than
reimplemented. So the document emits it, `null` on the same terms.

**Computed in the encoder, and not added to `AppStoreBuilds`.** The draft of
this section said the model would grow the getter, and it should not: that is a
new public name on a published class, and this repository adds those on their
own argument rather than as a side effect of building something else. A library
caller already has the value in two hops, which is precisely why the *document*
needs it and the model does not — a shell caller is the one with no hops
available. If the one-hop getter is ever wanted, it is its own change.

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

- Under `--json`, **stdout carries the document and nothing else.** On the
  App Store commands the `==>` line naming the app moves to stderr for that
  invocation; `play tracks` prints no banner at all, so there is nothing on
  that path to move. Split per store rather than stated once, because a
  sentence about the shared verb is written in whichever store the author had
  in mind and is false about the other — `docs/CONTRIBUTING.md` has that as a
  rule for a reason, and an earlier draft of this bullet broke it.
  **The listing is not redirected — it is not printed at all**, because it is
  already in the document under `display`: `printBuilds`, `printVersions` and
  `_listTracks` return the moment they have written the document. An earlier
  draft of this bullet said every rendered listing "moves to stderr", which is
  not what the code does and would have had the lines arriving twice.
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
  "newestBuildNumberAsInt": 169,
  "builds": [
    {
      "buildNumber": "169",
      "buildNumberAsInt": 169,
      "processingState": "VALID",
      "uploadedDate": "2026-09-09T14:02:11-07:00",
      "expired": false,
      "usable": true,
      "display": ["  build 169  VALID  uploaded 2026-09-09T14:02:11-07:00"]
    }
  ],
  "display": ["  build 169  VALID  uploaded 2026-09-09T14:02:11-07:00"]
}
```

One build is the smallest example and the most misleading one: the two
`display` arrays come out identical here and are not the same rendering. Past
twenty builds the document's is truncated and the items' are not, an
`appstore.versions` item carries two entries rather than one, and a
`play.tracks` document ends with a line no track owns.

## What spawning again costs, since this is a return to spawning

A stage reading Play and both Apple platforms makes five reads. Under `--json`
those are five processes rather than five calls — five `secrets exec` setups
and five auth handshakes. That is fine for a `status` nobody runs in a loop,
and it would matter for anything hotter. Nothing hotter exists.

The composition is arguably better than it costs. A store that fails is
isolated by *process*, so a run that read Play and then met a 401 from Apple
still holds Play's document and Play's exit code. The library gives that only
through a caller's own `try`/`catch` discipline — and the first version of that
discipline got it wrong, which is recorded in [read-api.md](read-api.md).

**One regression is real and specific.** `AppStoreReads.open` is a single
session shared by `appStoreBuilds` and `appStoreVersions`, and `open` is what
fails on absent credentials or an unknown bundle id. The consumer wraps both
calls in one `catch` for exactly that reason — catching per call would print
the same refusal twice under one platform. Two invocations are two sessions, so
a missing Apple credential yields the identical refusal twice per platform,
twice over for two platforms. The consumer can dedupe and says it will. Making
`appstore builds` and `appstore versions` one invocation emitting one document
would fix it at the source, and is not done here because it invents a fourth
kind to solve a problem its only consumer has already agreed to absorb.
Recorded so the next reader meets the reason rather than the symptom.

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

## `documents.dart` — the format as classes, and as published docs

Status: **built**, 10 September 2026, in the same release as `--json`.

**A consumer asked a question this document could not answer: what are the
keys, what values can they take, and what shape is a value in?** The vocabulary
was partly on the exported models' dartdoc, `appStoreState` said "and the
rest", and the key list existed only inside an encoder. Answering with prose
would have meant a field table here — the second list this document opens by
refusing.

So the format is a set of classes, exported as
`package:cux_ship/documents.dart`, with `fromJson` and `toJson` generated by
`json_serializable`. **pub.dev renders their dartdoc per version**, which makes
the API docs a published statement of the format rather than a description of
something adjacent to it — and a reader who is not in Dart at all can still
read the page.

`json_output.dart` builds these classes and calls `toJson`, so there is one
definition rather than an encoder here and a decoder in every consumer's tree.

### What this reverses, and what it does not

**It reverses the `toJson` refusal**, which was recorded here and is worth
being plain about. That refusal said document classes would exist only to be
serialized, constructed at exactly one call site each. A published `fromJson`
gives them a second call site outside this repository, at the consumer that
will otherwise hand-write a reader — which is what the objection was actually
about.

It also inverts where codegen earns its place. The **encoder** is the judgment
half: six deliberate deviations from the models, each argued at its field, and
codegen writes none of them. The **decoder** is the mechanical half, and is
exactly what a generator is for. The mapping in `json_output.dart` is still
hand-written and still the whole of that file.

**It does not make the commands into a library.** Nothing in `documents.dart`
talks to a store; these are value types over what a command printed. A caller
keeps spawning, so the printed command line still makes a failed step re-runnable
and `secrets exec --only` still keeps a credential out of a step with no use for
it. That is the trade `read.dart` gives up by construction and says so.

### Two vocabularies, two answers

**Store-owned values degrade; ours are closed.** `processingState`,
`appStoreState` and Play's `status` belong to Apple and Google, so their enums
carry a permanent `unknown` and the raw string travels beside them. Dart 3
switch expressions must be exhaustive, so adding a member is a breaking change
for a consumer that switched over one — and the trigger would be a store
shipping a state rather than this package deciding anything. **So members are
not added when a store adds a value; the value arrives as `unknown` and its
string is readable.** Adding one stays possible and stays a deliberate major.

`kind` and `platform` have no `unknown` member. Those are this package's own
names, and an unrecognized one means a document from a version that knows more
than the reader does — refusing is the answer, exactly as for an unrecognized
`schema`.

**And absent stays distinct from unknown.** A null field is a store that sent
nothing; `unknown` is a store that sent something this version does not name.

**`unknown` has a spelling of ours and none of the store's.** Every member
carries a `wire` — this package's word, which is what the document says — and
every member except `unknown` also carries the store's, which is what the
encoder reads to decide which member arrived. `unknown` has no store spelling
because it is the member that exists precisely when the store said something
this version has no word for; the store's actual word is in the `*Raw` field.

An earlier draft gave `unknown` the empty string as its only spelling, which
was a lie in the single case where the truth matters — a caller reaching for
the raw value would have been handed a plausible-looking `''`.

### A store's vocabulary arrives twice: as ours, and as theirs

**The document carries this package's own vocabulary, and the store's word
beside it.** `processingState` is `processing` / `valid` / `failed` / `invalid`
/ `unknown`, ours and closed; `processingStateRaw` is `PROCESSING` / `VALID` /
… , Apple's and unchanged. Same for `appStoreState`, `releaseType` and Play's
`status`. Two fields, and two genuinely different facts: what this package
*understood*, and what the store *said*. A caller writes against the first and
falls back to the second in the one case the first cannot cover.

Lowercase on purpose. A reader looking at `"valid"` next to `"VALID"` is never
in doubt which vocabulary they are in.

**The shape this replaced looked simpler and was measured to be lossy.** The
first version had one field carrying Apple's string, with the enum as a Dart
*reading* of it — no `@JsonEnum`, a hand-written lookup, and a shell caller
left with Apple's vocabulary and no way to reach ours. The version before
*that* typed the field with Apple's own spellings and let
`json_serializable` decode it, which was tried on `releaseType`:

```
decoded   : ReleaseType.unknown
re-encoded: null
```

The generated encoder writes `_$ReleaseTypeEnumMap[value]`, and an `unknown`
whose spelling is Apple's-or-nothing maps to null — so a state Apple ships
after a release would arrive, decode, and **go back out as `null`**, the word
destroyed in precisely the case a reader needs it.

Giving `unknown` a spelling in *our* vocabulary fixes that at the root: it is a
value rather than a hole, `"unknown"` round-trips, and the store's word is in
the sibling field where nothing can lose it. `documents_test.dart` holds it —
a document with a state nobody names, decoded and re-encoded, asserted equal.

The generated codec is therefore back, on all four store enums as well as on
`DocumentKind`, and the hand-written lookup shrinks to one job: reading the
*store's* spelling into a member, which is what the encoder does once per
field.

**And it fixes a consistency failure the earlier shape had.** `usable`,
`mayBecomeUsable` and `serving` are emitted as fields on the argument that a
shell caller gets them too and a Dart getter structurally cannot reach them.
The typed state was a Dart getter — so a shell caller had Apple's vocabulary
and nothing else, which is what this whole document says it is ending.

### One place for each spelling

The lookup is `ProcessingState.read` and its three siblings, and the reason it
exists rather than a `switch` on the string is small and worth writing down: a
`switch` case pattern must be a compile-time constant, and `processing.wire` is
not one. Branching on the string therefore meant writing `'PROCESSING'` in the
enum and again in every branch that cared — which is what the first version of
`_mayBecomeUsable` and `_serving` did, with four Play spellings duplicated
between the enum and the encoder.

Reading to a member first makes those enum switches, which buys two things: one
copy of each spelling, and exhaustiveness. A member added to `ProcessingState`
now breaks the branches that have not considered it, instead of falling into a
default that quietly answers `null`.

**The same duplication is still spread through the App Store client** —
`'VALID'`, `'FAILED'` and `'INVALID'` are compared in about eleven places in
`app_store.dart` and `cli.dart`, including the terminal-versus-transient rule
`mayBecomeUsable` now exposes, which already existed there three times and had
never reached the model or the document. That is pre-existing rather than
introduced here, and unifying it means moving the vocabularies to the store
clients and re-exporting them — its own change, with its own argument.

### The question, not the vocabulary

The point of all of it is that a caller never opens Apple's or Google's
documentation. `usable`, `editable` and `expired` already did that on the App
Store side. **The Play side answered nothing** — a caller asking "is this
rollout stopped" wrote `status == 'halted'`, which is the deferral this is
meant to end.

Emitted rather than offered as getters, for the reason this document already
gives for `usable`: a shell caller gets them too, and a Dart getter
structurally cannot reach them.

### A derived field cannot be less honest than its input

**`serving` is `bool?`, and the first draft had it as `bool`.** The consumer
review caught it by turning this document's own rule back on it: absent and
unknown are two facts and get two representations — and then a plain boolean
was derived from a vocabulary deliberately left open. A `bool` has no way to
say "a status nobody here names", and both answers it is forced to give are
claims nobody can stand behind. `false` reports a possibly-healthy rollout as
reaching nobody, on every run, until somebody upgrades. `true` calls an
unrecognized state healthy, which is the failure this repository has a habit
of paying for.

So: true for `completed` and `inProgress`, false for `halted` and `draft`, null
for a status this version does not name — and null for
`statusUnspecified` too, because Play saying "unspecified" and Play saying
nothing are the same amount of information. A caller wanting the conservative
reading writes `serving != true`.

**And `serving` is not sufficient alone.** `halted` and `draft` are both false
and call for different advice — one was stopped by a person, the other never
started — so both stay reachable as enum members. The boolean answers the
common question; the status answers the one it cannot.

### `usable` hid a second question, and that cost a consumer a defect

`usable` is `VALID && !expired`. It answers *"can I act now"* and says nothing
about *"will waiting help"* — and those are different questions with different
next actions. A consumer built its Apple advice on `usable == false` and told
an operator to wait for `VALID` in every case. That is right for `PROCESSING`
and wrong for `FAILED` and `INVALID`, which are Apple refusing the binary
during processing and never change again: the advice was "wait forever" for
precisely the two states where the answer is "upload a different build".

**The one bit `usable` exposes is what made treating all four states alike
natural**, so adding `serving` without learning from it would have propagated
the shape. `AppStoreBuildEntry.needsNewUpload` is the missing axis.

**It was called `mayBecomeUsable` first, and the review that renamed it made
the sharper point.** The rule to aim for is not "expose the second axis" — it
is that **every derived field reads correctly in isolation, in every state**. A
pair that is only safe when read in the right order gets read in the other
order, which is exactly how the defect above happened: `usable` was sitting
there, correct, and a caller reasoned from one boolean anyway.

`mayBecomeUsable` fails that test at `VALID`, where it must answer `false` and
`false` reads as "give up" precisely where everything is fine. And the case
that settled it is expiry: `mayBecomeUsable` is `false` for a healthy `VALID`
build *and* for a `VALID` build that has expired, flattening the one state
where the operator has work to do into the one where they do not.
`needsNewUpload` separates them — `false` and `true` — and every row reads
correctly with nothing beside it.

The rule lives on `ProcessingState.needsNewUpload` rather than inside the
encoder, so that the three copies of it already in the App Store client have
somewhere to move to: the next change deletes them rather than reconciling
with a fourth.

`usable` and `editable` stay plain `bool` and fail closed, deliberately. **A
boolean that gates an action should fail closed; one that reports a state
should admit ignorance.** `usable == false` therefore means "not known to be
usable" rather than "not usable", and its doc comment says so — refusing to
release a build whose state is not understood is the safe direction, where
reporting one as dead is not.

**Deliberately not a fraction** — how much of the audience a staged rollout has
reached is the release-and-rollout task's, not this one's. That task now has a
named consumer requirement waiting on it: a consumer documents that a 1%
rollout reads exactly like a finished one, and names this document as the
reason.

### `uploadedDate` stays a string

No `DateTime` anywhere in these classes. A Dart type in the rendered docs is a
translation a non-Dart reader has to perform, and `DateTime.toIso8601String` is
not the string Apple sends — so the document carries Apple's spelling and the
`uploadedAt` convenience stays on the model, out of the document.

## Hand-written, and what would change that

Status: **decided**, 10 September 2026 — and the half this section argued
against was *taken*, which is worth reading before the argument below.

**Codegen arrived, for the decoder.** `documents.dart` above is generated by
`json_serializable`, the workspace now carries `build_runner` and
`json_annotation`, and `documents.g.dart` is committed with `tool/check.sh`
regenerating it and failing on a diff. So this section is no longer about
whether codegen belongs here at all.

**What stayed hand-written is the mapping**, which is the whole of
`json_output.dart`: the six deviations between the models and the documents.
The section below is why, and it is unchanged by the decoder arriving.

### The case for annotated document classes, which was real and was taken

**The keys stopped being strings.** `'newestBuildNumberAsInt': …` was a string
literal, so a typo was caught by `json_output_test.dart`'s key set and not by
the compiler — and this repository's whole disposition is that a check beats a
test. Field names on a class are compile-checked and nullability lands in the
type system, which is now the case.

`json_serializable` is also not a risky dependency. It is dart.dev-published
and among the most used packages in the ecosystem, so the ecosystem argument
that applies to the schema generators below does not apply to it.

### What it would not remove, which is the deciding half

**The encoder is not a serializer.** Between the models and the documents it
renames `line` and `lines` to `display`, drops `uploadedAt`, adds
`newestBuildNumberAsInt` reached through `newest`, adds a `bundleId` that is on
no model at all, flattens `platform` to `platform.api`, and passes a parent's
`track.name` into `release.lineOn` so a release can say which track it is on.
Every one is deliberate and every one is argued in a comment beside the field.

Codegen generates the `toJson` half. **The mapping half — where all six of
those decisions live — is exactly as hand-written as it was**: a map literal
became a constructor call, the same lines carrying the same judgment.

### What actually decided it, and the objection that did not survive

The ledger against was `build_runner` as a step in `tool/check.sh` and in CI,
committed `.g.dart` that `dart pub publish` needs present, a `json_annotation`
runtime dependency in a pubspec that argues every line — **and a set of classes
that exist only to be serialized, constructed at exactly one call site each.**

That last one was the deciding objection and it did not survive the shape that
was actually proposed. **A published `fromJson` gives the classes a second call
site, outside this repository**, at the consumer that would otherwise
hand-write a reader. Classes with one internal call site are scaffolding;
classes a consumer decodes into are the format. The other costs were real and
were paid.

The trigger this section once named — roughly double the document count — is
therefore spent, and the reason it was the wrong trigger is worth keeping: it
counted documents when what mattered was whether anything outside this
repository would ever construct one.

## Publishing the schema, which is still open and now weaker

Status: **open**, 10 September 2026. A gap that was measured, a fix that was
designed and not built — and a different fix that was built instead and closed
most of it.

**`documents.dart` is what answers this for a reader.** pub.dev renders its
dartdoc per version: every key, its type, its nullability, its vocabulary, and
the questions derived from them, on a hosted page a non-Dart reader can read as
well as a Dart one. That was the whole of what schema files were wanted for,
and it is now done by something a consumer also *uses* rather than merely
reads.

What a schema file would still buy is the machine-readable half: validation,
and `quicktype` against a URL for a consumer in another language. Real, and
much smaller than the case below, which was written before the classes existed.
Two caveats belong to the reader who picks this up: the dartdoc states Dart
types rather than JSON types, so a reader translates `String?` and
`List<String>`; and nothing there is machine-checkable.

The measurement that motivated it, kept because it is still true of the
encoder:

**A consumer cannot see a document's shape in the published package's API
docs.** `json_output.dart` is in `lib/src/`, dartdoc does not document
`lib/src/`, there is no `dartdoc_options.yaml` overriding that, and no public
library exports it.

**The source does ship, though, and an earlier draft of this section said
otherwise.** It claimed the key list "lives on GitHub and nowhere else", which
is false: `pub publish` puts all of `lib/` in the archive, so
`json_output.dart` is in every consumer's pub cache. That is not hypothetical
reading either — the consumer this was built for checked the 4.2.0 models that
way before answering a review.

So the gap is narrower than first written, and it is still a gap. Learning a
wire format by reading the encoder that emits it is worse than reading a
statement of the format, and it is only available to a *Dart* consumer at all:
a shell `status` or a Python step has no pub cache to look in. What those get
is what pub.dev renders — `--json`'s own `--help` text, the README's *Reading
the stores as JSON* section, the changelog entry, and this document linked from
the README.

**And `read.dart`'s dartdoc is a good source for meaning and a bad one for
shape**, which is the worse of the two failures: the member names are the item
keys in most places and are not in three — `line` and `lines` are `display`,
`uploadedAt` is absent from the document, `newestBuildNumberAsInt` is absent
from the model. Those are exactly the places a reader working from the API docs
would get it wrong, and getting it nearly right is what makes it dangerous.

The fix, when it is wanted: `cux_ship/schema/<kind>.v<n>.schema.json`, hand
written, under `cux_ship/` so they ship inside the published archive as well as
having a stable URL. **Immutable by construction** — the schema number is per
kind and only increments, so v2 is a new file and v1 never changes again, and a
consumer holding a document written six months ago reads its `schema` and
fetches exactly the file that describes it. A validator as a dev dependency
then makes the test ask *"does this document validate"* rather than compare key
sets by hand.

**Not a `--schema` flag on the commands.** `--help` belongs to `CommandRunner`
— both parsers say so where they decline to add one — and a mode selected by
combining flags is what this CLI moved away from when `--promote` and
`--list-builds` became subcommands. A flag would also only ever describe the
installed binary, where a per-version file answers for a document already
written.

**And not generated, because nothing generates it.** Every package requires the
shape declared somewhere; none infers nullability or "may be empty" from an
encoder. The survey, recorded so it is not repeated: `ack` with
`ack_json_schema_builder` is the schema-first option with real traction;
`schemantic_builder` (genkit.dev), `typed_llm_generator` and `spectra_schema`
generate schemas from annotated classes and had no likes between them;
`betto_schema` validates 2020-12 in pure Dart and is what a test would use;
`schema2dart` goes the other way and is what a *consumer* would run against
published files.
