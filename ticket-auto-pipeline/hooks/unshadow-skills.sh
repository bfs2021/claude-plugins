#!/usr/bin/env bash
# SessionStart hook — moves aside any ~/.claude/skills/<name>/SKILL.md that
# shadows one of this plugin's skills (lib/skill-shadow.sh explains why that
# is dangerous). The file is renamed to SKILL.md.shadowed-<stamp>, never
# deleted; Claude Code only loads SKILL.md, so the renamed copy is inert.
#
# Registered after the lib-sync hook and before skill-fingerprint.sh, so the
# fingerprint sees the cleaned state. TICKET_UNSHADOW=warn reports without
# moving anything. A symlinked copy is only reported (it is managed elsewhere).
# When anything is found, a systemMessage tells the user what happened.
# Fail-open: exits 0 on every path.

_root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}"
[ -f "$_root/lib/skill-shadow.sh" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

_mode=fix
[ "${TICKET_UNSHADOW:-}" = "warn" ] && _mode=list

_out=$(bash "$_root/lib/skill-shadow.sh" "$_mode" --plugin-root "$_root" \
  --skills-dir "${UNSHADOW_SKILLS_DIR:-$HOME/.claude/skills}" 2>/dev/null) || true
[ -n "$_out" ] || exit 0

_moved="" _kept=""
while IFS='|' read -r _name _a _b _c; do
  case "$_a" in
  moved) _moved="${_moved}${_moved:+, }${_name}" ;;
  kept) _kept="${_kept}${_kept:+, }${_name} (${_b}: ${_c})" ;;
  *) _kept="${_kept}${_kept:+, }${_name} (${_a})" ;;
  esac
done <<<"$_out"

_msg="ticket-auto-pipeline:"
[ -n "$_moved" ] && _msg="$_msg moved stale user-level skill copies aside (they shadowed the plugin's skills): ${_moved}. Each is now SKILL.md.shadowed-<date> in its ~/.claude/skills folder."
[ -n "$_kept" ] && _msg="$_msg user-level SKILL.md still shadowing a plugin skill: ${_kept}. Remove or rename it, or the old copy runs instead of the plugin's."

jq -nc --arg m "$_msg" '{systemMessage: $m}' 2>/dev/null || true
exit 0
