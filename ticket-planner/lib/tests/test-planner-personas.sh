#!/usr/bin/env bash
# test-planner-personas.sh — the persona lookups of planner-personas.sh
# (planner-persona-panel, tasks 2.1, 2.6, 3.1):
#
#   - root lookup: TICKET_AUTO_PLUGIN_ROOT, the sibling directory, the
#     installed plugin path, and none (one NOT_AVAILABLE line);
#   - the persona of each authoring phase, the architect and developer
#     specializers, no persona for Review, Consensus and Completed;
#   - the affected-repository scan and the layer rule;
#   - the persona text (front matter and wiring sections left out) and the
#     `## Your perspective` block;
#   - planner_persona_apply: byte-identical with the flag off, the block
#     before the last `## Constraints` heading with it on, unchanged when the
#     personas are missing.
#
# Every case is guarded on the functions it needs, so on a checkout without
# the lib this file prints FAIL lines and a non-zero summary.
#
# Run: bash ticket-planner/lib/tests/test-planner-personas.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REAL_PIPELINE="$(cd "${LIB_DIR}/../.." && pwd)/ticket-auto-pipeline"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export HOME="${WORK}/home"
mkdir -p "$HOME"
export REPOS_ROOT="${WORK}/repos"
mkdir -p "$REPOS_ROOT"
unset PLANNER_PHASE_PERSONAS PLANNER_PERSONA_PANEL TICKET_AUTO_PLUGIN_ROOT PLANNER_PERSONA_OWN_ROOT
unset TICKET_TITLE TICKET_DESCRIPTION TICKET_TEXT_FILE TICKET_ID CLAUDE_PLUGIN_ROOT

source "${LIB_DIR}/planner-state.sh"
[ -f "${LIB_DIR}/planner-personas.sh" ] && source "${LIB_DIR}/planner-personas.sh"

PASS=0
FAIL=0
pass() {
  echo "  PASS $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "  FAIL $1: $2"
  FAIL=$((FAIL + 1))
}
need() {
  local name="$1" fn
  shift
  for fn in "$@"; do
    if ! declare -f "$fn" >/dev/null; then
      fail "$name" "$fn missing"
      return 1
    fi
  done
  return 0
}
check() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got [$2] want [$3]"; fi
}
contains() {
  case "$2" in
  *"$3"*) pass "$1" ;;
  *) fail "$1" "missing [$3] in [$2]" ;;
  esac
}
lacks() {
  case "$2" in
  *"$3"*) fail "$1" "unexpected [$3] in [$2]" ;;
  *) pass "$1" ;;
  esac
}

# A planner root with no pipeline plugin beside it: lookups 2 and 3 miss
# unless a case sets them up.
ALONE="${WORK}/alone/ticket-planner"
mkdir -p "$ALONE"

N=0
new_init() {
  N=$((N + 1))
  INIT="INIT-personas-${N}"
  planner_state_init "$INIT" "an idea" >/dev/null 2>&1
  SD="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT}"
  mkdir -p "${SD}/artifacts/specs"
  LOG="${SD}/state.log"
}

# Repositories: a Java backend, an Angular frontend, a services monorepo, and
# one whose name is a prefix of another.
mkdir -p "${REPOS_ROOT}/billing/.git" "${REPOS_ROOT}/web/.git" "${REPOS_ROOT}/platform/.git" \
  "${REPOS_ROOT}/platform/services/a" "${REPOS_ROOT}/web-admin/.git" "${REPOS_ROOT}/notes"
: >"${REPOS_ROOT}/billing/pom.xml"
: >"${REPOS_ROOT}/billing/Dockerfile"
: >"${REPOS_ROOT}/web/angular.json"
printf '{"dependencies":{"react":"18"}}\n' >"${REPOS_ROOT}/web-admin/package.json"

echo "=== planner-personas: root lookup (2.1) ==="

name="lookup 1: TICKET_AUTO_PLUGIN_ROOT"
if need "$name" planner_persona_root; then
  mkdir -p "${WORK}/cfg/personas/base"
  got=$(PLANNER_PERSONA_OWN_ROOT="$ALONE" TICKET_AUTO_PLUGIN_ROOT="${WORK}/cfg" planner_persona_root)
  check "$name" "$got" "${WORK}/cfg"
  got=$(PLANNER_PERSONA_OWN_ROOT="$ALONE" TICKET_AUTO_PLUGIN_ROOT="${WORK}/nowhere" planner_persona_root) &&
    fail "a configured root without personas/ is not used" "$got" ||
    pass "a configured root without personas/ is not used"
fi

name="lookup 2: beside the planner's own root"
if need "$name" planner_persona_root; then
  got=$(planner_persona_root)
  check "$name (this checkout)" "$got" "$REAL_PIPELINE"
  mkdir -p "${WORK}/pair/ticket-planner" "${WORK}/pair/ticket-auto-pipeline/personas/base"
  got=$(PLANNER_PERSONA_OWN_ROOT="${WORK}/pair/ticket-planner" planner_persona_root)
  check "$name" "$got" "${WORK}/pair/ticket-auto-pipeline"
fi

name="lookup 3: the installed plugin path"
if need "$name" planner_persona_root; then
  inst="${HOME}/.claude/plugins/cache/mkt/ticket-auto-pipeline/1.2.3"
  mkdir -p "${inst}/personas/base"
  : >"${inst}/personas/base/product-owner.md"
  got=$(PLANNER_PERSONA_OWN_ROOT="$ALONE" planner_persona_root)
  check "$name" "$got" "$inst"
  rm -rf "${HOME}/.claude"
fi

name="no lookup holds personas: rc 1, one NOT_AVAILABLE line"
if need "$name" planner_persona_root planner_persona_note_unavailable; then
  PLANNER_PERSONA_OWN_ROOT="$ALONE" planner_persona_root >/dev/null &&
    fail "$name: rc" "0" || pass "$name: rc"
  new_init
  planner_persona_note_unavailable "$INIT"
  planner_persona_note_unavailable "$INIT"
  check "$name: one line" "$(grep -c '|META|persona|skip|NOT_AVAILABLE' "$LOG")" "1"
fi

echo "=== planner-personas: repositories and layer ==="

name="repositories in order of first mention, whole names only"
if need "$name" planner_persona_repos planner_persona_layer; then
  new_init
  printf '# Proposal\nThe web-admin page changes.\nThen billing stores it.\nnotes are not a repo.\n' \
    >"${SD}/artifacts/proposal.md"
  got=$(planner_persona_repos "$INIT" proposal.md | sed "s#${REPOS_ROOT}/##" | paste -sd, -)
  check "$name" "$got" "web-admin,billing"
  printf 'Affected: platform\n' >"${SD}/artifacts/appraisal.md"
  got=$(planner_persona_repos "$INIT" | sed "s#${REPOS_ROOT}/##" | paste -sd, -)
  check "default artifacts: proposal.md then appraisal.md" "$got" "web-admin,billing,platform"
  check "no artifact, no repository" "$(planner_persona_repos "$INIT" missing.md)" ""
  check "layer: pom.xml is BE" "$(planner_persona_layer "${REPOS_ROOT}/billing")" "BE"
  check "layer: angular.json is FE" "$(planner_persona_layer "${REPOS_ROOT}/web")" "FE"
  check "layer: react package.json is FE" "$(planner_persona_layer "${REPOS_ROOT}/web-admin")" "FE"
  check "layer: nothing known is BE" "$(planner_persona_layer "${REPOS_ROOT}/platform")" "BE"
fi

echo "=== planner-personas: persona per phase (2.6) ==="

rel() { sed "s#${REAL_PIPELINE}/personas/##" | paste -sd, -; }

name="each authoring phase"
if need "$name" planner_persona_for_phase; then
  check "Appraisal" "$(planner_persona_for_phase Appraisal | rel)" "base/product-owner.md"
  check "Discovery" "$(planner_persona_for_phase Discovery | rel)" "base/analyzer.md"
  check "Architecture, no repository" "$(planner_persona_for_phase Architecture | rel)" "base/architect.md"
  check "Architecture, services monorepo" \
    "$(planner_persona_for_phase Architecture "${REPOS_ROOT}/platform" | rel)" \
    "base/architect.md,specializers/architect/microservices.md"
  check "Architecture, single service" \
    "$(planner_persona_for_phase Architecture "${REPOS_ROOT}/billing" | rel)" \
    "base/architect.md,specializers/architect/monolith.md"
  check "Specify, Java backend" \
    "$(planner_persona_for_phase Specify "${REPOS_ROOT}/billing" | rel)" \
    "base/backend-developer.md,specializers/backend/java.md"
  check "Specify, Angular frontend" \
    "$(planner_persona_for_phase Specify "${REPOS_ROOT}/web" | rel)" \
    "base/frontend-developer.md,specializers/frontend/angular.md"
  check "Specify, no repository" "$(planner_persona_for_phase Specify | rel)" "base/backend-developer.md"
  check "EpicGen" "$(planner_persona_for_phase EpicGen | rel)" "base/technical-writer.md"
  check "TicketGen" "$(planner_persona_for_phase TicketGen | rel)" "base/technical-writer.md"
  for ph in Review Consensus Completed Crosscheck Refinement; do
    check "${ph} has no persona" "$(planner_persona_for_phase "$ph")" ""
  done
  PLANNER_PERSONA_OWN_ROOT="$ALONE" planner_persona_for_phase Appraisal >/dev/null &&
    fail "personas not available: rc 1" "0" || pass "personas not available: rc 1"
fi

echo "=== planner-personas: text and block ==="

name="persona text"
if need "$name" planner_persona_text planner_persona_block; then
  t=$(planner_persona_text "${REAL_PIPELINE}/personas/base/security.md")
  contains "$name: title, two levels down" "$t" "### Security"
  contains "$name: principles kept" "$t" "#### Core Principles"
  lacks "$name: no front matter" "$t" "auto-include-when"
  lacks "$name: no Preferred Tools" "$t" "Preferred Tools"
  lacks "$name: no Composition Note" "$t" "Composition Note"
  check "$name: starts at the title" "$(printf '%s\n' "$t" | head -1)" "### Security"
  planner_persona_text "${WORK}/missing.md" >/dev/null 2>&1 &&
    fail "$name: missing file rc" "0" || pass "$name: missing file rc"

  b=$(planner_persona_block "${REAL_PIPELINE}/personas/base/architect.md" \
    "${REAL_PIPELINE}/personas/specializers/architect/microservices.md")
  check "block heading first" "$(printf '%s\n' "$b" | head -1)" "## Your perspective"
  contains "block priority line" "$b" "decide what you produce"
  contains "block: base" "$b" "### Architect"
  check "block: one heading" "$(printf '%s\n' "$b" | grep -c '^## ')" "1"
  planner_persona_block "${WORK}/missing.md" >/dev/null &&
    fail "block with no readable file: rc 1" "0" || pass "block with no readable file: rc 1"
fi

echo "=== planner-personas: apply (3.1) ==="

PROMPT=$'You are the phase agent.\n\n## Your task\n\n1. Do it.\n\n```\n## Constraints\n```\n\n## Constraints\n- Be exact.\n'

name="flag off: byte-identical"
if need "$name" planner_persona_apply; then
  new_init
  for ph in Appraisal Discovery Architecture Specify Review Consensus EpicGen TicketGen Completed; do
    got=$(printf '%s' "$PROMPT" | planner_persona_apply "$ph" "$INIT" && printf x)
    check "$name: ${ph}" "$got" "${PROMPT}x"
  done
  check "$name: nothing logged" "$(grep -c '|META|persona|' "$LOG")" "0"
fi

name="flag on: the block sits before the last Constraints heading"
if need "$name" planner_persona_apply; then
  new_init
  printf 'Affected Services: billing\n' >"${SD}/artifacts/appraisal.md"
  export PLANNER_PHASE_PERSONAS=true
  got=$(printf '%s' "$PROMPT" | planner_persona_apply Architecture "$INIT")
  contains "$name: architect" "$got" "### Architect"
  contains "$name: specializer for the affected repository" "$got" "Monolith"
  # The fenced `## Constraints` is not the anchor.
  before=$(printf '%s\n' "$got" | sed -n '1,/^## Your perspective$/p')
  contains "$name: after the task" "$before" "1. Do it."
  contains "$name: after the fenced heading" "$before" '```'
  after=$(printf '%s\n' "$got" | sed -n '/^## Your perspective$/,$p')
  contains "$name: constraints follow" "$after" "- Be exact."
  stripped=$(printf '%s\n' "$got" | awk '
    /^## Your perspective$/ { skip = 1; next }
    skip && /^## Constraints$/ { skip = 0 }
    !skip { print }')
  check "$name: the rest of the prompt is unchanged" "$stripped" "$(printf '%s' "$PROMPT")"
  for ph in Review Consensus Completed; do
    got=$(printf '%s' "$PROMPT" | planner_persona_apply "$ph" "$INIT" && printf x)
    check "flag on: ${ph} unchanged" "$got" "${PROMPT}x"
  done
  got=$(printf '%s' "$PROMPT" | planner_persona_apply Appraisal "$INIT")
  contains "flag on: Appraisal reads as the product owner" "$got" "### Product Owner"
  got=$(printf '%s' "$PROMPT" | planner_persona_apply TicketGen "$INIT")
  contains "flag on: TicketGen reads as the technical writer" "$got" "### Technical Writer"
  got=$(printf 'no anchor here\n' | planner_persona_apply Appraisal "$INIT")
  check "flag on: a prompt without the anchor is unchanged" "$got" "no anchor here"
  unset PLANNER_PHASE_PERSONAS
fi

name="flag on, personas missing: unchanged, one line"
if need "$name" planner_persona_apply; then
  new_init
  export PLANNER_PHASE_PERSONAS=true PLANNER_PERSONA_OWN_ROOT="$ALONE"
  for ph in Appraisal Discovery; do
    got=$(printf '%s' "$PROMPT" | planner_persona_apply "$ph" "$INIT" && printf x)
    check "$name: ${ph}" "$got" "${PROMPT}x"
  done
  check "$name: one NOT_AVAILABLE line" "$(grep -c '|META|persona|skip|NOT_AVAILABLE' "$LOG")" "1"
  unset PLANNER_PHASE_PERSONAS PLANNER_PERSONA_OWN_ROOT
fi

echo ""
echo "=== planner-personas: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
