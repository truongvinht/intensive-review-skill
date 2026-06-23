#!/usr/bin/env bash
set -euo pipefail

SKILL_NAME="intensive-review"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/$SKILL_NAME"
DEST_DIR="${HOME}/.claude/skills/$SKILL_NAME"

if [[ ! -d "$SRC_DIR" ]]; then
  echo "error: source directory not found: $SRC_DIR" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
cp "$SRC_DIR/SKILL.md" "$DEST_DIR/SKILL.md"
cp "$SRC_DIR/TESTS.md" "$DEST_DIR/TESTS.md"

echo "installed: $DEST_DIR"
