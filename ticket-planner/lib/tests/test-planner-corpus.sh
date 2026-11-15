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
#
# Slice 2 cases:
#   F70  (same snapshot) Consensus's status line said 11/0/2, its headings
#        say 12/0/1. Bash records the headings in phase-results/consensus.json
#        after Consensus; unreadable headings mean no file, never a guess.
#   row 19 (s02-cited, iteration 02, two NOT FOUND cited artifacts) A
#        reworded or dropped CITED_ARTIFACT line used to be
#        CITED_ARTIFACT_UNRAISED. Bash now restores the canonical lines,
#        keeping any Answer:, so a paraphrase cannot block Crosscheck.
#   R1 lint over every prompt status line, and the list of prompt-written
#        lines whose message a script still reads.
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

# Slice 2 (task 2.5): the same rule over every status line a prompt writes —
# EpicGen, TicketGen, Completed and the META lines included, continuation
# lines joined — so no agent-typed count can reach a line a script reads.
counted=$(awk '/\\$/ { buf = buf substr($0, 1, length($0) - 1); next } { print buf $0; buf = "" }' \
  "${LIB_DIR}/planner-phase-prompts.sh" | grep -E 'planner_state_write "\$\{initiative_id\}" ' |
  grep -E '"[^"]*(\b[NMXYZ]\b|_counts|<n>|[0-9]+ (tickets?|specs?|findings?))[^"]*"')
if [ -z "$counted" ]; then
  pass "no count placeholders in any prompt status line"
else
  fail "no count placeholders in any prompt status line" "$counted"
fi

# The prompt-written lines whose message a script still reads. A new reader
# fails the inventory below until it is listed here (and justified); a
# removed one fails until it is dropped, so the list stays true.
#   key (phase|step) <TAB> reader file <TAB> what it reads
PROMPT_MESSAGE_READERS=$(
  cat <<'EOF'
EpicGen|create	planner-refinement.sh	EPIC_ID= (planner_epic_id; value from Linear's issueCreate response, in prompt bash)
EpicGen|create	planner-ticket-body.sh	the EPIC_ID= line's timestamp (planner_ticketgen_generated_ts)
META|adr-gate	planner-adr-gate.sh	<VERDICT> ADR_ID= (agent-copied; change seam-fail-closed)
META|discovery	planner-crosscheck-repo-ref.sh	repo-ref <repo>@<ref>@<sha> (git output, in prompt bash)
EOF
)
# Every reader is found by the anchored shape it greps or splits on.
reader_found() {
  case "$1" in
  "EpicGen|create") grep -qF 'EpicGen\|[^|]*\|done\|EPIC_ID=' "${LIB_DIR}/$2" ;;
  "META|adr-gate") grep -q '"adr-gate" ]' "${LIB_DIR}/$2" ;;
  "META|discovery") grep -q '"repo-ref" ]' "${LIB_DIR}/$2" ;;
  *) return 1 ;;
  esac
}
stale=""
while IFS=$'\t' read -r key file _; do
  [ -n "$key" ] || continue
  reader_found "$key" "$file" || stale="${stale} ${key}@${file}"
done <<<"$PROMPT_MESSAGE_READERS"
if [ -z "$stale" ]; then
  pass "every listed prompt-message reader still exists"
else
  fail "every listed prompt-message reader still exists" "gone:${stale} — drop it from PROMPT_MESSAGE_READERS"
fi
# Retired readers (slices 1-2): Specify start, Consensus done, TicketGen's
# Created/done lines. COMPLETED.md now reads the intent files.
retired=$(grep -nE "ticketgen\\\\?\|(done|step)\\\\?\||Consensus\\\\?\|resolve\\\\?\|done\\\\?\||Specify\\\\?\|synthesize\\\\?\|start" \
  "${LIB_DIR}"/*.sh | grep -v 'planner-phase-prompts.sh' | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#')
if [ -z "$retired" ]; then
  pass "no lib reads a TicketGen, Specify start or Consensus done message"
else
  fail "no lib reads a TicketGen, Specify start or Consensus done message" "$retired"
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

# ── slice 2: Consensus dispositions from consensus.md headings ──────────────
echo "--- F70 shape: Consensus's status line counts disagree with its headings ---"
source "${LIB_DIR}/planner-router.sh"
source "${LIB_DIR}/planner-crosscheck-testdata.sh"
source "${LIB_DIR}/planner-consensus-gate.sh"
source "${LIB_DIR}/planner-phase-prompts.sh"

# The router's step 4a, after the Consensus agent returned.
consensus_end() {
  planner_dispatch_gate post "$1" Consensus "${REPOS_ROOT}/.ticket-auto/initiatives/$1" >/dev/null 2>&1
}

INIT=INIT-corpus-disp
DIR=$(replay s10-crosscheck "$INIT")
cp "${CORPUS}/s10-crosscheck/consensus.md" "${DIR}/artifacts/consensus.md"
RESULT="${DIR}/artifacts/phase-results/consensus.json"
if grep -q '|Consensus|resolve|done|Consensus: 11 accepted, 0 rejected, 2 deferred$' "${DIR}/state.log" &&
  [ "$(grep -c '^### F[0-9]* — .* — deferred$' "${DIR}/artifacts/consensus.md")" -eq 1 ]; then
  pass "snapshot still holds the F70 shape (log says 11/0/2, headings say 12/0/1)"
else
  fail "snapshot still holds the F70 shape (log says 11/0/2, headings say 12/0/1)" "corpus changed"
fi
consensus_end "$INIT"
if [ "$(jq -c '[.counts.accepted, .counts.rejected, .counts.deferred, .total]' "$RESULT" 2>/dev/null)" = "[12,0,1,13]" ] &&
  [ "$(jq -r '.derived_by' "$RESULT" 2>/dev/null)" = "bash" ] &&
  [ "$(jq -r '.consensus_done' "$RESULT" 2>/dev/null)" = "2026-11-15T12:38:44Z" ]; then
  pass "Consensus end records 12/0/1 from the headings, derived by bash"
else
  fail "Consensus end records 12/0/1 from the headings, derived by bash" "$(cat "$RESULT" 2>&1)"
fi
if [ "$(planner_consensus_result_counts "$RESULT" 2>/dev/null)" = "12 0 1" ]; then
  pass "the reader returns accepted rejected deferred"
else
  fail "the reader returns accepted rejected deferred" "$(planner_consensus_result_counts "$RESULT" 2>&1)"
fi
if [ "$(jq -r '[.findings[] | select(.disposition == "deferred") | .id] | join(",")' "$RESULT" 2>/dev/null)" = "F7" ]; then
  pass "each finding keeps its id and disposition"
else
  fail "each finding keeps its id and disposition" "$(cat "$RESULT" 2>&1)"
fi

echo "--- unreadable dispositions: no consensus.json, nothing blocks ---"
# A heading the closed set does not cover (a real iteration wrote "partly
# accepted"): the counts would be a guess, so no file is written.
{
  echo "2026-11-15T13:00:00Z|Consensus|resolve|start|Resolving review findings"
  echo "2026-11-15T13:05:00Z|Consensus|resolve|done|Consensus written to artifacts/consensus.md"
} >>"${DIR}/state.log"
sed -i 's/^\(### F6 — .*\) — accepted$/\1 — partly accepted/' "${DIR}/artifacts/consensus.md"
RC=0
planner_dispatch_gate post "$INIT" Consensus "$DIR" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 0 ] && [ ! -f "$RESULT" ]; then
  pass "an unreadable disposition removes the earlier record and does not block"
else
  fail "an unreadable disposition removes the earlier record and does not block" "rc=${RC} $(cat "$RESULT" 2>&1)"
fi

INIT=INIT-corpus-bold
DIR=$(replay s10-crosscheck "$INIT")
RESULT="${DIR}/artifacts/phase-results/consensus.json"
# Iteration 03's shape: bold lines, no headings.
printf '# Consensus\n\n## Findings Addressed\n\n**R1 (major): browser verification is not repeatable. Accepted.**\n\n## Readiness\n\nready-for-spec\n' \
  >"${DIR}/artifacts/consensus.md"
consensus_end "$INIT"
if [ ! -f "$RESULT" ]; then
  pass "findings without id headings are unreadable, never zero"
else
  fail "findings without id headings are unreadable, never zero" "$(cat "$RESULT")"
fi
printf '# Consensus\n\n## Findings Addressed\n\n### F1 - major - dash separators - accepted\n\n## Readiness\n\nready-for-spec\n' \
  >"${DIR}/artifacts/consensus.md"
consensus_end "$INIT"
if [ ! -f "$RESULT" ]; then
  pass "an id heading without the em-dash shape is unreadable, not skipped"
else
  fail "an id heading without the em-dash shape is unreadable, not skipped" "$(cat "$RESULT")"
fi

INIT=INIT-corpus-unfinished
DIR=$(replay s10-crosscheck "$INIT")
RESULT="${DIR}/artifacts/phase-results/consensus.json"
cp "${CORPUS}/s10-crosscheck/consensus.md" "${DIR}/artifacts/consensus.md"
sed -i '$d' "${DIR}/state.log" # drop the Consensus done line
consensus_end "$INIT"
if [ ! -f "$RESULT" ]; then
  pass "nothing recorded while Consensus has not finished"
else
  fail "nothing recorded while Consensus has not finished" "$(cat "$RESULT")"
fi

# ── slice 2: CITED_ARTIFACT questions written by bash ───────────────────────
echo "--- cited-artifact questions: bash restores the canonical lines ---"
# replay_cited <init> — iteration 02 at Consensus done, two NOT FOUND artifacts.
replay_cited() {
  local dir="${REPOS_ROOT}/.ticket-auto/initiatives/$1"
  rm -rf "$dir"
  mkdir -p "${dir}/artifacts/specs"
  cp "${CORPUS}/s02-cited/state.log" "${dir}/state.log"
  cp "${CORPUS}/s02-cited/discovery.md" "${CORPUS}/s02-cited/consensus.md" "${dir}/artifacts/"
  printf '%s\n' "$dir"
}
cited_findings() { planner_crosscheck_cited_artifacts "$1" 2>&1; }
CANON1='- CITED_ARTIFACT: `RealWorld Conduit api/openapi.yml` — cited but not retrievable. Provide it, or confirm it should be synthesised. Answer: PENDING'
CANON2='- CITED_ARTIFACT: `the brief (exact request/response shapes and status codes for each endpoint)` — cited but not retrievable. Provide it, or confirm it should be synthesised. Answer: PENDING'

INIT=INIT-corpus-cited
DIR=$(replay_cited "$INIT")
before=$(sha256sum <"${DIR}/artifacts/consensus.md")
consensus_end "$INIT"
if [ "$(sha256sum <"${DIR}/artifacts/consensus.md")" = "$before" ]; then
  pass "verbatim questions: consensus.md left byte-identical"
else
  fail "verbatim questions: consensus.md left byte-identical" "$(diff <(cat "${CORPUS}/s02-cited/consensus.md") "${DIR}/artifacts/consensus.md")"
fi

INIT=INIT-corpus-paraphrase
DIR=$(replay_cited "$INIT")
C="${DIR}/artifacts/consensus.md"
# Harmful operators an agent applies: reword one question, drop the other.
sed -i 's/^- CITED_ARTIFACT: `RealWorld Conduit api\/openapi.yml` — .*$/- CITED_ARTIFACT: the published `RealWorld Conduit api\/openapi.yml` was not found; please supply it. Answer: PENDING/' "$C"
sed -i '/^- CITED_ARTIFACT: `the brief/d' "$C"
if grep -q 'CITED_ARTIFACT_UNRAISED' <<<"$(cited_findings "$INIT")"; then
  pass "a dropped question is CITED_ARTIFACT_UNRAISED before bash runs"
else
  fail "a dropped question is CITED_ARTIFACT_UNRAISED before bash runs" "$(cited_findings "$INIT")"
fi
consensus_end "$INIT"
OUT=$(cited_findings "$INIT")
if ! grep -q 'CITED_ARTIFACT_UNRAISED' <<<"$OUT"; then
  pass "after Consensus, Crosscheck reports no CITED_ARTIFACT_UNRAISED"
else
  fail "after Consensus, Crosscheck reports no CITED_ARTIFACT_UNRAISED" "$OUT"
fi
if [ "$(grep -cxF -- "$CANON1" "$C")" -eq 1 ] && [ "$(grep -cxF -- "$CANON2" "$C")" -eq 1 ] &&
  [ "$(grep -c 'CITED_ARTIFACT:' "$C")" -eq 2 ]; then
  pass "both canonical lines present exactly once, the paraphrase replaced"
else
  fail "both canonical lines present exactly once, the paraphrase replaced" "$(grep -n 'CITED_ARTIFACT' "$C")"
fi
q=$(awk '/^## Open Questions/{on=1;next} /^## /{on=0} on' "$C")
if grep -qF -- "$CANON2" <<<"$q" && grep -q '^- Operator merge:' "$C" && grep -q '^ready-for-spec$' "$C"; then
  pass "the appended line sits in ## Open Questions; other text untouched"
else
  fail "the appended line sits in ## Open Questions; other text untouched" "$(cat "$C")"
fi

INIT=INIT-corpus-answer
DIR=$(replay_cited "$INIT")
C="${DIR}/artifacts/consensus.md"
sed -i 's/^- CITED_ARTIFACT: `RealWorld Conduit api\/openapi.yml` — .*$/- **CITED_ARTIFACT:** `RealWorld Conduit api\/openapi.yml` (public spec) — Answer: external:RealWorld maintainers/' "$C"
consensus_end "$INIT"
if grep -qxF -- "${CANON1% Answer: PENDING} Answer: external:RealWorld maintainers" "$C"; then
  pass "a refreshed line keeps its Answer"
else
  fail "a refreshed line keeps its Answer" "$(grep -n 'CITED_ARTIFACT' "$C")"
fi

INIT=INIT-corpus-nosection
DIR=$(replay_cited "$INIT")
C="${DIR}/artifacts/consensus.md"
printf '# Consensus\n\n## Findings Addressed\n\nNone.\n\n## Readiness\n\nready-for-spec\n' >"$C"
consensus_end "$INIT"
if [ "$(awk '/^## Open Questions/{on=1;next} /^## /{on=0} on' "$C" | grep -c 'CITED_ARTIFACT:')" -eq 2 ] &&
  [ "$(planner_consensus_readiness "$INIT" 2>/dev/null)" = "ready-for-spec" ]; then
  pass "no ## Open Questions section: bash adds it; Readiness still reads"
else
  fail "no ## Open Questions section: bash adds it; Readiness still reads" "$(cat "$C")"
fi

INIT=INIT-corpus-crlf
DIR=$(replay_cited "$INIT")
C="${DIR}/artifacts/consensus.md"
sed -i '/^- CITED_ARTIFACT: `the brief/d; s/$/\r/' "$C"
consensus_end "$INIT"
if [ "$(grep -c $'\r$' "$C")" -eq "$(wc -l <"$C")" ] && [ "$(grep -c 'CITED_ARTIFACT:' "$C")" -eq 2 ]; then
  pass "CRLF consensus.md keeps CRLF on every line"
else
  fail "CRLF consensus.md keeps CRLF on every line" "$(cat -A "$C" | grep CITED)"
fi

prompt=$(planner_prompt_consensus "$INIT" "an idea" "$DIR" 2>/dev/null)
if [ -n "$prompt" ] && ! grep -qiE 'copy its output verbatim|copied verbatim from .planner_cited' <<<"$prompt" && grep -q 'Bash writes' <<<"$prompt"; then
  pass "the Consensus prompt no longer asks the agent to copy the lines"
else
  fail "the Consensus prompt no longer asks the agent to copy the lines" "copy instruction still present"
fi

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
