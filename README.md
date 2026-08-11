# cux_ship

Release tooling for shipping a Flutter or Dart app to the App Store and Google
Play: upload an artifact, publish the store listing, promote a build that is
already up, and turn a `CHANGELOG.md` into the notes each store shows.

Two published packages, and which one you want depends on what you are doing.

| Package | | |
|---|---|---|
| [**`cux_ship`**](cux_ship) | **You are shipping.** The command, and the App Store Connect and Google Play clients behind it. | [pub.dev](https://pub.dev/packages/cux_ship) · [README](cux_ship/README.md) |
| [**`cux_ship_verify`**](cux_ship_verify) | **You are checking.** The changelog parser, the App Store metadata model, and the offline checks over both. No dependencies at all, so it belongs in your `dev_dependencies`. | [pub.dev](https://pub.dev/packages/cux_ship_verify) · [README](cux_ship_verify/README.md) |

`cux_ship` depends on `cux_ship_verify`, never the reverse. That direction is the
reason there are two packages: both stores enforce their limits *after* an
upload, so the checks want to run in your own test suite on every push — and
reaching them through the CLI would put googleapis in the lockfile of everyone
who only wanted to know whether a release note is too long.

Extracted from [Hold the Wheel](https://holdthewheel.app/) with its
history intact — `git log --follow` on any file here reaches back past both the
extraction and the later merge from five packages into two. Most comments in
this code record a specific incident, and that is the point of keeping the
history: `git blame` is usually the only way to recover why a line exists.

**Everything else is in [`cux_ship/README.md`](cux_ship/README.md)** — the
command tree, monorepo layouts, credentials and sops, pinned `sops`/`age`
binaries, and the Apple and Play behavior each command works around.

## For agents

[`skills/cux-ship-releasing`](cux_ship/skills/cux-ship-releasing/SKILL.md) is a skill for an AI agent setting
up or operating releases with this tooling — the ordering and the irreversible
steps, pointing at the READMEs for everything else. See
[`skills/README.md`](cux_ship/skills/README.md) to install it.

## Development

A pub workspace. `dart pub get` at the root resolves both packages against one
lockfile; `dart format`, `dart analyze --fatal-infos` and `dart test` run per
package.

## Licence

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
