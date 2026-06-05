#!/usr/bin/env bash
# Symlink each skill in this repo into Claude, Codex, and Pi skill directories.
# Usage: ./install.sh [skill-name ...]
#   No args = install all skills found in repo.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIRS=(
  "${HOME}/.claude/skills"
  "${HOME}/.codex/skills"
  "${HOME}/.pi/skills"
)
mkdir -p "${TARGET_DIRS[@]}"

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
  if [[ ! -d "$src" ]]; then
    echo "skip: ${name} (not in repo)" >&2
    continue
  fi

  for target_dir in "${TARGET_DIRS[@]}"; do
    dst="${target_dir}/${name}"
    if [[ -L "$dst" ]]; then
      echo "relink: ${name} -> ${target_dir}"
      rm "$dst"
    elif [[ -e "$dst" ]]; then
      backup="${dst}.backup.$(date +%Y%m%d%H%M%S)"
      echo "backup: ${name} (${dst} -> ${backup})"
      mv "$dst" "$backup"
    else
      echo "link:   ${name} -> ${target_dir}"
    fi
    ln -s "$src" "$dst"
  done
done

echo "Done. Skills installed to:"
for target_dir in "${TARGET_DIRS[@]}"; do
  echo "  - ${target_dir}"
done
