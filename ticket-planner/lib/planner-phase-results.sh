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

# The timestamp of the latest Specify attempt's terminal line when that line
# is `done`; nothing (rc 1) when Specify has not finished, or its latest
# attempt started again or failed after its last `done`.
_planner_specify_done_ts() {
  local log="$1" last
  [ -f "$log" ] || return 1
  last=$(grep -E '^[^|]*\|Specify\|[^|]*\|(start|done|fail|skip)\|' "$log" 2>/dev/null | tail -1)
  [ -n "$last" ] || return 1
  [ "$(printf '%s' "$last" | cut -d'|' -f4)" = "done" ] || return 1
  printf '%s\n' "${last%%|*}"
}

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
