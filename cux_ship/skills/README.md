# Agent skills

[`cux-ship`](cux-ship/SKILL.md) — for an AI agent setting up or operating
releases with this tooling.

Deliberately **not** a copy of the package READMEs. Those are the reference; a
second copy of a reference is a copy that drifts, which is the thing extracting
this repository existed to stop. The skill holds only what a reference cannot:
the order to do things in, and which steps cannot be undone.

It ships **inside the `cux_ship` package**, not only in this repository, so it
travels wherever the command does: a project that depends on the tool already
has the skill, with nothing to clone.

Install it into a project, from wherever pub put the package:

```bash
mkdir -p .claude/skills
cp -R ~/.pub-cache/hosted/pub.dev/cux_ship-*/skills/cux-ship .claude/skills/
```

Use `~/.claude/skills/` instead to have it in every project you work on. From a
clone of this repository the source is `cux_ship/skills/cux-ship` — the same
directory either way.

Versioned beside the tool it describes, so when a command grows a new refusal
the warning about it is in the same commit.
