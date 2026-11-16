#!/usr/bin/env bash
# test-planner-semantic-harness-errors.sh — seam-gate-safety slice 3 (G5,
# design D4): an evaluator that could not judge is a harness error, never a
# plan defect and never a clean pass.
#
# Draft gate (7 drafts, stubbed agents):
#   - 1 of 7 unevaluated: the run passes and says so (UNEVALUATED 1/7);
#   - 2 of 7 unevaluated: the run halts with HARNESS_ERROR before any Linear
#     write;
#   - PLANNER_DRAFT_WARN_CODES exported empty still warns; `none` blocks;
#   - an unreadable PLANNER_DRAFT_UNEVALUATED_MAX_SHARE fails the config check.
# Refinement (2 children):
#   - two failed attempts: ready.harness_error with the reasons, rejected
#     files kept, the gate does not halt the epic, the ticket stays not
#     ready, the report has `## Not evaluated (harness error)`;
#   - a harness error next to a real missing code still halts;
#   - an unbacked gap (SEMANTIC_UNVERIFIED) is a harness error too;
#   - a resume after Completed retries the unevaluated child only.
# planner-run-report.sh: the `Unevaluated:` line.
#
# Usage: bash ticket-planner/lib/tests/test-planner-semantic-harness-errors.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/draft-readiness-gate-harness.sh"

echo "=== semantic harness errors (seam-gate-safety G5) ==="
export PLANNER_REFINEMENT_PARALLEL=8
unset PLANNER_DRAFT_WARN_CODES PLANNER_DRAFT_UNEVALUATED_MAX_SHARE

for _s in c d e f g; do
  _spec "${_s}-ui" "Finance sees the ${_s} panel" "planned, feature" \
    "- [ ] The ${_s} panel lists unpaid invoices"
done
# A harmless edit (the Summary line) makes a draft stale.
_edit() { sed -i "s/^Finance sees the $1 panel, in plain language\..*/Finance sees the $1 panel, in plain language. ${2}/" "${SPECS}/$1-ui.md"; }
_report() { planner_draft_readiness_report "$INIT"; }

echo "--- draft gate ---"
_gate
if [ "$GATE_RC" -eq 0 ] && [ "$SPAWNS" -eq 14 ]; then
  pass "seven clean drafts pass"
else
  fail "clean prelude" "rc=$GATE_RC spawns=$SPAWNS $(tail -3 "$LOG")"
fi

_edit c "first"
BROKEN_c_ui=1 _gate
if [ "$GATE_RC" -eq 0 ] && grep -q '|META|draft-readiness|warn|(run) UNEVALUATED 1/7 c-ui$' "$LOG" &&
  grep -q 'Unevaluated drafts: 1/7' <<<"$(_report)"; then
  pass "1 of 7 unevaluated: passes, logged and reported as unevaluated"
else
  fail "1 of 7" "rc=$GATE_RC $(grep -c UNEVALUATED "$LOG") $(tail -4 "$LOG")"
fi

_edit c "second"
_edit d "second"
BROKEN_c_ui=1 BROKEN_d_ui=1 _gate
report=$(_report)
if [ "$GATE_RC" -eq 3 ] && grep -q '|META|draft-readiness|fail|(run) HARNESS_ERROR 2/7 unevaluated$' "$LOG" &&
  tail -1 "$LOG" | grep -q '|META|draft-readiness|done|blocked 0/7 HARNESS_ERROR$' &&
  grep -q 'HARNESS_ERROR: 2/7 unevaluated' <<<"$report" && grep -q '^Run-level:' <<<"$report" &&
  [ ! -s "$LINEAR_CALLS" ]; then
  pass "2 of 7 unevaluated: HARNESS_ERROR halt, no Linear call"
else
  fail "2 of 7" "rc=$GATE_RC $(tail -3 "$LOG") | $report"
fi
if grep -q '^attempt 2: ' "${DR}/c-ui/last-failure" && [ -s "${DR}/c-ui/scan-result.rejected.txt" ]; then
  pass "the halted drafts keep their failure reason and rejected results"
else
  fail "draft diagnostics" "$(ls "${DR}/c-ui")"
fi

_edit c "third"
export PLANNER_DRAFT_WARN_CODES="" PLANNER_DRAFT_UNEVALUATED_MAX_SHARE=1
BROKEN_c_ui=1 _gate
if [ "$GATE_RC" -eq 0 ] && tail -4 "$LOG" | grep -q '|META|draft-readiness|warn|c-ui SEMANTIC_UNAVAILABLE '; then
  pass "PLANNER_DRAFT_WARN_CODES exported empty still warns"
else
  fail "empty warn codes" "rc=$GATE_RC $(tail -4 "$LOG")"
fi

_edit c "fourth"
export PLANNER_DRAFT_WARN_CODES=none
BROKEN_c_ui=1 _gate
if [ "$GATE_RC" -eq 3 ] && grep -q '|META|draft-readiness|fail|c-ui SEMANTIC_UNAVAILABLE ' <<<"$(tail -4 "$LOG")"; then
  pass "PLANNER_DRAFT_WARN_CODES=none makes a harness error block"
else
  fail "none" "rc=$GATE_RC $(tail -4 "$LOG")"
fi
unset PLANNER_DRAFT_WARN_CODES PLANNER_DRAFT_UNEVALUATED_MAX_SHARE

for _v in abc 1.5 -0.1; do
  rc=0
  PLANNER_DRAFT_UNEVALUATED_MAX_SHARE="$_v" planner_draft_readiness_begin "$INIT" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] && pass "PLANNER_DRAFT_UNEVALUATED_MAX_SHARE=${_v}: begin refuses" || fail "share ${_v}" "rc=$rc"
done
if PLANNER_DRAFT_UNEVALUATED_MAX_SHARE=abc _planner_draft_share_exceeded 0 7; then
  pass "an unreadable share counts as exceeded (fail closed)"
else
  fail "share fail-closed" "not exceeded"
fi

_gate
d_line=$(bash "${LIB_DIR}/planner-run-report.sh" "$INIT" --no-sync 2>/dev/null | grep '^Unevaluated:')
if [ "$GATE_RC" -eq 0 ] && grep -q '^Unevaluated: drafts 0/7, tickets 0, harness-error lines 0 — nothing unevaluated$' <<<"$d_line"; then
  pass "run report after a clean gate run: nothing unevaluated"
else
  fail "run report clean" "rc=$GATE_RC $d_line"
fi
_edit c "fifth"
BROKEN_c_ui=1 _gate
d_line=$(bash "${LIB_DIR}/planner-run-report.sh" "$INIT" --no-sync 2>/dev/null | grep '^Unevaluated:')
grep -q '^Unevaluated: drafts 1/7, .* not a clean run$' <<<"$d_line" &&
  pass "run report: 1/7 unevaluated drafts is not a clean run" || fail "run report draft" "$d_line"

# ── Refinement ────────────────────────────────────────────────────────────
echo "--- Refinement ---"
GATE_REPOS_ROOT="$REPOS_ROOT"
export REPOS_ROOT="${TMP_ROOT}/repos-refinement"
mkdir -p "$REPOS_ROOT"
FIXTURES="${LIB_DIR}/../../ticket-auto-pipeline/lib/tests/fixtures/dor"
R_INIT="INIT-1700000005-5555"
R_EPIC="PRO-600"
T1="PRO-601"
T2="PRO-602"
planner_state_init "$R_INIT" "harness error idea" >/dev/null
planner_state_write "$R_INIT" "EpicGen" "create" "done" "EPIC_ID=${R_EPIC}"
planner_state_write "$R_INIT" "TicketGen" "verify" "done" "ok"
write_epic_manifest "$R_EPIC" "" "per-ticket" "" '[]' >/dev/null
for _t in "$T1" "$T2"; do
  write_ticket_manifest "$_t" "$R_INIT" "feature" '[]' >/dev/null
  add_epic_manifest_child "$R_EPIC" "$_t" >/dev/null
  mkdir -p "${REPOS_ROOT}/.ticket-auto/initiatives/${R_INIT}/tickets/${_t}/planner"
  cp "${FIXTURES}/22-sourced-contract.md" "${REPOS_ROOT}/.ticket-auto/initiatives/${R_INIT}/tickets/${_t}/planner/body.md"
done
P2="${REPOS_ROOT}/.ticket-auto/initiatives/${R_INIT}/tickets/${T2}/planner"
RLOG="${REPOS_ROOT}/.ticket-auto/initiatives/${R_INIT}/state.log"

# R_MODE_<n> (n = ticket number): good (default), garbage, gap (a gap marked
# finding with no finding behind it).
_r_spawn() {
  local tid kind agent pf rf var mode gv
  while IFS=$'\t' read -r tid kind agent pf rf; do
    [ -n "$tid" ] || continue
    var="R_MODE_${tid#PRO-}"
    mode="${!var:-good}"
    if [ "$mode" = "garbage" ]; then
      echo "garbage" >"$rf"
      continue
    fi
    case "$kind" in
    scan)
      gv=clear
      [ "$mode" = "gap" ] && gv=finding
      printf '%s\n' "=== DOR_SEMANTIC_SCAN ===" "SCHEMA_VERSION: 1" \
        "PARAPHRASE: The ticket makes one change, described consistently." \
        "GAP_REQUIREMENT_COMPLETENESS: clear" "GAP_REQUIREMENT_COMPLETENESS_REASON: covered" \
        "GAP_CONTRADICTORY_REQUIREMENTS: clear" "GAP_CONTRADICTORY_REQUIREMENTS_REASON: covered" \
        "GAP_DEEP_SCOPE_AMBIGUITY: clear" "GAP_DEEP_SCOPE_AMBIGUITY_REASON: covered" \
        "GAP_EDGE_CASE_SUFFICIENCY: ${gv}" "GAP_EDGE_CASE_SUFFICIENCY_REASON: covered" \
        "=== END DOR_SEMANTIC_SCAN ===" >"$rf"
      ;;
    audit)
      printf '%s\n' "=== DOR_SEMANTIC_AUDIT ===" "SCHEMA_VERSION: 1" "SCORE_PLAUSIBLE: yes" \
        "SCORE_REASON: matches" "=== END DOR_SEMANTIC_AUDIT ===" >"$rf"
      ;;
    esac
  done <<<"$1"
}
_r_run() {
  local l i
  PLANNER_REFINEMENT_DRIFT_CHECK=false planner_refinement_prepare "$R_INIT" >/dev/null 2>&1 || return 1
  for i in 1 2 3 4 5 6 7 8; do
    l=$(planner_refinement_next "$R_INIT" 2>/dev/null) || return 1
    [ "$l" = "done 0" ] && return 0
    _r_spawn "$l"
    planner_refinement_apply_pending "$R_INIT" >/dev/null 2>&1
  done
  return 1
}
_r_ready() { get_ticket_manifest_field "$1" ready 2>/dev/null; }

R_MODE_602=garbage _r_run
r2=$(_r_ready "$T2")
fin_rc=0
fin=$(planner_refinement_finish "$R_INIT" "$(planner_initiative_dir "$R_INIT")" 2>/dev/null) || fin_rc=$?
if jq -e '.status == "not-ready" and .harness_error.code == "SEMANTIC_UNAVAILABLE" and .harness_error.attempts == 2
    and (.harness_error.reasons | length) == 2 and (.missing | index("SEMANTIC_UNAVAILABLE")) != null' <<<"$r2" >/dev/null; then
  pass "two failed attempts: ready.harness_error (2 attempts, 2 reasons), still not ready"
else
  fail "harness_error" "$(jq -c '{status, missing, harness_error}' <<<"$r2")"
fi
if [ -s "${P2}/semantic-scan-result.rejected.txt" ] && [ -s "${P2}/semantic-audit-result.rejected.txt" ]; then
  pass "the rejected result files are kept"
else
  fail "rejected kept" "$(ls "$P2")"
fi
if [ "$fin_rc" -eq 0 ] && grep -q "|Refinement|gate|done|1 of 2 tickets ready, 1 not evaluated (harness error), epic ${R_EPIC} stamped dispatch=true$" "$RLOG" &&
  grep -q "|META|refinement-gate|warn|1 of 2 not evaluated (harness error): ${T2}$" "$RLOG" &&
  grep -q '^## Not evaluated (harness error)$' <<<"$fin" && grep -q "^- ${T2} SEMANTIC_UNAVAILABLE: " <<<"$fin" &&
  ! grep -q '|META|refinement-gate|fail|' "$RLOG"; then
  pass "the gate does not halt the epic; the pass output lists the unevaluated ticket"
else
  fail "gate" "rc=$fin_rc $(tail -3 "$RLOG") | $fin"
fi
rep=$(planner_refinement_report "$R_INIT")
if grep -q '^## Not evaluated (harness error)$' <<<"$rep" && ! grep -q "^## ${T2}$" <<<"$rep"; then
  pass "the halt report lists it only under ## Not evaluated (harness error)"
else
  fail "report" "$rep"
fi
u_line=$(bash "${LIB_DIR}/planner-run-report.sh" "$R_INIT" --no-sync 2>/dev/null | grep '^Unevaluated:')
grep -q "tickets 1 (${T2}), .* not a clean run$" <<<"$u_line" &&
  pass "run report: 1 unevaluated ticket, not a clean run" || fail "run report ticket" "$u_line"

planner_state_write "$R_INIT" "Completed" "summary" "done" "fixture"
if planner_refinement_after_completed_pending "$R_INIT"; then
  pass "after Completed, an unevaluated child makes a resume re-run Refinement"
else
  fail "after-completed pending" "not pending"
fi
REFINEMENT_AFTER_COMPLETED=true _r_run
pass_list=$(cat "${REPOS_ROOT}/.ticket-auto/initiatives/${R_INIT}/refinement-pass" 2>/dev/null)
r2=$(_r_ready "$T2")
if jq -e '.status == "ready" and (.harness_error // null) == null' <<<"$r2" >/dev/null &&
  [ -z "$pass_list" ] && ! grep -q "refinement-round|done|${T1} .*round=2" "$RLOG" &&
  ! planner_refinement_after_completed_pending "$R_INIT"; then
  pass "the resume re-judged only the unevaluated child; it is ready and nothing is pending"
else
  fail "after-completed retry" "$(jq -c '{status, missing, harness_error}' <<<"$r2")"
fi

echo "--- a harness error next to a real code still halts ---"
cp "${FIXTURES}/21-unsourced-contract.md" "${P2}/body.md"
R_INIT_STATE_BEFORE=$(wc -l <"$RLOG")
# A fresh (not Completed) initiative view: drop the Completed line.
sed -i '/|Completed|summary|done|/d' "$RLOG"
R_MODE_602=garbage _r_run
fin_rc=0
fin=$(planner_refinement_finish "$R_INIT" "$(planner_initiative_dir "$R_INIT")" 2>/dev/null) || fin_rc=$?
if [ "$fin_rc" -eq 3 ] && grep -q "^## ${T2}$" <<<"$fin" && grep -q 'TEST_DATA_UNSOURCED' <<<"$fin"; then
  pass "TEST_DATA_UNSOURCED plus a harness error: halts as an ordinary not-ready ticket"
else
  fail "mixed halt" "rc=$fin_rc $fin"
fi

echo "--- an unbacked gap is a harness error ---"
cp "${FIXTURES}/22-sourced-contract.md" "${P2}/body.md"
echo "" >>"${P2}/body.md"
echo "One more sentence." >>"${P2}/body.md"
R_MODE_602=gap _r_run
r2=$(_r_ready "$T2")
fin_rc=0
fin=$(planner_refinement_finish "$R_INIT" "$(planner_initiative_dir "$R_INIT")" 2>/dev/null) || fin_rc=$?
if jq -e '.status == "not-ready" and .harness_error.code == "SEMANTIC_UNVERIFIED" and .missing == ["SEMANTIC_UNVERIFIED"]' <<<"$r2" >/dev/null &&
  [ "$fin_rc" -eq 0 ] && grep -q "^- ${T2} SEMANTIC_UNVERIFIED: " <<<"$fin"; then
  pass "SEMANTIC_UNVERIFIED alone: harness_error, not ready, the epic is not halted"
else
  fail "unverified gap" "rc=$fin_rc $(jq -c '{status, missing, harness_error}' <<<"$r2") | $fin"
fi
_uv_lines() { grep -c "|META|harness-error|warn|${T2} SEMANTIC_UNVERIFIED " "$RLOG"; }
before=$(_uv_lines)
rc=0
R_MODE_602=gap _r_run || rc=$?
if [ "$rc" -eq 0 ] && [ "$(_uv_lines)" -eq $((before + 1)) ]; then
  pass "a resume re-judges an unverified verdict on the same body"
else
  fail "unverified retry" "rc=$rc before=$before after=$(_uv_lines)"
fi

export REPOS_ROOT="$GATE_REPOS_ROOT"
_gate_finish 7
