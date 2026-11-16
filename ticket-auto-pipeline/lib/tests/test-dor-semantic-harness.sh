#!/usr/bin/env bash
# test-dor-semantic-harness.sh — the evaluator-side half of seam-gate-safety
# slice 3 (G5, design D4):
#   - the looser quote re-check in dor_semantic_findings: enclosing quotes,
#     an ellipsis and edge punctuation no longer make a real quote
#     unverified; a quote the body does not hold still fails;
#   - an advisory-code finding with an unverified quote no longer raises
#     SEMANTIC_UNVERIFIED, while a blocking-code finding still raises it and
#     keeps its own SEMANTIC_<DIMENSION> code;
#   - ready.harness_error (set_ticket_harness_error): written and cleared on
#     its own, never changes missing/status, dropped by a fresh verdict,
#     carried only while the semantic verdict is carried unstaled.
# Deterministic: canned blocks from fixtures/dor/semantic stand in for the
# agent. Usage: bash test-dor-semantic-harness.sh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES_DIR="$LIB_DIR/tests/fixtures/dor"
SEMANTIC_DIR="$FIXTURES_DIR/semantic"
PARSER="$LIB_DIR/dor-semantic-parse.sh"

source "$LIB_DIR/dor-semantic.sh"

PASS=0
FAIL=0
_pass() {
  echo "PASS: $1"
  ((PASS++)) || true
}
_fail() {
  echo "FAIL: $1"
  ((FAIL++)) || true
}

TMP_ROOT=$(mktemp -d)
export REPOS_ROOT="$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT
unset DOR_SEMANTIC_ADVISORY_CODES DOR_STRICT_TEST_DATA

BODY="$FIXTURES_DIR/27-planned-all-none-miss.md"
HASH=$(_dor_body_hash "$(cat "$BODY")")
REAL_AC="Duplicating a handover from the list creates a draft copy with the same line items"

# _scan <tid> <code> <quote> — fixture 27's scan with FINDING_1 replaced.
_scan() {
  sed -e "s|@TICKET@|$1|" -e "s|@BODY_HASH@|$HASH|" \
    -e "s|^FINDING_1_CODE: .*|FINDING_1_CODE: $2|" \
    -e "s|^FINDING_1_QUOTE: .*|FINDING_1_QUOTE: $3|" \
    "$SEMANTIC_DIR/27-scan.txt" >"$TMP_ROOT/$1-scan.txt"
  sed -e "s|@TICKET@|$1|" -e "s|@BODY_HASH@|$HASH|" "$SEMANTIC_DIR/27-audit.txt" >"$TMP_ROOT/$1-audit.txt"
}

# _judge <tid> <code> <quote> — dor_semantic_findings for that one finding;
# prints its JSON.
_judge() {
  local s a
  _scan "$1" "$2" "$3"
  s=$(bash "$PARSER" --kind scan --result-file "$TMP_ROOT/$1-scan.txt" 2>/dev/null) || return 10
  a=$(bash "$PARSER" --kind audit --result-file "$TMP_ROOT/$1-audit.txt" 2>/dev/null) || return 11
  dor_semantic_findings "$1" "$(cat "$BODY")" "$s" "$a" 2>/dev/null
}

# _apply <tid> <code> <quote> — a fresh manifest, then dor_semantic_apply.
_apply() {
  local s a
  write_ticket_manifest "$1" "INIT-1" feature '[]' >/dev/null
  set_ticket_readiness "$1" "ready" '[]' '[]' "{\"body_hash\": \"${HASH}\"}" >/dev/null
  _scan "$1" "$2" "$3"
  s=$(bash "$PARSER" --kind scan --result-file "$TMP_ROOT/$1-scan.txt" 2>/dev/null) || return 10
  a=$(bash "$PARSER" --kind audit --result-file "$TMP_ROOT/$1-audit.txt" 2>/dev/null) || return 11
  dor_semantic_apply "$1" "$BODY" "$s" "$a" >/dev/null 2>&1
}

_ready() { get_ticket_manifest_field "$1" ready; }

echo "=== looser quote re-check ==="

j=$(_judge Q-1 TEST_DATA_GAP "\"Duplicating a handover from the list creates a draft copy …\"")
if [ "$(jq -r '.findings[0].verified' <<<"$j")" = "true" ] &&
  [ "$(jq -r '.findings[0].quote_check' <<<"$j")" = "loose" ] &&
  [ "$(jq -r '.findings[0].quote' <<<"$j")" = "Duplicating a handover from the list creates a draft copy" ] &&
  jq -e '.findings[0].quote_raw | startswith("\"Duplicating")' <<<"$j" >/dev/null; then
  _pass "a quote wrapped in quotes with a trailing ellipsis verifies (loose), matched text stored"
else
  _fail "wrapped quote with ellipsis should verify ($j)"
fi

j=$(_judge Q-2 TEST_DATA_GAP "Duplicating a handover from the list ... with the same line items.")
[ "$(jq -r '.findings[0].verified' <<<"$j")" = "true" ] &&
  _pass "a mid-quote ellipsis: both pieces in order verify" ||
  _fail "mid-quote ellipsis should verify ($j)"

j=$(_judge Q-3 TEST_DATA_GAP "the handover detail page gains an Archive action … The handover list gains a Duplicate action")
[ "$(jq -r '.findings[0].verified' <<<"$j")" = "false" ] &&
  _pass "pieces out of order stay unverified" ||
  _fail "out-of-order pieces should stay unverified ($j)"

j=$(_judge Q-4 TEST_DATA_GAP "\"Duplicating …\"")
[ "$(jq -r '.findings[0].verified' <<<"$j")" = "false" ] &&
  _pass "a remainder under ${DOR_SEMANTIC_LOOSE_QUOTE_MIN} characters stays unverified" ||
  _fail "a short remainder should stay unverified ($j)"

j=$(_judge Q-5 TEST_DATA_GAP "Duplicating a handover from the list creates a draft copy with identical line items")
if [ "$(jq -r '.findings[0].verified' <<<"$j")" = "false" ] &&
  [ "$(jq -r '.findings[0].quote_check' <<<"$j")" = "unverified-quote" ]; then
  _pass "a reworded quote stays unverified and is marked unverified-quote"
else
  _fail "a reworded quote should stay unverified ($j)"
fi

j=$(_judge Q-6 TEST_DATA_GAP "duplicating a handover from the list creates a draft copy")
[ "$(jq -r '.findings[0].verified' <<<"$j")" = "false" ] &&
  _pass "case is not folded" || _fail "a lower-cased quote should stay unverified ($j)"

j=$(_judge Q-7 TEST_DATA_GAP "$REAL_AC")
if [ "$(jq -r '.findings[0].verified' <<<"$j")" = "true" ] && [ "$(jq -r '.findings[0].quote_check // "none"' <<<"$j")" = "none" ] &&
  [ "$(jq -r '.findings[0].quote' <<<"$j")" = "$REAL_AC" ]; then
  _pass "a verbatim quote passes the strict test unchanged (no quote_check)"
else
  _fail "verbatim quote changed ($j)"
fi

j=$(_judge Q-8 TEST_DATA_GAP "a … Duplicating a handover from the list")
[ "$(jq -r '.findings[0].verified' <<<"$j")" = "false" ] &&
  _pass "a piece under ${DOR_SEMANTIC_LOOSE_PIECE_MIN} characters fails the re-check" ||
  _fail "a one-letter piece should fail ($j)"

echo "=== loose-verified findings are never demoted ==="
f=$(jq -nc '[{code:"MISSING_CORE_AC",dimension:"requirement_completeness",severity:"blocking",quote:"Duplicating a handover from the list",quote_b:null,detail:"d",verified:true,quote_check:"loose"},
  {code:"EDGE_CASE_GAP",dimension:"edge_cases",severity:"blocking",quote:"Archiving a handover from its detail page",quote_b:null,detail:"d",verified:true}]')
out=$(DOR_SEMANTIC_MAX_ROUNDS=1 dor_semantic_lineage_from \
  '{"round":5,"evaluator":"'"$DOR_SEMANTIC_EVALUATOR"'","body_hash":"x","findings":[]}' "$(cat "$BODY")" "$HASH" "$f" '[]')
if [ "$(jq -c '[.findings[] | {code, severity, demoted}]' <<<"$out")" = '[{"code":"MISSING_CORE_AC","severity":"blocking","demoted":null},{"code":"EDGE_CASE_GAP","severity":"advisory","demoted":"round-limit"}]' ]; then
  _pass "round limit demotes a verbatim finding but never a loose-verified one"
else
  _fail "loose demotion ($(jq -c '[.findings[] | {code, severity, demoted, lineage}]' <<<"$out"))"
fi
out=$(DOR_SEMANTIC_PRIOR_PASSED=true dor_semantic_lineage_from null "$(cat "$BODY")" "$HASH" "$f" '[]')
[ "$(jq -r '[.findings[] | select(.code == "MISSING_CORE_AC") | .severity] | .[0]' <<<"$out")" = "blocking" ] &&
  _pass "the draft-passed policy never demotes a loose-verified finding" ||
  _fail "draft-passed loose ($(jq -c '.findings' <<<"$out"))"

echo "=== advisory vs blocking unverified findings ==="

_apply A-1 TEST_DATA_GAP "Duplicating a handover creates three copies of it" || true
r=$(_ready A-1)
if [ "$(jq -r '.semantic.findings[0].verified' <<<"$r")" = "false" ] &&
  [ "$(jq -r '(.missing // []) | index("SEMANTIC_UNVERIFIED")' <<<"$r")" = "null" ] &&
  [ "$(jq -r '.status' <<<"$r")" = "ready" ]; then
  _pass "advisory TEST_DATA_GAP with a bad quote: no SEMANTIC_UNVERIFIED, ticket ready"
else
  _fail "advisory TEST_DATA_GAP with a bad quote should not raise SEMANTIC_UNVERIFIED ($(jq -c '{missing, status}' <<<"$r"))"
fi

_apply A-2 MISSING_CORE_AC "Duplicating a handover creates three copies of it" || true
r=$(_ready A-2)
if [ "$(jq -c '.missing' <<<"$r")" = '["SEMANTIC_REQUIREMENT_COMPLETENESS","SEMANTIC_UNVERIFIED"]' ] &&
  [ "$(jq -r '.status' <<<"$r")" = "not-ready" ]; then
  _pass "blocking MISSING_CORE_AC with a bad quote: its own code and SEMANTIC_UNVERIFIED both stay"
else
  _fail "blocking finding with a bad quote must keep blocking ($(jq -c '.missing' <<<"$r"))"
fi

DOR_SEMANTIC_ADVISORY_CODES="EDGE_CASE_GAP" _apply A-3 EDGE_CASE_GAP "Duplicating a handover creates three copies of it" || true
r=$(_ready A-3)
[ "$(jq -r '(.missing // []) | index("SEMANTIC_UNVERIFIED")' <<<"$r")" = "null" ] &&
  _pass "a code made advisory by DOR_SEMANTIC_ADVISORY_CODES behaves like an advisory-only code" ||
  _fail "host-advisory code with a bad quote ($(jq -c '.missing' <<<"$r"))"

_apply A-4 MISSING_CORE_AC "\"Archiving a handover from its detail page moves it …\"" || true
r=$(_ready A-4)
if [ "$(jq -c '.missing' <<<"$r")" = '["SEMANTIC_REQUIREMENT_COMPLETENESS"]' ] &&
  [ "$(jq -r '.semantic.findings[0].unit // ""' <<<"$r")" != "" ]; then
  _pass "a loose-verified blocking finding blocks on its own code and is anchored to a unit"
else
  _fail "loose-verified blocking finding ($(jq -c '{missing, f: .semantic.findings[0]}' <<<"$r"))"
fi

codes=$(dor_semantic_blocking_codes '{"findings":[{"code":"TEST_DATA_GAP","dimension":"test_uat","severity":"advisory","verified":false}],"unverified_gaps":["edge_case_sufficiency"]}')
[ "$codes" = '["SEMANTIC_UNVERIFIED"]' ] &&
  _pass "an unbacked gap still raises SEMANTIC_UNVERIFIED next to an advisory finding" ||
  _fail "unbacked gap ($codes)"

echo "=== review fixes: an unverified finding is never demoted into silence ==="
# Reviewer case a1: past the round limit an unverified blocking finding was
# demoted to advisory, and the advisory test then dropped SEMANTIC_UNVERIFIED:
# the ticket became ready. Now the round limit never demotes an unverified
# finding, and the advisory test reads the code's class, not the severity.
a1_body=$'## Intent\nFinance exports invoices.\n\n## Acceptance Criteria\n- [ ] Export responds with 200 for a finance user\n\n## Scope\nOnly the export endpoint.\n\n## Test User\nfinance1\n'
a1_f='[{"code":"MISSING_CORE_AC","dimension":"requirement_completeness","severity":"blocking","quote":"Export fails with 500 for admins","detail":"x","verified":false}]'
a1_b1=$(DOR_SEMANTIC_MAX_ROUNDS=2 dor_semantic_lineage_from null "$a1_body" h1 '[]' '[]')
a1_p=$(jq -c '.lineage | .round=2' <<<"$a1_b1")
a1_out=$(DOR_SEMANTIC_MAX_ROUNDS=2 dor_semantic_lineage_from "$a1_p" "$a1_body"$'\nOne extra line.\n' h2 "$a1_f" '[]')
if [ "$(jq -c '.findings[0] | {severity, demoted}' <<<"$a1_out")" = '{"severity":"blocking","demoted":null}' ] &&
  [ "$(jq -r '.lineage.round' <<<"$a1_out")" = "3" ]; then
  _pass "a1: round 3 > limit 2 does not demote an unverified blocking finding"
else
  _fail "a1 lineage ($(jq -c '{f: .findings[0], round: .lineage.round}' <<<"$a1_out"))"
fi
write_ticket_manifest A1-1 INIT-1 feature '[]' >/dev/null
set_ticket_readiness A1-1 ready '[]' '[]' >/dev/null
set_ticket_semantic A1-1 "$(jq -c '{evaluator:"dor-semantic-v4", body_hash:"h2", findings: .findings, unverified_gaps: [], gaps:{}, audit:[], missed:[]}' <<<"$a1_out")" >/dev/null 2>&1
r=$(_ready A1-1)
[ "$(jq -c '{status, missing}' <<<"$r")" = '{"status":"not-ready","missing":["SEMANTIC_REQUIREMENT_COMPLETENESS","SEMANTIC_UNVERIFIED"]}' ] &&
  _pass "a1: the ticket stays not ready with its own code and SEMANTIC_UNVERIFIED" ||
  _fail "a1 manifest ($(jq -c '{status, missing}' <<<"$r"))"
# Even a demoted severity cannot hide it: the class decides, not the severity.
codes=$(dor_semantic_blocking_codes '{"findings":[{"code":"MISSING_CORE_AC","dimension":"requirement_completeness","severity":"advisory","demoted":"round-limit","code_class":"blocking","verified":false}],"unverified_gaps":[]}')
[ "$codes" = '["SEMANTIC_UNVERIFIED"]' ] &&
  _pass "a demoted blocking-class finding with a bad quote still raises SEMANTIC_UNVERIFIED" ||
  _fail "class vs severity ($codes)"
codes=$(dor_semantic_blocking_codes '{"findings":[{"code":"MISSING_CORE_AC","dimension":"requirement_completeness","severity":"advisory","verified":false}],"unverified_gaps":[]}')
[ "$codes" = '["SEMANTIC_UNVERIFIED"]' ] &&
  _pass "a finding with no code_class counts as blocking (fail closed)" ||
  _fail "no code_class ($codes)"
j=$(_judge Q-9 TEST_DATA_GAP "Duplicating a handover creates three copies of it")
[ "$(jq -r '.findings[0].code_class' <<<"$j")" = "advisory" ] &&
  _pass "dor_semantic_findings records the code's class" || _fail "code_class ($j)"

# Reviewer L1: an unverified finding never backs a gap, whatever its class.
_scan L1-1 EDGE_CASE_GAP "Duplicating a handover creates three copies of it"
sed -i 's/^GAP_EDGE_CASE_SUFFICIENCY: clear/GAP_EDGE_CASE_SUFFICIENCY: finding/' "$TMP_ROOT/L1-1-scan.txt"
s_l1=$(bash "$PARSER" --kind scan --result-file "$TMP_ROOT/L1-1-scan.txt" 2>/dev/null)
a_l1=$(bash "$PARSER" --kind audit --result-file "$TMP_ROOT/L1-1-audit.txt" 2>/dev/null)
j=$(DOR_SEMANTIC_ADVISORY_CODES="EDGE_CASE_GAP" dor_semantic_findings L1-1 "$(cat "$BODY")" "$s_l1" "$a_l1" 2>/dev/null)
if [ "$(jq -c '.unverified_gaps' <<<"$j")" = '["edge_case_sufficiency"]' ]; then
  _pass "L1: a host-advisory finding with a bad quote leaves its gap unbacked (SEMANTIC_UNVERIFIED)"
else
  _fail "L1 ($j)"
fi

echo "=== ready.harness_error ==="

write_ticket_manifest H-1 INIT-1 feature '[]' >/dev/null
set_ticket_readiness H-1 ready '[]' '[]' "{\"body_hash\": \"${HASH}\"}" >/dev/null
rc=0
set_ticket_harness_error H-1 '[1]' 2>/dev/null || rc=$?
[ "$rc" -eq 3 ] && _pass "set_ticket_harness_error refuses a non-object" || _fail "non-object rc=$rc"
set_ticket_semantic H-1 '{"evaluator":"x","unavailable":true,"findings":[],"gaps":{},"audit":[],"missed":[]}'
set_ticket_harness_error H-1 '{"code":"SEMANTIC_UNAVAILABLE","attempts":2}'
r=$(_ready H-1)
if [ "$(jq -c '.missing' <<<"$r")" = '["SEMANTIC_UNAVAILABLE"]' ] && [ "$(jq -r .status <<<"$r")" = "not-ready" ] &&
  [ "$(jq -r .harness_error.attempts <<<"$r")" = "2" ]; then
  _pass "harness_error recorded beside SEMANTIC_UNAVAILABLE; missing and status untouched"
else
  _fail "harness_error write ($r)"
fi
set_ticket_readiness H-1 ready '[]' '[]' "{\"body_hash\": \"${HASH}\"}" >/dev/null
r=$(_ready H-1)
[ "$(jq -r '.harness_error // "gone"' <<<"$r")" = "gone" ] && [ "$(jq -r .status <<<"$r")" = "not-ready" ] &&
  _pass "a re-scan that stales the verdict drops harness_error and keeps the ticket not ready" ||
  _fail "stale drop ($r)"

_apply H-2 MISSING_CORE_AC "Duplicating a handover creates three copies of it" || true
set_ticket_harness_error H-2 '{"code":"SEMANTIC_UNVERIFIED"}'
set_ticket_readiness H-2 ready '[]' '[]' "{\"body_hash\": \"${HASH}\"}" >/dev/null
r=$(_ready H-2)
[ "$(jq -r '.harness_error.code // "gone"' <<<"$r")" = "SEMANTIC_UNVERIFIED" ] &&
  _pass "a re-scan on the same body carries harness_error with the verdict" ||
  _fail "carry ($r)"
_apply H-2 MISSING_CORE_AC "$REAL_AC" || true
r=$(_ready H-2)
[ "$(jq -r '.harness_error // "gone"' <<<"$r")" = "gone" ] &&
  _pass "a fresh verdict drops harness_error" || _fail "fresh verdict ($r)"
set_ticket_harness_error H-2 '{"code":"x"}'
set_ticket_harness_error H-2 null
[ "$(_ready H-2 | jq -r '.harness_error // "gone"')" = "gone" ] &&
  _pass "null clears harness_error" || _fail "null clear"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
