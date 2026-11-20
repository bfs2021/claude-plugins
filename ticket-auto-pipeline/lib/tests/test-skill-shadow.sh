#!/usr/bin/env bash
# test-skill-shadow.sh — lib/skill-shadow.sh and hooks/unshadow-skills.sh.
# Usage: bash test-skill-shadow.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$LIB_DIR/.." && pwd)"
SS="$LIB_DIR/skill-shadow.sh"
HOOK="$PLUGIN_ROOT/hooks/unshadow-skills.sh"
FILTER="${1:-}"
PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  if "$@" 2>/dev/null; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

# _skill DIR NAME [FRONTMATTER_NAME] — a user skill folder with a SKILL.md.
_skill() {
  mkdir -p "$1/$2"
  printf -- '---\nname: %s\ndescription: old copy\n---\n\nold body\n' "${3:-$2}" >"$1/$2/SKILL.md"
}

test_list_finds_shadow_by_folder_and_by_name() {
  local d rc=0 out
  d=$(mktemp -d)
  _skill "$d" ticket-auto
  _skill "$d" my-router ticket-flow
  _skill "$d" unrelated-skill
  out=$(bash "$SS" list --plugin-root "$PLUGIN_ROOT" --skills-dir "$d") && rc=1
  {
    grep -qxF "ticket-auto|$d/ticket-auto/SKILL.md" <<<"$out" &&
      grep -qxF "ticket-flow|$d/my-router/SKILL.md" <<<"$out" &&
      ! grep -q unrelated <<<"$out"
  } || rc=1
  rm -rf "$d"
  return $rc
}

test_list_ignores_synced_scripts() {
  local d rc=0 out
  d=$(mktemp -d)
  mkdir -p "$d/ticket-flow" "$d/lib"
  echo 'echo hi' >"$d/ticket-flow/flow.sh"
  out=$(bash "$SS" list --plugin-root "$PLUGIN_ROOT" --skills-dir "$d") || rc=1
  [ -z "$out" ] || rc=1
  rm -rf "$d"
  return $rc
}

test_list_reports_app_knowledge_and_retired_names() {
  local d rc=0 out
  d=$(mktemp -d)
  _skill "$d" app-knowledge
  _skill "$d" ticket-fleet-controller
  out=$(bash "$SS" list --plugin-root "$PLUGIN_ROOT" --skills-dir "$d") && rc=1
  {
    grep -qxF "app-knowledge|$d/app-knowledge/SKILL.md" <<<"$out" &&
      grep -qxF "ticket-fleet-controller|$d/ticket-fleet-controller/SKILL.md" <<<"$out"
  } || rc=1
  rm -rf "$d"
  return $rc
}

test_keep_extra_exempts_a_name() {
  local d rc=0 out
  d=$(mktemp -d)
  _skill "$d" nav-hints
  out=$(SKILL_SHADOW_KEEP_EXTRA="nav-hints" bash "$SS" list --plugin-root "$PLUGIN_ROOT" --skills-dir "$d") || rc=1
  [ -z "$out" ] || rc=1
  rm -rf "$d"
  return $rc
}

test_fix_renames_never_deletes() {
  local d rc=0 out moved
  d=$(mktemp -d)
  _skill "$d" ticket-auto
  echo 'echo dash' >"$d/ticket-auto/dashboard.py"
  out=$(bash "$SS" fix --plugin-root "$PLUGIN_ROOT" --skills-dir "$d") || rc=1
  moved=$(ls "$d"/ticket-auto/SKILL.md.shadowed-* 2>/dev/null | head -1)
  {
    [ ! -e "$d/ticket-auto/SKILL.md" ] &&
      [ -n "$moved" ] && grep -q 'old body' "$moved" &&
      [ -f "$d/ticket-auto/dashboard.py" ] &&
      grep -qF "ticket-auto|moved|$moved" <<<"$out"
  } || rc=1
  # A second run finds nothing left.
  bash "$SS" fix --plugin-root "$PLUGIN_ROOT" --skills-dir "$d" >/dev/null || rc=1
  rm -rf "$d"
  return $rc
}

test_fix_keeps_symlinked_copy() {
  local d other rc=0 out
  d=$(mktemp -d)
  other=$(mktemp -d)
  _skill "$other" ticket-retro
  ln -s "$other/ticket-retro" "$d/ticket-retro"
  out=$(bash "$SS" fix --plugin-root "$PLUGIN_ROOT" --skills-dir "$d") && rc=1
  { [ -f "$other/ticket-retro/SKILL.md" ] && grep -q '^ticket-retro|kept|.*symlink' <<<"$out"; } || rc=1
  rm -rf "$d" "$other"
  return $rc
}

test_hook_moves_and_reports() {
  local d rc=0 out
  d=$(mktemp -d)
  _skill "$d" ticket-verify
  out=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" UNSHADOW_SKILLS_DIR="$d" bash "$HOOK") || rc=1
  {
    [ ! -e "$d/ticket-verify/SKILL.md" ] &&
      jq -e '.systemMessage | test("moved stale user-level skill copies aside.*ticket-verify")' <<<"$out" >/dev/null
  } || rc=1
  rm -rf "$d"
  return $rc
}

test_hook_warn_mode_moves_nothing() {
  local d rc=0 out
  d=$(mktemp -d)
  _skill "$d" ticket-verify
  out=$(TICKET_UNSHADOW=warn CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" UNSHADOW_SKILLS_DIR="$d" bash "$HOOK") || rc=1
  {
    [ -f "$d/ticket-verify/SKILL.md" ] &&
      jq -e '.systemMessage | test("still shadowing a plugin skill: ticket-verify")' <<<"$out" >/dev/null
  } || rc=1
  rm -rf "$d"
  return $rc
}

test_hook_silent_when_clean() {
  local d rc=0 out
  d=$(mktemp -d)
  _skill "$d" unrelated-skill
  out=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" UNSHADOW_SKILLS_DIR="$d" bash "$HOOK") || rc=1
  [ -z "$out" ] || rc=1
  rm -rf "$d"
  return $rc
}

test_hook_fails_open_without_plugin_lib() {
  local d rc=0
  d=$(mktemp -d)
  CLAUDE_PLUGIN_ROOT="$d/nowhere" UNSHADOW_SKILLS_DIR="$d" bash "$HOOK" >/dev/null || rc=1
  rm -rf "$d"
  return $rc
}

for fn in \
  test_list_finds_shadow_by_folder_and_by_name \
  test_list_ignores_synced_scripts \
  test_list_reports_app_knowledge_and_retired_names \
  test_keep_extra_exempts_a_name \
  test_fix_renames_never_deletes \
  test_fix_keeps_symlinked_copy \
  test_hook_moves_and_reports \
  test_hook_warn_mode_moves_nothing \
  test_hook_silent_when_clean \
  test_hook_fails_open_without_plugin_lib; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
