# The build manifest, schema 2

Status: **proposed**, not built. Schema 1 exists and is read by `cux_ship`
3.4.0-dev.1; nothing writes it but hand-rolled shell in two repositories.

Four questions are open and marked **OPEN** below. Two of them are load-bearing
and this should not be implemented until they are answered.

## What it is for

A manifest records what a build produced, so that an upload can be *told* rather
than *asked to guess*. Three of its fields cannot be recovered from the artifact
at any price once the build is over:

- **`gitSha`** — the commit the artifact was built from. Nothing inside a signed
  `.ipa` or `.aab` records it.
- **`dirty`** — whether the working tree was clean. Unknowable afterwards.
- **`sha256`** — the digest *as written down when the artifact was produced*.
  Recomputable, but then it compares the file to itself and proves nothing.

Everything else — version, build number, artifact name — is convenience, and
worth having anyway: typing those four flags by hand cost this project three
consecutive failed uploads in one afternoon and a release where two platforms
shipped build 51 beside a third on 52.

## Why a writer

**Not because two producers agree.** An earlier draft of this argument said the
two existing hand-written producers agreeing field-for-field was evidence the
format was right. They are not independent — `cycling_storyteller`'s was ported
from `cycling_physics_simulator`, and its commit says so. Copies agreeing is
evidence of copying.

The case is duplication: one format, two hand-maintained producers, and a third
repository would make three. The porting commit's own "with three changes" is
already drift; that none of the three touched the manifest is luck.

## Granularity: one manifest per artifact

Schema 1 is one file per platform directory — `dist/<platform>/manifest.json`,
with `artifact` relative to it. That does not survive AuthPass, which produces
up to six Android flavors from one commit in mutually blind CI jobs, plus iOS,
a Mac App Store `.pkg`, a notarized Developer ID build, a Linux tarball, a snap,
a deb, three Windows shapes and web.

**Schema 2 is a sidecar beside each artifact**: `<artifact>.manifest.json`. The
schema-1 layout is a special case of it, so a reader that finds a sidecar needs
no per-repository configuration.

## Fields

| Field | Required | Notes |
|---|---|---|
| `schema` | yes | `2`. A reader refuses anything it does not know. |
| `artifact` | yes | Filename, relative to the manifest. Keeps a `dist/` tree movable. |
| `sha256` | yes | Of the artifact **as it will be uploaded** — after signing. See below. |
| `gitSha` | yes | Full 40-character lowercase. |
| `dirty` | yes | No default. Absent must not read as clean. |
| `versionName` | yes | Marketing version. |
| `buildNumber` | yes | As allocated. |
| `buildNumberAssigned` | yes | False when allocation failed and the number is a placeholder. Promoted from a repo-local field: an upload must be able to refuse a placeholder, and today only one repository can. |
| `platform` | yes | `android`, `ios`, `macos`, `linux`, `windows`, `web`. |
| `flavor` | no | `playstore`, `sideload`, `amazon`, `huawei`, `samsungapps`, … Six artifacts can share version *and* build number, so the filename must not be the only discriminator. |
| `variant` | no | The artifact's kind — `aab`, `ipa`, `pkg`, `msix`. |
| `builtAt` | yes | UTC, ISO 8601. |
| `producer` | yes | `{name, version}` of the tool that wrote this. |
| `toolchain` | no | `{flutter, dart}` versions. Cheap, and answers "which SDK built the artifact users have", which is a recurring support question. |
| `gitTag` | no | The exact tag at `gitSha`, when there is one. |
| `derivedFrom` | no | **OPEN 2.** |

**`sha256` is taken after signing.** A producer that hashes before the signature
is applied fails verification on every real release rather than never — the sort
of thing found at the worst possible moment. The reference producer copies the
signed artifact into place and hashes that copy.

**`gitSha` is emitted canonical even though the reader normalizes.** `cux_ship`
resolves whatever it is given, so a short sha *works* — which is precisely what
lets a sloppy producer survive long enough to cause trouble in a tool that does
not normalize.

## Travelling inside a container

A derived artifact must be able to inherit provenance. AuthPass repackages a
`latest` Linux tarball into a `.deb` in a later, separate workflow: the deb's
built commit is the tarball's, not the repackaging checkout's, and today the
repackager has no way to know it.

**So a container artifact carries its own manifest inside it**, and a
repackager reads that rather than guessing from its checkout. This is the
requirement that turns provenance from a property of a directory into something
that chains — and it retires an entire class of "this upload path cannot name
its commit" problem rather than patching one workflow.

> **OPEN 1 — where, inside each container?** A tarball can carry it at the
> archive root; a `.deb`, an `.msix` and a snap each have their own conventions
> and their own opinions about unexpected files. The spec must either name a
> path per container kind or state which containers are in scope and leave the
> rest out. *Proposed*: `.cux-manifest.json` at the archive root for tar/zip
> shapes, and container-native metadata directories elsewhere — but this needs
> someone who has shipped a `.deb` and an `.msix` to check it, not a guess.

> **OPEN 2 — how is derivation represented?** "The repackager derives its own
> manifest" is a good idea rather than a format until this is decided. The
> derived artifact's `sha256` and `artifact` are its own; `gitSha` is inherited.
> A `derivedFrom` block naming the parent's `artifact`, `sha256` and `gitSha` is
> the obvious shape, and the questions are whether it nests for multi-step
> repackaging, and whether an inherited `gitSha` should also appear at top level
> where every reader already looks. **This is the crux of the most valuable
> requirement in the whole design, and it is unspecified.** AuthPass owns it:
> they have the only real derivation chain.

## When the fields are computed

> **OPEN 3 — and this is the one most likely to be silently wrong.** `gitSha`
> and `dirty` describe the tree *at build time*. A `manifest write` invoked as
> a separate step computes them at *write* time, and anything that changed in
> between is invisible. That window is not hypothetical: editing files during a
> build is exactly what `dirty` exists to catch, and it happened in this project
> the day the flag was added.
>
> *Proposed*: `write` **takes `--commit` and `--dirty` as inputs** and never
> derives them, so a wrong value has to be passed rather than drift in. The
> build knows both at the moment it starts and is the only thing that does.
> The alternative — `write` derives them and is documented as "call immediately"
> — is a convention, and conventions are what this format exists to replace.

## Extra keys

> **OPEN 4.** Schema 1 producers write fields no reader consumes (`app`,
> `artifactKind`) and one repository's uploader consumes a field the shared
> reader does not (`variant`). A spec has to say whether unknown keys are
> permitted, ignored, or refused.
>
> *Proposed*: unknown top-level keys are **ignored**, and anything a repository
> needs for itself goes under a single `x` object that no shared tool reads.
> Refusing them would make every schema addition breaking; permitting them
> unnamespaced is how two repositories end up meaning different things by one
> key. `buildNumberAssigned` and `variant` are promoted into the table above
> rather than left as extras, because both are things an *upload* should be able
> to refuse on.

## Compatibility

- A reader **refuses an unrecognized `schema`** rather than reading
  optimistically. Every value an upload is named by comes from this file;
  guessing at an unknown layout means publishing an artifact described by
  whatever happened to parse.
- Adding an optional field does **not** bump the schema. Adding a required one,
  or changing the meaning of an existing one, does.
- `cux_ship` reads schema 1 and schema 2 for as long as any repository writes 1.
  Schema 1 has exactly two producers and they are both in repositories we
  control, so that window is short by construction.

## Not in scope

**Release notes.** They are keyed by *version*, resolved per platform at upload,
and read from committed state — not from the manifest. The commit their text
came from belongs in the `uploaded/` tag annotation beside the built commit,
which is where two facts about one release are recorded together. Putting a
notes key in the manifest would freeze at build time something that is
deliberately written after it.
