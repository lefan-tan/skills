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

## Maintenance

**Every time a skill is added or updated in this repo, commit and push immediately.** Symlinks point back to `~/.claude/skills/<name>`, so edits made here (or to the symlinked file) are live locally — but other machines only get them after push + `git pull`.

Workflow:

```bash
cd ~/Documents/Code/skills
git add -A
git commit -m "Update <skill-name>: <what changed>"
git push
```

On other machines: `git pull` (no re-run of `install.sh` needed unless a new skill dir was added).
