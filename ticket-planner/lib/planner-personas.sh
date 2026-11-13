#!/usr/bin/env bash
# planner-personas.sh — the job-function personas the planner borrows from the
# ticket-auto-pipeline plugin (openspec change planner-persona-panel).
#
# The persona files live in the sibling plugin
# (ticket-auto-pipeline/personas/base/*.md and specializers/<group>/*.md).
# This file finds them, picks the one an authoring phase reads as, and renders
# its text as a `## Your perspective` block. planner-panel.sh uses the same
# lookups for the review panel's seats.
#
# Bash reads the persona files and puts their text into the prompt. A spawned
# agent never opens a file of the sibling plugin, so the lookup works the same
# in a Dexter container, on a bare install and in a source checkout.
#
# Lookup order of the pipeline plugin root (design D2), first one that holds
# `personas/base`:
#   1. TICKET_AUTO_PLUGIN_ROOT
#   2. the directory beside the planner's own plugin root
#   3. the installed plugin path (installed_plugins.json, then the plugin
#      cache — planner_cache_find)
# None: "not available". One `META|persona|skip|NOT_AVAILABLE` line is written
# per initiative and the planner behaves as with the flags off.
#
# Persona per authoring phase (design D1):
#   Appraisal     product-owner
#   Discovery     analyzer
#   Architecture  architect + architect/<microservices|monolith> for the repo
#   Specify       backend-developer or frontend-developer + its specializer
#   EpicGen, TicketGen   technical-writer
#   Review, Consensus, Completed   none
#
# Public API:
#   planner_persona_phases_enabled       rc 0 when PLANNER_PHASE_PERSONAS=true
#   planner_persona_root                 the pipeline plugin root; rc 1 none
#   planner_persona_note_unavailable <INIT>   the one NOT_AVAILABLE line
#   planner_persona_repos <INIT> [<artifact>...]
#                                        git repositories under REPOS_ROOT the
#                                        named artifacts mention, in order of
#                                        first mention (default: proposal.md,
#                                        then appraisal.md)
#   planner_persona_layer <repo>         FE or BE
#   planner_persona_developer <repo> <layer>
#                                        the developer base and specializer
#                                        paths, one per line
#   planner_persona_for_phase <phase> [<repo>] [<layer>]
#                                        persona file paths, one per line;
#                                        nothing for a phase with no persona;
#                                        rc 1 when personas are not available
#   planner_persona_text <path>          the persona's text for a prompt
#   planner_persona_block <path>...      the `## Your perspective` block
#   planner_persona_apply <phase> <INIT> filter: the prompt on stdin, with the
#                                        block inserted before the last
#                                        `## Constraints` heading; unchanged
#                                        with the flag off or no persona
#
# Flag: PLANNER_PHASE_PERSONAS (default false), read where the prompt is built.
#
# Awk runs under LC_ALL=C and takes values only through ENVIRON.
#
# Sourceable library — no set -euo pipefail.

_PLANNER_PERSONAS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

declare -f planner_state_write >/dev/null 2>&1 ||
  source "${_PLANNER_PERSONAS_LIB_DIR}/planner-state.sh"
if ! declare -f planner_cache_find >/dev/null 2>&1 &&
  [ -f "${_PLANNER_PERSONAS_LIB_DIR}/planner-plugin-cache.sh" ]; then
  source "${_PLANNER_PERSONAS_LIB_DIR}/planner-plugin-cache.sh"
fi

PLANNER_PERSONA_PLUGIN="ticket-auto-pipeline"
PLANNER_PERSONA_PROBE="personas/base/product-owner.md"

planner_persona_phases_enabled() {
  [ "${PLANNER_PHASE_PERSONAS:-false}" = "true" ]
}

# _planner_persona_own_root — the planner's own plugin root (tests override it
# with PLANNER_PERSONA_OWN_ROOT).
_planner_persona_own_root() {
  printf '%s\n' "${PLANNER_PERSONA_OWN_ROOT:-${_PLANNER_PERSONAS_LIB_DIR}/..}"
}

# planner_persona_root — prints the pipeline plugin root, rc 1 when no lookup
# holds `personas/base`.
planner_persona_root() {
  local c found
  for c in "${TICKET_AUTO_PLUGIN_ROOT:-}" "$(_planner_persona_own_root)/../${PLANNER_PERSONA_PLUGIN}"; do
    [ -n "$c" ] || continue
    if [ -d "${c}/personas/base" ]; then
      (cd "$c" && pwd)
      return 0
    fi
  done
  if declare -f planner_cache_find >/dev/null 2>&1; then
    found=$(planner_cache_find "$PLANNER_PERSONA_PLUGIN" "$PLANNER_PERSONA_PROBE")
    if [ -n "$found" ] && [ -d "${found%/product-owner.md}" ]; then
      printf '%s\n' "${found%/"${PLANNER_PERSONA_PROBE}"}"
      return 0
    fi
  fi
  return 1
}

# planner_persona_note_unavailable <INIT> — one line per initiative.
planner_persona_note_unavailable() {
  local init="$1" log
  log=$(planner_state_log "$init" 2>/dev/null) || return 0
  if [ -f "$log" ] && grep -q '^[^|]*|META|persona|skip|NOT_AVAILABLE' "$log" 2>/dev/null; then
    return 0
  fi
  planner_state_write "$init" META persona skip \
    "NOT_AVAILABLE ${PLANNER_PERSONA_PLUGIN} personas not found; prompts unchanged, no panel" >/dev/null 2>&1
  return 0
}

# _planner_persona_file <root> <relative path under personas/> — the absolute
# path when the file exists, else nothing.
_planner_persona_file() {
  [ -f "$1/personas/$2" ] && printf '%s\n' "$1/personas/$2"
  return 0
}

# _planner_persona_git_repos — every git repository directly under REPOS_ROOT.
_planner_persona_git_repos() {
  local root d
  root=$(planner_repos_root 2>/dev/null) || return 0
  root="${root%/}"
  for d in "$root"/*/; do
    d="${d%/}"
    [ -d "$d" ] && [ -e "${d}/.git" ] && printf '%s\n' "$d"
  done | LC_ALL=C sort
}

# planner_persona_repos <INIT> [<artifact>...] — the repositories the named
# artifacts mention by directory name, one absolute path per line, in order of
# first mention. A name counts only as a whole token: not inside a longer name
# made of letters, digits, `_` or `-`.
planner_persona_repos() {
  local init="$1" dir f files=() repo name esc line
  shift
  dir=$(planner_initiative_dir "$init" 2>/dev/null) || return 0
  [ "$#" -gt 0 ] || set -- proposal.md appraisal.md
  for f in "$@"; do
    [ -f "${dir}/artifacts/${f}" ] && files+=("${dir}/artifacts/${f}")
  done
  [ "${#files[@]}" -gt 0 ] || return 0
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    name="${repo##*/}"
    esc=$(printf '%s' "$name" | sed 's/[][\.*^$+?(){}|/]/\\&/g')
    line=$(cat "${files[@]}" 2>/dev/null |
      LC_ALL=C grep -n -E "(^|[^A-Za-z0-9_-])${esc}(\$|[^A-Za-z0-9_-])" 2>/dev/null |
      head -1 | cut -d: -f1)
    [ -n "$line" ] && printf '%s\t%s\n' "$line" "$repo"
  done < <(_planner_persona_git_repos) | LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k2,2 | cut -f2
}

# planner_persona_layer <repo> — FE for a browser application (angular.json,
# or a package.json naming a browser framework with no backend build file),
# else BE.
planner_persona_layer() {
  local repo="$1" f
  if [ -f "${repo}/angular.json" ]; then
    echo FE
    return 0
  fi
  for f in pom.xml build.gradle build.gradle.kts pyproject.toml requirements.txt go.mod; do
    if [ -f "${repo}/${f}" ]; then
      echo BE
      return 0
    fi
  done
  if [ -f "${repo}/package.json" ] &&
    grep -qE '"(react|react-dom|vue|svelte|next|@angular/core)"' "${repo}/package.json" 2>/dev/null; then
    echo FE
    return 0
  fi
  echo BE
}

# _planner_persona_architect_specializer <root> <repo> — the same signals
# persona-select.sh reads for its architect specializers.
_planner_persona_architect_specializer() {
  local root="$1" repo="$2" hit n
  [ -n "$repo" ] && [ -d "$repo" ] || return 0
  hit=$(find "$repo" -maxdepth 2 -type d \( -name services -o -name apps -o -name packages \) 2>/dev/null | head -1)
  if [ -z "$hit" ] && [ -f "${repo}/docker-compose.yml" ]; then
    n=$(grep -cE '^[[:space:]]{2}[A-Za-z0-9_-]+:' "${repo}/docker-compose.yml" 2>/dev/null) || n=0
    [ "${n:-0}" -gt 2 ] 2>/dev/null && hit="compose"
  fi
  if [ -n "$hit" ]; then
    _planner_persona_file "$root" "specializers/architect/microservices.md"
  elif [ -f "${repo}/Dockerfile" ] || [ -f "${repo}/Makefile" ]; then
    _planner_persona_file "$root" "specializers/architect/monolith.md"
  fi
  return 0
}

# planner_persona_developer <repo> <layer> — the developer base persona and
# its stack specializer. persona-select.sh decides when it is there; without
# it (or without a repository) the base persona for the layer is used alone.
planner_persona_developer() {
  local repo="$1" layer="${2:-BE}" root sel out base spec
  root=$(planner_persona_root) || return 1
  sel="${root}/lib/persona-select.sh"
  if [ -n "$repo" ] && [ -d "$repo" ] && [ -f "$sel" ]; then
    out=$(env -u TICKET_TITLE -u TICKET_DESCRIPTION -u TICKET_TEXT_FILE -u TICKET_ID \
      CLAUDE_PLUGIN_ROOT="$root" bash "$sel" --repo "$repo" --layer "$layer" --phase implement 2>/dev/null) || out=""
    base=$(printf '%s\n' "$out" | sed -n 's/^PERSONA_BASE=//p' | head -1)
    spec=$(printf '%s\n' "$out" | sed -n 's/^PERSONA_SPECIALIZER=//p' | head -1)
    case "$spec" in */specializers/architect/*) spec="" ;; esac
    if [ -n "$base" ] && [ -f "$base" ]; then
      printf '%s\n' "$base"
      [ -n "$spec" ] && [ -f "$spec" ] && printf '%s\n' "$spec"
      return 0
    fi
  fi
  if [ "$layer" = "FE" ]; then
    _planner_persona_file "$root" "base/frontend-developer.md"
  else
    _planner_persona_file "$root" "base/backend-developer.md"
  fi
}

# planner_persona_for_phase <phase> [<repo>] [<layer>]
planner_persona_for_phase() {
  local phase="$1" repo="${2:-}" layer="${3:-}" root
  root=$(planner_persona_root) || return 1
  case "$phase" in
  Appraisal) _planner_persona_file "$root" "base/product-owner.md" ;;
  Discovery) _planner_persona_file "$root" "base/analyzer.md" ;;
  Architecture)
    _planner_persona_file "$root" "base/architect.md"
    _planner_persona_architect_specializer "$root" "$repo"
    ;;
  Specify)
    [ -n "$layer" ] || { [ -n "$repo" ] && layer=$(planner_persona_layer "$repo"); }
    planner_persona_developer "$repo" "${layer:-BE}"
    ;;
  EpicGen | TicketGen) _planner_persona_file "$root" "base/technical-writer.md" ;;
  *) ;;
  esac
  return 0
}

# planner_persona_text <path> — the persona's text without its YAML front
# matter and without the two sections that describe pipeline wiring
# (`## Preferred Tools`, `## Composition Note`). Headings are lowered two
# levels so they sit under the prompt's own `##` heading.
planner_persona_text() {
  [ -f "$1" ] || return 1
  # shellcheck disable=SC2016  # awk program, not shell
  LC_ALL=C awk '
    { sub(/\r$/, "") }
    NR == 1 && $0 == "---" { fm = 1; next }
    fm { if ($0 == "---") fm = 0; next }
    /^(```|~~~)/ { fence = !fence }
    !fence && /^## / {
      skip = ($0 ~ /^## (Preferred Tools|Composition Note)[ \t]*$/)
    }
    skip { next }
    !fence && /^#+ / { $0 = "##" $0 }
    { buf[++n] = $0 }
    END {
      first = 1
      while (first <= n && buf[first] == "") first++
      while (n >= first && buf[n] == "") n--
      for (i = first; i <= n; i++) print buf[i]
    }
  ' "$1"
}

# planner_persona_block <path>... — the block an authoring prompt gets. The
# priority line keeps a persona from replacing the phase's instructions.
planner_persona_block() {
  local p text any=0
  for p in "$@"; do
    [ -f "$p" ] || continue
    text=$(planner_persona_text "$p") || continue
    [ -n "$text" ] || continue
    if [ "$any" -eq 0 ]; then
      printf '## Your perspective\n\n'
      printf '%s\n' "This is how you look at the work. The phase's task above and its constraints" \
        "below decide what you produce; this perspective never changes the output format."
      any=1
    fi
    printf '\n%s\n' "$text"
  done
  [ "$any" -eq 1 ]
}

# planner_persona_apply <phase> <INIT> — stdin to stdout. With the flag off,
# no persona for the phase, no persona files, or no `## Constraints` heading
# outside a fence, the prompt passes through byte for byte.
planner_persona_apply() {
  local phase="$1" init="$2" prompt paths=() p repo="" block
  prompt=$(cat && printf x)
  prompt="${prompt%x}"
  if ! planner_persona_phases_enabled; then
    printf '%s' "$prompt"
    return 0
  fi
  case "$phase" in
  Appraisal | Discovery | Architecture | Specify | EpicGen | TicketGen) ;;
  *)
    printf '%s' "$prompt"
    return 0
    ;;
  esac
  if ! planner_persona_root >/dev/null; then
    planner_persona_note_unavailable "$init"
    printf '%s' "$prompt"
    return 0
  fi
  case "$phase" in
  Architecture | Specify) repo=$(planner_persona_repos "$init" proposal.md appraisal.md | head -1) ;;
  esac
  while IFS= read -r p; do
    [ -n "$p" ] && paths+=("$p")
  done < <(planner_persona_for_phase "$phase" "$repo")
  if [ "${#paths[@]}" -eq 0 ] || ! block=$(planner_persona_block "${paths[@]}"); then
    planner_state_write "$init" META persona skip \
      "${phase} NOT_AVAILABLE persona file not found; prompt unchanged" >/dev/null 2>&1
    printf '%s' "$prompt"
    return 0
  fi
  # shellcheck disable=SC2016  # awk program, not shell
  printf '%s' "$prompt" | PPB_BLOCK="$block" LC_ALL=C awk '
    { line[NR] = $0 }
    /^(```|~~~)/ { fence = !fence; next }
    !fence && /^## Constraints[ \t]*$/ { at = NR }
    END {
      for (i = 1; i <= NR; i++) {
        if (i == at) { print ENVIRON["PPB_BLOCK"]; print "" }
        print line[i]
      }
    }
  '
}
