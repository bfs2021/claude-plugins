#!/usr/bin/env bash
# test-planner-panel-wiring.sh — the wiring of planner-persona-panel (tasks
# 3.1–3.8):
#
#   - the Review `pre` gate: nothing with the flags off, the panel's own SPAWN
#     line, the combined line when the goldfish lens is due too, no line for
#     any other phase; a shell that sourced only the router can run NEXT/APPLY;
#   - planner_prompt_for_phase: every prompt equals its own prompt function
#     with the flags off; the persona block with PLANNER_PHASE_PERSONAS; the
#     Consensus panel section only for an initiative whose panel ran;
#   - planner_panel_dispositions and the Crosscheck family: PANEL_UNADDRESSED
#     (warn), PANEL_STOP_SKIPPED (blocking), silent without a panel run;
#   - the stop: a security blocker Consensus did not accept halts before
#     Crosscheck through its `panel.<ID>` parameter row; an accepted one and a
#     rejected QA blocker do not;
#   - the owner's answer through `resume --answers`: overrule continues,
#     uphold sends the plan back to Consensus once;
#   - the review trail: a spec's `## Review Trail` section reaches the ticket
#     body outside the Planner Context block.
#
# Run: bash ticket-planner/lib/tests/test-planner-panel-wiring.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ANSWERS="${LIB_DIR}/planner-answers.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export HOME="${WORK}/home"
mkdir -p "$HOME"
export REPOS_ROOT="${WORK}/repos"
mkdir -p "${REPOS_ROOT}/billing/.git"
: >"${REPOS_ROOT}/billing/pom.xml"
export CLAUDE_PLUGIN_ROOT
CLAUDE_PLUGIN_ROOT="$(cd "$LIB_DIR/.." && pwd)"
unset PLANNER_PHASE_PERSONAS PLANNER_PERSONA_PANEL PLANNER_PANEL_SEATS PLANNER_PANEL_TIMEOUT PLANNER_PANEL_AWK
unset PLANNER_GOLDFISH_REVIEW PLANNER_GOLDFISH_TIMEOUT TICKET_AUTO_PLUGIN_ROOT PLANNER_PERSONA_OWN_ROOT
unset TICKET_TITLE TICKET_DESCRIPTION TICKET_TEXT_FILE TICKET_ID

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-router.sh"
source "${LIB_DIR}/planner-crosscheck.sh"
source "${LIB_DIR}/planner-answers.sh"
source "${LIB_DIR}/planner-phase-prompts.sh"
source "${LIB_DIR}/planner-ticket-body.sh"
source "${SCRIPT_DIR}/halt-fixtures.sh"

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
check() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got [$2] want [$3]"; fi
}
contains() {
  case "$2" in
  *"$3"*) pass "$1" ;;
  *) fail "$1" "missing [$3] in [${2:0:400}]" ;;
  esac
}
lacks() {
  case "$2" in
  *"$3"*) fail "$1" "unexpected [$3]" ;;
  *) pass "$1" ;;
  esac
}

for fn in planner_panel_due planner_panel_next planner_panel_prompt_apply planner_crosscheck_panel \
  planner_panel_reopen_on_uphold planner_persona_apply; do
  if ! declare -f "$fn" >/dev/null; then
    fail "wiring" "$fn missing"
    echo "=== planner-panel-wiring: ${PASS} passed, ${FAIL} failed ==="
    exit 1
  fi
done

PLAN_HEAD=$'# Proposal\n\n## Scope\nThe billing service checks the login token before it pauses a subscription.\n\n## Business Outcomes\n\n### O1\n**Outcome:** A customer can pause a subscription.\n\n## Parameters\n\n'
PLAN_NONE="${PLAN_HEAD}None."$'\n'
TABLE=$'| Name | Key | Kind | Default | Value | Source |\n|------|-----|------|---------|-------|--------|\n'
ROW_OPEN='| Panel objection SEC-1 | `panel.SEC-1` | policy | keep the token in the URL for now | NEEDS_HUMAN_DECISION — The security reviewer objects: the token is sent in the URL. The plan proposes: keep it for now. Answer "uphold" to follow the objection, or "overrule: <reason>" to keep the plan. | — |'

N=0
# new_init [<phase>...] — a contract initiative with those phases done.
new_init() {
  N=$((N + 1))
  INIT="INIT-1700000000-$((5000 + N))"
  planner_state_init "$INIT" "Pause a subscription" >/dev/null 2>&1
  SD="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT}"
  mkdir -p "${SD}/artifacts/specs"
  LOG="${SD}/state.log"
  printf 'Pause a subscription\n' >"${SD}/artifacts/idea.txt"
  printf '%s' "$PLAN_NONE" >"${SD}/artifacts/proposal.md"
  planner_state_write "$INIT" META contract start specify-parameters-v1 >/dev/null 2>&1
  [ "$#" -gt 0 ] && _halt_done "$INIT" "$@"
  return 0
}
pn_lines() { grep '|META|panel|' "$LOG" | cut -d'|' -f4-; }
# seat_result <seat> <PREFIX> <"sev,sev" | none>
seat_result() {
  local seat="$1" prefix="$2" spec="$3" sha i=0 sev
  sha=$(planner_panel_sha12 "$INIT")
  mkdir -p "${SD}/panel"
  {
    printf '# Panel Review — %s\n\n**Proposal:** %s\n\n## Findings\n' "$seat" "$sha"
    if [ "$spec" = "none" ]; then printf 'None.\n'; else
      for sev in ${spec//,/ }; do
        i=$((i + 1))
        printf '### %s-%d — %s — Title %d\n**About:** proposal § Scope\n**Problem:** P.\n**Recommendation:** R.\n\n' \
          "$prefix" "$i" "$sev" "$i"
      done
    fi
    printf '\n## Files Read\n- %s/panel/input/proposal.md\n' "$SD"
  } >"${SD}/panel/review-${seat}.md"
}
# run_panel <security spec> <qa spec> — the panel as it runs before Review:
# PO and ARCH with no findings, security and QA as given, developer not run.
run_panel() {
  PLANNER_PERSONA_PANEL=true planner_panel_next "$INIT" >/dev/null 2>&1
  seat_result product-owner PO none
  seat_result architect ARCH none
  seat_result qa-engineer QA "$2"
  seat_result security SEC "$1"
  seat_result developer DEV none
  planner_panel_apply "$INIT"
}
STATUS_ALL=""
consensus() {
  # consensus <panel section body> — consensus.md with the status lines first.
  {
    printf '# Consensus\n\n## Findings Addressed\nNone.\n\n## Panel\n'
    planner_panel_status "$INIT"
    printf '%s\n' "$1"
    printf '\n## Readiness\nready-for-spec\n'
  } >"${SD}/artifacts/consensus.md"
}
gate() {
  local rc=0
  OUT=$(planner_dispatch_gate "$1" "$INIT" "$2" "$SD" 2>/dev/null) || rc=$?
  RC=$rc
}
xc() { planner_crosscheck_panel "$INIT"; }

echo "=== wiring: the Review pre gate (3.2) ==="

new_init Appraisal Discovery Architecture Specify
gate pre Review
check "flags off: nothing printed" "$RC|$OUT" "0|"
check "flags off: one skip line" "$(pn_lines)" "skip|$(planner_panel_sha12 "$INIT") DISABLED"
[ -d "${SD}/panel" ] && fail "flags off: no panel directory" "exists" || pass "flags off: no panel directory"

new_init Appraisal Discovery Architecture Specify
PLANNER_PERSONA_PANEL=true gate pre Review
check "panel on: its own SPAWN line" "$OUT" "SPAWN NEXT=planner_panel_next APPLY=planner_panel_apply TIMEOUT=600000"
PLANNER_PERSONA_PANEL=true PLANNER_PANEL_TIMEOUT=90 gate pre Review
check "PLANNER_PANEL_TIMEOUT" "$OUT" "SPAWN NEXT=planner_panel_next APPLY=planner_panel_apply TIMEOUT=90000"

new_init Appraisal Discovery Architecture Specify
PLANNER_PERSONA_PANEL=true PLANNER_GOLDFISH_REVIEW=true PLANNER_GOLDFISH_TIMEOUT=900 gate pre Review
check "both on: one combined line, the longer timeout" "$OUT" \
  "SPAWN NEXT=planner_review_lenses_next APPLY=planner_review_lenses_apply TIMEOUT=900000"

new_init Appraisal Discovery Architecture Specify
PLANNER_GOLDFISH_REVIEW=true gate pre Review
check "goldfish only: its line is unchanged" "$OUT" \
  "SPAWN NEXT=planner_goldfish_next APPLY=planner_goldfish_apply TIMEOUT=600000"

new_init Appraisal Discovery Architecture
PLANNER_PERSONA_PANEL=true gate pre Specify
check "another phase: nothing printed" "$OUT" ""
check "another phase: no panel line" "$(pn_lines)" ""

out=$(bash -c 'source "$1/planner-router.sh"; declare -f planner_panel_next planner_panel_apply planner_review_lenses_next planner_review_lenses_apply >/dev/null && echo ok' _ "$LIB_DIR")
check "a shell that sourced only the router has NEXT and APPLY" "$out" "ok"

echo "=== wiring: planner_prompt_for_phase (3.1, 3.3) ==="

# Resolve the plugin root in this shell: a prompt function called directly in
# a subshell would otherwise print an empty root.
planner_prompt_lib_root >/dev/null

new_init Appraisal Discovery Architecture Specify Review
printf 'Affected Services: billing\n' >"${SD}/artifacts/appraisal.md"
for ph in Appraisal Discovery Architecture Specify Review Consensus EpicGen TicketGen Completed; do
  fn="planner_prompt_$(printf '%s' "$ph" | tr '[:upper:]' '[:lower:]')"
  a=$(planner_prompt_for_phase "$ph" "$INIT" "an idea" "$SD" 2>/dev/null && printf x)
  b=$("$fn" "$INIT" "an idea" "$SD" 2>/dev/null && printf x)
  if [ -n "$b" ] && [ "$a" = "$b" ]; then pass "flags off: ${ph} prompt is its own prompt"; else
    fail "flags off: ${ph} prompt is its own prompt" "differs"
  fi
done

export PLANNER_PHASE_PERSONAS=true
for pair in "Appraisal:### Product Owner" "Discovery:### Analyzer" "Architecture:### Architect" \
  "Specify:### Backend Developer" "EpicGen:### Technical Writer" "TicketGen:### Technical Writer"; do
  ph="${pair%%:*}"
  p=$(planner_prompt_for_phase "$ph" "$INIT" "an idea" "$SD" 2>/dev/null)
  contains "personas on: ${ph}" "$p" "${pair#*:}"
  contains "personas on: ${ph} has the perspective heading" "$p" "## Your perspective"
  fn="planner_prompt_$(printf '%s' "$ph" | tr '[:upper:]' '[:lower:]')"
  stripped=$(printf '%s\n' "$p" | awk '
    /^## Your perspective$/ { skip = 1; next }
    skip && /^## Constraints[ \t]*$/ { skip = 0 }
    !skip { print }')
  check "personas on: the rest of the ${ph} prompt is unchanged" "$stripped" "$("$fn" "$INIT" "an idea" "$SD" 2>/dev/null)"
done
contains "personas on: Specify gets the Java specializer" \
  "$(planner_prompt_for_phase Specify "$INIT" "an idea" "$SD" 2>/dev/null)" "Java"
for ph in Review Consensus Completed; do
  fn="planner_prompt_$(printf '%s' "$ph" | tr '[:upper:]' '[:lower:]')"
  a=$(planner_prompt_for_phase "$ph" "$INIT" "an idea" "$SD" 2>/dev/null && printf x)
  b=$("$fn" "$INIT" "an idea" "$SD" 2>/dev/null && printf x)
  [ "$a" = "$b" ] && pass "personas on: ${ph} gets none" || fail "personas on: ${ph} gets none" "differs"
done
unset PLANNER_PHASE_PERSONAS

a=$(planner_prompt_for_phase Consensus "$INIT" "an idea" "$SD" 2>/dev/null)
lacks "no panel run: Consensus has no panel section" "$a" "## Review panel"
run_panel "blocker" "major"
a=$(planner_prompt_for_phase Consensus "$INIT" "an idea" "$SD" 2>/dev/null)
contains "panel ran: Consensus has the panel section" "$a" "## Review panel (planner-persona-panel)"
contains "panel ran: the status call names the initiative" "$a" "planner_panel_status \"${INIT}\""
contains "panel ran: the stop rule" "$a" 'panel.<ID>'
contains "panel ran: the review trail rule" "$a" '## Review Trail'
stripped=$(printf '%s\n' "$a" | awk '
  /^## Review panel \(planner-persona-panel\)$/ { skip = 1; next }
  skip && /^## Constraints[ \t]*$/ { skip = 0 }
  !skip { print }')
check "panel ran: the rest of the Consensus prompt is unchanged" "$stripped" \
  "$(planner_prompt_consensus "$INIT" "an idea" "$SD" 2>/dev/null)"
a=$(planner_prompt_for_phase TicketGen "$INIT" "an idea" "$SD" 2>/dev/null && printf x)
b=$(planner_prompt_ticketgen "$INIT" "an idea" "$SD" 2>/dev/null && printf x)
[ "$a" = "$b" ] && pass "panel ran: the Ticket Generation prompt is unchanged" ||
  fail "panel ran: the Ticket Generation prompt is unchanged" "differs"
planner_prompt_for_phase Nope "$INIT" "an idea" "$SD" >/dev/null 2>&1 &&
  fail "unknown phase still fails" "rc 0" || pass "unknown phase still fails"

echo "=== wiring: dispositions and the Crosscheck family (3.5) ==="

case " $PLANNER_CROSSCHECK_WARN_CODES " in
*" PANEL_UNADDRESSED "*) pass "PANEL_UNADDRESSED is warn-level" ;;
*) fail "PANEL_UNADDRESSED is warn-level" "not in the warn list" ;;
esac
case " $PLANNER_CROSSCHECK_WARN_CODES " in
*" PANEL_STOP_SKIPPED "*) fail "PANEL_STOP_SKIPPED blocks" "in the warn list" ;;
*) pass "PANEL_STOP_SKIPPED blocks" ;;
esac

new_init Appraisal Discovery Architecture Specify Review Consensus
check "no panel run: silent" "$(xc)" ""
gate pre Review >/dev/null 2>&1
check "panel disabled: silent" "$(xc)" ""

# SEC-1 blocker, QA-1 blocker + QA-2 major; the developer seat did not run.
new_init Appraisal Discovery Architecture Specify Review Consensus
PLANNER_PERSONA_PANEL=true planner_panel_next "$INIT" >/dev/null 2>&1
seat_result product-owner PO none
seat_result architect ARCH none
seat_result qa-engineer QA "blocker,major,minor"
seat_result security SEC "blocker"
planner_panel_apply "$INIT"
PLANNER_PERSONA_PANEL=true planner_panel_next "$INIT" >/dev/null 2>&1
planner_panel_apply "$INIT"
contains "fixture: developer not run" "$(pn_lines)" "developer NOT_RUN no-result"

consensus $'### SEC-1 — blocker — Title 1 — accepted\nMoved the token to a header.\n### QA-1 — blocker — Title 1 — rejected (covered in spec pause)\n### QA-2 — major — Title 2 — deferred (to the follow-up ticket)\nMinor/nit QA-3: deferred\n### Conflicts\nNone.'
d=$(planner_panel_dispositions "${SD}/artifacts/consensus.md")
contains "dispositions: status per seat" "$d" "status developer"
contains "dispositions: accepted" "$d" "disp SEC-1 accepted"
contains "dispositions: rejected" "$d" "disp QA-1 rejected"
contains "dispositions: deferred" "$d" "disp QA-2 deferred"
check "all settled, security accepted: clean" "$(xc)" ""

consensus $'### SEC-1 — blocker — Title 1 — accepted\n### QA-1 — blocker — Title 1 — rejected (covered in spec pause)'
check "a major finding with no disposition: one warning" "$(xc)" \
  "planner-crosscheck-panel: PANEL_UNADDRESSED consensus.md ## Panel: no disposition for QA-2"

{
  printf '# Consensus\n\n## Panel\n'
  planner_panel_status "$INIT" | grep -v 'developer'
  printf '### SEC-1 — blocker — T — accepted\n### QA-1 — blocker — T — rejected (x)\n### QA-2 — major — T — deferred\n'
} >"${SD}/artifacts/consensus.md"
check "a seat with no status line" "$(xc)" \
  "planner-crosscheck-panel: PANEL_UNADDRESSED consensus.md ## Panel: status line missing for developer"

printf '# Consensus\n\n## Findings Addressed\n### SEC-1 — blocker — T — accepted\n' >"${SD}/artifacts/consensus.md"
contains "headings outside ## Panel do not count" "$(xc)" "PANEL_STOP_SKIPPED consensus.md ## Panel: SEC-1"
contains "… and everything is unaddressed" "$(xc)" "no disposition for QA-1, QA-2, SEC-1"

consensus $'### SEC-1 — blocker — Title 1 — rejected (out of scope, proposal § Scope)\n### QA-1 — blocker — Title 1 — rejected (covered in spec pause)\n### QA-2 — major — Title 2 — deferred'
check "a security blocker Consensus rejected on its own: blocks; the QA blocker does not" "$(xc)" \
  "planner-crosscheck-panel: PANEL_STOP_SKIPPED consensus.md ## Panel: SEC-1"

consensus $'### SEC-1 — blocker — Title 1 — accepted in part (kept the URL fallback)\n### QA-1 — blocker — Title 1 — rejected (x)\n### QA-2 — major — Title 2 — deferred'
contains "accepted in part is not accepted in full" "$(xc)" "PANEL_STOP_SKIPPED consensus.md ## Panel: SEC-1"
contains "… and parses as partial" "$(planner_panel_dispositions "${SD}/artifacts/consensus.md")" "disp SEC-1 partial"

printf '%s%s%s\n' "$PLAN_HEAD" "$TABLE" "$ROW_OPEN" >"${SD}/artifacts/proposal.md"
check "the open panel row is a valid parameter row" "$(planner_params_invalid "$INIT")" ""
check "… and an open one" "$(planner_params_scan "$INIT" | cut -f1)" "panel.SEC-1"
check "stop rows: open" "$(planner_panel_stop_rows "$INIT")" "$(printf 'SEC-1\topen')"
check "a decision row carries the blocker: clean" "$(xc)" ""

row() { printf '| Panel objection SEC-1 | `panel.SEC-1` | policy | keep the token in the URL for now | %s | human:r1:operator |' "$1"; }
printf '%s%s%s\n' "$PLAN_HEAD" "$TABLE" "$(row 'overrule: internal network only')" >"${SD}/artifacts/proposal.md"
check "stop rows: overrule" "$(planner_panel_stop_rows "$INIT")" "$(printf 'SEC-1\toverrule')"
check "overruled by the owner: clean" "$(xc)" ""
printf '%s%s%s\n' "$PLAN_HEAD" "$TABLE" "$(row 'Uphold')" >"${SD}/artifacts/proposal.md"
check "stop rows: uphold" "$(planner_panel_stop_rows "$INIT")" "$(printf 'SEC-1\tuphold')"
check "upheld but not accepted: blocks" "$(xc)" \
  "planner-crosscheck-panel: PANEL_STOP_SKIPPED consensus.md ## Panel: SEC-1 (upheld by the owner, not accepted)"
consensus $'### SEC-1 — blocker — Title 1 — accepted\n### QA-1 — blocker — Title 1 — rejected (x)\n### QA-2 — major — Title 2 — deferred'
check "upheld and accepted: clean" "$(xc)" ""

# Through planner_crosscheck_run: the warn does not block, the stop does.
consensus $'### SEC-1 — blocker — Title 1 — rejected (x)\n### QA-1 — blocker — Title 1 — rejected (x)'
printf '%s' "$PLAN_NONE" >"${SD}/artifacts/proposal.md"
planner_crosscheck_run "$INIT" >/dev/null 2>&1
if grep -q '|META|crosscheck|fail|PANEL_STOP_SKIPPED ' "$LOG"; then pass "Crosscheck logs PANEL_STOP_SKIPPED as fail"; else
  fail "Crosscheck logs PANEL_STOP_SKIPPED as fail" "$(grep 'META|crosscheck' "$LOG" | tail -3)"
fi
if grep -q '|META|crosscheck|warn|info PANEL_UNADDRESSED ' "$LOG"; then pass "Crosscheck logs PANEL_UNADDRESSED as warn"; else
  fail "Crosscheck logs PANEL_UNADDRESSED as warn" "$(grep 'META|crosscheck' "$LOG" | tail -3)"
fi
contains "the findings report explains the stop" "$(planner_crosscheck_findings_report "$INIT" 2>/dev/null)" "only a person may settle"

echo "=== wiring: the stop before Crosscheck (3.3, 3.8) ==="

# Security blocker rejected by Consensus: the row halts the loop.
new_init Appraisal Discovery Architecture Specify Review
run_panel "blocker" "blocker"
_halt_done "$INIT" Consensus
consensus $'### SEC-1 — blocker — Title 1 — rejected (out of scope)\n### QA-1 — blocker — Title 1 — rejected (covered in spec pause)'
printf '%s%s%s\n' "$PLAN_HEAD" "$TABLE" "$ROW_OPEN" >"${SD}/artifacts/proposal.md"
gate specify Crosscheck
check "security blocker not accepted: halts before Crosscheck" "$RC" "3"
contains "the halt names the objection" "$OUT" "The security reviewer objects"
q=$(planner_stop_describe_json "$INIT" 2>/dev/null)
check "the stop describer asks one question for it" \
  "$(printf '%s' "$q" | jq -r '[.questions[]? | select(.binding == "specify-param:panel.SEC-1")] | length' 2>/dev/null)" "1"
ROUND=$(printf '%s' "$q" | jq -r '.round // 1' 2>/dev/null)
QID=$(printf '%s' "$q" | jq -r '.questions[]? | select(.binding == "specify-param:panel.SEC-1") | .id' 2>/dev/null)

answer() {
  jq -n --argjson round "$ROUND" --arg id "$QID" --arg value "$1" \
    '{schema_version: 1, round: $round,
      answers: [{id: $id, value: $value, answered_by: "U123", role: "operator", ts: "2026-11-13T19:30:00Z"}]}' \
    >"${WORK}/a.json"
  AOUT=$(bash "$ANSWERS" "$INIT" "${WORK}/a.json" 2>"${WORK}/err")
  ARC=$?
}

# Overrule: the plan continues, the reason is recorded with the finding's row.
answer "overrule: the service is on the internal network only"
check "overrule: intake accepts the answer" "$ARC" "0"
contains "overrule: the row holds the reason" "$(grep -F 'panel.SEC-1' "${SD}/artifacts/proposal.md")" \
  "overrule: the service is on the internal network only | human:r${ROUND}:operator |"
gate specify Crosscheck
check "overrule: no halt left" "$RC" "0"
check "overrule: the position stays at Crosscheck" "$(planner_position_derive "$INIT")" "Crosscheck"
check "overrule: Crosscheck is clean for the panel" "$(xc | grep -c PANEL_STOP_SKIPPED)" "0"
lacks "overrule: no reopen line" "$(cat "$LOG")" "panel-uphold"

# Uphold: Consensus runs again, once.
new_init Appraisal Discovery Architecture Specify Review
run_panel "blocker" "none"
_halt_done "$INIT" Consensus
consensus $'### SEC-1 — blocker — Title 1 — rejected (out of scope)'
printf '%s%s%s\n' "$PLAN_HEAD" "$TABLE" "$ROW_OPEN" >"${SD}/artifacts/proposal.md"
q=$(planner_stop_describe_json "$INIT" 2>/dev/null)
ROUND=$(printf '%s' "$q" | jq -r '.round // 1' 2>/dev/null)
QID=$(printf '%s' "$q" | jq -r '.questions[]? | select(.binding == "specify-param:panel.SEC-1") | .id' 2>/dev/null)
answer "uphold"
check "uphold: intake accepts the answer" "$ARC" "0"
contains "uphold: intake reports it" "$AOUT" "panel-uphold:SEC-1"
check "uphold: the position goes back to Consensus" "$(planner_position_derive "$INIT")" "Consensus"
contains "uphold: the reopen line" "$(grep '|Review|panel-uphold|done|' "$LOG")" "SEC-1 upheld by the owner"
check "uphold: human-hold done is still the last line" "$(tail -1 "$LOG" | cut -d'|' -f2-4)" "META|human-hold|done"
a=$(planner_prompt_for_phase Consensus "$INIT" "an idea" "$SD" 2>/dev/null)
contains "uphold: the Consensus prompt carries the rule for an upheld row" "$a" 'When its Value starts with `uphold`'
# Consensus runs again and accepts.
_halt_done "$INIT" Consensus
check "after the second Consensus: Crosscheck" "$(planner_position_derive "$INIT")" "Crosscheck"
check "no second reopen for the same finding" "$(planner_panel_reopen_on_uphold "$INIT")" ""
check "still one reopen" "$(grep -c '|Review|panel-uphold|done|' "$LOG")" "1"
contains "a Consensus that still does not accept is left to Crosscheck" "$(xc)" "SEC-1 (upheld by the owner, not accepted)"
consensus $'### SEC-1 — blocker — Title 1 — accepted\nThe token moved to a header.'
check "accepted on the second run: clean" "$(xc)" ""
gate specify Crosscheck
check "accepted on the second run: no halt" "$RC" "0"

# Accepted at once, and a rejected QA blocker: no decision, no halt.
new_init Appraisal Discovery Architecture Specify Review
run_panel "blocker" "blocker"
_halt_done "$INIT" Consensus
consensus $'### SEC-1 — blocker — Title 1 — accepted\n### QA-1 — blocker — Title 1 — rejected (covered in spec pause)'
gate specify Crosscheck
check "accepted security blocker and rejected QA blocker: no halt" "$RC" "0"
check "… and Crosscheck is clean" "$(xc)" ""
check "reopen does nothing without an upheld row" "$(planner_panel_reopen_on_uphold "$INIT")" ""

# Reopen is only for the Crosscheck position.
new_init Appraisal Discovery Architecture Specify
run_panel "blocker" "none"
printf '%s%s%s\n' "$PLAN_HEAD" "$TABLE" "$(row 'uphold')" >"${SD}/artifacts/proposal.md"
check "reopen: not before Consensus has run" "$(planner_panel_reopen_on_uphold "$INIT")" ""

echo "=== wiring: the review trail on a ticket (3.6) ==="

SPEC="${WORK}/pause.md"
cat >"$SPEC" <<'EOF'
# Pause a subscription

## Title
Pause a subscription

## Description
A customer pauses a subscription.

## Acceptance Criteria
- Given an active subscription, when the customer pauses it, then its status is `paused`.

## Review Trail
- QA-2 (qa-engineer): added acceptance criterion 1

## Labels
feature

## Verification Notes

| Criterion | Role | Test data | Source | Expected | Verifiable |
|-----------|------|-----------|--------|----------|------------|
| Given an active subscription, when the customer pauses it, then its status is `paused`. | customer | none | none | status `paused` | Y |
EOF
CTX=$'## Planner Context\n- **Initiative:** INIT-X'
body=$(planner_ticket_body_compose "$SPEC" "$CTX" 2>/dev/null)
contains "the trail is in the ticket body" "$body" "- QA-2 (qa-engineer): added acceptance criterion 1"
trail_line=$(printf '%s\n' "$body" | grep -n '^## Review Trail$' | cut -d: -f1)
ctx_line=$(printf '%s\n' "$body" | grep -n '^## Planner Context$' | cut -d: -f1)
if [ -n "$trail_line" ] && [ -n "$ctx_line" ] && [ "$trail_line" -lt "$ctx_line" ]; then
  pass "the trail sits outside (before) the Planner Context block"
else
  fail "the trail sits outside (before) the Planner Context block" "trail=${trail_line} ctx=${ctx_line}"
fi
check "the Planner Context block is the given one, verbatim" "$(printf '%s\n' "$body" | sed -n "${ctx_line:-1},\$p")" "$CTX"

echo ""
echo "=== planner-panel-wiring: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
