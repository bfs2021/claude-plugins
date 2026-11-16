#!/usr/bin/env bash
# ── test-grill-skill-sources.sh ───────────────────────────────────────────────
# F68: every grill_* function SKILL.md tells the agent to call is defined after
# the source line(s) SKILL.md documents — and nothing else. A headless agent
# that sourced only lib/grill-hold.sh hit `grill_profile_load: command not
# found` and had to improvise the score and seal itself.
# ───────────────────────────────────────────────────────────────────────────────

set -euo pipefail

unset CLAUDE_CODE_SESSION_ID

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$TEST_DIR/../.." && pwd)"
SKILL="$PLUGIN_DIR/skills/grill-me/SKILL.md"

PASS=0
FAIL=0
pass() {
  PASS=$((PASS + 1))
  echo "  PASS $1"
}
fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL $1: $2"
}

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

echo "=== SKILL.md source lines ==="

# The documented source lines: `source "<path>"` in a code block, or the
# prose form "Source `<path>`". Both name the path with ${CLAUDE_PLUGIN_ROOT}.
paths=$(
  {
    grep -oE '^[[:space:]]*(source|\.)[[:space:]]+"?[^"[:space:]]*lib/grill[^"[:space:]]*\.sh' "$SKILL" |
      sed -E 's/^[[:space:]]*(source|\.)[[:space:]]+"?//' || true
    grep -oE 'Source `[^`]*lib/grill[^`]*\.sh`' "$SKILL" | sed -E 's/^Source `//; s/`$//' || true
  } | sort -u
)
if [ -n "$paths" ]; then
  pass "SKILL.md documents at least one lib source line"
else
  fail "SKILL.md documents at least one lib source line" "none found"
fi

# Every grill_* function SKILL.md names (calls and prose references alike).
wanted=$(grep -oE '\bgrill_[a-z_]+\b' "$SKILL" | sort -u)
if [ -n "$wanted" ]; then
  pass "SKILL.md names grill_* functions ($(echo "$wanted" | wc -l | tr -d ' '))"
else
  fail "SKILL.md names grill_* functions" "none found"
fi

# Source exactly the documented lines in a clean shell: no inherited
# functions, an empty HOME, CLAUDE_PLUGIN_ROOT pointing at this checkout.
printf '%s\n' "$paths" >"$SCRATCH/paths"
printf '%s\n' "$wanted" >"$SCRATCH/wanted"
# shellcheck disable=SC2016 # expanded by the inner shell
missing=$(env -i PATH="$PATH" HOME="$SCRATCH/home" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash --noprofile --norc -c '
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    p="${p//\$\{CLAUDE_PLUGIN_ROOT\}/$CLAUDE_PLUGIN_ROOT}"
    # shellcheck disable=SC1090
    . "$p" || { echo "SOURCE_FAILED:$p"; exit 0; }
  done <"$1"
  set +e
  while IFS= read -r f; do
    declare -F "$f" >/dev/null || echo "$f"
  done <"$2"
' _ "$SCRATCH/paths" "$SCRATCH/wanted" 2>&1)

if [ -z "$missing" ]; then
  pass "every grill_* function SKILL.md names is defined after its documented source line(s)"
else
  fail "every grill_* function SKILL.md names is defined after its documented source line(s)" \
    "$(echo "$missing" | tr '\n' ' ')"
fi

# The entry lib also works from the synced copy (~/.claude/skills/lib) and
# from any working directory: it resolves its siblings from its own path.
mkdir -p "$SCRATCH/synced/lib"
cp "$PLUGIN_DIR"/lib/*.sh "$SCRATCH/synced/lib/"
# shellcheck disable=SC2016 # expanded by the inner shell
out=$(cd / && env -i PATH="$PATH" HOME="$SCRATCH/home" bash --noprofile --norc -c '
  . "$1/lib/grill.sh" && declare -F grill_score grill_seal_generate grill_work_dir grill_profile_load grill_render grill_sanitize_input >/dev/null && echo ok
' _ "$SCRATCH/synced" 2>&1 || true)
if [ "$out" = "ok" ]; then
  pass "lib/grill.sh loads its siblings from its own directory"
else
  fail "lib/grill.sh loads its siblings from its own directory" "$out"
fi

echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo "$PASS/$TOTAL passed"
[ "$FAIL" -eq 0 ]
