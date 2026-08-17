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

**Why `keychain exec` gets the narrow default is an empirical claim, not a
definitional one.** An earlier draft said this command "exists to sign Apple
builds, so its child is an Apple build and nothing else" — the same sentence the
code has carried for a while. That is false. AuthPass's child is a release
script that runs `pod repo update`, builds, archives, uploads, and pushes over
ssh; the other consuming project's child reads a changelog and writes a
manifest. `keychain exec` is the *outer* wrapper in both, precisely because it
is the one that places no App Store key in the environment, which makes it the
natural place to hang everything else.

The defensible claim is about where the exposure is: **`keychain exec` is where
Apple builds run, and an Xcode script phase writes its whole environment into
the build log.** That can be checked, and someone extending it will extend it
safely. "Its child is an Apple build and nothing else" cannot be checked and is
wrong.

### Two rules decide the default, and they answer different threats

A single rule was proposed — withhold what is value-shaped, pass what is
path-shaped — and it is half right. Stated alone it silently undoes two
exclusions that are currently correct.

**Values are withheld, because an environment is broadcast.** It is inherited by
everything a child spawns and printed wholesale by an Xcode script phase. Tokens
are this rule's subject: theirs is the one family whose secret material is
irreducibly a value, which is why 2.0.0 could convert every other one to a path
and not that.

**Capabilities this command does not confer are withheld, because holding a
credential is itself the risk.** A child holding the Play service account path
can publish to Play whether or not anything ever prints it. A child holding an
App Store key can create and revoke signing material. Neither is a log-exposure
question, and the code already says so — the comment on
`android.play_service_account` notes that exposure *stopped* being the argument
when 2.0.0 made it a path, leaving capability as the reason it stays withheld.
This is why `--api-key` is opt-in.

Two rules is not a defeat. One rule that silently covers half a threat model is
worse than two that each say what they are for.

**They compose as a union, never as a chain.** Withhold if *either* rule
applies; do not let the first rule that matches decide. The order must not
change the answer, and there is exactly one case that proves it:

| | exposure rule | capability rule | outcome |
| --- | --- | --- | --- |
| a token | value — withhold | a capability — withhold | withheld twice, harmless |
| the Play service account | **path — passes** | a capability — withhold | **must be withheld** |

Since 2.0.0 the Play credential is path-shaped, so an implementation that
evaluates exposure first and returns on a pass hands it to the child. That is
the exact exclusion the capability rule exists for, and getting it wrong looks
like the rule working.

The tell is specific enough to test: **if `android.play_service_account` ever
appears in a child's environment because it is path-shaped, the union has become
a chain.**

That 2.0.0 removed the *exposure* reason for withholding it while the exclusion
stayed correct is the clue that there were two rules all along.

**The unit is the variable, not the family.** Families are mixed:

```
path  APPLE_DISTRIBUTION_P12_PATH     value  APPLE_DISTRIBUTION_P12_PASSWORD
path  ANDROID_KEYSTORE_PATH           value  ANDROID_KEYSTORE_PASSWORD
path  APPLE_API_PRIVATE_KEY_PATH      value  APPLE_API_KEY_ID, APPLE_API_ISSUER_ID
```

So no family can be classified whole. This is not a new idea in the codebase: it
is the generalisation of the one thing 2.3.0 already does correctly, which is to
strip `APPLE_*_P12_PASSWORD` from a child while leaving the paths beside them.
It also answers the keystore case without help — `ANDROID_KEYSTORE_PATH` passes,
`ANDROID_KEYSTORE_PASSWORD` does not, and the Gradle build that genuinely needs
the password gets it from `secrets exec`, whose default is everything. A rule
that stands only because an unrelated exclusion happens to hide its worst case
is not a rule.

**Consequence for what `--only` is.** With a per-variable default, a caller
writing `--only marks` is asking to readmit a specific *value*. That is a
sharper description of the flag's job than "select credentials", and it makes
the fail-closed story easier to state: values are out unless named.

### What `--only` governs on `keychain exec`, and what it does not

`keychain exec` is itself a consumer: it reads certificates to import them and
profiles to install them, before any child exists. `--only` does **not** reach
that. It governs the child's environment only, so `--only tokens.marks` does not
starve the command of the certificates it exists to import, and a caller does
not have to name `apple.certificates` in order to sign.

That is coherent — the child needs `APPLE_KEYCHAIN`, not the p12 paths, and the
passwords are stripped after import regardless — but it means the flag is
narrower on this command than "which credentials survive into the child"
suggests.

The help text is not enough. A consumer reviewing this said they would have
assumed `--only marks` meant "and nothing else", concluded it had starved the
import, and filed a bug. So it belongs in the **error** someone gets when they
name a selector with no certificates in it and signing then fails — which is the
moment they are already confused — rather than only in a paragraph they read
before they were.

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

### A selector that does not resolve is an error

`--only tokens.marsk` must fail, naming what exists.

Three cases, and they are not the same mistake. **Unknown to the schema** —
`tokns`, or a family that does not exist — is fatal. **A named instance absent
from the file** — `tokens.marsk` where `tokens` exists — is fatal. **A known
family that is empty in this file** is reported rather than fatal; see the
section on empty families for why, since it was the one disputed point.

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

## An empty family is reported, not fatal

Split by grammar production:

- **Unknown to the schema** — `tokns`, a family that does not exist — is fatal.
- **A named instance absent from the file** — `tokens.marsk` — is fatal. Naming
  an instance is an existence claim.
- **A known family that is empty in this file** selects nothing, is allowed, and
  is **reported**. Naming a family is a scope, not a claim about contents.

This matches a line `decideProfile` already draws: a named profile absent from
the file is fatal, while a profile that merely turns up unnamed is warned and
skipped. A tool that draws one line in two places for the same kind of question
is better than one that draws two.

This was disputed. The other position was that an empty family should also be
fatal, on the grounds that `--only` asserts the child consumes something, and
the ways to reach an empty family — wrong secrets file, or a retired credential
with a stale call site — are both bugs. It was withdrawn by the person who
argued it, and the reasoning is worth keeping because it is what makes the
decision safe rather than merely decided:

- **An empty family cannot strand a child.** The argument for fatality invoked
  "a credential absent four layers in, wrapper reports success". That failure is
  unreachable here: if the family is empty the credential is absent from the
  *file*, so no configuration of `--only` could have delivered it.
- **The retirement case is caught by the undisputed half.** Retiring
  `tokens.marks` while a call site still names it is fatal under instance-level
  naming, which nobody disputes. Fatality at family level only adds anything
  when a retirement empties an entire family.
- **The wrong-file case is real but is not this flag's job.** An unexpectedly
  empty family does suggest the wrong file — but a wrong file fails louder and
  earlier (the certificates are absent too), and `secrets list` and `secrets
  check` exist to answer "is this the file I think it is". Hanging that
  detection off a filter flag puts it where it happens to be noticed rather than
  where it belongs.

**The messages must differ, and the empty-family report must read as anomalous.**
"Unknown to the schema" and "known, but absent from this file" are different
mistakes; telling someone their spelling is wrong when it is not sends them
looking in the wrong place. And since a warning is now carrying the whole weight
of the design's answer to the silent-nothing fear, it has to be conspicuous:

```
==> family "tokens" selected, but there are no tokens in secrets/release.yaml
```

not a tally. `0 selected` at the end of a list is not a report anyone reads.
