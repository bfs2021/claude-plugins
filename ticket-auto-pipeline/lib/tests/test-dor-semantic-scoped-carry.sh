#!/usr/bin/env bash
# test-dor-semantic-scoped-carry.sh — rehearsal F85: a scan scoped to the
# changed sections cannot re-raise a finding whose units are all unchanged,
# so dor_semantic_lineage_from (with DOR_SEMANTIC_SCOPED_RESCAN=true) carries a
# prior structural finding of that kind forward instead of marking it
# resolved. Also: the spawn request records changed_sections, and
# dor_semantic_request_scoped reads it.
# Deterministic: findings JSON stands in for dor_semantic_findings.
# Usage: bash test-dor-semantic-scoped-carry.sh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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
_check() { # _check <desc> <command...>
  local desc="$1"
  shift
  if "$@" >/dev/null; then _pass "$desc"; else _fail "$desc"; fi
}

TMP_ROOT=$(mktemp -d)
export REPOS_ROOT="$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT
unset DOR_SEMANTIC_INERT_SECTIONS DOR_SEMANTIC_MAX_ROUNDS DOR_SEMANTIC_DRIFT_DEMOTE \
  DOR_SEMANTIC_ROUND_RESET_SHARE DOR_SEMANTIC_STRUCTURAL_CODES DOR_SEMANTIC_ADVISORY_CODES \
  DOR_SEMANTIC_PRIOR_PASSED DOR_SEMANTIC_SCOPED_RESCAN

# The iteration-13 shape: a slug rule stated two ways (Proposed Behaviour vs
# Technical Context), plus a missing criterion anchored in Proposed
# Behaviour. Round 1 adds criteria only.
BEHAVIOUR='* **Slug.** The slug is the title in lower case, with every run of characters that are not letters or digits replaced by `-`.'
CONTEXT='* Add `slugify(title)` (lower case, replace each run of `[^a-z0-9]` with `-`, trim `-` at both ends).'
BLANK='* A body that is not valid JSON counts as all three fields blank.'

_body() { # _body <extra AC lines>
  printf '## Summary\n\nPublish an article.\n\n## Proposed Behaviour\n\n%s\n%s\n\n## Technical Context\n\n%s\n\n## Acceptance Criteria\n\n- [ ] Creating an article returns status 201\n%s\n## Scope\n\n| Layer | Service | Area |\n| -- | -- | -- |\n| Backend | svc | create |\n' \
    "$BEHAVIOUR" "$BLANK" "$CONTEXT" "$1"
}

BODY0=$(_body "")
BODY1=$(_body "- [ ] A body with no \`article\` object returns status 422
")
# Round 1 that also rewords the Technical Context side of the contradiction.
BODY1_CTX=$(_body "- [ ] A body with no \`article\` object returns status 422
" | sed 's/`\[\^a-z0-9\]`/characters that are not letters or digits/')

H0=$(_dor_body_hash "$BODY0")
H1=$(_dor_body_hash "$BODY1")
H1C=$(_dor_body_hash "$BODY1_CTX")

F_CONTRA=$(jq -nc --arg q "$BEHAVIOUR" --arg qb "$CONTEXT" \
  '{code: "CONTRADICTORY_REQUIREMENTS", dimension: "contradictory_requirements", severity: "blocking",
    quote: $q, quote_b: $qb, detail: "non-ASCII titles slug differently", verified: true}')
F_CORE=$(jq -nc --arg q "$BLANK" \
  '{code: "MISSING_CORE_AC", dimension: "requirement_completeness", severity: "blocking",
    quote: $q, detail: "no criterion for a body with no article object", verified: true}')

R0=$(DOR_SEMANTIC_MAX_ROUNDS=2 dor_semantic_lineage_from null "$BODY0" "$H0" "[$F_CONTRA,$F_CORE]" '[]')
L0=$(jq -c '.lineage' <<<"$R0")
CONTRA_ID=$(jq -r '.findings[] | select(.code == "CONTRADICTORY_REQUIREMENTS") | .id' <<<"$R0")
CORE_ID=$(jq -r '.findings[] | select(.code == "MISSING_CORE_AC") | .id' <<<"$R0")

# ── 1. lineage stores a carry copy for structural findings only ───────────
_check "structural lineage entry has a carry copy with both quotes" \
  jq -e --arg id "$CONTRA_ID" '.findings[] | select(.id == $id) | .carry.quote_b != null and .carry.code == "CONTRADICTORY_REQUIREMENTS"' <<<"$L0"
_check "non-hold code (MISSING_CORE_AC) lineage entry has no carry copy" \
  jq -e --arg id "$CORE_ID" '.findings[] | select(.id == $id) | has("carry") | not' <<<"$L0"

# ── 2. scoped rescan that does not re-raise: contradiction held ───────────
R1=$(DOR_SEMANTIC_MAX_ROUNDS=2 DOR_SEMANTIC_SCOPED_RESCAN=true \
  dor_semantic_lineage_from "$L0" "$BODY1" "$H1" '[]' '[]')
_check "scoped: contradiction on unchanged units is carried, not resolved" \
  jq -e --arg id "$CONTRA_ID" '(.lineage.resolved | index($id)) == null and (.lineage.held | index($id)) != null' <<<"$R1"
_check "scoped: the carried finding stays a blocking verified finding" \
  jq -e --arg id "$CONTRA_ID" '[.findings[] | select(.id == $id and .severity == "blocking" and .verified == true and .lineage == "carried" and .carried_unseen == true)] | length == 1' <<<"$R1"
_check "scoped: MISSING_CORE_AC (non-structural) still resolves" \
  jq -e --arg id "$CORE_ID" '(.lineage.resolved | index($id)) != null' <<<"$R1"
_check "scoped: counts.held is 1" jq -e '.lineage.counts.held == 1' <<<"$R1"
_check "scoped: the carry copy survives into the next lineage" \
  jq -e --arg id "$CONTRA_ID" '.lineage.findings[] | select(.id == $id) | .carry.quote != null' <<<"$R1"
SEM1=$(dor_semantic_assemble "$H1" "$(jq -c '.findings' <<<"$R1")" '[]' \
  "{\"gaps\":$(jq -nc '{}')}" '{}' 2>/dev/null) || SEM1=""
if [ -n "$SEM1" ]; then
  CODES1=$(dor_semantic_blocking_codes "$SEM1" 2>/dev/null) || CODES1="[]"
  _check "scoped: the held finding still blocks (blocking codes non-empty)" \
    jq -e 'length > 0' <<<"$CODES1"
else
  _fail "scoped: dor_semantic_assemble produced no verdict for the held finding"
fi

# ── 3. a second scoped round keeps holding it ─────────────────────────────
L1=$(jq -c '.lineage' <<<"$R1")
R2=$(DOR_SEMANTIC_MAX_ROUNDS=2 DOR_SEMANTIC_SCOPED_RESCAN=true \
  dor_semantic_lineage_from "$L1" "$BODY1" "$H1" '[]' '[]')
_check "scoped, same body again: still held" \
  jq -e --arg id "$CONTRA_ID" '(.lineage.held | index($id)) != null and (.lineage.resolved | index($id)) == null' <<<"$R2"

# ── 4. an edit to one of its units releases it ────────────────────────────
R3=$(DOR_SEMANTIC_MAX_ROUNDS=2 DOR_SEMANTIC_SCOPED_RESCAN=true \
  dor_semantic_lineage_from "$L0" "$BODY1_CTX" "$H1C" '[]' '[]')
_check "scoped, Technical Context edited: contradiction resolves" \
  jq -e --arg id "$CONTRA_ID" '(.lineage.resolved | index($id)) != null and (.lineage.held | length) == 0' <<<"$R3"

# ── 5. unscoped (full) rescan keeps the old rule ──────────────────────────
R4=$(DOR_SEMANTIC_MAX_ROUNDS=2 dor_semantic_lineage_from "$L0" "$BODY1" "$H1" '[]' '[]')
_check "full rescan: a finding not re-raised resolves as before" \
  jq -e --arg id "$CONTRA_ID" '(.lineage.resolved | index($id)) != null and (.lineage.held | length) == 0' <<<"$R4"

# ── 6. a re-raised finding is carried once, not duplicated ────────────────
R5=$(DOR_SEMANTIC_MAX_ROUNDS=2 DOR_SEMANTIC_SCOPED_RESCAN=true \
  dor_semantic_lineage_from "$L0" "$BODY1" "$H1" "[$F_CONTRA]" '[]')
_check "scoped, re-raised: one finding with that id, not held" \
  jq -e --arg id "$CONTRA_ID" '([.findings[] | select(.id == $id)] | length == 1) and (.lineage.held | length) == 0' <<<"$R5"

# ── 7. a prior lineage without carry copies carries nothing ───────────────
L0_OLD=$(jq -c '.findings |= map(del(.carry))' <<<"$L0")
R6=$(DOR_SEMANTIC_MAX_ROUNDS=2 DOR_SEMANTIC_SCOPED_RESCAN=true \
  dor_semantic_lineage_from "$L0_OLD" "$BODY1" "$H1" '[]' '[]')
_check "legacy prior (no carry): resolves as before" \
  jq -e --arg id "$CONTRA_ID" '(.lineage.resolved | index($id)) != null' <<<"$R6"

# ── 8. the spawn request records changed_sections ─────────────────────────
printf '%s\n' "$BODY1" >"$TMP_ROOT/body.md"
dor_semantic_prompt scan --changed-sections "Acceptance Criteria|Verification Notes" T-1 \
  "$TMP_ROOT/body.md" "$TMP_ROOT/scan-result.txt" >/dev/null
REQ=$(dor_semantic_request_path "$TMP_ROOT/scan-result.txt")
_check "scoped prompt: request lists the changed sections" \
  jq -e '.changed_sections == ["Acceptance Criteria","Verification Notes"]' "$REQ"
_check "scoped prompt: dor_semantic_request_scoped is true" dor_semantic_request_scoped "$REQ"
dor_semantic_prompt scan T-1 "$TMP_ROOT/body.md" "$TMP_ROOT/scan-result.txt" >/dev/null
_check "full prompt: request has no changed_sections key" jq -e 'has("changed_sections") | not' "$REQ"
if dor_semantic_request_scoped "$REQ"; then
  _fail "full prompt: dor_semantic_request_scoped should be false"
else
  _pass "full prompt: dor_semantic_request_scoped is false"
fi
if dor_semantic_request_scoped "$TMP_ROOT/missing.request.json"; then
  _fail "missing request: dor_semantic_request_scoped should be false"
else
  _pass "missing request: dor_semantic_request_scoped is false"
fi

# ── 9. only CONTRADICTORY_REQUIREMENTS is held (review item 1) ────────────
# An INTENT_AC_MISMATCH quoting Proposed Behaviour is fixed by a new AC, so
# its unit stays unchanged when it resolves: a scoped rescan must release it.
F_INTENT=$(jq -nc --arg q "$BLANK" \
  '{code: "INTENT_AC_MISMATCH", dimension: "intent", severity: "blocking",
    quote: $q, detail: "no AC serves the blank-body behaviour", verified: true}')
RI0=$(DOR_SEMANTIC_MAX_ROUNDS=2 dor_semantic_lineage_from null "$BODY0" "$H0" "[$F_INTENT]" '[]')
INTENT_ID=$(jq -r '.findings[0].id' <<<"$RI0")
_check "structural non-hold code (INTENT_AC_MISMATCH): no carry copy" \
  jq -e '.lineage.findings[0] | has("carry") | not' <<<"$RI0"
RI1=$(DOR_SEMANTIC_MAX_ROUNDS=2 DOR_SEMANTIC_SCOPED_RESCAN=true \
  dor_semantic_lineage_from "$(jq -c '.lineage' <<<"$RI0")" "$BODY1" "$H1" '[]' '[]')
_check "scoped: INTENT_AC_MISMATCH on an unchanged unit resolves" \
  jq -e --arg id "$INTENT_ID" '(.lineage.resolved | index($id)) != null and (.lineage.held | length) == 0' <<<"$RI1"

# ── 10. a demoted contradiction is never held (review item 2) ─────────────
# Draft-passed policy: a new structural finding on an unchanged unit is
# demoted draft-passed-structural; it must get no carry copy.
RD0=$(DOR_SEMANTIC_MAX_ROUNDS=2 dor_semantic_lineage_from null "$BODY0" "$H0" '[]' '[]')
RD1=$(DOR_SEMANTIC_MAX_ROUNDS=2 DOR_SEMANTIC_PRIOR_PASSED=true \
  dor_semantic_lineage_from "$(jq -c '.lineage' <<<"$RD0")" "$BODY1" "$H1" "[$F_CONTRA]" '[]')
_check "draft-passed: the contradiction is demoted" \
  jq -e '.findings[0].demoted == "draft-passed-structural"' <<<"$RD1"
_check "draft-passed: a demoted contradiction has no carry copy" \
  jq -e '.lineage.findings[0] | has("carry") | not' <<<"$RD1"
RD2=$(DOR_SEMANTIC_MAX_ROUNDS=2 DOR_SEMANTIC_SCOPED_RESCAN=true \
  dor_semantic_lineage_from "$(jq -c '.lineage' <<<"$RD1")" "$BODY1" "$H1" '[]' '[]')
_check "scoped after a demotion: nothing held, nothing blocking" \
  jq -e '(.lineage.held | length) == 0 and ([.findings[] | select(.severity == "blocking")] | length) == 0' <<<"$RD2"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
