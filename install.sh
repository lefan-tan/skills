#!/usr/bin/env bash
# Symlink each skill in this repo into ~/.claude/skills/
# Usage: ./install.sh [skill-name ...]
#   No args = install all skills found in repo.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${HOME}/.claude/skills"
mkdir -p "${TARGET_DIR}"

if [[ $# -gt 0 ]]; then
  skills=("$@")
else
  skills=()
  for d in "${REPO_DIR}"/*/; do
    name="$(basename "$d")"
    [[ -f "$d/SKILL.md" ]] && skills+=("$name")
  done
fi

if [[ ${#skills[@]} -eq 0 ]]; then
  echo "No skills found." >&2
  exit 1
fi

for name in "${skills[@]}"; do
  src="${REPO_DIR}/${name}"
  dst="${TARGET_DIR}/${name}"
  if [[ ! -d "$src" ]]; then
    echo "skip: ${name} (not in repo)" >&2
    continue
  fi
  if [[ -L "$dst" ]]; then
    echo "relink: ${name}"
    rm "$dst"
  elif [[ -e "$dst" ]]; then
    echo "skip: ${name} (existing non-symlink at ${dst} — remove manually)" >&2
    continue
  else
    echo "link:   ${name}"
  fi
  ln -s "$src" "$dst"
done

echo "Done. Skills installed to ${TARGET_DIR}"
