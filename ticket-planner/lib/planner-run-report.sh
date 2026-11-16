#!/usr/bin/env bash
# planner-run-report.sh — read-out of an initiative's run telemetry (#631).
#
# Usage: planner-run-report.sh <INIT_ID> [--no-sync]
#
# Prints a markdown block for a rehearsal iteration's run-record.md: one row
# per phase attempt (wall-clock, outcome, tokens), one row per planner run, and
# two paste-ready lines, `Timing:` and `Cost:`. Tokens are never estimated: a
# phase whose agent transcript was not found prints UNMEASURED, a bash-only
# phase prints `n/a (bash)`.
#
# Reads <initiative>/telemetry/runs.jsonl (planner-run-telemetry.sh). Without
# --no-sync it first records any closed phase attempt not yet written, so the
# table is complete even when the Stop hook never fired; an open run stays
# open (its summary is written by the hook or the next `begin`).
# Read-only apart from that sync. Exit 0 printed, 1 no telemetry, 2 usage.
#
# Always ends with an `Unevaluated:` line (seam-gate-safety D4), printed even
# when there is no telemetry: the drafts the latest draft gate run could not
# judge (n/m), the epic's children carrying ready.harness_error, and the
# `META|harness-error` lines in the state log. A run with any unevaluated
# draft or ticket is not a clean run (runbook §5); a count that cannot be
# read prints `unknown`, which is not clean either.

_PRR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=planner-run-telemetry.sh
source "${_PRR_DIR}/planner-run-telemetry.sh"

# planner_run_unevaluated <INIT> — the `Unevaluated:` line.
planner_run_unevaluated() {
  local init="$1" log run drafts="0" tickets tids harness clean="yes"
  log=$(planner_state_log "$init" 2>/dev/null) || log=""
  if [ -n "$log" ] && [ -f "$log" ]; then
    harness=$(grep -c '^[^|]*|META|harness-error|' "$log" 2>/dev/null) || harness=0
    # The latest draft gate run: its `(run) UNEVALUATED|HARNESS_ERROR n/m`
    # line, else 0 of the drafts its done line counted.
    run=$(awk '/^[^|]*\|META\|draft-readiness\|start\|/ {buf = ""} {buf = buf $0 "\n"} END {printf "%s", buf}' "$log")
    if grep -q '^[^|]*|META|draft-readiness|start|' "$log"; then
      drafts=$(printf '%s' "$run" | grep -E '^[^|]*\|META\|draft-readiness\|(warn|fail)\|\(run\) (UNEVALUATED|HARNESS_ERROR) ' |
        tail -1 | cut -d'|' -f5- | awk '{print $3}')
      if [ -z "$drafts" ]; then
        drafts=$(printf '%s' "$run" | grep '^[^|]*|META|draft-readiness|done|' | tail -1 | cut -d'|' -f5- |
          awk '$2 ~ /^[0-9]+\/[0-9]+$/ {split($2, a, "/"); print "0/" a[2]}')
        [ -n "$drafts" ] || drafts="unknown"
      fi
    fi
  else
    harness="unknown"
  fi
  # Tickets: Refinement's own rule (planner_refinement_unevaluated), only
  # once an epic exists.
  tickets=0
  if grep -q '|EpicGen|' "$log" 2>/dev/null; then
    tids=""
    if { declare -f planner_refinement_unevaluated >/dev/null 2>&1 ||
      source "${_PRR_DIR}/planner-refinement.sh" 2>/dev/null; } &&
      _planner_refinement_source_deps 2>/dev/null; then
      tids=$(planner_refinement_unevaluated "$init" 2>/dev/null | cut -f1 | paste -sd, -)
      if [ -n "$tids" ]; then
        tickets="$(awk -F, '{print NF}' <<<"$tids") (${tids})"
      fi
    else
      tickets="unknown"
    fi
  fi
  case "$drafts" in 0 | 0/*) ;; *) clean="no" ;; esac
  case "$tickets" in 0) ;; *) clean="no" ;; esac
  echo "Unevaluated: drafts ${drafts}, tickets ${tickets}, harness-error lines ${harness} — $([ "$clean" = yes ] && echo "nothing unevaluated" || echo "not a clean run")"
}

planner_run_report() {
  local init="$1" sync="${2:-sync}" dir runs
  dir=$(planner_initiative_dir "$init") || return 2
  [ "$sync" = "sync" ] && planner_telemetry_sync "$init"
  runs="$dir/telemetry/runs.jsonl"
  if [ ! -s "$runs" ]; then
    echo "No run telemetry for ${init} (${runs})." >&2
    planner_run_unevaluated "$init"
    return 1
  fi
  jq -rRs --arg init "$init" --arg bash "$PLANNER_TELEMETRY_BASH_PHASES" '
    def dur: (. // 0) / 1000 | floor
      | if . >= 3600 then "\(. / 3600 | floor)h \(. % 3600 / 60 | floor)m"
        elif . >= 60 then "\(. / 60 | floor)m \(. % 60)s" else "\(.)s" end;
    def tok($p; $agents):
      if . != null then "\(.input) | \(.output) | \(.cache_read) | \(.cache_create)"
      elif ($agents == 0 and ($bash | split(" ") | index($p))) then "n/a (bash) | | |"
      else "UNMEASURED | | |" end;
    def tsum: reduce .[] as $t (null;
      if $t == null then . elif . == null then $t else
        {input: (.input + $t.input), output: (.output + $t.output),
         cache_read: (.cache_read + $t.cache_read), cache_create: (.cache_create + $t.cache_create)} end);
    [split("\n")[] | fromjson? | select(type == "object")] as $all
    | [$all[] | select(.kind == "planner_phase")] | group_by([.phase, .started_at]) | map(last)
    | sort_by(.started_at, .attempt) as $phases
    | [$all[] | select(.kind == "planner_run")] | sort_by(.started_at) as $runs
    | "## Planner run telemetry — \($init)",
      "",
      "| Phase | Attempt | Started (UTC) | Wall-clock | Outcome | Agents | Input | Output | Cache read | Cache write |",
      "|---|---|---|---|---|---|---|---|---|---|",
      ($phases[] | "| \(.phase) | \(.attempt) | \(.started_at) | \(.wall_ms | dur) | \(.outcome)\(if .halt_code then " " + .halt_code else "" end)\(if (.revise_rounds // 0) > 0 then " (revise rounds \(.revise_rounds))" else "" end) | \(.agents) | \(. as $r | $r.tokens | tok($r.phase; $r.agents)) |"),
      "",
      "| Run | Started (UTC) | Wall-clock | Furthest phase | Stop | Revise rounds | Answer rounds | Orchestrator tokens (in/out/cache r/w) |",
      "|---|---|---|---|---|---|---|---|",
      ($runs[] | "| \(.run_id) | \(.started_at) | \(.wall_ms | dur) | \(.furthest_phase // "-") | \(.stop_reason // "-") | \(.draft_revise_rounds) | \(.human_answer_rounds) | \(if .tokens.orchestrator == null then "UNMEASURED" else (.tokens.orchestrator | "\(.input)/\(.output)/\(.cache_read)/\(.cache_create)") end) |"),
      "",
      ( ([$phases[] | {phase, ms: .wall_ms}] | group_by(.phase) | map({phase: .[0].phase, ms: (map(.ms) | add)}) | sort_by(.ms) | reverse) as $per
        | "Timing: \([$runs[].wall_ms] | add | dur) wall-clock across \($runs | length) run(s); phases \([$phases[].wall_ms] | add | dur) — \([$per[] | "\(.phase) \(.ms | dur)"] | join(", "))" ),
      ( ([$phases[].tokens] | tsum) as $pt
        | ([$runs[].tokens.orchestrator | select(. != null) | {input, output, cache_read, cache_create}] | tsum) as $ot
        | ([$pt, $ot] | tsum) as $tt
        | [$phases[] | . as $p | select($p.tokens == null and (($bash | split(" ") | index($p.phase)) | not)) | $p.phase] | unique as $um
        | "Cost: \(if $tt == null then "UNMEASURED" else "tokens in \($tt.input) / out \($tt.output) / cache read \($tt.cache_read) / cache write \($tt.cache_create) (phase agents + orchestrator)" end)\(if ($um | length) > 0 then "; UNMEASURED: \($um | join(", "))" else "" end)" )
  ' "$runs" || return 1
  planner_run_unevaluated "$init"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ -z "${1:-}" ]; then
    echo "Usage: planner-run-report.sh <INIT_ID> [--no-sync]" >&2
    exit 2
  fi
  _mode=sync
  [ "${2:-}" = "--no-sync" ] && _mode=nosync
  planner_run_report "$1" "$_mode"
  exit $?
fi
