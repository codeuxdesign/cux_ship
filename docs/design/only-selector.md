# `--only`: the child gets what you name

Status: **proposed**, not built.

**Backward compatibility is not a constraint.** Three projects consume cux_ship,
they sit in adjacent directories, the same people maintain all of them, and
every call site will be rewritten by hand. Nothing here is shaped by what
existing invocations happen to say.

## The design

**`keychain exec` gives its child the keychain it made, and nothing else.
Whatever else the child needs, the call site names.**

```
keychain exec --profile ios_appstore -- tool/build.sh           # APPLE_KEYCHAIN only
keychain exec --only ssh_keys.github_deploy -- ci-release.sh    # and the deploy key
keychain exec --only tokens.marks -- tool/build.sh              # and that token
```

`secrets exec` is unchanged: it places everything. It is the general-purpose
wrapper, and a general-purpose wrapper that hands over nothing is inert.

The selector is a comma-separated list of `family` or `family.instance`:

```
tokens                      every token
tokens.marks                that one
apple.certificates          every certificate
android.keystores.upload    that one keystore
```

## Why the default is nothing

This document had three earlier defaults, and each was an attempt to make
"pass the right things automatically" sound principled. All three failed, and
the shape of the failures is the argument for having no default at all.

**"The minimum that signs."** Rested on the claim that `keychain exec`'s child
is an Apple build and nothing else. False: in one project the child is a release
script that builds, uploads and pushes over ssh; in another it reads a changelog
and writes a manifest. `keychain exec` is the *outer* wrapper in both, precisely
because it is the one that places no App Store key — which makes it the natural
place to hang everything else.

**"Withhold values, pass paths."** Half a threat model. It would have passed the
Play service account, which is path-shaped since 2.0.0 and still withheld —
because a child holding that path can publish to Play whether or not anything
prints it. That is not exposure, it is capability, and one rule could not say
both.

**"Two rules, applied per variable."** Broke worse. Per-variable splits a
credential in half: it would pass `ANDROID_KEYSTORE_PATH` and strip the password
beside it, which is the state this codebase calls dangerous everywhere else and
throws on for the Apple analogue — *"half a credential is worse than none"*. It
also resurrects the keystore lockout, since whole-family withholding is what
lets `keychain exec` avoid choosing between two keystores. It is not derivable
from the schema either: token variable names are project-declared, so a token
named `FOO_PATH` classifies as a path and is passed. And it is inexpressible as
a selector string, so the default would live as a constant in the source —
exactly what replacing the constant was for.

The "capability" half never became a rule at all. Asked to decide `ssh_keys` it
could not, and the document had to punt to deciding family by family. A rule
suspended for the first family it meets that it was not reverse-engineered from
is not an axis; it is a name written over two decisions already made.

**Three attempts, each needing more structure than the last, ending in one rule,
one guarantee and a seven-row table.** That is not a default anyone holds in
their head.

And the reason is structural rather than a failure to write it well: **a default
has to satisfy every consumer, so it is the union of their needs, and a union is
wrong for each of them individually.** That is what kept demanding more
structure — three attempts to make one list correct for three different
children, the last needing a table because that is what a union looks like
written out. A union has no explanation, only a membership list.

A call-site selector is each consumer's own set. It is smaller, and it has a
reason that fits in the flag: *this build bakes one token, so it names one
token.*

An empty default has none of these problems because it makes none of the claims.
It does not need to know what the child is, what a credential is shaped like, or
what capability it confers.

### What it withholds is what cux_ship placed

Not the ambient environment. `PATH`, `HOME`, `SSH_AUTH_SOCK` and everything else
inherited from the invoking shell are untouched — the filter removes credentials
this tool put there, and nothing else.

Worth stating because it looks like a counterexample and is not: one project's
build authenticates to git during the build, through an agent socket that
cux_ship never placed. An empty default cannot break it. A reader whose first
question is "does my build still have git access" needs that answered once,
here, rather than by experiment.

### Both kinds of list rot; the failures differ

An honest comparison, because the call-site list is not immune:

- **A call-site list that becomes too narrow fails loudly**, immediately, in the
  one build that is wrong, in front of whoever changed it — and the tool's own
  "removed from the environment" line is in the log beside the failure.
- **A call-site list that becomes too broad is silent.** What makes it tolerable
  is that it is *visible in a diff*: the flag sits in the same repository, and
  usually the same change, as the consumption that justified it.
- **A tool default that grows a family is silent for everyone**, and the change
  is in a different repository behind a version pin, which no consumer's review
  ever sees. That is how a Play service-account key reached four public logs.

So the claim is not that call sites are better maintained. It is that the failure
becomes local, loud and reviewable instead of shared, silent and invisible.

## What an empty default buys

- **No premise about the child.** It does not matter what the script does.
- **`ssh_keys` needs no decision.** Nothing passes unnamed, so there is no
  question of whether this family should.
- **The App Store guarantee is free, and only because the sops identity goes
  too.** `ios.yaml` relies by name on the archive being unable to hold a key that
  could create or revoke signing material. An empty default gets that for
  nothing — but it would have been a hollow guarantee if the child still carried
  `SOPS_AGE_KEY`, since a key to the file that *holds* `apple.api_keys` can mint
  the credential the guarantee denies. Stripping the identity unconditionally is
  what makes this bullet true rather than nearly true. `--api-key` remains the
  consent switch.
- **No half-credentials.** Credentials are named whole.
- **No keystore lockout.** Nothing is auto-selected, so nothing has to choose
  between two keystores.
- **The default is trivially printable.** It is empty.
- **It is honestly fail-closed**, which the earlier drafts claimed and only
  half-delivered.

The cost is real and is the point: **a call site now states what its build
consumes.** That is knowledge the tool cannot have — it wraps a build script, so
consumption happens below its argv, four layers down, sometimes with the
variable name inside a `printf` format string. Writing it at the call site is
the only place it can live, and an empty default is what forces it there.

## The selector

### Not resolving is an error

`--only tokens.marsk` fails, naming what exists. Three cases, three messages:

- **Unknown to the schema** — `tokns` — is fatal.
- **A named instance absent from the file** — `tokens.marsk` — is fatal. Naming
  an instance is an existence claim.
- **A known family, empty in this file** selects nothing, is allowed, and is
  **reported**. Naming a family is a scope, not a claim about contents.

The third matches a line `decideProfile` already draws: a named profile absent
from the file is fatal, one that merely turns up unnamed is warned and skipped.
A tool that draws one line in two places for the same question is better than
one that draws two.

The report has to read as anomalous rather than as a tally, because it is now
carrying the whole weight of the silent-nothing worry:

```
==> family "tokens" selected, but there are no tokens in secrets/release.yaml
```

not `0 selected` at the end of a list.

### Resolution is against what this process holds

Not against the file, and the difference appears under nesting:

```
secrets exec --only apple.certificates -- keychain exec --only tokens.marks -- build
```

The outer filtered its child to certificates; the inner then asks for
`tokens.marks`, which did not arrive. Validated against the *file* that passes,
and the build dies four layers down with `MARKS_TOKEN is not set`. Validated
against what the process holds, it stops here and names it.

**A partial match is fatal**: `--only a,b` where `a` arrived and `b` was
stripped upstream names `b` rather than proceeding with `a`. And a family
present in the file but stripped upstream is fatal too, with its own message —
it is not the empty-family case, and pointing at the file would be the wrong
diagnosis.

This is the 1.9.0 bug from the other side. That one filtered placement instead
of visibility; this would validate against the file instead of against
visibility.

### `--only` filters what the child sees, not what this process places

Under `secrets exec -- keychain exec -- build` the outer has already placed
everything before the inner runs. If `--only` meant "which credentials I place",
the inner filter would achieve nothing while reading as correct at every line.
So it removes non-selected variables from the child's environment however they
got there — which is what the current static withholding already does, what
1.9.0 got wrong and 1.9.1 fixed, and what the `includeParentEnvironment: false`
on the child guarantees. It belongs in a test.

Nested selectors compose as intersection: an inner command can only pass on what
it received, minus what it strips.

### Grammar

- **Resolution is schema-aware.** `apple.certificates` and `tokens.marks` are
  both two segments; only the schema says which is family-plus-instance. A
  *section* — `--only apple` — is neither production and is refused, naming the
  families under it.
- **Some families cap instances at one.** `--only
  android.keystores.upload,android.keystores.mirror` parses and cannot be
  satisfied: there is one set of `ANDROID_*` names to fill. Refused, saying why.
- **`--keystore` and `--api-key` are refused when `--only` is given.** They exist
  to resolve which instance fills a singular set of variable names, and an
  instance named in `--only` already says that. Adjudicating their interaction
  was three rules; refusing them flat is one, and the error names the
  replacement. They survive only for the no-`--only` mode of `secrets exec`,
  where the ambiguity still needs an answer. A side effect worth having: one
  project's iOS upload currently passes a vestigial `--keystore upload` that
  exists solely to appease ambiguity refusal, and it disappears.
- **`--profile` is a different axis and is not replaced.** It selects which
  profiles get *installed for Xcode*; `--only` selects what the child's
  environment holds. Readers will conflate them, so `--only apple.profiles.*` on
  `keychain exec` is refused, pointing at `--profile` — the same shape as
  `placed.foo` pointing at `secrets place`.
- `--only placed.foo` on an exec command is refused, pointing at `secrets
  place`: exec never writes placed files.

### One absence this cannot make loud

Fail-closed at the environment is not fail-closed at the build, and there is one
family where the difference bites. A missing Android keystore does not fail as
"you forgot the keystore" — Gradle falls through to the debug key and produces an
artifact only the store rejects, after a full upload. That is the whole reason
ambiguous keystore selection is fatal rather than guessed.

It never reaches `keychain exec`, whose child cannot sign an Android artifact.
But `secrets exec --only tokens.foo -- build android` reintroduces exactly that
state. So on `secrets exec`, an `--only` that omits a keystore the file holds
should say so rather than proceed silently — the one place where naming a subset
deserves a question rather than obedience.

No wildcards — family selection *is* the wildcard. No negation — "everything
except X" is the fail-open shape wearing selector syntax, and it is what this
design exists to avoid.

### What is removed is reported

`keychain exec` already prints what it withheld. That line should name what
`--only` excluded, so a caller who forgot the flag sees it in the log beside the
failure rather than guessing.

## `SOPS_AGE_KEY` is not covered by any of this, and should be

It is the master key to the whole file, it is value-shaped, and it is in the
child's environment — which on an Apple build is written wholesale into the log
by an Xcode script phase. It is not a credential *in* the file, so it is not a
family, so no selector can name it and no default touches it.

**It is stripped from the child, unconditionally, with no way to readmit it.**

The obvious objection is that one project's release nests `secrets exec`
*inside* the `keychain exec` child, so that child decrypts again and needs the
key. That was nearly the reason for a readmit flag. It is the wrong fix, because
the nesting is itself the thing to remove.

The nest exists to scope a credential to part of a script: the archive must not
hold an App Store key, the upload must, and they are two phases of one child. But
if two phases need different credentials they should be two invocations, not one
wrapping the other:

```
keychain exec --only ssh_keys.github_deploy -- build.sh   # signs; no ASC key, no age key
secrets exec --api-key upload -- upload.sh                # uploads; has both
```

The scoping is then done by the step boundary. Checked before proposing it: the
ios and macos arms of that project's release script are already
build-then-`secrets exec`-upload in sequence, two lines each, so the split is
mechanical rather than a redesign.

What that buys is worth more than the flag it deletes:

- **the readmit spelling has no consumers and does not exist** — one less
  concept, and one less thing that is a flag away from false;
- **"`keychain exec`'s child never holds the sops identity" becomes a flat
  guarantee**, not a default;
- and the App Store guarantee below stops being conditional. With a readmit, an
  Xcode script phase would dump an environment containing the master key to the
  file that holds `apple.api_keys` — so the archive could mint the very
  credential the guarantee says it cannot hold.

Two things to know before someone "fixes" this later. `ci-install-deps` also
consumes `SOPS_AGE_KEY`, but as a **sibling workflow step outside the wrapper**,
so stripping does not touch it. And in one consuming project the key is *already*
absent from the `keychain exec` child — measured, not inferred — so for them this
writes down an invariant that holds by accident rather than changing anything.

That the only consumer is cux_ship itself is verified for the project that
nests. It is checked per project rather than assumed about the world.

Today the only thing protecting this key in a public log is the CI provider's
secret masking, which works because it is the one registered Actions secret. The
Play service account leaked precisely because sops-decrypted material is
invisible to that masker; `SOPS_AGE_KEY` is covered only because it never passes
through sops.

Today the only thing protecting it in a public log is the CI provider's secret
masking, which works because it is the one registered Actions secret. That is
worth stating out loud: the Play service account leaked precisely because
sops-decrypted material is invisible to that masker, and `SOPS_AGE_KEY` is
covered only because it never passes through sops.

## What this deliberately does not do

**It does not detect which credentials a child consumes.** That was proposed and
is not possible. In one real case cux_ship's whole argv is `tool/build.sh
--release ios`, while the token is read four layers down inside a function where
its *name* is a JSON key in a `printf` format string. A rule of "do not withhold
a credential whose variable appears in the command line" would have withheld the
one token that must never be withheld — it fails on the example it was designed
around.

Scanning the script does not rescue it. In that same file the token name appears
seven times: once in real consumption, once in a format string, and five times
in `die` messages and comments — including one saying it must not be withheld. A
detector that reads a warning about a credential as evidence the credential is
needed is worse than no detector.

**It is hygiene, not containment.** `--only` filters the environment channel. A
child holding the sops identity can decrypt the file itself, which is exactly
what a nested `keychain exec` does.

**It does not go on `place`, `pack` or `clean`.** Those have no child. `--only`
exists because a child's environment is *broadcast* — inherited by everything it
spawns and printed wholesale into a log. A file `place` wrote is not broadcast.
And `place`/`clean` are a pair: independent selectors could desynchronise into a
credential left materialised in a working tree, which is the opposite of the
point. `pack` runs the other way, so a filter there is a partial write.

`secrets check` also keeps checking everything. A scoped check is a check people
learn to trust wrongly.

## What it costs to adopt

```
authpass      keychain exec --only ssh_keys.github_deploy -- build
              secrets exec --api-key upload -- upload-and-push     # was nested inside
storyteller   keychain exec --only tokens.marks -- tool/build.sh
```

The storyteller change is one line and is already written. The authpass change is
the step split described under `SOPS_AGE_KEY` — its `keychain exec` child cannot
simply gain a flag, because it is the project that nests.

**And on the other side of the ledger, authpass deletes more than it adds.**
`ci-release.sh` currently carries a hand-maintained *denylist*: ten `unset` lines
and a comment essay, including a claim that had to be verified by hand across
five scripts ("Verified in build-ios.sh, build-macos.sh, upload-ios.sh,
upload-macos.sh and release.sh: none of them mentions these"). That block exists
only because the current default is fail-open. Under an empty default the whole
of it is deletable, replaced by one token in the workflow.

That is the strongest concrete evidence for this design: the complexity is not
being moved to the call site, it is **already at the call site**, in negated
form, and this removes it.

Two stale strings in that project should be fixed in the same change, since both
are already wrong: `ci-release.sh`'s guard says "run this under 'cux_ship secrets
exec'" when the wrapper is `keychain exec`, and `release.sh` still claims
`build-ios.sh` imports a certificate into a keychain, which the workflow
contradicts.

The third project's `keychain exec` child needs nothing beyond the keychain, and
that is measured rather than assumed: its build reads `APPLE_KEYCHAIN` and one
token on the Apple path, and its Android path runs under `secrets exec`, whose
default does not change.

## Structural work required

`familyVariables` is a static map from family to variable names, and token
variable names come from the file's `env` field, so it must become a function of
the parsed file. The nested case sharpens this: an inner `keychain exec` takes
the certificates-already-present branch and never calls `loadSecrets`, so it
must learn those names without decrypting. That is possible because `env` and
the instance names are cleartext, but the existing shape-inspector discards
cleartext values and a reader that keeps them does not exist yet. Build this
first; everything else depends on it.
