# skills

Personal Claude Code skills.

## Install

```bash
git clone git@github.com:lefan-tan/skills.git ~/Documents/Code/skills
cd ~/Documents/Code/skills
./install.sh                          # install all skills in repo
./install.sh lefan-motion-net-pr-push # or just one
```

Script symlinks each skill dir into `~/.claude/skills/`. Re-run after `git pull` to pick up new skills. Existing non-symlink dirs are skipped — remove manually if you want to switch.

## Skills

- `lefan-motion-net-pr-push` — PR push flow for motion.net (C# code review, pre-commit fixes)
