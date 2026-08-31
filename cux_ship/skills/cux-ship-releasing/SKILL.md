---
name: cux-ship-releasing
description: Set up or operate releases to the App Store and Google Play with cux_ship. Use when wiring a project up to ship for the first time, adding store metadata or a signing key, uploading or promoting a build, releasing to TestFlight beta groups, handling sops-encrypted release credentials, or debugging a store rejection. Also use when a project has a tool/cux_ship directory, a .cux-ship.yaml, a store/ tree, or secrets/release.yaml.
---

# Shipping with cux_ship

**The reference is the package READMEs** —
[cux_ship](https://pub.dev/packages/cux_ship) for the command,
[cux_ship_verify](https://pub.dev/packages/cux_ship_verify) for the checks.
Read them for flags, inferred values and the Apple/Play behavior each command
works around. Do not restate them here or anywhere else.

This file is the part a reference cannot give: **what order to do things in, and
which steps cannot be undone.** Everything below was paid for once already.

## Read this before the first upload

**Identifiers lock at first upload.** `applicationId` and
`PRODUCT_BUNDLE_IDENTIFIER` are permanent once a build reaches either store. A
rename afterwards is a new listing with zero installs and no review history. If
the product name is not settled, **nothing may be uploaded** — not to an
internal track, not to TestFlight. Confirm the name is final, and confirm the
two identifiers are what they should be, before running anything that uploads.

Flutter's `create` default often leaves them disagreeing (`my_app` on Android,
`myApp` on iOS, because an iOS bundle id cannot contain an underscore). They do
not have to match, but the difference should be a decision rather than a
default.

## The order

1. **`cux_ship_verify` into the test suite, first.** Both stores enforce their
   limits *after* the artifact has been transferred and processed — a release
   note over the cap, a screenshot with an alpha channel, a missing iPad set.
   A test fails on the push that introduces the problem; a release-time check
   fails twenty minutes into a release, and a store check fails days later.
2. **`cux_ship deps install`** — fetches `sops` and `age` into `.bin/` by pinned
   hash. Add `/.bin` to `.gitignore` **before** running it, or the next
   `git add -A` commits ~55 MB of Go binaries.
3. **Signing and credentials** (below).
4. **Build, then upload** — and keep them separate. A failed upload should be
   retried without a rebuild.

   **Have the build write a manifest and the upload read it.**
   `cux_ship manifest write` after signing, then `<store> upload --manifest`,
   which supplies the artifact, build number, version name and commit from one
   file. Typing those as flags is four chances to name the wrong build, and the
   failure is not a refusal — it is uploading one artifact while telling the
   store it is another. The upload also verifies the artifact against the
   manifest's digest, and reads the build's own `versionCode` /
   `CFBundleVersion` back out of an `.aab` or `.ipa` to check they agree.

   Without a manifest the artifact goes to `appstore upload --artifact` for both
   platforms; `--ipa` and `--pkg` are accepted spellings of it, so neither
   platform's users need the other's file extension.
5. **`cux_ship appstore wait <build-number>`** if something has to block on
   Apple finishing processing. It needs only the API key, so it belongs on a
   cheap runner rather than the macOS one that built the thing:
   `cux_ship appstore wait $(cux_ship appstore build-number)`.
6. **`cux_ship <store> promote`** to reach real users.
7. **`cux_ship release finish`** once per release, after every store — not once
   per store. It tags the released commit and moves the branch past the version
   that is now public.

   **It is for step 7, not step 4.** Its `--destination` defaults to
   `production`, because it is built for the end of a real release — so using it
   to record an *upload* writes a tag saying "released to production" for a build
   that went to internal testing. Nothing refuses it, and a tag message is not
   read again until somebody is reconstructing what shipped where. If you want a
   record of an upload, that is `tag.upload.enabled` in `.cux-ship.yaml`, which
   `<store> upload` writes itself with the destination it actually used.

## TestFlight groups

**Internal and external groups are different releases wearing one flag.** An
internal group receives an assigned build within minutes, no review. An
external group receives *nothing* until the build passes Apple's beta review —
so `--beta-group`, on `upload` or `promote`, reads the group's kind and
carries an external one the rest of the way: the beta app description is
reasserted, the build is submitted for beta review, and the closing line reads
back what Apple now says (`WAITING_FOR_BETA_REVIEW` is success). Do not treat
"added to beta group" as the release for an external group; the closing state
line is.

For a build that is already up — CI uploaded it, `upload` has nothing left to
carry — the whole release is one command:

```bash
cux_ship appstore beta-release --build-number 52 --beta-group "External Testers"
```

`--build-number` is required and deliberately not defaulted to the newest, for
the reason `appstore wait` requires it: a release to testers is a release of a
*specific* build, and "newest" would release somebody else's upload.

**The group's name is the one input none of this can infer**, and it is not in
the repository — groups are made in App Store Connect and cannot be created
over the API. `appstore beta-groups` prints the names an app has and whether
each is internal or external, which is the kind that decides everything above:

```bash
cux_ship appstore beta-groups
```

**The beta app description is owned like every other listing field.**
`store/appstore/listings/<locale>/beta_description.txt` present means owned:
reasserted on every release, so the console cannot drift from it. Absent means
the console owns it and nothing here touches it. Like the changelog, only
committed text is published — a dirty file is refused, so commit it before
releasing.

Refusals a release runner will actually hit, each meaning what it says:

- **`--skip-waiting` with `--beta-group` is refused.** A build cannot reach a
  group until Apple finishes processing it, which is exactly the wait being
  skipped.
- **"No description anywhere"** — external group, nothing in the repository,
  no locale in App Store Connect holding one. It refuses *before* anything is
  written; either create the tree file above or fill in TestFlight > Test
  Information once in the console.
- **A REJECTED earlier beta review submission is a hard failure, not a
  no-op.** A build is submitted at most once, so re-running does not resubmit
  and the release delivered nothing. Apple explains the rejection only by
  e-mail and in the console; fix what it names and upload a new build.

## What cannot be undone

- **`play promote` is public immediately. `appstore promote` is not, and the
  difference is a setting you can now name.** Play's production track goes live
  on promotion. An App Store promotion submits for *review*, and what happens
  once Apple approves is the version's `releaseType`: `MANUAL` waits for
  somebody to press release, `AFTER_APPROVAL` goes out on approval. cux_ship
  creates new versions `MANUAL` and leaves existing ones alone, so the
  irreversible moment on the App Store is usually later than the promote — but
  `--release-type AFTER_APPROVAL` makes it the promote, and then it is as
  irreversible as Play. The run prints the effective release type either way,
  read back from Apple rather than from the flag.
- **Both print everything they inferred and wait.** Read the summary; do not
  reflexively pass `--yes`. In CI `--yes` is required, because with no terminal
  the command refuses rather than assuming yes — that refusal is a feature.
- **`--dry-run` is not offline, and the two stores rehearse differently.** Both
  authenticate, so neither is *credential-free*; the genuinely offline checks
  are `cux_ship verify` and the test-suite functions.

  On **Play** it opens a real edit, does every step inside it, and deletes the
  edit instead of committing, so Google validates the contents and then throws
  them away. A strong rehearsal, with two edges: the checks `edits.commit`
  performs are never reached, because the edit is deleted rather than
  committed, and the data-safety declaration is a separate API outside the
  edit that a dry run does not send at all.

  On the **App Store** there is no edit to open: App Store Connect has no edit
  transaction, so every write lands the moment it is made and a rehearsal can
  only mean *do every read, print every write, perform none*. Apple therefore
  never sees the writes and never validates them, which is a weaker promise —
  a dry run that prints cleanly can still fail for real on a value Apple
  rejects.

  **Weaker again on `appstore promote`, when the version does not exist yet.**
  Creating it is a write, so a dry run creates none, and everything hanging off
  the version is then skipped — the listing publish and the submission
  included. That is the ordinary repeat release, and there a green
  `appstore promote --dry-run` has exercised almost none of the promote path:
  read it as "the arguments and the reads are sound", not "this would have
  worked".

  When the version *does* already exist — the requested one, or the editable
  one cux_ship adopts by renaming — the dry run has a record to work from and
  rehearses the rest as would-writes. So how much a promote dry run proves
  depends on state you may not have checked. The line it prints about creating
  or renaming the version is the tell.
- **A published pub.dev version is permanent** (retraction is a seven-day window,
  not an undo), if you are working on cux_ship itself.

## Credentials

Every command reads **plain environment variables** and nothing else. How they
get there is the project's business; `cux_ship secrets exec -- <command>` is one
way, decrypting a sops file and removing the plaintext however the run ends.

**`keychain exec` gives its child nothing but `APPLE_KEYCHAIN`.** Not a token,
not a key, not the sops identity. Whatever else the build needs is named at the
call site:

```bash
cux_ship keychain exec --only ssh_keys.github_deploy -- tool/release.sh
cux_ship secrets exec --only apple.api_keys.upload -- tool/upload.sh
```

The selector is `family` or `family.instance`. On `secrets exec` it is optional
and omitting it places everything; on `keychain exec` it is the only way
anything arrives.

Two consequences worth knowing before you debug something:

- **A build that dies with `X is not set` under `keychain exec` is usually a
  missing `--only`, not a missing credential.** That failure is deliberate and
  is the design working: what a build script consumes happens below the
  wrapper's arguments, so it cannot be detected and has to be declared.
- **`SOPS_AGE_KEY` is stripped from that child and cannot be readmitted.** If a
  script under `keychain exec` needs to decrypt, that is the signal to run the
  two commands as siblings rather than nesting them — the archive is not
  supposed to be able to reach the file that holds the App Store key.

Three rules, and the second one has already leaked a key once:

- **Never decrypt a secrets file to look at it.** A sops file keeps its key
  names in cleartext and encrypts only the values, so its shape can be read with
  no identity and no risk of a secret reaching a terminal:

  ```bash
  cux_ship secrets list
  ```

  It lists every credential, says which heading each sits under, marks any name
  `secrets exec` would refuse, and ignores the `sops:` block — recipients, MAC,
  version — which is metadata, is stripped on decrypt, and is never a
  credential. **Run it before adopting a new version**: an unrecognized key
  stops `secrets exec` dead, and this is the check that finds one first.

  There are three levels, and each needs strictly more than the last:

  | | needs | answers |
  |---|---|---|
  | `cux_ship verify` | nothing | are the release inputs sound |
  | `cux_ship secrets list` | no identity | what is in the file |
  | `cux_ship secrets check` | an identity | do the credentials work, and agree |

  `secrets check` is the one to run after adding a credential, after a rotation,
  and when onboarding a machine — the moments an upload-time warning is
  structurally too late for. It reports each credential as **verified**,
  **failed**, or **opaque**, and exits non-zero only on `failed`. Opaque is not
  a to-do: it is a credential this tool cannot ever authenticate, such as a
  token, and it must not read as an error or the check becomes something people
  learn to skip.

  Its unique value is the **cross-checks**, which no single-artifact command can
  do — above all whether a stored profile still embeds a certificate the file
  actually holds. That pairing is not derivable from either side alone: a
  profile keeps its own expiry date, and this project has a Developer ID profile
  outliving the certificate inside it by more than a decade. Replacing a
  certificate silently invalidates every profile issued against it, and nothing
  else notices until codesign fails mid-archive.

  Do not hand-roll a `grep` for this. A version of this skill did, with
  `'^[a-z_]+:…'` — a character class that omits digits, so it silently hid
  `keystore_p12_base64`, `api_private_key_base64` and every other name carrying
  actual key material, reported the four that mattered least, and read as a
  clean bill of health.
- **Never list credential names with `cut -d= -f1`.** It prints any line
  containing no `=` *in full*, and a service-account JSON is multi-line — so it
  emits the `"private_key"` line verbatim. Use an anchored form:
  `env | sed -n 's/^\([A-Z_][A-Z_0-9]*\)=.*/\1/p' | sort`.
- **A partial credential group is worse than none.** A keystore path with no
  password does not fail as "you forgot the password" — Gradle falls through to
  the debug key and produces an artifact only the store rejects, after a full
  upload. `secrets exec` refuses a half-configured group for this reason; do not
  work around it.

**`api_issuer_id` is optional and its absence means something.** A *team* App
Store Connect key has one; an *individual* key, generated by one user and
inheriting that user's app restrictions, has none at all. The individual key is
how a CI credential is kept from reaching every app in the team.

### Putting a credential in

**Never hand-roll a `sops set` pipeline for this.** It encodes the schema path
by hand, writes one field at a time — so an interrupted run leaves a
half-credential — and `sops set` expects a *JSON-encoded* value, so a bare
string is accepted and stored wrong. That produces a credential which looks
present and authenticates as garbage.

```bash
cux_ship secrets add certificate distribution dist.p12 --password-file pw
cux_ship secrets add profile ios_appstore app.mobileprovision
cux_ship secrets add api-key upload ~/Downloads/AuthKey_ZHGL57YJVC.p8
cux_ship secrets add token artifact --env ARTIFACT_TOKEN --value-file tok
cux_ship secrets remove token fosshub
```

A name and an artifact, in that order, positionally. There are no `--p12` /
`--p8` / `--file` flags: **the file is identified by its contents**, so a `.p8`
handed to `add certificate` is told what it actually is and which command wants
it. Two exceptions, because the shape is not perfectly uniform — `token` takes
no file (its value comes from `--value-file` or stdin) and `play-account` takes
no name.

What it derives so nobody types it: the schema path, the base64, the JSON
quoting, and an api key's `id` and `kind` read back out of Apple's own
`AuthKey_`/`ApiKey_` naming — the two fields most often got wrong. It prints a
certificate's subject and expiry and a profile's uuid and platform, so you can
see you added what you meant to.

Two safety properties worth relying on:

- **Every field of a credential lands in one write**, so the partial state that
  `secrets exec` refuses is unrepresentable rather than merely reported.
- **It refuses to overwrite.** `--replace` is the rotation verb. Silently
  replacing a signing key is worse than any partial write.

Replacing a *certificate* also names the profiles issued against the outgoing
one, which stop working the moment it is replaced — a coupling no artifact
carries, since the profile keeps its own expiry date. If it cannot establish
that, it says so rather than reporting that none were affected.

`--from-keychain --team <id>` builds the `.p12` out of a macOS keychain instead
of taking one, with a generated password — the onboarding path. It pairs the
certificate with its private key on `localKeyID` and never on `friendlyName`:
macOS names the two bags differently, so a friendlyName filter yields a `.p12`
that imports cleanly and cannot sign.

Passwords and token values are never arguments — a command line is visible to
every `ps` on the machine — so they come from `--password-file`,
`--value-file`, or a prompt. A certificate's password is checked against the
`.p12` *before* anything is written, because a bundle stored with the wrong
password fails at signing time, a long way from here and looking nothing like a
password problem.

## Monorepos

If the Flutter app is not at the repository root, say so once in
`.cux-ship.yaml` at the root rather than passing `--app-dir` at every call site:

```yaml
app-dir: app
```

The split is deliberate and worth understanding before writing scripts around
it: **the repository owns `CHANGELOG.md` and `store/`; the app directory owns
`pubspec.yaml`, `android/`, `ios/` and `macos/`.** A release describes what the
repository shipped, and in a monorepo most of what a user notices usually
changed in some package other than the app.

Without this, every inferred value comes back null and silently turns back into
a required flag — and `cux_ship release finish` cannot find a pubspec at all.

## Verifying a release actually happened

Absence and success look the same here. A pipeline that uploaded nothing,
uploaded to the wrong listing, or uploaded a stale artifact all exit zero.

- **Check the artifact, not the intent.** For signing, that is
  `apksigner verify --print-certs` on the built `.aab` — not a grep of
  `build.gradle.kts`, which is a text match against a Turing-complete script.
- **After the first release, install it from the store on a real device and read
  the build number back.** Nothing else distinguishes a working pipeline from a
  plausible one.

## Store-side work no command can do

Creating the app record, the content rating questionnaire, data safety, age
rating, export compliance, and — for an app that reads the camera roll — Play's
photo and video permissions declaration, which has its own review cycle and is
avoidable entirely by using the system photo picker. Decide that one *before*
writing the manifest and the data-safety file, not after.

A **new personal** Play developer account also carries a closed-testing gate: 12
testers for 14 continuous days before production is offered at all. That
reorders an entire launch and is invisible until you try to promote.
