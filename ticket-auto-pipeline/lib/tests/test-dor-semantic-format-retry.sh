#!/usr/bin/env bash
# test-dor-semantic-format-retry.sh — the validator-only format retry
# (seam-gate-safety G6, design D5) in lib/dor-semantic-parse.sh.
#
# A stub stands in for the agent: it writes a chosen block to the retry
# path. Covered: the bullets/casing/wrap slips reach `ok` with the same
# codes; a dropped finding is restored (restored: true, its quote still
# checked against the body) or the retry is rejected; an added finding or a
# changed verdict rejects the retry; the same failure twice stops early;
# exhaustion is reported once; a parsed block is never retried; the prompt
# holds the original block, the error record and the instruction, never the
# body; nothing in a block is run or used as a path. Deterministic.
# Usage: bash test-dor-semantic-format-retry.sh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES_DIR="$LIB_DIR/tests/fixtures/dor"
SCAN30="$FIXTURES_DIR/semantic/30-scan.txt"
BODY30="$FIXTURES_DIR/30-chained-draft.md"
TID="DRAFT-client-upload"

source "$LIB_DIR/dor-semantic.sh"
source "$LIB_DIR/dor-semantic-parse.sh"

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
_check() { # _check <label> <cmd...>
  local label="$1"
  shift
  if "$@"; then _pass "$label"; else _fail "$label"; fi
}

TMP_ROOT=$(mktemp -d)
export REPOS_ROOT="$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT
unset DOR_SEMANTIC_ADVISORY_CODES DOR_STRICT_TEST_DATA DOR_SEMANTIC_FORMAT_RETRIES

# The corpus replay's harmless operators (test-planner-corpus-replay.sh).
op_bullets() { sed -E 's/^([A-Z][A-Z0-9_]*[[:space:]]*:)/- \1/'; }
op_casing() { sed -E 's/^((GAP_[A-Z_]+|SCORE_PLAUSIBLE|AUDIT_[0-9]+_VERDICT)[[:space:]]*:[[:space:]]*)([a-z])/\1\u\3/'; }
op_wrap() {
  awk '!done && /^[A-Z][A-Z0-9_]*(_DETAIL|_REASON|PARAPHRASE)[[:space:]]*:/ && length($0) > 90 {
         cut = index(substr($0, 70), " ")
         if (cut > 0) { print substr($0, 1, 68 + cut); print "  " substr($0, 70 + cut); done = 1; next }
       } { print }'
}
op_codecase() { sed -E 's/^(FINDING_1_CODE[[:space:]]*:[[:space:]]*)([A-Z_]+)/\1\L\2/'; }

AUDIT_CLEAN=$(
  cat <<'EOF'
=== DOR_SEMANTIC_AUDIT ===
SCHEMA_VERSION: 1
AUDIT_1_CODE: AC_VAGUE
AUDIT_1_VERDICT: disputed
AUDIT_1_REASON: The criterion names a concrete row number, so it is not vague; the deterministic pass matched the word "correctly" in a different sentence of the ticket body.
AUDIT_2_CODE: VPLAN_ROW_GAP
AUDIT_2_VERDICT: agree
MISSED_1_CODE: EDGE_CASE_GAP
MISSED_1_REASON: a file with several invalid rows is not covered
SCORE_PLAUSIBLE: yes
SCORE_REASON: the deterministic result matches the body
=== END DOR_SEMANTIC_AUDIT ===
EOF
)
DET='{"missing":["AC_VAGUE"],"advisory":["VPLAN_ROW_GAP"]}'

# _codes <kind> <file> [<det>] — sorted codes + verdicts of a parsed block, or "invalid".
_codes() {
  local args=(--kind "$1" --result-file "$2")
  [ -n "${3:-}" ] && args+=(--det-result "$3")
  local j
  j=$(parse_dor_semantic "${args[@]}" 2>/dev/null) || true
  [ -n "$j" ] || {
    echo invalid
    return 0
  }
  jq -r '
    if .parse_status != "ok" then "invalid" else
    ([(.findings // [])[] | .code] + [(.gaps // {}) | to_entries[] | .key + "=" + .value.verdict]
     + [(.audit // [])[] | .code + "=" + .verdict] + [(.missed // [])[].code]
     + (if .kind == "audit" then ["score=" + (.score_plausible | tostring)] else [] end)) | sort | join(",") end' <<<"$j" 2>/dev/null || echo invalid
}

# _case <dir> — a fresh case directory.
_case() {
  local d="$TMP_ROOT/$1"
  rm -rf "$d"
  mkdir -p "$d"
  printf '%s' "$d"
}

# _step <kind> <R> [--spawned] [<det>] — sets STEP_OUT / STEP_RC.
STEP_OUT=""
STEP_RC=0
_step() {
  local kind="$1" rf="$2" sp="${3:-}" det="${4:-}"
  local args=(--kind "$kind" --result-file "$rf")
  [ -n "$det" ] && args+=(--det-result "$det")
  [ "$sp" = "--spawned" ] && args+=(--spawned)
  STEP_RC=0
  STEP_OUT=$(dor_semantic_format_step "${args[@]}" 2>/dev/null) || STEP_RC=$?
}

# _retry_case <kind> <clean-file> <op> <stub-file> [<det>]
# Mutates the clean block with <op>, runs one step (expects a retry), lets
# the stub write <stub-file> to the retry path, runs the step again.
_retry_case() {
  local kind="$1" clean="$2" op="$3" stub="$4" det="${5:-}" d rf
  d=$(_case "rc-$kind-$op-$RANDOM")
  rf="$d/${kind}-result.txt"
  "op_${op}" <"$clean" >"$rf"
  _step "$kind" "$rf" "" "$det"
  [ "$STEP_RC" -eq 4 ] || {
    echo "  (first step rc=$STEP_RC out=$STEP_OUT)"
    return 1
  }
  cp "$stub" "$d/${kind}-result.format-result.txt"
  _step "$kind" "$rf" --spawned "$det"
  CASE_DIR="$d"
  CASE_RF="$rf"
}

echo "=== 4.1 corpus slips re-serialised by a stub reach ok with the same codes ==="
printf '%s\n' "$AUDIT_CLEAN" >"$TMP_ROOT/audit-clean.txt"
printf '%s\n' "$DET" >"$TMP_ROOT/det.json"
SCAN_CODES=$(_codes scan "$SCAN30")
AUDIT_CODES=$(_codes audit "$TMP_ROOT/audit-clean.txt" "$TMP_ROOT/det.json")
_check "clean scan fixture parses" [ "$SCAN_CODES" != invalid ]
_check "clean audit fixture parses" [ "$AUDIT_CODES" != invalid ]
for op in bullets casing wrap codecase; do
  for kind in scan audit; do
    clean="$SCAN30" det="" want="$SCAN_CODES"
    if [ "$kind" = audit ]; then
      clean="$TMP_ROOT/audit-clean.txt" det="$TMP_ROOT/det.json" want="$AUDIT_CODES"
    fi
    [ "$op" = codecase ] && [ "$kind" = audit ] && continue
    "op_${op}" <"$clean" >"$TMP_ROOT/mut.txt"
    if [ "$(_codes "$kind" "$TMP_ROOT/mut.txt" "$det")" != invalid ]; then
      [ "$op" = casing ] || [ "$op" = wrap ] || _fail "$kind@$op: the mutation should not parse"
      continue
    fi
    if _retry_case "$kind" "$clean" "$op" "$clean" "$det" && [ "$STEP_RC" -eq 0 ] && [ "$STEP_OUT" = ok ] &&
      [ "$(_codes "$kind" "$CASE_RF" "$det")" = "$want" ]; then
      _pass "$kind@$op: retry accepted, same codes"
    else
      _fail "$kind@$op: rc=$STEP_RC out='$STEP_OUT' codes='$(_codes "$kind" "${CASE_RF:-/dev/null}" "$det")' want='$want'"
    fi
    _check "$kind@$op: original block kept beside the result" [ -s "${CASE_DIR}/${kind}-result.format-original.txt" ]
    _check "$kind@$op: no retry state left" [ ! -e "${CASE_DIR}/${kind}-result.format.json" ]
  done
done

echo "=== the error record names field, expected, got and example from the contract ==="
d=$(_case record)
op_bullets <"$SCAN30" | sed '/^- SCHEMA_VERSION/s/^- //; /^- TICKET/s/^- //; /^- BODY_HASH/s/^- //; /^- PARAPHRASE/s/^- //' >"$d/scan-result.txt"
rc=0
rec=$(dor_semantic_format_record --kind scan --result-file "$d/scan-result.txt") || rc=$?
_check "bulleted FINDING_1_CODE is retryable (rc 1)" [ "$rc" -eq 1 ]
_check "record field is FINDING_1_CODE" [ "$(jq -r .field <<<"$rec")" = FINDING_1_CODE ]
_check "record expected is the contract line" [ "$(jq -r .expected <<<"$rec")" = "FINDING_1_CODE: <code>" ]
_check "record got is the line as written" [ "$(jq -r .got <<<"$rec")" = "- FINDING_1_CODE: INTENT_AC_MISMATCH" ]
_check "record example is a filled contract line" [ "$(jq -r .example <<<"$rec")" = "FINDING_1_CODE: MISSING_CORE_AC" ]
_check "record code is FORMAT_ERROR" [ "$(jq -r .code <<<"$rec")" = FORMAT_ERROR ]
op_casing <"$SCAN30" >"$d/c.txt"
rec=$(dor_semantic_format_record --kind scan --result-file "$d/c.txt") || true
_check "casing: field GAP_REQUIREMENT_COMPLETENESS, example its first value" \
  [ "$(jq -r '.field + " " + .example' <<<"$rec")" = "GAP_REQUIREMENT_COMPLETENESS GAP_REQUIREMENT_COMPLETENESS: clear" ]

echo "=== the retry prompt: original block verbatim, error record, instruction, no body ==="
_step scan "$d/scan-result.txt"
_check "fresh invalid block asks for a retry (rc 4)" [ "$STEP_RC" -eq 4 ]
P="$d/scan-result.format-prompt.txt"
_check "prompt file written" [ -s "$P" ]
_check "prompt holds the original block verbatim" grep -qxF -- "- FINDING_1_CODE: INTENT_AC_MISMATCH" "$P"
_check "prompt holds the error record field" grep -qF '"field": "FINDING_1_CODE"' "$P"
_check "prompt holds the instruction" grep -qxF "$DOR_SEMANTIC_FORMAT_INSTRUCTION" "$P"
_check "prompt names the retry path" grep -qF "$d/scan-result.format-result.txt" "$P"
_check "prompt holds no body path" bash -c '! grep -qF "30-chained-draft" "$1"' _ "$P"
_check "prompt holds no body text" bash -c '! grep -qF "## Acceptance Criteria" "$1"' _ "$P"
_check "last-failure.json is the error record" [ "$(jq -r .field "$d/scan-result.last-failure.json")" = FINDING_1_CODE ]
_step scan "$d/scan-result.txt"
_check "a second step before the spawn asks again without spending budget" \
  [ "$STEP_RC" -eq 4 ] && [ "$(jq -r .retries "$d/scan-result.format.json")" = 1 ]
_check "awaiting reports the prompt and retry path" \
  [ "$(dor_semantic_format_awaiting "$d/scan-result.txt")" = "$P"$'\t'"$d/scan-result.format-result.txt" ]

echo "=== a parsed block is never retried ==="
d=$(_case parsed)
cp "$SCAN30" "$d/scan-result.txt"
_step scan "$d/scan-result.txt"
_check "valid block with blocking findings: ok, rc 0" [ "$STEP_RC" -eq 0 ] && [ "$STEP_OUT" = ok ]
_check "no prompt, state or record written" [ -z "$(ls "$d" | grep -v '^scan-result.txt$')" ]

echo "=== the retry drops a blocking finding: restored from the original ==="
grep -v '^FINDING_1_' "$SCAN30" >"$TMP_ROOT/drop1.txt"
_retry_case scan "$SCAN30" bullets "$TMP_ROOT/drop1.txt"
_check "accepted (rc 0)" [ "$STEP_RC" -eq 0 ]
_check "same codes as the original" [ "$(_codes scan "$CASE_RF")" = "$SCAN_CODES" ]
J=$(parse_dor_semantic --kind scan --result-file "$CASE_RF" 2>/dev/null)
_check "the dropped INTENT_AC_MISMATCH is back with restored: true" \
  [ "$(jq -r '[.findings[] | select(.restored == true) | .code] | join(",")' <<<"$J")" = INTENT_AC_MISMATCH ]
_check "the restored quote is the original's" \
  [ "$(jq -r '.findings[] | select(.restored == true) | .quote' <<<"$J")" = "- [ ] A user without the ops role does not see the Upload menu item" ]
# Findings checks the restored quote against the body like any other. The
# fixture is stamped first: `restored` lives in a sidecar bound to the
# merged file's sha, so the file is never edited after the merge.
REAL=$(_dor_body_hash "$(cat "$BODY30")")
sed -e "s/@TICKET@/$TID/" -e "s/@BODY_HASH@/$REAL/" "$SCAN30" >"$TMP_ROOT/stamped-clean.txt"
grep -v '^FINDING_1_' "$TMP_ROOT/stamped-clean.txt" >"$TMP_ROOT/stamped-drop.txt"
_retry_case scan "$TMP_ROOT/stamped-clean.txt" bullets "$TMP_ROOT/stamped-drop.txt"
SJ=$(parse_dor_semantic --kind scan --result-file "$CASE_RF" 2>/dev/null)
AJ=$(printf '=== DOR_SEMANTIC_AUDIT ===\nSCHEMA_VERSION: 1\nTICKET: %s\nBODY_HASH: %s\nSCORE_PLAUSIBLE: yes\nSCORE_REASON: ok\n=== END DOR_SEMANTIC_AUDIT ===\n' "$TID" "$REAL" >"$TMP_ROOT/a.txt" && parse_dor_semantic --kind audit --result-file "$TMP_ROOT/a.txt" 2>/dev/null)
F=$(dor_semantic_findings "$TID" "$(cat "$BODY30")" "$SJ" "$AJ" 2>/dev/null)
_check "dor_semantic_findings keeps restored: true and verifies its quote" \
  [ "$(jq -r '[.findings[] | select(.restored == true) | .verified] | join(",")' <<<"$F")" = true ]
# A restored quote the body does not hold is unverified, never trusted.
sed -E 's/^FINDING_1_QUOTE: .*/FINDING_1_QUOTE: a sentence that is nowhere in the ticket body/' "$TMP_ROOT/stamped-clean.txt" >"$TMP_ROOT/fake.txt"
grep -v '^FINDING_1_' "$TMP_ROOT/fake.txt" >"$TMP_ROOT/fake-drop.txt"
_retry_case scan "$TMP_ROOT/fake.txt" bullets "$TMP_ROOT/fake-drop.txt"
SJ=$(parse_dor_semantic --kind scan --result-file "$CASE_RF" 2>/dev/null)
F=$(dor_semantic_findings "$TID" "$(cat "$BODY30")" "$SJ" "$AJ" 2>/dev/null)
_check "a restored quote not in the body is verified:false" \
  [ "$(jq -r '[.findings[] | select(.restored == true) | .verified] | join(",")' <<<"$F")" = false ]

echo "=== the retry drops a finding bash cannot rebuild: rejected ==="
# The original's CONTRADICTORY_REQUIREMENTS has no QUOTE_B (it would also
# fail the contract) behind a bullet slip; the retry leaves it out.
{
  sed '/^=== END DOR_SEMANTIC_SCAN ===/d' "$SCAN30"
  printf 'FINDING_5_CODE: CONTRADICTORY_REQUIREMENTS\nFINDING_5_QUOTE: The upload page validates every row\n=== END DOR_SEMANTIC_SCAN ===\n'
} >"$TMP_ROOT/contra.txt"
_retry_case scan "$TMP_ROOT/contra.txt" bullets "$SCAN30"
_check "rejected and exhausted (rc 5)" [ "$STEP_RC" -eq 5 ]
_check "exhausted names the original field" [ "$STEP_OUT" = "exhausted SCHEMA_VERSION" ]
_check "the record says the finding cannot be rebuilt" grep -qF "cannot rebuild" "$CASE_DIR/scan-result.last-failure.json"
_check "the result file is the original, unchanged" cmp -s <(op_bullets <"$TMP_ROOT/contra.txt") "$CASE_RF"

echo "=== the retry adds a finding: rejected ==="
sed 's/^=== END DOR_SEMANTIC_SCAN ===/FINDING_9_CODE: SCOPE_AMBIGUOUS\nFINDING_9_QUOTE: The upload page validates every row\n&/' "$SCAN30" >"$TMP_ROOT/added.txt"
_retry_case scan "$SCAN30" bullets "$TMP_ROOT/added.txt"
_check "rejected (rc 5, budget 1)" [ "$STEP_RC" -eq 5 ]
_check "record code FINDING_SET_CHANGED, field findings" \
  [ "$(jq -r '.code + " " + .field' "$CASE_DIR/scan-result.last-failure.json")" = "FINDING_SET_CHANGED findings" ]
_step scan "$CASE_RF" --spawned
_check "after exhaustion: invalid (rc 1), reported once" [ "$STEP_RC" -eq 1 ] && [ "$STEP_OUT" = invalid ]
_check "the result file still fails to parse" [ "$(_codes scan "$CASE_RF")" = invalid ]

echo "=== the retry changes a verdict: rejected ==="
sed 's/^GAP_EDGE_CASE_SUFFICIENCY: finding/GAP_EDGE_CASE_SUFFICIENCY: clear/' "$SCAN30" >"$TMP_ROOT/gapflip.txt"
_retry_case scan "$SCAN30" bullets "$TMP_ROOT/gapflip.txt"
_check "gap finding -> clear rejected" [ "$STEP_RC" -eq 5 ] &&
  [ "$(jq -r .field "$CASE_DIR/scan-result.last-failure.json")" = GAP_EDGE_CASE_SUFFICIENCY ]
sed 's/^FINDING_1_CODE: INTENT_AC_MISMATCH/FINDING_1_CODE: EDGE_CASE_GAP/' "$SCAN30" >"$TMP_ROOT/codeflip.txt"
_retry_case scan "$SCAN30" bullets "$TMP_ROOT/codeflip.txt"
_check "changed code rejected" [ "$STEP_RC" -eq 5 ]
sed 's/^AUDIT_1_VERDICT: disputed/AUDIT_1_VERDICT: agree/' "$TMP_ROOT/audit-clean.txt" >"$TMP_ROOT/aflip.txt"
_retry_case audit "$TMP_ROOT/audit-clean.txt" bullets "$TMP_ROOT/aflip.txt" "$TMP_ROOT/det.json"
_check "audit disputed -> agree rejected" [ "$STEP_RC" -eq 5 ]
grep -v '^MISSED_1_' "$TMP_ROOT/audit-clean.txt" >"$TMP_ROOT/amiss.txt"
_retry_case audit "$TMP_ROOT/audit-clean.txt" bullets "$TMP_ROOT/amiss.txt" "$TMP_ROOT/det.json"
_check "audit dropped MISSED rejected" [ "$STEP_RC" -eq 5 ]
sed 's/^SCORE_PLAUSIBLE: yes/SCORE_PLAUSIBLE: no/' "$TMP_ROOT/audit-clean.txt" >"$TMP_ROOT/aflip2.txt"
_retry_case audit "$TMP_ROOT/audit-clean.txt" bullets "$TMP_ROOT/aflip2.txt" "$TMP_ROOT/det.json"
_check "audit SCORE_PLAUSIBLE yes -> no rejected" [ "$STEP_RC" -eq 5 ]
# A verdict the original never wrote cannot be supplied by the retry.
op_bullets <"$SCAN30" | grep -v '^- GAP_DEEP_SCOPE_AMBIGUITY:' >"$TMP_ROOT/nogap.txt"
d=$(_case nogap)
cp "$TMP_ROOT/nogap.txt" "$d/scan-result.txt"
_step scan "$d/scan-result.txt"
cp "$SCAN30" "$d/scan-result.format-result.txt"
_step scan "$d/scan-result.txt" --spawned
_check "a gap verdict missing from the original rejects the retry" [ "$STEP_RC" -eq 5 ]

echo "=== the same failure twice stops early; budget and exhaustion ==="
d=$(_case early)
op_bullets <"$SCAN30" >"$d/scan-result.txt"
DOR_SEMANTIC_FORMAT_RETRIES=3 _step scan "$d/scan-result.txt"
op_bullets <"$SCAN30" >"$d/scan-result.format-result.txt"
DOR_SEMANTIC_FORMAT_RETRIES=3 _step scan "$d/scan-result.txt" --spawned
_check "same (field, got) twice: exhausted after one retry of three" \
  [ "$STEP_RC" -eq 5 ] && [ "$(jq -r .retries "$d/scan-result.format.json")" = 1 ]
d=$(_case budget2)
op_bullets <"$SCAN30" >"$d/scan-result.txt"
DOR_SEMANTIC_FORMAT_RETRIES=2 _step scan "$d/scan-result.txt"
op_casing <"$SCAN30" >"$d/scan-result.format-result.txt"
DOR_SEMANTIC_FORMAT_RETRIES=2 _step scan "$d/scan-result.txt" --spawned
_check "a different failure with budget left asks again (rc 4)" [ "$STEP_RC" -eq 4 ]
_check "the second prompt still holds the original block" grep -qxF -- "- FINDING_1_CODE: INTENT_AC_MISMATCH" "$d/scan-result.format-prompt.txt"
_check "the second prompt carries the new error record" grep -qF '"field": "GAP_REQUIREMENT_COMPLETENESS"' "$d/scan-result.format-prompt.txt"
cp "$SCAN30" "$d/scan-result.format-result.txt"
DOR_SEMANTIC_FORMAT_RETRIES=2 _step scan "$d/scan-result.txt" --spawned
_check "second retry accepted" [ "$STEP_RC" -eq 0 ] && [ "$(_codes scan "$d/scan-result.txt")" = "$SCAN_CODES" ]
d=$(_case noshow)
op_bullets <"$SCAN30" >"$d/scan-result.txt"
_step scan "$d/scan-result.txt"
_step scan "$d/scan-result.txt" --spawned
_check "a spawned retry that wrote nothing exhausts (rc 5)" [ "$STEP_RC" -eq 5 ]
d=$(_case newattempt)
op_bullets <"$SCAN30" >"$d/scan-result.txt"
_step scan "$d/scan-result.txt"
_step scan "$d/scan-result.txt" --spawned
op_wrap <"$SCAN30" >"$d/scan-result.txt"
_step scan "$d/scan-result.txt"
_check "a new attempt's result gets a fresh budget (rc 4)" [ "$STEP_RC" -eq 4 ]
dor_semantic_format_clear "$d/scan-result.txt"
_check "clear drops state, prompt and retry result" \
  [ ! -e "$d/scan-result.format.json" ] && [ ! -e "$d/scan-result.format-prompt.txt" ]

echo "=== not retryable: content, not format ==="
for case in "no_paraphrase:/^PARAPHRASE:/d" "gap_enum:s/^GAP_DEEP_SCOPE_AMBIGUITY: clear/GAP_DEEP_SCOPE_AMBIGUITY: maybe/" \
  "schema_v2:s/^SCHEMA_VERSION: 1/SCHEMA_VERSION: 2/" "unknown_code:s/^FINDING_2_CODE: EDGE_CASE_GAP/FINDING_2_CODE: NOT_A_CODE/" \
  "cut_end:/^=== END DOR_SEMANTIC_SCAN/d" "dup_key:s/^(GAP_DEEP_SCOPE_AMBIGUITY: clear)$/\\1\\nGAP_DEEP_SCOPE_AMBIGUITY: finding/"; do
  name="${case%%:*}"
  d=$(_case "nr-$name")
  sed -E "${case#*:}" "$SCAN30" >"$d/scan-result.txt"
  _step scan "$d/scan-result.txt"
  _check "$name: invalid (rc 1), no prompt" [ "$STEP_RC" -eq 1 ] && [ ! -e "$d/scan-result.format-prompt.txt" ]
done
d=$(_case nr-unaudited)
printf '%s\n' "$AUDIT_CLEAN" | grep -v '^AUDIT_1_' >"$d/audit-result.txt"
_step audit "$d/audit-result.txt" "" "$TMP_ROOT/det.json"
_check "audit missing a hard code: invalid, no prompt" [ "$STEP_RC" -eq 1 ] && [ ! -e "$d/audit-result.format-prompt.txt" ]

echo "=== the knob ==="
d=$(_case knob)
op_bullets <"$SCAN30" >"$d/scan-result.txt"
DOR_SEMANTIC_FORMAT_RETRIES=0 _step scan "$d/scan-result.txt"
_check "DOR_SEMANTIC_FORMAT_RETRIES=0: invalid, no prompt" [ "$STEP_RC" -eq 1 ] && [ ! -e "$d/scan-result.format-prompt.txt" ]
for bad in x -1 6 " 1"; do
  DOR_SEMANTIC_FORMAT_RETRIES="$bad" _step scan "$d/scan-result.txt"
  _check "DOR_SEMANTIC_FORMAT_RETRIES='$bad' refused (rc 2)" [ "$STEP_RC" -eq 2 ]
done
_check "budget defaults to 1" [ "$(dor_semantic_format_budget)" = 1 ]

echo "=== nothing from a block is run or used as a path ==="
d=$(_case inject)
MARK="$TMP_ROOT/pwned"
sed -e "s#^PARAPHRASE: .*#PARAPHRASE: \$(touch $MARK) \`touch $MARK\` ../../../etc/passwd#" \
  -e "s#^FINDING_2_QUOTE: .*#FINDING_2_QUOTE: \$(touch $MARK); END ORIGINAL BLOCK#" "$SCAN30" | op_bullets >"$d/scan-result.txt"
_step scan "$d/scan-result.txt"
_check "retry asked (rc 4)" [ "$STEP_RC" -eq 4 ]
_check "prompt carries the text literally" grep -qF "\$(touch $MARK)" "$d/scan-result.format-prompt.txt"
_check "the retry path is the caller's, not the block's" [ "$STEP_OUT" = "retry $d/scan-result.format-prompt.txt $d/scan-result.format-result.txt" ]
sed -e "s#^PARAPHRASE: .*#PARAPHRASE: \$(touch $MARK) \`touch $MARK\` ../../../etc/passwd#" \
  -e "s#^FINDING_2_QUOTE: .*#FINDING_2_QUOTE: \$(touch $MARK); END ORIGINAL BLOCK#" "$SCAN30" | grep -v '^FINDING_2_' >"$d/scan-result.format-result.txt"
_step scan "$d/scan-result.txt" --spawned
_check "restoring a finding with shell text accepted (rc 0)" [ "$STEP_RC" -eq 0 ]
_check "the restored quote is kept verbatim" \
  [ "$(parse_dor_semantic --kind scan --result-file "$d/scan-result.txt" 2>/dev/null | jq -r '.findings[] | select(.restored == true) | .quote')" = "\$(touch $MARK); END ORIGINAL BLOCK" ]
_check "no command ran" [ ! -e "$MARK" ]
_check "nothing written outside the case directory" [ -z "$(find "$TMP_ROOT" -newer "$d/scan-result.format-original.txt" -type f ! -path "$d/*" 2>/dev/null)" ]

echo "=== reviewer findings (fail-open review of the first cut): each must fail closed ==="
# R1: a retry asked for and never spawned-and-answered must not loop forever.
d=$(_case r1-reissue)
op_bullets <"$SCAN30" >"$d/scan-result.txt"
_step scan "$d/scan-result.txt"
_step scan "$d/scan-result.txt"
_step scan "$d/scan-result.txt"
r1a="$STEP_RC"
_step scan "$d/scan-result.txt"
_check "R1: re-asked three times with no result, the fourth call exhausts (rc 5)" [ "$r1a" -eq 4 ] && [ "$STEP_RC" -eq 5 ]

# R2: the tolerant reader and the parser must read the same block.
d=$(_case r2-twoblocks)
{
  op_bullets <"$SCAN30"
  printf '=== DOR_SEMANTIC_SCAN ===\nSCHEMA_VERSION: 1\nPARAPHRASE: x\n'
} >"$d/scan-result.txt"
_step scan "$d/scan-result.txt"
_check "R2: a closed block plus a trailing unclosed one is not retried" [ "$STEP_RC" -eq 1 ] && [ ! -e "$d/scan-result.format-prompt.txt" ]
d=$(_case r2-marker)
op_bullets <"$SCAN30" | sed '0,/^- FINDING_2_CODE/s//=== END DOR_SEMANTIC_AUDIT ===\n&/' >"$d/scan-result.txt"
_step scan "$d/scan-result.txt"
_check "R2: a marker-shaped line inside the block is not retried" [ "$STEP_RC" -eq 1 ] && [ ! -e "$d/scan-result.format-prompt.txt" ]
d=$(_case r2-retry-two)
op_bullets <"$SCAN30" >"$d/scan-result.txt"
_step scan "$d/scan-result.txt"
{
  cat "$SCAN30"
  printf '=== DOR_SEMANTIC_SCAN ===\n'
} >"$d/scan-result.format-result.txt"
_step scan "$d/scan-result.txt" --spawned
_check "R2: a retry with a second, unclosed block is rejected" [ "$STEP_RC" -eq 5 ]

# R3: a content defect behind a format slip stays a defect.
d=$(_case r3-schema)
op_bullets <"$SCAN30" | sed 's/^- SCHEMA_VERSION: 1/- SCHEMA_VERSION: 2/' >"$d/scan-result.txt"
_step scan "$d/scan-result.txt"
cp "$SCAN30" "$d/scan-result.format-result.txt"
_step scan "$d/scan-result.txt" --spawned
_check "R3: SCHEMA_VERSION 2 behind a bullet cannot become 1" [ "$STEP_RC" -eq 5 ]
for drop in '^- PARAPHRASE:' '^- FINDING_3_DETAIL:' '^- GAP_DEEP_SCOPE_AMBIGUITY_REASON:'; do
  d=$(_case "r3-drop-$RANDOM")
  op_bullets <"$SCAN30" | grep -v -- "$drop" >"$d/scan-result.txt"
  _step scan "$d/scan-result.txt"
  cp "$SCAN30" "$d/scan-result.format-result.txt"
  _step scan "$d/scan-result.txt" --spawned
  _check "R3: a value missing from the original ('$drop') cannot be supplied by the retry" [ "$STEP_RC" -eq 5 ]
done
d=$(_case r3-audit)
printf '%s\n' "$AUDIT_CLEAN" | sed 's/^AUDIT_1_VERDICT: disputed/AUDIT_1_VERDICT: Disputed/' | grep -v '^AUDIT_1_REASON' >"$d/audit-result.txt"
_step audit "$d/audit-result.txt" "" "$TMP_ROOT/det.json"
{
  printf '%s\n' "$AUDIT_CLEAN" | sed '/^AUDIT_1_REASON/a AUDIT_1_QUOTE: - [ ] Uploading a file with an invalid row'
} >"$d/audit-result.format-result.txt"
_step audit "$d/audit-result.txt" --spawned "$TMP_ROOT/det.json"
_check "R3: a retry cannot invent a dispute REASON or AUDIT_n_QUOTE" [ "$STEP_RC" -eq 5 ]

# R4: values past the code and anchor are compared too.
sed -E 's/^(FINDING_2_QUOTE: .*)row error list when any row is invalid\./\1row error list./' "$SCAN30" >"$TMP_ROOT/r4-tail.txt"
_retry_case scan "$SCAN30" bullets "$TMP_ROOT/r4-tail.txt"
_check "R4: a retry that rewrites a quote's tail is rejected" [ "$STEP_RC" -eq 5 ]
sed -E 's/^FINDING_1_DETAIL: .*/FINDING_1_DETAIL: completely different judgement/' "$SCAN30" >"$TMP_ROOT/r4-detail.txt"
_retry_case scan "$SCAN30" bullets "$TMP_ROOT/r4-detail.txt"
_check "R4: a retry that rewrites a DETAIL is rejected" [ "$STEP_RC" -eq 5 ]
sed -E 's/^(GAP_DEEP_SCOPE_AMBIGUITY_REASON: ).*/\1another reason/' "$SCAN30" >"$TMP_ROOT/r4-reason.txt"
_retry_case scan "$SCAN30" bullets "$TMP_ROOT/r4-reason.txt"
_check "R4: a retry that rewrites a GAP reason is rejected" [ "$STEP_RC" -eq 5 ]
sed -E 's/^(PARAPHRASE: ).*/\1another change/' "$SCAN30" >"$TMP_ROOT/r4-para.txt"
_retry_case scan "$SCAN30" bullets "$TMP_ROOT/r4-para.txt"
_check "R4: a retry that rewrites the PARAPHRASE is rejected" [ "$STEP_RC" -eq 5 ]

# R5: the original replaced while its retry is out is never judged.
d=$(_case r5-tamper)
op_bullets <"$SCAN30" >"$d/scan-result.txt"
_step scan "$d/scan-result.txt"
grep -v '^FINDING_' "$SCAN30" | sed 's/^GAP_\(REQUIREMENT_COMPLETENESS\|EDGE_CASE_SUFFICIENCY\): finding/GAP_\1: clear/' >"$d/scan-result.txt"
_step scan "$d/scan-result.txt" --spawned
_check "R5: an overwritten original: invalid (rc 1), moved aside, nothing left to parse" \
  [ "$STEP_RC" -eq 1 ] && [ ! -e "$d/scan-result.txt" ] && [ -s "$d/scan-result.format-tampered.txt" ]

# R6: restored comes only from bash, never from a key in a block.
sed 's/^FINDING_4_DETAIL: .*/&\nFINDING_4_RESTORED: true/' "$SCAN30" >"$TMP_ROOT/r6-forged.txt"
_retry_case scan "$SCAN30" bullets "$TMP_ROOT/r6-forged.txt"
_check "R6: a retry that writes FINDING_n_RESTORED is rejected" [ "$STEP_RC" -eq 5 ]
_check "R6: a first-attempt block's own FINDING_n_RESTORED is ignored" \
  [ "$(parse_dor_semantic --kind scan --result-file "$TMP_ROOT/r6-forged.txt" 2>/dev/null | jq '[.findings[] | select(.restored == true)] | length')" = 0 ]
d=$(_case r6-sidecar)
grep -v '^FINDING_1_' "$SCAN30" >"$TMP_ROOT/r6-drop.txt"
_retry_case scan "$SCAN30" bullets "$TMP_ROOT/r6-drop.txt"
echo "# edited" >>"$CASE_RF"
_check "R6: the restored mark is dropped once the file changes" \
  [ "$(parse_dor_semantic --kind scan --result-file "$CASE_RF" 2>/dev/null | jq '[.findings[] | select(.restored == true)] | length')" = 0 ]

# R7: duplicates by code and anchor: the dropped copy is the one restored.
{
  sed '/^=== END DOR_SEMANTIC_SCAN ===/d' "$SCAN30"
  printf 'FINDING_5_CODE: EDGE_CASE_GAP\nFINDING_5_QUOTE: The upload page validates every row against the shared client upload row schema before import\nFINDING_5_DETAIL: a second, different edge case\n=== END DOR_SEMANTIC_SCAN ===\n'
} >"$TMP_ROOT/r7-dups.txt"
grep -v '^FINDING_5_' "$TMP_ROOT/r7-dups.txt" >"$TMP_ROOT/r7-drop.txt"
_retry_case scan "$TMP_ROOT/r7-dups.txt" bullets "$TMP_ROOT/r7-drop.txt"
_check "R7: accepted, and the restored finding is the dropped one" [ "$STEP_RC" -eq 0 ] &&
  [ "$(parse_dor_semantic --kind scan --result-file "$CASE_RF" 2>/dev/null | jq -r '.findings[] | select(.restored == true) | .detail')" = "a second, different edge case" ]

echo "=== contract drift: every contract line is in the evaluator's own prompt ==="
SP=$(dor_semantic_prompt scan "$TID" "$BODY30" "$TMP_ROOT/drift-scan.txt")
AP=$(dor_semantic_prompt audit "$TID" "$BODY30" "$TMP_ROOT/drift-audit.txt" "$TMP_ROOT/det.json")
missing=""
while IFS= read -r line; do
  grep -qxF -- "$line" <<<"$SP" || missing+="scan: $line"$'\n'
done <<<"$_DSP_CONTRACT_SCAN"
while IFS= read -r line; do
  grep -qxF -- "$line" <<<"$AP" || missing+="audit: $line"$'\n'
done <<<"$_DSP_CONTRACT_AUDIT"
if [ -z "$missing" ]; then _pass "contract lines match dor_semantic_prompt"; else _fail "contract drift: $missing"; fi

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
