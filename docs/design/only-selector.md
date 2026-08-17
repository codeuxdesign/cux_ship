# `--only`: one selector for which credentials reach a child

Status: **proposed**, not built. Decision taken; open to review of the design.

**Backward compatibility is not a constraint on this document.** Three projects
consume cux_ship, they live next to each other, and all three are migrated by
the same people who would read this. Nothing here should be shaped by what
existing call sites happen to say today. Where this breaks them, they change.
The question is what the right design is from here.

## The problem

Deciding which credentials reach a child process is currently two mechanisms,
and neither is reachable by a caller.

**One is a static per-family list, hardcoded in `keychain exec`.** It withholds
`android.keystores`, `android.play_service_account` and — unless `--api-key`
names one — `apple.api_keys`. The set is a constant in the source. A caller
cannot see it, cannot extend it, and cannot ask for something different.

**The other is nothing at all.** `secrets exec` places every credential in the
file into the child's environment. There is no way to say a build does not
consume one.

The list has never been wrong. It withholds exactly the right three families
today, and it is tempting to leave it alone on that evidence. The reason not to
is that **it has already met a family it cannot express**, and that family is
the one with a live exposure.

### Why tokens broke it

`tokens` is the escape hatch family: a project's own credentials, named by the
project, exported under variable names the project declares. In one consuming
repository there are eleven — `marks`, `marks_dashboard`, four
`review_contact_*`, four `strava_*` — of which an Apple build consumes exactly
one.

The static list cannot hold them, because its members are compile-time
constants and token instance names come out of the file at run time. So today
every token reaches every child, including an Xcode build, whose script phases
write the entire environment into a log. That is the mechanism by which a Play
service-account key reached four public CI logs; it is closed for that family
because the credential became a path, and it is open for tokens because a token
is a value by definition.

A `--withhold tokens` flag beside the static list would close the exposure and
leave two mechanisms, one of them already known to be inextensible. The next
family that does not fit gets a third.

## The design

One flag, on both commands that place credentials:

```
secrets exec  --only apple.certificates,tokens.marks -- <command>
keychain exec --only tokens.marks -- tool/build.sh --release ios
```

The selector is a comma-separated list of `family` or `family.instance`:

```
tokens                      every token
tokens.marks                that one
apple.certificates          every certificate
android.keystores.upload    that one keystore
```

Both granularities are supported because the grammar costs nothing extra and
consumers want different ones: one project would start at `tokens` and tighten
later, another needs `tokens.marks` on the first day.

This replaces the static list entirely. What `keychain exec` withholds becomes
a consequence of its default (below) rather than a constant nobody can see.

### Why `--only`, and not `--secrets` or `--withhold`

`--withhold` is subtractive, so the default is permissive: every credential
reaches every child unless a caller remembers to exclude it. That is the same
shape as the hand-maintained `unset` list one project wrote as a stopgap — the
next person adding a credential does not know to add it to the flag either.

An allowlist inverts that **on `keychain exec`**, whose default is minimal: a
newly added credential is withheld until someone names it, and the failure is a
build that says `X is not set` rather than a value riding quietly into a log.

**It does not invert it on `secrets exec`**, and this is worth stating plainly
because the rest of this section reads as though it did. That command keeps its
default of everything (see below), so a credential added tomorrow still reaches
every `secrets exec` child whose call site has not opted in. The exposure this
design was written for occurs in Apple builds, which run under `keychain exec`,
and that is where the guarantee holds. On `secrets exec` filtering is opt-in.
A generic wrapper defaulting to nothing would be inert, so this is the right
trade — but it is a trade, and a reader who takes "allowlists fail closed" from
this section and applies it to `secrets exec` will be wrong.

`--secrets` was the first candidate and is wrong on the command that needs it
most:

```
secrets exec --file secrets/release.yaml --secrets tokens.marks -- ...
```

Two flags both called secrets, one naming a location and one naming a subset of
its contents. `--only` says *filter* and cannot be misread as *which file*.

`--tokens` was the original scope and is too narrow: it names one family in a
mechanism that has to work for all of them.

### Defaults differ per command, deliberately

| command | `--only` omitted means |
| --- | --- |
| `secrets exec` | every credential in the file |
| `keychain exec` | only what signs — no tokens, no api key unless `--api-key` names one |

This is the part most likely to be got wrong, so it is stated rather than
inferred, and both help texts must say it.

The rule that makes it principled rather than two exceptions: **`secrets exec`
is a general-purpose wrapper and defaults to everything; `keychain exec` exists
to sign and defaults to the minimum that signs.** A command whose entire purpose
is one operation can know what that operation needs. A command whose purpose is
"run this with credentials" cannot.

### What `--only` governs on `keychain exec`, and what it does not

`keychain exec` is itself a consumer: it reads certificates to import them and
profiles to install them, before any child exists. `--only` does **not** reach
that. It governs the child's environment only, so `--only tokens.marks` does not
starve the command of the certificates it exists to import, and a caller does
not have to name `apple.certificates` in order to sign.

That is coherent — the child needs `APPLE_KEYCHAIN`, not the p12 paths, and the
passwords are stripped after import regardless — but it means the flag is
narrower on this command than "which credentials survive into the child"
suggests, and the help text has to say so or the first user will expect
otherwise.

**The limit of the whole mechanism, while it is being written down:** `--only`
filters the *environment* channel. A child holding the sops identity can decrypt
the file itself — which is exactly what a nested `keychain exec` does. This is
hygiene against leak-by-environment, not containment.

### The default set is a selector, not a constant

"Only what signs" is a slogan, and shipping a slogan leaves the constant at the
top of `keychain exec` renamed rather than removed. The default must be
*expressed as a selector string*, printed in `--help` and at runtime:

```
==> default selection: apple.certificates, apple.profiles
```

Enumerating it also forces a decision the slogan hides: **`ssh_keys` pass
through `keychain exec` today** — they are not in the static withheld set — and
"only what signs" would withhold them. The exported value is a path, so the log
exposure is nil, but a build that fetches over ssh mid-archive breaks. That is a
behaviour change and it needs deciding family by family rather than by phrase.

### One structural dependency

Withholding today works through `familyVariables`, a static map from family to
*variable names*. Token variable names come from the file's `env` field, so
implementing `--only`'s removal semantics requires that map to become a function
of the parsed file.

The awkward case is the nested one, where an inner `keychain exec` takes the
certificates-already-present branch and never calls `loadSecrets` — it must
learn token variable names without decrypting. That is possible, because `env`
and the instance names are cleartext fields, but it needs a reader that keeps
cleartext *values*, and the existing shape-inspector discards them. This is the
one piece of real structural work the flag requires and it should be built
first.

### A selector that matches nothing is an error

`--only tokens.marsk` must fail, naming what exists, and must never resolve to
an empty selection.

This is the condition most likely to be under-built and it is the one with the
worst failure. An allowlist that silently selects nothing produces a credential
absent four layers inside a build script, with the wrapper reporting success —
a thing that did not work, presenting as a thing that was not there. That exact
shape has caused three separate bugs in this codebase in two days: a `plutil`
exit code read as an absent plist key, twice; and a cross-check that reported
nothing wrong because its extraction had silently returned an empty list.

So: every name in the selector must resolve, and an unknown family or instance
is fatal with the valid set printed.

**Resolution is against what this process holds, not against the file**, and the
difference only appears under nesting:

```
secrets exec --only apple.certificates -- keychain exec --only tokens.marks -- build
```

The outer has filtered its child down to certificates. The inner then asks for
`tokens.marks`, which is not in what it received. Validated against the *file*
that passes, because the file does contain it — and the build dies four layers
down with `MARKS_TOKEN is not set`. Validated against what the process actually
holds, it stops here and names the missing one. A **partial** match is fatal
too: `--only a,b` where `a` arrived and `b` was stripped upstream must name `b`
rather than proceeding with `a`.

This is the 1.9.0 bug approached from the other side. That one filtered
placement instead of visibility; this one would validate against the file
instead of against visibility.

Nested selectors therefore compose as intersection — an inner command can only
pass on what the outer passed, minus what it strips. That is the correct
behaviour and it wants a test rather than a sentence.

### The grammar needs three things defined

- **Resolution is schema-aware.** `apple.certificates` and `tokens.marks` are
  both two segments; one is a family and the other is family-plus-instance, and
  only the schema separates them. A *section* — `--only apple` — is neither
  production and is refused, naming the families under it.
- **Some families cap instances at one.** `--only
  android.keystores.upload,android.keystores.mirror` parses and cannot be
  satisfied: there is one set of `ANDROID_*` variable names to fill. Refused,
  saying why. Same for two `apple.api_keys`.
- **`--keystore` and `--api-key` now overlap with `--only`.** An instance named
  in `--only` resolves the ambiguity those flags exist to resolve; and
  `--keystore upload` together with an `--only` that excludes
  `android.keystores`, or names a different instance, is a contradiction and
  fatal. This also settles the conditional in the defaults table: `--api-key`
  given means `apple.api_keys` is in the default selection.

`--only placed.foo` on an exec command is refused too, pointing at `secrets
place`: exec never writes placed files.

### `--only` filters what the child *sees*, not what this process *places*

The distinction is invisible until commands are nested, and then it is the whole
thing:

```
secrets exec -- keychain exec -- tool/build.sh
```

The outer command has already put every credential in the environment before the
inner one runs. If `--only` means "which credentials I place", the inner
command's filter achieves nothing while reading as correct at every line, and
the build inherits everything.

So `--only` means "which credentials survive into the child", and the
implementation removes non-selected variables from the child's environment
however they got there. This is not new: it is what the current static
withholding already does, it is what 1.9.0 got wrong and 1.9.1 fixed, and it is
preserved by removing from a copied environment map and passing
`includeParentEnvironment: false`. It belongs in a test rather than a comment.

### What was removed from the environment is reported

`keychain exec` already prints:

```
==> imported, so withheld from the child: APPLE_DISTRIBUTION_P12_PASSWORD
```

The same line should name credentials withheld by `--only`, so a caller who
forgot the flag sees it in the log beside the failure rather than guessing. A
credential removed from a child's environment is something the operator should
see rather than deduce — and seeing it is what tells them an outer wrapper was
handing it over.

## What this deliberately does not do

**It does not detect which credentials a child consumes.** That was proposed and
is not possible. `keychain exec` wraps a *build script* by design, so
consumption happens below the wrapper's argv: in one real case the whole argv is
`tool/build.sh --release ios`, while the token is read four layers down inside a
function, where its *name* is a JSON key in a `printf` format string. A rule of
"do not withhold a credential whose variable appears in the command line" would
have withheld the one token that must never be withheld — it fails on the
example it was designed around.

Scanning the script does not rescue it either. In that same file the token name
appears seven times: once in real consumption, once in a format string, and five
times in `die` messages and comments — including a comment saying it must not be
withheld. A detector that reads a warning about a credential as evidence the
credential is needed is worse than no detector.

So the knowledge of what a child consumes lives at the call site, written down,
which is what an allowlist forces.

## Settled questions

**No escape hatch.** `--only all` was proposed and withdrawn by the person who
proposed it, once backward compatibility stopped being a constraint: its only
justification was migration, and there is no mid-migration state when every call
site is rewritten by hand. It would become the thing a new project copies from
an old one, restoring the permissive default under a nicer name — and worse,
*looking deliberate in review*, where an omitted flag at least reads as an
omission. A caller who genuinely needs everything writes everything out, and
"this build consumes all eleven credentials" should look as strange on the page
as it is in fact.

**Not on `place`, `pack` or `clean`.** The reason `--only` exists is that a
child's environment is *broadcast* — inherited by everything it spawns, echoed
wholesale into a log by an Xcode script phase. A file `place` wrote is not
broadcast; it sits at a path something opens deliberately. Same tool, different
physics, and putting the flag on both would be symmetry rather than reasoning.

Two concrete costs if it were added anyway. `place` and `clean` are a pair, and
independent selectors can desynchronise into a credential left materialised in a
working tree — the opposite of the flag's purpose; if this is ever wanted they
need a shared record of what was placed, not two selectors that are supposed to
agree. And `pack` runs the other way, so a filter there is a partial write,
which is the half-credential state `secrets add` exists to prevent.

`secrets check` also keeps checking everything. A scoped check is a check people
learn to trust wrongly.

## One question still open

**Is a family that is empty in this file an error, or a reported no-op?**

Two reviewers disagreed, and the disagreement is recorded rather than resolved,
because both positions are coherent and the choice is a judgement about which
mistake matters more.

*Fatal, both cases.* `--only` at a call site is an assertion that the child
consumes this. If the file has none, the assertion is false, and both routes
there are bugs worth stopping on: pointed at the wrong secrets file, or a
credential was retired and the call site never updated. There is already a way
to say "no tokens" — omit them — so a flag that means both "I need these" and "I
need nothing" reintroduces in the semantics the ambiguity the name removed.

*Split by production.* Naming an *instance* is an existence claim, so
`tokens.marks` with no `marks` is fatal — matching how a named profile absent
from the file is already fatal. Naming a *family* is a scope: `tokens` in a file
with no tokens selects nothing, is allowed, and is **reported** — matching how
profiles that merely turn up unnamed are warned and skipped. A family name is
validated against the schema and so cannot be a typo, and the reporting line the
design already requires answers the silent-nothing fear.

The strongest point on each side: the first catches a wrong-file mistake at the
call site; the second is the one that matches precedent already in this
codebase, and observes that a family which is empty cannot strand a child,
because a credential that does not exist cannot be consumed four layers down.

Whichever is chosen, the messages must differ. "Unknown to the schema" and
"known, but absent from this file" are different mistakes, and telling someone
their spelling is wrong when it is not sends them looking in the wrong place.
