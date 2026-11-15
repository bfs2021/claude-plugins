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
# Which lines count. The agent writes to the same pipeline log while its
# bracket is open, so a META|phase-result line it wrote itself must never be
# read as the parser's. `router-step.sh post-spawn` runs after the agent has
# returned and writes `META|phase-route-anchor|info|<PHASE> …` immediately
# before it runs the parser. This reads:
#   - the bracket: lines after the phase's last `|<PHASE>|<step>|waiting|`
#     line (step = verify / pr-review);
#   - the anchor: the LAST anchor line for <PHASE> in the bracket (an anchor
#     the agent forged earlier is superseded by bash's, written later);
#   - the record: the FIRST META|phase-result for <PHASE> after the anchor —
#     the parser's own line. No anchor, or no record after it, is no verdict.
#   - VERIFY: the first META|claim-delta after the anchor (verdict-recompute.sh).
#
# PR-REVIEW no-diff exemption (a verification-only ticket has no PR): routes
# `done OK no-diff` only when ALL hold — the parser found no block at all
# (parse_status=absent; a parsed FAIL/BLOCK/WARN/PASS or an invalid block is
# never overridden), the bracket has `PR-REVIEW|pr-review|done|N/A`, the
# current implement attempt (after the last `IMPLEMENT|implement|waiting|`)
# logged `IMPLEMENT|commit-push|skip|`, and the log names no PR at all (no
# `PR-REVIEW|checkout-pr|done|`, no `META|pr-created`). auto-merge.sh refuses
# a no-diff route — there is nothing to merge.
#
# Output (eval-safe, always printed):
#   ROUTE_RESULT=done|fail
#   ROUTE_VERDICT=PASS|FAIL|OK|WARN|BLOCK
#   ROUTE_SOURCE=phase-result|no-verdict|invalid|claim-delta|no-diff|no-bracket|no-anchor
#
# Decision (fail closed — a missing or unparseable verdict never passes):
#   VERIFY     PASS                         → done PASS
#              PASS, but claim-delta says optimistic on fresh evidence with
#              criteria_total > 0           → fail FAIL (claim-delta)
#              FAIL / WARN / BLOCK          → fail FAIL
#              absent / invalid / no anchor → fail FAIL
#   PR-REVIEW  PASS → done OK, WARN → done WARN, FAIL / BLOCK → done BLOCK
#              absent / invalid / no anchor → done BLOCK
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

# _prt_msg — field 5.. of each input line (messages may contain `|`).
_prt_msg() {
  awk -F'|' '{s=$5; for(i=6;i<=NF;i++) s=s"|"$i; print s}'
}

# _prt_no_diff <log> <bracket> — rc 0 when the no-diff exemption holds
# (everything but the parse_status check, which the caller makes).
_prt_no_diff() {
  local log="$1" bracket="$2" impl
  grep -q '^[^|]*|PR-REVIEW|pr-review|done|N/A' <<<"$bracket" || return 1
  grep -qE '^[^|]*\|(PR-REVIEW\|checkout-pr\|done|META\|pr-created\|info)\|' "$log" 2>/dev/null && return 1
  impl=$(grep -n '^[^|]*|IMPLEMENT|implement|waiting|' "$log" 2>/dev/null | tail -1 | cut -d: -f1) || impl=""
  [ -n "$impl" ] || impl=0
  tail -n "+$((impl + 1))" "$log" 2>/dev/null | grep -q '^[^|]*|IMPLEMENT|commit-push|skip|'
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

  local open bracket anchor after
  open=$(grep -n "^[^|]*|${phase}|${step}|waiting|" "$log" 2>/dev/null | tail -1 | cut -d: -f1) || open=""
  if [ -z "$open" ]; then
    _prt_fail "$phase" no-bracket
    return 0
  fi
  bracket=$(tail -n "+$((open + 1))" "$log" 2>/dev/null) || bracket=""
  anchor=$(grep -n "^[^|]*|META|phase-route-anchor|info|${phase}\( \|$\)" <<<"$bracket" | tail -1 | cut -d: -f1) || anchor=""
  if [ -z "$anchor" ]; then
    _prt_fail "$phase" no-anchor
    return 0
  fi
  after=$(tail -n "+$((anchor + 1))" <<<"$bracket") || after=""

  local rec status verdict
  rec=$(grep '^[^|]*|META|phase-result|info|' <<<"$after" | _prt_msg |
    jq -c --arg p "$phase" 'select(type == "object" and .phase == $p)' 2>/dev/null | head -1) || rec=""
  if [ -z "$rec" ]; then
    _prt_fail "$phase" no-verdict
    return 0
  fi
  status=$(jq -r '.parse_status // ""' <<<"$rec" 2>/dev/null) || status=""
  verdict=$(jq -r '.claimed_verdict // ""' <<<"$rec" 2>/dev/null) || verdict=""

  if [ "$phase" = "PR-REVIEW" ] && [ "$status" = "absent" ] && _prt_no_diff "$log" "$bracket"; then
    _prt_emit done OK no-diff
    return 0
  fi
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
    delta=$(grep '^[^|]*|META|claim-delta|info|' <<<"$after" | _prt_msg | head -1) || delta=""
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
