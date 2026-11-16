#!/usr/bin/env bash
# test-planner-panel.sh — the review panel lib (planner-persona-panel, tasks
# 2.2–2.4, 2.6): planner-panel.sh.
#
#   - seats: the three fixed seats, security on an auth plan and not on a
#     copy change, the developer for the first repository the proposal names,
#     the cap, PLANNER_PANEL_SEATS, seats.txt with reasons;
#   - prompt: the persona text, the input copy, the seat's own result path,
#     no other seat's file, no upstream artifact;
#   - parse: valid, None., every malformed reason, the 6-finding cap, CRLF,
#     fenced headings, another seat's prefix;
#   - due / next / apply: flag off, not available, no proposal, one spawn
#     line per seat, done, warn then fail NOT_RUN, contaminated, reuse by
#     sha, proposal-changed, a new version runs again;
#   - results and status; the combined goldfish + panel spawn list.
#
# Every case is guarded on the functions it needs.
#
# Run: bash ticket-planner/lib/tests/test-planner-panel.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export HOME="${WORK}/home"
mkdir -p "$HOME"
export REPOS_ROOT="${WORK}/repos"
mkdir -p "$REPOS_ROOT"
unset PLANNER_PHASE_PERSONAS PLANNER_PERSONA_PANEL PLANNER_PANEL_SEATS PLANNER_PANEL_TIMEOUT PLANNER_PANEL_AWK
unset PLANNER_GOLDFISH_REVIEW TICKET_AUTO_PLUGIN_ROOT PLANNER_PERSONA_OWN_ROOT
unset TICKET_TITLE TICKET_DESCRIPTION TICKET_TEXT_FILE TICKET_ID CLAUDE_PLUGIN_ROOT

source "${LIB_DIR}/planner-state.sh"
[ -f "${LIB_DIR}/planner-goldfish.sh" ] && source "${LIB_DIR}/planner-goldfish.sh"
[ -f "${LIB_DIR}/planner-panel.sh" ] && source "${LIB_DIR}/planner-panel.sh"

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
need() {
  local name="$1" fn
  shift
  for fn in "$@"; do
    if ! declare -f "$fn" >/dev/null; then
      fail "$name" "$fn missing"
      return 1
    fi
  done
  return 0
}
check() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got [$2] want [$3]"; fi
}
contains() {
  case "$2" in
  *"$3"*) pass "$1" ;;
  *) fail "$1" "missing [$3] in [$2]" ;;
  esac
}
lacks() {
  case "$2" in
  *"$3"*) fail "$1" "unexpected [$3] in [$2]" ;;
  *) pass "$1" ;;
  esac
}

ALONE="${WORK}/alone/ticket-planner"
mkdir -p "$ALONE"

mkdir -p "${REPOS_ROOT}/billing/.git" "${REPOS_ROOT}/web/.git" "${REPOS_ROOT}/notes"
: >"${REPOS_ROOT}/billing/pom.xml"
: >"${REPOS_ROOT}/web/angular.json"

AUTH_PLAN=$'# Proposal\n\n## Scope\nThe billing service checks the login token before it pauses a subscription.\n'
COPY_PLAN=$'# Proposal\n\n## Scope\nChange the heading text on the web page.\n'
BARE_PLAN=$'# Proposal\n\n## Scope\nRename a heading.\n'

N=0
# new_init [<proposal text>] — a fresh initiative with a proposal and a spec.
new_init() {
  N=$((N + 1))
  INIT="INIT-panel-${N}"
  planner_state_init "$INIT" "Pause a subscription" >/dev/null 2>&1
  SD="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT}"
  mkdir -p "${SD}/artifacts/specs"
  printf 'Pause a subscription\n' >"${SD}/artifacts/idea.txt"
  printf '# review\n' >"${SD}/artifacts/review.md"
  printf '# Spec pause\n' >"${SD}/artifacts/specs/pause.md"
  printf '%s' "${1:-$AUTH_PLAN}" >"${SD}/artifacts/proposal.md"
  LOG="${SD}/state.log"
}
pn_lines() { grep '|META|panel|' "$LOG" | cut -d'|' -f4-; }
seats_of() { cut -f1 | paste -sd, -; }

# write_result <seat> <PREFIX> <findings: "sev,sev,…" | none> [<extra Files Read path>] [<body line>]
write_result() {
  local seat="$1" prefix="$2" spec="$3" extra="${4:-}" body="${5:-}" sha f i=0 sev
  sha=$(planner_panel_sha12 "$INIT")
  f="${SD}/panel/review-${seat}.md"
  mkdir -p "${SD}/panel"
  {
    printf '# Panel Review — %s\n\n**Proposal:** %s\n\n## Findings\n' "$seat" "$sha"
    if [ "$spec" = "none" ]; then
      printf 'None.\n'
    else
      for sev in ${spec//,/ }; do
        i=$((i + 1))
        printf '### %s-%d — %s — Title %d\n**About:** proposal § Scope\n**Problem:** A problem.\n**Recommendation:** Fix it.\n\n' \
          "$prefix" "$i" "$sev" "$i"
      done
    fi
    [ -n "$body" ] && printf '%s\n' "$body"
    printf '\n## Files Read\n- %s/panel/input/proposal.md\n- %s/billing/pom.xml\n' "$SD" "$REPOS_ROOT"
    [ -n "$extra" ] && printf -- '- %s\n' "$extra"
  } >"$f"
}

echo "=== planner-panel: seats (2.2) ==="

name="auth plan on a backend repository: all five seats"
if need "$name" planner_panel_seats planner_panel_sha12; then
  new_init "$AUTH_PLAN"
  rows=$(planner_panel_seats "$INIT")
  check "$name" "$(printf '%s\n' "$rows" | seats_of)" "product-owner,architect,qa-engineer,security,developer"
  check "$name: prefixes" "$(printf '%s\n' "$rows" | cut -f2 | paste -sd, -)" "PO,ARCH,QA,SEC,DEV"
  contains "$name: developer is the backend developer" "$(printf '%s\n' "$rows" | grep '^developer')" "backend-developer.md"
  contains "$name: with the Java specializer" "$(printf '%s\n' "$rows" | grep '^developer')" "specializers/backend/java.md"
  contains "$name: developer reason" "$(printf '%s\n' "$rows" | grep '^developer' | cut -f4)" "billing (BE, backend-developer)"
  contains "$name: security reason" "$(printf '%s\n' "$rows" | grep '^security' | cut -f4)" "auto-include"
  check "$name: seats.txt header" "$(head -1 "${SD}/panel/seats.txt")" "# proposal $(planner_panel_sha12 "$INIT")"
  check "$name: seats.txt rows" "$(tail -n +2 "${SD}/panel/seats.txt")" "$rows"
fi

name="copy change on a frontend repository: no security seat"
if need "$name" planner_panel_seats; then
  new_init "$COPY_PLAN"
  rows=$(planner_panel_seats "$INIT")
  check "$name" "$(printf '%s\n' "$rows" | seats_of)" "product-owner,architect,qa-engineer,developer"
  contains "$name: frontend developer" "$(printf '%s\n' "$rows" | grep '^developer')" "frontend-developer.md"
fi

name="a plan that names no repository: the fixed seats only"
if need "$name" planner_panel_seats; then
  new_init "$BARE_PLAN"
  check "$name" "$(planner_panel_seats "$INIT" | seats_of)" "product-owner,architect,qa-engineer"
fi

name="a trigger word with no repository still seats security"
if need "$name" planner_panel_seats; then
  new_init $'# Proposal\nStore the password hash.\n'
  rows=$(planner_panel_seats "$INIT")
  check "$name" "$(printf '%s\n' "$rows" | seats_of)" "product-owner,architect,qa-engineer,security"
  contains "$name: reason" "$(printf '%s\n' "$rows" | grep '^security' | cut -f4)" "trigger word"
fi

name="PLANNER_PANEL_SEATS narrows and cannot add"
if need "$name" planner_panel_seats; then
  new_init "$AUTH_PLAN"
  check "$name: subset" "$(PLANNER_PANEL_SEATS="security, qa-engineer debugger" planner_panel_seats "$INIT" | seats_of)" \
    "qa-engineer,security"
  check "$name: developer by its persona name" \
    "$(PLANNER_PANEL_SEATS="backend-developer" planner_panel_seats "$INIT" | seats_of)" "developer"
  check "$name: only unknown names leaves no seat" "$(PLANNER_PANEL_SEATS="debugger" planner_panel_seats "$INIT" | seats_of)" ""
fi

name="the cap"
if need "$name" planner_panel_seats; then
  new_init "$AUTH_PLAN"
  check "$name: at most five" "$(planner_panel_seats "$INIT" | wc -l)" "5"
  check "$name: lowered" "$(PLANNER_PANEL_MAX_SEATS=4 planner_panel_seats "$INIT" | seats_of)" \
    "product-owner,architect,qa-engineer,security"
fi

name="personas not available: rc 1"
if need "$name" planner_panel_seats; then
  new_init
  PLANNER_PERSONA_OWN_ROOT="$ALONE" planner_panel_seats "$INIT" >/dev/null &&
    fail "$name" "rc 0" || pass "$name"
fi

echo "=== planner-panel: prompt (2.3) ==="

name="the seat's prompt"
if need "$name" planner_panel_next; then
  new_init "$AUTH_PLAN"
  export PLANNER_PERSONA_PANEL=true
  planner_panel_next "$INIT" >/dev/null 2>&1
  p=$(cat "${SD}/panel/prompt-security.txt" 2>/dev/null)
  contains "$name: seat" "$p" "the **security** seat"
  contains "$name: persona text" "$p" "### Security"
  contains "$name: input proposal" "$p" "${SD}/panel/input/proposal.md"
  contains "$name: input specs" "$p" "${SD}/panel/input/specs/"
  contains "$name: intent" "$p" "${SD}/panel/input/intent.txt"
  contains "$name: repository" "$p" "- ${REPOS_ROOT}/billing"
  lacks "$name: non-git directory left out" "$p" "${REPOS_ROOT}/notes"
  contains "$name: own result" "$p" "${SD}/panel/review-security.md"
  contains "$name: id prefix" "$p" "### SEC-1 — major — "
  contains "$name: sha" "$p" "**Proposal:** $(planner_panel_sha12 "$INIT")"
  contains "$name: cap" "$p" "At most 6 findings"
  for w in "review-product-owner.md" "review-architect.md" "review-qa-engineer.md" "review-developer.md" \
    "review.md" "goldfish" "artifacts/" "consensus"; do
    lacks "$name: withholds '$w'" "$p" "$w"
  done
  cmp -s "${SD}/artifacts/proposal.md" "${SD}/panel/input/proposal.md" &&
    pass "input proposal is byte-identical" || fail "input proposal is byte-identical" "differs"
  [ -f "${SD}/panel/input/specs/pause.md" ] && pass "specs copied" || fail "specs copied" "missing"
  [ -f "${SD}/panel/input/intent.txt" ] && pass "intent copied" || fail "intent copied" "missing"
  contains "the developer prompt carries base and specializer" "$(cat "${SD}/panel/prompt-developer.txt")" "### Backend Developer"
  unset PLANNER_PERSONA_PANEL
fi

echo "=== planner-panel: parse (2.4) ==="

if need "parse" planner_panel_parse; then
  new_init
  sha=$(planner_panel_sha12 "$INIT")
  F="${SD}/panel/review-qa-engineer.md"
  write_result qa-engineer QA "blocker,major,minor,nit"
  check "valid" "$(planner_panel_parse "$F" "$sha" QA)" "ok 4 QA-1,QA-2 QA-1"
  write_result qa-engineer QA "minor"
  check "no blocker or major" "$(planner_panel_parse "$F" "$sha" QA)" "ok 1 - -"
  write_result qa-engineer QA none
  check "None." "$(planner_panel_parse "$F" "$sha" QA)" "ok 0 - -"
  write_result qa-engineer QA "major,major,major,major,major,major,blocker"
  check "over the cap" "$(planner_panel_parse "$F" "$sha" QA)" "ok 6 QA-1,QA-2,QA-3,QA-4,QA-5,QA-6 - capped"
  write_result qa-engineer QA "major"
  check "wrong sha" "$(planner_panel_parse "$F" 000000000000 QA)" "malformed wrong-proposal"
  check "another seat's prefix is a bad heading" "$(planner_panel_parse "$F" "$sha" SEC)" "malformed bad-heading"
  sed -i 's/$/\r/' "$F"
  check "CRLF" "$(planner_panel_parse "$F" "$sha" QA)" "ok 1 QA-1 -"
  write_result qa-engineer QA "major"
  sed -i '/^\*\*Proposal:/d' "$F"
  check "no proposal line" "$(planner_panel_parse "$F" "$sha" QA)" "malformed no-proposal-line"
  write_result qa-engineer QA "major"
  sed -i 's/^## Findings$/## Results/' "$F"
  check "no findings section" "$(planner_panel_parse "$F" "$sha" QA)" "malformed no-findings-section"
  write_result qa-engineer QA "major"
  sed -i 's/^## Files Read$/## Files/' "$F"
  check "no files read" "$(planner_panel_parse "$F" "$sha" QA)" "malformed no-files-read"
  write_result qa-engineer QA "major"
  sed -i 's/ — major — / - major - /' "$F"
  check "bad separator" "$(planner_panel_parse "$F" "$sha" QA)" "malformed bad-heading"
  write_result qa-engineer QA "critical"
  check "bad severity" "$(planner_panel_parse "$F" "$sha" QA)" "malformed bad-heading"
  write_result qa-engineer QA "major,minor"
  sed -i 's/^### QA-2 /### QA-1 /' "$F"
  check "duplicate id" "$(planner_panel_parse "$F" "$sha" QA)" "malformed duplicate-id"
  write_result qa-engineer QA none
  sed -i '/^None\.$/d' "$F"
  check "empty findings" "$(planner_panel_parse "$F" "$sha" QA)" "malformed empty-findings"
  write_result qa-engineer QA "major" "" "None."
  check "None. with findings" "$(planner_panel_parse "$F" "$sha" QA)" "malformed none-with-findings"
  write_result qa-engineer QA "major" "" $'```\n### QA-9 — blocker — In a fence\n```'
  check "fenced heading not counted" "$(planner_panel_parse "$F" "$sha" QA)" "ok 1 QA-1 -"
  : >"$F"
  check "empty file" "$(planner_panel_parse "$F" "$sha" QA)" "malformed empty"
  if command -v mawk >/dev/null 2>&1 && command -v gawk >/dev/null 2>&1; then
    write_result qa-engineer QA "blocker,major,minor"
    check "mawk and gawk agree" "$(PLANNER_PANEL_AWK=mawk planner_panel_parse "$F" "$sha" QA)" \
      "$(PLANNER_PANEL_AWK=gawk planner_panel_parse "$F" "$sha" QA)"
  else
    echo "  SKIP mawk and gawk agree (one of them is not installed)"
  fi
fi

echo "=== planner-panel: due, next, apply (2.4) ==="

name="flag off: skip DISABLED once, nothing spawned, no panel directory"
if need "$name" planner_panel_due planner_panel_next; then
  new_init
  sha=$(planner_panel_sha12 "$INIT")
  check "$name: next" "$(planner_panel_next "$INIT")" "done 0"
  planner_panel_due "$INIT" && fail "$name: not due" "due" || pass "$name: not due"
  check "$name: one line" "$(pn_lines)" "skip|${sha} DISABLED"
  [ -d "${SD}/panel" ] && fail "$name: no panel directory" "exists" || pass "$name: no panel directory"
  PLANNER_PERSONA_PANEL=true planner_panel_due "$INIT" &&
    fail "flag turned on later does not re-decide the version" "due" ||
    pass "flag turned on later does not re-decide the version"
fi

name="personas not available: skip NOT_AVAILABLE and the persona line"
if need "$name" planner_panel_next; then
  new_init
  sha=$(planner_panel_sha12 "$INIT")
  out=$(PLANNER_PERSONA_PANEL=true PLANNER_PERSONA_OWN_ROOT="$ALONE" planner_panel_next "$INIT")
  check "$name: next" "$out" "done 0"
  check "$name: line" "$(pn_lines)" "skip|${sha} NOT_AVAILABLE"
  check "$name: persona line" "$(grep -c '|META|persona|skip|NOT_AVAILABLE' "$LOG")" "1"
fi

name="no proposal: skip NO_PROPOSAL"
if need "$name" planner_panel_next; then
  new_init
  rm -f "${SD}/artifacts/proposal.md"
  sha=$(planner_panel_sha12 "$INIT")
  check "$name: next" "$(PLANNER_PERSONA_PANEL=true planner_panel_next "$INIT")" "done 0"
  check "$name: line" "$(pn_lines)" "skip|${sha} NO_PROPOSAL"
fi

name="flag on: one spawn line per seat"
if need "$name" planner_panel_due planner_panel_next planner_panel_apply; then
  new_init "$AUTH_PLAN"
  sha=$(planner_panel_sha12 "$INIT")
  export PLANNER_PERSONA_PANEL=true
  planner_panel_due "$INIT" && pass "$name: due" || fail "$name: due" "not due"
  check "due writes no panel line while seats are due" "$(pn_lines | wc -l)" "0"
  out=$(planner_panel_next "$INIT" 2>/dev/null)
  check "$name: five lines" "$(printf '%s\n' "$out" | wc -l)" "5"
  line=$(printf '%s\n' "$out" | sed -n 4p)
  IFS=$'\t' read -r f1 f2 f3 f4 f5 f6 <<<"$line"
  check "field 1 id" "$f1" "${INIT}:security"
  check "field 2 kind" "$f2" "panel"
  check "field 3 agent" "$f3" "ticket-planner:panel-review-agent"
  check "field 4 prompt" "$f4" "${SD}/panel/prompt-security.txt"
  check "field 5 result" "$f5" "${SD}/panel/review-security.md"
  check "no sixth field" "${f6:-}" ""
  check "five start lines" "$(pn_lines | grep -c "^start|${sha} .* attempt=1\$")" "5"

  # Round 1: PO and QA valid, architect none, security malformed, developer missing.
  write_result product-owner PO "blocker,minor"
  write_result qa-engineer QA "major"
  write_result architect ARCH none
  write_result security SEC "critical"
  planner_panel_apply "$INIT"
  contains "PO done" "$(pn_lines)" "done|${sha} product-owner findings=2 bm=PO-1 blockers=PO-1"
  contains "QA done" "$(pn_lines)" "done|${sha} qa-engineer findings=1 bm=QA-1 blockers=-"
  contains "ARCH done with no findings" "$(pn_lines)" "done|${sha} architect findings=0 bm=- blockers=-"
  contains "SEC first failure is a warn" "$(pn_lines)" "warn|${sha} security attempt=1 malformed:bad-heading"
  contains "DEV first failure is a warn" "$(pn_lines)" "warn|${sha} developer attempt=1 no-result"
  [ -f "${SD}/panel/review-security.md" ] && fail "malformed result deleted" "kept" || pass "malformed result deleted"
  [ -f "${SD}/panel/review-product-owner.md" ] && pass "valid result kept" || fail "valid result kept" "deleted"

  # Round 2: only the two failed seats are handed out again.
  out=$(planner_panel_next "$INIT" 2>/dev/null)
  check "retry: two lines" "$(printf '%s\n' "$out" | cut -f1 | paste -sd, -)" "${INIT}:security,${INIT}:developer"
  [ -f "${SD}/panel/review-product-owner.md" ] && pass "retry keeps the other seats' results" ||
    fail "retry keeps the other seats' results" "deleted"
  write_result security SEC "blocker"
  planner_panel_apply "$INIT"
  contains "SEC done on the second attempt" "$(pn_lines)" "done|${sha} security findings=1 bm=SEC-1 blockers=SEC-1"
  contains "DEV recorded not run" "$(pn_lines)" "fail|${sha} developer NOT_RUN no-result"
  check "nothing left" "$(planner_panel_next "$INIT")" "done 0"
  planner_panel_due "$INIT" && fail "same proposal again: not due" "due" || pass "same proposal again: not due"
  n=$(pn_lines | wc -l)
  planner_panel_apply "$INIT"
  check "apply again writes nothing" "$(pn_lines | wc -l)" "$n"
  check "position is unaffected" "$(planner_position_derive "$INIT")" "Appraisal"

  name2="results"
  if need "$name2" planner_panel_results planner_panel_status; then
    res=$(planner_panel_results "$INIT")
    check "$name2: five rows" "$(printf '%s\n' "$res" | wc -l)" "5"
    check "$name2: PO" "$(printf '%s\n' "$res" | sed -n 1p)" "$(printf 'product-owner\tPO\tdone\t2\tPO-1\tPO-1\t-')"
    check "$name2: DEV" "$(printf '%s\n' "$res" | sed -n 5p)" "$(printf 'developer\tDEV\tfail\t0\t-\t-\tno-result')"
    st=$(planner_panel_status "$INIT")
    contains "status: ran" "$st" "Panel product-owner (PO): ran — 2 finding(s), see panel/review-product-owner.md"
    contains "status: no findings" "$st" "Panel architect (ARCH): ran — 0 finding(s)"
    contains "status: not run" "$st" "Panel developer (DEV): NOT RUN — no-result. Its findings are unknown, not zero."
    check "status: one line per seat" "$(printf '%s\n' "$st" | wc -l)" "5"
  fi

  # A new proposal version runs the panel again and keeps the old lines.
  printf '\nMore scope.\n' >>"${SD}/artifacts/proposal.md"
  sha2=$(planner_panel_sha12 "$INIT")
  planner_panel_due "$INIT" && pass "a new version is due" || fail "a new version is due" "not due"
  check "seats.txt rewritten for the new version" "$(head -1 "${SD}/panel/seats.txt")" "# proposal ${sha2}"
  out=$(planner_panel_next "$INIT" 2>/dev/null)
  check "new version: five lines" "$(printf '%s\n' "$out" | wc -l)" "5"
  [ -f "${SD}/panel/review-product-owner.md" ] && fail "old result removed before the spawn" "kept" ||
    pass "old result removed before the spawn"
  contains "old version's lines kept" "$(pn_lines)" "done|${sha} product-owner findings=2"

  # The proposal changes while the seats run.
  printf '\nEven more.\n' >>"${SD}/artifacts/proposal.md"
  write_result product-owner PO "minor"
  planner_panel_apply "$INIT"
  check "proposal-changed: every started seat" "$(pn_lines | grep -c "^fail|${sha2} .* NOT_RUN proposal-changed\$")" "5"
  unset PLANNER_PERSONA_PANEL
fi

name="a valid result on disk is reused without a spawn"
if need "$name" planner_panel_next planner_panel_seats; then
  new_init "$BARE_PLAN"
  sha=$(planner_panel_sha12 "$INIT")
  export PLANNER_PERSONA_PANEL=true
  planner_panel_next "$INIT" >/dev/null 2>&1
  write_result product-owner PO "major"
  write_result architect ARCH none
  write_result qa-engineer QA "minor"
  check "$name: next" "$(planner_panel_next "$INIT")" "done 0"
  check "$name: three done lines" "$(pn_lines | grep -c "^done|${sha} ")" "3"
  check "$name: one start per seat" "$(pn_lines | grep -c '^start|')" "3"
  unset PLANNER_PERSONA_PANEL
fi

name="crash between NEXT and APPLY twice: NOT_RUN no-result"
if need "$name" planner_panel_next; then
  new_init "$BARE_PLAN"
  sha=$(planner_panel_sha12 "$INIT")
  export PLANNER_PERSONA_PANEL=true
  planner_panel_next "$INIT" >/dev/null 2>&1
  planner_panel_next "$INIT" >/dev/null 2>&1
  check "$name: next" "$(planner_panel_next "$INIT")" "done 0"
  check "$name: three fail lines" "$(pn_lines | grep -c "^fail|${sha} .* NOT_RUN no-result\$")" "3"
  check "$name: two starts per seat" "$(pn_lines | grep -c '^start|')" "6"
  unset PLANNER_PERSONA_PANEL
fi

name="contamination"
if need "$name" planner_panel_next planner_panel_apply; then
  new_init "$BARE_PLAN"
  sha=$(planner_panel_sha12 "$INIT")
  export PLANNER_PERSONA_PANEL=true
  planner_panel_next "$INIT" >/dev/null 2>&1
  write_result product-owner PO "major" "${SD}/artifacts/review.md"
  write_result architect ARCH "major" "" "As QA-2 also says, this is wrong."
  write_result qa-engineer QA "major" "${SD}/panel/input/specs/pause.md" "The ticket AB-12 is fine."
  planner_panel_apply "$INIT"
  contains "$name: a file outside the input copy" "$(pn_lines)" \
    "warn|${sha} product-owner attempt=1 contaminated:${SD}/artifacts/review.md"
  contains "$name: another seat's id" "$(pn_lines)" "warn|${sha} architect attempt=1 contaminated:foreign-id:QA-2"
  contains "$name: the input copy and other ids are fine" "$(pn_lines)" "done|${sha} qa-engineer findings=1"
  # A token the plan itself holds is not another seat's id.
  new_init $'# Proposal\nFollows ticket DEV-12.\n'
  sha=$(planner_panel_sha12 "$INIT")
  planner_panel_next "$INIT" >/dev/null 2>&1
  write_result architect ARCH "major" "" "DEV-12 already covers this."
  planner_panel_apply "$INIT"
  contains "$name: a token from the plan is allowed" "$(pn_lines)" "done|${sha} architect findings=1"
  unset PLANNER_PERSONA_PANEL
fi

name="a seat without a persona file is recorded, the others run"
if need "$name" planner_panel_next; then
  new_init "$BARE_PLAN"
  sha=$(planner_panel_sha12 "$INIT")
  fake="${WORK}/partial"
  mkdir -p "${fake}/personas/base"
  cp "${LIB_DIR}/../../ticket-auto-pipeline/personas/base/product-owner.md" \
    "${LIB_DIR}/../../ticket-auto-pipeline/personas/base/architect.md" "${fake}/personas/base/"
  out=$(PLANNER_PERSONA_PANEL=true TICKET_AUTO_PLUGIN_ROOT="$fake" planner_panel_next "$INIT" 2>/dev/null)
  check "$name: two seats spawn" "$(printf '%s\n' "$out" | cut -f1 | paste -sd, -)" "${INIT}:product-owner,${INIT}:architect"
  contains "$name: the missing one" "$(pn_lines)" "fail|${sha} qa-engineer NOT_RUN no-persona"
fi

echo "=== planner-panel: status without a run ==="

if need "status" planner_panel_status planner_panel_results; then
  new_init
  check "no record" "$(planner_panel_status "$INIT")" "Panel: NOT RUN — no record. Its findings are unknown, not zero."
  check "no record: no results" "$(planner_panel_results "$INIT")" ""
  planner_panel_next "$INIT" >/dev/null
  check "disabled" "$(planner_panel_status "$INIT")" "Panel: disabled"
  new_init
  PLANNER_PERSONA_PANEL=true PLANNER_PERSONA_OWN_ROOT="$ALONE" planner_panel_next "$INIT" >/dev/null
  check "not available" "$(planner_panel_status "$INIT")" \
    "Panel: NOT RUN — persona files not found. Its findings are unknown, not zero."
fi

echo "=== planner-panel: timeout ==="

if need "timeout" planner_panel_timeout_ms; then
  check "default" "$(planner_panel_timeout_ms)" "600000"
  check "set" "$(PLANNER_PANEL_TIMEOUT=90 planner_panel_timeout_ms)" "90000"
  check "bad value falls back" "$(PLANNER_PANEL_TIMEOUT=abc planner_panel_timeout_ms)" "600000"
fi

echo "=== planner-panel: the goldfish lens and the panel as one list ==="

name="combined spawn list"
if need "$name" planner_review_lenses_next planner_review_lenses_apply planner_goldfish_next; then
  new_init "$BARE_PLAN"
  check "$name: both off" "$(planner_review_lenses_next "$INIT")" "done 0"
  new_init "$BARE_PLAN"
  export PLANNER_PERSONA_PANEL=true PLANNER_GOLDFISH_REVIEW=true
  out=$(planner_review_lenses_next "$INIT" 2>/dev/null)
  check "$name: goldfish first, then the seats" "$(printf '%s\n' "$out" | cut -f2 | paste -sd, -)" "lens,panel,panel,panel"
  write_result product-owner PO none
  write_result architect ARCH none
  write_result qa-engineer QA none
  planner_review_lenses_apply "$INIT"
  check "$name: seats recorded" "$(pn_lines | grep -c '^done|')" "3"
  contains "$name: goldfish failure recorded by its own lib" "$(grep '|META|goldfish|' "$LOG")" "attempt=1 no-result"
  out=$(planner_review_lenses_next "$INIT" 2>/dev/null)
  check "$name: only the goldfish retry is left" "$(printf '%s\n' "$out" | cut -f2 | paste -sd, -)" "lens"
  planner_review_lenses_apply "$INIT"
  check "$name: done when both are done" "$(planner_review_lenses_next "$INIT")" "done 0"
  unset PLANNER_PERSONA_PANEL PLANNER_GOLDFISH_REVIEW
fi

echo ""
echo "=== planner-panel: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
