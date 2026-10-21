# Adopting this, and the arguments behind it

**This is not a setup guide.** It is the reasoning one project arrived at while
composing a release pipeline out of `cux_ship` and a few scripts around it —
offered because the reasoning is what transfers, and because a file list does
not tell you which parts you are free to do differently.

There is deliberately no migration checklist here. `docs/RELEASING.md` covers
this repository's own release, and a checklist for moving *another* project onto
this shape should be written **while the first such migration happens**, not
before it. Two reasons, and the second is a rule this repository already keeps: a
setup guide nobody has followed is untested documentation, and it fails the way
untested things do — silently, on somebody else's machine. And designing the
general shape from one adopter is the mistake that the "one and a half
implementations" note in the adopting project's own SHIPPING.md warns about. The
second project is the evidence. Write it down then.

## Three kinds of piece, and only one of them installs

The distinction matters more than any individual decision, because it tells you
what you get and what you must own.

| | |
|---|---|
| **Packages** | `cux_ship` and `cux_ship_verify`. You add them and they are yours. `cux_ship_verify` has no dependencies at all, which is what lets it sit in `dev_dependencies` and run in CI with no secrets. |
| **Scripts** | Thin wrappers around the packages, and a manifest tool for media too large to commit. Copied, not installed. They are short on purpose and each project's will differ. |
| **Decisions** | The rest of this page. Nothing to install; the part that is expensive to rediscover. |

## The decisions

### Not fastlane

`fastlane deliver` validates screenshot **dimensions** and little else. In
particular it has no alpha-channel check, and Apple rejects any screenshot
carrying transparency — *after* the upload and the processing wait, which can be
hours. Every macOS screen capture carries an alpha channel whether or not it uses
one, so this is the ordinary case rather than an edge one.

`cux_ship_verify` exists to move that class of refusal to the push that
introduces it. The rule generalises past screenshots: **a store's own validation
is the worst place to discover a problem, because it is the slowest and the
least specific.**

### A pinned wrapper, never a bare command name

Put a two-line script in your repository that `cd`s to a directory with a
lockfile and runs `dart run cux_ship` from there. Then use *that*, in
documentation as well as in scripts.

The failure it prevents is not hypothetical. A globally activated `cux_ship` on
`PATH` and a lockfile-pinned resolution are two different programs answering to
one name, they drift, and there is no `--version` to ask. The project this came
from lost an afternoon to an upstream fix reported as "not landed" — it had
landed, in the pinned version, and the command being typed was the global one.

The scripts were never exposed to this because they already `cd` before running.
The *documentation* was: sixty-two invocations written as a bare command name,
which is not pinned however carefully the package is. **The wrapper is for the
reader.**

### The offline half is offline on purpose

`cux_ship_verify` carries the changelog parser, the store metadata model and the
checks over both, and depends on nothing. `cux_ship` depends on it, never the
reverse.

That direction is what lets a CI job run every check without credentials, a
network, or thirty transitive packages — and a check that needs secrets is a
check that only runs where secrets are, which is usually the last moment before
an upload.

### Media that regenerates does not belong in git

Screenshots and preview videos are large, they change whenever the UI does, and —
once capture is automated — they are *regenerated* rather than edited. Each
regeneration commits a full copy that history never gives back. One project
measured 15 MB of listing images in a 58 MB pack from a single generation; at
four locales a generation is closer to 170 MB, and a 30-second App Store preview
is about 45 MB on its own.

**Not Git LFS.** It is still git: every clone and every CI run pays for it, the
quota is per-repo and priced badly, and removing something is painful — which is
precisely the regeneration case, where each new set obsoletes the last.

**A tracked manifest and untracked bytes.** One line per file — path, size,
sha256 — committed; the bytes on a bucket or a host you already have. A release
is still described by one commit, because the manifest is in it. Fetching is
opt-in, so somebody fixing a bug does not pay for the listing media. And the
staleness check *improves*: regenerate, and the diff is a few lines of text
naming exactly which files changed, rather than an opaque binary blob.

### Regenerable and hand-made media are not the same category

A screenshot can be rebuilt by a command, so a missing one is an inconvenience
and the fix is that command. A preview video is cut by hand, so a missing one
means editing it again and no tool can help.

Same manifest, different message. A gate that tells you to re-run the capture
tool about a video is confidently wrong, and confidently wrong is worse than
silent.

### A release gate fails where a test would skip

This is the one place store media differ from test fixtures. A test wanting a
large fixture should **skip, loudly** — a clone without it is the normal state,
not a broken one. You cannot upload a listing whose images are absent, so the
same absence is a **hard failure** before a release, and the message must name
the fetch rather than leaving somebody to find it.

Watch for the destructive variant: some publishing APIs treat *present* as
*owned*, so an empty screenshots directory is not a no-op waiting to be noticed —
it is an instruction, and the listing loses its pictures. An unfetched checkout
uploading is worse than a failed upload.

### A guard that cannot fire is worse than none

Put the check where it can actually refuse something, and if a path genuinely
cannot reach the bad state, write down *why* instead of adding a guard there.
An unreachable guard reads as cover: the next person has to prove it never
mattered before they can remove it.

The same rule applies to tests, and this repository's `CONTRIBUTING.md` states it
first: watch the guard's test fail with the guard removed, or you have proved
nothing about the guard.

## What is not packaged yet

The manifest tool is a script, not a command. That is deliberate: it exists in
one project, and one adopter cannot tell which parts of it are general and which
are that project's accidents. When a second project needs it, that is the
evidence — and the seam to preserve until then is that **recording and verifying
never touch the transport**. Writing a manifest from a tree, checking a tree
against a manifest, and refusing a release are pure and identical everywhere;
fetching and pushing are yours. Keep those apart and lifting the first half here
is a move rather than a rewrite.
