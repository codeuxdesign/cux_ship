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
next person adding a credential does not know to add it to the flag either. An
allowlist inverts that: a newly added credential is withheld until someone says
otherwise, and the failure is a build that says `X is not set` rather than a
value riding quietly into a log.

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

So: every name in the selector must resolve against the parsed file, and an
unknown family or instance is fatal with the valid set printed.

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

## Open questions

1. Should `--only` accept a family that the file does not contain? Selecting
   `tokens` in a project with no tokens is arguably fine (an empty family is not
   a typo) and arguably the same silent-nothing failure as a misspelling.
2. Is there a case for `--all` on `keychain exec` — a mid-migration escape
   hatch — or does that just preserve the permissive default under a new name?
3. `secrets place`, `pack` and `clean` also touch credentials. Do they want the
   same selector, or is `--only` specific to the two commands that build a child
   environment?
