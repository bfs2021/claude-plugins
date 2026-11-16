#!/usr/bin/env bash
# test-planner-gate-ledger.sh — checks ticket-planner/gates/gate-ledger.tsv, the
# labelled record of every gate fire in dispatch rehearsal iterations 01–10
# (change seam-gate-safety, slice G3), and its read-only summary script.
#
#   - every row has the 15 columns, closed values and a consistent label/cause/
#     fixed/live set (a false row says whether its cause is still live on main)
#   - deep-dive D's corrections hold (F25 false, F43 debatable) and fires from
#     checker bugs already fixed (F12/F24, F22, F33, F52, F67) are never live
#   - each evidence pointer has the <file>:<line> shape; with
#     GATE_LEDGER_EVIDENCE_DIR set to the rehearsal folder (local only, never in
#     CI) the line exists and names the row's f_id, else its code
#   - gate-ledger-summary.sh counts what the ledger holds, lists the G4 demotion
#     candidates (pinned below: a ledger change that moves the list fails here
#     until the pin is updated), never lists a warn code or DEPENDENCY_CYCLE,
#     fails closed when it cannot read the class lists, writes nothing
#   - the corpus privacy scan passes over the gates directory
#
# Run: bash ticket-planner/lib/tests/test-planner-gate-ledger.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLANNER_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GATES="${PLANNER_DIR}/gates"
LEDGER="${GATES}/gate-ledger.tsv"
SUMMARY="${GATES}/gate-ledger-summary.sh"

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
check() { # check <name> <problems-text>
  if [ -z "$2" ]; then pass "$1"; else fail "$1" "$(head -10 <<<"$2")"; fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "=== gate ledger (seam-gate-safety G3) ==="

if [ ! -f "$LEDGER" ]; then
  fail "ledger exists" "no file at $LEDGER"
  echo "=== $PASS passed, $FAIL failed ==="
  exit 1
fi
grep -v '^#' "$LEDGER" | grep -v '^[[:space:]]*$' >"$WORK/rows"

echo "--- shape ---"
HEADER=$'iter\tgate\tround\tcode\tclass\toutcome\tunit\tcount\tlabel\tcause\tfixed\tlive\tf_id\tevidence\tnote'
if [ "$(head -1 "$WORK/rows")" = "$HEADER" ]; then
  pass "header row"
else
  fail "header row" "$(head -1 "$WORK/rows")"
fi
tail -n +2 "$WORK/rows" >"$WORK/data"
n=$(wc -l <"$WORK/data")
if [ "$n" -ge 100 ]; then pass "ledger holds the seed (${n} rows)"; else fail "ledger holds the seed" "${n} rows"; fi

problems=$(awk -F'\t' '
  function bad(m) { printf "row %d (%s %s %s): %s\n", NR, $1, $4, $7, m }
  NF != 15 { bad("has " NF " fields"); next }
  $1 !~ /^(0[1-9]|10|05b)$/ { bad("iter " $1) }
  $2 !~ /^(crosscheck|draft|draft-crosscheck|draft-guard|refinement|dor-check)$/ { bad("gate " $2) }
  $3 !~ /^(-|[0-9]|[0-9]-[0-9])$/ { bad("round " $3) }
  $4 !~ /^[A-Z][A-Z0-9_]+$/ { bad("code " $4) }
  $5 !~ /^(block|warn|revert)$/ { bad("class " $5) }
  $6 !~ /^(halted|revised|rebutted|demoted|reverted|accepted|hand-fixed|logged|expected)$/ { bad("outcome " $6) }
  $7 == "" || $7 ~ /[\/ ]/ && $7 !~ /^\(/ { bad("unit " $7) }
  $8 !~ /^[1-9][0-9]*$/ { bad("count " $8) }
  $9 !~ /^(true|false|debatable)$/ { bad("label " $9) }
  $10 !~ /^(plan-gap|live-logic|checker-bug|upstream-bug|format|env|negative-control|unlabelled)$/ { bad("cause " $10) }
  $11 !~ /^(yes|partial|no|-)$/ { bad("fixed " $11) }
  $12 !~ /^(yes|no|-)$/ { bad("live " $12) }
  $13 !~ /^(-|F[0-9]+( F[0-9]+)*)$/ { bad("f_id " $13) }
  $14 !~ /^(findings\.md|iter-(0[1-9]|10|05b)\/run-record\.md):[1-9][0-9]*$/ { bad("evidence " $14) }
  $15 == "" { bad("empty note") }
  ($5 == "warn") != ($6 == "logged") { bad("warn class and logged outcome go together") }
  ($5 == "revert") != ($2 == "draft-guard") { bad("revert class is a draft-guard fire") }
' "$WORK/data")
check "every row has 15 closed-value columns" "$problems"

problems=$(awk -F'\t' '
  function bad(m) { printf "row %d (%s %s %s): %s\n", NR, $1, $4, $7, m }
  $9 == "false" && $12 !~ /^(yes|no)$/ { bad("a false row must say live yes or no") }
  $9 != "false" && $12 != "-" { bad("only a false row carries live") }
  $9 == "false" && $10 ~ /^(plan-gap|negative-control|unlabelled)$/ { bad("false with cause " $10) }
  $9 == "true" && $10 !~ /^(plan-gap|negative-control)$/ { bad("true with cause " $10) }
  $10 == "unlabelled" && ($9 != "debatable" || $13 != "-") { bad("unlabelled is debatable with no f_id") }
  $10 ~ /^(checker-bug|upstream-bug|format|env)$/ && ($13 == "-" || $11 !~ /^(yes|partial|no)$/) { bad($10 " needs an f_id and fixed yes/partial/no") }
  $9 == "true" && $11 != "-" { bad("a true row has no fixed value") }
  $9 == "false" && $11 == "yes" && $12 != "no" { bad("fixed yes but live yes") }
  $9 == "false" && $11 == "no" && $12 != "yes" { bad("fixed no but live no") }
  $10 == "negative-control" && $7 != "negative-control" { bad("negative-control unit") }
' "$WORK/data")
check "label, cause, fixed and live agree" "$problems"

echo "--- corrections and the G4 rule ---"
problems=$(awk -F'\t' '
  $13 ~ /(^| )F25( |$)/ && $9 != "false" { print "F25 row labelled " $9 }
  $13 ~ /(^| )F43( |$)/ && $9 != "debatable" { print "F43 row labelled " $9 }
' "$WORK/data")
check "deep-dive D corrections: F25 false, F43 debatable" "$problems"
[ "$(awk -F'\t' '$13 ~ /F25|F43/' "$WORK/data" | wc -l)" -ge 2 ] && pass "F25 and F43 rows present" || fail "F25 and F43 rows present" "missing"
problems=$(awk -F'\t' '$13 ~ /(^| )F(12|22|24|33|52|67)( |$)/ && $12 != "no" { print $1 " " $4 " " $13 " live=" $12 }' "$WORK/data")
check "fires from fixed checker bugs (F12/F24, F22, F33, F52, F67) are not live" "$problems"
problems=$(awk -F'\t' '$4 == "DEPENDENCY_CYCLE" && $12 == "yes" { print $1 " live=yes" }' "$WORK/data")
check "no live DEPENDENCY_CYCLE false fire" "$problems"

echo "--- evidence pointers ---"
EVID="${GATE_LEDGER_EVIDENCE_DIR:-}"
if [ -n "$EVID" ] && [ -d "$EVID" ]; then
  problems=""
  while IFS=$'\t' read -r iter _gate _round code _class _out _unit _cnt _label cause _fixed _live fid ev _note; do
    file="${ev%:*}" line="${ev##*:}"
    if [ ! -f "${EVID}/${file}" ]; then
      problems+="${iter} ${code}: no ${file}"$'\n'
      continue
    fi
    text=$(sed -n "${line}p" "${EVID}/${file}")
    if [ -z "$text" ]; then
      problems+="${iter} ${code}: ${ev} is empty or past the end"$'\n'
    elif [ "$fid" != "-" ]; then
      for f in $fid; do
        /usr/bin/grep -qE "(^|[^0-9A-Za-z])${f}([^0-9]|$)" <<<"$text" || problems+="${iter} ${code}: ${ev} does not name ${f}"$'\n'
      done
    elif [ "$cause" != "unlabelled" ]; then
      /usr/bin/grep -qF "$code" <<<"$text" || problems+="${iter} ${code}: ${ev} does not name the code"$'\n'
    fi
  done <"$WORK/data"
  check "every pointer resolves in ${EVID} and names its f_id or code" "$problems"
else
  echo "  (GATE_LEDGER_EVIDENCE_DIR not set: pointer resolution skipped; the rehearsal folder is local)"
fi

echo "--- summary script ---"
sum_before=$(sha256sum "$LEDGER")
out=$(bash "$SUMMARY" 2>"$WORK/err")
rc=$?
if [ "$rc" -eq 0 ]; then pass "summary runs (rc 0)"; else fail "summary runs" "rc ${rc}: $(cat "$WORK/err")"; fi
[ "$sum_before" = "$(sha256sum "$LEDGER")" ] && pass "summary leaves the ledger untouched" || fail "summary leaves the ledger untouched" "changed"

want_fires=$(awk -F'\t' '{ s += $8 } END { print s }' "$WORK/data")
got_fires=$(awk -F'\t' '$1 == "fires" { print $2 }' <<<"$out")
[ "$got_fires" = "$want_fires" ] && pass "fires total = sum of count (${want_fires})" || fail "fires total" "got ${got_fires}, want ${want_fires}"
for l in true false debatable; do
  want=$(awk -F'\t' -v l="$l" '$9 == l { s += $8 } END { print s + 0 }' "$WORK/data")
  got=$(awk -F'\t' -v l="$l" '/^== fires by label/ { on = 1; next } on && /^$/ { on = 0 } on && $1 == l { print $2 }' <<<"$out")
  [ "$got" = "$want" ] && pass "label ${l} = ${want}" || fail "label ${l}" "got ${got}, want ${want}"
done

cands=$(awk -F'\t' '/^== G4 demotion candidates/ { on = 1; getline; next } on && NF { print $1 " " $2 }' <<<"$out")
# Pinned on purpose: a ledger change that adds or drops a candidate shows here.
want_cands=$'refinement MISSING_CORE_AC\ndraft EDGE_CASE_GAP\ndraft INTENT_AC_MISMATCH\ndraft-guard ASSUMPTION_INVALID'
[ "$cands" = "$want_cands" ] && pass "G4 candidates are the pinned four" || fail "G4 candidates" "got: ${cands}"

# Planted rows: a live false fire on a warn code, and on DEPENDENCY_CYCLE, are never
# candidates; a live false fire on a blocking code is.
cp "$LEDGER" "$WORK/planted.tsv"
printf '%s\n' \
  $'10\tcrosscheck\t-\tOWN_UNDECLARED_REF\twarn\tlogged\tx\t1\tfalse\tlive-logic\tno\tyes\t-\tfindings.md:1\tplanted' \
  $'10\tcrosscheck\t-\tDEPENDENCY_CYCLE\tblock\thalted\tx\t1\tfalse\tlive-logic\tno\tyes\t-\tfindings.md:1\tplanted' \
  $'10\tcrosscheck\t-\tSIGNALS_UNIFORM\tblock\thalted\tx\t2\tfalse\tlive-logic\tno\tyes\t-\tfindings.md:1\tplanted' >>"$WORK/planted.tsv"
pc=$(bash "$SUMMARY" --ledger "$WORK/planted.tsv" --section candidates | awk -F'\t' 'NR > 2 { print $1 " " $2 " " $8 }')
grep -q '^crosscheck SIGNALS_UNIFORM 2$' <<<"$pc" && pass "a live false fire on a blocking code is a candidate (window count 2)" || fail "planted blocking candidate" "$pc"
grep -qE 'OWN_UNDECLARED_REF|DEPENDENCY_CYCLE' <<<"$pc" && fail "warn codes and DEPENDENCY_CYCLE are never candidates" "$pc" || pass "warn codes and DEPENDENCY_CYCLE are never candidates"

mkdir -p "$WORK/emptylib"
GATE_LEDGER_PLANNER_LIB="$WORK/emptylib" bash "$SUMMARY" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] && pass "unreadable class lists fail closed (rc 2)" || fail "unreadable class lists fail closed" "rc ${rc}"
printf '01\tcrosscheck\tonly-three-fields\n' >>"$WORK/planted.tsv"
bash "$SUMMARY" --ledger "$WORK/planted.tsv" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 1 ] && pass "a malformed row fails (rc 1)" || fail "a malformed row fails" "rc ${rc}"
bash "$SUMMARY" --section nope >/dev/null 2>&1
[ $? -eq 2 ] && pass "unknown section is usage (rc 2)" || fail "unknown section is usage" "rc $?"

echo "--- privacy ---"
if out=$(CORPUS_PRIVACY_DIRS="$GATES" bash "${SCRIPT_DIR}/test-corpus-privacy.sh" 2>&1); then
  pass "corpus privacy scan passes over gates/"
else
  fail "corpus privacy scan passes over gates/" "$(grep FAIL <<<"$out" | head -5)"
fi
if grep -q 'gates' "${SCRIPT_DIR}/test-corpus-privacy.sh"; then
  pass "test-corpus-privacy.sh scans */gates by default"
else
  fail "test-corpus-privacy.sh scans */gates by default" "no gates directory in its default list"
fi

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
