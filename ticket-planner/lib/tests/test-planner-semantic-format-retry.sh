#!/usr/bin/env bash
# test-planner-semantic-format-retry.sh — the DoR evaluator's validator-only
# format retry (seam-gate-safety G6, design D5) as the draft readiness gate
# and Refinement drive it through the shared spawn list.
#
# Covers, for both callers:
#   - a bulleted scan is sent back as a `format` spawn (the original block,
#     never the body) and judged on the re-serialised block, with no failed
#     attempt counted and no harness-error line;
#   - a retry that adds a finding is rejected: one
#     `META|harness-error|fail|<ticket> FORMAT_RETRY_EXHAUSTED <field>` line,
#     then the attempt fails exactly as before (unavailable after two);
#   - a format retry that writes nothing is the same exhaustion.
# Agents are stubbed. Usage: bash ticket-planner/lib/tests/test-planner-semantic-format-retry.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/draft-readiness-gate-harness.sh"

echo "=== DoR format retry through the spawn list (seam-gate-safety G6) ==="

# SLIP_<slug>=1: the scan is written with a "- " before every KEY line.
# FMT_<slug>: what the format agent writes — clean (default; the block
# without the bullets), add (clean plus an invented finding), none.
_orig_spawn_list="$(declare -f _spawn_list)"
eval "${_orig_spawn_list/_spawn_list/_base_spawn_list}"
_spawn_list() {
  local list="$1" slug kind type pf rf var mode
  _base_spawn_list "$(printf '%s\n' "$list" | awk -F'\t' '$2 != "format"')"
  while IFS=$'\t' read -r slug kind type pf rf; do
    [ -n "$slug" ] || continue
    var="SLIP_${slug//-/_}"
    if [ "$kind" = "scan" ] && [ "${!var:-}" = "1" ]; then
      sed -i -E 's/^([A-Z][A-Z0-9_]*[[:space:]]*:)/- \1/' "$rf"
    fi
    [ "$kind" = "format" ] || continue
    cp "$pf" "${TMP_ROOT}/format-prompt-${#FORMAT_PROMPTS[@]}.txt"
    FORMAT_PROMPTS+=("${TMP_ROOT}/format-prompt-${#FORMAT_PROMPTS[@]}.txt")
    var="FMT_${slug//-/_}"
    mode="${!var:-clean}"
    case "$mode" in
    none) ;;
    clean) sed -E 's/^- ([A-Z][A-Z0-9_]*[[:space:]]*:)/\1/' "${rf%.format-result.txt}.txt" >"$rf" ;;
    add)
      sed -E 's/^- ([A-Z][A-Z0-9_]*[[:space:]]*:)/\1/' "${rf%.format-result.txt}.txt" |
        sed 's/^=== END DOR_SEMANTIC_SCAN ===/FINDING_9_CODE: SCOPE_AMBIGUOUS\nFINDING_9_QUOTE: Export responds with 200\n&/' >"$rf"
      ;;
    esac
  done <<<"$list"
}
FORMAT_PROMPTS=()
_harness_lines() { grep -c '|META|harness-error|fail|' "$LOG"; }

# ── draft gate ────────────────────────────────────────────────────────────
echo "--- draft gate: a bulleted scan is re-serialised, not failed ---"
export SLIP_b_api=1
_gate
v=$(cut -d' ' -f3 "${DR}/b-api/verdict" 2>/dev/null)
if [ "$GATE_RC" -eq 0 ] && [ "$v" = "ready" ] && [ "$SPAWNS" -eq 5 ] &&
  [ "$(_planner_draft_attempts "$INIT" b-api "$(_hash_of b-api)")" = "0" ] && [ "$(_harness_lines)" = 0 ]; then
  pass "judged ready after one format spawn; no failed attempt, no harness-error line"
else
  fail "draft re-serialise" "rc=$GATE_RC verdict=$v spawns=$SPAWNS attempts=$(cat "${DR}/b-api/attempts" 2>/dev/null) $(tail -3 "$LOG")"
fi
p="${FORMAT_PROMPTS[0]:-}"
if [ -n "$p" ] && grep -q '^## DoR Semantic Format Retry' "$p" && grep -qxF -- "- SCHEMA_VERSION: 1" "$p" &&
  ! grep -qF "body.md" "$p" && ! grep -qF "Finance staff rebuild" "$p"; then
  pass "the format prompt holds the original block and no body"
else
  fail "draft prompt" "${p:-no prompt}"
fi
if [ -s "${DR}/b-api/scan-result.format-original.txt" ] && grep -q '^- SCHEMA_VERSION' "${DR}/b-api/scan-result.format-original.txt" &&
  ! grep -q '^- ' "${DR}/b-api/scan-result.txt"; then
  pass "the original block is kept beside the re-serialised result"
else
  fail "draft original kept" "$(ls "${DR}/b-api")"
fi

echo "--- draft gate: a retry that adds a finding is rejected ---"
sed -i 's/Export responds with 200/Export responds with HTTP 200/' "${SPECS}/b-api.md"
FORMAT_PROMPTS=()
export FMT_b_api=add PLANNER_DRAFT_WARN_CODES=none
_gate
v=$(cut -d' ' -f3 "${DR}/b-api/verdict" 2>/dev/null)
if [ "$GATE_RC" -eq 3 ] && [ "$v" = "unavailable" ] && [ "$(_harness_lines)" = 2 ] &&
  grep -q '|META|harness-error|fail|DRAFT-b-api FORMAT_RETRY_EXHAUSTED SCHEMA_VERSION$' "$LOG" &&
  [ "${#FORMAT_PROMPTS[@]}" -eq 2 ] && [ "$SPAWNS" -eq 6 ]; then
  pass "two attempts, one rejected retry each: two harness-error lines, then unavailable as before"
  # seam-gate-safety G5: the exhaustion is the attempt's reason.
  jq -e '.reason | startswith("FORMAT_RETRY_EXHAUSTED SCHEMA_VERSION; ")' "${DR}/b-api/semantic.json" >/dev/null &&
    pass "the unavailable reason names FORMAT_RETRY_EXHAUSTED" ||
    fail "draft exhausted reason" "$(cat "${DR}/b-api/semantic.json")"
else
  fail "draft add" "rc=$GATE_RC verdict=$v spawns=$SPAWNS formats=${#FORMAT_PROMPTS[@]} $(grep harness-error "$LOG")"
fi
if [ -s "${DR}/b-api/scan-result.rejected.txt" ] && grep -q '^- SCHEMA_VERSION' "${DR}/b-api/scan-result.rejected.txt" &&
  [ ! -e "${DR}/b-api/scan-result.format.json" ]; then
  pass "the rejected original is kept, the retry state is cleared"
else
  fail "draft rejected kept" "$(ls "${DR}/b-api")"
fi

echo "--- draft gate: a format agent that writes nothing ---"
sed -i 's/Export responds with HTTP 200/Export responds with status 200/' "${SPECS}/b-api.md"
export FMT_b_api=none
_gate
v=$(cut -d' ' -f3 "${DR}/b-api/verdict" 2>/dev/null)
if [ "$GATE_RC" -eq 3 ] && [ "$v" = "unavailable" ] && [ "$(_harness_lines)" = 4 ]; then
  pass "no retry result: harness-error per attempt, then unavailable"
else
  fail "draft none" "rc=$GATE_RC verdict=$v $(grep -c harness-error "$LOG")"
fi
unset SLIP_b_api FMT_b_api PLANNER_DRAFT_WARN_CODES

echo "--- the knob is checked when the gate starts ---"
rc=0
DOR_SEMANTIC_FORMAT_RETRIES=x planner_draft_readiness_begin "$INIT" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] && pass "DOR_SEMANTIC_FORMAT_RETRIES=x: begin refuses (rc 1)" || fail "knob" "rc=$rc"

# ── Refinement ────────────────────────────────────────────────────────────
echo "--- Refinement: the same retry through step 1b's spawn list ---"
# Its own REPOS_ROOT: the gate's end-of-file check wants no ticket manifest.
GATE_REPOS_ROOT="$REPOS_ROOT"
export REPOS_ROOT="${TMP_ROOT}/repos-refinement"
mkdir -p "$REPOS_ROOT"
FIXTURES="${LIB_DIR}/../../ticket-auto-pipeline/lib/tests/fixtures/dor"
R_INIT="INIT-1700000003-3333"
R_EPIC="PRO-500"
R_TID="PRO-501"
planner_state_init "$R_INIT" "format retry idea" >/dev/null
planner_state_write "$R_INIT" "EpicGen" "create" "done" "EPIC_ID=${R_EPIC}"
planner_state_write "$R_INIT" "TicketGen" "verify" "done" "ok"
write_epic_manifest "$R_EPIC" "" "per-ticket" "" '[]' >/dev/null
write_ticket_manifest "$R_TID" "$R_INIT" "feature" '[]' >/dev/null
add_epic_manifest_child "$R_EPIC" "$R_TID" >/dev/null
RP="${REPOS_ROOT}/.ticket-auto/initiatives/${R_INIT}/tickets/${R_TID}/planner"
RLOG="${REPOS_ROOT}/.ticket-auto/initiatives/${R_INIT}/state.log"
mkdir -p "$RP"
cp "${FIXTURES}/22-sourced-contract.md" "${RP}/body.md"

# The scan stub writes a bulleted block; FMT_R picks the format agent.
_r_spawn() {
  local tid kind agent pf rf
  while IFS=$'\t' read -r tid kind agent pf rf; do
    [ -n "$tid" ] || continue
    case "$kind" in
    scan)
      printf '%s\n' "=== DOR_SEMANTIC_SCAN ===" "- SCHEMA_VERSION: 1" \
        "- PARAPHRASE: The ticket makes one change, described consistently." \
        "- GAP_REQUIREMENT_COMPLETENESS: clear" "- GAP_REQUIREMENT_COMPLETENESS_REASON: covered" \
        "- GAP_CONTRADICTORY_REQUIREMENTS: clear" "- GAP_CONTRADICTORY_REQUIREMENTS_REASON: covered" \
        "- GAP_DEEP_SCOPE_AMBIGUITY: clear" "- GAP_DEEP_SCOPE_AMBIGUITY_REASON: covered" \
        "- GAP_EDGE_CASE_SUFFICIENCY: clear" "- GAP_EDGE_CASE_SUFFICIENCY_REASON: covered" \
        "=== END DOR_SEMANTIC_SCAN ===" >"$rf"
      ;;
    audit)
      printf '%s\n' "=== DOR_SEMANTIC_AUDIT ===" "SCHEMA_VERSION: 1" "SCORE_PLAUSIBLE: yes" \
        "SCORE_REASON: matches" "=== END DOR_SEMANTIC_AUDIT ===" >"$rf"
      ;;
    format)
      case "${FMT_R:-clean}" in
      clean) sed -E 's/^- //' "${rf%.format-result.txt}.txt" >"$rf" ;;
      add) sed -E 's/^- //' "${rf%.format-result.txt}.txt" |
        sed 's/^=== END DOR_SEMANTIC_SCAN ===/FINDING_1_CODE: SCOPE_AMBIGUOUS\nFINDING_1_QUOTE: invented\n&/' >"$rf" ;;
      esac
      ;;
    esac
  done <<<"$1"
}
# _r_run — prepare, then step 1e until done; sets R_KINDS (every spawned kind).
_r_run() {
  local l i
  R_KINDS=""
  PLANNER_REFINEMENT_DRIFT_CHECK=false planner_refinement_prepare "$R_INIT" >/dev/null 2>&1 || return 1
  for i in 1 2 3 4 5 6 7 8; do
    l=$(planner_refinement_next "$R_INIT" 2>/dev/null) || return 1
    [ "$l" = "done 0" ] && return 0
    R_KINDS+="$(printf '%s\n' "$l" | cut -f2 | tr '\n' ' ')"
    _r_spawn "$l"
    planner_refinement_apply_pending "$R_INIT" >/dev/null 2>&1
  done
  return 1
}
_r_harness() { grep -c '|META|harness-error|fail|' "$RLOG"; }

_r_run
ready=$(get_ticket_manifest_field "$R_TID" ready 2>/dev/null)
if [ "$R_KINDS" = "scan audit format " ] && jq -e '.semantic.findings == [] and (.semantic.unavailable // false) == false' <<<"$ready" >/dev/null &&
  [ ! -e "${RP}/semantic-attempts" ] && [ "$(_r_harness)" = 0 ]; then
  pass "Refinement: scan, audit, one format spawn; judged with no failed attempt"
else
  fail "refinement re-serialise" "kinds=$R_KINDS attempts=$(cat "${RP}/semantic-attempts" 2>/dev/null) $(jq -c '.semantic | {unavailable, findings}' <<<"$ready")"
fi
grep -q 'semantic-scan-result.format-prompt.txt' <<<"$(ls "$RP")" &&
  fail "refinement prompt left" "$(ls "$RP")" || pass "Refinement: no retry state left after acceptance"

echo "- an edit" >>"${RP}/body.md"
FMT_R=add _r_run
ready=$(get_ticket_manifest_field "$R_TID" ready 2>/dev/null)
if jq -e '.missing | index("SEMANTIC_UNAVAILABLE") != null' <<<"$ready" >/dev/null && [ "$(_r_harness)" = 2 ] &&
  grep -q "|META|harness-error|fail|${R_TID} FORMAT_RETRY_EXHAUSTED SCHEMA_VERSION$" "$RLOG" &&
  [ "$(cat "${RP}/semantic-attempts")" = 2 ]; then
  pass "Refinement: a rejected retry per attempt, harness-error lines, then SEMANTIC_UNAVAILABLE as before"
  # seam-gate-safety G5: a harness error, with each attempt's reason.
  jq -e '.harness_error.code == "SEMANTIC_UNAVAILABLE" and .harness_error.attempts == 2
      and ([.harness_error.reasons[] | select(test("FORMAT_RETRY_EXHAUSTED SCHEMA_VERSION"))] | length) == 2' <<<"$ready" >/dev/null &&
    pass "Refinement: ready.harness_error carries FORMAT_RETRY_EXHAUSTED for both attempts" ||
    fail "refinement harness_error" "$(jq -c .harness_error <<<"$ready")"
else
  fail "refinement add" "kinds=$R_KINDS harness=$(_r_harness) attempts=$(cat "${RP}/semantic-attempts" 2>/dev/null) $(jq -c .missing <<<"$ready")"
fi
rc=0
DOR_SEMANTIC_FORMAT_RETRIES=9 planner_refinement_prepare "$R_INIT" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] && pass "Refinement: prepare refuses a bad DOR_SEMANTIC_FORMAT_RETRIES" || fail "refinement knob" "rc=$rc"

export REPOS_ROOT="$GATE_REPOS_ROOT"
_gate_finish 3
