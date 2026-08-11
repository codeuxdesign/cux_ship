# Agent skills

[`cux-ship`](cux-ship/SKILL.md) — for an AI agent setting up or operating
releases with this tooling.

Deliberately **not** a copy of the package READMEs. Those are the reference; a
second copy of a reference is a copy that drifts, which is the thing extracting
this repository existed to stop. The skill holds only what a reference cannot:
the order to do things in, and which steps cannot be undone.

Install it for one project:

```bash
mkdir -p .claude/skills
cp -R path/to/cux_ship/skills/cux-ship .claude/skills/
```

Or for every project you work on:

```bash
cp -R path/to/cux_ship/skills/cux-ship ~/.claude/skills/
```

It is versioned here so it travels with the tool it describes — when a command
grows a new refusal, the skill that warns about it is in the same commit.
