#!/usr/bin/env bash
# PreToolUse guard for two things CLAUDE.md warns about that nothing else enforces:
#  1. ./bundle.sh (and release.sh, which calls it) rm -rf's ./ClaudePet.app, usually the copy the
#     user is running. Ask first while it runs; verification builds go through verify-claudepet.
#  2. /tmp/claude/statusline-usage-cache.json and codex-usage-cache.tsv are what the user's live
#     statusline reads; a fake figure written there shows on their real status bar. Deny writes.
input="$(cat)"
tool="$(jq -r '.tool_name // empty' <<<"$input")"
CACHE='(/private)?/tmp/claude/(statusline-usage-cache\.json|codex-usage-cache\.tsv)'

decide() {  # decide <ask|deny> <reason>
  jq -n --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: $r}}'
  exit 0
}

case "$tool" in
  Edit|Write|MultiEdit|NotebookEdit)
    f="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input")"
    grep -qE "^$CACHE\$" <<<"$f" && decide deny \
      "$f is the live cache the user's statusline reads. Use CLAUDEPET_UTIL / CLAUDEPET_CODEX, which write their own temp files."
    ;;
  Bash)
    cmd="$(jq -r '.tool_input.command // empty' <<<"$input")"
    if grep -qE "$CACHE" <<<"$cmd"; then
      grep -qE ">>?[[:space:]]*['\"]?$CACHE" <<<"$cmd" && decide deny \
        "This redirects into a live /tmp/claude cache the user's statusline reads. Use CLAUDEPET_UTIL / CLAUDEPET_CODEX instead."
      grep -qE '\b(tee|cp|mv|rm|touch|truncate|ln|install|rsync)\b|sed[[:space:]]+-i' <<<"$cmd" && decide ask \
        "This command may modify a live /tmp/claude cache the user's statusline reads (reading it is fine)."
    fi
    # Only when run as a command (line start, after ; & | ( or a shell), not when merely read.
    if grep -qE '(^|[;&|(]|\b(bash|sh|zsh|exec|time))[[:space:]]*([^[:space:];&|()]*/)?(bundle|release)\.sh\b' <<<"$cmd" \
       && pgrep -f "$CLAUDE_PROJECT_DIR/ClaudePet.app/Contents/MacOS/ClaudePet" >/dev/null; then
      decide ask \
        "bundle.sh rm -rf's ./ClaudePet.app, which is running right now (the user's widget). To verify a change, use .claude/skills/verify-claudepet/scripts/verify.sh build instead."
    fi
    ;;
esac
exit 0
