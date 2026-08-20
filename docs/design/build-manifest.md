# The build manifest, schema 2

Status: **built**, 20 August 2026 — `cux_ship manifest write`, and the reader
takes schema 1 and 2 alike. Parts of it are still unexercised; *Status* at the
end says which and is the honest account.

This document specifies **the file**. When it is written is
[build-lifecycle.md](build-lifecycle.md), which proposes splitting the write into
a `begin` before the build and a `seal` after it — because the four fields this
document requires a producer to supply are exactly the ones nothing can verify
in the current ordering. That is specified and unimplemented; this is what
ships.

## What it is for

A manifest records what a build produced, so an upload can be *told* rather than
asked to guess. Three fields cannot be recovered from the artifact at any price
once the build is over:

- **`gitSha`** — the commit it was built from. Nothing inside a signed `.ipa` or
  `.aab` records it.
- **`dirty`** — whether the tree was clean. Unknowable afterwards.
- **`sha256`** — the digest *as written down when the artifact was produced*.
  Recomputable, but then it compares the file to itself and proves nothing.

The rest is convenience worth having: typing those flags by hand cost three
consecutive failed uploads in one afternoon, and a release where two platforms
shipped build 51 beside a third on 52.

## Why a writer

**Not because two producers agree.** They are not independent — one was ported
from the other and the porting commit says so. Copies agreeing is evidence of
copying.

The case is duplication: one format, two hand-maintained producers, a third
repository would make three, and that porting commit's own "with three changes"
is already drift.

## Two documents, not one

The draft this replaces required a single document to both sit beside an
artifact *and* travel inside it. Those cannot be the same document:

- **Self-reference.** A manifest inside a tarball cannot carry the tarball's own
  digest — it does not exist until the container is closed, and writing it in
  would change it.
- **Ordering.** Embedding must happen *before* pack and sign; injecting into a
  signed `.msix`, snap or deb afterwards is a repack that invalidates the
  signature. The sidecar's digest is computed *after* signing, over a container
  that already contains the embedded copy.

| | **Sidecar manifest** | **Provenance card** |
|---|---|---|
| Where | `<artifact>.manifest.json`, beside it | inside the container |
| Read by | uploaders | repackagers |
| Carries | build facts **+** `artifact`, `sha256`, `format` | build facts only |
| Written | after signing | before pack and sign |

`artifact` and `sha256` are **required in a sidecar and forbidden in a card.**

## Granularity: one sidecar per artifact

Schema 1 is one file per platform directory. That does not survive AuthPass: six
Android flavors from one commit in mutually blind CI jobs, plus iOS, a MAS
`.pkg`, a notarized Developer ID build, a tarball, a snap, a deb, three Windows
shapes and web. A reader is handed an explicit manifest path in both schemas,
so telling a schema-1 `manifest.json` from a sidecar needs no per-repository
configuration — the `schema` field, not the filename, says which rules apply.

**An artifact is a single file.** A required digest of a directory is not a
thing, so directory outputs are archived first — but see the archaeology below
before assuming that is free.

### What schema 1's fields actually meant

Established by the repository that wrote them, in the one commit that introduced
both (`48639f2`), against a claim of mine that was false.

**`artifactKind` is the file-versus-directory distinction, and it is used.** I
asserted it means `file` in every manifest either repository has written. True
here — this `build.sh` handles android, ios and macos and writes `file` from two
call sites — and false there, where the web build writes `directory`. I had no
way to check the second half and stated it anyway.

That makes "directory outputs are archived first" a requirement rather than a
restatement. That repository's web artifact is digested with a tree hash and
`rsync`ed to the host; there is no archive anywhere in the path. So dropping
`artifactKind` is not a field deletion for them, it is a change to how web is
built *and* shipped, from tree-sync to archive-and-unpack.

**`variant` is two axes, not one, and `format` only covers one of them.**

| platform | `variant` | what it is |
|---|---|---|
| android | `aab` | artifact format |
| ios | `ipa` | artifact format |
| web | `js` \| `wasm` | **compile target** |

`js` and `wasm` are not formats — the output is a directory either way, and what
varies is whether it went through dart2wasm, which decides whether the host must
serve COOP/COEP headers. Renaming `variant` to `format` would put `wasm` in a
field whose enum does not contain it, **and it would still parse**: the
information does not error, it becomes wrong.

**Schema 2 does not model compile targets.** A repository that needs one puts it
under `x` until a second repository needs it too, at which point it earns a real
field with a name — `target` — chosen deliberately rather than inherited.

### What the migration actually costs

Scored by the repository that inherits it, rather than estimated from here:

| | |
|---|---|
| `buildNumberAssigned` promoted | mechanical — already written, same meaning |
| `variant → format` | **not mechanical** — lossy for web, needs a new home |
| `artifactKind` dropped | **not mechanical** — requires archiving the web output |

One of three. An earlier draft said schema 1 has exactly two producers, both in
repositories we control, so the migration window is short by construction. True
about ownership and misleading about cost: the window is short only if migrating
is cheap, and for the platform neither repository was thinking about, it is not.

**And a test this document proposes, applied backwards.** Every record should
name the question it answers and who asked. `artifactKind` and `variant` both
fail it seven months after they were written, which is why the wrong answer
about one of them could be inferred from another repository. Schema 2's fields
should carry their askers, or their descendants will be guessed at the same way.

## Fields

| Field | Required | Notes |
|---|---|---|
| `schema` | yes | `2`. Anything unrecognized is refused. |
| `artifact` | sidecar only | Filename, relative to the manifest. Keeps a `dist/` tree movable. |
| `sha256` | sidecar only | Of the artifact **as it will be uploaded** — after signing, over the container including its card. |
| `format` | no | `aab`, `apk`, `ipa`, `pkg`, `dmg`, `msix`, `exe`, `snap`, `deb`, `tar.gz`, `zip`. Named `format` rather than schema 1's `variant`, which collides with Gradle's meaning — *variant* there is flavor-plus-buildType, and the repository that motivated this schema has six Gradle flavors, so `flavor: playstore, variant: aab` would be misread by every Android-literate reader. **It does not absorb `variant`** — see the archaeology above. Its asker today is thin: the pre-upload confirmation line a human reads. Optional for that reason, and a consumer that ever branches on it should say so here. |
| `gitSha` | yes | `^[0-9a-f]{40}$`, validated rather than trusted. |
| `dirty` | yes | No default; absent must not read as clean. Defined as a non-empty `git status --porcelain` at the repository root, untracked non-ignored files counting. |
| `versionName` | yes | Marketing version. |
| `buildNumber` | yes | JSON integer. |
| `buildNumberAssigned` | yes | False when allocation failed and the number is a placeholder. Promoted from a repo-local field: an upload must be able to refuse a placeholder. Kept as a *pair* rather than omitting `buildNumber` when unassigned, so the refusal reads "the number is a placeholder — rebuild with git-buildnumber reachable" rather than "has no buildNumber", and the manifest stays readable for every other purpose. |
| `platform` | yes | `android`, `ios`, `macos`, `linux`, `windows`, `web`. |
| `flavor` | no | `playstore`, `sideload`, `amazon`, … Six artifacts can share version *and* build number, so the filename must not be the only discriminator. |
| `builtAt` | no | UTC, ISO 8601, seconds. **Optional because it fails this document's own test**: nothing branches on it, the notes-reconstruction argument deliberately uses the tag's date instead, and its one real consumer is ordering a derivation chain — where it already appears as an optional entry field. Write it; do not depend on it. |
| `producer` | yes | `{name, version}`. `version` is a **compiled-in constant of the writer**, never queried at runtime — two installs answering to one name is a lesson this project has already paid for. |
| `toolchain` | no | `{flutter, dart}`. Answers "which SDK built the artifact users have", a recurring support question. |
| `gitTag` | no | The exact tag at `gitSha`, when there is one. |
| `derivedFrom` | no | Ordered list, nearest ancestor first. See below. |

**`gitSha` is emitted canonical *and* validated on read.** `cux_ship` normalizes
whatever it is given, so a short sha *works* — which is exactly what lets a
sloppy producer survive long enough to break a tool that does not normalize.

## Producer requirements

The format cannot enforce these; only a build script can honor them, so they are
stated as obligations rather than left to a reference implementation.

1. **Capture `gitSha` and `dirty` before the first step that can mutate the
   tree**, and pass them to the writer. The writer takes both as required inputs
   and never derives them — a wrong value then has to be passed rather than
   drift in. Note this *relocates* the window rather than closing it: a producer
   can still capture late.
2. **Hash after signing.** A digest recorded before the signature fails
   verification on every real release rather than never.
3. **Embed the card before pack and sign.**
4. When `--dirty false` is passed, the writer re-checks and **warns** if the tree
   is dirty at write time — that means either the build mutated tracked files or
   the claim was stale. A warning rather than a refusal, because builds
   legitimately touch `pubspec.lock` and a hard stop would train people to pass
   an override.

## Consistency across one release

> **A conditional requirement — binding on a consumer that does not exist
> yet.** Any operation that ever holds more than one manifest for a single
> release **must** refuse manifests that disagree on `gitSha`, `versionName` or
> `buildNumber`.

**Nothing can enforce it today**: `upload.sh` handles one platform per
invocation, so no consumer ever holds two manifests at once — which is why this
must not be read as protection that exists. But stating it as *advice* would
leave the first multi-manifest consumer free to skip it, and skipping it is
exactly how the incident below happens again. Conditional-normative is the
honest strength: it costs nothing until such a consumer is written, and binds it
the day it is.

**The invariant it wants belongs upstream anyway — one commit, one build number,
for every platform in a release.** That is an allocator property, true before
any artifact exists, and a manifest can only observe its violation after the
fact.

**What the 51/52 incident actually was, since this document keeps citing it:**
two platforms built from *different commits* — `fef65ce` and `bd420ec` — because
a documentation commit landed between the iOS build and the macOS rebuild. Not a
lost concurrent allocation, which is the other candidate and which v1.3's
refspec split already fixed at source. Each manifest was individually correct;
the disagreement was upstream of all of them.

That matters for what would be worth building. Because it was different commits,
a **release-level pre-flight** — one command reading every sidecar before any
upload runs — would have caught it, and is the only shape that could. Because it
was not a lost allocation, nothing in the allocator needs changing. The
pre-flight is not built and waits for a second occurrence — and note that v1.3
makes one no less likely, since it fixed the other candidate cause, not this
one; a commit can still land between two platform builds tomorrow. The wait is
restraint, not protection.

## Derivation

A repackaged artifact inherits provenance: AuthPass rebuilds a `latest` Linux
tarball into a `.deb` in a separate workflow, and the deb's built commit is the
tarball's, not the repackaging checkout's.

1. **Inherited build facts are hoisted to top level, always.** The deb's
   manifest carries the tarball's `gitSha`, `dirty`, `versionName` and
   `buildNumber` as its own. `derivedFrom` must be **ignorable**: a reader that
   knows nothing about derivation still gets true answers from the fields it
   already reads. A format where the real `gitSha` lives in a nested block is a
   format where some reader reads the wrong one.
2. **`derivedFrom` is a flat ordered list, nearest first** — each entry
   `{artifact, sha256, builtAt?, producer?}`. A repackager writes
   `[parent] + parent's own derivedFrom`, so chains survive multi-step
   repackaging. Cards carry `derivedFrom` too. Nesting would duplicate the
   hoisted facts and create two places for them to disagree.
3. **`derivedFrom[n].sha256` is the digest of the bytes the deriver actually
   consumed**, computed by the repackager over what it unpacked — not copied
   from a parent sidecar it may never have seen, because a `latest` tarball
   arrives without one. It is an honest "what I read", not a verified claim.

`dirty` is inherited as-is. It describes the parent's files; do not OR in the
repackaging tree's own state.

**An acknowledged approximation.** A `.deb` is tarball bytes *plus* packaging
files from the repackaging checkout, so "the deb's commit is the tarball's"
answers the question provenance exists to answer — what code do users run — and
is not the whole truth.

**Closed: the packaging step gets its own record.** Optional
`packaging: {gitSha, dirty}`, written by the repackager, describing the tree its
packaging files came from. AuthPass closed this, owning the only real chain, and
it passes both of this document's own tests: the repackaging checkout is
default-branch-HEAD-at-trigger-time, recoverable from nothing once the run is
gone; and it answers a question with an asker — *which commit's packaging files
built this deb?*, asked by whoever debugs a broken `Depends:` line or a
`postinst`, since the control file and maintainer scripts come entirely from the
packaging tree and a packaging defect is a real shipping defect.

Named `packaging` rather than `derivation`, which sits one edit-distance from
`derivedFrom` while meaning something else.

**On a derived manifest the top-level event fields are the repackager's.**
`builtAt` is the repackage time and `producer` is the repackager; only the
*identity* facts — `gitSha`, `dirty`, `versionName`, `buildNumber` — are
inherited. Said explicitly because the hoist list names those four and not
`builtAt`, and two producers would otherwise disagree about it exactly as they
would have about the field above.

## Where a card sits inside a container

**Two cards in one container is the expected shape, not a mistake to
deduplicate.** AuthPass's `make_deb` extracts the tarball *into*
`debian/opt/authpass/`, so the tarball's archive-root card lands at
`/opt/authpass/.cux-manifest.json` in the installed package by construction —
the deb ships its parent's card for free, with nobody doing anything. The deb's
*own* card, carrying the hoisted facts plus `derivedFrom` and `packaging`, is a
second file. An implementer who "tidies" one of them away destroys the chain.

**Normative, because it has a consumer today:** `.cux-manifest.json` at the
archive root for tar and zip shapes, embedded before compression. That is the
whole AuthPass derivation chain, and it supersedes BUILD-TAGS §8.1's "write the
gitSha into the tarball beside `version.txt`" with a richer record at the same
cost.

**Informative and unverified**, not to be made normative until someone has
shipped one: `/usr/share/doc/<package>/cux-manifest.json` for deb, a
payload-root file added pre-pack for msix and snap. An msix is a zip whose
payload files are hashed into the `AppxBlockMap` at pack time, so
add-before-pack-and-sign works; the constraint is avoiding the reserved names —
`AppxManifest.xml`, `AppxBlockMap.xml`, `AppxSignature.p7x`,
`[Content_Types].xml`, and the `AppxMetadata` directory. Derivation is the only
requirement that *needs* embedding and tarballs are the only derivation that
exists, so the spec loses nothing by scoping these out.

The invariant is normative for every container kind now: **embed before signing,
hash the sidecar after.** The paths are details.

## Extra keys

Unknown top-level keys are **ignored**. Anything a repository needs for itself
goes under a single `x` object that shared tools never read.

This is a staging area rather than an escape hatch, and one rule keeps it so:
**a key promoted out of `x` into the schema gets a new name if its semantics
changed.** The property unnamespaced extras cannot have is that a future schema
field can never collide with a repo-local key — without it, schema 3 adding a
field some repository already writes with different meaning is a silent change.
The trap is the *current* state, where `variant` is consumed by one repository's
uploader off the shared reader's books.

## Compatibility

- A reader **refuses an unrecognized `schema`** rather than reading
  optimistically. Every value an upload is named by comes from this file.
- A reader **refuses a sidecar whose stem and `artifact` field disagree.** Two
  sources for one name, and a copied-then-renamed artifact beside a stale
  manifest is the "every flag right, bytes wrong" family the digest check exists
  for.
- Adding an optional field does not bump the schema. Adding a required one, or
  changing an existing one's meaning, does.
- `cux_ship` reads schema 1 and schema 2 for as long as any repository writes 1.
  Both producers are in repositories we control, but the window is priced by the
  migration table above rather than short by construction — short for android,
  ios and macos, open for web until its output is archived.
- Migration from schema 1: `buildNumberAssigned` promoted unchanged; mobile's
  `variant` becomes `format`; web's `variant` is a compile target and moves
  under `x` until `target` earns its name; `artifactKind` is dropped only when
  web's output is archived. The migration is the one moment those meanings can
  silently shift, which is why they are named here.

## Not in scope: release notes

Keyed by *version*, resolved per platform at upload from committed state — not
carried here. The manifest is written by the build; the notes are legitimately
written after it, so a field for them would be either empty at write time or a
reimposition of freezing them into the build. The commit their text came from
belongs in the `uploaded/` annotation beside the built commit, which is the
record of the upload *event* and the moment the notes are resolved.

For **baked** formats the notes are inside the artifact anyway — a
`debian/changelog` rendered at build or repackage time — so the artifact is its
own record. That is not a duplicate of the card: the changelog is user-facing
listing content, the card is machine provenance, and a `.deb` carrying both is
correct.

## Status

**Built, ahead of the trigger this section originally named.** The plan was to
wait for the third producer — to write it as part of AuthPass's migration onto
`cux_ship`, so the writer would be born with two honest consumers and the
derivation block specified against a real chain. The owner chose to start it
once AuthPass's migration was down to its final PR merge, which is close enough
to that condition to act on and far enough from it to be worth recording.

So the honest state, field by field:

- **`manifest write` exists and is tested**, including the round trip through
  this package's own reader. That is the part that ends two hand-rolled
  producers, and it did not need a third repository to be worth having.
- **Schema 2 reads and writes.** Schema 1 still reads, unchanged.
- **`derivedFrom` and `packaging` are written but unexercised.** Nothing in
  either consuming repository repackages an artifact yet — the tarball → `.deb`
  → `.snap` chain that motivated them is AuthPass's, and their migration has not
  reached it. The fields are specified above and round-trip in tests; they have
  never described a real derivation. Expect the first real chain to correct
  something here, and prefer correcting it to working around it.
- **`flavor` is written but this repository has one flavor.** Its six-flavor
  justification is AuthPass's too.

The case for never building it, kept because it was real and may yet be right
about the parts above: schema 1 plus per-flavor directories survives six flavors
without a schema change, and the tarball problem is solvable with five lines
writing a sha beside `version.txt`. What that forgoes is the single writer —
which is now the half that shipped — and a derivation record that chains rather
than patching one workflow, which is the half still on paper.
