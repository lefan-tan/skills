# skills

Personal Claude Code skills.

## Install

Clone into `~/.claude/skills/` so each subdirectory becomes a discoverable skill:

```bash
git clone git@github.com:lefan-tan/skills.git ~/.claude/skills-repo
```

Then symlink each skill you want:

```bash
ln -s ~/.claude/skills-repo/lefan-motion-net-pr-push ~/.claude/skills/lefan-motion-net-pr-push
```

Or clone directly into `~/.claude/skills/` if you have no existing skills there:

```bash
git clone git@github.com:lefan-tan/skills.git ~/.claude/skills
```

## Skills

- `lefan-motion-net-pr-push` — PR push flow for motion.net (C# code review, pre-commit fixes)
