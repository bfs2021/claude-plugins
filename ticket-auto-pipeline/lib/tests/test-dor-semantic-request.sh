#!/usr/bin/env bash
# test-dor-semantic-request.sh — TICKET and BODY_HASH come from the spawn
# request bash writes, not from the evaluator's echo (seam-bash-derives
# slice 3). The fixtures under fixtures/dor/semantic/ are real
# dor-semantic-agent output for fixture 30 (30-scan.txt) with literal values:
#   30-slip-{scan,audit}.txt      BODY_HASH one character off the real hash
#   30-noticket-{scan,audit}.txt  no TICKET line
# Deterministic: no model runs.
# Usage: bash test-dor-semantic-request.sh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES_DIR="$LIB_DIR/tests/fixtures/dor"
SEMANTIC_DIR="$FIXTURES_DIR/semantic"
PARSER="$LIB_DIR/dor-semantic-parse.sh"
BODY30="$FIXTURES_DIR/30-chained-draft.md"
TID="DRAFT-client-upload"

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
_check() { # _check <label> <cmd...>
  local label="$1"
  shift
  if "$@"; then _pass "$label"; else _fail "$label"; fi
}

TMP_ROOT=$(mktemp -d)
export REPOS_ROOT="$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT
unset DOR_SEMANTIC_ADVISORY_CODES DOR_STRICT_TEST_DATA

REAL=$(_dor_body_hash "$(cat "$BODY30")")

# _parse <kind> <file> — the parser's JSON, or empty on a parse failure.
_parse() { bash "$PARSER" --kind "$1" --result-file "$2" 2>/dev/null || true; }

# _diff_chars <a> <b> — number of positions at which two equal-length strings differ.
_diff_chars() {
  local a="$1" b="$2" i n=0
  [ "${#a}" -eq "${#b}" ] || {
    echo 99
    return 0
  }
  for ((i = 0; i < ${#a}; i++)); do
    [ "${a:i:1}" = "${b:i:1}" ] || n=$((n + 1))
  done
  echo "$n"
}

# _spawn <dir> [<attempt>] — what a caller does before spawning: build both
# prompts (which writes both requests) into <dir>.
_spawn() {
  local dir="$1" attempt="${2:-1}"
  mkdir -p "$dir"
  cp "$BODY30" "$dir/body.md"
  dor_semantic_prompt scan --attempt "$attempt" "$TID" "$dir/body.md" "$dir/scan-result.txt" >"$dir/scan-prompt.txt"
  dor_semantic_prompt audit --attempt "$attempt" "$TID" "$dir/body.md" "$dir/audit-result.txt" "$dir/dor-result.json" >"$dir/audit-prompt.txt"
}

# _findings <dir> <scan-file> <audit-file> [<scan-req> <audit-req>] —
# sets F_RC, F_OUT, F_ERR.
_findings() {
  local dir="$1" sf="$2" af="$3" sr="${4-$(dor_semantic_request_path "$1/scan-result.txt")}"
  local ar="${5-$(dor_semantic_request_path "$1/audit-result.txt")}"
  local s a errf
  s=$(_parse scan "$sf")
  a=$(_parse audit "$af")
  errf=$(mktemp)
  F_RC=0
  F_OUT=$(dor_semantic_findings "$TID" "$(cat "$dir/body.md")" "$s" "$a" "$sr" "$ar" 2>"$errf") || F_RC=$?
  F_ERR=$(cat "$errf")
  rm -f "$errf"
}

echo "--- fixtures ---"

slip_s=$(sed -n 's/^BODY_HASH: //p' "$SEMANTIC_DIR/30-slip-scan.txt")
slip_a=$(sed -n 's/^BODY_HASH: //p' "$SEMANTIC_DIR/30-slip-audit.txt")
_check "30-slip-scan BODY_HASH is one character off the body's hash" [ "$(_diff_chars "$slip_s" "$REAL")" = "1" ]
_check "30-slip-audit BODY_HASH is one character off the body's hash" [ "$(_diff_chars "$slip_a" "$REAL")" = "1" ]
_check "30-noticket scan and audit carry no TICKET line" \
  bash -c '! grep -q "^TICKET:" "$1" && ! grep -q "^TICKET:" "$2"' _ \
  "$SEMANTIC_DIR/30-noticket-scan.txt" "$SEMANTIC_DIR/30-noticket-audit.txt"
_check "the fixtures carry no tracker id" \
  bash -c '! grep -Eq "\b(WIL|CRE|PRO)-[0-9]+" "$@"' _ "$SEMANTIC_DIR"/30-slip-*.txt "$SEMANTIC_DIR"/30-noticket-*.txt

echo "--- parser: TICKET and BODY_HASH are optional ---"

ws="$TMP_ROOT/parse"
mkdir -p "$ws"
sed '/^BODY_HASH:/d' "$SEMANTIC_DIR/30-noticket-scan.txt" >"$ws/noecho-scan.txt"
sed '/^BODY_HASH:/d' "$SEMANTIC_DIR/30-noticket-audit.txt" >"$ws/noecho-audit.txt"
for k in scan audit; do
  out=$(_parse "$k" "$SEMANTIC_DIR/30-noticket-${k}.txt")
  _check "parse: a ${k} without TICKET is ok" [ "$(jq -r '.parse_status // ""' <<<"$out")" = "ok" ]
  out=$(_parse "$k" "$ws/noecho-${k}.txt")
  _check "parse: a ${k} without TICKET or BODY_HASH is ok, both empty" \
    [ "$(jq -r '"\(.parse_status)|\(.ticket)|\(.body_hash)"' <<<"$out" 2>/dev/null)" = "ok||" ]
  out=$(_parse "$k" "$SEMANTIC_DIR/30-slip-${k}.txt")
  _check "parse: a ${k} echoing a slipped hash still parses (the echo is kept as data)" \
    [ "$(jq -r '.parse_status // ""' <<<"$out")" = "ok" ]
done
sed '/^SCHEMA_VERSION:/d' "$ws/noecho-scan.txt" >"$ws/noschema-scan.txt"
_check "parse: SCHEMA_VERSION is still required" \
  [ "$(jq -r .parse_status <<<"$(_parse scan "$ws/noschema-scan.txt")")" = "invalid" ]

echo "--- the prompt writes the request and stops asking for the echo ---"

d="$TMP_ROOT/spawn1"
_spawn "$d" 2
for k in scan audit; do
  req=$(dor_semantic_request_path "$d/${k}-result.txt")
  _check "request: ${k} request sits next to the result file" [ "$(dirname "$req")" = "$d" ]
  _check "request: ${k} request carries kind, ticket, body_hash, attempt and the result path" \
    [ "$(jq -r '"\(.kind)|\(.ticket)|\(.body_hash)|\(.attempt)|\(.result_file)"' "$req" 2>/dev/null)" = "${k}|${TID}|${REAL}|2|$d/${k}-result.txt" ]
  _check "prompt: the ${k} prompt asks for no TICKET or BODY_HASH line" \
    bash -c '! grep -Eq "^(TICKET|BODY_HASH):" "$1"' _ "$d/${k}-prompt.txt"
  _check "prompt: the ${k} prompt carries no body hash" bash -c '! grep -q "sha256:" "$1"' _ "$d/${k}-prompt.txt"
done
d0="$TMP_ROOT/spawn0"
mkdir -p "$d0"
cp "$BODY30" "$d0/body.md"
dor_semantic_prompt scan "$TID" "$d0/body.md" "$d0/scan-result.txt" >/dev/null
_check "request: attempt defaults to 1" [ "$(jq -r .attempt "$(dor_semantic_request_path "$d0/scan-result.txt")" 2>/dev/null)" = "1" ]
rc=0
dor_semantic_prompt scan "$TID" "$d0/missing-body.md" "$d0/scan-result.txt" >/dev/null 2>&1 || rc=$?
_check "request: a missing body leaves no request behind (prompt rc 0)" \
  bash -c '[ "$1" = 0 ] && [ ! -e "$2" ]' _ "$rc" "$(dor_semantic_request_path "$d0/scan-result.txt")"

echo "--- slip and missing TICKET pass on the request ---"

_findings "$d" "$SEMANTIC_DIR/30-slip-scan.txt" "$SEMANTIC_DIR/30-slip-audit.txt"
_check "findings: a one-character BODY_HASH slip is not rejected" [ "$F_RC" = "0" ]
_check "findings: the slipped echo is reported as a warning" grep -q "BODY_HASH.*ignored" <<<"$F_ERR"
slip_n=$(jq '.findings | length' <<<"$F_OUT" 2>/dev/null || echo x)
_findings "$d" "$SEMANTIC_DIR/30-noticket-scan.txt" "$SEMANTIC_DIR/30-noticket-audit.txt"
_check "findings: a result without TICKET is not rejected" [ "$F_RC" = "0" ]
_check "findings: slip and no-ticket judge the same four findings" bash -c '[ "$1" = 4 ] && [ "$2" = 4 ]' _ \
  "$slip_n" "$(jq '.findings | length' <<<"$F_OUT" 2>/dev/null || echo x)"
_findings "$d" "$ws/noecho-scan.txt" "$ws/noecho-audit.txt"
_check "findings: a result with no echo at all passes on the request, silently" \
  bash -c '[ "$1" = 0 ] && [ -z "$2" ]' _ "$F_RC" "$F_ERR"

echo "--- the request is the real binding ---"

echo "- [ ] A criterion added after the spawn" >>"$d/body.md"
_findings "$d" "$ws/noecho-scan.txt" "$ws/noecho-audit.txt"
_check "findings: a body edited after the spawn is rejected (rc 2)" [ "$F_RC" = "2" ]
_check "findings: the rejection says the body changed since the spawn" grep -q "changed since" <<<"$F_ERR"
# An echo of the NEW hash cannot launder a stale spawn.
new=$(_dor_body_hash "$(cat "$d/body.md")")
sed "s|^SCHEMA_VERSION: 1|SCHEMA_VERSION: 1\nTICKET: ${TID}\nBODY_HASH: ${new}|" "$ws/noecho-scan.txt" >"$ws/newecho-scan.txt"
sed "s|^SCHEMA_VERSION: 1|SCHEMA_VERSION: 1\nTICKET: ${TID}\nBODY_HASH: ${new}|" "$ws/noecho-audit.txt" >"$ws/newecho-audit.txt"
_findings "$d" "$ws/newecho-scan.txt" "$ws/newecho-audit.txt"
_check "findings: echoing the edited body's hash does not override the request" [ "$F_RC" = "2" ]

d2="$TMP_ROOT/spawn2"
_spawn "$d2"
jq -c '.ticket = "DRAFT-other"' "$(dor_semantic_request_path "$d2/audit-result.txt")" >"$ws/req.tmp"
mv "$ws/req.tmp" "$(dor_semantic_request_path "$d2/audit-result.txt")"
_findings "$d2" "$ws/noecho-scan.txt" "$ws/noecho-audit.txt"
_check "findings: a request for another ticket is rejected (rc 2)" [ "$F_RC" = "2" ]

echo "--- a missing request is never silent ---"

d3="$TMP_ROOT/spawn3"
_spawn "$d3"
rm -f "$(dor_semantic_request_path "$d3/scan-result.txt")" "$(dor_semantic_request_path "$d3/audit-result.txt")"
_findings "$d3" "$SEMANTIC_DIR/30-noticket-scan.txt" "$SEMANTIC_DIR/30-noticket-audit.txt"
_check "fallback: no request and no TICKET echo is rejected (rc 2)" [ "$F_RC" = "2" ]
sed "s|^SCHEMA_VERSION: 1|SCHEMA_VERSION: 1\nTICKET: ${TID}|" "$SEMANTIC_DIR/30-noticket-scan.txt" >"$ws/echo-scan.txt"
sed "s|^SCHEMA_VERSION: 1|SCHEMA_VERSION: 1\nTICKET: ${TID}|" "$SEMANTIC_DIR/30-noticket-audit.txt" >"$ws/echo-audit.txt"
_findings "$d3" "$ws/echo-scan.txt" "$ws/echo-audit.txt"
_check "fallback: no request, a correct echo passes" [ "$F_RC" = "0" ]
_check "fallback: ... with a warning naming the missing request" grep -q "request missing" <<<"$F_ERR"
_findings "$d3" "$SEMANTIC_DIR/30-slip-scan.txt" "$SEMANTIC_DIR/30-slip-audit.txt"
_check "fallback: no request, a slipped echo is rejected as before (rc 2)" [ "$F_RC" = "2" ]
echo "not json" >"$(dor_semantic_request_path "$d3/scan-result.txt")"
_findings "$d3" "$ws/echo-scan.txt" "$ws/echo-audit.txt"
_check "fallback: an unreadable request warns and uses the echo" \
  bash -c '[ "$1" = 0 ] && grep -q "request unreadable" <<<"$2"' _ "$F_RC" "$F_ERR"
_findings "$d3" "$ws/echo-scan.txt" "$ws/echo-audit.txt" "" ""
_check "fallback: no request given at all warns too" \
  bash -c '[ "$1" = 0 ] && grep -q "no spawn request" <<<"$2"' _ "$F_RC" "$F_ERR"

echo "--- dor_semantic_apply passes the requests through ---"

d4="$TMP_ROOT/spawn4"
_spawn "$d4"
write_ticket_manifest "$TID" "INIT-1" "feature" '[]' >/dev/null
set_ticket_readiness "$TID" "ready" '[]' '[]' "{\"body_hash\": \"${REAL}\"}" >/dev/null
rc=0
dor_semantic_apply "$TID" "$d4/body.md" "$(_parse scan "$SEMANTIC_DIR/30-slip-scan.txt")" \
  "$(_parse audit "$SEMANTIC_DIR/30-slip-audit.txt")" \
  "$(dor_semantic_request_path "$d4/scan-result.txt")" "$(dor_semantic_request_path "$d4/audit-result.txt")" \
  >/dev/null 2>&1 || rc=$?
_check "apply: a slipped result is stored (rc 0)" [ "$rc" = "0" ]
_check "apply: the stored verdict carries the bash-computed hash" \
  [ "$(get_ticket_manifest_field "$TID" ready | jq -r '.semantic.body_hash // ""')" = "$REAL" ]

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
