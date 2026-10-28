#!/usr/bin/env bash
# PostToolUse guard for CLAUDE.md hard constraint #1: ClaudePet never makes a network request.
# After an Edit/Write to a Swift file under Sources/, flag any networking API now in that file.
# Exit 2 feeds the message back to Claude; the edit itself has already happened.
f="$(jq -r '.tool_input.file_path // empty')"
case "$f" in
  "$CLAUDE_PROJECT_DIR"/Sources/*.swift) ;;
  *) exit 0 ;;
esac
[ -f "$f" ] || exit 0
hits="$(grep -nE 'URLSession|URLRequest|NWConnection|NWListener|NWBrowser|^import Network|NSURLConnection|CFSocket|CFStream|\bcurl\b|\bwget\b' "$f")"
[ -z "$hits" ] && exit 0
{
  echo "no-network guard: ${f#"$CLAUDE_PROJECT_DIR"/} now uses a networking API:"
  echo "$hits"
  echo "ClaudePet reads local files only and never makes a network request (CLAUDE.md, 'Two hard constraints')."
  echo "Remove it, or stop and ask the user: data that isn't already local is out of scope."
} >&2
exit 2
