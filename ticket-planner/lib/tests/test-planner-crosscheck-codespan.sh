#!/usr/bin/env bash
# test-planner-crosscheck-codespan.sh — dispatch rehearsal F53:
# CODE_SPAN_EDGE_SPACE flags an inline code span that starts and ends with a
# space (markdown drops one from each end), is warn-level, skips fenced blocks
# and synth-marked TD specs, and reaches the state log through a full
# Crosscheck run.
#
# Run: bash ticket-planner/lib/tests/test-planner-crosscheck-codespan.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-crosscheck.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
export REPOS_ROOT="${TMPDIR}/repos"
mkdir -p "$REPOS_ROOT"

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
assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}
assert_contains() {
  case "$2" in
  *"$3"*) pass "$1" ;;
  *) fail "$1" "missing '$3' in: $2" ;;
  esac
}

# _spans <text> — flagged "<line>:<content>" entries, '|'-joined.
_spans() {
  local f="${TMPDIR}/one.md"
  printf '%s\n' "$1" >"$f"
  _planner_crosscheck_codespan_one "$f" | awk -F'\t' '{printf "%s%s:%s", (NR > 1 ? "|" : ""), $1, $2}'
}

echo "--- detection ---"
assert_eq "rehearsal case flagged" "$(_spans '- [ ] title `  Hello,  World!! ` returns `hello-world`.')" "1:  Hello,  World!! "
assert_eq "single space each end flagged" "$(_spans 'a ` x ` b')" "1: x "
assert_eq "leading space only kept" "$(_spans 'title ` Hello` ok')" ""
assert_eq "trailing space only kept" "$(_spans 'title `Hello ` ok')" ""
assert_eq "all-space span kept" "$(_spans 'a `   ` b')" ""
assert_eq "plain spans clean" "$(_spans 'run `npm test` in `backend/`')" ""
assert_eq "quoted value is the fix" "$(_spans 'title `"  Hello,  World!! "` ok')" ""
assert_eq "double-backtick span" "$(_spans 'a `` `x` `` b')" "1: \`x\` "
assert_eq "unclosed backtick ignored" "$(_spans 'a ` x b')" ""
assert_eq "two spans, one flagged" "$(_spans 'a `ok` and ` bad ` c')" "1: bad "
assert_eq "line number of the span" "$(_spans $'# t\n\nfine\n- ` v ` here')" "4: v "
assert_eq "fenced block skipped" "$(_spans $'```\nx ` y ` z\n```\nafter')" ""

echo "--- initiative run ---"
INIT="INIT-CSP-1"
planner_state_init "$INIT" "an idea" >/dev/null
SPECS="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT}/artifacts/specs"
mkdir -p "$SPECS"
printf '# a\n\n## Acceptance Criteria\n\n- [ ] title `  Hello,  World!! ` returns `hello-world`.\n' >"${SPECS}/article-create.md"
printf '<!-- planner:testdata-synth v1 -->\n# td\n\n- [ ] ` x ` seeded\n' >"${SPECS}/article-create-test-data.md"
printf '# idx\n\n` y `\n' >"${SPECS}/INDEX.md"
out=$(planner_crosscheck_codespan "$INIT")
rc=$?
assert_eq "rc 1 on a finding" "$rc" "1"
assert_eq "one finding (TD spec and INDEX skipped)" "$(grep -c CODE_SPAN_EDGE_SPACE <<<"$out")" "1"
assert_contains "finding names file and line" "$out" "planner-crosscheck-codespan: CODE_SPAN_EDGE_SPACE article-create.md:5 inline code"
assert_contains "finding shows what readers see" "$out" 'readers and Linear see ` Hello,  World!!`'
assert_eq "warn code registered" "$(_planner_crosscheck_is_warn_code CODE_SPAN_EDGE_SPACE && echo yes)" "yes"

planner_crosscheck_run "$INIT" >/dev/null 2>&1
log=$(planner_state_log "$INIT")
assert_contains "warn reaches state.log" "$(cat "$log")" "|META|crosscheck|warn|info CODE_SPAN_EDGE_SPACE article-create.md:5"
if grep -q '|META|crosscheck|fail|CODE_SPAN_EDGE_SPACE' "$log"; then
  fail "never blocking" "found a fail line"
else
  pass "never blocking"
fi

rm -f "${SPECS}/article-create.md"
out=$(planner_crosscheck_codespan "$INIT")
assert_eq "clean specs rc 0" "$?" "0"
assert_eq "clean specs print nothing" "$out" ""

echo "--- Specify self-lint ---"
source "${LIB_DIR}/planner-phase-prompts.sh"
prompt=$(planner_prompt_for_phase Specify "$INIT" "an idea" "${REPOS_ROOT}/.ticket-auto/initiatives/${INIT}" 2>/dev/null)
assert_contains "Specify prompt runs the codespan lint" "$prompt" "planner_crosscheck_codespan \"${INIT}\""

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
