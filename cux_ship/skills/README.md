# Agent skills

[`cux-ship-releasing`](cux-ship-releasing/SKILL.md) — for an AI agent setting up
or operating releases with this tooling.

Deliberately **not** a copy of the package READMEs. Those are the reference; a
second copy of a reference is a copy that drifts, which is the thing extracting
this repository existed to stop. The skill holds only what a reference cannot:
the order to do things in, and which steps cannot be undone.

It ships **inside the `cux_ship` package** rather than only in this repository,
so it travels wherever the command does.

## Installing it

```bash
mkdir -p .claude/skills
cp -R ~/.pub-cache/hosted/pub.dev/cux_ship-*/skills/cux-ship-releasing .claude/skills/
```

Use `~/.claude/skills/` instead to have it in every project you work on. From a
clone of this repository the source is `cux_ship/skills/cux-ship-releasing` —
the same directory either way.

## Why `skills get` does not find it

The [`skills`](https://pub.dev/packages/skills) CLI discovers skills bundled in
pub dependencies, which is exactly what this directory is for — and it **skips
this one**, with a warning naming the reason. That is deliberate, and the
reasoning is worth recording because the next person to look will assume it is a
bug.

**Two conventions disagree, and no naming satisfies both.**

`skills` requires a bundled skill's directory to begin with the package name and
a hyphen. Its scanner is a literal prefix match with no normalization
(`lib/src/core/skill_scanner.dart`):

```dart
final prefix = '${package.name}-';
final skillName = p.basename(entity.path);
if (!skillName.startsWith(prefix)) { logger.warning('Skipping skill ...'); }
```

This package is `cux_ship`, so it wants `cux_ship-releasing`.

The [Agent Skills specification](https://agentskills.io/specification) says the
`name` field "may only contain unicode lowercase alphanumeric characters (`a-z`,
`0-9`) and hyphens" and "must match the parent directory name". An underscore is
invalid, so `cux_ship-releasing` cannot be a conforming skill name.

**Dart package names are snake_case by convention. So this affects most of
pub.dev, not just this package** — it is simply unexercised, because every Dart
package shipping skills today (`fluwx`, `patrol`, `webf`, `signals`) has a
single-word name that sidesteps it.

### The three options, and why this one

| | Result |
|---|---|
| `cux-ship-releasing` everywhere | **Chosen.** Conforms; loads in every agent. `skills get` warns and skips it. |
| dir `cux_ship-releasing`, name `cux-ship-releasing` | The CLI would find it — it reads only the directory. But **VS Code requires `name` to match the parent directory and fails silently when it does not**: the skill never loads and nothing says why. |
| `cux_ship-releasing` everywhere | Underscore in `name` is an invalid character; reference validators reject it. |

The deciding argument is the *failure mode*, not the feature. A skipped skill
announces itself — one warning, naming the skill and the rule it broke. A skill
that silently never loads is indistinguishable from one that loaded and had
nothing to say, which is the class of failure this whole repository is built to
refuse.

So: a loud missing feature over a silent broken one.

### If this is worth fixing later

Nothing has been reported upstream. Two things would each resolve it, and either
would help every snake_case package on pub.dev:

- **`serverpod/skills`** accepting the hyphenated form of a package name as an
  alternative prefix, so `cux_ship` also matches `cux-ship-`. Its issue tracker
  has nothing on this.
- **The spec** dropping the name-must-match-directory rule, which has been
  argued for in [agentskills#191](https://github.com/agentskills/agentskills/issues/191)
  — including by a VS Code maintainer calling it "redundant" and a "confusing
  user experience". The rule still stands, and VS Code still enforces it.

Until one of those lands, the copy command above is the whole story.
