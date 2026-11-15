#!/usr/bin/env bash
# test-planner-corpus-replay.sh — replay the harvested rehearsal corpus
# (lib/tests/corpus/s*-run, s*-draft; seam-bash-derives slice 5) through the
# real readers, with enumerated operators and a known-failure ratchet.
#
# Adapters (each calls the narrowest real function that reads the artifact):
#   statelog        planner_position_derive + planner_crosscheck_findings_summary
#                   on every real state.log → "position=<P> xc=<b>/<w>/<a>"
#   carve_scope     planner_specify_result_ensure (Specify end, as the router
#                   runs it) + planner_crosscheck_carve_scope → "pass" or codes
#   semantic_parse  parse_dor_semantic on every real scan/audit block (audits
#                   with their dor-result.json) → "ok <codes>" or "invalid"
#
# Base units: the verdict must equal labels.tsv's `expected` (the verdict a
# person decided on, never regenerated from the code).
# Harmless operators (casing, bullets, wrapping, number words, CRLF, trailing
# spaces): the verdict must equal the unmutated unit's verdict.
# Harmful operators: the verdict must carry the blocking code
# (CARVE_SCOPE_LOST, CHECK_ERRORED, PARSE_INVALID); at least five fixtures per
# code.
# Ratchet: a case that does not hold must match a row of corpus/known.tsv
# (`check<TAB>case-glob<TAB>reason<TAB>source`), and every case a known row
# matches must still fail. A known case that starts passing fails this test
# until its row is removed or narrowed — the case is then expected.
#
# Run: bash ticket-planner/lib/tests/test-planner-corpus-replay.sh
#   PLANNER_CORPUS_DIR=<dir> replays another corpus (e.g. the local unscrubbed
#   corpus-raw tree, outside the repository) with the same labels.
#   CORPUS_REPLAY_DUMP=<file> keeps every case's result (check, case, class,
#   held, detail) for a report.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."
TAP_LIB="${SCRIPT_DIR}/../../../ticket-auto-pipeline/lib"
CORPUS="${PLANNER_CORPUS_DIR:-${SCRIPT_DIR}/corpus}"
LABELS="${SCRIPT_DIR}/corpus/labels.tsv"
KNOWN="${SCRIPT_DIR}/corpus/known.tsv"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export REPOS_ROOT="${WORK}/repos"
export HOME="${WORK}/home"
mkdir -p "$REPOS_ROOT" "$HOME"

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-crosscheck.sh"
source "${LIB_DIR}/planner-crosscheck-propagation.sh"
source "${LIB_DIR}/planner-phase-results.sh"
source "${TAP_LIB}/dor-semantic-parse.sh"

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

RESULTS="${WORK}/results.tsv" # check  case  class  held(1/0)  detail
: >"$RESULTS"
record() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(tr '\t\n' '  ' <<<"$5")" >>"$RESULTS"; }

# label <snap> <check> <unit> — the expected verdict a person decided on.
# An initiative id inside a unit name (a TD pack's slug) is compared as
# init-N, so the unscrubbed corpus-raw replay finds the scrubbed label.
label() {
  awk -F'\t' -v s="$1" -v c="$2" -v u="$3" '
    function norm(x) { gsub(/init-[0-9]+-[0-9]+/, "init-N", x); return x }
    $1 == s && $2 == c && norm($3) == norm(u) { print $5; exit }' "$LABELS"
}

echo "=== planner corpus replay (seam-bash-derives slice 5) ==="

# ── operators ────────────────────────────────────────────────────────────────
NUMBER_WORDS=(zero one two three four five six seven eight nine ten eleven twelve)
op_crlf() { sed 's/$/\r/'; }
op_trailing() { sed 's/$/  /'; }
# State log: only the message (fields 5+) changes.
op_msg_upper() { awk 'BEGIN { FS = OFS = "|" } { for (i = 5; i <= NF; i++) $i = toupper($i); print }'; }
op_msg_numbers() {
  local i expr=()
  for i in "${!NUMBER_WORDS[@]}"; do
    expr+=(-e "s/^(([^|]*\\|){4}.*[^0-9A-Za-z])${i}([^0-9A-Za-z.:]|\$)/\\1${NUMBER_WORDS[$i]}\\3/")
  done
  sed -E "${expr[@]}"
}
# Result blocks: KEY lines only, markers untouched.
op_bullets() { sed -E 's/^([A-Z][A-Z0-9_]*[[:space:]]*:)/- \1/'; }
op_casing() { sed -E 's/^((GAP_[A-Z_]+|SCORE_PLAUSIBLE|AUDIT_[0-9]+_VERDICT)[[:space:]]*:[[:space:]]*)([a-z])/\1\u\3/'; }
op_wrap() {
  awk '!done && /^[A-Z][A-Z0-9_]*(_DETAIL|_REASON|PARAPHRASE)[[:space:]]*:/ && length($0) > 90 {
         cut = index(substr($0, 70), " ")
         if (cut > 0) { print substr($0, 1, 68 + cut); print "  " substr($0, 70 + cut); done = 1; next }
       } { print }'
}
op_value_numbers() {
  local i expr=()
  for i in "${!NUMBER_WORDS[@]}"; do
    expr+=(-e "/^[A-Z][A-Z0-9_]*(_DETAIL|_REASON|PARAPHRASE)[[:space:]]*:/s/(^|[^0-9A-Za-z._-])${i}([^0-9A-Za-z._%-]|\$)/\\1${NUMBER_WORDS[$i]}\\2/g")
  done
  sed -E "${expr[@]}"
}
HARMLESS_LOG_OPS="crlf trailing msg_upper msg_numbers"
HARMLESS_RESULT_OPS="crlf trailing bullets casing wrap value_numbers"

# ── adapter: statelog ────────────────────────────────────────────────────────
statelog_verdict() { # <init>
  local p s
  p=$(planner_position_derive "$1" 2>/dev/null)
  s=none
  if grep -q '|Crosscheck|check|start|' "$(planner_state_log "$1")"; then
    s=$(planner_crosscheck_findings_summary "$1" 2>/dev/null | sed -n 's/^TOTAL: \([0-9]*\) blocking, \([0-9]*\) warn, \([0-9]*\) accepted$/\1\/\2\/\3/p')
  fi
  printf 'position=%s xc=%s' "${p:--}" "${s:-0/0/0}"
}
seed_init() { # <init> <state.log source> [<specs dir>]
  local dir="${REPOS_ROOT}/.ticket-auto/initiatives/$1"
  rm -rf "$dir"
  mkdir -p "${dir}/artifacts"
  cp "$2" "${dir}/state.log"
  [ -n "${3:-}" ] && cp -r "$3" "${dir}/artifacts/specs"
  printf '%s\n' "$dir"
}

RUNS=()
for d in "$CORPUS"/s*-run; do
  [ -f "$d/state.log" ] && RUNS+=("$(basename "$d")")
done

echo "--- statelog: ${#RUNS[@]} real state logs ---"
for snap in "${RUNS[@]}"; do
  init="INIT-corpus-${snap}"
  seed_init "$init" "$CORPUS/$snap/state.log" >/dev/null
  base=$(statelog_verdict "$init")
  want=$(label "$snap" statelog state.log)
  if [ -n "$want" ] && [ "$base" = "$want" ]; then
    record statelog "${snap}" base 1 "$base"
  else
    record statelog "${snap}" base 0 "got '${base}', label '${want:-none}'"
  fi
  for op in $HARMLESS_LOG_OPS; do
    "op_${op}" <"$CORPUS/$snap/state.log" >"${WORK}/mut.log"
    seed_init "$init" "${WORK}/mut.log" >/dev/null
    got=$(statelog_verdict "$init")
    [ "$got" = "$base" ] && record statelog "${snap}@${op}" harmless 1 "$got" ||
      record statelog "${snap}@${op}" harmless 0 "'${base}' became '${got}'"
  done
done

# ── adapter: carve_scope ─────────────────────────────────────────────────────
carve_verdict() { # <init>
  local dir="${REPOS_ROOT}/.ticket-auto/initiatives/$1" out
  out=$(planner_crosscheck_carve_scope "${dir}/artifacts/phase-results/specify.json" "${dir}/artifacts/specs" 2>&1)
  out=$(grep -oE '(CARVE_SCOPE_LOST|CHECK_ERRORED)' <<<"$out" | sort -u | tr '\n' ' ')
  printf '%s' "${out:-pass}" | sed 's/ $//'
}
carve_case() { # <snap> <case> <class> <want-code|-> <state.log> [<mutate-after-ensure>]
  local snap="$1" case="$2" class="$3" want="$4" log="$5" after="${6:-}" init="INIT-corpus-carve" dir got
  dir=$(seed_init "$init" "$log" "$CORPUS/$snap/specs")
  planner_specify_result_ensure "$init" >/dev/null 2>&1
  [ -n "$after" ] && "$after" "$dir"
  got=$(carve_verdict "$init")
  case "$class" in
  base | harmless)
    [ "$got" = "$want" ] && record carve_scope "$case" "$class" 1 "$got" ||
      record carve_scope "$case" "$class" 0 "got '${got}', want '${want}'"
    ;;
  harmful)
    [[ " $got " == *" $want "* ]] && record carve_scope "$case" harmful 1 "$got" ||
      record carve_scope "$case" harmful 0 "got '${got}', must carry ${want}"
    ;;
  esac
}
# Harmful edits made after Specify ended (the record exists).
after_drop_spec() { rm -f "$(find "$1/artifacts/specs" -name '*.md' ! -name INDEX.md -exec grep -LF '<!-- planner:testdata-synth v1 -->' {} + | sort | head -1)"; }
after_add_spec() { printf '# split-out\n\n## Title\n\nSplit out of a sibling after Specify\n' >"$1/artifacts/specs/split-out.md"; }
after_corrupt_record() { printf 'Proposal written, 7 ticket specs\n' >"$1/artifacts/phase-results/specify.json"; }
after_bad_slug() { jq '.specs[0] = "../escape"' "$1/artifacts/phase-results/specify.json" >"$1/x" && mv "$1/x" "$1/artifacts/phase-results/specify.json"; }
after_count_lie() { jq '.count = (.count + 1)' "$1/artifacts/phase-results/specify.json" >"$1/x" && mv "$1/x" "$1/artifacts/phase-results/specify.json"; }

CARVES=()
for snap in "${RUNS[@]}"; do
  [ -d "$CORPUS/$snap/specs" ] && CARVES+=("$snap")
done
echo "--- carve_scope: ${#CARVES[@]} real spec sets ---"
for snap in "${CARVES[@]}"; do
  log="$CORPUS/$snap/state.log"
  carve_case "$snap" "$snap" base "$(label "$snap" carve_scope initiative)" "$log"
  for op in $HARMLESS_LOG_OPS; do
    "op_${op}" <"$log" >"${WORK}/mut.log"
    carve_case "$snap" "${snap}@${op}" harmless "$(label "$snap" carve_scope initiative)" "${WORK}/mut.log"
  done
  carve_case "$snap" "${snap}@drop_spec" harmful CARVE_SCOPE_LOST "$log" after_drop_spec
  carve_case "$snap" "${snap}@add_spec" harmful CARVE_SCOPE_LOST "$log" after_add_spec
  grep -vE '^[^|]*\|Specify\|[^|]*\|done\|' "$log" >"${WORK}/mut.log"
  carve_case "$snap" "${snap}@no_specify_done" harmful CHECK_ERRORED "${WORK}/mut.log"
  { cat "$log" && echo "2026-12-01T00:00:00Z|Specify|synthesize|start|Re-running Specify"; } >"${WORK}/mut.log"
  carve_case "$snap" "${snap}@specify_rerun_unfinished" harmful CHECK_ERRORED "${WORK}/mut.log"
  carve_case "$snap" "${snap}@corrupt_record" harmful CHECK_ERRORED "$log" after_corrupt_record
  carve_case "$snap" "${snap}@bad_slug" harmful CHECK_ERRORED "$log" after_bad_slug
  carve_case "$snap" "${snap}@count_lie" harmful CHECK_ERRORED "$log" after_count_lie
done

# ── adapter: semantic_parse ──────────────────────────────────────────────────
parse_verdict() { # <kind> <file> [<det>]
  local out args=(--kind "$1" --result-file "$2")
  [ -n "${3:-}" ] && args+=(--det-result "$3")
  out=$(parse_dor_semantic "${args[@]}" 2>/dev/null)
  jq -r 'if .parse_status != "ok" then "invalid"
         else "ok " + ([(.findings // [])[].code] + [(.gaps // {}) | to_entries[] | .key + "=" + .value.verdict]
                     + [(.audit // [])[] | .code + "=" + .verdict] + [(.missed // [])[].code]
                     + (if .kind == "audit" then ["score=" + (.score_plausible | tostring)] else [] end)
                     | sort | join(",")) end' <<<"$out" 2>/dev/null || echo invalid
}
# Harmful edits of a result block.
harm_cut_end() { sed '/^=== END DOR_SEMANTIC_/d'; }
harm_schema_v2() { sed -E 's/^(SCHEMA_VERSION[[:space:]]*:[[:space:]]*).*/\12/'; }
harm_scan_dup_key() { sed -E '0,/^(GAP_[A-Z_]+)[[:space:]]*:[[:space:]]*(clear|finding|not-applicable)[[:space:]]*$/s//\1: \2\n\1: not-applicable/'; }
harm_scan_gap_enum() { sed -E '0,/^(GAP_[A-Z_]+[[:space:]]*:[[:space:]]*)(clear|finding|not-applicable)[[:space:]]*$/s//\1maybe/'; }
harm_scan_no_paraphrase() { sed '/^PARAPHRASE[[:space:]]*:/d'; }
harm_scan_unknown_code() { sed 's/^=== END DOR_SEMANTIC_SCAN ===/FINDING_99_CODE: NOT_A_CODE\nFINDING_99_QUOTE: x\n&/'; }
harm_audit_dup_key() { sed -E 's/^(SCORE_PLAUSIBLE[[:space:]]*:[[:space:]]*)(yes|no)[[:space:]]*$/&\nSCORE_PLAUSIBLE: maybe-not/'; }
harm_audit_score_enum() { sed -E 's/^(SCORE_PLAUSIBLE[[:space:]]*:[[:space:]]*).*/\1probably/'; }
harm_audit_no_reason() { sed '/^SCORE_REASON[[:space:]]*:/d'; }
HARMFUL_SCAN="cut_end schema_v2 scan_dup_key scan_gap_enum scan_no_paraphrase scan_unknown_code"
HARMFUL_AUDIT="cut_end schema_v2 audit_dup_key audit_score_enum audit_no_reason audit_det_unaudited"

DRAFTS=()
for d in "$CORPUS"/s*-draft/*/*-result.txt; do
  [ -f "$d" ] && DRAFTS+=("${d#"$CORPUS"/}")
done
echo "--- semantic_parse: ${#DRAFTS[@]} real result blocks ---"
for rel in "${DRAFTS[@]}"; do
  f="$CORPUS/$rel"
  snap="${rel%%/*}"
  unit="${rel#*/}"
  unit="${unit%-result.txt}" # <slug>/scan | <slug>/audit
  kind="${unit##*/}"
  det=""
  [ "$kind" = audit ] && [ -f "$(dirname "$f")/dor-result.json" ] && det="$(dirname "$f")/dor-result.json"
  base=$(parse_verdict "$kind" "$f" "$det")
  want=$(label "$snap" semantic_parse "$unit")
  if [ -n "$want" ] && [ "${base%% *}" = "$want" ]; then
    record semantic_parse "${snap}/${unit}" base 1 "$base"
  else
    record semantic_parse "${snap}/${unit}" base 0 "got '${base%% *}', label '${want:-none}'"
  fi
  for op in $HARMLESS_RESULT_OPS; do
    "op_${op}" <"$f" >"${WORK}/mut.txt"
    got=$(parse_verdict "$kind" "${WORK}/mut.txt" "$det")
    [ "$got" = "$base" ] && record semantic_parse "${snap}/${unit}@${op}" harmless 1 "$got" ||
      record semantic_parse "${snap}/${unit}@${op}" harmless 0 "'${base}' became '${got}'"
  done
  [ "${base%% *}" = ok ] || continue # harmful edits of a block that already fails prove nothing
  ops="$HARMFUL_SCAN"
  [ "$kind" = audit ] && ops="$HARMFUL_AUDIT"
  for op in $ops; do
    mdet="$det"
    if [ "$op" = audit_det_unaudited ]; then
      cp "$f" "${WORK}/mut.txt"
      jq '.missing = ((.missing // []) + ["CORPUS_UNAUDITED_CODE"])' "${det:-/dev/null}" >"${WORK}/det.json" 2>/dev/null ||
        echo '{"missing":["CORPUS_UNAUDITED_CODE"],"advisory":[]}' >"${WORK}/det.json"
      mdet="${WORK}/det.json"
    else
      "harm_${op}" <"$f" >"${WORK}/mut.txt"
    fi
    got=$(parse_verdict "$kind" "${WORK}/mut.txt" "$mdet")
    [ "$got" = invalid ] && record semantic_parse "${snap}/${unit}@${op}" harmful 1 PARSE_INVALID ||
      record semantic_parse "${snap}/${unit}@${op}" harmful 0 "passed as '${got}'"
  done
done

# ── corpus integrity ─────────────────────────────────────────────────────────
echo "--- corpus integrity ---"
missing_labels=$(
  for snap in "${RUNS[@]}"; do
    [ -n "$(label "$snap" statelog state.log)" ] || echo "${snap} statelog"
  done
  for snap in "${CARVES[@]}"; do
    [ -n "$(label "$snap" carve_scope initiative)" ] || echo "${snap} carve_scope"
  done
)
[ -z "$missing_labels" ] && pass "every replayed unit has a label" || fail "every replayed unit has a label" "$missing_labels"
listed=$(awk -F'\t' 'NR > 1 && $1 ~ /-(run|draft)$/ { print $1 }' "${SCRIPT_DIR}/corpus/MANIFEST.tsv" | sort)
ondisk=$(cd "$CORPUS" && for d in s*-run/ s*-draft/; do [ -d "$d" ] && echo "${d%/}"; done | sort)
if [ "$listed" = "$ondisk" ]; then
  pass "MANIFEST.tsv lists exactly the harvested snapshot directories"
else
  fail "MANIFEST.tsv lists exactly the harvested snapshot directories" "$(diff <(echo "$listed") <(echo "$ondisk") | grep '^[<>]' | tr '\n' ' ')"
fi
bad_manifest=$(awk -F'\t' 'NR > 1 && ($7 == "" || $8 == "") { print $1 }' "${SCRIPT_DIR}/corpus/MANIFEST.tsv")
[ -z "$bad_manifest" ] && pass "every snapshot names the code it was read against and its contracts" ||
  fail "every snapshot names the code it was read against and its contracts" "$bad_manifest"

# ── ratchet ──────────────────────────────────────────────────────────────────
echo "--- ratchet: known failures may only shrink ---"
# ratchet <known.tsv> <results.tsv> — print one problem per line, prefixed
# UNEXPECTED (a case that does not hold and no row lists), STALE (a row that
# matches no case) or NOW-PASSES (a row whose case holds now).
ratchet() {
  local known="$1" results="$2" kc kg i hit check case class held detail
  local -a kn=()
  local -A hits=() passed=()
  while IFS=$'\t' read -r kc kg _; do
    case "$kc" in '' | '#'*) continue ;; esac
    kn+=("${kc}"$'\t'"${kg}")
  done <"$known"
  while IFS=$'\t' read -r check case class held detail; do
    hit=""
    for i in "${!kn[@]}"; do
      # shellcheck disable=SC2053
      if [ "${kn[$i]%%$'\t'*}" = "$check" ] && [[ "$case" == ${kn[$i]#*$'\t'} ]]; then
        hit="$i"
        break
      fi
    done
    if [ -n "$hit" ]; then
      hits[$hit]=1
      [ "$held" = 1 ] && passed[$hit]="${passed[$hit]:-}${case} "
    elif [ "$held" != 1 ]; then
      echo "UNEXPECTED ${check} ${case} (${class}): ${detail}"
    fi
  done <"$results"
  for i in "${!kn[@]}"; do
    [ -n "${hits[$i]:-}" ] || echo "STALE ${kn[$i]/$'\t'/ }"
    [ -z "${passed[$i]:-}" ] || echo "NOW-PASSES ${kn[$i]/$'\t'/ }: ${passed[$i]}"
  done
}
problems=$(ratchet "$KNOWN" "$RESULTS")
if ! grep -q '^UNEXPECTED' <<<"$problems"; then
  pass "every case that does not hold is listed in known.tsv"
else
  fail "every case that does not hold is listed in known.tsv" "$(grep '^UNEXPECTED' <<<"$problems" | head -20)"
fi
if ! grep -q '^STALE' <<<"$problems"; then
  pass "every known.tsv row matches a replayed case"
else
  fail "every known.tsv row matches a replayed case" "$(grep '^STALE' <<<"$problems")"
fi
if ! grep -q '^NOW-PASSES' <<<"$problems"; then
  pass "no known case has started passing"
else
  fail "a known case now passes — remove or narrow its known.tsv row (it is then expected)" "$(grep '^NOW-PASSES' <<<"$problems" | cut -c1-400)"
fi

# The ratchet itself: a planted row over cases that hold must be NOW-PASSES,
# and a dropped row must turn its cases UNEXPECTED.
{
  cat "$KNOWN"
  printf 'semantic_parse\t*@crlf\tplanted\tself-test\n'
} >"${WORK}/known-plus.tsv"
if grep -q '^NOW-PASSES semantic_parse \*@crlf' <<<"$(ratchet "${WORK}/known-plus.tsv" "$RESULTS")"; then
  pass "ratchet self-test: a known case that passes is reported"
else
  fail "ratchet self-test: a known case that passes is reported" "not reported"
fi
grep -v '@wrap' "$KNOWN" >"${WORK}/known-minus.tsv"
if [ "$(grep -c '^UNEXPECTED .*@wrap ' <<<"$(ratchet "${WORK}/known-minus.tsv" "$RESULTS")")" -gt 0 ]; then
  pass "ratchet self-test: a failing case no row lists is reported"
else
  fail "ratchet self-test: a failing case no row lists is reported" "not reported"
fi

# ── report ───────────────────────────────────────────────────────────────────
echo "--- per check: units, harmless cases and flips, harmful cases and passes ---"
awk -F'\t' '
  { k = $1; n[k]++ }
  $3 == "base" { b[k]++; if ($4 != 1) bf[k]++ }
  $3 == "harmless" { h[k]++; if ($4 != 1) hf[k]++ }
  $3 == "harmful" { x[k]++; if ($4 != 1) xp[k]++ }
  END { for (k in n) printf "  %-15s base %d (%d off-label)  harmless %d (%d flips)  harmful %d (%d passes)\n", k, b[k], bf[k], h[k], hf[k], x[k], xp[k] }' "$RESULTS" | sort
echo "  harmful fixtures per blocking code:"
awk -F'\t' '$3 == "harmful" { c = ($1 == "semantic_parse") ? "PARSE_INVALID" : ""; if ($1 == "carve_scope") c = ($2 ~ /@(drop|add)_spec$/) ? "CARVE_SCOPE_LOST" : "CHECK_ERRORED"; n[c]++ }
  END { for (c in n) printf "    %-17s %d\n", c, n[c] }' "$RESULTS" | sort
min=$(awk -F'\t' '$3 == "harmful" { c = ($1 == "semantic_parse") ? "PARSE_INVALID" : (($2 ~ /@(drop|add)_spec$/) ? "CARVE_SCOPE_LOST" : "CHECK_ERRORED"); n[c]++ }
  END { m = -1; for (c in n) if (m < 0 || n[c] < m) m = n[c]; print (length(n) == 3 ? m : 0) }' "$RESULTS")
[ "${min:-0}" -ge 5 ] && pass "at least five harmful fixtures per blocking code (min ${min})" ||
  fail "at least five harmful fixtures per blocking code" "min ${min:-0}"

[ -n "${CORPUS_REPLAY_DUMP:-}" ] && cp "$RESULTS" "$CORPUS_REPLAY_DUMP"
echo ""
echo "=== $PASS passed, $FAIL failed ($(wc -l <"$RESULTS") replayed cases) ==="
[ "$FAIL" -eq 0 ]
