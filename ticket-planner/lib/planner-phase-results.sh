#!/usr/bin/env bash
# planner-phase-results.sh — facts bash derives from a phase's artifacts
# (seam-bash-derives, slice 1).
#
# The model judges; bash knows. A check never reads a number or a list out of
# a status line an agent wrote: that text is for people, and it is written
# before the work is done, or retyped after it (rehearsal F67: Specify's start
# line said "for 7 tickets", the phase then wrote 8 specs, and Crosscheck
# blocked with CARVE_SCOPE_LOST). What a check needs, bash derives from the
# files on disk once the phase has finished and writes into
#
#   artifacts/phase-results/<phase>.json
#
# Specify is the first (and in slice 1 the only) phase with a result file:
#
#   { "version": 1, "phase": "Specify", "derived_by": "bash",
#     "specify_done": "<ISO of the Specify done line it was derived after>",
#     "specs": ["<slug>", …],   # artifacts/specs/*.md, sorted, minus INDEX.md
#                               # and synth-marked TD specs
#     "count": <n> }
#
# Functions:
#   planner_phase_result_path <initiative_id> <phase>
#       the result file path (<phase> lower-cased); rc 1 when the initiative
#       directory cannot be resolved
#   planner_specify_result_write <initiative_id>
#       lists artifacts/specs/ and writes specify.json (tmp + mv); rc 1 with a
#       message on stderr when it cannot
#   planner_specify_result_ensure <initiative_id>
#       writes specify.json when Specify's latest attempt ended `done` and the
#       file is missing or was derived after an earlier `done`; otherwise
#       nothing. Called by the router after the Specify agent returns
#       (`planner_dispatch_gate post`) and again before Review is dispatched
#       (`pre`), so a router that crashed between the two still records it
#   planner_specify_result_slugs <file>
#       prints the recorded slugs one per line; rc 1 (reason on stderr) when
#       the file is missing or is not a valid version-1 result — the caller
#       must fail closed, never treat it as "nothing recorded"
#
# Consensus (slice 2) records the disposition of every review finding, read
# from consensus.md's `### <id> — <severity> — <title> — <disposition>`
# headings under `## Findings Addressed` (rehearsal F70: the agent's status
# line said 11/0/2, its own headings said 12/0/1):
#
#   { "version": 1, "phase": "Consensus", "derived_by": "bash",
#     "consensus_done": "<ISO of the Consensus done line>",
#     "findings": [{"id": "F1", "disposition": "accepted"}, …],
#     "counts": {"accepted": a, "rejected": r, "deferred": d},
#     "total": <n> }
#
#   planner_consensus_result_write <initiative_id>
#       rc 0 written; rc 2 the headings cannot be read (reason on stderr) —
#       an earlier file is removed, so a reader finds nothing rather than a
#       stale or guessed count (fail closed); rc 1 cannot write
#   planner_consensus_result_ensure <initiative_id>
#       writes it when Consensus's latest attempt ended `done` and the file is
#       missing or was derived after an earlier `done`; otherwise nothing.
#       Called by `planner_dispatch_gate post` after Consensus and by `pre`
#       before Crosscheck. Nothing blocks on the file yet
#   planner_consensus_result_counts <file>
#       prints `<accepted> <rejected> <deferred>`; rc 1 when the file is
#       missing or is not a valid version-1 Consensus result
#   _planner_consensus_dispositions <consensus.md>
#       `<id>\t<disposition>` per finding; rc 2 with the reason on stderr when
#       the section is missing, holds no id heading (and does not say
#       `None.`), or an id heading lacks a closed-set last segment
#
# Sourceable library — no set -euo pipefail.

if ! declare -f planner_initiative_dir >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/planner-state.sh"
fi

PLANNER_PHASE_RESULTS_VERSION=1

planner_phase_result_path() {
  local initiative_id="$1" phase="$2" dir
  dir=$(planner_initiative_dir "$initiative_id") || return 1
  [ -n "$dir" ] || return 1
  printf '%s/artifacts/phase-results/%s.json\n' "$dir" "$(printf '%s' "$phase" | tr '[:upper:]' '[:lower:]')"
}

# The timestamp of the latest <phase> attempt's terminal line when that line
# is `done`; nothing (rc 1) when the phase has not finished, or its latest
# attempt started again or failed after its last `done`.
_planner_phase_done_ts() {
  local log="$1" phase="$2" last
  [ -f "$log" ] || return 1
  last=$(grep -E "^[^|]*\\|${phase}\\|[^|]*\\|(start|done|fail|skip)\\|" "$log" 2>/dev/null | tail -1)
  [ -n "$last" ] || return 1
  [ "$(printf '%s' "$last" | cut -d'|' -f4)" = "done" ] || return 1
  printf '%s\n' "${last%%|*}"
}

_planner_specify_done_ts() { _planner_phase_done_ts "$1" Specify; }

# The spec slugs Specify wrote: artifacts/specs/*.md minus INDEX.md and the
# TD specs Crosscheck's test-data synthesis writes (marker line), sorted.
_planner_specify_slugs_on_disk() {
  local specs_dir="$1" f base
  [ -d "$specs_dir" ] || return 0
  for f in "$specs_dir"/*.md; do
    [ -f "$f" ] || continue
    base=$(basename "$f" .md)
    [ "$base" = "INDEX" ] && continue
    grep -qF -- "${PLANNER_TESTDATA_SYNTH_MARKER:-<!-- planner:testdata-synth v1 -->}" "$f" 2>/dev/null && continue
    printf '%s\n' "$base"
  done | LC_ALL=C sort
}

planner_specify_result_write() {
  local initiative_id="$1" dir out ts tmp
  dir=$(planner_initiative_dir "$initiative_id") || return 1
  out=$(planner_phase_result_path "$initiative_id" Specify) || return 1
  ts=$(_planner_specify_done_ts "$(planner_state_log "$initiative_id")") || ts=""
  mkdir -p "$(dirname "$out")" || {
    echo "planner-phase-results: cannot create $(dirname "$out")" >&2
    return 1
  }
  tmp="${out}.tmp.$$"
  if ! _planner_specify_slugs_on_disk "${dir}/artifacts/specs" |
    jq -R -s --arg ts "$ts" --argjson v "$PLANNER_PHASE_RESULTS_VERSION" '
      (split("\n") | map(select(length > 0))) as $s
      | {version: $v, phase: "Specify", derived_by: "bash",
         specify_done: $ts, specs: $s, count: ($s | length)}' >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "planner-phase-results: could not write ${out}" >&2
    return 1
  fi
  mv -f "$tmp" "$out" || {
    rm -f "$tmp"
    echo "planner-phase-results: could not write ${out}" >&2
    return 1
  }
}

planner_specify_result_ensure() {
  local initiative_id="$1" out ts have
  ts=$(_planner_specify_done_ts "$(planner_state_log "$initiative_id")") || return 0
  out=$(planner_phase_result_path "$initiative_id" Specify) || return 1
  if [ -f "$out" ]; then
    have=$(jq -r '.specify_done // ""' "$out" 2>/dev/null)
    [ "$have" = "$ts" ] && return 0
  fi
  planner_specify_result_write "$initiative_id"
}

planner_specify_result_slugs() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "missing: ${file}" >&2
    return 1
  fi
  if ! jq -e --argjson v "$PLANNER_PHASE_RESULTS_VERSION" '
      .version == $v and .phase == "Specify" and (.specs | type == "array")
      and all(.specs[]; type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]*$"))
      and .count == (.specs | length)' "$file" >/dev/null 2>&1; then
    echo "not a version-${PLANNER_PHASE_RESULTS_VERSION} Specify result: ${file}" >&2
    return 1
  fi
  jq -r '.specs[]' "$file"
}

# ── Consensus (slice 2) ─────────────────────────────────────────────────────

_planner_consensus_dispositions() {
  local file="$1" raw err
  if [ ! -f "$file" ]; then
    echo "no consensus.md at ${file}" >&2
    return 2
  fi
  # One `OK\t<id>\t<disposition>` per finding heading, `ERR <reason>` per
  # unreadable one. Fence-aware, CR stripped, only `## Findings Addressed`
  # (the goldfish section has its own `### G<n>` headings).
  # shellcheck disable=SC2016  # awk program, not shell
  raw=$(LC_ALL=C awk '
    BEGIN { sep = " \342\200\224 " }
    { sub(/\r$/, "") }
    /^[ \t]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    /^## / {
      s = $0; sub(/[ \t]+$/, "", s)
      insec = (s == "## Findings Addressed")
      if (insec) found = 1
      next
    }
    !insec { next }
    /^[ \t]*$/ { next }
    first == "" { first = $0 }
    /^###[ \t]+[A-Z][A-Z]?[A-Z]?[0-9]+([^A-Za-z0-9]|$)/ {
      h = $0; sub(/^###[ \t]+/, "", h)
      i = index(h, sep)
      if (i == 0) { print "ERR finding heading without \" — \" separators: " $0; next }
      id = substr(h, 1, i - 1)
      if (id !~ /^[A-Z][A-Z]?[A-Z]?[0-9]+$/) { print "ERR finding heading id not readable: " $0; next }
      # The disposition is the last segment: a title may itself start with
      # "Rejected" or "Accepted".
      seg = h
      while ((j = index(seg, sep)) > 0) seg = substr(seg, j + length(sep))
      sub(/^[ \t*_]+/, "", seg)
      w = seg; sub(/[^A-Za-z].*$/, "", w); w = tolower(w)
      if (w != "accepted" && w != "rejected" && w != "deferred") {
        print "ERR " id " has no accepted/rejected/deferred disposition (\"" seg "\")"; next
      }
      if (id in seen) { print "ERR finding " id " has two headings"; next }
      seen[id] = 1
      print "OK\t" id "\t" w
      n++
    }
    END {
      if (!found) { print "ERR consensus.md has no ## Findings Addressed section"; exit }
      if (n == 0) {
        f = tolower(first); gsub(/[*_.]/, "", f); sub(/[ \t]+$/, "", f)
        if (f != "none") print "ERR no \"### <id> — <severity> — <title> — <disposition>\" heading under ## Findings Addressed"
      }
    }
  ' "$file")
  err=$(printf '%s\n' "$raw" | grep -m1 '^ERR ')
  if [ -n "$err" ]; then
    echo "${err#ERR }" >&2
    return 2
  fi
  printf '%s\n' "$raw" | sed -n 's/^OK\t//p'
}

planner_consensus_result_write() {
  local initiative_id="$1" dir out ts tmp disp
  dir=$(planner_initiative_dir "$initiative_id") || return 1
  out=$(planner_phase_result_path "$initiative_id" Consensus) || return 1
  ts=$(_planner_phase_done_ts "$(planner_state_log "$initiative_id")" Consensus) || ts=""
  if ! disp=$(_planner_consensus_dispositions "${dir}/artifacts/consensus.md"); then
    rm -f "$out"
    echo "planner-phase-results: ${out##*/artifacts/} not written — the dispositions in consensus.md cannot be read" >&2
    return 2
  fi
  mkdir -p "$(dirname "$out")" || {
    echo "planner-phase-results: cannot create $(dirname "$out")" >&2
    return 1
  }
  tmp="${out}.tmp.$$"
  if ! printf '%s\n' "$disp" |
    jq -R -s --arg ts "$ts" --argjson v "$PLANNER_PHASE_RESULTS_VERSION" '
      (split("\n") | map(select(length > 0) | split("\t") | {id: .[0], disposition: .[1]})) as $f
      | def n($d): $f | map(select(.disposition == $d)) | length;
      {version: $v, phase: "Consensus", derived_by: "bash", consensus_done: $ts,
       findings: $f,
       counts: {accepted: n("accepted"), rejected: n("rejected"), deferred: n("deferred")},
       total: ($f | length)}' >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "planner-phase-results: could not write ${out}" >&2
    return 1
  fi
  mv -f "$tmp" "$out" || {
    rm -f "$tmp"
    echo "planner-phase-results: could not write ${out}" >&2
    return 1
  }
}

planner_consensus_result_ensure() {
  local initiative_id="$1" out ts have
  ts=$(_planner_phase_done_ts "$(planner_state_log "$initiative_id")" Consensus) || return 0
  out=$(planner_phase_result_path "$initiative_id" Consensus) || return 1
  if [ -f "$out" ]; then
    have=$(jq -r '.consensus_done // ""' "$out" 2>/dev/null)
    [ "$have" = "$ts" ] && return 0
  fi
  planner_consensus_result_write "$initiative_id"
}

planner_consensus_result_counts() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "missing: ${file}" >&2
    return 1
  fi
  if ! jq -e --argjson v "$PLANNER_PHASE_RESULTS_VERSION" '
      .version == $v and .phase == "Consensus" and (.findings | type == "array")
      and all(.findings[]; .disposition == "accepted" or .disposition == "rejected" or .disposition == "deferred")
      and .total == (.findings | length)
      and .counts.accepted + .counts.rejected + .counts.deferred == .total' "$file" >/dev/null 2>&1; then
    echo "not a version-${PLANNER_PHASE_RESULTS_VERSION} Consensus result: ${file}" >&2
    return 1
  fi
  jq -r '"\(.counts.accepted) \(.counts.rejected) \(.counts.deferred)"' "$file"
}
