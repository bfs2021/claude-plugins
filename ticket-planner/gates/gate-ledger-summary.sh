#!/usr/bin/env bash
# gate-ledger-summary.sh — read-only counts over gate-ledger.tsv (change
# seam-gate-safety, slice G3). It changes no gate and writes no file.
#
# Usage: gate-ledger-summary.sh [--ledger FILE] [--section NAME]
#   --ledger   default: gate-ledger.tsv beside this script
#   --section  totals | label | cause | code | candidates (default: all)
#
# Fires are summed over the ledger's count column. "candidates" lists the codes
# G4 may consider for demotion: a code with at least one false fire whose cause
# is still live on main (live=yes) and whose class at that gate today is not
# warn. The class today is read from the planner libs:
#   crosscheck, draft-crosscheck  warn when the code is in
#                                 PLANNER_CROSSCHECK_WARN_CODES, or is
#                                 TEST_DATA_IMPLIED while
#                                 PLANNER_TESTDATA_IMPLIED_BLOCKS defaults false
#   draft                         warn when the code is in the default of
#                                 PLANNER_DRAFT_WARN_CODES
#   draft-guard                   revert (a guard never halts; it costs the round)
#   refinement, dor-check         block
# DEPENDENCY_CYCLE is never a candidate (PLAN G4: a derived-edge cycle stays
# BLOCK). The list is counts only: deciding a demotion is G4's job, with a
# fixture, the dor 20-28 anchor and a separate reviewer.
#
# Env: GATE_LEDGER_PLANNER_LIB overrides the planner lib directory the class
# lists are read from (default: ../lib beside this script).
#
# Exit: 0 printed; 1 the ledger is missing or a row is malformed; 2 usage, or a
# class list could not be read from the libs (never guessed).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEDGER="${HERE}/gate-ledger.tsv"
SECTION="all"
LIB="${GATE_LEDGER_PLANNER_LIB:-${HERE}/../lib}"

usage() {
  echo "usage: gate-ledger-summary.sh [--ledger FILE] [--section totals|label|cause|code|candidates]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
  --ledger)
    [ "$#" -ge 2 ] || usage
    LEDGER="$2"
    shift 2
    ;;
  --section)
    [ "$#" -ge 2 ] || usage
    SECTION="$2"
    shift 2
    ;;
  *) usage ;;
  esac
done
case "$SECTION" in all | totals | label | cause | code | candidates) ;; *) usage ;; esac

[ -f "$LEDGER" ] || {
  echo "gate-ledger-summary: no ledger at $LEDGER" >&2
  exit 1
}

# The class lists, read from the libs. An empty read is an error, never "no
# warn codes", so a refactor of those assignments fails here, loudly.
XC_WARN=$(sed -n 's/^PLANNER_CROSSCHECK_WARN_CODES="\(.*\)"$/\1/p' "${LIB}/planner-crosscheck.sh" 2>/dev/null | head -1)
DRAFT_WARN=$(grep -o 'PLANNER_DRAFT_WARN_CODES:\{0,1\}-[A-Z_ ]*}' "${LIB}/planner-draft-readiness-gate.sh" 2>/dev/null |
  head -1 | sed 's/^PLANNER_DRAFT_WARN_CODES:\{0,1\}-//; s/}$//')
if [ -z "$XC_WARN" ] || [ -z "$DRAFT_WARN" ]; then
  echo "gate-ledger-summary: cannot read the warn-code lists from ${LIB} (PLANNER_CROSSCHECK_WARN_CODES, PLANNER_DRAFT_WARN_CODES default)" >&2
  exit 2
fi
TDI_WARN=no
grep -q 'PLANNER_TESTDATA_IMPLIED_BLOCKS:-false' "${LIB}/planner-crosscheck-testdata.sh" 2>/dev/null && TDI_WARN=yes

awk -F'\t' -v section="$SECTION" -v xc_warn=" $XC_WARN " -v draft_warn=" $DRAFT_WARN " \
  -v tdi_warn="$TDI_WARN" '
  function class_now(gate, code) {
    if (gate == "draft-guard") return "revert"
    if (gate == "refinement" || gate == "dor-check") return "block"
    if (gate == "crosscheck" || gate == "draft-crosscheck") {
      if (index(xc_warn, " " code " ")) return "warn"
      if (code == "TEST_DATA_IMPLIED" && tdi_warn == "yes") return "warn"
      return "block"
    }
    if (gate == "draft") return index(draft_warn, " " code " ") ? "warn" : "block"
    return "unknown"
  }
  /^#/ || /^[[:space:]]*$/ { next }
  !hdr { hdr = 1; next }
  NF != 15 || $8 !~ /^[1-9][0-9]*$/ {
    printf "gate-ledger-summary: malformed row %d (%d fields)\n", NR, NF > "/dev/stderr"
    bad = 1
    next
  }
  {
    n = $8; key = $2 SUBSEP $4
    rows++; fires += n
    lab[$9] += n
    cause = $10
    if ($10 == "checker-bug" || $10 == "upstream-bug" || $10 == "format" || $10 == "env")
      cause = $10 " (fixed=" $11 ")"
    cz[cause] += n
    if (!(key in seen)) { seen[key] = 1; order[++nk] = key }
    tot[key] += n; byl[key, $9] += n
    if ($9 == "false") {
      if ($12 == "yes") lf[key] += n; else of[key] += n
    }
    # Sliding window over the fires of one gate+code in ledger (time) order:
    # the most live-false fires inside any 10 consecutive fires (deep-dive D
    # demotes B -> W at 2 in 10).
    for (i = 0; i < n; i++) {
      k = ++seq[key]
      win[key, k] = ($9 == "false" && $12 == "yes") ? 1 : 0
      run[key] += win[key, k]
      if (k > 10) run[key] -= win[key, k - 10]
      if (run[key] > wmax[key]) wmax[key] = run[key]
    }
  }
  END {
    if (bad) exit 1
    if (section == "all" || section == "totals")
      printf "== totals\nrows\t%d\nfires\t%d\n\n", rows, fires
    if (section == "all" || section == "label") {
      print "== fires by label"
      split("true false debatable", L, " ")
      for (i = 1; i <= 3; i++) printf "%s\t%d\n", L[i], lab[L[i]]
      print ""
    }
    if (section == "all" || section == "cause") {
      print "== fires by cause"
      nc = 0
      for (c in cz) C[++nc] = c
      for (i = 2; i <= nc; i++) { v = C[i]; for (j = i - 1; j >= 1 && C[j] > v; j--) C[j + 1] = C[j]; C[j + 1] = v }
      for (i = 1; i <= nc; i++) printf "%s\t%d\n", C[i], cz[C[i]]
      print ""
    }
    if (section == "all" || section == "code") {
      print "== fires by gate and code"
      print "gate\tcode\tclass_now\tfires\ttrue\tfalse\tfalse_live\tdebatable"
      for (i = 1; i <= nk; i++) {
        split(order[i], K, SUBSEP)
        printf "%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\n", K[1], K[2], class_now(K[1], K[2]), tot[order[i]],
          byl[order[i], "true"], byl[order[i], "false"], lf[order[i]], byl[order[i], "debatable"]
      }
      print ""
    }
    if (section == "all" || section == "candidates") {
      print "== G4 demotion candidates (false fire with live=yes, not warn today; counts only, nothing is demoted)"
      print "gate\tcode\tclass_now\tfalse_live\tfalse_not_live\ttrue\tdebatable\tmax_false_live_in_10"
      nc = 0
      for (i = 1; i <= nk; i++) {
        split(order[i], K, SUBSEP)
        if (lf[order[i]] < 1 || K[2] == "DEPENDENCY_CYCLE") continue
        cn = class_now(K[1], K[2])
        if (cn == "warn") continue
        nc++
        printf "%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\n", K[1], K[2], cn, lf[order[i]], of[order[i]],
          byl[order[i], "true"], byl[order[i], "debatable"], wmax[order[i]]
      }
      if (!nc) print "(none)"
    }
  }
' "$LEDGER"
