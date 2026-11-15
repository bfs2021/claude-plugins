#!/usr/bin/env bash
# test-planner-corpus.sh — replay real planner output (lib/tests/corpus/)
# through the deterministic readers it once broke (seam-bash-derives).
#
# Slice 1 cases, all from dispatch rehearsal iteration 10 (s10-crosscheck):
#   F67  Specify's start line said "for 7 tickets", the phase wrote 8 specs,
#        and carve_scope blocked a clean plan. With the fix, carve_scope
#        compares the spec slugs bash recorded at Specify end, never a count
#        an agent typed. The same snapshot with a spec really lost still
#        blocks (CARVE_SCOPE_LOST); with no Specify record it fails closed
#        (CHECK_ERRORED), never passes.
#   F70  Consensus's corrected second `done` was dropped as a duplicate with
#        rc 0, so the agent never knew. A suppressed duplicate now returns 3
#        and says so on stderr; the log keeps the first line.
# Plus a privacy guard: the corpus sits in a public repo.
#
# Run: bash ticket-planner/lib/tests/test-planner-corpus.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."
CORPUS="${SCRIPT_DIR}/corpus"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export REPOS_ROOT="${WORK}/repos"
export HOME="${WORK}/home"
mkdir -p "$REPOS_ROOT" "$HOME"

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-crosscheck-propagation.sh"
[ -f "${LIB_DIR}/planner-phase-results.sh" ] && source "${LIB_DIR}/planner-phase-results.sh"

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

echo "=== planner corpus replay (seam-bash-derives) ==="

# replay <snap> <init> — copy a snapshot into a scratch initiative.
replay() {
  local snap="$1" init="$2" dir="${REPOS_ROOT}/.ticket-auto/initiatives/$2"
  rm -rf "$dir"
  mkdir -p "${dir}/artifacts"
  cp "${CORPUS}/${snap}/state.log" "${dir}/state.log"
  cp -r "${CORPUS}/${snap}/specs" "${dir}/artifacts/specs"
  printf '%s\n' "$dir"
}

# Specify end, as the router runs it: bash records what is on disk.
specify_end() {
  declare -f planner_specify_result_ensure >/dev/null 2>&1 || return 1
  planner_specify_result_ensure "$1"
}

has_code() { grep -q "planner-crosscheck-propagation: $1 " <<<"$2"; }

# ── privacy ──────────────────────────────────────────────────────────────────
echo "--- corpus carries no private data ---"
leaks=$(grep -rInE 'INIT-[0-9]{6,}|WIL-[0-9]|/home/[a-z]|dexter|mortal|willard|lin_api_|sk-ant-|ghp_|github_pat_|xox[bp]-' "$CORPUS" 2>/dev/null)
emails=$(grep -rIhoE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$CORPUS" 2>/dev/null |
  grep -vE '@(conduit\.test|example\.(com|org|net))$')
if [ -z "$leaks" ] && [ -z "$emails" ]; then
  pass "no tracker ids, real initiative ids, home paths, tokens or e-mails"
else
  fail "no tracker ids, real initiative ids, home paths, tokens or e-mails" "${leaks}${emails}"
fi

if [ -f "${CORPUS}/MANIFEST.tsv" ] && [ -f "${CORPUS}/labels.tsv" ] &&
  awk -F'\t' 'NR > 1 { print $1 }' "${CORPUS}/MANIFEST.tsv" | while read -r s; do [ -d "${CORPUS}/$s" ] || exit 1; done; then
  pass "every MANIFEST.tsv snapshot exists"
else
  fail "every MANIFEST.tsv snapshot exists" "missing MANIFEST/labels or a listed directory"
fi

# ── F67: the guessed count no longer blocks ─────────────────────────────────
echo "--- F67: 8 specs on disk, Specify's start line guessed 7 ---"
INIT=INIT-corpus-f67
DIR=$(replay s10-crosscheck "$INIT")
if grep -q '|Specify|synthesize|start|.*for 7 tickets' "${DIR}/state.log" &&
  [ "$(find "${DIR}/artifacts/specs" -name '*.md' ! -name INDEX.md | wc -l)" -eq 8 ]; then
  pass "snapshot still holds the F67 shape (start says 7, 8 specs)"
else
  fail "snapshot still holds the F67 shape (start says 7, 8 specs)" "corpus changed"
fi
specify_end "$INIT"
RESULT="${DIR}/artifacts/phase-results/specify.json"
if [ "$(jq -r '.count' "$RESULT" 2>/dev/null)" = "8" ] &&
  [ "$(jq -r '.derived_by' "$RESULT" 2>/dev/null)" = "bash" ]; then
  pass "Specify end records 8 slugs, derived by bash"
else
  fail "Specify end records 8 slugs, derived by bash" "$(cat "$RESULT" 2>&1)"
fi
OUT=$(planner_crosscheck_propagation "$INIT" 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && ! has_code CARVE_SCOPE_LOST "$OUT" && ! has_code CHECK_ERRORED "$OUT"; then
  pass "F67 snapshot passes carve scope"
else
  fail "F67 snapshot passes carve scope" "rc=${RC} ${OUT}"
fi

# ── fail closed ──────────────────────────────────────────────────────────────
echo "--- no Specify record: CHECK_ERRORED, never a pass ---"
INIT=INIT-corpus-missing
DIR=$(replay s10-crosscheck "$INIT")
OUT=$(planner_crosscheck_propagation "$INIT" 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && has_code CHECK_ERRORED "$OUT"; then
  pass "missing specify.json is CHECK_ERRORED"
else
  fail "missing specify.json is CHECK_ERRORED" "rc=${RC} ${OUT}"
fi

mkdir -p "${DIR}/artifacts/phase-results"
printf 'Proposal written, 8 ticket specs\n' >"${DIR}/artifacts/phase-results/specify.json"
OUT=$(planner_crosscheck_propagation "$INIT" 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && has_code CHECK_ERRORED "$OUT"; then
  pass "unparseable specify.json is CHECK_ERRORED"
else
  fail "unparseable specify.json is CHECK_ERRORED" "rc=${RC} ${OUT}"
fi

echo '{"version":1,"phase":"Specify","specs":["a","../x"],"count":2}' >"${DIR}/artifacts/phase-results/specify.json"
OUT=$(planner_crosscheck_propagation "$INIT" 2>&1)
if has_code CHECK_ERRORED "$OUT"; then
  pass "a slug with a path in it is CHECK_ERRORED"
else
  fail "a slug with a path in it is CHECK_ERRORED" "$OUT"
fi

source "${LIB_DIR}/planner-crosscheck.sh"
if ! _planner_crosscheck_is_warn_code CHECK_ERRORED; then
  pass "CHECK_ERRORED is blocking, not warn"
else
  fail "CHECK_ERRORED is blocking, not warn" "listed in PLANNER_CROSSCHECK_WARN_CODES"
fi

# ── a real carve still blocks ────────────────────────────────────────────────
echo "--- a spec lost after Specify: CARVE_SCOPE_LOST ---"
INIT=INIT-corpus-carve
DIR=$(replay s10-crosscheck "$INIT")
specify_end "$INIT"
rm -f "${DIR}/artifacts/specs/web-accounts.md"
OUT=$(planner_crosscheck_propagation "$INIT" 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && has_code CARVE_SCOPE_LOST "$OUT" && grep -q 'web-accounts' <<<"$OUT"; then
  pass "lost spec blocks and is named"
else
  fail "lost spec blocks and is named" "rc=${RC} ${OUT}"
fi

echo "--- a spec added after Specify: CARVE_SCOPE_LOST ---"
INIT=INIT-corpus-split
DIR=$(replay s10-crosscheck "$INIT")
specify_end "$INIT"
printf '# web-editor\n\n## Title\n\nSplit out of web-publish-article\n' >"${DIR}/artifacts/specs/web-editor.md"
OUT=$(planner_crosscheck_propagation "$INIT" 2>&1)
if has_code CARVE_SCOPE_LOST "$OUT" && grep -q 'web-editor' <<<"$OUT"; then
  pass "added spec blocks and is named"
else
  fail "added spec blocks and is named" "$OUT"
fi

echo "--- a TD spec synthesis wrote after Specify is not a carve ---"
INIT=INIT-corpus-td
DIR=$(replay s10-crosscheck "$INIT")
specify_end "$INIT"
printf '%s\n# api-register-test-data\n' "${PLANNER_TESTDATA_SYNTH_MARKER:-<!-- planner:testdata-synth v1 -->}" \
  >"${DIR}/artifacts/specs/api-register-test-data.md"
OUT=$(planner_crosscheck_propagation "$INIT" 2>&1)
RC=$?
if [ "$RC" -eq 0 ]; then
  pass "synth TD spec ignored"
else
  fail "synth TD spec ignored" "rc=${RC} ${OUT}"
fi

# ── Specify-end recording follows the log ────────────────────────────────────
echo "--- the record follows Specify's latest attempt ---"
INIT=INIT-corpus-rerun
DIR=$(replay s10-crosscheck "$INIT")
RESULT="${DIR}/artifacts/phase-results/specify.json"
head -17 "${CORPUS}/s10-crosscheck/state.log" >"${DIR}/state.log" # through Specify start
specify_end "$INIT"
if [ ! -f "$RESULT" ]; then
  pass "nothing recorded while Specify has not finished"
else
  fail "nothing recorded while Specify has not finished" "$(cat "$RESULT")"
fi
echo "2026-11-15T12:31:48Z|Specify|synthesize|done|Proposal and ticket specs written" >>"${DIR}/state.log"
specify_end "$INIT"
first=$(jq -r '.specify_done' "$RESULT" 2>/dev/null)
rm -f "${DIR}/artifacts/specs/docs-conduit-lite.md"
specify_end "$INIT"
if [ "$(jq -r '.count' "$RESULT" 2>/dev/null)" = "8" ]; then
  pass "an existing record for the same done line is not rewritten"
else
  fail "an existing record for the same done line is not rewritten" "$(cat "$RESULT")"
fi
{
  echo "2026-11-15T13:00:00Z|Specify|synthesize|start|Synthesizing proposal and writing ticket specs"
  echo "2026-11-15T13:10:00Z|Specify|synthesize|done|Proposal and ticket specs written"
} >>"${DIR}/state.log"
specify_end "$INIT"
if [ "$(jq -r '.count' "$RESULT" 2>/dev/null)" = "7" ] && [ "$(jq -r '.specify_done' "$RESULT")" != "$first" ]; then
  pass "a re-run Specify is recorded again"
else
  fail "a re-run Specify is recorded again" "$(cat "$RESULT")"
fi

# ── status lines an agent writes carry no counts ─────────────────────────────
echo "--- agent-written status lines carry no counts (R1) ---"
# The agent phases write these lines from the prompt's own example; a count
# placeholder there is a guess some script will one day read (F67).
counted=$(grep -nE 'planner_state_write "\$\{initiative_id\}" "(Appraisal|Discovery|Architecture|Specify|Review|Consensus)" ' \
  "${LIB_DIR}/planner-phase-prompts.sh" | grep -E '"[^"]*(\b[NMXYZ]\b|_counts|[0-9]+ (tickets?|specs?|findings?))[^"]*"$')
if [ -z "$counted" ]; then
  pass "no count placeholders in the agent phases' status lines"
else
  fail "no count placeholders in the agent phases' status lines" "$counted"
fi
if ! grep -qE 'grep[^|]*Specify\|synthesize' "${LIB_DIR}/planner-crosscheck-propagation.sh"; then
  pass "carve_scope reads no Specify status line"
else
  fail "carve_scope reads no Specify status line" "a Specify log grep is back"
fi

# ── F70: a suppressed duplicate done is visible ──────────────────────────────
echo "--- F70: Consensus's corrected second done ---"
INIT=INIT-corpus-f70
DIR=$(replay s10-crosscheck "$INIT")
before=$(wc -l <"${DIR}/state.log")
ERR=$(planner_state_write "$INIT" Consensus resolve done "Consensus complete (corrected)" 2>&1 >/dev/null)
RC=$?
if [ "$RC" -eq 3 ] && grep -q 'duplicate done for Consensus/resolve not written' <<<"$ERR"; then
  pass "suppressed duplicate returns 3 and says so"
else
  fail "suppressed duplicate returns 3 and says so" "rc=${RC} ${ERR}"
fi
if [ "$(wc -l <"${DIR}/state.log")" -eq "$before" ] &&
  [ "$(grep '|Consensus|resolve|done|' "${DIR}/state.log" | wc -l)" -eq 1 ]; then
  pass "the first done line stands, nothing appended"
else
  fail "the first done line stands, nothing appended" "$(tail -2 "${DIR}/state.log")"
fi
planner_state_write "$INIT" Consensus resolve start "Resolving review findings" 2>/dev/null
if planner_state_write "$INIT" Consensus resolve done "Consensus complete" 2>/dev/null; then
  pass "start then done is a new run's result (rc 0)"
else
  fail "start then done is a new run's result (rc 0)" "rc=$?"
fi

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
