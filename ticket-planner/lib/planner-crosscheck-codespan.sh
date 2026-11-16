#!/usr/bin/env bash
# planner-crosscheck-codespan.sh — Inline code spans whose edge spaces markdown drops.
#
# Part of the Crosscheck check family (dispatch rehearsal iter 07, F53). A spec
# criterion tested the slug of the title `  Hello,  World!! `. CommonMark strips
# one space from each end of an inline code span that both starts and ends with
# a space (and is not all spaces), so every renderer, and Linear when it stores
# the ticket, reads ` Hello,  World!!`: the trailing-space case of the test was
# lost without anyone seeing it. The markdown source and what a reader sees
# disagree, and the test value is ambiguous.
#
# Flagged: a code span on a line outside fenced blocks whose content starts
# with a space and ends with a space and is not only spaces. A span is a
# backtick run of length N and the next backtick run of exactly length N on
# the same line, as in CommonMark (spans that wrap across lines are not
# checked). Spans with a space at one end only are not flagged: markdown keeps
# those as written.
#
# Fix: quote the value inside the span (`"  Hello,  World!! "`), or describe the
# spaces in words.
#
# Code: CODE_SPAN_EDGE_SPACE (warn), one finding per span. Synth-marked TD
# specs are skipped.
#
# Usage:
#   planner_crosscheck_codespan <initiative_id>
#     Returns: 0 if clean, 1 if any finding was reported.
#
# Sourceable library — no set -euo pipefail.

_PLANNER_CROSSCHECK_CODESPAN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -f _planner_crosscheck_contracts_defenced >/dev/null 2>&1; then
  # shellcheck source=planner-crosscheck-contracts.sh
  source "${_PLANNER_CROSSCHECK_CODESPAN_LIB_DIR}/planner-crosscheck-contracts.sh"
fi

# Flagged spans of one file, one "<line>\t<raw span content>" line each, in
# file order. Fenced lines are blanked first, so line numbers stay true.
# Usage: _planner_crosscheck_codespan_one <file>
_planner_crosscheck_codespan_one() {
  _planner_crosscheck_contracts_defenced "$1" | tr -d '\r' | awk '
    function run(s, i,   n) {
      n = 0
      while (substr(s, i + n, 1) == "`") n++
      return n
    }
    {
      s = $0
      len = length(s)
      i = 1
      while (i <= len) {
        if (substr(s, i, 1) != "`") { i++; continue }
        n = run(s, i)
        # Find the next backtick run of exactly n.
        j = i + n
        close_at = 0
        while (j <= len) {
          if (substr(s, j, 1) != "`") { j++; continue }
          m = run(s, j)
          if (m == n) { close_at = j; break }
          j += m
        }
        if (!close_at) { i += n; continue }
        c = substr(s, i + n, close_at - i - n)
        if (length(c) >= 2 && substr(c, 1, 1) == " " && substr(c, length(c), 1) == " " && c !~ /^ +$/) {
          gsub(/\t/, " ", c)
          printf "%d\t%s\n", NR, c
        }
        i = close_at + n
      }
    }
  '
}

# Usage: planner_crosscheck_codespan <initiative_id>
planner_crosscheck_codespan() {
  local initiative_id="$1"
  local repos_root="${REPOS_ROOT:-}"
  [ -n "$repos_root" ] || {
    echo "ERROR: REPOS_ROOT is not set — refusing to guess (#459)" >&2
    return 1
  }
  local specs_dir="${repos_root}/.ticket-auto/initiatives/${initiative_id}/artifacts/specs"
  [ -d "$specs_dir" ] || return 0

  local spec_file base ln span seen found=0
  for spec_file in "$specs_dir"/*.md; do
    [ -f "$spec_file" ] || continue
    base="$(basename "$spec_file")"
    [ "$base" = "INDEX.md" ] && continue
    grep -qF -- "${PLANNER_TESTDATA_SYNTH_MARKER:-<!-- planner:testdata-synth v1 -->}" "$spec_file" 2>/dev/null && continue
    while IFS=$'\t' read -r ln span; do
      [ -n "$ln" ] || continue
      seen="${span:1:${#span}-2}"
      echo "planner-crosscheck-codespan: CODE_SPAN_EDGE_SPACE ${base}:${ln} inline code \`${span}\` starts and ends with a space; markdown drops one space from each end, so readers and Linear see \`${seen}\` — quote the value inside the span (e.g. \`\"${span}\"\`) or describe the spaces in words"
      found=1
    done < <(_planner_crosscheck_codespan_one "$spec_file")
  done
  [ "$found" -eq 0 ]
}
