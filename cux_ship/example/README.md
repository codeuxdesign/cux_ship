# Examples

This package is a command rather than a library, so the examples are
invocations. Run them from anywhere inside your project — everything is read
from the repository around you.

```bash
dart pub global activate cux_ship
```

## Publish a build testers already have

Nothing is built and nothing is uploaded: the store is told to point a track at
a build it already holds, so what ships is the identical artifact rather than a
rebuild of the same commit.

```bash
cux_ship play promote                  # internal → production
cux_ship play promote --rollout 0.1    # ... to 10% of users first
cux_ship appstore promote              # newest processed build → App Store review
```

Each prints everything it inferred — the application id, the tracks, the build
number, where the notes come from — and waits, because both are public
immediately. `--yes` skips the question and is required where there is no
terminal; with neither, the command refuses rather than assuming yes.

## Upload an artifact and the listing together

On Google Play these ride one edit transaction, so a release and the store text
describing it commit together or not at all.

```bash
cux_ship play upload --aab build/app/outputs/bundle/release/app-release.aab \
  --build-number 41 --version-name 1.0.3 --track internal

cux_ship play upload --dry-run         # listing only: no --aab
```

`--dry-run` does every step and then deletes the edit instead of committing it.
That makes it safe, not offline — it authenticates and needs an app that
already exists.

## Check the release inputs, offline

No credentials, no network. Better still, put these in your test suite with
[`cux_ship_verify`](https://pub.dev/packages/cux_ship_verify) so they run on
every push instead of at release time.

```bash
cux_ship verify --require-screenshot-type APP_IPHONE_67
cux_ship screenshots flatten --check store/appstore
```

## Finish the release in the repository

Run once per release, after every store has been promoted — not once per store.
It tags the released commit and moves the branch to the next patch version, so
no later build claims a name that is already in front of users.

```bash
cux_ship release finish --build-number 41
```

## Credentials

Every command reads plain environment variables and nothing else. If you keep
yours in a sops-encrypted file, this puts them there for one command and removes
them however it ends:

```bash
cux_ship deps install                  # fetch sops and age, by pinned hash
cux_ship secrets exec -- cux_ship play promote
```

The full reference — inferred values, monorepo layouts, the secrets file shape,
and the Apple and Play behavior each command works around — is in the
[README](../README.md).
