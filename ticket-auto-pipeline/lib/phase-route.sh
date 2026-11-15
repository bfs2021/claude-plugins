#!/usr/bin/env bash
# phase-route.sh — the router's VERIFY / PR-REVIEW verdict, decided by bash
# from the parsed PHASE_RESULT (seam audit Track 0.2).
#
# The router used to pick RESULT=/VERDICT= by reading the agent's free-text
# return (for PR-REVIEW, an emoji). `phase-result-parse.sh` already validates
# the agent's machine-readable block and logs it as META|phase-result; this
# turns that record into the routing decision, so a FAIL can no longer be
# logged as PASS and carried on to merge. The model judges; bash knows.
#
# Usage (sourced):  phase_route <VERIFY|PR-REVIEW> <LOG_FILE>
# CLI:              phase-route.sh <VERIFY|PR-REVIEW> <LOG_FILE>
#
# Reads only the current bracket: the lines after the phase's last
# `|<PHASE>|<step>|waiting|` line (step = verify / pr-review). In it:
#   - the last META|phase-result whose .phase is <PHASE>;
#   - VERIFY: the last META|claim-delta (verdict-recompute.sh);
#   - PR-REVIEW: a `PR-REVIEW|pr-review|done|N/A` no-diff marker, honoured
#     only when the log also has IMPLEMENT|commit-push|skip| (written by
#     implement-diff-check.sh).
#
# Output (eval-safe, always printed):
#   ROUTE_RESULT=done|fail
#   ROUTE_VERDICT=PASS|FAIL|OK|WARN|BLOCK
#   ROUTE_SOURCE=phase-result|no-verdict|invalid|claim-delta|no-diff|no-bracket
#
# Decision (fail closed — a missing or unparseable verdict never passes):
#   VERIFY     PASS                         → done PASS
#              PASS, but claim-delta says optimistic on fresh evidence with
#              criteria_total > 0           → fail FAIL (claim-delta)
#              FAIL / WARN / BLOCK          → fail FAIL
#              absent / invalid / no bracket → fail FAIL
#   PR-REVIEW  PASS → done OK, WARN → done WARN, FAIL / BLOCK → done BLOCK
#              absent / invalid / no bracket → done BLOCK
#              (PR-REVIEW terminals are always `done`; ITERATION counts them)
#
# Exit: 0 decided, 2 usage. Writes nothing.
#
# -u and -e intentionally omitted (sourceable lib; repo convention).

_prt_emit() {
  echo "ROUTE_RESULT=$1"
  echo "ROUTE_VERDICT=$2"
  echo "ROUTE_SOURCE=$3"
}

# _prt_fail <PHASE> <source> — the fail-closed answer for a phase.
_prt_fail() {
  if [ "$1" = "VERIFY" ]; then
    _prt_emit fail FAIL "$2"
  else
    _prt_emit done BLOCK "$2"
  fi
}

phase_route() {
  local phase="${1:-}" log="${2:-}" step
  case "$phase" in
  VERIFY) step=verify ;;
  PR-REVIEW) step=pr-review ;;
  *)
    echo "phase-route: phase must be VERIFY or PR-REVIEW, got '${phase}'" >&2
    return 2
    ;;
  esac
  if [ -z "$log" ] || [ ! -f "$log" ]; then
    _prt_fail "$phase" no-bracket
    return 0
  fi

  local open bracket
  open=$(grep -n "^[^|]*|${phase}|${step}|waiting|" "$log" 2>/dev/null | tail -1 | cut -d: -f1) || open=""
  if [ -z "$open" ]; then
    _prt_fail "$phase" no-bracket
    return 0
  fi
  bracket=$(tail -n "+$((open + 1))" "$log" 2>/dev/null) || bracket=""

  # PR-REVIEW no-diff exemption: there is no PR to review, and no PR to merge.
  if [ "$phase" = "PR-REVIEW" ] &&
    grep -q '^[^|]*|PR-REVIEW|pr-review|done|N/A' <<<"$bracket" &&
    grep -q '^[^|]*|IMPLEMENT|commit-push|skip|' "$log" 2>/dev/null; then
    _prt_emit done OK no-diff
    return 0
  fi

  local rec status verdict
  rec=$(grep '^[^|]*|META|phase-result|info|' <<<"$bracket" |
    awk -F'|' '{s=$5; for(i=6;i<=NF;i++) s=s"|"$i; print s}' |
    jq -c --arg p "$phase" 'select(type == "object" and .phase == $p)' 2>/dev/null | tail -1) || rec=""
  if [ -z "$rec" ]; then
    _prt_fail "$phase" no-verdict
    return 0
  fi
  status=$(jq -r '.parse_status // ""' <<<"$rec" 2>/dev/null) || status=""
  verdict=$(jq -r '.claimed_verdict // ""' <<<"$rec" 2>/dev/null) || verdict=""
  if [ "$status" != "ok" ]; then
    _prt_fail "$phase" invalid
    return 0
  fi

  if [ "$phase" = "VERIFY" ]; then
    if [ "$verdict" != "PASS" ]; then
      _prt_emit fail FAIL phase-result
      return 0
    fi
    local delta optimistic
    delta=$(grep '^[^|]*|META|claim-delta|info|' <<<"$bracket" |
      awk -F'|' '{s=$5; for(i=6;i<=NF;i++) s=s"|"$i; print s}' | tail -1) || delta=""
    optimistic=$(jq -r 'if .direction == "optimistic"
        and ((.evidence_state // "") | startswith("fresh"))
        and ((.criteria_total // 0) > 0) then "yes" else "no" end' <<<"$delta" 2>/dev/null) || optimistic="no"
    if [ "$optimistic" = "yes" ]; then
      _prt_emit fail FAIL claim-delta
      return 0
    fi
    _prt_emit done PASS phase-result
    return 0
  fi

  case "$verdict" in
  PASS) _prt_emit done OK phase-result ;;
  WARN) _prt_emit done WARN phase-result ;;
  *) _prt_emit done BLOCK phase-result ;;
  esac
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  [ $# -eq 2 ] || {
    echo "Usage: phase-route.sh <VERIFY|PR-REVIEW> <LOG_FILE>" >&2
    exit 2
  }
  phase_route "$1" "$2"
  exit $?
fi
