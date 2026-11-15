#!/usr/bin/env bash
# test-corpus-privacy.sh — the corpus of real planner output sits in a public
# repository (seam-bash-derives slice 5). This gate fails on any file, or file
# name, under a `*/lib/tests/corpus/` directory that holds:
#   - a tracker issue id (<KEY>-<n>, any key but the scrub's TKT) or a
#     linear.app URL
#   - a real initiative id (INIT-<ts>-<n> whose timestamp is not the scrub's
#     0000000000), in either case
#   - a home directory path (/home/<user>, /Users/<user>, -home-<user>-), or a
#     home-relative path outside the scrub's neutral ~/work/
#   - a token-shaped string (sk-ant-, lin_api_, gh?_, github_pat_, glpat-,
#     xox?-, AKIA…, a JWT)
#   - an e-mail address outside conduit.test and example.{com,org,net}
#   - any private token listed in the local names file — names, the sandbox
#     repository and owner, tracker keys, path prefixes. The file is never
#     committed: $CORPUS_PRIVATE_NAMES_FILE, default
#     ~/.config/claude-plugins/corpus-private-names (the format is in
#     scripts/corpus-scrub.sh). Without it only the generic rules above run.
# It then plants one leak of each kind in a copy of a clean file — private
# names from a synthetic names file — and checks that the scan reports every
# one, so a weakened pattern fails here too.
#
# scripts/corpus-scrub.sh is the tool that removes these; this is the check.
#
# Run: bash ticket-planner/lib/tests/test-corpus-privacy.sh
#   CORPUS_PRIVACY_DIRS="<dir> …" scans those directories instead.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
NAMES_FILE="${CORPUS_PRIVATE_NAMES_FILE:-${HOME}/.config/claude-plugins/corpus-private-names}"

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

# One rule per leak kind: kind@@i (case-insensitive) or c@@extended regex@@
# allow regex (matches dropped, may be empty). Kept in sync with corpus-scrub.sh.
CORPUS_GENERIC=(
  'tracker-id@@c@@\b[A-Z][A-Z0-9]{1,4}-[0-9]+\b@@^(.*:)?(TKT|INIT)-[0-9]+$'
  'tracker-url@@i@@linear\.app/@@'
  'initiative-id@@i@@\binit-[1-9][0-9]{5,}-[0-9]+@@'
  'home-path@@i@@/home/[a-z0-9_]|/Users/[a-z0-9_]|-home-[a-z0-9_]+-@@'
  'home-path@@c@@~/[A-Za-z0-9_.-]+/@@^(.*:)?~/work/$'
  'home-path@@c@@-homedir-[A-Za-z0-9_.]+-@@^(.*:)?-homedir-work-$'
  'token@@i@@sk-ant-|lin_api_|\bgh[pousr]_[a-z0-9]{6,}|github_pat_|glpat-|\bxox[abp]-|\bakia[0-9a-z]{16}\b|\beyj[a-z0-9_-]{10,}\.[a-z0-9_-]{10,}\.@@'
)
CORPUS_EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
CORPUS_EMAIL_ALLOW='@(conduit\.test|example\.(com|org|net))$'

_lit() { printf '%s' "$1" | sed -e 's/[][\.*^$+?(){}|/]/\\&/g'; }

# corpus_privacy_rules <names-file> — set CORPUS_RULES to the generic rules
# plus one rule per private token in the file (none when it is missing).
corpus_privacy_rules() {
  local file="$1" kind value _
  CORPUS_RULES=("${CORPUS_GENERIC[@]}")
  [ -f "$file" ] || return 0
  while read -r kind value _; do
    case "$kind" in '' | '#'*) continue ;; esac
    case "$kind" in
    name | owner | sandbox) CORPUS_RULES+=("private-name@@i@@\\b$(_lit "$value")\\b@@") ;;
    tracker) CORPUS_RULES+=("tracker-id@@c@@\\b$(_lit "$value")\\b@@") ;;
    path) CORPUS_RULES+=("private-path@@c@@$(_lit "$value")@@") ;;
    esac
  done <"$file"
}

# corpus_privacy_scan <dir> — print one `<kind>\t<file>[:<line>]:<match>` per
# leak (contents and relative file names) under CORPUS_RULES; rc 1 when any.
corpus_privacy_scan() {
  local dir="$1" rule kind flag re allow rest out="" hits opt
  for rule in "${CORPUS_RULES[@]}"; do
    kind="${rule%%@@*}"
    rest="${rule#*@@}"
    flag="${rest%%@@*}"
    rest="${rest#*@@}"
    re="${rest%%@@*}"
    allow="${rest#*@@}"
    opt=-E
    [ "$flag" = i ] && opt=-iE
    hits=$({
      grep -rnoI "$opt" -e "$re" "$dir" 2>/dev/null
      (cd "$dir" && find . -mindepth 1 | grep -o "$opt" -e "$re" | sed 's/^/name:/')
    } | { if [ -n "$allow" ]; then grep -vE -e "$allow"; else cat; fi; })
    [ -n "$hits" ] && out="${out}$(sed "s/^/${kind}\t/" <<<"$hits")"$'\n'
  done
  hits=$(grep -rnoIE "$CORPUS_EMAIL_RE" "$dir" 2>/dev/null | grep -viE "$CORPUS_EMAIL_ALLOW")
  [ -n "$hits" ] && out="${out}$(sed "s/^/email\t/" <<<"$hits")"$'\n'
  printf '%s' "$out"
  [ -z "$out" ]
}

echo "=== corpus privacy (seam-bash-derives) ==="

if [ -n "${CORPUS_PRIVACY_DIRS:-}" ]; then
  read -r -a DIRS <<<"$CORPUS_PRIVACY_DIRS"
else
  mapfile -t DIRS < <(find "$REPO_ROOT" -maxdepth 5 -name .git -prune -o -type d -path '*/lib/tests/corpus' -print | sort)
fi

echo "--- every corpus directory is clean ---"
corpus_privacy_rules "$NAMES_FILE"
if [ -f "$NAMES_FILE" ]; then
  echo "  (private names: $((${#CORPUS_RULES[@]} - ${#CORPUS_GENERIC[@]})) rule(s) from the local names file)"
else
  echo "  (no local names file: generic rules only)"
fi
if [ "${#DIRS[@]}" -eq 0 ]; then
  fail "a corpus directory exists" "none found under ${REPO_ROOT}"
fi
for d in "${DIRS[@]}"; do
  rel="${d#"${REPO_ROOT}"/}"
  if leaks=$(corpus_privacy_scan "$d"); then
    pass "${rel}: no private data ($(find "$d" -type f | wc -l) files)"
  else
    fail "${rel}: private data" "$(head -20 <<<"$leaks")"
  fi
done

# ── planted leaks: the scan must see each kind ──────────────────────────────
echo "--- a planted leak of each kind is reported ---"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# Synthetic private tokens, planted through the same names-file mechanism.
printf '%s\n' '# synthetic' 'name zorblax' 'owner acme-corp' 'sandbox zorblax-sandbox' \
  'tracker ZRB' 'path ~/zorb/space/ ~/work/' >"$WORK/names"
corpus_privacy_rules "$WORK/names"
mkdir -p "$WORK/clean"
printf '%s\n' '2026-11-15T12:16:26Z|META|initiative-id|start|INIT-0000000000-0001' \
  'Sign in as jake@conduit.test or admin@example.com; repo app, owner owner, TKT-12.' \
  'Path ~/work/e2e-conduit/app, -homedir-work-e2e and /home/ is not a user.' >"$WORK/clean/state.log"
if corpus_privacy_scan "$WORK/clean" >/dev/null; then
  pass "the scrub's own fakes and allowlisted e-mails pass"
else
  fail "the scrub's own fakes and allowlisted e-mails pass" "$(corpus_privacy_scan "$WORK/clean")"
fi

plant() {
  local name="$1" kind="$2" text="$3" d="$WORK/plant-$1"
  rm -rf "$d"
  cp -r "$WORK/clean" "$d"
  printf '%s\n' "$text" >>"$d/state.log"
  local out
  out=$(corpus_privacy_scan "$d")
  if grep -q "^${kind}"$'\t' <<<"$out"; then
    pass "planted ${name} is reported as ${kind}"
  else
    fail "planted ${name} is reported as ${kind}" "scan said: ${out:-nothing}"
  fi
}
plant tracker-id tracker-id 'blocked-by:ABC-131'
plant team-key tracker-id "cannot resolve Linear team (ref='ZRB')"
plant tracker-url tracker-url 'see https://linear.app/acme/issue/TKT-1/x'
plant initiative-id initiative-id 'INIT-1794744986-6851 abandoned'
plant initiative-slug initiative-id 'specs/init-1794584184-3869-test-data-pack.md'
plant home-path home-path 'cd /home/alice/workspace'
plant mac-home home-path 'open /Users/alice/repo'
plant dash-home home-path '/tmp/claude-1000/-home-alice-workspace-x'
plant home-layout home-path 'State log: ~/projects/e2e/.ticket-auto/x'
plant dash-layout home-path '/tmp/c/-homedir-projects-e2e'
plant private-path private-path 'cd ~/zorb/space/e2e'
plant sandbox private-name 'git clone zorblax-sandbox'
plant owner private-name 'github.com/acme-corp/x'
plant name private-name 'ran by Zorblax on the host'
plant anthropic-key token 'ANTHROPIC_API_KEY=sk-ant-api03-abcdef'
plant linear-key token 'LINEAR_API_KEY=lin_api_abcdef123456'
plant github-pat token 'token ghp_abcdefghijkl1234'
plant jwt token 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJqYWtlIn0.abcdefghijklmn'
plant email email 'contact john.doe@gmail.com'
plant truncated-email email 'login as newauthor@conduit.te'

d="$WORK/plant-name"
rm -rf "$d"
cp -r "$WORK/clean" "$d"
mkdir -p "$d/ABC-120"
: >"$d/ABC-120/body.md"
if grep -q $'^tracker-id\tname:' <<<"$(corpus_privacy_scan "$d")"; then
  pass "a tracker id in a file name is reported"
else
  fail "a tracker id in a file name is reported" "$(corpus_privacy_scan "$d")"
fi

corpus_privacy_rules "$WORK/no-such-file"
if corpus_privacy_scan "$WORK/plant-name" >/dev/null 2>&1; then
  fail "without a names file the generic rules still run" "planted tracker id passed"
elif [ "${#CORPUS_RULES[@]}" -eq "${#CORPUS_GENERIC[@]}" ]; then
  pass "without a names file only the generic rules run, and they still report"
else
  fail "without a names file only the generic rules run" "${#CORPUS_RULES[@]} rules"
fi

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
