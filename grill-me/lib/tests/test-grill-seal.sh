#!/usr/bin/env bash
# ── test-grill-seal.sh ────────────────────────────────────────────────────────
# Test suite for grill-seal.sh — seal generation and verification.
# ───────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# Telemetry off (#645): with a session id set, grill_seal_generate rewrites
# open.json in every work dir listed in the developer's real session marker.
unset CLAUDE_CODE_SESSION_ID

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"

# shellcheck source=../grill-seal.sh
source "$LIB_DIR/grill-seal.sh"

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  echo "  PASS $1"
}
fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL $1: $2"
}

# ── Helper: run a function and capture its output + exit code ─────────────────
# Usage: run_capturing <func_name> <args...>
# Sets global: CAPTURED_OUT, CAPTURED_EXIT
run_capturing() {
  local func="$1"
  shift
  # Capture output and exit code without || true
  set +e
  CAPTURED_OUT=$("$func" "$@" 2>&1)
  CAPTURED_EXIT=$?
  set -e
}

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# ── Helper: create a minimal test document ────────────────────────────────────
make_doc() {
  cat <<'MD'
# Validated Business Intent

**Subject:** Test Subject
**Profile:** product-idea
**Readiness:** 88/100
**Recommendation:** ready

## Objective

Build a real-time collaboration feature for the document editor.

## Users & Problem

Enterprise users who need to co-edit documents simultaneously.

## Success Criteria

Users can see each other's cursors in real time within 500ms.

## Scope

### In scope

Real-time cursor presence, document locking.

### Out of scope

Video chat, voice chat, offline sync.

## Acceptance Criteria

- Two users can open the same document simultaneously
- Cursor positions update within 500ms
- Document state is consistent across clients

## Constraints

Must work within existing WebSocket infrastructure.

## Dependencies

Depends on operational WebSocket service v2.

## Risks

Network latency may exceed 500ms threshold.

## Edge Cases

_None identified_

## Assumptions (require validation)

_None identified_

## Resolved Questions

_No questions were asked — the input scored ready on the first round._

## Open Gaps

_No open gaps — all dimensions are present._

## Category Scores

| Dimension | Weight | Status | Contribution |
|-----------|--------|--------|-------------|
| Objective | 14 | present | 14 |
MD
}

# ── Helpers: a scored work dir, and a seal taken from it ──────────────────────
# make_result <work_dir> <readiness> <recommendation> <round> [profile]
# Writes the fields grill_seal_generate reads, in grill_score's result.json shape.
make_result() {
  mkdir -p "$1"
  jq -n --argjson r "$2" --arg rec "$3" --argjson round "$4" --arg p "${5:-product-idea}" \
    '{profile: $p, subject: "Test Subject", round: $round, readiness: $r,
      recommendation: $rec, critical_missing: "", flags: "", question_count: 0}' >"$1/result.json"
}

# seal_doc <doc> <readiness> <recommendation> <round>
# Seals <doc> from a work dir whose result.json holds those values.
seal_doc() {
  local wd="${1}.work"
  make_result "$wd" "$2" "$3" "$4"
  grill_seal_generate "$1" "$wd"
}

# seal_field <doc> <field> — the value of **<field>:** in the seal block.
seal_field() {
  sed -n "/^## Intent Seal\$/,\$s/^\\*\\*${2}:\\*\\* //p" "$1" | head -1
}

# ── Round-trip: generate → verify → VALID ─────────────────────────────────────
echo "=== Round-trip verification ==="

DOC="$SCRATCH/test-roundtrip.md"
make_doc >"$DOC"

run_capturing seal_doc "$DOC" 88 ready 1
if [ "$CAPTURED_EXIT" -eq 0 ]; then
  pass "seal generation succeeds"
else
  fail "seal generation succeeds" "exit code $CAPTURED_EXIT"
fi

# Verify
run_capturing grill_seal_verify "$DOC"
STATUS=$(echo "$CAPTURED_OUT" | grep "^GRILL_SEAL_STATUS=" | cut -d= -f2)

if [ "$CAPTURED_EXIT" -eq 0 ] && [ "$STATUS" = "VALID" ]; then
  pass "round-trip verify: VALID exit 0"
else
  fail "round-trip verify: VALID exit 0" "exit=$CAPTURED_EXIT, status=$STATUS"
fi

# Check metadata extraction
READY=$(echo "$CAPTURED_OUT" | grep "^GRILL_READINESS=" | cut -d= -f2)
REC=$(echo "$CAPTURED_OUT" | grep "^GRILL_RECOMMENDATION=" | cut -d= -f2)
PROF=$(echo "$CAPTURED_OUT" | grep "^GRILL_PROFILE=" | cut -d= -f2)

if [ "$READY" = "88" ] && [ "$REC" = "ready" ] && [ "$PROF" = "product-idea" ]; then
  pass "verify extracts metadata correctly"
else
  fail "verify extracts metadata" "readiness=$READY, rec=$REC, profile=$PROF"
fi

# ── Body edit → MISMATCH exit 4 ───────────────────────────────────────────────
echo "=== Tamper detection ==="

TAMPER_DOC="$SCRATCH/test-tamper.md"
make_doc >"$TAMPER_DOC"
seal_doc "$TAMPER_DOC" 88 ready 1 >/dev/null 2>&1

# Edit one byte in the body
sed -i 's/real-time/offline/' "$TAMPER_DOC"

run_capturing grill_seal_verify "$TAMPER_DOC"
TAMPER_STATUS=$(echo "$CAPTURED_OUT" | grep "^GRILL_SEAL_STATUS=" | cut -d= -f2)

if [ "$CAPTURED_EXIT" -eq 4 ] && [ "$TAMPER_STATUS" = "MISMATCH" ]; then
  pass "body edit → MISMATCH exit 4"
else
  fail "body edit → MISMATCH exit 4" "exit=$CAPTURED_EXIT, status=$TAMPER_STATUS"
fi

# ── Editing seal metadata Readiness → MISMATCH exit 4 ────────────────────────
META_TAMPER_DOC="$SCRATCH/test-meta-tamper.md"
make_doc >"$META_TAMPER_DOC"
seal_doc "$META_TAMPER_DOC" 22 do-not-proceed 1 >/dev/null 2>&1

# Change readiness from 22 to 95 inside the seal
sed -i 's/\*\*Readiness:\*\* 22/**Readiness:** 95/' "$META_TAMPER_DOC"

run_capturing grill_seal_verify "$META_TAMPER_DOC"
META_STATUS=$(echo "$CAPTURED_OUT" | grep "^GRILL_SEAL_STATUS=" | cut -d= -f2)

if [ "$CAPTURED_EXIT" -eq 4 ] && [ "$META_STATUS" = "MISMATCH" ]; then
  pass "seal metadata edit → MISMATCH exit 4"
else
  fail "seal metadata edit → MISMATCH exit 4" "exit=$CAPTURED_EXIT, status=$META_STATUS"
fi

# ── No seal → exit 3 ─────────────────────────────────────────────────────────
echo "=== No-seal and missing file ==="

NO_SEAL_DOC="$SCRATCH/test-noseal.md"
make_doc >"$NO_SEAL_DOC"

run_capturing grill_seal_verify "$NO_SEAL_DOC"
NO_SEAL_STATUS=$(echo "$CAPTURED_OUT" | grep "^GRILL_SEAL_STATUS=" | cut -d= -f2)

if [ "$CAPTURED_EXIT" -eq 3 ] && [ "$NO_SEAL_STATUS" = "NO_SEAL" ]; then
  pass "no seal → exit 3 NO_SEAL"
else
  fail "no seal → exit 3 NO_SEAL" "exit=$CAPTURED_EXIT, status=$NO_SEAL_STATUS"
fi

# ── Missing file → exit 2 ────────────────────────────────────────────────────
run_capturing grill_seal_verify "$SCRATCH/nonexistent.md"

if [ "$CAPTURED_EXIT" -eq 2 ]; then
  pass "missing file → exit 2"
else
  fail "missing file → exit 2" "exit=$CAPTURED_EXIT"
fi

# ── Double-generate refused ───────────────────────────────────────────────────
echo "=== Double-seal prevention ==="

DOUBLE_DOC="$SCRATCH/test-double.md"
make_doc >"$DOUBLE_DOC"
seal_doc "$DOUBLE_DOC" 88 ready 1 >/dev/null 2>&1

run_capturing seal_doc "$DOUBLE_DOC" 88 ready 1
if [ "$CAPTURED_EXIT" -ne 0 ]; then
  pass "double-generate refused"
else
  fail "double-generate refused" "should have failed"
fi

# ── Trailing newline independence ────────────────────────────────────────────
echo "=== Trailing whitespace independence ==="

TRAIL_DOC="$SCRATCH/test-trailing.md"
make_doc >"$TRAIL_DOC"
seal_doc "$TRAIL_DOC" 88 ready 1 >/dev/null 2>&1

# Verify original
run_capturing grill_seal_verify "$TRAIL_DOC"
orig_exit=$CAPTURED_EXIT

# Add trailing newlines and verify again
echo "" >>"$TRAIL_DOC"
echo "" >>"$TRAIL_DOC"

run_capturing grill_seal_verify "$TRAIL_DOC"
trail_exit=$CAPTURED_EXIT

if [ "$orig_exit" -eq 0 ] && [ "$trail_exit" -eq 0 ]; then
  pass "trailing newlines after hash don't break validation"
else
  fail "trailing newlines after hash" "orig=$orig_exit, with_trailing=$trail_exit"
fi

# ── Malformed hash value → exit 3 NO_SEAL ────────────────────────────────────
echo "=== Malformed hash ==="

MALFORM_DOC="$SCRATCH/test-malform.md"
make_doc >"$MALFORM_DOC"
seal_doc "$MALFORM_DOC" 88 ready 1 >/dev/null 2>&1

# Corrupt the hash to be non-hex
sed -i 's/sha256:[a-f0-9]*/sha256:zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz/' "$MALFORM_DOC"

run_capturing grill_seal_verify "$MALFORM_DOC"
MALFORM_STATUS=$(echo "$CAPTURED_OUT" | grep "^GRILL_SEAL_STATUS=" | cut -d= -f2)

if [ "$CAPTURED_EXIT" -eq 3 ] && [ "$MALFORM_STATUS" = "NO_SEAL" ]; then
  pass "malformed hash → exit 3 NO_SEAL"
else
  fail "malformed hash → exit 3 NO_SEAL" "exit=$CAPTURED_EXIT, status=$MALFORM_STATUS"
fi

# ── Content-Hash is last non-empty line ──────────────────────────────────────
echo "=== Content-Hash position ==="

CH_DOC="$SCRATCH/test-ch-position.md"
make_doc >"$CH_DOC"
seal_doc "$CH_DOC" 88 ready 1 >/dev/null 2>&1

# Get the last non-empty line
LAST_LINE=$(grep -v '^[[:space:]]*$' "$CH_DOC" | tail -1)
if grep -q '^\*\*Content-Hash:\*\*' <<<"$LAST_LINE"; then
  pass "Content-Hash is the last non-empty line"
else
  fail "Content-Hash is the last non-empty line" "last line: $LAST_LINE"
fi

# ── The seal takes its values from result.json (seam-bash-derives slice 4) ────
echo "=== Seal values come from result.json ==="

# A doc is unchanged by a refused seal: same bytes, no seal block.
unchanged() {
  cmp -s "$1" "$2" && ! grep -q '^## Intent Seal$' "$1"
}

# Stale round: the agent scored round 2, but still holds round 1's numbers.
STALE_DOC="$SCRATCH/test-stale.md"
make_doc >"$STALE_DOC"
STALE_WD="$SCRATCH/work-stale"
make_result "$STALE_WD" 85 ready 2
run_capturing grill_seal_generate "$STALE_DOC" "$STALE_WD"
if [ "$CAPTURED_EXIT" -eq 0 ] && [ "$(seal_field "$STALE_DOC" Readiness)" = "85" ] &&
  [ "$(seal_field "$STALE_DOC" Recommendation)" = "ready" ] && [ "$(seal_field "$STALE_DOC" Rounds)" = "2" ] &&
  [ "$(seal_field "$STALE_DOC" Profile)" = "product-idea" ]; then
  pass "the seal carries the latest result.json's readiness, recommendation, round and profile"
else
  fail "the seal carries the latest result.json" "exit=$CAPTURED_EXIT out=$CAPTURED_OUT"
fi
if grill_seal_verify "$STALE_DOC" >/dev/null 2>&1 && [[ "$(seal_field "$STALE_DOC" Generated)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]]; then
  pass "a result.json seal verifies, with a bash-stamped UTC Generated time"
else
  fail "a result.json seal verifies" "$(grill_seal_verify "$STALE_DOC" 2>&1)"
fi

# The old call shape (values as arguments) is refused: nothing the agent
# copies can reach the seal.
LEGACY_DOC="$SCRATCH/test-legacy.md"
make_doc >"$LEGACY_DOC"
cp "$LEGACY_DOC" "$SCRATCH/legacy.orig"
run_capturing grill_seal_generate "$LEGACY_DOC" "product-idea" "60" "do-not-proceed" "1" "2026-07-26T00:00:00Z"
if [ "$CAPTURED_EXIT" -ne 0 ] && unchanged "$LEGACY_DOC" "$SCRATCH/legacy.orig"; then
  pass "a call passing readiness/recommendation as arguments is refused and writes no seal"
else
  fail "a call passing readiness/recommendation as arguments is refused" "exit=$CAPTURED_EXIT"
fi

# result.json from an earlier round than assessment.json: re-scored? No.
LAG_DOC="$SCRATCH/test-lag.md"
make_doc >"$LAG_DOC"
cp "$LAG_DOC" "$SCRATCH/lag.orig"
LAG_WD="$SCRATCH/work-lag"
make_result "$LAG_WD" 85 ready 2
echo '{"round": 3, "dimensions": []}' >"$LAG_WD/assessment.json"
run_capturing grill_seal_generate "$LAG_DOC" "$LAG_WD"
if [ "$CAPTURED_EXIT" -ne 0 ] && unchanged "$LAG_DOC" "$SCRATCH/lag.orig" && [[ "$CAPTURED_OUT" == *round* ]]; then
  pass "a result.json older than the assessment's round is not sealed"
else
  fail "a result.json older than the assessment's round is not sealed" "exit=$CAPTURED_EXIT out=$CAPTURED_OUT"
fi
echo '{"round": 2, "dimensions": []}' >"$LAG_WD/assessment.json"
run_capturing grill_seal_generate "$LAG_DOC" "$LAG_WD"
[ "$CAPTURED_EXIT" -eq 0 ] && [ "$(seal_field "$LAG_DOC" Rounds)" = "2" ] &&
  pass "the same rounds in assessment.json and result.json seal" ||
  fail "the same rounds in assessment.json and result.json seal" "exit=$CAPTURED_EXIT out=$CAPTURED_OUT"

# No score: missing result.json.
NOSCORE_DOC="$SCRATCH/test-noscore.md"
make_doc >"$NOSCORE_DOC"
cp "$NOSCORE_DOC" "$SCRATCH/noscore.orig"
mkdir -p "$SCRATCH/work-empty"
run_capturing grill_seal_generate "$NOSCORE_DOC" "$SCRATCH/work-empty"
if [ "$CAPTURED_EXIT" -ne 0 ] && unchanged "$NOSCORE_DOC" "$SCRATCH/noscore.orig"; then
  pass "missing result.json → non-zero, no seal written"
else
  fail "missing result.json → non-zero, no seal written" "exit=$CAPTURED_EXIT"
fi

# Unparseable or out-of-contract result.json → no seal.
bad_result() {
  local name="$1" json="$2" doc="$SCRATCH/test-bad-$1.md" wd="$SCRATCH/work-bad-$1"
  make_doc >"$doc"
  cp "$doc" "$doc.orig"
  mkdir -p "$wd"
  printf '%s\n' "$json" >"$wd/result.json"
  run_capturing grill_seal_generate "$doc" "$wd"
  if [ "$CAPTURED_EXIT" -ne 0 ] && unchanged "$doc" "$doc.orig"; then
    pass "result.json ${name} → no seal"
  else
    fail "result.json ${name} → no seal" "exit=$CAPTURED_EXIT"
  fi
}
bad_result unparseable '{"readiness": 88, "recommendation": "ready"'
bad_result "readiness not a number" '{"profile":"product-idea","round":1,"readiness":"88","recommendation":"ready"}'
bad_result "readiness over 100" '{"profile":"product-idea","round":1,"readiness":180,"recommendation":"ready"}'
bad_result "unknown recommendation" '{"profile":"product-idea","round":1,"readiness":88,"recommendation":"great"}'
bad_result "round 0" '{"profile":"product-idea","round":0,"readiness":88,"recommendation":"ready"}'
bad_result "profile with a newline" '{"profile":"product-idea\n**Readiness:** 99","round":1,"readiness":88,"recommendation":"ready"}'
bad_result "no profile" '{"round":1,"readiness":88,"recommendation":"ready"}'

# ── Existing seals still verify (the verifier is unchanged) ──────────────────
echo "=== Pre-0.7.0 seal ==="

# Written by grill-me 0.6.0's grill_seal_generate (values passed as arguments).
run_capturing grill_seal_verify "$TEST_DIR/fixtures/sealed-intent-v0.6.0.md"
if [ "$CAPTURED_EXIT" -eq 0 ] && [[ "$CAPTURED_OUT" == *"GRILL_SEAL_STATUS=VALID"* ]] &&
  [[ "$CAPTURED_OUT" == *"GRILL_READINESS=88"* ]] && [[ "$CAPTURED_OUT" == *"GRILL_GENERATED=2026-11-13T00:00:00Z"* ]]; then
  pass "a seal written by grill-me 0.6.0 verifies VALID"
else
  fail "a seal written by grill-me 0.6.0 verifies VALID" "exit=$CAPTURED_EXIT out=$CAPTURED_OUT"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo "$PASS/$TOTAL passed"
if [ "$FAIL" -gt 0 ]; then
  echo "$FAIL test(s) failed"
  exit 1
fi
echo "All tests passed"
