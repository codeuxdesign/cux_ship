# The build manifest, schema 2

Status: **proposed**, not built, and deliberately so — see *When to build it*.
Schema 1 exists and is read by `cux_ship` 3.4.0-dev.1; nothing writes it but
hand-rolled shell in two repositories.

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

**An artifact is a single file.** Directory outputs — `web` — are archived
first. A required digest of a directory is not a thing.

## Fields

| Field | Required | Notes |
|---|---|---|
| `schema` | yes | `2`. Anything unrecognized is refused. |
| `artifact` | sidecar only | Filename, relative to the manifest. Keeps a `dist/` tree movable. |
| `sha256` | sidecar only | Of the artifact **as it will be uploaded** — after signing, over the container including its card. |
| `format` | no | `aab`, `apk`, `ipa`, `pkg`, `dmg`, `msix`, `snap`, `deb`, `tar.gz`, `zip`. Replaces schema 1's `variant`, which collides with Gradle's meaning — *variant* there is flavor-plus-buildType, and the repository that motivated this schema has six Gradle flavors, so `flavor: playstore, variant: aab` would be misread by every Android-literate reader. Also replaces `artifactKind`. |
| `gitSha` | yes | `^[0-9a-f]{40}$`, validated rather than trusted. |
| `dirty` | yes | No default; absent must not read as clean. Defined as a non-empty `git status --porcelain` at the repository root, untracked non-ignored files counting. |
| `versionName` | yes | Marketing version. |
| `buildNumber` | yes | JSON integer. |
| `buildNumberAssigned` | yes | False when allocation failed and the number is a placeholder. Promoted from a repo-local field: an upload must be able to refuse a placeholder. Kept as a *pair* rather than omitting `buildNumber` when unassigned, so the refusal reads "the number is a placeholder — rebuild with git-buildnumber reachable" rather than "has no buildNumber", and the manifest stays readable for every other purpose. |
| `platform` | yes | `android`, `ios`, `macos`, `linux`, `windows`, `web`. |
| `flavor` | no | `playstore`, `sideload`, `amazon`, … Six artifacts can share version *and* build number, so the filename must not be the only discriminator. |
| `builtAt` | yes | UTC, ISO 8601, seconds. |
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

Sidecars make disagreement between platforms *more* representable, not less —
and the 51/52 incident is this document's own motivating story. No field fixes
that; a consumer rule does:

> **Any operation consuming more than one manifest for a single release refuses
> manifests that disagree on `gitSha`, `versionName` or `buildNumber`.**

Without that sentence the schema records the incident beautifully and prevents
it never.

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

> **OPEN — does the packaging step earn its own record?** An optional
> `derivation: {gitSha, dirty}` describing the repackaging tree would close it.
> AuthPass owns this: they have the only real chain. Shipping the approximation
> with this sentence is better than pretending the question does not exist,
> which is how the field gets added later with two producers already disagreeing
> about it.

## Where a card sits inside a container

**Normative, because it has a consumer today:** `.cux-manifest.json` at the
archive root for tar and zip shapes, embedded before compression. That is the
whole AuthPass derivation chain, and it supersedes BUILD-TAGS §8.1's "write the
gitSha into the tarball beside `version.txt`" with a richer record at the same
cost.

**Informative and unverified**, not to be made normative until someone has
shipped one: `/usr/share/doc/<package>/cux-manifest.json` for deb, a
payload-root file added pre-pack for msix and snap. Derivation is the only
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
  Schema 1 has exactly two producers, both in repositories we control, so that
  window is short by construction.
- Migration from schema 1: `variant → format`, `artifactKind` dropped,
  `buildNumberAssigned` promoted from repo-local. That migration is the one
  moment those meanings can silently shift, which is why they are named here.

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

## When to build it

**When the third producer is real** — written as part of AuthPass's migration
onto `cux_ship`, in the same change, so the writer is born with two honest
consumers and the derivation block is specified against an actual chain rather
than a guess about one.

The case for never building it is weaker than for the metadata model but real:
schema 1 plus per-flavor directories survives AuthPass's six flavors without a
schema change, and the tarball problem is solvable with five lines writing a sha
beside `version.txt`. What that forgoes is the single writer and a derivation
record that chains rather than patching one workflow.

Until then this document is the artifact: a spec with its load-bearing questions
answered and deliberately unimplemented.
