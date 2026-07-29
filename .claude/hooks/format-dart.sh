#!/bin/bash
# PostToolUse hook (Edit|Write): keep edited Dart files in canonical
# `dart format` style so formatting never shows up as review noise
# (ffigen regens and hand edits alike).
set -euo pipefail

FILE=$(jq -r '.tool_input.file_path // empty')

case "$FILE" in
  *.dart) ;;
  *) exit 0 ;;
esac

[ -f "$FILE" ] || exit 0
command -v dart >/dev/null 2>&1 || exit 0

dart format "$FILE" >/dev/null 2>&1 || true
