# cux_ship

Release tooling for the App Store and Google Play. A pub workspace of three
published packages:

| | |
|---|---|
| `cux_ship` | the command, and everything publishing needs — googleapis, an image codec, an HTTP client, a JWT signer |
| `cux_ship_verify` | the offline half, with no dependencies at all: the CHANGELOG parser, the App Store metadata model, and the checks over both |
| `cux_buildnumber` | allocating a build number, which is a git operation a build does before it has an artifact |

**Read [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) before changing anything.**
It is three rules and a rule about the rules, and it is deliberately short: a
rule lives there only while it cannot be a check, and only after it has bitten
twice. The first of the three — *every guard's test is observed failing with the
guard removed* — governs every fix here, and is not negotiable because a test
only ever seen green proves nothing about the thing it guards.

**Publishing is [docs/RELEASING.md](docs/RELEASING.md), and it owns the version
number.** A change writes its entry under `## Unreleased` and stops there;
`pubspec.yaml`, `lib/src/version.dart` and the changelog heading move together
on a `release/x.y.z` branch. A feature branch that bumps them is claiming a
number it cannot know it will get — and with several branches open at once, each
claims the same one and they collide.

Per package, from its own directory:

```bash
dart pub get && dart analyze --fatal-infos && dart test
```

`version_test.dart` asserts `cuxShipVersion` and `pubspec.yaml` agree, so run
the suite *after* the last edit rather than before it.
