# Changelog

## 3.3.0

**`release finish` now refuses a tag that names a different commit, and pushes
one it finds already there.** Both are behavior changes on a path every release
runs, so read this before upgrading — nothing else in this release is reachable
from the command line yet.

### A failed tag push used to be permanent

The tag was pushed only on the run that *created* it. So a run whose push failed
— an expired token, a runner without the route, a network blip — left a tag that
no later run would ever publish: every repeat found it locally, logged
`v1.0.3 already exists at abc1234 — leaving it alone`, and finished green while
the remote never got it. The release then had no tag anywhere a later reader
would look, and nothing said so.

The push now runs whether or not this invocation created the tag. Pushing a tag
the remote already holds at the same commit is a no-op; pushing one it holds at
a *different* commit is rejected, which is the collision below arriving from the
side a local check cannot see. The `— leaving it alone` half of that log line is
gone, because it was no longer true.

### An existing tag at another commit is now an error

It used to log and carry on, **including the version bump**. One version
recorded against two commits is one of them being wrong, and continuing left
whichever it was standing as the record of what shipped. It now throws, in
`--dry-run` too, and the bump does not happen.

If you have a release in that state, the fix is to decide which commit shipped
and retag deliberately. This refuses rather than choosing for you.

### Commit arguments are resolved before they are compared

`--commit HEAD` and `--commit abc1234` used to work on the first run and fail on
the second. The tag side of the comparison is `rev-parse` output — always a full
40-character SHA — while the other side was whatever you passed, so the
*legitimate repeat* was reported as a version naming two commits. That
accusation is the loudest error this command can raise and it was false.

Both sides now go through the same resolution, which also turns a commit that is
simply absent from a shallow clone into a message saying so, instead of git's
`fatal: bad object type.`

### Internal: recording what reached a store

`recordUpload` writes an annotated tag naming the commit an artifact was **built
from**, so a build number still resolves to a commit after `git gc` has taken
the branch that contained it. It is not wired into `play upload` or `appstore
upload` yet and there is no way to reach it from the CLI in this release; it is
published now so the repositories that will call it can be built against it.

Two things worth knowing before that wiring lands, because both change how a
caller has to behave:

- **The tag records an upload *attempted*, not accepted.** It is written before
  the store is contacted — tagging afterwards would make the failure mode
  "shipped but unprovable" — so a signature refusal leaves the tag standing over
  an artifact nobody received. Anything reading these tags must read them as
  attempts.
- **A collision throws `UploadCollisionException`**, distinct from an ordinary
  `ReleaseException`, so a wrapper can tell it apart. Release scripts routinely
  call the upload under `|| exitCode=$?` so that re-running a release for a
  build the store already holds is a no-op. A collision exiting through that
  same path would be downgraded to a tolerated failure and the release would
  finish green with the loudest error unreported.

## 3.2.1

**Every `appstore` subcommand crashed in 3.2.0 if the repository declared an
`appstore:` block.** Upgrade immediately; 3.2.0 should not be used.

```
Unhandled exception:
Invalid argument(s): Could not find an option named "--require-screenshot-type".
#1  _derivationProblem (package:cux_ship/runner.dart:1535:12)
#2  _AscSubcommand.run (package:cux_ship/runner.dart:190:15)
```

`upload`, `promote`, `wait`, `builds`, `versions`, `signing` and
`screenshot-types` all died before doing anything. Nothing reached Apple and
nothing was published wrongly — the command could not start. `verify` and the
whole Play side were unaffected.

`_derivationProblem` read `--require-screenshot-type` out of `ArgResults`. That
option is declared on `verify` alone; the function was also wired into the App
Store path, where `argResults` is a parser that has never heard of it.

**And 3.2.0 left no way back.** A repository that adopted the declaration could
neither upload on 3.2.0 nor fall back to 3.1.0, which refuses the config
outright:

```
--app-dir: .cux-ship.yaml has unknown keys: appstore, play
    known keys: app-dir, apple
```

3.2.0's own notes said to land the constraint bump and the config in one commit.
That is right for *migration ordering*, and it removes the *rollback* — which
those notes did not say and should have. Anyone who followed them was stuck on
both sides until this release.

### The fix, and why it is not the one-line guard

`_derivationProblem` takes the flag's value as a parameter now instead of
reading it. `verify` passes what its flag supplied; the App Store path passes an
empty set, because it has no such flag.

Guarding the read — `args.options.contains(…)` before `multiOption` — works, and
leaves the function still asking a question about a parser it does not own,
which is the same trap for the next helper shared across two commands. Declaring
the option on the App Store parser would grow the CLI surface to fix internal
wiring. A parameter makes the question unaskable.

### Worth saying plainly

**The crash was in the error-reporting path 3.2.0 added to close a silent-pass
hole.** That guard existed to make an underived screenshot requirement loud
rather than silent; instead it killed the command and named a flag the user
never passed. A check that cannot start is not a stricter check.

And the ordering is the general lesson, in the words of the project that hit
it: **loudness added at the wrong layer is quieter than what it replaced.** The
guard ran before the validation that would have produced a useful message, so
it did not merely fail to help — it hid the thing that would have.

It shipped because no test ran a subcommand against a repository that declares a
store block — the crash needs one to fire, and every fixture in this package had
none. `test/subcommand_smoke_test.dart` now starts every subcommand against both
shapes: a repository declaring `appstore:` and `play:`, and one declaring
neither. It asserts only that a command gets past argument handling and into its
own body, which is the whole class of failure this was.

Found by a consuming project, one command after adopting the config, by somebody
doing something unrelated.

### `3.2.1` means uploads tell you the truth, not that they succeed

If a project has an interpolated `PRODUCT_BUNDLE_IDENTIFIER` — per-configuration
suffixes, `design.codeux.example$(BUNDLE_ID_SUFFIX)` — the next thing it meets
is 3.1.0's refusal:

```
PRODUCT_BUNDLE_IDENTIFIER in ios/Runner.xcodeproj/project.pbxproj is
'…$(BUNDLE_ID_SUFFIX)', which Xcode expands at build time and this can only
read as text — pass --bundle-id
```

That is correct and is not a regression: `--bundle-id` is required for those
projects and always was. But 3.2.0's crash fired *before* it, so two blockers
were stacked and only the second becomes visible once this release removes the
first. Nothing further is broken; there is simply a second thing to pass.

## 3.2.0

**A repository can declare what its listings must carry, and `verify` reads it.**

```yaml
appstore:
  locales: [en-US]
  screenshots:            # optional — derived when absent
    ios: [APP_IPHONE_67, APP_IPAD_PRO_3GEN_129]
play:
  locales: [en-US]
  screenshots: [phoneScreenshots, tenInchScreenshots]
```

`--require-screenshot-type` and `--require-locale` never varied between runs;
they vary between apps, which is what `.cux-ship.yaml` is for. Three consuming
repositories had each hand-written the same wiring to say them.

### **Breaking, in a minor. Read this one.**

**A project that has a listing tree and does not declare it now fails
`verify`.** Semantically this is a major; it ships as a minor deliberately,
because the alternative is a major every few days and a version number that has
stopped carrying information. The compensation is that the break is loud, early,
and says what to do:

```
.cux-ship.yaml: appstore: is not declared, and store/appstore exists — so the
tree is checked but nothing says which locales it must carry […] Declaring
appstore has been required since 3.2.0: add appstore.locales, e.g.
locales: [en-US]
```

The failure names **the version that introduced the requirement**, because the
question a reader actually has is not *what is missing* but *why did this work
yesterday*.

**Nothing checks less than it did before.** A present tree is still validated
against everything intrinsic to it, declared or not — an upgrade that quietly
checked less would be the exact failure this release exists to remove. What the
declaration adds is the one thing that cannot be inferred: which locales the
listing must carry, so that one silently disappearing is noticed.

**Take this bump in a commit that also adds the config**, in the same way the
secrets file moves with a constraint that admits a new shape.

### `verify` gains the Play half

`--play`, `--data-safety`, and the checks behind them. Play was covered for
release-note length and nothing else.

**`data-safety.csv` is the reason this release is ordered the way it is.**
`play upload --dry-run` discards its edit rather than validating it, and skips
the declaration outright; a real run sends it as a separate POST, deliberately
after the commit, because it is not versioned with a release. That ordering is
right and cannot be changed — so a broken declaration fails *after* the release
is public, and an offline check is the only place it can be caught at all.

Structure, never content: whether the answers are *true* is a question about a
particular app, and this cannot answer it. There is also nothing to specify —
the file is Play's own export and every row states its own answer requirement.

### Screenshot types are derived from `TARGETED_DEVICE_FAMILY`

`{APP_IPHONE_67, APP_IPAD_PRO_3GEN_129}` is Apple's current requirement for a
universal app, not a fact about any app: the 6.7" class replaced the 6.5" one.
A project holding those names in its own config holds a value that ages into a
rejection after upload; one derived here is fixed for everybody by taking a new
version. `appstore.screenshots` overrides it when Apple and this table disagree.

macOS has no `TARGETED_DEVICE_FAMILY`, so that side is a constant rather than a
lookup — two mechanisms behind one word, said out loud.

`TARGETED_DEVICE_FAMILY` gets 3.1.0's refuse-on-ambiguity rule. It is the same
multi-target shape that forced `PRODUCT_BUNDLE_IDENTIFIER`'s.

### The declared requirements are enforced on `appstore upload`, not only in `verify`

A requirement that is a property of the repository and is honoured by one
command out of two reads as a standing fact and is not one. `upload` is the
command that reaches Apple.

### Listing URLs are checked for reachability, and never block

A privacy policy URL that 404s is a rejection, and the site is usually deployed
by a different command than the app. This runs on the upload path, always, and
**reports rather than fails**: a URL can be legitimately dead at exactly one
release — a policy site deployed after the app — and a gate there would fail
correctly and teach the bypass.

It is not in `cux_ship_verify` and never will be. That package has no
dependencies and makes no network calls, and `verify --help`'s "No network, no
credentials" is an **invariant**, not a description of what it currently does.

### Two checks were written, run against a live listing, and deleted

Both would have failed a listing a store is serving right now:

- *a response id belongs to one question* — Play reuses them across questions by
  design. 22 problems on an accepted declaration.
- *an enumerated set of answer requirements* — exports also use `SINGLE_CHOICE`
  and `OPTIONAL`. 88 problems.

Play's published "longest side at most twice the shortest" is absent for the
same reason. A 20:9 phone capture is 2.22:1, and the reductio needs no
counterexample: Play *mandates* a 1024x500 feature graphic, which is 2.048:1.

**A check that fails what a store accepts is worse than one that passes
vacuously**, because the first response to a red board over a live listing is to
find the flag that turns it off. No dimension or length rule should ship without
being run against a real listing and asked whether it would have failed
something already published.

## 3.1.0

**Inference refuses an ambiguous project instead of taking the first match.**
`PRODUCT_BUNDLE_IDENTIFIER` and `DEVELOPMENT_TEAM` are read from the Xcode
project as before when the project names one of them. When it names several,
the command stops and lists them rather than picking.

**The one thing to check on upgrade**, because a caret constraint takes this
without asking: a project that was inferring by luck now needs a flag. It stops
at the start of a release rather than partway through, and names the project and
the candidates — but it can stop a run that worked yesterday. Two real projects
were relying on that luck, in different ways and neither visibly:

- One puts an app extension's target first, so the first match was the appex
  rather than the app. Its uploads were correct only because the release script
  passes `--bundle-id` — remove that flag and it would have talked to Apple
  about the extension.
- One interpolates `design.codeux.howitwent$(BUNDLE_ID_SUFFIX)`, which Xcode
  expands at build time and this can only read as literal text. Apple answered
  404 for an app by that name, which sends you to look at the app record and
  the API key before the project.

`head -1` on a file that may legitimately name several things is not a rule,
it is a coin toss that has been landing the same way.

### The refusal says which failure it is

Three situations a single null cannot tell apart, so they no longer share a
message: nothing could be read, several were read, or the one that was read is
not literal text. Only the first is answered by *pass the flag*. Reporting the
others as the first is what sends someone to check their credentials — the
sentence has to name the project, or the afternoon goes elsewhere.

An absent iOS project is unchanged and still just absent. That is ordinary, not
a problem, and "none could be read from the Xcode project" was already right.

### `secrets add certificate --from-keychain` defaults `--team`

From `DEVELOPMENT_TEAM`, as `keychain exec --team` already did. It was the last
value in an Apple setup still typed by hand, out of a file already being parsed
for the bundle identifier. A team retyped once a year during a certificate
rotation is where a transposition survives — the wrong one exports somebody
else's identity and surfaces much later as a profile mismatch that never
mentions the team.

`keychain exec --team` gets the ambiguity refusal too, and there it is a
tightening rather than a convenience: `expectTeam` is optional, so an ambiguous
project used to become an *unchecked* one. Silently dropping the check that
exists to catch a certificate from another account is a worse answer than the
guess it replaced.

### `--no-metadata` on `appstore upload`

Uploads the build and leaves the store listing alone.

Omitting `--metadata` never did this: the default is inferred from
`store/appstore` whenever that directory exists, so there was no way to put a
build on TestFlight without also publishing the listing. When the App Store
version is locked by review — `WAITING_FOR_REVIEW` or `IN_REVIEW`, both
ordinary states — the listing push fails with a 409.

It failed *last*. The binary and the TestFlight notes were already up, so the
command did everything asked and then exited non-zero, which invites the one
response that is wrong: run it again.

A TestFlight build is not a version submission and needs no listing. Apple
reviews the listing together with the version, which is why `upload` is where
metadata belongs and `promote` still never publishes it — that part is
unchanged and deliberate.

`--metadata` and `--no-metadata` together are refused rather than ordered.

## 3.0.0

**`keychain exec` gives its child the keychain it made and nothing else.**
Everything further is named at the call site:

```
keychain exec --profile ios_appstore -- tool/build.sh          # APPLE_KEYCHAIN only
keychain exec --only tokens.marks -- tool/build.sh             # and that token
keychain exec --only ssh_keys.github_deploy -- ci-release.sh   # and the deploy key
```

`secrets exec` is unchanged by default — it places everything, because a
general-purpose wrapper that hands over nothing is inert — and takes the same
`--only` when a caller wants to narrow it.

The selector is `family` or `family.instance`, comma-separated or repeated:
`tokens`, `tokens.marks`, `apple.certificates.distribution`.

### Why the default is nothing rather than something better

This replaces a hardcoded three-family withhold list that no caller could see,
extend, or ask for something different from. The obvious replacement was a
better default, and three were tried: "the minimum that signs", then "withhold
values and pass paths", then two rules applied per variable. Each needed more
structure than the last, ending in one rule, one guarantee and a seven-row
table.

The reason is structural rather than a failure to pick well. **A default has to
satisfy every consumer, so it is the union of their needs, and a union is wrong
for each of them individually.** A union has no explanation, only a membership
list — which is why it could not be written down in a way anyone could hold in
their head. A call-site selector is one consumer's own set, and it has a reason
that fits in the flag.

It also could not be derived. `keychain exec` wraps a *build script*, so what
that script consumes happens below this command's arguments — in one real case
four layers down inside a function, with the variable's name in a `printf`
format string. A rule of "do not withhold a credential whose variable appears in
the command line" was proposed and would have withheld the one token that must
never be withheld: it failed on the example it was designed around.

### `SOPS_AGE_KEY` is stripped from `keychain exec`'s child

Unconditionally, with no way to readmit it. It is the master key to the whole
file, value-shaped, and not a credential *in* the file — so no selector can name
it and no default covered it, while an Xcode script phase writes the whole
environment into a build log.

Nothing outside cux_ship reads it. The one composition that did — a nested
`secrets exec` inside a `keychain exec` child — is replaced by running the two
as siblings, which is a change in the consuming project rather than here.

This is also what makes the archive guarantee true rather than nearly true. A
child that could decrypt the file could mint the App Store key the archive is
meant not to hold.

### Check the advice your own tooling prints

This release changes no message cux_ship prints. It can invalidate messages
**you** print. Grep your own scripts for a remedy naming `keychain exec` without
`--only`:

```
no temporary keychain — run this through `cux_ship keychain exec`
```

Correct for years, and incomplete at 3.0.0. Someone who follows it gets a
keychain, clears that check, and dies further down on the credential the empty
default no longer places — one error handing them to the next, each true on its
own. Name the whole invocation instead, `--only` included.

The asymmetry is what hides this. Advice naming `secrets exec` survives
unchanged, because that command kept its everything default; only `keychain
exec` moved. The two read as the same kind of sentence, so a sweep for one does
not suggest a sweep for the other.

Worth doing even though your build passes. The loud version of this failure is
the lucky one — a later check that refuses outright. Where the credential is
read by something that merely carries on without it, an optional feature quietly
staying off or a signing step choosing a different identity, nothing fails and
the sentence that sent them there still reads as correct.

### Behaviour worth knowing

- **A selector that does not resolve is fatal, and the three mistakes get three
  messages.** Unknown to the schema, a named instance absent from the file, and
  a section named instead of a family are different errors; telling someone
  their spelling is wrong when it is not sends them looking in the wrong place.
- **A known family that is empty in this file is reported, not fatal.** Naming a
  family is a scope; naming an instance is an existence claim. That is the line
  `decideProfile` already draws.
- **Resolution is against what the process holds, not the file.** Under
  `secrets exec --only x -- keychain exec --only y --`, the inner command asking
  for something the outer stripped fails there, naming it, rather than four
  layers down inside a build. A partial match is fatal too.
- **Selection removes, it does not merely decline to place.** An outer wrapper
  has already put everything in the environment before an inner one runs.
- **`--keystore` and `--api-key` are refused alongside `--only`**, which already
  names the instance they exist to choose. `--only apple.profiles.*` is refused
  pointing at `--profile`, and `placed.*` pointing at `secrets place`.
- **`secrets exec --only` warns when it omits a keystore the file holds.** A
  missing Android keystore is the one absence that is silent: Gradle falls
  through to the debug key and produces an artifact only the store rejects.

### Fixed on the way

`secrets exec` never passed `includeParentEnvironment: false` to its child.
`Process.start` merges the map into the parent's environment, so anything
removed from the map came back. It had never removed anything, so it had never
needed the flag — and the moment `--only` gave it something to remove, the
removals silently did nothing. `keychain exec` has carried the flag, and a
comment warning about exactly this, since 1.9.1.

## 2.3.2

- **An App Store Connect error that blocks a submission now says where to fix
  it.** "Unable to Add for Review — an Admin must provide information about the
  app's privacy practices in the App Privacy section" stops a release and names
  no remedy, and the natural reading of an API error is that the caller sent
  something wrong. The printed failure now adds the console path, that an
  **Admin** must do it (a Developer-role account cannot, which the error does
  not say), and that it is per *app* rather than per version.

  It also says plainly that cux_ship cannot check this in advance and will not
  pretend to. **App Privacy is absent from the App Store Connect API** — not
  readable, not writable — so nothing here can tell you the section is
  incomplete before Apple does. That was checked rather than assumed: Apple's
  API index enumerates the areas it automates and privacy is not among them,
  the `App` resource carries `appEncryptionDeclarations` and
  `accessibilityDeclarations` and nothing for data usage, and fastlane's
  privacy action authenticates with a web session because the endpoints are not
  in the official API.

  Only this one error is annotated. An error that already names its field is
  actionable as printed, and a paragraph on every failure trains people to stop
  reading the paragraph.

## 2.3.1

- **`Platform` is extracted as `xml1` rather than `json`.** On a `macos-15`
  runner `plutil -extract Platform json` exits 1 with empty stderr — not an
  absent key, not a malformed profile, a subprocess that fails and says
  nothing. `keychain exec --profile` therefore refused every provisioning
  profile on that runner, which is every GitHub job using `macos-latest` at the
  time of writing.

  Measured on a real runner rather than predicted, and found in one line
  because 2.3.0 had already stopped reporting a failing `plutil` as an absent
  key. The old message asserted the one thing that was false; the new one named
  the command, the exit code, and the absence of any explanation to pass on.

  This is the second failure of `-extract … json` on that OS — the first was
  `DeveloperCertificates`, an array of `<data>` which JSON cannot represent and
  plutil refuses outright. `Platform` is an array of *strings*, which JSON
  represents perfectly well, so the two have no cause in common except the
  format. `xml1` works on both macOS versions. `UUID`, `Name` and
  `ExpirationDate` stay on `raw`, which has never failed and is unambiguous for
  a scalar.

## 2.3.0

- **`cux_ship secrets add`** puts a credential *into* the file. Until now
  `secrets` could read one five ways and write one — `pack`, and only for a
  `placed` file `place` had already written — so adding a certificate, a
  profile or a token meant a hand-rolled `ruby | sops set` pipeline in every
  project. Those encode the schema path by hand, write one field at a time so
  an interrupted run leaves a half-credential, and hand `sops set` a bare
  string when it wants JSON — which is accepted, stored wrong, and
  authenticates as garbage.

  ```
  secrets add certificate distribution dist.p12 --password-file pw
  secrets add profile ios_appstore app.mobileprovision
  secrets add api-key upload ~/Downloads/AuthKey_ZHGL57YJVC.p8
  secrets add token artifact --env ARTIFACT_TOKEN --value-file tok
  ```

  A name and an artifact, positionally. **No `--p12` / `--p8` / `--file`: the
  artifact is identified by its contents.** That names the real mistake rather
  than the wrong flag, and catches a correctly named file with the wrong thing
  inside — which happens, because people rename downloads. An api key's `id`
  and `kind` are read back out of Apple's `AuthKey_`/`ApiKey_` naming, so the
  two fields most often got wrong are two nobody types.

  Every field of a credential lands in **one** write, making the partial state
  `secrets exec` refuses unrepresentable rather than merely reported. Adding
  over an existing credential is refused; `--replace` is the rotation verb.
  Passwords and values are never arguments, because an argument is visible to
  `ps`; a certificate's password is checked against the `.p12` before anything
  is written.

- **`cux_ship secrets check`** decrypts and reports whether each credential
  actually works, as **verified**, **failed** or **opaque** — the last being one
  this tool can never authenticate, such as a token. Only `failed` colours the
  exit code; an opaque credential is not an error and must not read as one, or
  the check becomes something people learn to skip past.

  Its unique value is the **cross-checks**, which no single-artifact command can
  perform: above all whether a stored profile still embeds a certificate the
  file actually holds. That is not derivable from either artifact alone — a
  Developer ID profile can outlive the certificate inside it by a decade, so its
  expiry says nothing about whether it still holds a usable certificate, and
  replacing a certificate silently invalidates every profile issued against it.

- **`cux_ship secrets remove`** retires one. Doing it by hand was the same
  failure class as adding by hand, at the worst possible moment — having just
  decided something is compromised.

- **Replacing a certificate names the profiles it invalidates.** Every profile
  issued against a certificate stops working the moment that certificate is
  replaced, and no artifact says so — the profile keeps its own expiry date.
  Established *before* the write, while the outgoing certificate is still there
  to fingerprint; afterwards the evidence is gone. When it cannot be
  established it says so rather than reporting that none were affected, which
  is a different claim and the only reassuring one.

- **`secrets add certificate --from-keychain`** builds the `.p12` out of a
  macOS keychain, with a generated password, for onboarding a machine that has
  an identity but no file. Ported from a shell version in a sibling project,
  for three traps it already encodes — each of which produces a file that looks
  correct: pairing the certificate with its key on `localKeyID` rather than
  `friendlyName` (macOS names the two bags differently, so a friendlyName
  filter yields a `.p12` that imports cleanly and cannot sign); matching the
  certificate *kind* as well as the team, since Apple Development carries the
  same `OU=`; and checking expiry on every candidate, because a keychain never
  sheds the expired ones.

- **Renames.** `secrets keys` is now **`secrets list`**: the file holds
  `api_keys`, `ssh_keys` and `keystores`, so "keys" read as a category rather
  than as the credential names it actually prints. `appstore await` is now
  **`appstore wait`**, taking the build number positionally — it was required
  anyway, and `await`/`builds`/`build-number` shared tokens while meaning
  unrelated things. `appstore upload` takes **`--artifact`**, with `--ipa` and
  `--pkg` as accepted spellings: `--platform macos` is first-class, so a macOS
  release passing its `.pkg` to a flag called `--ipa` read as though macOS had
  been bolted onto an iOS-shaped command, and `--pkg` — what anyone tries first
  — was rejected outright.

- **`deps update` is hidden from `--help`.** It re-pins cux_ship's own sources
  and refuses to run outside a cux_ship checkout, so to every consuming project
  it was a documented way to get an error. Still runs when typed.

- **A failing `plutil` no longer reads as an absent key.** The per-key loop
  recorded a value only on exit 0, so a tool that could not do what was asked,
  a key that is genuinely missing, and a plist that would not parse all arrived
  at the same message — and the one it printed named the least likely cause.
  That cost a consuming project an afternoon bisecting macOS versions to learn
  `Platform` had been present all along. The same bug bit again while building
  the cross-check, where `plutil -extract … json` refuses a `<data>` array
  outright ("Invalid object in plist for JSON format") and the empty result
  silently checked nothing.

## 2.2.0

- **`cux_ship appstore await`** exposes the wait that `appstore upload` already
  did internally. Uploading and waiting can now run on different machines,
  which matters because the wait is a poll against a REST endpoint that needs
  no Xcode, no keychain and no signing material — only the API key — while the
  runner that built the artifact is billed at 10× for being macOS. It also
  finishes `--skip-waiting`, which until now said a caller would wait later and
  left nothing to wait with.

  `--build-number` is required rather than defaulting to the newest build: the
  point of waiting elsewhere is to wait for a *specific* build, and "newest"
  would succeed on somebody else's upload. The three outcomes keep the meanings
  `upload` gave them — success, the 422 for a build Apple refused, and the
  timeout that names where the reason actually is.

- **Every certificate's remaining life is reported at import**, by
  `keychain exec`, in the words the developer-account audit already uses.
  A profile carries its own expiry and a certificate carries `notAfter`; they
  are independent, and nothing read the second. A profile valid for a year that
  embeds a certificate dying next week passed every check and failed inside
  codesign — and a project on automatic signing had no profile to check at all.
  Reported for every certificate imported, not only the one that signs, because
  an installer certificate expiring is a `productbuild` failure at the end of a
  Mac App Store run. A warning, never a refusal.

## 2.1.0

- **The App Store review contact comes from the environment**, as
  `APPLE_REVIEW_CONTACT_FIRST_NAME`, `_LAST_NAME`, `_EMAIL` and `_PHONE`, and is
  sent with every review-notes write.

  **Not from the metadata tree, and the asymmetry is deliberate.** Every other
  listing field is a file beside `info/`; a name, an e-mail address and a mobile
  number are one person's, they are the same person's across every project using
  this package, and at least one of those projects is a public repository. A
  phone number in git history outlives whatever the repository's visibility was
  on the day it was committed, and unlike a leaked key it cannot be rotated. The
  environment keeps the choice with each project — a sops file, a CI secret, a
  shell — which is where every other credential here already lives.

  All four or none: a partial set is refused before anything is written, since
  Apple wants them together. The phone is checked against the format Apple's own
  rejection describes — `+` then the country code — because that refusal
  otherwise arrives mid-push with several fields already landed.

  Sent on create *and* update, which is the part that is not guessable: creating
  a review detail with notes alone succeeds, and updating one is then refused
  without the whole contact. So the second push of an unchanged file failed
  where the first had worked.

- **`appstore upload --metadata` now publishes review notes**, from
  `review-notes.md` beside `info/` and `listings/`, into
  `appStoreReviewDetails.notes` on the version.

  **This is the piece of a listing whose absence costs a review cycle rather
  than a rejection.** An app with no content of its own — anything that needs
  the user's own files before it shows anything — opens to an empty screen, and
  a reviewer with no sample data concludes it does nothing. That comes back days
  later as "we were unable to evaluate your app", with nothing to fix, and it is
  invisible beforehand because every other part of the listing uploaded fine.

  The notes are created where the version has none and patched where it has
  some — with the contact above sent alongside either way.

  Parsing, the marker that keeps internal checklists out of it, and the
  4000-character check are `cux_ship_verify` 1.8.0 — so `cux_ship verify` fails
  an over-long note with no network at all.

## 2.0.0

**The Play service account is passed as a path, not as JSON.** `secrets exec`
now writes the account to a file and exports
`GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH`. `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` is
**gone** — not deprecated, not exported alongside.

### Why

A Google private key reached four public CI logs. An xcode script build phase
writes its whole environment into the build log, and a public repository's
action logs are public, so a variable holding a key printed the key. It was the
only credential this package passed by value; every other one was already a
path, and no other one leaked. That is not a coincidence, and it is the rule
this release makes universal:

> A secret passed as a value can escape through anything that echoes its
> environment. A secret passed as a path cannot.

1.9.0 and 1.9.1 mitigated it by letting a caller withhold the credential from
commands that cannot need it. That was worth having and it is still here, but it
was never the fix: withholding is not compositional. Each layer can speak for its
own child and no further, so a `secrets exec` nested inside a `keychain exec`
reintroduced the value for its own subtree — and "build under `keychain exec`,
upload under `secrets exec`" is the natural shape, so the mitigation failed
exactly where the pattern was most idiomatic. A path cannot be reintroduced in a
form that matters, because what comes back is a filename in a temp directory
that has already been removed.

### Migrating

One line per consumer. Read the file instead of the variable:

```diff
- echo "$GOOGLE_PLAY_SERVICE_ACCOUNT_JSON" > /tmp/sa.json
- supply --json_key /tmp/sa.json
+ supply --json_key "$GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH"
```

**There is deliberately no window in which both are exported.** A window is the
only variant in which something can quietly keep using the by-value path: the
key stays in every consumer's environment for its whole duration while the
release notes claim it was removed, which converts a known problem into a
believed-solved one. It is less safe than either alternative, not a middle
course between them.

Not migrating is loud rather than silent. An unmigrated consumer finds the
variable unset and dies on its first line naming the cause — which is the
criterion this package already applies elsewhere, and the reason the new name is
`…_PATH` rather than the old name with new meaning. A consumer reading a path
from a variable still called `…_JSON` would post a filename to Google and fail
at the API, describing neither the file nor the script.

## 1.9.1

**Withholding did not survive being nested, which is the composition 1.9.0's own
notes recommend.** `cux_ship secrets exec -- cux_ship keychain exec -- build`
gave the build every credential the file holds, including the Play service
account private key by value — the exposure `keychain exec` was added to close,
reintroduced by the documented way of using it. Upgrade if you nest them. A
project with `keychain exec` outermost was never affected.

Two causes, and the second is the instructive one:

- Declining to *add* a variable does nothing when it is already there. The
  environment begins as a copy of this process's own, so under nesting the outer
  command has already placed every credential. Withheld families are now
  **removed**, however they arrived.
- Removing them from the map did not remove them from the child.
  `Process.start` merges the map into the parent's environment unless
  `includeParentEnvironment` is false, so every deletion was restored from this
  process's own environment — exactly the case that matters, since under nesting
  the parent is what holds the credential.

The second was invisible from inside: the `removed from the environment` line
printed the correct full list throughout, because it reports what this process
did to a map rather than what the child received. Only reading the child's own
environment showed otherwise.

### A limitation this does not fix

**Withholding does not propagate downward through a second `secrets exec`.** The
natural shape —

```
cux_ship keychain exec -- sh -c 'build && cux_ship secrets exec --api-key k -- upload'
```

— builds without a Play credential and then, for the duration of the upload
child, has one again: the inner call loads the file fresh and withholds nothing.
That is correct for an uploader that needs it, and it means the by-value private
key is present at exactly the moment most likely to be wrapped in CI logging.

This is not fixable by adding more withholding, and the attempt would be worse
than the disease — a `secrets exec` that withheld the Play account by default
would break every Android upload that does not know to ask, which is all of
them. **The fix is to stop passing it by value at all**, exporting a path like
every other credential here, and that changes the contract and belongs to the
next major version. Until then, an Apple build should not be wrapped around a
Play upload in a job whose log is public.

- The reserved-name collision guard is derived from the withholding table rather
  than listed beside it. They were the same nine names written twice, and drift
  is silent in both directions: a name missing from the guard lets a project
  token overwrite a real credential, and one missing from the table leaves a
  secret in a child's environment the caller believes it withheld.

## 1.9.0

**Purely additive.** Nothing in the 1.8.0 secrets contract moves, and a project
that does not sign Apple builds sees no difference.

- **`cux_ship keychain exec -- <command>`** runs a command with the project's
  Apple signing identity in a keychain that is created for it and destroyed
  however the run ends. macOS only, and it refuses rather than continuing
  anywhere else — a build that carries on without the keychain signs with
  whatever the machine happens to hold, and exits zero.

  **The login keychain is never read.** That is the point rather than a side
  effect: a signing identity that comes from installed machine state makes the
  same commit sign differently on two laptops, with nothing saying so.

  It consumes the 1.8.0 schema rather than extending it — `apple.certificates.*`
  and `apple.profiles.*` as `secrets exec` already materializes them. Reads them
  from the environment when they are already there, so `secrets exec -- keychain
  exec -- …` composes, and otherwise decrypts the file itself. Which of the two
  happened is printed, not inferred.

  The wrapped command gets `APPLE_KEYCHAIN`, and is expected to pass
  `OTHER_CODE_SIGN_FLAGS="--keychain $APPLE_KEYCHAIN"` to xcodebuild. Not
  optional: the login keychain cannot be removed from the search list — that
  would drop Apple's intermediates and leave the leaf chaining to nothing — so
  pinning is the only thing that makes *signed with the certificate we imported*
  true rather than likely. A stale identity of the same name in the login
  keychain is not hypothetical; there was one on the author's machine, three
  months old, while this was being written.

  It consolidates two implementations that had each found a different subset of
  this platform's sharp edges, and adds four things neither had:

  - **Garbage collection of keychains left by a killed run.** A trap covers a
    failed build, Ctrl-C and SIGTERM. It covers neither SIGKILL nor the power
    going out, and what survives those is a distribution private key in a
    keychain that stays unlocked for the rest of its timeout. The pid in the
    filename is what makes staleness checkable, and nothing was checking it.
  - **A refusal when a named provisioning profile has expired**, at import
    rather than inside codesign, which reports it without using the word. Only
    when named with `--profile`: the secrets file holds every profile a project
    has, so failing on any expired one would mean an unused Developer ID profile
    lapsing breaks every App Store release, naming a profile that build never
    touches.
  - **Quote-aware parsing of the keychain search list.** Both sources strip
    quotes with `tr` or `sed`, which corrupts the list for anyone whose home
    directory contains a space — the output is quote-delimited precisely to
    permit that.
  - **A diagnosis rather than an assertion** when there is no usable identity.
    `find-identity -v` alone cannot separate "the .p12 had no private key" from
    "the key is here and the certificate does not chain", and those need
    opposite fixes.

- **`loadSecrets` takes `withhold`**, naming credential families the caller
  declares it does not consume. Additive: the default withholds nothing, so
  `secrets exec` is unchanged.

  It exists because a caller that knows its child's platform knows more than
  this file can. `keychain exec` withholds all three it can, each for its own
  reason, and says so rather than going quiet:

  - **`android.keystores`** — an Apple signing command's child cannot sign an
    Android artifact. Refusing to start because the file held two keystores
    locked the first consumer out of the command entirely.
  - **`android.play_service_account`** — **the one credential this tool passes
    by value rather than as a path**, and therefore the one that can escape
    through anything that echoes its environment. An Xcode script build phase
    writes its whole environment into the build log; this variable reached a
    *public* CI log that way, in full, in a project that ships from one.

    Every other credential is a filename in a temp directory that no longer
    exists by the time anyone reads the log. **Withholding it here is a
    mitigation, not the fix** — the fix is to write it to a file and export a
    path like everything else, which changes the contract and so belongs to the
    next major version. A consumer still running an Apple build under plain
    `secrets exec` should unset the variable before invoking xcodebuild.
  - **`apple.api_keys`** — signing needs no App Store key. Nothing is placed
    unless `--api-key` names one: not the singular variables and not
    `API_PRIVATE_KEYS_DIR`, so the `.p8` is never written. A build step can
    deliberately hold no App Store credential — which is what lets CI sign
    without holding anything able to create or revoke signing material — and
    requiring a key to obtain a keychain would give that property away.

    The asymmetry with the keystore above is the argument, and it is worth
    keeping: a keystore that fails to arrive is *silent*, because Gradle falls
    through to the debug config and Play rejects the artifact after a full
    upload. An App Store key that fails to arrive is *loud*, because its
    consumer dies on the first line naming the cause.

  An unrecognized family name is refused rather than ignored, since one
  misspelled withholds nothing while reporting success — and for the Play
  account that means a private key in an environment the caller believes it
  excluded.

- **`ProjectContext.developmentTeam`** reads `DEVELOPMENT_TEAM` from whichever
  Xcode project has one, ignoring the empty assignment Xcode writes for a target
  without a team. It is what lets the identity check ask whether the certificate
  belongs to the account this project builds for — a certificate from another
  account imports perfectly and fails much later as a profile mismatch that
  never mentions certificates.

## 1.8.0

**A minor version that changes the secrets file's shape.** The number is
deliberate rather than an oversight: three projects use this, all owned by one
person and all checked out side by side, and none of them had a reason to
depend on 1.x meaning anything yet. A 2.0.0 two days after 1.0.0 would have
claimed a stability that never existed. Read this section as the breaking one it
is — the migration is at the end and takes about ten minutes per project.

- **The file's shape is now a schema, not a naming convention.** Credentials
  live at a position in a declared tree rather than being recognized by their
  name, and one walker reads that tree. `secrets keys` and `secrets exec` call
  it and differ only in whether they keep the values, so "is this recognized"
  has exactly one answer.

  This replaced six defects with one cause — three consumers each recovering
  structure from a string, slightly differently. Among them: a complete Android
  keystore that validated, reported nothing amiss, and **set no environment
  variables at all**; and `secrets keys` reporting a file as refused that
  `secrets exec` accepted, with the test meant to pin them comparing one set to
  itself and therefore unable to fail for any input.

- **Any credential can appear more than once, under a name.** An app that ships
  to the App Store, notarizes a direct download and signs a `.pkg` has three
  Apple certificates; one that keeps a scoped upload key alongside an Admin key
  for reading the portal has two API keys of different kinds. Previously the
  vocabulary could express one of each.

  Instance names never become variable names — uppercasing is not injective, so
  `dist` and `dist_p12` would mint the same variable. Selection fills the fixed
  names instead: exactly one instance is the default, two or more must be named
  with `--keystore` or `--api-key`, and a name that is not in the file is an
  error listing what is, rather than a fall back that would run an Admin-gated
  read with a scoped key.

- **Certificate kinds are a closed set** — `distribution`, `developer_id`,
  `mac_installer` — so `developr_id` is refused. Keystore, profile, token and
  ssh key names are the project's own, which is the one level no schema can
  police.

- **`api_private_key_filename` is replaced by `kind: team | individual`**, and
  the filename is derived from it and the id. The filename is the only signal of
  which claims Apple is sent; storing it as well meant a third copy that could
  disagree with the other two, which is why 1.7.2 had to cross-check them.

- **`tokens:` and `ssh_keys:`** hold what this tool will never understand — an
  artifact host, a deploy key. Each declares the variable it exports, validated
  as `[A-Z][A-Z0-9_]*` and refused if it collides with a name materialization
  sets, so a token cannot quietly redirect `ANDROID_KEYSTORE_PATH`.

- **`placed:` holds files the build reads from the working tree**, with
  `secrets place`, `secrets clean` and `secrets pack`. Some credentials are
  source — a compiler and an analyzer read them from fixed paths — so they
  cannot live in a temp directory and cannot vanish when a command exits.

  Their guarantee is a different one and weaker, and it is stated rather than
  implied: not *plaintext never outlives the run* but **plaintext never enters
  history**. A target is refused if it is not ignored, if git already tracks it
  (`.gitignore` does not apply to tracked files, so one `git add -f` makes a
  path publishable forever), if it crosses into a submodule, if it leaves the
  repository once symlinks are resolved, or if it is a symlink or a directory.
  All three verbs compare content: `place` refuses to overwrite an edited file,
  `clean` removes only what still matches, and `pack` re-encrypts an edit back.

- **`apple.profiles` is gone from `.cux-ship.yaml`.** The secrets file names the
  profiles; a second declaration of one fact is a second thing that can drift.
  `apple.signing: manual | automatic` stays, because it is a repository-level
  choice and not derivable from which blobs happen to be present — and it
  decides more than it sounds like: `-allowProvisioningUpdates` is a portal
  write and an individual key cannot read the portal at all, so automatic
  signing requires a team key that reaches every app in the team.

- **`path`, `env` and `kind` are stored in cleartext**, so `secrets keys` and
  the placement pre-flight work with no identity. That is a real disclosure — a
  path tells a reader where a project keeps things — and it buys a pre-flight
  that needs no key. Enforced both ways: the walker refuses an encrypted value
  in those fields and names the `unencrypted_regex` to add, and a schema whose
  secret-bearing field took one of those names fails the test suite.

### Migrating a project

Environment variables are unchanged, so **nothing that consumes credentials
needs editing** — `build.sh`, `upload.sh` and Gradle keep reading the same
names.

**The tool and the file have to move together, and no order avoids a window
where they disagree.** Both directions fail loudly, and the message says which
way round you are: an older version reading a new file complains that something
*"nests deeper than a credential goes"*, while this version reading an old file
reports unrecognized keys. Neither can mistake the other's file for a valid one,
so the window is an inconvenience rather than a hazard — but do these in one
sitting.

1. **Raise the constraint and upgrade.** A minor bump does not compel this the
   way a major one would: `^1.7.1` already permits 1.8.0, so a resolved
   `pubspec.lock` stays where it is and `dart pub get` alone will not move you
   onto the version that can read the new shape.

   ```sh
   dart pub upgrade cux_ship     # or raise the constraint to ^1.8.0
   ```

2. Add to `.sops.yaml`, under the rule that matches your secrets file:

   ```yaml
   unencrypted_regex: '^(path|env|kind)$'
   ```

   Inert until the file holds a `placed:`, `tokens:`, `ssh_keys:` or
   `apple.api_keys` entry, so a project with only a keystore and a service
   account needs nothing from it yet. Add it anyway: otherwise its absence
   surfaces months later, from a file that had been working, the first time
   somebody adds one of those.

3. Restructure the file. Needs the age identity, because sops binds each value
   to its key path — a textual rename fails authentication. Plaintext never
   touches disk:

   ```sh
   sops -d secrets/release.yaml \
     | <your restructuring> \
     | sops -e --filename-override secrets/release.yaml /dev/stdin \
     > secrets/release.yaml.new && mv secrets/release.yaml.new secrets/release.yaml
   ```

   | 1.7.x | 1.8.0 |
   | --- | --- |
   | `keystore_p12_base64`, `keystore_password`, `key_alias` | `android.keystores.<name>.{base64, password, key_alias}` |
   | `play_service_account_json_base64` | `android.play_service_account.json_base64` |
   | `api_key_id`, `api_private_key_base64`, `api_issuer_id` | `apple.api_keys.<name>.{id, private_key_base64, issuer_id}` |
   | `api_private_key_filename` | `apple.api_keys.<name>.kind: team \| individual` |
   | `distribution_p12_base64`, `distribution_p12_password` | `apple.certificates.distribution.{p12_base64, password}` |

4. Run `cux_ship secrets keys`. It needs no identity, reports every credential
   by path, and names anything half configured — so it will tell you whether the
   result is right before you try to build with it.

## 1.7.2

- **An individual App Store Connect key was classified as a team key.**
  `secrets exec` materialized every key as `AuthKey_<id>.p8`, and both `altool`
  and this tool's JWT builder read that prefix to decide which claims to send —
  Apple names an individual key `ApiKey_<id>.p8` and a team key `AuthKey_<id>.p8`.
  So an individual key routed through `secrets exec` was sent `iss` instead of
  `sub: user` and got a bare 401, after a full build.

  The issuer id cannot stand in for the prefix: `altool` documents
  `--api-issuer` as required alongside `--api-key`, so an individual key
  legitimately carries one too. The filename is the only signal, which is why
  inventing it destroyed the distinction.

  New optional `api_private_key_filename` carries the name Apple gave the key.
  **Absent, the behavior is exactly as before** — `AuthKey_<id>.p8` — so a
  project with a team key needs no change. A project with an individual key
  must now set it. The value is checked against `(ApiKey|AuthKey)_<id>.p8` and
  against `api_key_id`, because it becomes a filename in a directory `altool`
  searches, and a mismatched id produces a file `altool` looks straight past.

  Predates the Dart port — `with-secrets.sh` renamed identically. Found by the
  AuthPass maintainers while migrating onto `secrets exec`.

- `cux_ship_verify` is **not** released alongside this one. It has no changes,
  and the dependency on it now names the oldest version that works rather than
  the newest — bumping in lockstep made the repository unresolvable as a git
  dependency for the whole window between a commit and its publish.

## 1.7.1

From a security audit. No high-severity defects were found; these are the three
worth acting on.

- **A malformed decrypted secrets file could print its own contents.**
  `package:yaml` renders a parse error with the offending source line and a
  caret under it, and the whole exception was being interpolated into a message
  that goes to stderr — so a decrypted private key could land in a terminal or a
  CI log. It needs a hand-mangled file that still decrypts, which is why it is
  not higher, but it is the difference between an error and a disclosure. Both
  YAML error paths now print the bare reason and no source.
- **`deps update` now validates what it writes.** The version and hash come from
  GitHub over the network and were interpolated into generated Dart source
  inside single quotes, so a value carrying a quote could inject code that runs
  on the next analyze. Maintainer-only and behind a reviewed diff; two regexes
  are cheaper than relying on the review.
- **Pagination cannot carry the bearer token off-origin.** `getAll` followed
  `links.next` to whatever host it named, with the Authorization header
  attached. Reaching it would require Apple's own TLS response to be
  attacker-controlled — but "the token only goes to Apple" should be a property
  of this code rather than of Apple's response.

## 1.7.0

- **`cux_ship secrets keys`** — lists the credential names in a secrets file
  without decrypting it, says which heading each sits under, marks any name
  `secrets exec` would refuse, and ignores the `sops:` metadata block. Worth
  running before adopting a new version, since an unrecognized key stops
  `secrets exec` outright.
- **Fixes a wrong command in the bundled skill**, which is why this exists. It
  recommended `grep -oE '^[a-z_]+:|^[[:space:]]+[a-z_]+:'` for the same job, and
  that character class omits digits — so against a real file with nine
  credentials it reported four and hid five, including the entire Android
  keystore, the Play service account and the App Store private key. Every name
  it hid was one carrying key material, and the output read as a clean bill of
  health.

  The command replaces the advice rather than correcting it: it shares the
  key-walking with the parser that enforces the rules, so the two cannot drift.
  Reported by a consumer migrating from 1.5.1.

## 1.6.0

First release on pub.dev. Versions before this one were consumed as git refs;
they are in the git history and in this repository's tags.

- **Two packages instead of five.** The App Store and Play clients moved into
  `lib/src/appstore/` and `lib/src/play/` here, and the changelog parser and App
  Store metadata model moved into `cux_ship_verify`, which now has no
  dependencies at all. The split is about what a consumer's lockfile gets: a
  release machine wants googleapis and an image codec, a test suite does not.
- `lib/verify.dart` still re-exports `cux_ship_verify`, so nothing breaks — but
  a test suite should now depend on `cux_ship_verify` directly rather than
  reaching the checks through this package.
- Resolved as a pub workspace, so the repository has one lockfile and each
  package still declares ordinary hosted constraints.

## 1.5.1

- Read the headings a real secrets file groups its credentials under. `secrets
  exec` walked only top-level keys, so a file grouping values under `android:`
  and `apple:` — which is how they are actually written — was refused with none
  of its credentials found.

## 1.5.0

**Broken; use 1.5.1.** Its secrets parser refuses any grouped secrets file.

- `--app-dir` and `.cux-ship.yaml`, so a repository whose Flutter app is a
  subdirectory can use `release finish` at all. The repository owns
  `CHANGELOG.md` and `store/`; the app directory owns `pubspec.yaml`,
  `android/` and `ios/`.
- `cux_ship secrets exec` — decrypt a sops file, run a command with the
  credentials in its environment, remove them however the run ends.
- `cux_ship deps install` — fetch sops and age by pinned hash into `.bin/`.
- `api_issuer_id` is optional. An individual App Store Connect key has none,
  and requiring one ruled out the credential that scopes CI to a single app.
