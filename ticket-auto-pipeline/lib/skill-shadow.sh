#!/usr/bin/env bash
# skill-shadow.sh — find, and on request move aside, user-level SKILL.md files
# that shadow this plugin's skills.
#
# A ~/.claude/skills/<name>/SKILL.md whose skill name matches one of the
# plugin's skills takes priority over the plugin's copy, with no warning. An
# old copy left there (from the pre-plugin install, or kept alive by a dotfiles
# repo) silently runs instead of the current skill: in one run a stale
# ticket-auto router without router-step.sh routed a 16/16 VERIFY PASS as a
# FAIL. The lib-sync SessionStart hook makes this easier to hit, because it
# creates ~/.claude/skills/ticket-auto/ and the other per-skill folders for its
# scripts, so a stray SKILL.md there looks like an ordinary user skill.
#
# A user skill's name is its frontmatter `name:`, else its folder name; both
# are compared with the plugin's skill names.
#
# Also reported: SKILL_SHADOW_RETIRED, former names of marketplace skills
# (ticket-fleet-controller, now fleet-controller:fleet-controller). Such a copy
# shadows nothing by name, but it is an old duplicate that still loads.
#
# app-knowledge gets no exemption. Its project data lives in
# {TICKETS_ROOT}/app-knowledge.md; a ~/.claude/skills/app-knowledge/SKILL.md is
# an old copy from when the pipeline wrote it there. Moving it aside keeps the
# text (copy it into that project's tickets root by hand).
# $SKILL_SHADOW_KEEP_EXTRA (space separated names) exempts a copy kept on purpose.
#
# Functions:
#   skill_shadow_plugin_names PLUGIN_ROOT   plugin skill names, one per line
#   skill_shadow_list PLUGIN_ROOT [SKILLS_DIR]
#                                           "name<TAB>path" per shadowing
#                                           SKILL.md (SKILLS_DIR defaults to
#                                           ~/.claude/skills)
#   skill_shadow_move PATH                  renames PATH to
#                                           PATH.shadowed-<UTC stamp>, never
#                                           deletes; prints the new path.
#                                           Refuses a symlinked file or folder
#                                           (rc 3): that copy is managed
#                                           elsewhere, so it is only reported.
#
# CLI: skill-shadow.sh list|fix [--plugin-root DIR] [--skills-dir DIR]
#   --plugin-root defaults to this file's plugin (../), else the path in
#   ~/.claude/skills/lib/.plugin-root. Output "<name>|<path>" (list) or
#   "<name>|moved|<new path>" / "<name>|kept|<path>|<reason>" (fix).
#   Exit 0 none found (list) or none left (fix), 1 some remain, 2 usage.
# No set -e at file scope: env-check.sh and the hook source this.

_SS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_SHADOW_RETIRED="ticket-fleet-controller"

_skill_shadow_name_of() {
  local f="$1" n
  n=$(awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} NR>1 && /^name:[ \t]*/{sub(/^name:[ \t]*/,""); gsub(/["\047\r]/,""); sub(/[ \t]+$/,""); print; exit}' "$f" 2>/dev/null)
  printf '%s\n' "${n:-$(basename "$(dirname "$f")")}"
}

skill_shadow_plugin_names() {
  local root="$1" f
  [ -d "$root/skills" ] || return 1
  for f in "$root"/skills/*/SKILL.md; do
    [ -f "$f" ] || continue
    _skill_shadow_name_of "$f"
    basename "$(dirname "$f")"
  done | sort -u
}

skill_shadow_list() {
  local root="$1" dir="${2:-$HOME/.claude/skills}" names f name base
  [ -d "$dir" ] || return 0
  names=$(skill_shadow_plugin_names "$root") || return 1
  names=$(printf '%s\n' "$names" $SKILL_SHADOW_RETIRED | sort -u)
  local keep
  for keep in ${SKILL_SHADOW_KEEP_EXTRA:-}; do
    names=$(grep -vxF -- "$keep" <<<"$names" || true)
  done
  [ -n "$names" ] || return 0
  for f in "$dir"/*/SKILL.md; do
    [ -e "$f" ] || continue
    name=$(_skill_shadow_name_of "$f")
    base=$(basename "$(dirname "$f")")
    if grep -qxF -- "$name" <<<"$names" || grep -qxF -- "$base" <<<"$names"; then
      printf '%s\t%s\n' "$name" "$f"
    fi
  done
}

skill_shadow_move() {
  local f="$1" dest
  [ -f "$f" ] || return 1
  if [ -L "$f" ] || [ -L "$(dirname "$f")" ]; then
    return 3
  fi
  dest="$f.shadowed-$(date -u +%Y%m%dT%H%M%SZ)"
  mv -n -- "$f" "$dest" 2>/dev/null || return 1
  [ -e "$f" ] && return 1
  printf '%s\n' "$dest"
}

_skill_shadow_default_root() {
  if [ -d "$_SS_DIR/../skills" ]; then
    (cd "$_SS_DIR/.." && pwd)
  elif [ -f "$HOME/.claude/skills/lib/.plugin-root" ]; then
    head -1 "$HOME/.claude/skills/lib/.plugin-root"
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _ss_mode="${1:-}"
  shift || true
  _ss_root="" _ss_dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --plugin-root) _ss_root="${2:-}" && shift 2 || shift ;;
    --skills-dir) _ss_dir="${2:-}" && shift 2 || shift ;;
    *)
      echo "skill-shadow: unexpected argument: $1" >&2
      exit 2
      ;;
    esac
  done
  case "$_ss_mode" in list | fix) ;; *)
    echo "usage: skill-shadow.sh list|fix [--plugin-root DIR] [--skills-dir DIR]" >&2
    exit 2
    ;;
  esac
  _ss_root="${_ss_root:-$(_skill_shadow_default_root)}"
  if [ -z "$_ss_root" ] || [ ! -d "$_ss_root/skills" ]; then
    echo "skill-shadow: plugin root not found (pass --plugin-root)" >&2
    exit 2
  fi
  _ss_left=0
  while IFS=$'\t' read -r _ss_name _ss_path; do
    [ -z "$_ss_path" ] && continue
    if [ "$_ss_mode" = list ]; then
      echo "${_ss_name}|${_ss_path}"
      _ss_left=1
      continue
    fi
    _ss_rc=0
    _ss_new=$(skill_shadow_move "$_ss_path") || _ss_rc=$?
    if [ "$_ss_rc" -eq 0 ]; then
      echo "${_ss_name}|moved|${_ss_new}"
    else
      _ss_why="move failed"
      [ "$_ss_rc" -eq 3 ] && _ss_why="symlink — managed elsewhere, remove it there"
      echo "${_ss_name}|kept|${_ss_path}|${_ss_why}"
      _ss_left=1
    fi
  done < <(skill_shadow_list "$_ss_root" "${_ss_dir:-$HOME/.claude/skills}")
  exit "$_ss_left"
fi
